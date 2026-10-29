defmodule Patchbay.ContextCompaction do
  @moduledoc """
  Provider-driven compaction of a conversation context.

  When the estimated context size crosses the definition's `[context]`
  threshold, the engine summarizes the older messages with the configured
  provider, keeps a complete recent suffix, archives the full current context
  under `<state_dir>/context/<agent>/archive`, and atomically replaces the
  current context with the summary plus the suffix. System prompts are kept
  ahead of the summary so the provider still sees the agent's instructions.

  Provider summarization and compression happen in `prepare/4`, which never
  writes the current context. `commit/4` performs the atomic replacement, so
  a process that owns the message list can decide whether a prepared
  generation is still current.

  The current context is never modified unless summarization and the archive
  generation both succeed. Callers integrate it after a model response:

      case Patchbay.ContextCompaction.maybe_compact(state_dir, agent_id, messages,
             definition: definition,
             run_id: run_id,
             attempt_id: attempt_id,
             provider_opts: provider_opts
           ) do
        {:ok, result} -> result.messages
        :unchanged -> messages
        {:error, _reason} -> messages
      end

  `result.archive` describes the compressed generation and its metadata
  sidecar. `result.summary` is the message that replaced `result.dropped`.
  """

  alias Patchbay.ContextCompaction.{Policy, Split, Tokens, Zstd}
  alias Patchbay.ContextStore
  alias Patchbay.Provider
  alias Patchbay.Provider.{Error, JSON, Message, Request, Response, ToolCall}
  alias Patchbay.Transcript

  @summary_name "context-summary"
  @default_max_summary_tokens 1024

  @system_prompt """
  You compact conversation context for another agent. Write a factual summary
  of the conversation transcript you receive. Preserve decisions, constraints,
  file paths, commands, tool call ids, tool outcomes, unresolved problems, and
  the current task state. Do not invent facts. Do not call tools. Return only
  the summary text.
  """

  @user_prompt """
  Summarize the transcript above so the agent can continue without it.
  """

  @type result :: %{
          summary: Message.t(),
          messages: [Message.t()],
          retained: [Message.t()],
          dropped: [Message.t()],
          archive: map(),
          policy: Policy.t()
        }

  @type plan :: %{
          summary: Message.t(),
          messages: [Message.t()],
          retained: [Message.t()],
          dropped: [Message.t()],
          archive: map(),
          policy: Policy.t(),
          entries: [ContextStore.entry()]
        }

  @doc "Resolves the compaction policy from a definition, context struct, or map."
  @spec policy(term(), keyword()) :: Policy.t()
  def policy(source, opts \\ []), do: Policy.from(source, opts)

  @doc "Returns true when the context estimate exceeds the configured threshold."
  @spec due?([Message.t()], term(), keyword()) :: boolean()
  def due?(messages, source, opts \\ []) when is_list(messages) do
    policy = policy_for(source, opts)

    Policy.enabled?(policy) and Tokens.estimate(messages) > policy.threshold
  end

  @doc """
  Compacts when the policy is enabled and the estimate crosses its threshold.

  Returns `:unchanged` when compaction is not configured or not due.
  """
  @spec maybe_compact(Path.t(), binary(), [Message.t()], keyword()) ::
          {:ok, result()} | :unchanged | {:error, term()}
  def maybe_compact(state_dir, agent_id, messages, opts \\ []) when is_list(messages) do
    source = Keyword.get(opts, :definition) || Keyword.get(opts, :context)
    policy = policy_for(source, opts)

    cond do
      not Policy.enabled?(policy) -> :unchanged
      Tokens.estimate(messages) <= policy.threshold -> :unchanged
      true -> compact(state_dir, agent_id, messages, Keyword.put(opts, :policy, policy))
    end
  end

  @doc """
  Runs one compaction regardless of the trigger threshold and commits it.

  A target from the policy, or the `:target` option, bounds the retained
  suffix. Without either, half of the current estimate is targeted.

  `prepare/4` does the provider and compression work; this convenience wraps
  it with `commit/4` for callers that do not need to keep those phases apart.
  """
  @spec compact(Path.t(), binary(), [Message.t()], keyword()) ::
          {:ok, result()} | :unchanged | {:error, term()}
  def compact(state_dir, agent_id, messages, opts \\ []) when is_list(messages) do
    with {:ok, plan} <- prepare(state_dir, agent_id, messages, opts),
         :ok <- commit(state_dir, agent_id, plan, opts) do
      {:ok, plan}
    end
  end

  @doc """
  Builds a compaction plan without replacing the current context.

  This phase calls the provider and compresses the archive generation. It is
  safe to run outside the process that owns the context, because it never
  writes the current context file. The caller commits the plan while it still
  owns the message list, and discards it when the context moved on.
  """
  @spec prepare(Path.t(), binary(), [Message.t()], keyword()) ::
          {:ok, plan()} | :unchanged | {:error, term()}
  def prepare(state_dir, agent_id, messages, opts \\ []) when is_list(messages) do
    source = Keyword.get(opts, :definition) || Keyword.get(opts, :context)
    policy = policy_for(source, opts)
    {systems, conversation} = split_system(messages)
    conversation = ContextStore.sanitize(conversation)
    target = target(policy, conversation, opts)
    split = Split.split(conversation, target)

    with :ok <- ensure_progress(split),
         {:ok, entries} <- read_entries(state_dir, agent_id),
         {:ok, summary_text} <- summarize(split.dropped, source, opts) do
      run = last_run(entries)
      message_meta = last_message_meta(entries)
      run_id = run_id(opts, message_meta, run)
      attempt_id = attempt_id(opts, message_meta)
      at = Keyword.get_lazy(opts, :at, fn -> now_iso() end)
      summary = Message.user(summary_text, name: @summary_name)
      conversation_messages = [summary | split.retained]
      new_messages = systems ++ conversation_messages

      new_entries =
        run_entries(run, run_id, at) ++
          ContextStore.message_entries(conversation_messages,
            run_id: run_id,
            attempt_id: attempt_id,
            at: at
          )

      archived = archived_messages(entries, conversation)

      base_metadata = %{
        agent_id: agent_id,
        created_at: at,
        run_id: run_id,
        attempt_id: attempt_id,
        model: request_model(source, opts),
        threshold: policy.threshold,
        target: target,
        messages: length(archived),
        tokens: Tokens.estimate(archived),
        dropped_messages: length(split.dropped),
        retained_messages: length(split.retained),
        summary_tokens: Tokens.estimate_text(summary_text)
      }

      with {:ok, snapshot} <- snapshot(state_dir, agent_id, conversation, run_id, attempt_id, at),
           {:ok, archive} <- write_archive(state_dir, agent_id, snapshot, base_metadata, opts) do
        {:ok,
         %{
           summary: summary,
           messages: new_messages,
           retained: split.retained,
           dropped: split.dropped,
           archive: archive,
           policy: policy,
           entries: new_entries
         }}
      end
    end
  end

  @doc """
  Atomically replaces the current context with a prepared plan.

  The archive generation is durable before the swap. If the swap fails, the
  archive is removed (or marked orphaned when it cannot be removed) so a
  later reader never mistakes an uncommitted generation for the current one.
  """
  @spec commit(Path.t(), binary(), plan(), keyword()) :: :ok | {:error, term()}
  def commit(state_dir, agent_id, %{archive: archive, entries: entries}, opts \\ []) do
    replace =
      Keyword.get(opts, :replace, fn -> ContextStore.replace(state_dir, agent_id, entries) end)

    result =
      try do
        replace.()
      rescue
        error -> {:error, {:exception, Exception.message(error)}}
      catch
        kind, reason -> {:error, {:exception, {kind, reason}}}
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        abandon_archive(archive)
        {:error, {:context_replace_failed, reason}}

      other ->
        abandon_archive(archive)
        {:error, {:context_replace_failed, other}}
    end
  end

  @doc "Removes the archive generation of a plan that will not be committed."
  @spec discard(plan()) :: :ok
  def discard(%{archive: archive}), do: abandon_archive(archive)

  defp split_system(messages) do
    Enum.split_with(messages, &match?(%Message{role: :system}, &1))
  end

  defp ensure_progress(%{dropped: []}), do: :unchanged
  defp ensure_progress(%{dropped: _dropped}), do: :ok

  defp target(policy, messages, opts) do
    cond do
      is_integer(opts[:target]) and opts[:target] >= 0 ->
        opts[:target]

      Policy.enabled?(policy) ->
        policy.target

      true ->
        div(Tokens.estimate(messages), 2)
    end
  end

  defp policy_for(source, opts) do
    case Keyword.get(opts, :policy) do
      %Policy{} = policy -> policy
      _other -> Policy.from(source, opts)
    end
  end

  defp read_entries(state_dir, agent_id) do
    case ContextStore.read(state_dir, agent_id) do
      {:ok, entries} -> {:ok, entries}
      {:incomplete, entries, _rest} -> {:ok, entries}
      {:error, reason} -> {:error, {:context_read_failed, reason}}
    end
  end

  defp last_run(entries) do
    entries
    |> Enum.filter(&match?({:run, _record}, &1))
    |> List.last()
    |> case do
      {:run, record} -> record
      nil -> nil
    end
  end

  defp last_message_meta(entries) do
    entries
    |> Enum.filter(&match?({:message, _record}, &1))
    |> List.last()
    |> case do
      {:message, record} -> record
      nil -> %{}
    end
  end

  defp run_id(opts, message_meta, run) do
    Keyword.get(opts, :run_id) ||
      Map.get(message_meta, :run_id) ||
      (run && Map.get(run, :run_id))
  end

  defp attempt_id(opts, message_meta) do
    Keyword.get(opts, :attempt_id) || Map.get(message_meta, :attempt_id)
  end

  defp run_entries(nil, nil, _at), do: []

  defp run_entries(nil, run_id, at),
    do: [{:run, %{run_id: run_id, status: "started", at: at}}]

  defp run_entries(run, nil, _at), do: [{:run, run}]

  defp run_entries(%{run_id: run_id} = run, run_id, _at) when is_binary(run_id),
    do: [{:run, run}]

  defp run_entries(_run, run_id, at),
    do: [{:run, %{run_id: run_id, status: "started", at: at}}]

  defp archived_messages(entries, fallback) do
    case for {:message, %{message: message}} <- entries, do: message do
      [] -> fallback
      messages -> messages
    end
  end

  defp snapshot(state_dir, agent_id, messages, run_id, attempt_id, at) do
    case ContextStore.snapshot(state_dir, agent_id) do
      {:ok, <<>>} ->
        entries =
          [] |> append_run(run_id, at) |> append_messages(messages, run_id, attempt_id, at)

        ContextStore.encode_entries(entries)

      {:ok, data} ->
        {:ok, data}

      {:error, reason} ->
        {:error, {:context_snapshot_failed, reason}}
    end
  end

  defp append_run(entries, nil, _at), do: entries

  defp append_run(entries, run_id, at) do
    entries ++ [{:run, %{run_id: run_id, status: "started", at: at}}]
  end

  defp append_messages(entries, messages, run_id, attempt_id, at) do
    entries ++
      ContextStore.message_entries(messages, run_id: run_id, attempt_id: attempt_id, at: at)
  end

  defp summarize(dropped, source, opts) do
    request = %Request{
      model: request_model(source, opts),
      messages: [
        Message.system(@system_prompt),
        Message.user(render_transcript(dropped) <> "\n\n" <> @user_prompt)
      ],
      temperature: 0,
      max_tokens: Keyword.get(opts, :max_summary_tokens, @default_max_summary_tokens)
    }

    case safe_complete(request, provider_opts(opts)) do
      {:ok, %Response{content: content}} when is_binary(content) ->
        case String.trim(content) do
          "" -> {:error, :empty_summary}
          summary -> {:ok, summary}
        end

      {:ok, %Response{}} ->
        {:error, :empty_summary}

      {:error, %Error{} = error} ->
        {:error, {:provider_error, error}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:provider_invalid_response, other}}
    end
  end

  defp safe_complete(request, opts) do
    try do
      Provider.complete(request, opts)
    rescue
      error -> {:error, {:provider_exception, Exception.message(error)}}
    catch
      kind, reason -> {:error, {:provider_exception, {kind, reason}}}
    end
  end

  defp provider_opts(opts) do
    provider_opts = Keyword.get(opts, :provider_opts, [])

    provider_opts =
      case Keyword.fetch(opts, :provider) do
        {:ok, provider} -> Keyword.put_new(provider_opts, :provider, provider)
        :error -> provider_opts
      end

    case Keyword.fetch(opts, :config) do
      {:ok, config} -> Keyword.put_new(provider_opts, :config, config)
      :error -> provider_opts
    end
  end

  defp request_model(source, opts) do
    Keyword.get(opts, :model) || model_name(source)
  end

  defp model_name(%{model: %{name: name}}) when is_binary(name), do: name
  defp model_name(%{"model" => %{"name" => name}}) when is_binary(name), do: name
  defp model_name(_source), do: nil

  defp render_transcript(messages) do
    messages
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {message, index} -> render_message(message, index) end)
  end

  defp render_message(%Message{} = message, index) do
    lines =
      ["[" <> Integer.to_string(index) <> "] role=" <> to_string(message.role)]
      |> append_line("name", message.name)
      |> append_line("tool_call_id", message.tool_call_id)
      |> append_line("content", message.content)
      |> Kernel.++(render_calls(message.tool_calls))

    Enum.join(lines, "\n")
  end

  defp append_line(lines, _key, nil), do: lines
  defp append_line(lines, key, value), do: lines ++ [key <> ": " <> to_string(value)]

  defp render_calls([]), do: []

  defp render_calls(calls) do
    ["tool_calls:" | Enum.map(calls, &render_call/1)]
  end

  defp render_call(%ToolCall{} = call) do
    arguments =
      case call.raw_arguments do
        raw when is_binary(raw) ->
          raw

        nil ->
          case JSON.encode(call.arguments) do
            {:ok, encoded} -> encoded
            {:error, _reason} -> inspect(call.arguments, limit: 20, printable_limit: 512)
          end
      end

    "  id=" <> to_string(call.id) <> " name=" <> to_string(call.name) <> " args=" <> arguments
  end

  defp render_call(other), do: "  " <> inspect(other, limit: 10, printable_limit: 256)

  defp write_archive(state_dir, agent_id, snapshot, base_metadata, opts) do
    archive_dir = ContextStore.archive_dir(state_dir, agent_id)
    generation = generation_name()
    final_path = ContextStore.archive_path(state_dir, agent_id, generation)
    metadata_path = ContextStore.archive_metadata_path(state_dir, agent_id, generation)
    source_path = temp_path(archive_dir, "snapshot-", ".pbc")
    compressed_path = temp_path(archive_dir, "generation-", ".tmp")

    result =
      with :ok <- Transcript.ensure_dir(archive_dir),
           :ok <- write_file(source_path, snapshot),
           :ok <- Zstd.compress_file(source_path, compressed_path, opts),
           :ok <- File.chmod(compressed_path, 0o600),
           :ok <- sync_file(compressed_path),
           :ok <- File.rename(compressed_path, final_path),
           {:ok, stat} <- File.stat(final_path) do
        metadata =
          Map.merge(base_metadata, %{
            generation: generation,
            path: final_path,
            metadata_path: metadata_path,
            sha256: Base.encode16(:crypto.hash(:sha256, snapshot), case: :lower),
            original_bytes: byte_size(snapshot),
            compressed_bytes: stat.size
          })

        with {:ok, encoded} <- JSON.encode(stringify_keys(metadata)),
             :ok <- write_file(metadata_path, encoded),
             :ok <- File.chmod(metadata_path, 0o600) do
          _ = Transcript.sync_dir(archive_dir)
          {:ok, metadata}
        else
          {:error, reason} ->
            _ = File.rm(final_path)
            _ = File.rm(metadata_path)
            _ = Transcript.sync_dir(archive_dir)
            {:error, {:archive_metadata_failed, reason}}
        end
      end

    _ = File.rm(source_path)
    _ = File.rm(compressed_path)
    result
  end

  defp abandon_archive(%{path: path, metadata_path: metadata_path}) do
    archive_dir = Path.dirname(path)
    path_result = remove(path)
    metadata_result = remove(metadata_path)

    if path_result != :ok or metadata_result != :ok do
      mark_orphaned(metadata_path, path, path_result, metadata_result)
    end

    _ = Transcript.sync_dir(archive_dir)
    :ok
  end

  defp remove(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_orphaned(metadata_path, archive_path, path_result, metadata_result) do
    metadata = %{
      status: "orphaned",
      reason: "context_replace_failed",
      path: archive_path,
      cleanup: %{archive: inspect(path_result), metadata: inspect(metadata_result)}
    }

    with {:ok, encoded} <- JSON.encode(stringify_keys(metadata)),
         :ok <- File.write(metadata_path, encoded) do
      _ = File.chmod(metadata_path, 0o600)
      :ok
    end
  end

  defp generation_name do
    timestamp =
      DateTime.utc_now()
      |> DateTime.truncate(:millisecond)
      |> DateTime.to_iso8601()
      |> String.replace(~r/[^0-9A-Za-z]/, "")

    suffix =
      :crypto.strong_rand_bytes(5)
      |> Base.url_encode64(padding: false)

    timestamp <> "-" <> suffix <> ".pbc.zst"
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp temp_path(dir, prefix, suffix) do
    random =
      :crypto.strong_rand_bytes(6)
      |> Base.url_encode64(padding: false)

    Path.join(dir, "." <> prefix <> random <> suffix)
  end

  defp write_file(path, data) do
    with {:ok, io} <- File.open(path, [:write, :binary, :exclusive]) do
      try do
        with :ok <- IO.binwrite(io, data),
             :ok <- :file.sync(io) do
          :ok
        end
      after
        File.close(io)
      end
    end
  end

  defp sync_file(path) do
    path
    |> File.open([:read, :write, :binary], fn io -> :file.sync(io) end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp now_iso do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end
end
