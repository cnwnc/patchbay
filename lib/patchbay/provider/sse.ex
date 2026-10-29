defmodule Patchbay.Provider.SSE do
  @moduledoc """
  Incremental parser for server-sent events.

  `push/2` accepts arbitrary body fragments and returns the data payloads of
  any complete events. A payload is the `data:` field value with multiple lines
  joined by `\\n`, as the SSE specification requires. Comments and non-data
  fields are ignored. Incomplete lines stay buffered until the next fragment,
  so chunk boundaries do not need to align with event boundaries.
  """

  defstruct buffer: "", data: []

  @type t :: %__MODULE__{buffer: binary(), data: [binary()]}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Feeds a body fragment into the parser.

  Returns the payloads of events completed by this fragment and the updated
  parser state.
  """
  @spec push(t(), binary()) :: {[binary()], t()}
  def push(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    buffer = state.buffer <> chunk

    case String.split(buffer, "\n") do
      [_incomplete] ->
        {[], %{state | buffer: buffer}}

      parts ->
        {complete, [rest]} = Enum.split(parts, -1)
        {events, data} = Enum.reduce(complete, {[], state.data}, &line/2)

        {Enum.reverse(events), %{state | buffer: rest, data: data}}
    end
  end

  @doc """
  Flushes a final payload when the stream ends without a trailing blank line.
  """
  @spec finish(t()) :: {[binary()], t()}
  def finish(%__MODULE__{} = state) do
    push(state, "\n\n")
  end

  defp line(line, {events, data}) do
    case String.trim_trailing(line, "\r") do
      "" -> flush(events, data)
      ":" <> _comment -> {events, data}
      field -> field(field, events, data)
    end
  end

  defp flush(events, []), do: {events, []}

  defp flush(events, data) do
    payload = data |> Enum.reverse() |> Enum.join("\n")
    {[payload | events], []}
  end

  defp field(field, events, data) do
    case String.split(field, ":", parts: 2) do
      ["data", value] -> {events, [strip_space(value) | data]}
      ["data"] -> {events, ["" | data]}
      _other -> {events, data}
    end
  end

  defp strip_space(" " <> value), do: value
  defp strip_space(value), do: value
end
