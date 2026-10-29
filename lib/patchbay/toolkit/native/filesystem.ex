defmodule Patchbay.Toolkit.Native.Filesystem do
  @moduledoc """
  Built-in file tools confined to a configured directory root.

  A toolkit declaration supplies `config.root`. Relative roots are resolved
  against the agent's `config_root`; absolute roots are accepted only when they
  land strictly below that config root. The root must exist and be a directory.

  Every model-supplied path is relative, is checked component by component, and
  is confined below the root. Existing and missing paths are both resolved
  through existing symlinks, so a link that leaves the root is rejected before
  any read or write. Sibling names that merely share a prefix with the root are
  outside the root.

  Reads, writes, edits, and directory listings are bounded. Writes are atomic
  within the target directory.
  """

  @behaviour Patchbay.Toolkit.Native

  @id "filesystem"

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

  @impl true
  def id, do: @id

  @doc """
  Validates a toolkit `config` at definition load time.

  `config.root` is required. A relative root must resolve strictly below the
  agent's config root. An absolute root is trusted configuration: it may point
  at an agent-owned workspace outside the config tree, and execute/4 still
  canonicalizes it and confines every model-supplied path below it.
  """
  @spec validate_config(term(), Path.t() | nil) :: :ok | {:error, String.t()}
  def validate_config(config, config_root) when is_map(config) do
    case fetch(config, :root) do
      root when is_binary(root) ->
        cond do
          String.contains?(root, <<0>>) ->
            {:error, "must not contain NUL bytes"}

          String.trim(root) == "" ->
            {:error, "must be a non-empty path"}

          Path.type(root) == :absolute ->
            :ok

          true ->
            validate_relative_root(root, config_root)
        end

      nil ->
        {:error, "is required for the filesystem toolkit"}

      _other ->
        {:error, "must be a string path"}
    end
  end

  def validate_config(_config, _config_root),
    do: {:error, "must be a table with a root path"}

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
         {:ok, base} <- base_for_root(context, root_value),
         {:ok, root} <- canonical_root(base, root_value) do
      {:ok, root, limits(config)}
    end
  end

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
