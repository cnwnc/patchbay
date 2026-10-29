defmodule Patchbay.ToolHistory do
  @moduledoc false

  alias Patchbay.ToolHistory.Decoder

  @us 0x1F
  @rs 0x1E

  @fields [
    :sequence,
    :timestamp,
    :call_id,
    :toolkit_id,
    :tool_name,
    :arguments,
    :status,
    :truncated_result,
    :transcript_event_id
  ]

  @enforce_keys @fields
  defstruct @fields

  @type field :: binary()

  @type t :: %__MODULE__{
          sequence: field(),
          timestamp: field(),
          call_id: field(),
          toolkit_id: field(),
          tool_name: field(),
          arguments: field(),
          status: field(),
          truncated_result: field(),
          transcript_event_id: field()
        }

  @type decode_error :: {:malformed_escape, byte()} | {:field_count, pos_integer()}

  @spec fields() :: [atom()]
  def fields, do: @fields

  @spec encode_record(t() | map()) :: binary()
  def encode_record(%__MODULE__{} = record), do: encode_record(Map.from_struct(record))

  def encode_record(record) when is_map(record) do
    values = Enum.map(@fields, &fetch_field!(record, &1))
    IO.iodata_to_binary([Enum.map_intersperse(values, @us, &escape/1), @rs])
  end

  @spec encode_records([t() | map()]) :: binary()
  def encode_records(records) when is_list(records) do
    records |> Enum.map(&encode_record/1) |> IO.iodata_to_binary()
  end

  @spec decode_stream(binary()) ::
          {:ok, [t()]} | {:incomplete, [t()], binary()} | {:error, decode_error()}
  def decode_stream(binary) when is_binary(binary) do
    case Decoder.push(Decoder.new(), binary) do
      {:ok, records, decoder} ->
        case Decoder.finish(decoder) do
          :ok -> {:ok, records}
          {:incomplete, rest} -> {:incomplete, records, rest}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec from_fields([field()]) :: t()
  def from_fields([
        sequence,
        timestamp,
        call_id,
        toolkit_id,
        tool_name,
        arguments,
        status,
        truncated_result,
        transcript_event_id
      ]) do
    %__MODULE__{
      sequence: sequence,
      timestamp: timestamp,
      call_id: call_id,
      toolkit_id: toolkit_id,
      tool_name: tool_name,
      arguments: arguments,
      status: status,
      truncated_result: truncated_result,
      transcript_event_id: transcript_event_id
    }
  end

  defp fetch_field!(record, field) do
    case Map.fetch(record, field) do
      {:ok, value} when is_binary(value) ->
        value

      {:ok, value} ->
        raise ArgumentError,
              "field #{inspect(field)} must be a binary, got: #{inspect(value)}"

      :error ->
        raise ArgumentError, "missing field #{inspect(field)}"
    end
  end

  defp escape(binary), do: escape(binary, [])

  defp escape(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp escape(<<?\\, rest::binary>>, acc), do: escape(rest, [<<"\\\\">> | acc])

  defp escape(<<@us, rest::binary>>, acc), do: escape(rest, [<<"\\", @us>> | acc])

  defp escape(<<@rs, rest::binary>>, acc), do: escape(rest, [<<"\\", @rs>> | acc])

  defp escape(binary, acc) do
    case :binary.match(binary, [<<?\\>>, <<@us>>, <<@rs>>]) do
      :nomatch ->
        escape(<<>>, [binary | acc])

      {position, 1} ->
        <<chunk::binary-size(position), rest::binary>> = binary
        escape(rest, [chunk | acc])
    end
  end
end
