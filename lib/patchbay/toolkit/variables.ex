defmodule Patchbay.Toolkit.Variables do
  @moduledoc """
  Fixed built-in variables available to operation argv templates.

  Templates use `{%name}` for a fixed variable and `{name}` for a model-facing
  operation argument. Fixed variables come from the registry below; model
  arguments must be declared by the operation.

  Substitution is single pass: substituted values are never scanned again.
  `{{` and `}}` are escapes for literal braces, and any other brace sequence
  that does not form a token is copied unchanged. A `$` directly in front of
  a `{%name}` token does not substitute: `${...}` is shell-style syntax and
  the sequence stays literal.
  """

  @variables ~w(
    workspace
    result_dir
    agent_id
    run_id
    attempt_id
    agent_state
    run_state
    agent_scripts
    shared_scripts
  )

  @variable_set MapSet.new(@variables)

  @token ~r/\{%([A-Za-z_][A-Za-z0-9_]*)\}|\{([A-Za-z_][A-Za-z0-9_-]*)\}|\{\{|\}\}/

  @shell_style ~r/\$\{%([A-Za-z_][A-Za-z0-9_]*)\}/

  @type name :: String.t()
  @type variables :: map()
  @type arguments :: map()

  @type issue ::
          {:unknown_variable, String.t()}
          | {:undeclared_argument, String.t()}
          | {:model_argument_not_allowed, String.t()}
          | {:unsupported_shell_variable, String.t()}

  @type render_error ::
          {:unknown_variable, String.t()}
          | {:unavailable_variable, String.t()}
          | :invalid_value

  @doc "Returns the fixed variable names accepted in `{%name}` tokens."
  @spec names() :: [String.t()]
  def names, do: @variables

  @doc "Returns true when `name` is a registered fixed variable."
  @spec known?(term()) :: boolean()
  def known?(name) when is_binary(name), do: MapSet.member?(@variable_set, name)
  def known?(_name), do: false

  @doc """
  Lists fixed variables and model argument names referenced by `template`.

  Escaped braces are ignored. Tokens with an invalid shape stay literal, and
  a `$` directly in front of a `{%name}` token is not a variable reference.
  """
  @spec references(String.t()) :: %{
          variables: [String.t()],
          arguments: [String.t()]
        }
  def references(template) when is_binary(template) do
    do_references(template, %{variables: [], arguments: []})
  end

  @doc """
  Validates the tokens in one argv element.

  Fixed variables must be registered. Model arguments must be declared unless
  `:mode` is `:hook`, where model arguments are rejected outright. The
  shell-style `${%name}` sequence is rejected: it stays literal rather than
  expanding, and silent non-substitution would surprise operators.
  """
  @spec validate(String.t(), map(), keyword()) :: :ok | {:error, [issue()]}
  def validate(template, declared_arguments \\ %{}, opts \\ []) when is_binary(template) do
    mode = Keyword.get(opts, :mode, :operation)
    refs = references(template)

    issues =
      shell_variable_issues(template) ++
        unknown_variables(refs.variables) ++
        argument_issues(refs.arguments, declared_arguments, mode)

    case issues do
      [] -> :ok
      issues -> {:error, issues}
    end
  end

  @doc """
  Returns true when `template` holds `${%name}`, the shell-style sequence.

  `render/3` keeps such a sequence literal, so templates passing `validate/3`
  never contain one.
  """
  @spec shell_style_variable?(String.t()) :: boolean()
  def shell_style_variable?(template) when is_binary(template) do
    Regex.match?(@shell_style, template)
  end

  @doc """
  Names of every fixed variable referenced by any element of `argv`.
  """
  @spec referenced_variables([String.t()]) :: [String.t()]
  def referenced_variables(argv) when is_list(argv) do
    argv
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&references(&1).variables)
    |> Enum.uniq()
  end

  defp shell_variable_issues(template) do
    case Regex.run(@shell_style, template) do
      [match | _captures] -> [{:unsupported_shell_variable, match}]
      nil -> []
    end
  end

  @doc "Validates every element of an argv list and returns issues with element indexes."
  @spec validate_argv([String.t()], map(), keyword()) :: [{[non_neg_integer()], [issue()]}]
  def validate_argv(argv, declared_arguments \\ %{}, opts \\ []) when is_list(argv) do
    argv
    |> Enum.with_index()
    |> Enum.flat_map(fn {template, index} ->
      case validate(template, declared_arguments, opts) do
        :ok -> []
        {:error, issues} -> [{index, issues}]
      end
    end)
  end

  @doc """
  Renders one template element.

  Returns `{:ok, :omit}` when the element consists only of unsupplied model
  arguments, which lets optional argv elements disappear.
  """
  @spec render(String.t(), variables(), arguments()) ::
          {:ok, String.t() | :omit} | {:error, term()}
  def render(template, variables, arguments \\ %{}) when is_binary(template) do
    with {:ok, rendered, omitted?} <- do_render(template, variables, arguments, "", false) do
      if rendered == "" and omitted?, do: {:ok, :omit}, else: {:ok, rendered}
    end
  end

  @doc "Renders an argv list, dropping elements whose optional arguments were not supplied."
  @spec render_argv([String.t()], variables(), arguments()) ::
          {:ok, [String.t()]} | {:error, term()}
  def render_argv(argv, variables, arguments \\ %{}) when is_list(argv) do
    argv
    |> Enum.reduce_while({:ok, []}, fn template, {:ok, acc} ->
      case render(template, variables, arguments) do
        {:ok, :omit} -> {:cont, {:ok, acc}}
        {:ok, rendered} -> {:cont, {:ok, [rendered | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rendered} -> {:ok, Enum.reverse(rendered)}
      error -> error
    end
  end

  @doc """
  Builds the fixed variable context for an agent definition.

  Values that the caller does not supply stay `nil` and render as
  `{:error, {:unavailable_variable, name}}`.
  """
  @spec context(map(), keyword()) :: map()
  def context(definition \\ %{}, opts \\ []) do
    %{
      "workspace" => Keyword.get(opts, :workspace),
      "result_dir" => Keyword.get(opts, :result_dir),
      "agent_id" => Keyword.get(opts, :agent_id) || Map.get(definition, :id),
      "run_id" => Keyword.get(opts, :run_id),
      "attempt_id" => Keyword.get(opts, :attempt_id),
      "agent_state" => atom_value(Keyword.get(opts, :agent_state)),
      "run_state" => atom_value(Keyword.get(opts, :run_state)),
      "agent_scripts" => script_dir(Map.get(definition, :agent_dir)),
      "shared_scripts" => script_dir(Map.get(definition, :config_root))
    }
  end

  defp do_references(template, acc) do
    case Regex.run(@token, template, return: :index) do
      nil ->
        %{variables: Enum.reverse(acc.variables), arguments: Enum.reverse(acc.arguments)}

      [{start, length} | _captures] ->
        token = binary_part(template, start, length)

        acc =
          if dollar_prefixed?(template, start, token),
            do: acc,
            else: record_token(token, acc)

        do_references(remainder(template, start, length), acc)
    end
  end

  defp remainder(template, start, length),
    do: binary_part(template, start + length, byte_size(template) - start - length)

  defp record_token("{{", acc), do: acc
  defp record_token("}}", acc), do: acc

  defp record_token("{%" <> _rest = token, acc) do
    name = inner_token(token, 2)
    %{acc | variables: prepend_unique(acc.variables, name)}
  end

  defp record_token(token, acc) do
    name = inner_token(token, 1)
    %{acc | arguments: prepend_unique(acc.arguments, name)}
  end

  defp dollar_prefixed?(template, start, "{%" <> _rest) when start > 0 do
    binary_part(template, start - 1, 1) == "$"
  end

  defp dollar_prefixed?(_template, _start, _token), do: false

  defp inner_token(token, offset) when byte_size(token) >= offset + 2 do
    binary_part(token, offset, byte_size(token) - offset - 1)
  end

  defp prepend_unique(values, value) do
    if value in values, do: values, else: [value | values]
  end

  defp unknown_variables(names) do
    names
    |> Enum.uniq()
    |> Enum.reject(&known?/1)
    |> Enum.map(&{:unknown_variable, &1})
  end

  defp argument_issues(names, _declared_arguments, :hook) do
    Enum.map(names, &{:model_argument_not_allowed, &1})
  end

  defp argument_issues(names, declared_arguments, _mode) do
    declared = MapSet.new(Map.keys(declared_arguments))
    Enum.reject(names, &MapSet.member?(declared, &1)) |> Enum.map(&{:undeclared_argument, &1})
  end

  defp do_render("", _variables, _arguments, acc, omitted?) do
    {:ok, acc, omitted?}
  end

  defp do_render(template, variables, arguments, acc, omitted?) do
    case Regex.run(@token, template, return: :index) do
      nil ->
        {:ok, acc <> template, omitted?}

      [{start, length} | _captures] ->
        token = binary_part(template, start, length)
        prefix = binary_part(template, 0, start)
        rest = remainder(template, start, length)

        if dollar_prefixed?(template, start, token) do
          # A `$` directly in front of `{%name}` stays literal: `${...}` is
          # shell-style syntax this template language does not define.
          do_render(rest, variables, arguments, acc <> prefix <> token, omitted?)
        else
          render_token(token, prefix, rest, variables, arguments, acc, omitted?)
        end
    end
  end

  defp render_token(token, prefix, rest, variables, arguments, acc, omitted?) do
    case render_token(token, variables, arguments) do
      {:ok, :literal, value} ->
        do_render(rest, variables, arguments, acc <> prefix <> value, omitted?)

      {:ok, :value, value} ->
        do_render(rest, variables, arguments, acc <> prefix <> value, omitted?)

      {:ok, :omitted} ->
        do_render(rest, variables, arguments, acc <> prefix, true)

      {:error, _reason} = error ->
        error
    end
  end

  defp render_token("{{", _variables, _arguments), do: {:ok, :literal, "{"}
  defp render_token("}}", _variables, _arguments), do: {:ok, :literal, "}"}

  defp render_token("{%" <> _rest = token, variables, _arguments) do
    name = inner_token(token, 2)

    if known?(name) do
      case fetch_string(variables, name) do
        {:ok, value} -> value_token(value)
        :error -> {:error, {:unavailable_variable, name}}
      end
    else
      {:error, {:unknown_variable, name}}
    end
  end

  defp render_token("{" <> _rest = token, _variables, arguments) do
    name = inner_token(token, 1)

    case fetch_value(arguments, name) do
      {:ok, value} -> value_token(value)
      :missing -> {:ok, :omitted}
    end
  end

  defp value_token(value) do
    if :binary.match(value, <<0>>) == :nomatch do
      {:ok, :value, value}
    else
      {:error, :invalid_value}
    end
  end

  defp fetch_string(map, name) when is_map(map) do
    case fetch_value(map, name) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, value} -> {:ok, to_string(value)}
      :missing -> :error
    end
  end

  defp fetch_value(map, name) do
    case Map.fetch(map, name) do
      {:ok, value} when not is_nil(value) ->
        {:ok, to_string(value)}

      _ ->
        atom = existing_atom(name)

        case atom && Map.fetch(map, atom) do
          {:ok, value} when not is_nil(value) -> {:ok, to_string(value)}
          _ -> :missing
        end
    end
  end

  defp existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp script_dir(nil), do: nil
  defp script_dir(root), do: Path.join(root, "scripts")

  defp atom_value(nil), do: nil
  defp atom_value(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_value(value) when is_binary(value), do: value
  defp atom_value(_value), do: nil
end
