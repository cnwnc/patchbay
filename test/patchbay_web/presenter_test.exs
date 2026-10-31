defmodule PatchbayWeb.PresenterTest do
  use ExUnit.Case, async: true

  import PatchbayWeb.Presenter

  alias Patchbay.Event
  alias Patchbay.ToolHistory

  @base ~U[2026-01-01 00:05:05Z]
  @same_bucket ~U[2026-01-01 00:05:09Z]
  @next_bucket ~U[2026-01-01 00:05:10Z]

  defp event(id, at, type \\ :run_started) do
    %Event{
      id: id,
      sequence: 1,
      at: at,
      type: type,
      agent_id: "researcher",
      data: %{}
    }
  end

  describe "trace_points/2" do
    test "keeps positions fixed while now stays inside a bucket" do
      events = [
        event("old", ~U[2026-01-01 00:03:00Z]),
        event("new", ~U[2026-01-01 00:05:05Z], :tool_call)
      ]

      assert trace_points(events, @base) ==
               trace_points(events, @same_bucket)

      assert trace_points(events, @base) ==
               trace_points(events, ~U[2026-01-01 00:05:05.750Z])
    end

    test "shifts positions only after crossing a bucket boundary" do
      events = [
        event("old", ~U[2026-01-01 00:03:00Z]),
        event("new", ~U[2026-01-01 00:05:05Z], :tool_call)
      ]

      assert trace_points(events, @base) == "0,16 21,14 74,8 76,16"
      assert trace_points(events, @same_bucket) == "0,16 21,14 74,8 76,16"

      assert trace_points(events, @next_bucket) == "0,16 17,14 70,8 76,16"
    end

    test "parses DateTime and ISO8601 timestamps the same way" do
      datetime = event("dt", ~U[2026-01-01 00:03:00Z])
      iso = event("iso", "2026-01-01T00:03:00Z")
      offset = event("offset", "2026-01-01T01:03:00+01:00")

      for stamp <- [iso, offset] do
        assert trace_points([datetime], @base) == trace_points([stamp], @base)
      end
    end

    test "ignores events outside the quantized window" do
      inside = event("inside", ~U[2026-01-01 00:03:00Z])
      edge = event("edge", ~U[2026-01-01 00:02:10Z])
      outside = event("outside", ~U[2026-01-01 00:02:09Z])

      assert trace_points([inside], @base) == "0,16 21,14 76,16"
      assert trace_points([edge], @base) == "0,16 76,16"
      assert trace_points([outside], @base) == "0,16 76,16"
    end
  end

  describe "stream_items/2" do
    test "gives each event and tool row a stable id" do
      events = [
        event("evt-1", ~U[2026-01-01 00:05:00Z], :provider_error),
        event("evt-2", ~U[2026-01-01 00:05:01Z], :run_started)
      ]

      history = [
        %ToolHistory{
          sequence: "1",
          timestamp: "2026-01-01T00:05:02Z",
          call_id: "call-1",
          toolkit_id: "filesystem",
          tool_name: "read",
          arguments: "{}",
          status: "ok",
          truncated_result: "",
          transcript_event_id: "evt-2"
        }
      ]

      items = stream_items(events, history)

      assert Enum.map(items, & &1.id) == ["evt-1", "evt-2", "tool-call-1"]
      assert Enum.map(stream_items(events, history), & &1.id) == Enum.map(items, & &1.id)
    end
  end
end
