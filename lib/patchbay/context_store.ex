defmodule Patchbay.ContextStore do
  @moduledoc """
  Durable, provider-neutral conversation records for the agent runner.

  Records are appended to a per-agent file under `<state_dir>/context` using
  the same framed, safe-decoding format as runtime events. Directories are
  private and files are owner-only, matching the transcript storage policy.

  The store is not an event-sourcing rebuild. It holds just enough to answer
  one question when an agent starts again: should the previous provider
  messages be restored, and if so, which complete turns are safe to reuse.

  Run markers (`started`, `interrupted`, `completed`, `failed`, `cancelled`)
  let a fresh runtime tell an interrupted run from a closed one without
  replaying lifecycle events. Tool outcomes are recorded before dispatch, so
  an interrupted turn restores with an unknown-outcome result; `sanitize/1`
  still discards a trailing assistant tool call whose results were never
  recorded, so a restart cannot replay tools from an incomplete provider turn.
  """

  alias Patchbay.Definition.Context
  alias Patchbay.Provider.{Message, ToolCall}
  alias Patchbay.Transcript
  alias Patchbay.Worker.Protocol
  alias Patchbay.Worker.Protocol.Stream

  @tag :context
  @keep_values ~w(keep carry handoff prompt full all continue resume checkpoint queryable)
  @reset_values ~w(reset none fresh clear drop new)
  @open_statuses ["started", "interrupted"]
  @roles ["system", "user", "assistant", "tool"]

  @type decision :: :reset | :restore_run | :restore_all

  @type entry ::
          {:message,
           %{
             run_id: binary() | nil,
             attempt_id: binary() | nil,
             at: binary() | nil,
             message: Message.t()
           }}
          | {:run, %{run_id: binary() | nil, status: String.t(), at: binary() | nil}}

  @doc "Returns the directory that holds context files for `state_dir`."
  @spec dir(Path.t()) :: Path.t()
  def dir(state_dir) when is_binary(state_dir), do: Path.join(state_dir, "context")

  @doc "Returns the context file for `agent_id`."
  @spec path(Path.t(), binary()) :: Path.t()
  def path(state_dir, agent_id) when is_binary(state_dir) and is_binary(agent_id) do
    unless valid_agent_id?(agent_id) do
      raise ArgumentError, "invalid agent id for context path: #{inspect(agent_id)}"
    end

    Path.join(dir(state_dir), agent_id <> ".pbc")
  end

  @doc "Returns the archive directory for `agent_id`."
  @spec archive_dir(Path.t(), binary()) :: Path.t()
  def archive_dir(state_dir, agent_id) when is_binary(state_dir) and is_binary(agent_id) do
    unless valid_agent_id?(agent_id) do
      raise ArgumentError, "invalid agent id for context archive: #{inspect(agent_id)}"
    end

    Path.join([dir(state_dir), agent_id, "archive"])
  end

  @doc "Returns the archive file for one compressed generation."
  @spec archive_path(Path.t(), binary(), binary()) :: Path.t()
  def archive_path(state_dir, agent_id, generation) when is_binary(generation) do
    unless valid_generation?(generation) do
      raise ArgumentError, "invalid context archive generation: #{inspect(generation)}"
    end

    Path.join(archive_dir(state_dir, agent_id), generation)
  end

  @doc "Returns the metadata sidecar path for one compressed generation."
  @spec archive_metadata_path(Path.t(), binary(), binary()) :: Path.t()
  def archive_metadata_path(state_dir, agent_id, generation) do
    state_dir
    |> archive_path(agent_id, generation)
    |> Path.rootname(".zst")
    |> Kernel.<>(".json")
  end

  defp valid_generation?(generation) do
    generation not in ["", ".", ".."] and
      Path.basename(generation) == generation and
      String.ends_with?(generation, ".pbc.zst") and
      not String.contains?(generation, ["/", "\\"]) and
      String.valid?(generation)
  end

  @doc "Returns true when `agent_id` can be used as one context file name."
  @spec valid_agent_id?(term()) :: boolean()
  def valid_agent_id?(agent_id) when is_binary(agent_id) do
    agent_id not in ["", ".", ".."] and
      Path.basename(agent_id) == agent_id and
      not String.contains?(agent_id, ["/", "\\"]) and
      String.valid?(agent_id)
  end

  def valid_agent_id?(_agent_id), do: false

  @doc """
  Appends one provider message.

  `:repair` (default `true`) drops an incomplete trailing frame before the
  append. A runtime that already repaired the file in this process can pass
  `repair: false`. `sync: true` flushes the frame to stable storage before
  returning, which the runner uses for an in-flight tool outcome.
  """
  @spec append_message(
          Path.t(),
          binary(),
          binary() | nil,
          binary() | nil,
          Message.t(),
          keyword()
        ) :: :ok | {:error, term()}
  def append_message(state_dir, agent_id, run_id, attempt_id, %Message{} = message, opts \\ []) do
    record = %{
      type: "message",
      run_id: run_id,
      attempt_id: attempt_id,
      at: timestamp(opts),
      message: encode_message(message)
    }

    append(state_dir, agent_id, record, opts)
  end

  @doc "Appends a run boundary marker for `run_id`."
  @spec append_run(Path.t(), binary(), binary() | nil, atom() | String.t(), keyword()) ::
          :ok | {:error, term()}
  def append_run(state_dir, agent_id, run_id, status, opts \\ []) do
    record = %{
      type: "run",
      run_id: run_id,
      status: normalize_status(status),
      at: timestamp(opts)
    }

    append(state_dir, agent_id, record, opts)
  end

  @doc "Removes the stored conversation for `agent_id`."
  @spec clear(Path.t(), binary()) :: :ok | {:error, term()}
  def clear(state_dir, agent_id) do
    case File.rm(path(state_dir, agent_id)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reads the raw bytes of the stored context file.

  A missing file returns an empty binary. The bytes are not repaired, so an
  archive of an interrupted append keeps the file as it was on disk.
  """
  @spec snapshot(Path.t(), binary()) :: {:ok, binary()} | {:error, term()}
  def snapshot(state_dir, agent_id) do
    path = path(state_dir, agent_id)

    with :ok <- Transcript.ensure_file(path) do
      case File.read(path) do
        {:ok, data} -> {:ok, data}
        {:error, :enoent} -> {:ok, <<>>}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Atomically replaces the stored context with `entries`.

  The new file is written to a temporary name, synced, given owner-only
  permissions, and renamed over the current context. Readers therefore see
  either the old file or the complete new one.
  """
  @spec replace(Path.t(), binary(), [entry()]) :: :ok | {:error, term()}
  def replace(state_dir, agent_id, entries) when is_list(entries) do
    path = path(state_dir, agent_id)

    with :ok <- Transcript.ensure_dir(dir(state_dir)),
         :ok <- Transcript.ensure_file(path),
         {:ok, data} <- encode_entries(entries) do
      write_atomic(path, data)
    end
  end

  @doc "Builds message entries attributed to one run and attempt."
  @spec message_entries([Message.t()], keyword()) :: [entry()]
  def message_entries(messages, opts \\ []) when is_list(messages) do
    run_id = Keyword.get(opts, :run_id)
    attempt_id = Keyword.get(opts, :attempt_id)
    at = timestamp(opts)

    for %Message{} = message <- messages do
      {:message, %{run_id: run_id, attempt_id: attempt_id, at: at, message: message}}
    end
  end

  @doc "Encodes entries into the framed context file format."
  @spec encode_entries([entry()]) :: {:ok, binary()} | {:error, term()}
  def encode_entries(entries) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, frames} ->
      with {:ok, record} <- encode_entry(entry),
           {:ok, frame} <- Protocol.encode({@tag, record}) do
        {:cont, {:ok, [frame | frames]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, frames} -> {:ok, frames |> Enum.reverse() |> IO.iodata_to_binary()}
      {:error, _reason} = error -> error
    end
  end

  defp encode_entry({:message, %{message: %Message{} = message} = meta}) do
    {:ok,
     %{
       type: "message",
       run_id: binary_or_nil(Map.get(meta, :run_id)),
       attempt_id: binary_or_nil(Map.get(meta, :attempt_id)),
       at: meta_timestamp(meta),
       message: encode_message(message)
     }}
  end

  defp encode_entry({:run, %{status: status} = meta}) do
    {:ok,
     %{
       type: "run",
       run_id: binary_or_nil(Map.get(meta, :run_id)),
       status: normalize_status(status),
       at: meta_timestamp(meta)
     }}
  end

  defp encode_entry(_entry), do: {:error, :invalid_context_entry}

  defp meta_timestamp(%{at: at}) when is_binary(at), do: at
  defp meta_timestamp(_meta), do: nil

  defp write_atomic(path, data) do
    temp = temp_path(path)

    result =
      with {:ok, io} <- File.open(temp, [:write, :binary, :exclusive]),
           :ok <- write_sync(io, data),
           :ok <- File.chmod(temp, 0o600),
           :ok <- File.rename(temp, path) do
        _ = Transcript.sync_dir(Path.dirname(path))
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        _ = File.rm(temp)
        {:error, reason}
    end
  end

  defp write_sync(io, data) do
    try do
      with :ok <- IO.binwrite(io, data) do
        :file.sync(io)
      end
    after
      File.close(io)
    end
  end

  defp temp_path(path) do
    suffix =
      :crypto.strong_rand_bytes(6)
      |> Base.url_encode64(padding: false)

    Path.join(Path.dirname(path), "." <> Path.basename(path) <> ".tmp-" <> suffix)
  end

  @doc """
  Reads every complete context record for `agent_id`.

  A trailing partial frame is returned with `:incomplete`, matching the event
  and transcript readers.
  """
  @spec read(Path.t(), binary()) ::
          {:ok, [entry()]} | {:incomplete, [entry()], binary()} | {:error, term()}
  def read(state_dir, agent_id) do
    path = path(state_dir, agent_id)

    with :ok <- Transcript.ensure_file(path) do
      case File.read(path) do
        {:ok, data} -> decode_stream(data)
        {:error, :enoent} -> {:ok, []}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc false
  @spec decode_stream(binary()) ::
          {:ok, [entry()]} | {:incomplete, [entry()], binary()} | {:error, term()}
  def decode_stream(data) when is_binary(data) do
    case Stream.feed(Stream.new(), data) do
      {:ok, terms, stream} ->
        with {:ok, entries} <- decode_terms(terms) do
          if stream.buffer == "" do
            {:ok, entries}
          else
            {:incomplete, entries, stream.buffer}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Decides whether to restore a stored conversation and returns its messages.

  The decision depends on the definition's `[context]` policy and on whether
  the last stored run was interrupted. `recovery` is a
  `Patchbay.Lifecycle.recovery/1` value.
  """
  @spec restore([entry()], Context.t() | map() | nil, atom(), term(), term()) ::
          {decision(), [Message.t()]}
  def restore(entries, context, kind, recovery, current_run_id) do
    case recovery do
      {:refuse, _run_id} ->
        {:reset, []}

      _other ->
        store_state = store_state(entries, recovery)
        decision = recovery_mode(context, kind, store_state)

        messages =
          case decision do
            :reset ->
              []

            :restore_run ->
              messages_for(entries, :run, target_run_id(entries, recovery, current_run_id))

            :restore_all ->
              messages_for(entries, :all, nil)
          end

        {decision, sanitize(messages)}
    end
  end

  @doc """
  Returns `:interrupted`, `:closed`, or `:none` for the last stored run.
  """
  @spec store_state([entry()], term()) :: :interrupted | :closed | :none
  def store_state(_entries, {:resume, _run_id}), do: :interrupted
  def store_state(_entries, {:refuse, _run_id}), do: :none

  def store_state(entries, _recovery) do
    case last_run(entries) do
      nil -> :none
      %{status: status} -> if status in @open_statuses, do: :interrupted, else: :closed
    end
  end

  @doc """
  Applies the `[context]` vocabulary to a run boundary.

  Values are intentionally permissive because the definition loader validates
  their shape, not their meaning. Recognized keep values opt in; recognized
  reset values opt out; anything else falls back to the lifecycle kind. A
  perpetual agent keeps its memory across runs, while a one-shot agent starts
  a new run without prior conversation unless its policy says otherwise.
  """
  @spec recovery_mode(Context.t() | map() | nil, atom() | nil, atom()) :: decision()
  def recovery_mode(context, kind, store_state) do
    context = context_fields(context)

    case store_state do
      :interrupted ->
        case classify(Map.get(context, :restore_interrupted)) do
          :keep ->
            if keep_prior_runs?(context, kind), do: :restore_all, else: :restore_run

          :reset ->
            :reset

          :unset ->
            cond do
              keep_prior_runs?(context, kind) -> :restore_all
              kind == :scheduled -> :restore_run
              true -> :reset
            end
        end

      :closed ->
        case classify(Map.get(context, :between_runs)) do
          :keep ->
            :restore_all

          :reset ->
            :reset

          :unset ->
            case classify(Map.get(context, :prior_runs)) do
              :keep -> :restore_all
              :reset -> :reset
              :unset -> if kind == :perpetual, do: :restore_all, else: :reset
            end
        end

      :none ->
        :reset
    end
  end

  @doc """
  Drops partial tool turns and orphaned tool messages from `messages`.

  An assistant message that requested tools is kept only when every requested
  call has a following tool message with the matching id. Invalid, duplicate,
  or unanswered calls drop the whole turn so a restart never resumes a
  half-executed provider turn.
  """
  @spec sanitize([Message.t()]) :: [Message.t()]
  def sanitize(messages) when is_list(messages) do
    {kept, pending, marker} =
      messages
      |> keep_last_tool_result()
      |> Enum.reduce({[], [], nil}, &sanitize_step/2)

    {kept, _pending, _marker} = close_turn(kept, pending, marker)
    kept |> Enum.reverse()
  end

  defp keep_last_tool_result(messages) do
    {kept, _seen} =
      messages
      |> Enum.reverse()
      |> Enum.reduce({[], MapSet.new()}, fn
        %Message{role: :tool, tool_call_id: id} = message, {kept, seen}
        when is_binary(id) ->
          if MapSet.member?(seen, id) do
            {kept, seen}
          else
            {[message | kept], MapSet.put(seen, id)}
          end

        message, {kept, seen} ->
          {[message | kept], seen}
      end)

    kept
  end

  defp sanitize_step(%Message{role: :system}, state), do: state

  defp sanitize_step(%Message{role: role} = message, {kept, pending, marker})
       when role in [:user, :assistant] and message.tool_calls == [] do
    {kept, _pending, _marker} = close_turn(kept, pending, marker)
    {[message | kept], [], nil}
  end

  defp sanitize_step(
         %Message{role: :assistant, tool_calls: calls} = message,
         {kept, pending, marker}
       ) do
    kept = rollback(kept, pending, marker)

    case call_ids(calls) do
      {:ok, ids} when ids != [] ->
        {[message | kept], ids, length(kept)}

      _invalid ->
        {kept, [], nil}
    end
  end

  defp sanitize_step(%Message{role: :tool, tool_call_id: id} = message, {kept, pending, marker}) do
    if is_binary(id) and id in pending do
      pending = List.delete(pending, id)
      marker = if pending == [], do: nil, else: marker
      {[message | kept], pending, marker}
    else
      {kept, pending, marker}
    end
  end

  defp sanitize_step(_message, state), do: state

  defp close_turn(kept, [], _marker), do: {kept, [], nil}
  defp close_turn(kept, pending, marker), do: {rollback(kept, pending, marker), [], nil}

  defp rollback(kept, [], _marker), do: kept

  defp rollback(kept, _pending, marker) when is_integer(marker) do
    Enum.drop(kept, max(length(kept) - marker, 0))
  end

  defp rollback(kept, _pending, _marker), do: kept

  defp call_ids(calls) do
    ids =
      Enum.map(calls, fn
        %ToolCall{id: id, name: name} when is_binary(id) and id != "" and is_binary(name) -> id
        _call -> nil
      end)

    if Enum.all?(ids, &is_binary/1) and Enum.uniq(ids) == ids do
      {:ok, ids}
    else
      :invalid
    end
  end

  defp append(state_dir, agent_id, record, opts) do
    path = path(state_dir, agent_id)
    repair? = Keyword.get(opts, :repair, true)
    sync? = Keyword.get(opts, :sync, false)

    with :ok <- Transcript.ensure_dir(dir(state_dir)),
         :ok <- maybe_repair(path, repair?),
         {:ok, frame} <- Protocol.encode({@tag, record}) do
      Transcript.append(path, frame, sync: sync?)
    end
  end

  defp maybe_repair(_path, false), do: :ok
  defp maybe_repair(path, true), do: repair(path)

  defp repair(path) do
    with :ok <- Transcript.ensure_file(path),
         {:ok, data} <- read_bytes(path),
         {:ok, complete_size} <- complete_size(data, 0) do
      if complete_size == byte_size(data), do: :ok, else: truncate(path, complete_size)
    end
  end

  defp read_bytes(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, :enoent} -> {:ok, <<>>}
      {:error, reason} -> {:error, reason}
    end
  end

  defp complete_size(<<>>, offset), do: {:ok, offset}

  defp complete_size(<<size::unsigned-big-32, rest::binary>>, offset) do
    cond do
      size == 0 -> {:ok, offset}
      size > Protocol.default_max_frame() -> {:ok, offset}
      byte_size(rest) < size -> {:ok, offset}
      true -> complete_size(binary_part(rest, size, byte_size(rest) - size), offset + 4 + size)
    end
  end

  defp complete_size(_partial, offset), do: {:ok, offset}

  defp truncate(path, offset) do
    path
    |> File.open([:read, :write, :binary], fn io ->
      {:ok, _position} = :file.position(io, offset)
      :file.truncate(io)
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_terms(terms) do
    Enum.reduce_while(terms, {:ok, []}, fn term, {:ok, acc} ->
      case decode_entry(term) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, _reason} -> {:halt, {:error, :invalid_context_record}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_entry({@tag, %{type: "message", message: message} = record}) do
    with {:ok, message} <- decode_message(message) do
      {:ok,
       {:message,
        %{
          run_id: binary_or_nil(Map.get(record, :run_id)),
          attempt_id: binary_or_nil(Map.get(record, :attempt_id)),
          at: binary_or_nil(Map.get(record, :at)),
          message: message
        }}}
    end
  end

  defp decode_entry({@tag, %{type: "run", status: status} = record}) when is_binary(status) do
    {:ok,
     {:run,
      %{
        run_id: binary_or_nil(Map.get(record, :run_id)),
        status: status,
        at: binary_or_nil(Map.get(record, :at))
      }}}
  end

  defp decode_entry(_term), do: {:error, :invalid_context_record}

  defp decode_message(%{role: role} = map) when is_binary(role) and role in @roles do
    with {:ok, content} <- content(Map.get(map, :content)),
         {:ok, tool_calls} <- decode_calls(Map.get(map, :tool_calls, [])),
         {:ok, tool_call_id} <- binary_or_nil_ok(Map.get(map, :tool_call_id)),
         {:ok, name} <- binary_or_nil_ok(Map.get(map, :name)) do
      {:ok,
       %Message{
         role: String.to_existing_atom(role),
         content: content,
         tool_calls: tool_calls,
         tool_call_id: tool_call_id,
         name: name
       }}
    end
  end

  defp decode_message(_map), do: {:error, :invalid_context_message}

  defp content(nil), do: {:ok, nil}
  defp content(value) when is_binary(value), do: {:ok, value}
  defp content(_value), do: {:error, :invalid_context_content}

  defp decode_calls(calls) when is_list(calls) do
    Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, acc} ->
      case decode_call(call) do
        {:ok, call} -> {:cont, {:ok, [call | acc]}}
        {:error, _reason} -> {:halt, {:error, :invalid_context_tool_call}}
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_calls(_calls), do: {:error, :invalid_context_tool_calls}

  defp decode_call(%{id: id, name: name, arguments: arguments} = call)
       when is_binary(id) and is_binary(name) and is_map(arguments) do
    {:ok,
     %ToolCall{
       id: id,
       name: name,
       arguments: arguments,
       raw_arguments: binary_or_nil(Map.get(call, :raw_arguments))
     }}
  end

  defp decode_call(_call), do: {:error, :invalid_context_tool_call}

  defp encode_message(message) do
    %{
      role: Atom.to_string(message.role),
      content: message.content,
      tool_calls: Enum.map(message.tool_calls, &encode_call/1),
      tool_call_id: message.tool_call_id,
      name: message.name
    }
  end

  defp encode_call(%ToolCall{} = call) do
    %{
      id: call.id,
      name: call.name,
      arguments: wire(call.arguments),
      raw_arguments: call.raw_arguments
    }
  end

  defp encode_call(other), do: wire(other)

  defp wire(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {wire_key(key), wire(nested)} end)
  end

  defp wire(value) when is_list(value), do: Enum.map(value, &wire/1)
  defp wire(value) when is_binary(value) or is_number(value), do: value
  defp wire(value) when value in [true, false, nil], do: value
  defp wire(value) when is_atom(value), do: Atom.to_string(value)
  defp wire(value), do: inspect(value, limit: 20, printable_limit: 512)

  defp wire_key(key) when is_binary(key), do: key
  defp wire_key(key) when is_atom(key), do: Atom.to_string(key)
  defp wire_key(key), do: inspect(key, limit: 10, printable_limit: 256)

  defp messages_for(entries, :all, _run_id) do
    for {:message, %{message: message}} <- entries, do: message
  end

  defp messages_for(entries, :run, run_id) when is_binary(run_id) do
    for {:message, %{run_id: ^run_id, message: message}} <- entries, do: message
  end

  defp messages_for(_entries, :run, _run_id), do: []

  defp target_run_id(_entries, {:resume, run_id}, _current_run_id), do: run_id
  defp target_run_id(entries, _recovery, _current_run_id), do: last_run_id(entries)

  defp last_run_id(entries) do
    case last_run(entries) do
      nil -> nil
      %{run_id: run_id} -> run_id
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

  defp keep_prior_runs?(context, kind) do
    case classify(Map.get(context, :between_runs)) do
      :keep ->
        true

      :reset ->
        false

      :unset ->
        case classify(Map.get(context, :prior_runs)) do
          :keep -> true
          :reset -> false
          :unset -> kind == :perpetual
        end
    end
  end

  defp classify(nil), do: :unset

  defp classify(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()

    cond do
      value in @keep_values -> :keep
      value in @reset_values -> :reset
      true -> :unset
    end
  end

  defp classify(value) when is_atom(value) and not is_nil(value),
    do: value |> Atom.to_string() |> classify()

  defp classify(_value), do: :unset

  defp context_fields(%Context{} = context), do: Map.from_struct(context)
  defp context_fields(context) when is_map(context), do: context
  defp context_fields(_context), do: %{}

  defp normalize_status(status) when is_atom(status), do: Atom.to_string(status)
  defp normalize_status(status) when is_binary(status), do: status
  defp normalize_status(_status), do: "unknown"

  defp timestamp(opts) do
    Keyword.get_lazy(opts, :at, fn -> DateTime.utc_now() |> DateTime.to_iso8601() end)
  end

  defp binary_or_nil(value) when is_binary(value), do: value
  defp binary_or_nil(_value), do: nil

  defp binary_or_nil_ok(nil), do: {:ok, nil}
  defp binary_or_nil_ok(value) when is_binary(value), do: {:ok, value}
  defp binary_or_nil_ok(_value), do: {:error, :invalid_context_field}
end
