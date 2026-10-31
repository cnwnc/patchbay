defmodule Patchbay.Toolkit.Native.PersonalMemory do
  @moduledoc """
  Built-in persistent memory scoped to one agent.

  Memories are Markdown files stored below
  `<state_dir>/personal-memory/<agent-id>/<namespace>`. The namespace comes
  from the toolkit `config` and defaults to `default`; the agent id comes from
  the native execution context. Agents therefore never share a directory.

  Model-supplied topic paths are relative names. Every component is checked,
  traversal is rejected, and the lowest existing path component is inspected
  with `lstat/1` so a symlink cannot redirect a read, write, or move outside
  the namespace. Directories are created `0700` and memory files `0600`.

  Files written by `remember` and `append_memory` carry a one-line summary as
  their first line. `recall` tokenizes a query, ranks summary matches above
  body matches, and bounds both the result count and the rendered output.
  `delete_memory` moves a file into a per-agent trash directory rather than
  removing it.
  """

  @behaviour Patchbay.Toolkit.Native

  alias Patchbay.Transcript

  @id "personal-memory"

  @remember "remember"
  @append_memory "append_memory"
  @read_memory "read_memory"
  @list_memories "list_memories"
  @recall "recall"
  @delete_memory "delete_memory"

  @defaults %{
    max_read_bytes: 262_144,
    max_write_bytes: 262_144,
    max_entries: 500,
    max_scan_entries: 5_000,
    max_recall_results: 10,
    max_output_bytes: 8_192
  }

  @hard_limits %{
    max_read_bytes: 4_194_304,
    max_write_bytes: 4_194_304,
    max_entries: 10_000,
    max_scan_entries: 50_000,
    max_recall_results: 50,
    max_output_bytes: 65_536
  }

  @max_path_bytes 4096
  @max_component_bytes 255
  @max_summary_bytes 512
  @max_depth 32
  @max_scan_dirs 10_000
  @summary_read_bytes 4096

  @impl true
  def id, do: @id

  @doc """
  Validates a toolkit `config` at definition load time.

  The only constrained key is `namespace`, which must be one directory name
  below the per-agent memory root.
  """
  @spec validate_config(term(), Path.t() | nil, keyword()) :: :ok | {:error, String.t()}
  def validate_config(config, _config_root, _opts \\ [])

  def validate_config(config, _config_root, _opts) when is_map(config) do
    case fetch(config, :namespace) do
      nil ->
        :ok

      namespace when is_binary(namespace) ->
        case validate_namespace(namespace) do
          :ok -> :ok
          {:error, {:reserved_namespace, _value}} -> {:error, "must not be .trash"}
          {:error, _reason} -> {:error, "must be a single directory name"}
        end

      _other ->
        {:error, "must be a string directory name"}
    end
  end

  def validate_config(_config, _config_root, _opts),
    do: {:error, "must be a table"}

  @impl true
  def tools(_context) do
    [
      %{
        name: @remember,
        description:
          "Write or overwrite a Markdown memory below the agent's personal namespace. " <>
            "The summary is stored as the first line. A missing .md extension is added.",
        schema: %{
          "type" => "object",
          "properties" => %{
            "topic" => %{
              "type" => "string",
              "description" => "Relative memory path, for example projects/acme."
            },
            "summary" => %{
              "type" => "string",
              "description" => "Single-line summary stored as the first line."
            },
            "content" => %{
              "type" => "string",
              "description" => "Markdown body. May be empty."
            }
          },
          "required" => ["topic", "summary", "content"],
          "additionalProperties" => false
        }
      },
      %{
        name: @append_memory,
        description:
          "Append Markdown to an existing memory. When the memory does not exist, " <>
            "summary is required and becomes the first line.",
        schema: %{
          "type" => "object",
          "properties" => %{
            "topic" => %{
              "type" => "string",
              "description" => "Relative memory path, for example projects/acme."
            },
            "summary" => %{
              "type" => "string",
              "description" => "Single-line summary used only when creating the memory."
            },
            "content" => %{
              "type" => "string",
              "description" => "Markdown to append."
            }
          },
          "required" => ["topic", "content"],
          "additionalProperties" => false
        }
      },
      %{
        name: @read_memory,
        description: "Read one Markdown memory below the agent's personal namespace.",
        schema: %{
          "type" => "object",
          "properties" => %{
            "topic" => %{
              "type" => "string",
              "description" => "Relative memory path, for example projects/acme."
            }
          },
          "required" => ["topic"],
          "additionalProperties" => false
        }
      },
      %{
        name: @list_memories,
        description:
          "List memory paths and their first-line summaries in the configured namespace.",
        schema: %{
          "type" => "object",
          "properties" => %{},
          "additionalProperties" => false
        }
      },
      %{
        name: @recall,
        description:
          "Search memory summaries and bodies with simple token matching. " <>
            "Summary matches rank above body matches.",
        schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{
              "type" => "string",
              "description" => "Words to match against memory summaries and content."
            },
            "limit" => %{
              "type" => "integer",
              "description" => "Maximum results. Defaults to the configured recall limit."
            }
          },
          "required" => ["query"],
          "additionalProperties" => false
        }
      },
      %{
        name: @delete_memory,
        description: "Move one memory into the agent's trash. The file is not removed from disk.",
        schema: %{
          "type" => "object",
          "properties" => %{
            "topic" => %{
              "type" => "string",
              "description" => "Relative memory path, for example projects/acme."
            }
          },
          "required" => ["topic"],
          "additionalProperties" => false
        }
      }
    ]
  end

  @impl true
  def execute(name, arguments, context) when is_binary(name) and is_map(arguments) do
    with {:ok, storage} <- storage(context) do
      do_execute(name, arguments, storage)
    end
  end

  def execute(_name, _arguments, _context), do: {:error, :invalid_arguments}

  defp do_execute(@remember, arguments, storage) do
    with {:ok, relative} <- model_topic(arguments),
         {:ok, summary} <- summary_argument(arguments, :required),
         {:ok, content} <- binary_argument(arguments, "content"),
         document = document(summary, content),
         :ok <- bounded_size(byte_size(document), storage.limits.max_write_bytes, relative),
         {:ok, path} <- resolve_topic(storage, relative),
         :ok <- ensure_parent(storage.root, path),
         :ok <- Transcript.ensure_file(path),
         {:ok, _written} <- write_atomic(path, document) do
      {:ok,
       %{
         status: :ok,
         output: "remembered #{relative}\n",
         path: relative,
         summary: summary,
         bytes: byte_size(document)
       }}
    end
  end

  defp do_execute(@append_memory, arguments, storage) do
    with {:ok, relative} <- model_topic(arguments),
         {:ok, summary} <- summary_argument(arguments, :optional),
         {:ok, content} <- binary_argument(arguments, "content"),
         :ok <- non_empty(content, :content),
         {:ok, path} <- resolve_topic(storage, relative),
         :ok <- ensure_parent(storage.root, path),
         :ok <- Transcript.ensure_file(path),
         existing? = existing_memory?(path),
         :ok <- summary_for_new(existing?, summary),
         document = append_document(existing?, summary, content),
         :ok <- bounded_size(byte_size(document), storage.limits.max_write_bytes, relative),
         :ok <- Transcript.append(path, document, sync: true) do
      {:ok,
       %{
         status: :ok,
         output: "appended #{relative}\n",
         path: relative,
         summary: if(existing?, do: nil, else: summary),
         bytes: byte_size(document)
       }}
    end
  end

  defp do_execute(@read_memory, arguments, storage) do
    with {:ok, relative} <- model_topic(arguments),
         {:ok, path} <- resolve_topic(storage, relative),
         :ok <- regular_file(path, relative),
         {:ok, content} <- read_bounded(path, relative, storage.limits.max_read_bytes) do
      {:ok,
       %{
         status: :ok,
         output: content,
         path: relative,
         summary: summary_of(content),
         bytes: byte_size(content)
       }}
    end
  end

  defp do_execute(@list_memories, _arguments, storage) do
    max_entries = storage.limits.max_entries
    {paths, scan_limited?} = collect_files(storage.root, max_entries + 1)
    truncated? = scan_limited? or length(paths) > max_entries
    paths = Enum.take(paths, max_entries)

    lines =
      Enum.map(paths, fn path ->
        path <> "\t" <> memory_summary(storage.root, path, storage.limits)
      end)

    output = if lines == [], do: "", else: Enum.join(lines, "\n") <> "\n"

    {:ok,
     %{
       status: :ok,
       output: output,
       entries: length(lines),
       truncated: truncated?
     }}
  end

  defp do_execute(@recall, arguments, storage) do
    with {:ok, query} <- query_argument(arguments),
         {:ok, limit} <- recall_limit(arguments, storage.limits.max_recall_results),
         {:ok, tokens} <- query_tokens(query) do
      max_scan_entries = storage.limits.max_scan_entries
      {paths, scan_limited?} = collect_files(storage.root, max_scan_entries + 1)
      scan_truncated? = scan_limited? or length(paths) > max_scan_entries
      paths = Enum.take(paths, max_scan_entries)

      results =
        paths
        |> Enum.map(&score_memory(storage, &1, query, tokens))
        |> Enum.reject(&(&1.score == 0))
        |> Enum.sort_by(&{-&1.score, &1.path})
        |> Enum.take(limit)

      {output, output_truncated?} = render_results(results, storage.limits.max_output_bytes)

      {:ok,
       %{
         status: :ok,
         output: output,
         results:
           Enum.map(results, fn result ->
             Map.take(result, [:path, :summary, :score])
           end),
         count: length(results),
         truncated: scan_truncated? or output_truncated?
       }}
    end
  end

  defp do_execute(@delete_memory, arguments, storage) do
    with {:ok, relative} <- model_topic(arguments),
         {:ok, path} <- resolve_topic(storage, relative),
         :ok <- regular_file(path, relative),
         {:ok, trash} <- trash_target(storage, relative) do
      case File.rename(path, trash) do
        :ok ->
          Transcript.sync_dir(Path.dirname(path))

          {:ok,
           %{
             status: :ok,
             output: "deleted #{relative}\n",
             path: relative,
             trash: Path.relative_to(trash, storage.agent_root)
           }}

        {:error, reason} ->
          {:error, {:delete_failed, relative, reason}}
      end
    end
  end

  defp do_execute(name, _arguments, _storage), do: {:error, {:unknown_tool, name}}

  defp storage(context) do
    with {:ok, state_dir} <- state_dir(context),
         {:ok, agent_id} <- agent_id(context),
         :ok <- validate_component(agent_id, :agent_id),
         {:ok, config} <- toolkit_config(context),
         {:ok, namespace} <- namespace(config),
         {:ok, dirs} <- ensure_storage_dirs(state_dir, agent_id, namespace) do
      {:ok,
       Map.merge(dirs, %{
         agent: agent_id,
         namespace: namespace,
         limits: limits(config)
       })}
    end
  end

  defp state_dir(context) do
    case fetch(context, :state_dir) do
      value when is_binary(value) and value != "" ->
        if Path.type(value) == :absolute do
          {:ok, Path.expand(value)}
        else
          {:error, {:state_dir_not_absolute, value}}
        end

      _other ->
        {:error, :state_dir_not_configured}
    end
  end

  defp agent_id(context) do
    case fetch(context, :agent_id) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :personal_memory_agent_id_not_configured}
    end
  end

  defp toolkit_config(context) do
    case fetch(context, :config) do
      config when is_map(config) ->
        {:ok, config}

      _other ->
        case find_toolkit(context) do
          nil -> {:ok, %{}}
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

  defp namespace(config) do
    case fetch(config, :namespace) do
      nil ->
        {:ok, "default"}

      namespace when is_binary(namespace) ->
        with :ok <- validate_namespace(namespace), do: {:ok, namespace}

      other ->
        {:error, {:invalid_namespace, other}}
    end
  end

  defp validate_namespace(namespace) do
    with :ok <- validate_component(namespace, :namespace) do
      if namespace == ".trash",
        do: {:error, {:reserved_namespace, namespace}},
        else: :ok
    end
  end

  defp validate_component(value, label) when is_binary(value) do
    cond do
      value in ["", ".", ".."] ->
        {:error, {label, :invalid_component, value}}

      byte_size(value) > @max_component_bytes ->
        {:error, {label, :component_too_long, value}}

      not String.valid?(value) ->
        {:error, {label, :invalid_component, value}}

      String.contains?(value, ["/", "\\", <<0>>]) ->
        {:error, {label, :invalid_component, value}}

      Regex.match?(~r/[\x00-\x1f]/, value) ->
        {:error, {label, :invalid_component, value}}

      true ->
        :ok
    end
  end

  defp validate_component(value, label), do: {:error, {label, :invalid_component, value}}

  defp ensure_storage_dirs(state_dir, agent_id, namespace) do
    with {:ok, base} <- ensure_dir(Path.join(state_dir, "personal-memory")),
         {:ok, agent_root} <- ensure_dir(Path.join(base, agent_id)),
         {:ok, root} <- ensure_dir(Path.join(agent_root, namespace)) do
      {:ok, %{base: base, agent_root: agent_root, root: root}}
    end
  end

  defp ensure_dir(path) do
    case Transcript.ensure_dir(path) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:storage_dir_failed, path, reason}}
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
      max_entries: limit(config, :max_entries, @defaults.max_entries, @hard_limits.max_entries),
      max_scan_entries:
        limit(
          config,
          :max_scan_entries,
          @defaults.max_scan_entries,
          @hard_limits.max_scan_entries
        ),
      max_recall_results:
        limit(
          config,
          :max_recall_results,
          @defaults.max_recall_results,
          @hard_limits.max_recall_results
        ),
      max_output_bytes:
        limit(
          config,
          :max_output_bytes,
          @defaults.max_output_bytes,
          @hard_limits.max_output_bytes
        )
    }
  end

  defp limit(config, key, default, hard_limit) do
    case fetch(config, key) do
      value when is_integer(value) and value > 0 -> min(value, hard_limit)
      _other -> default
    end
  end

  defp model_topic(arguments) do
    case fetch(arguments, "topic") do
      value when is_binary(value) -> normalize_topic(value)
      _other -> {:error, {:invalid_topic, fetch(arguments, "topic")}}
    end
  end

  defp normalize_topic(raw) do
    segments = String.split(raw, "/", trim: true)

    cond do
      byte_size(raw) > @max_path_bytes ->
        {:error, {:path_too_long, raw}}

      String.contains?(raw, <<0>>) ->
        {:error, {:invalid_topic, raw}}

      Path.type(raw) == :absolute ->
        {:error, {:absolute_path_not_allowed, raw}}

      Enum.any?(segments, &(&1 in [".", ".."])) ->
        {:error, {:path_traversal_not_allowed, raw}}

      segments == [] ->
        {:error, {:invalid_topic, raw}}

      not Enum.all?(segments, &valid_topic_segment?/1) ->
        {:error, {:invalid_topic, raw}}

      true ->
        normalized = Enum.join(segments, "/")

        relative =
          if String.ends_with?(normalized, ".md"), do: normalized, else: normalized <> ".md"

        if Enum.all?(String.split(relative, "/"), &(byte_size(&1) <= @max_component_bytes)) do
          {:ok, relative}
        else
          {:error, {:component_too_long, raw}}
        end
    end
  end

  defp valid_topic_segment?(segment) do
    segment not in ["", ".", ".."] and
      byte_size(segment) <= @max_component_bytes and
      String.valid?(segment) and
      not String.contains?(segment, ["\\", <<0>>]) and
      not Regex.match?(~r/[\x00-\x1f]/, segment)
  end

  defp resolve_topic(storage, relative) do
    segments = String.split(relative, "/", trim: true)
    path = walk_topic(storage.root, segments)

    case path do
      {:ok, path} ->
        if below?(path, storage.root),
          do: {:ok, path},
          else: {:error, {:path_escapes_namespace, path}}

      {:error, _reason} = error ->
        error
    end
  end

  defp walk_topic(current, [segment | rest]) do
    next = Path.join(current, segment)

    case File.lstat(next) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:path_escapes_namespace, next}}

      {:ok, %File.Stat{type: :directory}} ->
        if rest == [],
          do: {:error, {:is_directory, next}},
          else: walk_topic(next, rest)

      {:ok, _stat} ->
        if rest == [], do: {:ok, next}, else: {:error, {:not_a_directory, next}}

      {:error, :enoent} ->
        {:ok, Path.join([current | [segment | rest]])}

      {:error, reason} ->
        {:error, {:path_unreadable, next, reason}}
    end
  end

  defp below?(path, base) do
    cond do
      path == base -> true
      base == "/" -> String.starts_with?(path, "/")
      true -> String.starts_with?(path, base <> "/")
    end
  end

  defp ensure_parent(base, path) do
    relative = Path.relative_to(Path.dirname(path), base)

    segments =
      case relative do
        "." -> []
        relative -> String.split(relative, "/", trim: true)
      end

    Enum.reduce_while(segments, {:ok, base}, fn segment, {:ok, current} ->
      next = Path.join(current, segment)

      case ensure_dir(next) do
        {:ok, _path} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _path} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp existing_memory?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> size > 0
      _other -> false
    end
  end

  defp summary_for_new(true, _summary), do: :ok
  defp summary_for_new(false, nil), do: {:error, :summary_required_for_new_memory}
  defp summary_for_new(false, _summary), do: :ok

  defp document(summary, content) do
    body = String.trim_trailing(content)
    header = "# " <> summary <> "\n"

    case body do
      "" -> header
      body -> header <> "\n" <> body <> "\n"
    end
  end

  defp append_document(true, _summary, content) do
    body = String.trim_trailing(content)

    case body do
      "" -> ""
      body -> "\n" <> body <> "\n"
    end
  end

  defp append_document(false, summary, content), do: document(summary, content)

  defp summary_argument(arguments, mode) do
    case fetch(arguments, "summary") do
      nil when mode == :optional ->
        {:ok, nil}

      nil ->
        {:error, {:invalid_argument, "summary"}}

      value when is_binary(value) ->
        value = String.trim(value)

        cond do
          value == "" ->
            {:error, {:invalid_argument, "summary"}}

          String.contains?(value, ["\n", "\r"]) ->
            {:error, {:invalid_argument, "summary"}}

          byte_size(value) > @max_summary_bytes ->
            {:error, {:summary_too_long, @max_summary_bytes}}

          true ->
            {:ok, value}
        end

      _other ->
        {:error, {:invalid_argument, "summary"}}
    end
  end

  defp query_argument(arguments) do
    case fetch(arguments, "query") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:invalid_argument, "query"}}
          query -> {:ok, query}
        end

      _other ->
        {:error, {:invalid_argument, "query"}}
    end
  end

  defp query_tokens(query) do
    tokens =
      query
      |> String.downcase()
      |> String.split(~r/[^A-Za-z0-9_]+/, trim: true)
      |> Enum.uniq()

    case tokens do
      [] -> {:error, {:invalid_argument, "query"}}
      tokens -> {:ok, tokens}
    end
  end

  defp recall_limit(arguments, default) do
    case fetch(arguments, "limit") do
      nil ->
        {:ok, default}

      value when is_integer(value) and value > 0 ->
        {:ok, min(value, @hard_limits.max_recall_results)}

      _other ->
        {:error, {:invalid_argument, "limit"}}
    end
  end

  defp score_memory(storage, path, query, tokens) do
    case read_prefix(Path.join(storage.root, path), storage.limits.max_read_bytes) do
      {:ok, content} ->
        summary = summary_of(content)
        lowered_summary = String.downcase(summary)
        lowered_content = String.downcase(content)
        lowered_query = String.downcase(query)

        score =
          Enum.reduce(tokens, 0, fn token, total ->
            cond do
              String.contains?(lowered_summary, token) -> total + 3
              String.contains?(lowered_content, token) -> total + 1
              true -> total
            end
          end)

        score =
          if String.contains?(lowered_content, lowered_query), do: score + 2, else: score

        %{path: path, summary: summary, score: score}

      {:error, _reason} ->
        %{path: path, summary: "", score: 0}
    end
  end

  defp render_results(results, max_bytes) do
    {lines, _size, truncated?} =
      Enum.reduce_while(results, {[], 0, false}, fn result, {lines, size, truncated?} ->
        line = result.path <> "\t" <> result.summary
        addition = byte_size(line) + 1

        cond do
          size + addition > max_bytes and lines == [] ->
            line = truncate_to_bytes(line, max(max_bytes - 1, 0))
            {:halt, {[line], byte_size(line) + 1, true}}

          size + addition > max_bytes ->
            {:halt, {lines, size, true}}

          true ->
            {:cont, {[line | lines], size + addition, truncated?}}
        end
      end)

    lines = Enum.reverse(lines)
    output = if lines == [], do: "", else: Enum.join(lines, "\n") <> "\n"
    {output, truncated?}
  end

  defp truncate_to_bytes(value, max_bytes) do
    if byte_size(value) <= max_bytes do
      value
    else
      value
      |> binary_part(0, max_bytes)
      |> drop_invalid_tail()
    end
  end

  defp drop_invalid_tail(""), do: ""

  defp drop_invalid_tail(value) do
    if String.valid?(value) do
      value
    else
      value
      |> binary_part(0, byte_size(value) - 1)
      |> drop_invalid_tail()
    end
  end

  defp memory_summary(root, relative, limits) do
    max_bytes = min(limits.max_read_bytes, @summary_read_bytes)

    case read_prefix(Path.join(root, relative), max_bytes) do
      {:ok, content} -> summary_of(content)
      {:error, _reason} -> ""
    end
  end

  defp summary_of(content) do
    content
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.trim()
    |> String.replace_prefix("# ", "")
    |> String.trim()
    |> collapse_whitespace()
    |> truncate_summary()
  end

  defp collapse_whitespace(value), do: String.replace(value, ~r/\s+/, " ")

  defp truncate_summary(value) do
    if String.length(value) > @max_summary_bytes,
      do: String.slice(value, 0, @max_summary_bytes) <> "...",
      else: value
  end

  defp collect_files(root, limit) do
    do_collect([{"", 0}], root, limit, [], 0)
  end

  defp do_collect(_queue, _root, limit, acc, _scanned) when length(acc) >= limit,
    do: {Enum.sort(acc), true}

  defp do_collect(_queue, _root, _limit, acc, scanned) when scanned >= @max_scan_dirs,
    do: {Enum.sort(acc), true}

  defp do_collect([], _root, _limit, acc, _scanned), do: {Enum.sort(acc), false}

  defp do_collect([{relative, depth} | rest], root, limit, acc, scanned) do
    directory = if relative == "", do: root, else: Path.join(root, relative)

    if depth > @max_depth do
      do_collect(rest, root, limit, acc, scanned)
    else
      case File.ls(directory) do
        {:ok, entries} ->
          {files, directories} =
            entries
            |> Enum.sort()
            |> Enum.reduce({[], []}, fn name, {files, directories} ->
              child = if relative == "", do: name, else: relative <> "/" <> name
              path = Path.join(directory, name)

              case File.lstat(path) do
                {:ok, %File.Stat{type: :regular}} -> {[child | files], directories}
                {:ok, %File.Stat{type: :directory}} -> {files, [{child, depth + 1} | directories]}
                _other -> {files, directories}
              end
            end)

          remaining = max(limit - length(acc), 0)
          files = files |> Enum.reverse() |> Enum.take(remaining)
          queue = rest ++ Enum.reverse(directories)
          do_collect(queue, root, limit, acc ++ files, scanned + 1)

        {:error, _reason} ->
          do_collect(rest, root, limit, acc, scanned + 1)
      end
    end
  end

  defp trash_target(storage, relative) do
    stamp = System.system_time(:microsecond)
    unique = System.unique_integer([:positive, :monotonic])

    trash_root = Path.join([storage.agent_root, ".trash", storage.namespace])
    stamp_dir = Path.join(trash_root, "#{stamp}-#{unique}")
    destination = Path.join(stamp_dir, relative)

    with {:ok, _trash} <- ensure_dir(Path.join(storage.agent_root, ".trash")),
         {:ok, _root} <- ensure_dir(trash_root),
         {:ok, _stamp} <- ensure_dir(stamp_dir),
         :ok <- ensure_parent(stamp_dir, destination) do
      {:ok, destination}
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

  defp read_prefix(path, max_bytes) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        try do
          case IO.binread(device, max_bytes) do
            :eof ->
              {:ok, ""}

            data when is_binary(data) ->
              if String.valid?(data), do: {:ok, data}, else: {:ok, ""}

            _other ->
              {:ok, ""}
          end
        after
          File.close(device)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_atomic(path, content) do
    directory = Path.dirname(path)

    temporary =
      Path.join(directory, ".patchbay-memory-#{System.unique_integer([:positive, :monotonic])}")

    with :ok <- write_temporary(temporary, content),
         :ok <- chmod(temporary),
         :ok <- rename_temporary(temporary, path) do
      Transcript.sync_dir(directory)
      {:ok, path}
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, reason}
    end
  end

  defp write_temporary(path, content) do
    case :file.open(path, [:write, :binary, :raw, :exclusive]) do
      {:ok, device} ->
        written = :file.write(device, content)
        synced = :file.sync(device)
        closed = :file.close(device)

        case {written, synced, closed} do
          {:ok, :ok, :ok} -> :ok
          {{:error, reason}, _synced, _closed} -> {:error, {:write_failed, path, reason}}
          {:ok, {:error, reason}, _closed} -> {:error, {:write_failed, path, reason}}
          {:ok, :ok, {:error, reason}} -> {:error, {:write_failed, path, reason}}
        end

      {:error, reason} ->
        {:error, {:write_failed, path, reason}}
    end
  end

  defp chmod(path) do
    case File.chmod(path, 0o600) do
      :ok -> :ok
      {:error, reason} -> {:error, {:chmod_failed, path, reason}}
    end
  end

  defp rename_temporary(temporary, path) do
    case File.rename(temporary, path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:rename_failed, path, reason}}
    end
  end

  defp binary_argument(arguments, key) do
    case fetch(arguments, key) do
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, {:invalid_argument, key}}
    end
  end

  defp non_empty(value, key) do
    if String.trim(value) == "", do: {:error, {:invalid_argument, key}}, else: :ok
  end

  defp bounded_size(size, max_bytes, relative) do
    if size <= max_bytes do
      :ok
    else
      {:error, {:content_too_large, relative, max_bytes}}
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
