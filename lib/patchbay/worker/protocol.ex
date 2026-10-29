defmodule Patchbay.Worker.Protocol do
  @moduledoc """
  Length-prefixed external term framing for Patchbay's local control channels.

  A frame is an unsigned 32-bit big-endian payload length followed by
  `term_to_binary/1` output. Frames are decoded with `[:safe]`, so a peer
  cannot create atoms, references, pids, ports, or funs. Compressed terms are
  rejected before decoding, which would otherwise let a small frame expand
  without bound.

  Terms are limited to binaries, numbers, atoms, proper lists, tuples, and
  maps. The streaming decoder keeps a bounded buffer and rejects frames whose
  declared length exceeds the configured maximum.
  """

  @term_version 131
  @compressed_tag 80
  @max_depth 64
  @default_max_frame 1_048_576

  @type wire_term ::
          binary()
          | number()
          | atom()
          | [wire_term()]
          | tuple()
          | %{optional(wire_term()) => wire_term()}

  @doc "Default maximum accepted frame size in bytes."
  @spec default_max_frame() :: pos_integer()
  def default_max_frame, do: @default_max_frame

  @doc """
  Encodes `term` into a single frame.

  Returns `{:error, :invalid_term}` for terms the protocol does not carry and
  `{:error, :term_too_large}` when the encoded frame exceeds `:max_frame`.
  """
  @spec encode(wire_term(), keyword()) ::
          {:ok, binary()} | {:error, :invalid_term | :term_too_large}
  def encode(term, opts \\ []) do
    max_frame = Keyword.get(opts, :max_frame, @default_max_frame)

    if term_allowed?(term) do
      payload = :erlang.term_to_binary(term, minor_version: 1)

      if byte_size(payload) <= max_frame do
        {:ok, <<byte_size(payload)::unsigned-big-32, payload::binary>>}
      else
        {:error, :term_too_large}
      end
    else
      {:error, :invalid_term}
    end
  end

  @doc "Decodes exactly one complete frame."
  @spec decode_frame(binary(), keyword()) ::
          {:ok, wire_term()}
          | {:error,
             :truncated_frame
             | :frame_size_mismatch
             | :frame_too_large
             | :empty_frame
             | :compressed_term
             | :invalid_term}
  def decode_frame(frame, opts \\ []) when is_binary(frame) do
    max_frame = Keyword.get(opts, :max_frame, @default_max_frame)

    case frame do
      <<size::unsigned-big-32, payload::binary>> ->
        cond do
          size == 0 -> {:error, :empty_frame}
          size > max_frame -> {:error, :frame_too_large}
          byte_size(payload) != size -> {:error, :frame_size_mismatch}
          true -> decode_payload(payload, max_frame)
        end

      _ ->
        {:error, :truncated_frame}
    end
  end

  @doc "Decodes one already-separated payload."
  @spec decode_payload(binary(), pos_integer()) ::
          {:ok, wire_term()}
          | {:error, :compressed_term | :frame_too_large | :invalid_term}
  def decode_payload(payload, max_frame \\ @default_max_frame) when is_binary(payload) do
    cond do
      byte_size(payload) > max_frame ->
        {:error, :frame_too_large}

      match?(<<@term_version, @compressed_tag, _::binary>>, payload) ->
        {:error, :compressed_term}

      true ->
        # Safe decoding only accepts atoms that already exist in this VM.
        # Loading the fixed vocabulary first makes peers in other VMs able to
        # exchange the protocol terms regardless of local module loading order.
        _ = Patchbay.Worker.Wire.ensure_loaded()

        try do
          term = :erlang.binary_to_term(payload, [:safe])

          if term_allowed?(term) do
            {:ok, term}
          else
            {:error, :invalid_term}
          end
        rescue
          _error -> {:error, :invalid_term}
        end
    end
  end

  @doc "Returns true when `term` may cross a protocol boundary."
  @spec term_allowed?(wire_term()) :: boolean()
  def term_allowed?(term), do: term_allowed?(term, 0)

  defp term_allowed?(_term, depth) when depth > @max_depth, do: false

  defp term_allowed?(term, _depth) when is_binary(term) or is_number(term) or is_atom(term),
    do: true

  defp term_allowed?(list, depth) when is_list(list) do
    proper_list?(list) and Enum.all?(list, &term_allowed?(&1, depth + 1))
  end

  defp term_allowed?(tuple, depth) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.all?(&term_allowed?(&1, depth + 1))
  end

  defp term_allowed?(map, depth) when is_map(map) do
    Enum.all?(map, fn {key, value} ->
      term_allowed?(key, depth + 1) and term_allowed?(value, depth + 1)
    end)
  end

  defp term_allowed?(_term, _depth), do: false

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_other), do: false
end

defmodule Patchbay.Worker.Protocol.Stream do
  @moduledoc """
  Incremental decoder for length-prefixed frames.

  `feed/2` accepts arbitrary TCP chunks and returns every complete term while
  retaining an incomplete tail. The retained buffer never exceeds the maximum
  frame size plus one length prefix.
  """

  alias Patchbay.Worker.Protocol

  defstruct buffer: <<>>, max_frame: Protocol.default_max_frame()

  @type t :: %__MODULE__{buffer: binary(), max_frame: pos_integer()}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{max_frame: Keyword.get(opts, :max_frame, Protocol.default_max_frame())}
  end

  @doc """
  Adds `data` and returns all complete terms.

  Errors are terminal for the connection: the receiver should close it.
  """
  @spec feed(t(), binary()) :: {:ok, [Protocol.wire_term()], t()} | {:error, atom()}
  def feed(%__MODULE__{} = stream, data) when is_binary(data) do
    parse(%{stream | buffer: stream.buffer <> data}, [])
  end

  @doc """
  Blocks until at least one term is available or an error/timeout occurs.

  `timeout` is in milliseconds or `:infinity`.
  """
  @spec recv(port(), t(), timeout()) ::
          {:ok, [Protocol.wire_term()], t()} | {:error, term()}
  def recv(socket, %__MODULE__{} = stream, timeout \\ :infinity) do
    case parse(stream, []) do
      {:ok, [_ | _] = messages, stream} ->
        {:ok, messages, stream}

      {:ok, [], stream} ->
        deadline = deadline(timeout)
        recv_more(socket, stream, deadline)

      {:error, _reason} = error ->
        error
    end
  end

  defp recv_more(socket, stream, deadline) do
    case :gen_tcp.recv(socket, 0, remaining(deadline)) do
      {:ok, data} ->
        case feed(stream, data) do
          {:ok, [], stream} -> recv_more(socket, stream, deadline)
          {:ok, messages, stream} -> {:ok, messages, stream}
          {:error, _reason} = error -> error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout) when is_integer(timeout) and timeout >= 0, do: now_ms() + timeout

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - now_ms(), 0)

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp parse(%__MODULE__{buffer: <<>>} = stream, acc), do: {:ok, Enum.reverse(acc), stream}

  defp parse(%__MODULE__{buffer: <<size::unsigned-big-32, rest::binary>>} = stream, acc) do
    cond do
      size == 0 ->
        {:error, :empty_frame}

      size > stream.max_frame ->
        {:error, :frame_too_large}

      byte_size(rest) >= size ->
        <<payload::binary-size(size), tail::binary>> = rest

        case Protocol.decode_payload(payload, stream.max_frame) do
          {:ok, term} -> parse(%{stream | buffer: tail}, [term | acc])
          {:error, _reason} = error -> error
        end

      true ->
        {:ok, Enum.reverse(acc), stream}
    end
  end

  defp parse(%__MODULE__{} = stream, acc) do
    if byte_size(stream.buffer) > stream.max_frame + 4 do
      {:error, :frame_too_large}
    else
      {:ok, Enum.reverse(acc), stream}
    end
  end
end
