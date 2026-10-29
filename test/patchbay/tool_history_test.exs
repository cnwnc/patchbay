defmodule Patchbay.ToolHistoryTest do
  use ExUnit.Case, async: true

  alias Patchbay.ToolHistory
  alias Patchbay.ToolHistory.Decoder
  alias Patchbay.ToolHistory.Writer

  @us 0x1F
  @rs 0x1E

  @base %{
    sequence: "1",
    timestamp: "1700000000",
    call_id: "call-1",
    toolkit_id: "toolkit",
    tool_name: "search",
    arguments: ~s({"q":"x"}),
    status: "ok",
    truncated_result: "result",
    transcript_event_id: "evt-1"
  }

  defp record(overrides \\ %{}) do
    struct!(ToolHistory, Map.merge(@base, overrides))
  end

  defp raw_record(fields) do
    Enum.map_intersperse(fields, @us, & &1) ++ [@rs]
  end

  defp blanks(first), do: [first, "", "", "", "", "", "", "", ""]

  describe "encode_record/1 and decode_stream/1" do
    test "roundtrips every field" do
      record = record()
      assert ToolHistory.decode_stream(ToolHistory.encode_record(record)) == {:ok, [record]}
    end

    test "uses US between fields and RS after each record" do
      fields = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
      expected = raw_record(fields)

      assert ToolHistory.encode_record(record(Map.new(Enum.zip(ToolHistory.fields(), fields)))) ==
               IO.iodata_to_binary(expected)
    end

    test "preserves empty fields" do
      record = record(%{arguments: "", truncated_result: ""})
      assert {:ok, [^record]} = ToolHistory.decode_stream(ToolHistory.encode_record(record))
    end

    test "handles arbitrary bytes" do
      bytes = <<0, 1, 2, 0x7F, 0x80, 0xFF, @us, @rs, ?\\, ?a, 0, @us, @rs, ?\\>>

      record =
        record(%{
          sequence: bytes,
          timestamp: bytes,
          call_id: bytes,
          toolkit_id: bytes,
          tool_name: bytes,
          arguments: bytes,
          status: bytes,
          truncated_result: bytes,
          transcript_event_id: bytes
        })

      assert {:ok, [decoded]} = ToolHistory.decode_stream(ToolHistory.encode_record(record))
      assert decoded == record
    end

    test "decodes multiple records in order" do
      records = for n <- 1..5, do: record(%{sequence: Integer.to_string(n)})
      assert ToolHistory.decode_stream(ToolHistory.encode_records(records)) == {:ok, records}
    end

    test "accepts plain maps" do
      map = Map.new(@base)
      assert ToolHistory.decode_stream(ToolHistory.encode_record(map)) == {:ok, [record()]}
    end

    test "empty stream" do
      assert ToolHistory.decode_stream("") == {:ok, []}
    end

    test "raises for non-binary fields" do
      assert_raise ArgumentError, fn ->
        ToolHistory.encode_record(Map.put(Map.new(@base), :status, :ok))
      end
    end

    test "raises for missing fields" do
      assert_raise ArgumentError, fn ->
        ToolHistory.encode_record(Map.delete(Map.new(@base), :status))
      end
    end
  end

  describe "escaping" do
    test "escapes separators and backslashes" do
      field = <<"a", @us, "b", @rs, ?\\>>

      encoded =
        record(%{arguments: field})
        |> ToolHistory.encode_record()

      assert encoded =~ <<"a\\", @us, "b\\", @rs, "\\\\">>
      assert {:ok, [decoded]} = ToolHistory.decode_stream(encoded)
      assert decoded.arguments == field
    end

    test "even backslashes before US leave it as a separator" do
      raw = <<"a\\\\", @us, @us, @us, @us, @us, @us, @us, @us, @rs>>

      assert {:ok, [decoded]} = ToolHistory.decode_stream(raw)
      assert decoded.sequence == <<"a\\">>
      assert Enum.drop(ToolHistory.fields(), 1) |> Enum.all?(&(Map.fetch!(decoded, &1) == ""))
    end

    test "odd backslash before US escapes the separator" do
      raw = <<"a\\", @us, "b", @us, @us, @us, @us, @us, @us, @us, @us, @rs>>

      assert {:ok, [decoded]} = ToolHistory.decode_stream(raw)
      assert decoded.sequence == <<"a", @us, "b">>
      assert decoded.timestamp == ""
    end

    test "three backslashes before US produce one backslash and an escaped separator" do
      raw = <<"a\\\\\\", @us, "b", @us, @us, @us, @us, @us, @us, @us, @us, @rs>>

      assert {:ok, [decoded]} = ToolHistory.decode_stream(raw)
      assert decoded.sequence == <<"a\\", @us, "b">>
    end

    test "escaped RS stays inside the field" do
      raw = <<"a\\", @rs, "b", @us, @us, @us, @us, @us, @us, @us, @us, @rs>>

      assert {:ok, [decoded]} = ToolHistory.decode_stream(raw)
      assert decoded.sequence == <<"a", @rs, "b">>
    end

    test "rejects unknown escapes" do
      raw = raw_record(blanks(<<"a\\x">>)) |> IO.iodata_to_binary()
      assert ToolHistory.decode_stream(raw) == {:error, {:malformed_escape, ?x}}
    end

    test "rejects unknown escapes in an incomplete record" do
      assert ToolHistory.decode_stream(<<"a\\x">>) == {:error, {:malformed_escape, ?x}}
    end

    test "escapes every backslash so ordinary trailing bytes roundtrip" do
      field = <<"a\\qb">>

      encoded =
        record(%{arguments: field})
        |> ToolHistory.encode_record()

      assert encoded =~ <<"a\\\\qb">>
      assert {:ok, [decoded]} = ToolHistory.decode_stream(encoded)
      assert decoded.arguments == field
    end
  end

  describe "incomplete and malformed records" do
    test "reports a trailing record without RS" do
      complete = record(%{sequence: "1"})
      partial = record(%{sequence: "2"})

      stream =
        ToolHistory.encode_record(complete) <>
          binary_part(
            ToolHistory.encode_record(partial),
            0,
            byte_size(ToolHistory.encode_record(partial)) - 1
          )

      assert {:incomplete, [^complete], rest} = ToolHistory.decode_stream(stream)

      assert rest ==
               binary_part(
                 ToolHistory.encode_record(partial),
                 0,
                 byte_size(ToolHistory.encode_record(partial)) - 1
               )
    end

    test "reports a stream that is only a partial record" do
      assert {:incomplete, [], <<"1", @us, "2">>} = ToolHistory.decode_stream(<<"1", @us, "2">>)
    end

    test "reports a dangling escape as incomplete" do
      assert {:incomplete, [], "\\"} = ToolHistory.decode_stream("\\")
    end

    test "rejects too few fields" do
      raw = Enum.map_intersperse(["1", "2"], @us, & &1) ++ [@rs]
      assert ToolHistory.decode_stream(IO.iodata_to_binary(raw)) == {:error, {:field_count, 2}}
    end

    test "rejects too many fields" do
      raw =
        raw_record(["1", "2", "3", "4", "5", "6", "7", "8", "9", "10"]) |> IO.iodata_to_binary()

      assert ToolHistory.decode_stream(raw) == {:error, {:field_count, 10}}
    end

    test "rejects an empty record" do
      assert ToolHistory.decode_stream(<<@rs>>) == {:error, {:field_count, 1}}
    end
  end

  describe "incremental decoder" do
    test "emits records when the terminating RS arrives" do
      record = record()
      stream = ToolHistory.encode_record(record)
      decoder = Decoder.new()

      {decoder, emitted} =
        Enum.reduce(:binary.bin_to_list(stream), {decoder, []}, fn byte, {decoder, emitted} ->
          assert {:ok, records, decoder} = Decoder.push(decoder, <<byte>>)
          {decoder, emitted ++ records}
        end)

      assert emitted == [record]
      assert Decoder.finish(decoder) == :ok
    end

    test "handles chunks split inside an escape sequence" do
      record = record(%{arguments: <<"a", @us, "b", ?\\>>})
      stream = ToolHistory.encode_record(record)
      {position, 1} = :binary.match(stream, "\\")
      split = position + 1
      decoder = Decoder.new()

      assert {:ok, [], decoder} = Decoder.push(decoder, binary_part(stream, 0, split))

      assert {:ok, [^record], decoder} =
               Decoder.push(decoder, binary_part(stream, split, byte_size(stream) - split))

      assert Decoder.finish(decoder) == :ok
    end

    test "handles a dangling backslash across pushes" do
      decoder = Decoder.new()
      assert {:ok, [], decoder} = Decoder.push(decoder, "\\")
      assert Decoder.finish(decoder) == {:incomplete, "\\"}
      assert {:ok, [], decoder} = Decoder.push(decoder, "\\")
      assert Decoder.finish(decoder) == {:incomplete, "\\\\"}
    end

    test "keeps incomplete trailing bytes after complete records" do
      complete = record(%{sequence: "1"})
      stream = ToolHistory.encode_record(complete) <> "partial"
      decoder = Decoder.new()

      assert {:ok, [^complete], decoder} = Decoder.push(decoder, stream)
      assert Decoder.finish(decoder) == {:incomplete, "partial"}
    end

    test "rejects malformed escapes while pushing chunks" do
      decoder = Decoder.new()
      assert Decoder.push(decoder, "a\\q") == {:error, {:malformed_escape, ?q}}
    end

    test "accepts empty chunks" do
      decoder = Decoder.new()
      assert {:ok, [], decoder} = Decoder.push(decoder, "")
      assert Decoder.finish(decoder) == :ok
    end
  end

  describe "writer" do
    setup do
      path =
        Path.join(
          System.tmp_dir!(),
          "patchbay-tool-history-#{System.unique_integer([:positive])}.bin"
        )

      on_exit(fn -> File.rm(path) end)
      %{path: path}
    end

    test "appends records to a file", %{path: path} do
      records = [record(%{sequence: "1"}), record(%{sequence: "2"}), record(%{sequence: "3"})]

      assert {:ok, writer} = Writer.open(path)
      assert Writer.append(writer, Enum.at(records, 0)) == :ok
      assert Writer.append_many(writer, Enum.drop(records, 1)) == :ok
      assert Writer.close(writer) == :ok

      assert ToolHistory.decode_stream(File.read!(path)) == {:ok, records}
    end

    test "reopening continues the existing stream", %{path: path} do
      first = record(%{sequence: "1"})
      second = record(%{sequence: "2"})

      assert {:ok, writer} = Writer.open(path)
      assert Writer.append(writer, first) == :ok
      assert Writer.close(writer) == :ok

      assert {:ok, writer} = Writer.open(path)
      assert Writer.append(writer, second) == :ok
      assert Writer.close(writer) == :ok

      assert ToolHistory.decode_stream(File.read!(path)) == {:ok, [first, second]}
    end

    test "reopening truncates a torn final record", %{path: path} do
      first = record(%{sequence: "1", arguments: <<"a", @rs, "b">>})
      torn = <<"partial\\", @rs, " tail">>
      second = record(%{sequence: "2"})

      File.write!(path, ToolHistory.encode_record(first) <> torn)

      assert {:ok, writer} = Writer.open(path)
      assert Writer.append(writer, second) == :ok
      assert Writer.close(writer) == :ok

      assert ToolHistory.decode_stream(File.read!(path)) == {:ok, [first, second]}
    end

    test "reopening a file with only a torn record starts empty", %{path: path} do
      record = record(%{sequence: "1"})

      File.write!(path, <<"partial\\", @rs, " tail">>)

      assert {:ok, writer} = Writer.open(path)
      assert Writer.append(writer, record) == :ok
      assert Writer.close(writer) == :ok

      assert ToolHistory.decode_stream(File.read!(path)) == {:ok, [record]}
    end
  end
end
