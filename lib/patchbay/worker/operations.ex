defmodule Patchbay.Worker.Operations do
  @moduledoc """
  Registry of fixed operations available to one worker.

  An operation is a map with:

      %{
        name: "build",
        executable: "/nix/store/.../bin/nix",
        argv: ["build", "{%workspace}{target}"],
        arguments: %{
          "target" => %{type: :string, required: true}
        }
      }

  `{%workspace}` is filled by the worker's configured workspace. Other fixed
  variables come from the `:variables` option. `{name}` placeholders are
  filled from validated model-facing arguments. Rendering substitutes within
  an argv element and never splits one element into several; it is single pass
  and `{{`/`}}` escape literal braces. Execution does not invoke a shell.
  `executable` may be an absolute path or a bare command name resolved on the
  worker's `PATH` when the operation runs.

  Operation files are external terms decoded with `[:safe]`. They are expected
  to be manager-owned configuration, written per worker, not model input.
  """

  alias Patchbay.Toolkit.Name
  alias Patchbay.Toolkit.Variables
  alias Patchbay.Worker.Exec
  alias Patchbay.Worker.Protocol

  @max_operations 128
  @max_argv_elements 256
  @max_arg_value_bytes 65_536
  @max_rendered_argv_bytes 262_144
  @max_symlink_depth 40
  @argument_name_regex ~r/^[A-Za-z_][A-Za-z0-9_-]*$/
  @types [:string, :integer, :number, :boolean, :enum, :path, :file, :directory]

  @type operation :: %{
          name: binary(),
          executable: binary(),
          argv: [binary()],
          arguments: %{optional(binary()) => map()}
        }

  @doc "Loads and validates an operation file."
  @spec load(binary()) :: {:ok, [operation()]} | {:error, term()}
  def load(path) when is_binary(path) do
    with {:ok, binary} <- File.read(path),
         {:ok, term} <- decode(binary),
         {:ok, operations} <- validate(term) do
      {:ok, operations}
    end
  end

  @doc "Validates an already-decoded operation list."
  @spec validate(term()) :: {:ok, [operation()]} | {:error, term()}
  def validate(operations) when is_list(operations) and length(operations) <= @max_operations do
    with {:ok, validated} <- map_ok(operations, &validate_operation/1) do
      names = Enum.map(validated, & &1.name)

      if length(Enum.uniq(names)) == length(names) do
        {:ok, validated}
      else
        {:error, {:duplicate_operation, names -- Enum.uniq(names)}}
      end
    end
  end

  def validate(_operations), do: {:error, :invalid_operations}

  @doc """
  Executes `name` with model-facing `arguments`.

  Returns the `Patchbay.Worker.Exec` result plus a `:status` field. A nonzero
  exit status is reported as `:error`; the output is still returned.
  """
  @spec execute([operation()], binary(), term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute(operations, name, arguments, opts \\ []) when is_list(operations) do
    with {:ok, operation} <- fetch(operations, name),
         {:ok, values} <- validate_arguments(operation, arguments),
         {:ok, argv, workspace} <- render_argv(operation, values, opts) do
      exec_opts =
        opts
        |> Keyword.take([:timeout, :max_output_bytes, :secret_names])
        |> Keyword.put(:cd, workspace)

      case Exec.run(operation.executable, argv, exec_opts) do
        {:ok, result} ->
          {:ok, Map.put(result, :status, if(result.exit_status == 0, do: :ok, else: :error))}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc "Lists operation names in declaration order."
  @spec names([operation()]) :: [binary()]
  def names(operations), do: Enum.map(operations, & &1.name)

  @doc """
  Canonicalizes an absolute path: `Path.expand/1` normalization followed by
  symlink resolution of existing components.

  The result of `Path.expand/2` includes `..` and `.` segments in place, so
  lexical normalization happens before components are walked; existing
  components are then read with `File.lstat/1` and symlinks are resolved
  within a depth limit. A missing tail stays lexical, so the caller can
  confine a path that does not exist yet.

  Shared by tool-path confinement and by artifact reading across the
  worker/manager UID split.
  """
  @spec canonical(binary()) :: {:ok, binary()} | {:error, :invalid_path}
  def canonical(path) when is_binary(path), do: canonical_allow_missing(path)

  @doc """
  Validates operations declared by an agent definition.

  A definition operation may carry `executable` separately. When it does not,
  the first `argv` element is the executable and the remaining elements become
  the argument vector. This is the same contract `validate/1` applies to
  operation files.
  """
  @spec from_definition([struct() | map()]) :: {:ok, [operation()]} | {:error, term()}
  def from_definition(operations) when is_list(operations) do
    operations
    |> Enum.map(&definition_operation/1)
    |> validate()
  end

  def from_definition(_operations), do: {:error, :invalid_operations}

  defp definition_operation(%{__struct__: _module} = operation),
    do: operation |> Map.from_struct() |> definition_operation()

  defp definition_operation(%{} = operation) do
    requested =
      operation
      |> Map.get(:argv, [])
      |> List.wrap()
      |> Enum.flat_map(&Variables.references(&1).arguments)
      |> MapSet.new()

    arguments =
      operation
      |> Map.get(:arguments, %{})
      |> Map.new(fn {name, spec} ->
        {name, normalize_definition_argument(name, spec, requested)}
      end)

    operation = Map.put(operation, :arguments, arguments)

    case Map.get(operation, :executable) do
      nil -> Map.delete(operation, :executable)
      _executable -> operation
    end
  end

  defp definition_operation(other), do: other

  defp normalize_definition_argument(name, %{__struct__: _module} = argument, requested) do
    normalize_definition_argument(name, Map.from_struct(argument), requested)
  end

  defp normalize_definition_argument(name, %{} = argument, requested) do
    case Map.get(argument, :required) do
      nil -> Map.put(argument, :required, MapSet.member?(requested, name))
      _required -> argument
    end
  end

  defp normalize_definition_argument(_name, other, _requested), do: other

  defp decode(binary) when is_binary(binary) do
    cond do
      byte_size(binary) == 0 ->
        {:error, :empty_operation_file}

      match?(<<131, 80, _::binary>>, binary) ->
        {:error, :compressed_term}

      true ->
        try do
          term = :erlang.binary_to_term(binary, [:safe])

          if Protocol.term_allowed?(term) do
            {:ok, term}
          else
            {:error, :invalid_term}
          end
        rescue
          _error -> {:error, :invalid_term}
        end
    end
  end

  defp validate_operation(%{} = operation) do
    with {:ok, name} <- fetch_binary(operation, :name),
         :ok <- validate_name(name),
         {:ok, argv} <- fetch_argv(operation),
         {:ok, executable, argv} <- split_executable(operation, argv),
         :ok <- validate_executable(executable),
         {:ok, arguments} <- fetch_arguments(operation),
         :ok <- validate_placeholders(argv, arguments) do
      {:ok,
       %{
         name: name,
         executable: executable,
         argv: argv,
         arguments: arguments
       }}
    end
  end

  defp validate_operation(_operation), do: {:error, :invalid_operation}

  defp split_executable(operation, argv) do
    case Map.get(operation, :executable) do
      nil ->
        case argv do
          [executable | args] when executable != "" -> {:ok, executable, args}
          _other -> {:error, :invalid_executable}
        end

      executable when is_binary(executable) and executable != "" ->
        {:ok, executable, argv}

      _other ->
        {:error, {:invalid_operation_field, :executable}}
    end
  end

  defp fetch_binary(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _ -> {:error, {:invalid_operation_field, key}}
    end
  end

  defp validate_name(name) do
    cond do
      not Name.valid?(name) ->
        {:error, {:invalid_operation_name, name}}

      Patchbay.Worker.Artifacts.reserved?(name) ->
        {:error, {:reserved_operation_name, name}}

      Patchbay.Worker.Native.reserved?(name) ->
        {:error, {:reserved_operation_name, name}}

      true ->
        :ok
    end
  end

  defp validate_executable(executable) do
    cond do
      not is_binary(executable) or not String.valid?(executable) or
          String.trim(executable) == "" ->
        {:error, :invalid_executable}

      :binary.match(executable, <<0>>) != :nomatch ->
        {:error, :invalid_executable}

      Path.type(executable) == :absolute and not Exec.valid_executable?(executable) ->
        {:error, {:invalid_executable, executable}}

      true ->
        :ok
    end
  end

  defp fetch_argv(operation) do
    case Map.get(operation, :argv) do
      argv when is_list(argv) and length(argv) <= @max_argv_elements ->
        if Enum.all?(argv, &is_binary/1) do
          {:ok, argv}
        else
          {:error, :invalid_argv}
        end

      _ ->
        {:error, :invalid_argv}
    end
  end

  defp fetch_arguments(operation) do
    case Map.get(operation, :arguments, %{}) do
      arguments when is_map(arguments) ->
        arguments
        |> Map.to_list()
        |> map_ok(fn {name, spec} -> validate_argument_spec(name, spec) end)
        |> case do
          {:ok, pairs} -> {:ok, Map.new(pairs)}
          {:error, _reason} = error -> error
        end

      _ ->
        {:error, :invalid_arguments}
    end
  end

  defp validate_argument_spec(name, %{} = spec) do
    with true <-
           is_binary(name) and String.valid?(name) and Regex.match?(@argument_name_regex, name),
         {:ok, type} <- fetch_type(spec),
         {:ok, required} <- fetch_required(spec),
         {:ok, values} <- fetch_enum_values(type, spec) do
      {:ok, {name, %{type: type, required: required, values: values}}}
    else
      _ -> {:error, {:invalid_argument_spec, name}}
    end
  end

  defp validate_argument_spec(name, _spec), do: {:error, {:invalid_argument_spec, name}}

  defp fetch_type(spec) do
    case Map.get(spec, :type) do
      type when type in @types -> {:ok, type}
      _ -> {:error, :invalid_type}
    end
  end

  defp fetch_required(spec) do
    case Map.get(spec, :required, false) do
      nil -> {:ok, false}
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, :invalid_required}
    end
  end

  defp fetch_enum_values(:enum, spec) do
    case Map.get(spec, :values) do
      values when is_list(values) and values != [] ->
        if Enum.all?(values, &is_binary/1),
          do: {:ok, values},
          else: {:error, :invalid_enum}

      _ ->
        {:error, :invalid_enum}
    end
  end

  defp fetch_enum_values(_type, _spec), do: {:ok, nil}

  defp validate_placeholders(argv, arguments) do
    refs = Enum.map(argv, &Variables.references/1)

    unknown_args =
      refs
      |> Enum.flat_map(& &1.arguments)
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(arguments, &1))

    unknown_vars =
      refs
      |> Enum.flat_map(& &1.variables)
      |> Enum.uniq()
      |> Enum.reject(&Variables.known?/1)

    cond do
      unknown_vars != [] -> {:error, {:unknown_variables, unknown_vars}}
      unknown_args != [] -> {:error, {:undeclared_placeholders, unknown_args}}
      true -> :ok
    end
  end

  defp fetch(operations, name) when is_binary(name) do
    case Enum.find(operations, &(&1.name == name)) do
      nil -> {:error, {:unknown_operation, name}}
      operation -> {:ok, operation}
    end
  end

  defp fetch(_operations, name), do: {:error, {:invalid_operation_name, name}}

  defp validate_arguments(operation, arguments) when is_map(arguments) do
    with :ok <- validate_argument_keys(arguments, operation.arguments),
         {:ok, converted} <- convert_arguments(arguments, operation.arguments),
         :ok <- validate_required(converted, operation.arguments) do
      {:ok, converted}
    end
  end

  defp validate_arguments(_operation, _arguments), do: {:error, :invalid_arguments}

  defp validate_argument_keys(arguments, declared) do
    unknown = Map.keys(arguments) |> Enum.reject(&Map.has_key?(declared, &1))

    if unknown == [] do
      :ok
    else
      {:error, {:unknown_arguments, Enum.sort(unknown)}}
    end
  end

  defp convert_arguments(arguments, declared) do
    arguments
    |> Enum.reduce_while({:ok, %{}}, fn {name, value}, {:ok, acc} ->
      case convert_argument(name, value, Map.fetch!(declared, name)) do
        {:ok, converted} -> {:cont, {:ok, Map.put(acc, name, converted)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_required(converted, declared) do
    missing =
      declared
      |> Enum.filter(fn {_name, spec} -> Map.get(spec, :required, false) end)
      |> Enum.map(fn {name, _spec} -> name end)
      |> Enum.reject(&Map.has_key?(converted, &1))

    if missing == [] do
      :ok
    else
      {:error, {:missing_arguments, Enum.sort(missing)}}
    end
  end

  defp convert_argument(name, value, %{type: :string}) do
    if is_binary(value) and String.valid?(value) and byte_size(value) <= @max_arg_value_bytes and
         not contains_nul?(value) do
      {:ok, value}
    else
      {:error, {:invalid_argument, name}}
    end
  end

  defp convert_argument(name, value, %{type: :integer}) do
    if is_integer(value) and abs(value) <= 1_000_000_000_000_000_000 do
      {:ok, Integer.to_string(value)}
    else
      {:error, {:invalid_argument, name}}
    end
  end

  defp convert_argument(name, value, %{type: :number}) do
    if is_number(value) do
      {:ok, to_string(value)}
    else
      {:error, {:invalid_argument, name}}
    end
  end

  defp convert_argument(name, value, %{type: :boolean}) do
    case value do
      true -> {:ok, "true"}
      false -> {:ok, "false"}
      _ -> {:error, {:invalid_argument, name}}
    end
  end

  defp convert_argument(name, value, %{type: :enum, values: values}) do
    if is_binary(value) and String.valid?(value) and value in values do
      {:ok, value}
    else
      {:error, {:invalid_argument, name}}
    end
  end

  defp convert_argument(name, value, %{type: type} = _spec)
       when type in [:path, :file, :directory] do
    if is_binary(value) and String.valid?(value) and byte_size(value) <= @max_arg_value_bytes and
         not contains_nul?(value) do
      {:ok, {:path, value, type}}
    else
      {:error, {:invalid_argument, name}}
    end
  end

  defp contains_nul?(value), do: :binary.match(value, <<0>>) != :nomatch

  defp render_argv(operation, values, opts) do
    workspace = Keyword.get(opts, :workspace)

    with {:ok, workspace} <- resolve_workspace(operation, workspace),
         {:ok, replacements} <- resolve_path_values(values, workspace),
         {:ok, variables} <- variables(opts, workspace),
         {:ok, rendered} <- Variables.render_argv(operation.argv, variables, replacements) do
      total = Enum.reduce(rendered, 0, &(byte_size(&1) + &2))

      if total <= @max_rendered_argv_bytes do
        {:ok, rendered, workspace}
      else
        {:error, :argv_too_large}
      end
    end
  end

  defp variables(opts, workspace) do
    provided = Keyword.get(opts, :variables, %{})

    if is_map(provided) do
      variables =
        provided
        |> normalize_variables()
        |> Map.put("workspace", workspace)
        |> maybe_put_new_variable("agent_id", Keyword.get(opts, :agent_id))

      {:ok, variables}
    else
      {:error, :invalid_variables}
    end
  end

  defp normalize_variables(variables) do
    Map.new(variables, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp maybe_put_new_variable(variables, _name, nil), do: variables

  defp maybe_put_new_variable(variables, name, _value) when is_map_key(variables, name),
    do: variables

  defp maybe_put_new_variable(variables, name, value), do: Map.put(variables, name, value)

  defp resolve_workspace(operation, workspace) do
    uses_workspace =
      Enum.any?(operation.argv, fn element ->
        "workspace" in Variables.references(element).variables
      end)

    cond do
      uses_workspace and is_nil(workspace) ->
        {:error, :workspace_required}

      is_nil(workspace) ->
        {:ok, nil}

      is_binary(workspace) and String.valid?(workspace) and Path.type(workspace) == :absolute and
          not contains_nul?(workspace) ->
        canonical_allow_missing(Path.expand(workspace))

      true ->
        {:error, :invalid_workspace}
    end
  end

  defp resolve_path_values(values, workspace) do
    values
    |> Enum.reduce_while({:ok, %{}}, fn
      {name, {:path, path, kind}}, {:ok, acc} ->
        case resolve_path(path, workspace, kind) do
          {:ok, resolved} -> {:cont, {:ok, Map.put(acc, name, resolved)}}
          {:error, _reason} = error -> {:halt, error}
        end

      {name, value}, {:ok, acc} ->
        {:cont, {:ok, Map.put(acc, name, value)}}
    end)
  end

  defp resolve_path(_path, nil, _kind), do: {:error, :workspace_required}

  defp resolve_path(path, workspace, kind) do
    with {:ok, expanded} <- expand_path(path, workspace),
         {:ok, root} <- canonical_allow_missing(workspace),
         {:ok, resolved} <- canonical_allow_missing(expanded) do
      root = String.trim_trailing(root, "/")

      cond do
        resolved != root and not String.starts_with?(resolved, root <> "/") ->
          {:error, {:path_outside_workspace, path}}

        kind == :file and not match?({:ok, %File.Stat{type: :regular}}, File.stat(resolved)) ->
          {:error, {:file_not_found, path}}

        kind == :directory and
            not match?({:ok, %File.Stat{type: :directory}}, File.stat(resolved)) ->
          {:error, {:directory_not_found, path}}

        true ->
          {:ok, resolved}
      end
    end
  end

  defp expand_path("~" <> _rest = path, _workspace) do
    {:error, {:path_outside_workspace, path}}
  end

  defp expand_path(path, workspace) do
    {:ok, Path.expand(path, workspace)}
  rescue
    _error -> {:error, {:path_outside_workspace, path}}
  end

  # Resolves symlinks in every existing component and keeps the non-existent
  # tail lexical. Confinement checks then compare real paths, so a symlink
  # inside the workspace cannot redirect an argument outside it.
  defp canonical_allow_missing(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> resolve_components([], 0)
  end

  defp resolve_components([], acc, _depth), do: {:ok, Path.join(acc)}

  defp resolve_components(["/" | rest], [], depth),
    do: resolve_components(rest, ["/"], depth)

  defp resolve_components([part | rest], acc, depth) do
    candidate = Path.join(acc ++ [part])

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} when depth < @max_symlink_depth ->
        with {:ok, target} <- File.read_link(candidate) do
          base = Path.join(acc)
          components = Path.expand(target, base) |> Path.split()
          resolve_components(components ++ rest, [], depth + 1)
        else
          _error -> {:error, :invalid_path}
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :invalid_path}

      {:ok, _stat} ->
        resolve_components(rest, acc ++ [part], depth)

      {:error, :enoent} ->
        {:ok, Path.join(acc ++ [part | rest])}

      {:error, _reason} ->
        {:error, :invalid_path}
    end
  end

  defp map_ok(enumerable, fun) do
    enumerable
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end
end
