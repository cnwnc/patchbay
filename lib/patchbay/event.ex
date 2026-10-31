defmodule Patchbay.Event do
  @moduledoc """
  Durable, ordered runtime events.

  Events are appended to a per-agent file under `<state_dir>/events`. Each
  record is one `Patchbay.Worker.Protocol` frame carrying `{:event, map}` so
  the existing streaming decoder can read a partially written tail without
  losing the records before it.

  Event data is restricted to wire-safe values before it is written. Atoms
  become strings, tuples become lists, and unknown terms are inspected. That
  keeps a state file readable by a fresh VM without creating atoms from the
  file contents.
  """

  alias Patchbay.Transcript
  alias Patchbay.Worker.Protocol
  alias Patchbay.Worker.Protocol.Stream

  @types [
    :run_started,
    :run_resumed,
    :attempt_started,
    :instance_ready,
    :agent_started,
    :agent_start_failed,
    :agent_stopped,
    :agent_stop_failed,
    :tool_call,
    :tool_result,
    :user_message,
    :model_message,
    :model_tool_call,
    :context_compacted,
    :agent_waiting,
    :agent_woken,
    :run_completed,
    :run_failed,
    :provider_error,
    :agent_failed,
    :hook_started,
    :hook_finished,
    :hook_failed,
    :artifact_published,
    :artifact_publish_failed,
    :workspace_exported,
    :workspace_destroyed,
    :workspace_teardown_failed
  ]

  @fields [
    :id,
    :sequence,
    :at,
    :type,
    :agent_id,
    :run_id,
    :attempt_id,
    :instance_id,
    :definition_revision,
    :data
  ]

  @enforce_keys [:id, :sequence, :at, :type, :agent_id]
  defstruct @fields

  @type type ::
          :run_started
          | :run_resumed
          | :attempt_started
          | :instance_ready
          | :agent_started
          | :agent_start_failed
          | :agent_stopped
          | :agent_stop_failed
          | :tool_call
          | :tool_result
          | :user_message
          | :model_message
          | :model_tool_call
          | :context_compacted
          | :agent_waiting
          | :agent_woken
          | :run_completed
          | :run_failed
          | :provider_error
          | :agent_failed
          | :hook_started
          | :hook_finished
          | :hook_failed
          | :artifact_published
          | :artifact_publish_failed
          | :workspace_exported
          | :workspace_destroyed
          | :workspace_teardown_failed

  @type t :: %__MODULE__{
          id: binary(),
          sequence: pos_integer(),
          at: binary(),
          type: type(),
          agent_id: binary(),
          run_id: binary() | nil,
          attempt_id: binary() | nil,
          instance_id: binary() | nil,
          definition_revision: pos_integer() | nil,
          data: map()
        }

  @doc false
  @spec types() :: [type()]
  def types, do: @types

  @doc "Builds an event. `:id`, `:at`, and `:data` have defaults."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, type} <- fetch_type(attrs),
         {:ok, agent_id} <- fetch_agent_id(attrs),
         {:ok, sequence} <- fetch_sequence(attrs) do
      {:ok,
       %__MODULE__{
         id: Map.get(attrs, :id) || generate_id(),
         sequence: sequence,
         at: Map.get(attrs, :at) || now(),
         type: type,
         agent_id: agent_id,
         run_id: Map.get(attrs, :run_id),
         attempt_id: Map.get(attrs, :attempt_id),
         instance_id: Map.get(attrs, :instance_id),
         definition_revision: Map.get(attrs, :definition_revision),
         data: sanitize(Map.get(attrs, :data, %{}))
       }}
    end
  end

  @doc "Returns the directory that holds event files for `state_dir`."
  @spec dir(Path.t()) :: Path.t()
  def dir(state_dir) when is_binary(state_dir), do: Path.join(state_dir, "events")

  @doc "Returns the event file for `agent_id`."
  @spec path(Path.t(), binary()) :: Path.t()
  def path(state_dir, agent_id) when is_binary(state_dir) and is_binary(agent_id) do
    unless valid_agent_id?(agent_id) do
      raise ArgumentError, "invalid agent id for event path: #{inspect(agent_id)}"
    end

    Path.join(dir(state_dir), agent_id <> ".pbe")
  end

  @doc "Returns true when `agent_id` can be used as one event file name."
  @spec valid_agent_id?(term()) :: boolean()
  def valid_agent_id?(agent_id) when is_binary(agent_id) do
    agent_id not in ["", ".", ".."] and
      Path.basename(agent_id) == agent_id and
      not String.contains?(agent_id, ["/", "\\"]) and
      String.valid?(agent_id)
  end

  def valid_agent_id?(_agent_id), do: false

  @doc """
  Appends one event, creating its private directory when needed.

  `:repair` (default `true`) drops an incomplete trailing frame before the
  append. A caller that already repaired the file in this process can pass
  `repair: false` to avoid rescanning it.
  """
  @spec append(Path.t(), t(), keyword()) :: :ok | {:error, term()}
  def append(path, %__MODULE__{} = event, opts \\ []) when is_binary(path) do
    with :ok <- Transcript.ensure_dir(Path.dirname(path)),
         :ok <- maybe_repair(path, Keyword.get(opts, :repair, true)),
         {:ok, frame} <- Protocol.encode(encode_term(event)) do
      Transcript.append(path, frame)
    end
  end

  @doc """
  Reads every complete event in `path`.

  A trailing partial frame is returned with `:incomplete` rather than
  discarded, matching the transcript reader.
  """
  @spec read(Path.t()) ::
          {:ok, [t()]} | {:incomplete, [t()], binary()} | {:error, term()}
  def read(path) when is_binary(path) do
    with :ok <- Transcript.ensure_file(path) do
      case File.read(path) do
        {:ok, data} -> decode_stream(data)
        {:error, :enoent} -> {:ok, []}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Returns the highest complete sequence in `path`, or zero when absent."
  @spec last_sequence(Path.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def last_sequence(path) when is_binary(path) do
    case read(path) do
      {:ok, events} -> {:ok, max_sequence(events)}
      {:incomplete, events, _rest} -> {:ok, max_sequence(events)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec decode_stream(binary()) ::
          {:ok, [t()]} | {:incomplete, [t()], binary()} | {:error, term()}
  def decode_stream(data) when is_binary(data) do
    case Stream.feed(Stream.new(), data) do
      {:ok, terms, stream} ->
        with {:ok, events} <- decode_terms(terms) do
          if stream.buffer == "" do
            {:ok, events}
          else
            {:incomplete, events, stream.buffer}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec encode_term(t()) :: term()
  def encode_term(%__MODULE__{} = event) do
    {:event,
     %{
       id: event.id,
       sequence: event.sequence,
       at: event.at,
       type: event.type,
       agent_id: event.agent_id,
       run_id: event.run_id,
       attempt_id: event.attempt_id,
       instance_id: event.instance_id,
       definition_revision: event.definition_revision,
       data: event.data
     }}
  end

  defp maybe_repair(_path, false), do: :ok
  defp maybe_repair(path, true), do: recover(path)

  defp recover(path) do
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
      size > 1_048_576 -> {:ok, offset}
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
      case decode_term(term) do
        {:ok, event} -> {:cont, {:ok, [event | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_term({:event, %{} = map}) do
    with {:ok, type} <- fetch_type(map),
         {:ok, agent_id} <- fetch_agent_id(map),
         {:ok, sequence} <- fetch_sequence(map),
         {:ok, id} <- fetch_binary(map, :id),
         {:ok, at} <- fetch_binary(map, :at) do
      {:ok,
       %__MODULE__{
         id: id,
         sequence: sequence,
         at: at,
         type: type,
         agent_id: agent_id,
         run_id: Map.get(map, :run_id),
         attempt_id: Map.get(map, :attempt_id),
         instance_id: Map.get(map, :instance_id),
         definition_revision: Map.get(map, :definition_revision),
         data: Map.get(map, :data, %{})
       }}
    end
  end

  defp decode_term(term), do: {:error, {:invalid_event, term}}

  defp max_sequence(events) do
    events
    |> Enum.map(& &1.sequence)
    |> Enum.max(fn -> 0 end)
  end

  defp fetch_type(attrs) do
    case Map.get(attrs, :type) do
      type when type in @types -> {:ok, type}
      other -> {:error, {:invalid_event_type, other}}
    end
  end

  defp fetch_agent_id(attrs) do
    case Map.get(attrs, :agent_id) do
      agent_id when is_binary(agent_id) ->
        if valid_agent_id?(agent_id),
          do: {:ok, agent_id},
          else: {:error, {:invalid_agent_id, agent_id}}

      other ->
        {:error, {:invalid_agent_id, other}}
    end
  end

  defp fetch_sequence(attrs) do
    case Map.get(attrs, :sequence) do
      sequence when is_integer(sequence) and sequence > 0 -> {:ok, sequence}
      other -> {:error, {:invalid_event_sequence, other}}
    end
  end

  defp fetch_binary(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) -> {:ok, value}
      other -> {:error, {:invalid_event_field, key, other}}
    end
  end

  defp sanitize(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {sanitize_key(key), sanitize(nested)} end)
  end

  defp sanitize(value) when is_list(value), do: Enum.map(value, &sanitize/1)

  defp sanitize(value) when is_tuple(value), do: value |> Tuple.to_list() |> sanitize()

  defp sanitize(value) when is_binary(value) or is_number(value), do: value

  defp sanitize(value) when value in [true, false, nil], do: value

  defp sanitize(value) when is_atom(value), do: Atom.to_string(value)

  defp sanitize(value), do: inspect(value, limit: 50, printable_limit: 4096)

  defp sanitize_key(key) when is_binary(key), do: key
  defp sanitize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp sanitize_key(key), do: inspect(key, limit: 10, printable_limit: 256)

  defp generate_id do
    "evt-" <>
      Integer.to_string(System.system_time(:microsecond), 36) <>
      "-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
