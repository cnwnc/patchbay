defmodule Patchbay.ToolHistory.Decoder do
  @moduledoc false

  alias Patchbay.ToolHistory

  @us 0x1F
  @rs 0x1E

  defstruct fields: [], current: [], raw: [], pending: ""

  @type t :: %__MODULE__{
          fields: [binary()],
          current: [binary()],
          raw: [binary()],
          pending: binary()
        }

  @type reason :: ToolHistory.decode_error()

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec push(t(), binary()) :: {:ok, [ToolHistory.t()], t()} | {:error, reason()}
  def push(%__MODULE__{pending: pending} = decoder, chunk) when is_binary(chunk) do
    scan(pending <> chunk, %{decoder | pending: ""}, [])
  end

  @spec finish(t()) :: :ok | {:incomplete, binary()}
  def finish(%__MODULE__{} = decoder) do
    rest = IO.iodata_to_binary([Enum.reverse(decoder.raw), decoder.pending])

    if rest == "", do: :ok, else: {:incomplete, rest}
  end

  defp scan(data, decoder, records) do
    case :binary.match(data, [<<@us>>, <<@rs>>, <<?\\>>]) do
      :nomatch ->
        {:ok, Enum.reverse(records), append_bytes(decoder, data)}

      {position, 1} ->
        <<chunk::binary-size(position), byte, rest::binary>> = data
        decoder = append_bytes(decoder, chunk)

        case byte do
          @us ->
            with {:ok, decoder} <- end_field(decoder) do
              scan(rest, %{decoder | raw: [<<@us>> | decoder.raw]}, records)
            end

          @rs ->
            end_record(rest, decoder, records)

          ?\\ ->
            scan_escape(rest, decoder, records)
        end
    end
  end

  defp scan_escape(<<>>, decoder, records) do
    {:ok, Enum.reverse(records), %{decoder | pending: "\\"}}
  end

  defp scan_escape(<<escaped, rest::binary>>, decoder, records) do
    case escaped do
      ?\\ -> scan(rest, append_escape(decoder, "\\", <<?\\, escaped>>), records)
      @us -> scan(rest, append_escape(decoder, <<@us>>, <<?\\, escaped>>), records)
      @rs -> scan(rest, append_escape(decoder, <<@rs>>, <<?\\, escaped>>), records)
      # The writer escapes every backslash, so an unknown escape can only come
      # from a stream this format did not produce. Reject it; the format stays
      # limited to these three sequences.
      _ -> {:error, {:malformed_escape, escaped}}
    end
  end

  defp end_record(rest, decoder, records) do
    with {:ok, decoder} <- end_field(decoder) do
      case Enum.reverse(decoder.fields) do
        fields when length(fields) == 9 ->
          record = ToolHistory.from_fields(fields)
          decoder = %{decoder | fields: [], current: [], raw: [], pending: ""}
          scan(rest, decoder, [record | records])

        fields ->
          {:error, {:field_count, length(fields)}}
      end
    end
  end

  defp end_field(decoder) do
    field = decoder.current |> Enum.reverse() |> IO.iodata_to_binary()
    fields = [field | decoder.fields]

    if length(fields) > 9 do
      {:error, {:field_count, length(fields)}}
    else
      {:ok, %{decoder | fields: fields, current: []}}
    end
  end

  defp append_bytes(decoder, ""), do: decoder

  defp append_bytes(decoder, bytes) do
    %{decoder | current: [bytes | decoder.current], raw: [bytes | decoder.raw]}
  end

  defp append_escape(decoder, decoded, raw) do
    %{
      decoder
      | current: [decoded | decoder.current],
        raw: [raw | decoder.raw]
    }
  end
end
