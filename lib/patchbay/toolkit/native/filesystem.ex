defmodule Patchbay.Toolkit.Native.Filesystem do
  @moduledoc """
  Built-in file tools confined to a configured directory root.

  A toolkit declaration supplies `config.root`. Relative roots are resolved
  against the agent's `config_root` and must stay strictly below it. Absolute
  roots are trusted operator configuration: they may point at an agent-owned
  workspace or project directory outside the config tree, but they must not
  overlap `/proc` or the manager's state, runtime, or secret paths.

  The tools run inside the agent worker through the reserved
  `patchbay-filesystem` operation, because the usual roots are agent-owned
  directories that the manager cannot traverse across the UID split. The
  runtime renders the configured root and rejects a protected one before
  dispatch, without resolving anything inside the agent-owned tree; the
  worker then resolves the real path and confines every model path below it.
  Symlink checks therefore always happen in the process that owns the tree,
  so a link the agent swaps between the manager's check and the read cannot
  redirect the manager into its own state, runtime, or secret paths.

  Every model-supplied path is relative, is checked component by component,
  and is confined below the effective root. Existing and missing paths are both
  resolved through existing symlinks, so a link that leaves the root is
  rejected before any read or write. Sibling names that merely share a prefix
  with the root are outside the root.

  Reads, writes, edits, and directory listings are bounded. Writes are atomic
  within the target directory.
  """

  @behaviour Patchbay.Toolkit.Native

  alias Patchbay.Provider.JSON
  alias Patchbay.Toolkit.Variables

  @id "filesystem"

  @worker_operation "patchbay-filesystem"

  @worker_result_keys %{
    "output" => :output,
    "path" => :path,
    "bytes" => :bytes,
    "entries" => :entries,
    "truncated" => :truncated
  }

  # Filesystem errors are small terms. The bound keeps a worker from turning
  # one refused call into a large decode in the manager.
  @max_error_bytes 65_536

  @read_file "read_file"
  @list_directory "list_directory"
  @write_file "write_file"
  @edit_file "edit_file"

  @defaults %{
    max_read_bytes: 262_144,
    max_write_bytes: 262_144,
    max_list_entries: 500
  }

  @hard_limits %{
    max_read_bytes: 4_194_304,
    max_write_bytes: 4_194_304,
    max_list_entries: 10_000
  }

  @max_path_bytes 4096

  @always_protected ["/proc"]

  @secret_path_variables ~w(
    PATCHBAY_CONTROL_TOKEN_FILE
    PATCHBAY_UI_TOKEN_FILE
    PATCHBAY_SECRET_KEY_BASE_FILE
    PATCHBAY_SIGNING_SALTS_FILE
  )

  @impl true
  def id, do: @id

  @doc """
  Validates a toolkit `config` at definition load time.

  `config.root` is required. A relative root must resolve strictly below the
  agent's config root; the relative form is the intended way to scope a
  toolkit to the config tree. A root that interpolates fixed variables is
  checked for template validity here and expanded at execution time, when the
  variables exist. Only a root that is absolute without interpolation can be
  checked for protected paths now; one that becomes absolute after rendering
  is checked at execution instead. The shell-style `${%name}` sequence is
  rejected because it stays literal instead of expanding. An absolute root is
  trusted configuration, but it is rejected when it overlaps `/proc` or a
  configured manager state, runtime, or secret path. Pass `:state_dir`,
  `:runtime_dir`, `:protected_roots`, or `:secret_roots` to check against
  explicit paths instead of the process environment.
  """
  @spec validate_config(term(), Path.t() | nil, keyword()) :: :ok | {:error, String.t()}
  def validate_config(config, config_root, opts \\ [])

  def validate_config(config, config_root, opts) when is_map(config) do
    case fetch(config, :root) do
      root when is_binary(root) ->
        cond do
          String.contains?(root, <<0>>) ->
            {:error, "must not contain NUL bytes"}

          String.trim(root) == "" ->
            {:error, "must be a non-empty path"}

          Variables.shell_style_variable?(root) ->
            {:error,
             "must not use the shell-style ${%...} sequence; it stays literal instead of expanding, so use the {%workspace} form directly"}

          true ->
            root_variables = Variables.references(root).variables

            case Enum.reject(root_variables, &Variables.known?/1) do
              [] ->
                if root_variables == [] do
                  validate_literal_root(root, config_root, opts)
                else
                  :ok
                end

              unknown ->
                {:error, "uses unsupported fixed variable {%" <> hd(unknown) <> "}"}
            end
        end

      nil ->
        {:error, "is required for the filesystem toolkit"}

      _other ->
        {:error, "must be a string path"}
    end
  end

  def validate_config(_config, _config_root, _opts),
    do: {:error, "must be a table with a root path"}

  defp validate_literal_root(root, config_root, opts) do
    if Path.type(root) == :absolute do
      validate_absolute_root(root, opts)
    else
      validate_relative_root(root, config_root)
    end
  end

  defp validate_absolute_root(root, opts) do
    if protected_root?(canonical_candidate(root), protected_roots(opts)) do
      {:error, "must not target /proc or manager-owned state, runtime, or secret paths"}
    else
      :ok
    end
  end

  defp validate_relative_root(root, config_root) when is_binary(config_root) do
    if Path.type(config_root) == :absolute do
      base = Path.expand(config_root)
      candidate = Path.expand(root, base)

      if candidate != base and lexical_below?(candidate, base) do
        :ok
      else
        {:error, "relative root must stay strictly below the config root"}
      end
    else
      {:error, "must be absolute or resolved from an absolute config_root"}
    end
  end

  defp validate_relative_root(_root, _config_root),
    do: {:error, "must be absolute when no config_root is available"}

  defp lexical_below?(path, base) do
    case base do
      "/" -> String.starts_with?(path, "/") and path != "/"
      _ -> String.starts_with?(path, base <> "/")
    end
  end

  @doc """
  Name of the reserved worker operation that runs these tools.

  Agent definitions cannot declare an operation with this name.
  """
  @impl true
  @spec worker_operation() :: String.t()
  def worker_operation, do: @worker_operation

  @doc """
  Builds the wire request that runs one tool inside the agent worker.

  `context` carries `:config` (this toolkit's configuration), `:variables`,
  `:config_root`, `:state_dir`, and `:runtime_dir`. The root is rendered here
  and checked against the protected paths lexically: the caller cannot
  resolve symlinks inside the agent-owned tree without risking `EACCES` or
  racing the agent. The worker repeats the check on the real path.
  """
  @impl true
  @spec worker_request(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def worker_request(tool, arguments, context) when is_binary(tool) and is_map(arguments) do
    with {:ok, config} <- toolkit_config(context),
         {:ok, config} <- worker_config(config, context),
         {:ok, encoded} <- encode_worker_request(worker_payload(tool, arguments, config, context)) do
      {:ok, %{"request" => encoded}}
    end
  end

  def worker_request(_tool, _arguments, _context), do: {:error, :invalid_arguments}

  @doc """
  Runs one reserved worker request and returns a worker result map.

  A tool failure is a normal result with `status: :ok` and a JSON envelope;
  the manager decodes it back into the `execute/3` error shape, so the
  structured reason survives the worker boundary.
  """
  @spec worker_execute(term()) :: {:ok, map()} | {:error, term()}
  def worker_execute(%{"request" => encoded}) when is_binary(encoded) do
    {:ok, worker_reply(decode_worker_request(encoded))}
  end

  def worker_execute(_arguments), do: {:ok, worker_reply({:error, :invalid_filesystem_request})}

  @doc """
  Decodes a manager-side worker result back into the `execute/3` shape.
  """
  @impl true
  @spec worker_result(term()) :: {:ok, map()} | {:error, term()}
  def worker_result({:ok, %{status: :ok, output: output}}) when is_binary(output) do
    case JSON.decode(output) do
      {:ok, %{"ok" => true, "result" => result}} when is_map(result) ->
        normalize_worker_result(result)

      {:ok, %{"ok" => false, "error" => error}} ->
        decode_worker_error(error)

      _other ->
        {:error, :invalid_filesystem_response}
    end
  end

  def worker_result({:ok, %{status: _status} = result}),
    do: {:error, {:filesystem_worker_failed, Map.get(result, :error)}}

  def worker_result({:error, reason}), do: {:error, reason}
  def worker_result(_other), do: {:error, :invalid_filesystem_response}

  @doc """
  Canonical paths that no filesystem root may overlap.

  The worker receives the same list so both sides reject a root that points
  at `/proc`, manager state, runtime, or a secret file.
  """
  @spec protected_paths(keyword()) :: [Path.t()]
  def protected_paths(opts \\ []), do: protected_roots(opts)

  @impl true
  def tools(_context) do
    [
      %{
        name: @read_file,
        description: "Read a UTF-8 text file below the configured root. Paths are relative.",
        schema: %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "File path relative to the configured root."
            }
          },
          "required" => ["path"],
          "additionalProperties" => false
        }
      },
      %{
        name: @list_directory,
        description: "List a directory below the configured root. The path defaults to the root.",
        schema: %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "Directory path relative to the configured root."
            }
          },
          "additionalProperties" => false
        }
      },
      %{
        name: @write_file,
        description:
          "Write a UTF-8 text file below the configured root, creating parent directories.",
        schema: %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "File path relative to the configured root."
            },
            "content" => %{"type" => "string", "description" => "File contents."}
          },
          "required" => ["path", "content"],
          "additionalProperties" => false
        }
      },
      %{
        name: @edit_file,
        description:
          "Replace text in a UTF-8 file below the configured root. Fails when the old text is absent.",
        schema: %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "File path relative to the configured root."
            },
            "old_string" => %{"type" => "string", "description" => "Text to replace."},
            "new_string" => %{"type" => "string", "description" => "Replacement text."},
            "replace_all" => %{
              "type" => "boolean",
              "description" => "Replace every occurrence. Defaults to false."
            }
          },
          "required" => ["path", "old_string", "new_string"],
          "additionalProperties" => false
        }
      }
    ]
  end

  @impl true
  def execute(name, arguments, context) when is_binary(name) and is_map(arguments) do
    with {:ok, root, limits} <- environment(context) do
      do_execute(name, arguments, root, limits)
    end
  end

  def execute(_name, _arguments, _context), do: {:error, :invalid_arguments}

  defp do_execute(@read_file, arguments, root, limits) do
    with {:ok, relative} <- model_path(arguments, "path", false),
         {:ok, path} <- resolve(root, relative, false),
         :ok <- regular_file(path, relative),
         {:ok, content} <- read_bounded(path, relative, limits.max_read_bytes) do
      {:ok,
       %{
         status: :ok,
         output: content,
         path: relative_to(path, root),
         bytes: byte_size(content)
       }}
    end
  end

  defp do_execute(@list_directory, arguments, root, limits) do
    with {:ok, relative} <- model_path(arguments, "path", true),
         {:ok, path} <- resolve(root, relative, true),
         :ok <- directory(path, relative),
         {:ok, output, count, truncated?} <- list_entries(path, limits.max_list_entries) do
      {:ok,
       %{
         status: :ok,
         output: output,
         path: relative_to(path, root),
         entries: count,
         truncated: truncated?
       }}
    end
  end

  defp do_execute(@write_file, arguments, root, limits) do
    with {:ok, relative} <- model_path(arguments, "path", false),
         {:ok, content} <- binary_argument(arguments, "content"),
         :ok <- bounded_size(byte_size(content), limits.max_write_bytes, relative),
         {:ok, path} <- resolve(root, relative, false),
         :ok <- writable_target(path, relative),
         {:ok, path} <- write_atomic(path, content) do
      {:ok,
       %{
         status: :ok,
         output: "wrote #{byte_size(content)} bytes to #{relative_to(path, root)}\n",
         path: relative_to(path, root),
         bytes: byte_size(content)
       }}
    end
  end

  defp do_execute(@edit_file, arguments, root, limits) do
    with {:ok, relative} <- model_path(arguments, "path", false),
         {:ok, old_string} <- binary_argument(arguments, "old_string"),
         {:ok, new_string} <- binary_argument(arguments, "new_string"),
         {:ok, replace_all?} <- boolean_argument(arguments, "replace_all", false),
         :ok <- non_empty_edit_text(old_string),
         {:ok, path} <- resolve(root, relative, false),
         :ok <- regular_file(path, relative),
         {:ok, content} <- read_bounded(path, relative, limits.max_read_bytes),
         :ok <- edit_text_present(content, old_string, relative),
         updated = replace_text(content, old_string, new_string, replace_all?),
         :ok <- bounded_size(byte_size(updated), limits.max_write_bytes, relative),
         {:ok, path} <- write_atomic(path, updated) do
      {:ok,
       %{
         status: :ok,
         output: "edited #{relative_to(path, root)}\n",
         path: relative_to(path, root),
         bytes: byte_size(updated)
       }}
    end
  end

  defp do_execute(name, _arguments, _root, _limits), do: {:error, {:unknown_tool, name}}

  defp environment(context) do
    with {:ok, config} <- toolkit_config(context),
         {:ok, root_value} <- required_root(config),
         {:ok, root_value} <- expand_root(root_value, context),
         {:ok, base} <- base_for_root(context, root_value),
         {:ok, root} <- canonical_root(base, root_value),
         :ok <- unprotected_root(root, protected_options(context)) do
      {:ok, root, limits(config)}
    end
  end

  # `config.root` may interpolate fixed variables, so the configured value is
  # rendered with the full variable map the runtime carries for this agent
  # before it is treated as an absolute or relative path.
  defp expand_root(root_value, context) do
    case Variables.render(root_value, variables(context), %{}) do
      {:ok, rendered} when is_binary(rendered) -> {:ok, rendered}
      {:ok, :omit} -> {:error, {:invalid_root, root_value}}
      {:error, {:unavailable_variable, name}} -> {:error, {:root_variable_unavailable, name}}
      {:error, _reason} -> {:error, {:invalid_root, root_value}}
    end
  end

  defp variables(context) do
    case fetch(context, :variables) do
      variables when is_map(variables) ->
        variables

      _other ->
        context
        |> fetch(:definition)
        |> case do
          definition when is_map(definition) -> Variables.context(definition)
          _other -> %{}
        end
    end
  end

  defp protected_options(context) do
    [
      state_dir: fetch(context, :state_dir),
      runtime_dir: fetch(context, :runtime_dir),
      protected_roots: fetch(context, :protected_roots),
      secret_roots: fetch(context, :secret_roots)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp protected_roots(opts) do
    config = Patchbay.Config.load()

    configured =
      opts
      |> Keyword.get(:protected_roots, [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)

    secret_roots =
      opts
      |> Keyword.get(:secret_roots, [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)

    state_dir = Keyword.get(opts, :state_dir) || config.state_dir
    runtime_dir = Keyword.get(opts, :runtime_dir) || config.runtime_dir

    (@always_protected ++
       [state_dir, runtime_dir] ++ configured ++ secret_roots ++ secret_paths())
    |> Enum.map(&canonical_candidate/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp secret_paths do
    Enum.flat_map(@secret_path_variables, fn variable ->
      case System.get_env(variable) do
        value when is_binary(value) and value != "" -> [value]
        _missing -> []
      end
    end)
  end

  defp unprotected_root(root, opts) do
    case Enum.find(protected_roots(opts), &overlaps?(root, &1)) do
      nil -> :ok
      protected -> {:error, {:root_protected, root, protected}}
    end
  end

  defp protected_root?(root, protected) do
    Enum.any?(protected, &overlaps?(root, &1))
  end

  defp overlaps?(path, protected), do: below?(path, protected) or below?(protected, path)

  defp canonical_candidate(path) when is_binary(path) and path != "" do
    expanded = Path.expand(path)

    case real_path(expanded) do
      {:ok, real} -> real
      {:error, _reason} -> expanded
    end
  end

  defp canonical_candidate(_path), do: nil

  defp base_for_root(context, root_value) do
    if is_binary(root_value) and Path.type(root_value) == :absolute do
      {:ok, nil}
    else
      config_root(context)
    end
  end

  defp toolkit_config(context) do
    case fetch(context, :config) do
      config when is_map(config) ->
        {:ok, config}

      _other ->
        case find_toolkit(context) do
          nil -> {:error, :filesystem_root_not_configured}
          toolkit -> {:ok, fetch(toolkit, :config) || %{}}
        end
    end
  end

  defp find_toolkit(context) do
    case fetch(context, :toolkit) do
      toolkit when is_map(toolkit) ->
        toolkit

      _other ->
        definition = fetch(context, :definition) || %{}

        definition
        |> fetch(:toolkits)
        |> List.wrap()
        |> Enum.find(fn toolkit -> fetch(toolkit, :native) == @id end)
    end
  end

  defp required_root(config) do
    case fetch(config, :root) do
      root when is_binary(root) and root != "" -> {:ok, root}
      _other -> {:error, :filesystem_root_not_configured}
    end
  end

  defp config_root(context) do
    definition = fetch(context, :definition) || %{}

    case fetch(context, :config_root) || fetch(definition, :config_root) do
      root when is_binary(root) and root != "" -> {:ok, root}
      _other -> {:error, :filesystem_config_root_not_configured}
    end
  end

  defp canonical_root(nil, root_value) do
    with {:ok, candidate} <- root_candidate(nil, root_value),
         {:ok, root} <- real_directory(candidate, :root) do
      {:ok, root}
    end
  end

  defp canonical_root(base, root_value) do
    with {:ok, base} <- real_directory(base, :config_root),
         {:ok, candidate} <- root_candidate(base, root_value),
         {:ok, root} <- real_directory(candidate, :root),
         :ok <- strict_below(root, base) do
      {:ok, root}
    end
  end

  defp root_candidate(base, root_value) do
    cond do
      String.contains?(root_value, <<0>>) ->
        {:error, {:invalid_root, root_value}}

      String.trim(root_value) == "" ->
        {:error, {:invalid_root, root_value}}

      Path.type(root_value) == :absolute ->
        {:ok, Path.expand(root_value)}

      true ->
        {:ok, Path.expand(root_value, base)}
    end
  end

  defp real_directory(path, label) do
    case real_path(path) do
      {:ok, real} ->
        case File.stat(real) do
          {:ok, %File.Stat{type: :directory}} -> {:ok, real}
          {:ok, _stat} -> {:error, {label, :not_a_directory, path}}
          {:error, reason} -> {:error, {label, reason, path}}
        end

      {:error, reason} ->
        {:error, {label, reason, path}}
    end
  end

  defp real_path(path), do: real_path(path, 0)

  defp real_path(_path, depth) when depth > 64, do: {:error, :eloop}

  defp real_path(path, depth) do
    parts = path |> Path.expand() |> Path.split()
    resolve_parts("/", parts, depth)
  end

  defp resolve_parts(current, [], _depth), do: {:ok, current}

  defp resolve_parts(_current, ["/" | rest], depth), do: resolve_parts("/", rest, depth)

  defp resolve_parts(current, [part | rest], depth) do
    next = Path.join(current, part)

    case File.lstat(next) do
      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- File.read_link(next),
             {:ok, resolved} <- real_path(Path.expand(target, current), depth + 1) do
          resolve_parts(resolved, rest, depth)
        end

      {:ok, _stat} ->
        resolve_parts(next, rest, depth)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp strict_below(root, base) do
    if root != base and below?(root, base) do
      :ok
    else
      {:error, {:root_not_strictly_below_config_root, root, base}}
    end
  end

  defp limits(config) do
    %{
      max_read_bytes:
        limit(config, :max_read_bytes, @defaults.max_read_bytes, @hard_limits.max_read_bytes),
      max_write_bytes:
        limit(
          config,
          :max_write_bytes,
          @defaults.max_write_bytes,
          @hard_limits.max_write_bytes
        ),
      max_list_entries:
        limit(
          config,
          :max_list_entries,
          @defaults.max_list_entries,
          @hard_limits.max_list_entries
        )
    }
  end

  defp limit(config, key, default, hard_limit) do
    case fetch(config, key) do
      value when is_integer(value) and value > 0 -> min(value, hard_limit)
      _other -> default
    end
  end

  defp model_path(arguments, key, allow_root) do
    case fetch(arguments, key) do
      nil when allow_root ->
        {:ok, "."}

      value when is_binary(value) ->
        normalize_model_path(value, allow_root)

      _other ->
        {:error, {:invalid_path, fetch(arguments, key)}}
    end
  end

  defp normalize_model_path(raw, allow_root) do
    segments = String.split(raw, "/", trim: true)
    normalized = Enum.reject(segments, &(&1 == "."))

    cond do
      byte_size(raw) > @max_path_bytes ->
        {:error, {:path_too_long, raw}}

      String.contains?(raw, <<0>>) ->
        {:error, {:invalid_path, raw}}

      Path.type(raw) == :absolute ->
        {:error, {:absolute_path_not_allowed, raw}}

      Enum.any?(segments, &(&1 == "..")) ->
        {:error, {:path_traversal_not_allowed, raw}}

      normalized == [] and not allow_root ->
        {:error, {:invalid_path, raw}}

      true ->
        {:ok, Enum.join(normalized, "/")}
    end
  end

  defp resolve(root, relative, allow_root) do
    segments =
      case relative do
        "." -> []
        relative -> String.split(relative, "/", trim: true)
      end

    with {:ok, path} <- walk(root, root, segments) do
      cond do
        path == root and not allow_root -> {:error, {:invalid_path, relative}}
        true -> {:ok, path}
      end
    end
  end

  defp walk(_root, current, []), do: {:ok, current}

  defp walk(root, current, [segment | rest]) do
    next = Path.join(current, segment)

    case File.lstat(next) do
      {:ok, %File.Stat{type: :symlink}} ->
        follow_symlink(root, next, rest)

      {:ok, %File.Stat{type: :directory}} ->
        walk(root, next, rest)

      {:ok, %File.Stat{}} ->
        if rest == [], do: {:ok, next}, else: {:error, {:not_a_directory, next}}

      {:error, :enoent} ->
        {:ok, Path.join([current | [segment | rest]])}

      {:error, reason} ->
        {:error, {:path_unreadable, next, reason}}
    end
  end

  defp follow_symlink(root, link, rest) do
    case real_path(link) do
      {:ok, target} ->
        if below?(target, root) do
          walk(root, target, rest)
        else
          {:error, {:path_escapes_root, link}}
        end

      {:error, :enoent} ->
        {:error, {:broken_symlink, link}}

      {:error, reason} ->
        {:error, {:path_unreadable, link, reason}}
    end
  end

  defp below?(path, base) do
    cond do
      path == base -> true
      base == "/" -> String.starts_with?(path, "/")
      true -> String.starts_with?(path, base <> "/")
    end
  end

  defp regular_file(path, relative) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: :directory}} -> {:error, {:is_directory, relative}}
      {:ok, _stat} -> {:error, {:not_a_regular_file, relative}}
      {:error, :enoent} -> {:error, {:not_found, relative}}
      {:error, reason} -> {:error, {:path_unreadable, relative, reason}}
    end
  end

  defp directory(path, relative) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _stat} -> {:error, {:not_a_directory, relative}}
      {:error, :enoent} -> {:error, {:not_found, relative}}
      {:error, reason} -> {:error, {:path_unreadable, relative, reason}}
    end
  end

  defp writable_target(path, relative) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> {:error, {:is_directory, relative}}
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:path_escapes_root, relative}}
      {:ok, _stat} -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:path_unreadable, relative, reason}}
    end
  end

  defp read_bounded(path, relative, max_bytes) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        try do
          case IO.binread(device, max_bytes + 1) do
            :eof ->
              {:ok, ""}

            data when is_binary(data) ->
              cond do
                byte_size(data) > max_bytes ->
                  {:error, {:file_too_large, relative, max_bytes}}

                String.valid?(data) ->
                  {:ok, data}

                true ->
                  {:error, {:not_a_text_file, relative}}
              end

            {:error, reason} ->
              {:error, {:read_failed, relative, reason}}
          end
        after
          File.close(device)
        end

      {:error, :enoent} ->
        {:error, {:not_found, relative}}

      {:error, reason} ->
        {:error, {:path_unreadable, relative, reason}}
    end
  end

  defp list_entries(path, max_entries) do
    case File.ls(path) do
      {:ok, entries} ->
        entries = Enum.sort(entries)
        shown = Enum.take(entries, max_entries)
        lines = Enum.map(shown, &entry_line(path, &1))
        output = if lines == [], do: "", else: Enum.join(lines, "\n") <> "\n"
        {:ok, output, length(shown), length(entries) > max_entries}

      {:error, reason} ->
        {:error, {:read_failed, path, reason}}
    end
  end

  defp entry_line(directory, name) do
    path = Path.join(directory, name)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        "d " <> name <> "/"

      {:ok, %File.Stat{type: :regular, size: size}} ->
        "f " <> name <> " (" <> to_string(size) <> " bytes)"

      {:ok, %File.Stat{type: :symlink}} ->
        "l " <> name

      {:ok, _stat} ->
        "? " <> name

      {:error, _reason} ->
        "? " <> name
    end
  end

  defp write_atomic(path, content) do
    directory = Path.dirname(path)

    temporary =
      Path.join(directory, ".patchbay-write-#{System.unique_integer([:positive, :monotonic])}")

    with :ok <- ensure_directory(directory),
         :ok <- write_temporary(temporary, content),
         :ok <- rename_temporary(temporary, path) do
      {:ok, path}
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, reason}
    end
  end

  defp ensure_directory(directory) do
    case File.mkdir_p(directory) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, directory, reason}}
    end
  end

  defp write_temporary(path, content) do
    case :file.open(path, [:write, :binary, :raw, :exclusive]) do
      {:ok, device} ->
        written = :file.write(device, content)
        closed = :file.close(device)

        case {written, closed} do
          {:ok, :ok} -> :ok
          {{:error, reason}, _closed} -> {:error, {:write_failed, path, reason}}
          {:ok, {:error, reason}} -> {:error, {:write_failed, path, reason}}
        end

      {:error, reason} ->
        {:error, {:write_failed, path, reason}}
    end
  end

  defp rename_temporary(temporary, path) do
    case File.rename(temporary, path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:rename_failed, path, reason}}
    end
  end

  defp bounded_size(size, max_bytes, relative) do
    if size <= max_bytes do
      :ok
    else
      {:error, {:content_too_large, relative, max_bytes}}
    end
  end

  defp non_empty_edit_text(""), do: {:error, :empty_old_string}
  defp non_empty_edit_text(_old_string), do: :ok

  defp edit_text_present(content, old_string, relative) do
    if String.contains?(content, old_string) do
      :ok
    else
      {:error, {:edit_text_not_found, relative}}
    end
  end

  defp replace_text(content, old_string, new_string, true),
    do: String.replace(content, old_string, new_string, global: true)

  defp replace_text(content, old_string, new_string, false),
    do: String.replace(content, old_string, new_string)

  defp binary_argument(arguments, key) do
    case fetch(arguments, key) do
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, {:invalid_argument, key}}
    end
  end

  defp boolean_argument(arguments, key, default) do
    case fetch(arguments, key) do
      nil -> {:ok, default}
      value when is_boolean(value) -> {:ok, value}
      _other -> {:error, {:invalid_argument, key}}
    end
  end

  defp worker_payload(tool, arguments, config, context) do
    protected = protected_options(context)

    %{
      "tool" => tool,
      "arguments" => arguments,
      "config" => config,
      "variables" => variables(context),
      "config_root" =>
        fetch(context, :config_root) || fetch(fetch(context, :definition) || %{}, :config_root),
      "protected" => %{
        "state_dir" => fetch(context, :state_dir),
        "runtime_dir" => fetch(context, :runtime_dir),
        "protected_roots" => protected_paths(protected),
        "secret_roots" => fetch(context, :secret_roots) || []
      }
    }
  end

  defp encode_worker_request(payload) do
    case JSON.encode(payload) do
      {:ok, encoded} when is_binary(encoded) -> {:ok, encoded}
      {:error, reason} -> {:error, {:invalid_filesystem_request, reason}}
    end
  end

  defp decode_worker_request(encoded) do
    with {:ok, %{} = request} <- JSON.decode(encoded),
         {:ok, tool} <- request_tool(request),
         {:ok, arguments} <- request_arguments(request),
         {:ok, context} <- request_context(request) do
      execute(tool, arguments, context)
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_filesystem_request}
    end
  end

  defp request_tool(request) do
    case Map.get(request, "tool") do
      tool when is_binary(tool) and tool != "" -> {:ok, tool}
      _other -> {:error, :invalid_filesystem_request}
    end
  end

  defp request_arguments(request) do
    case Map.get(request, "arguments", %{}) do
      arguments when is_map(arguments) -> {:ok, arguments}
      _other -> {:error, :invalid_arguments}
    end
  end

  defp request_context(request) do
    config = Map.get(request, "config")
    variables = Map.get(request, "variables", %{})
    protected = Map.get(request, "protected", %{})

    if is_map(config) and is_map(variables) and is_map(protected) do
      {:ok,
       %{
         config: config,
         variables: variables,
         config_root: Map.get(request, "config_root"),
         state_dir: Map.get(protected, "state_dir"),
         runtime_dir: Map.get(protected, "runtime_dir"),
         protected_roots: string_list(Map.get(protected, "protected_roots")),
         secret_roots: string_list(Map.get(protected, "secret_roots"))
       }}
    else
      {:error, :invalid_filesystem_request}
    end
  end

  defp string_list(values) when is_list(values), do: Enum.filter(values, &is_binary/1)
  defp string_list(_values), do: []

  @doc false
  @spec worker_reply({:ok, map()} | {:error, term()}) :: map()
  def worker_reply(reply), do: encode_worker_reply(reply)

  defp encode_worker_reply({:ok, %{} = result}) do
    %{status: :ok, output: json!(%{"ok" => true, "result" => result})}
  end

  defp encode_worker_reply({:error, reason}) do
    %{status: :ok, output: json!(%{"ok" => false, "error" => encode_worker_error(reason)})}
  end

  defp normalize_worker_result(result) do
    status =
      case Map.get(result, "status") do
        "error" -> :error
        _other -> :ok
      end

    normalized =
      result
      |> Map.take(Map.keys(@worker_result_keys))
      |> Map.new(fn {key, value} -> {Map.fetch!(@worker_result_keys, key), value} end)

    {:ok, normalized |> Map.put_new(:output, "") |> Map.put(:status, status)}
  end

  defp encode_worker_error(reason) do
    %{"term" => Base.encode64(:erlang.term_to_binary(reason, minor_version: 1))}
  end

  defp decode_worker_error(%{"term" => encoded}) when is_binary(encoded) do
    if byte_size(encoded) > @max_error_bytes do
      {:error, :filesystem_worker_error}
    else
      decode_error_term(encoded)
    end
  end

  defp decode_worker_error(_error), do: {:error, :filesystem_worker_error}

  defp decode_error_term(encoded) do
    with {:ok, binary} when byte_size(binary) <= @max_error_bytes <- Base.decode64(encoded),
         false <- match?(<<131, 80, _::binary>>, binary),
         {:ok, reason} <- safe_binary_to_term(binary) do
      {:error, reason}
    else
      _other -> {:error, :filesystem_worker_error}
    end
  end

  # The worker is less trusted than the manager. Safe decoding refuses funs,
  # pids, references, and atoms this VM has not created; every tag in a
  # filesystem error is a literal in this module, which is loaded here.
  defp safe_binary_to_term(binary) do
    try do
      {:ok, :erlang.binary_to_term(binary, [:safe])}
    rescue
      _error -> :error
    end
  end

  defp json!(payload) do
    case JSON.encode(payload) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> "{}"
    end
  end

  defp worker_config(config, context) do
    with {:ok, root_value} <- required_root(config),
         {:ok, rendered} <- expand_root(root_value, context),
         :ok <- validate_worker_root(rendered, context, protected_options(context)) do
      {:ok, put_root(config, rendered)}
    end
  end

  defp put_root(config, rendered) do
    if Map.has_key?(config, :root),
      do: Map.put(config, :root, rendered),
      else: Map.put(config, "root", rendered)
  end

  defp validate_worker_root(rendered, context, opts) do
    cond do
      String.contains?(rendered, <<0>>) ->
        {:error, {:invalid_root, rendered}}

      String.trim(rendered) == "" ->
        {:error, {:invalid_root, rendered}}

      Path.type(rendered) == :absolute ->
        candidate = Path.expand(rendered)

        case Enum.find(protected_roots(opts), &overlaps?(candidate, &1)) do
          nil -> :ok
          protected -> {:error, {:root_protected, candidate, protected}}
        end

      true ->
        validate_lexical_relative_root(rendered, context)
    end
  end

  defp validate_lexical_relative_root(rendered, context) do
    with {:ok, config_root} <- config_root(context) do
      base = Path.expand(config_root)
      candidate = Path.expand(rendered, base)

      if Path.type(config_root) == :absolute and candidate != base and
           lexical_below?(candidate, base) do
        :ok
      else
        {:error, {:root_not_strictly_below_config_root, candidate, base}}
      end
    end
  end

  defp relative_to(path, root) do
    case Path.relative_to(path, root) do
      "." -> "."
      relative -> relative
    end
  end

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Map.get(map, to_string(key))
    end
  end

  defp fetch(_map, _key), do: nil
end
