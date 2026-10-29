defmodule Patchbay.Worker.ProtocolTest do
  use ExUnit.Case, async: true

  alias Patchbay.Worker.Protocol
  alias Patchbay.Worker.Protocol.Stream

  test "round trips protocol terms" do
    term = {:result, %{call_id: "abc", status: :ok, output: "hello", exit_status: 0}}

    assert {:ok, frame} = Protocol.encode(term)
    assert {:ok, ^term} = Protocol.decode_frame(frame)
  end

  test "rejects terms that cannot cross a protocol boundary" do
    assert {:error, :invalid_term} = Protocol.encode(self())
    assert {:error, :invalid_term} = Protocol.encode(make_ref())
    assert {:error, :invalid_term} = Protocol.encode(fn -> :ok end)
    assert {:error, :invalid_term} = Protocol.encode([1 | 2])
  end

  test "rejects deeply nested terms" do
    nested = Enum.reduce(1..100, [], fn _index, acc -> [acc] end)
    refute Protocol.term_allowed?(nested)
    assert {:error, :invalid_term} = Protocol.encode(nested)
  end

  test "enforces the frame limit" do
    assert {:error, :term_too_large} =
             Protocol.encode("a term larger than ten bytes", max_frame: 10)
  end

  test "rejects compressed payloads before decompression" do
    payload = :erlang.term_to_binary(%{a: String.duplicate("x", 1000)}, compressed: 9)
    assert <<131, 80, _::binary>> = payload
    frame = <<byte_size(payload)::unsigned-big-32, payload::binary>>
    assert {:error, :compressed_term} = Protocol.decode_frame(frame)
  end

  test "rejects malformed frames" do
    assert {:error, :empty_frame} = Protocol.decode_frame(<<0::unsigned-big-32>>)
    assert {:error, :frame_size_mismatch} = Protocol.decode_frame(<<5::unsigned-big-32, "abc">>)
    assert {:error, :truncated_frame} = Protocol.decode_frame(<<1, 2, 3>>)

    assert {:error, :frame_too_large} =
             Protocol.decode_frame(<<99::unsigned-big-32, "x">>, max_frame: 10)
  end

  test "stream handles fragmented frames" do
    {:ok, frame} = Protocol.encode({:hello, %{role: :worker, version: 1}})

    {messages, stream} =
      frame
      |> :binary.bin_to_list()
      |> Enum.reduce({[], Stream.new()}, fn byte, {messages, stream} ->
        {:ok, new_messages, stream} = Stream.feed(stream, <<byte>>)
        {messages ++ new_messages, stream}
      end)

    assert messages == [{:hello, %{role: :worker, version: 1}}]
    assert stream.buffer == <<>>
  end

  test "stream handles coalesced frames" do
    {:ok, first} = Protocol.encode({:ping, %{id: "1"}})
    {:ok, second} = Protocol.encode({:pong, %{id: "1"}})

    assert {:ok, [{:ping, %{id: "1"}}, {:pong, %{id: "1"}}], %Stream{buffer: <<>>}} =
             Stream.feed(Stream.new(), first <> second)
  end

  test "stream rejects a complete frame with an invalid payload" do
    payload = :binary.copy("x", 100)
    frame = <<100::unsigned-big-32, payload::binary>>
    assert {:error, :invalid_term} = Stream.feed(Stream.new(max_frame: 100), frame)
  end

  test "stream rejects an announced frame beyond the limit" do
    assert {:error, :frame_too_large} =
             Stream.feed(Stream.new(max_frame: 10), <<11::unsigned-big-32>>)
  end
end
