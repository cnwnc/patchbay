defmodule Patchbay.ToolHistoryFuzzTest do
  use ExUnit.Case, async: true

  alias Patchbay.ToolHistory
  alias Patchbay.ToolHistory.Decoder

  @us 0x1F
  @rs 0x1E

  setup do
    :rand.seed(:exsss, {101, 202, 303})
    :ok
  end

  defp random_bytes(0), do: ""

  defp random_bytes(count) do
    for _ <- 1..count, into: <<>>, do: <<random_byte()>>
  end

  defp random_byte do
    case :rand.uniform(8) do
      1 -> @us
      2 -> @rs
      3 -> ?\\
      4 -> 0
      5 -> 0xFF
      _ -> :rand.uniform(256) - 1
    end
  end

  defp random_binary do
    random_bytes(:rand.uniform(64) - 1)
  end

  defp random_record(sequence) do
    values =
      Map.new(ToolHistory.fields(), fn field ->
        {field, random_binary()}
      end)

    struct!(ToolHistory, Map.put(values, :sequence, Integer.to_string(sequence)))
  end

  defp random_chunks(binary) do
    do_random_chunks(binary, [])
  end

  defp do_random_chunks("", acc), do: Enum.reverse(acc)

  defp do_random_chunks(binary, acc) do
    size = min(byte_size(binary), :rand.uniform(17) - 1)
    <<chunk::binary-size(size), rest::binary>> = binary
    do_random_chunks(rest, [chunk | acc])
  end

  defp push_all(chunks) do
    chunks
    |> Enum.reduce({Decoder.new(), []}, fn chunk, {decoder, records} ->
      assert {:ok, new_records, decoder} = Decoder.push(decoder, chunk)
      {decoder, records ++ new_records}
    end)
  end

  test "generated records roundtrip through the stream codec" do
    records = for sequence <- 1..250, do: random_record(sequence)
    stream = ToolHistory.encode_records(records)

    assert ToolHistory.decode_stream(stream) == {:ok, records}

    for record <- records do
      encoded = ToolHistory.encode_record(record)
      assert {:ok, [decoded]} = ToolHistory.decode_stream(encoded)
      assert decoded == record
      assert ToolHistory.encode_record(decoded) == encoded
    end
  end

  test "generated streams decode across random chunk boundaries" do
    records = for sequence <- 1..200, do: random_record(sequence)
    stream = ToolHistory.encode_records(records)

    {decoder, decoded} = push_all(random_chunks(stream))
    assert decoded == records
    assert Decoder.finish(decoder) == :ok
  end

  test "arbitrary byte streams do not crash the decoder" do
    for _ <- 1..400 do
      binary = random_binary()

      case ToolHistory.decode_stream(binary) do
        {:ok, records} ->
          assert Enum.all?(records, &valid_record?/1)

        {:incomplete, records, rest} ->
          assert Enum.all?(records, &valid_record?/1)
          assert is_binary(rest) and rest != ""

        {:error, {:malformed_escape, byte}} ->
          assert byte in 0..255
          refute byte in [?\\, @us, @rs]

        {:error, {:field_count, count}} ->
          assert count in 1..10
      end
    end
  end

  test "mutated valid streams still produce a well-formed result" do
    base = ToolHistory.encode_records(for sequence <- 1..10, do: random_record(sequence))

    for _ <- 1..300 do
      mutated = mutate(base)
      result = ToolHistory.decode_stream(mutated)

      assert match?({:ok, _}, result) or match?({:incomplete, _, _}, result) or
               match?({:error, _}, result)

      case result do
        {:ok, records} ->
          assert Enum.all?(records, &valid_record?/1)

        {:incomplete, records, rest} ->
          assert Enum.all?(records, &valid_record?/1)
          assert is_binary(rest)

        {:error, _reason} ->
          :ok
      end
    end
  end

  defp mutate(binary) do
    position = :rand.uniform(byte_size(binary)) - 1
    <<prefix::binary-size(position), _byte, suffix::binary>> = binary
    <<prefix::binary, random_byte(), suffix::binary>>
  end

  defp valid_record?(record) do
    Enum.all?(ToolHistory.fields(), fn field ->
      is_binary(Map.fetch!(record, field))
    end)
  end
end
