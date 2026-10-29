defmodule Patchbay.Provider.SSETest do
  use ExUnit.Case, async: true

  alias Patchbay.Provider.SSE

  test "buffers an incomplete line across fragments" do
    state = SSE.new()

    assert {[], state} = SSE.push(state, "data: hel")
    assert {[], state} = SSE.push(state, "lo\n")
    assert {["hello"], _state} = SSE.push(state, "\n")
  end

  test "joins multi-line data and ignores comments and non-data fields" do
    payload =
      ": keep-alive\r\nevent: message\r\nid: 1\r\nretry: 100\r\n" <>
        "data: first\r\ndata: second\r\n\r\n"

    assert {["first\nsecond"], _state} = SSE.push(SSE.new(), payload)
  end

  test "strips one leading space from data values" do
    assert {["plain", " padded"], _state} =
             SSE.push(SSE.new(), "data:plain\n\ndata:  padded\n\n")
  end

  test "treats a data field without a colon as an empty payload" do
    assert {[""], _state} = SSE.push(SSE.new(), "data\n\n")
  end

  test "emits no event for a blank line without data" do
    assert {[], _state} = SSE.push(SSE.new(), "\n\r\n: comment\n\n")
  end

  test "handles multiple events in one fragment and arbitrary byte boundaries" do
    payload = "data: alpha\n\ndata: beta\n\n"

    {events, _state} =
      payload
      |> bytes()
      |> Enum.reduce({[], SSE.new()}, fn byte, {events, state} ->
        {new_events, state} = SSE.push(state, byte)
        {events ++ new_events, state}
      end)

    assert events == ["alpha", "beta"]
  end

  test "finish flushes a payload without a trailing blank line" do
    {[], state} = SSE.push(SSE.new(), "data: tail")

    assert {["tail"], _state} = SSE.finish(state)
  end

  defp bytes(binary) do
    for <<byte <- binary>>, do: <<byte>>
  end
end
