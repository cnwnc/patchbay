defmodule Patchbay.EventTest do
  use ExUnit.Case, async: true

  alias Patchbay.Event

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "patchbay-event-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    %{tmp: tmp}
  end

  test "new/1 validates the event vocabulary and sanitizes data" do
    assert {:ok, event} =
             Event.new(%{
               type: :run_started,
               agent_id: "agent",
               sequence: 1,
               data: %{reason: :worker_lost, tuple: {1, 2}, nested: %{ok: true}}
             })

    assert event.data == %{
             "reason" => "worker_lost",
             "tuple" => [1, 2],
             "nested" => %{"ok" => true}
           }

    assert {:error, {:invalid_event_type, :unknown}} =
             Event.new(%{type: :unknown, agent_id: "agent", sequence: 1})

    assert {:error, {:invalid_agent_id, "../escape"}} =
             Event.new(%{type: :run_started, agent_id: "../escape", sequence: 1})

    assert {:error, {:invalid_event_sequence, 0}} =
             Event.new(%{type: :run_started, agent_id: "agent", sequence: 0})
  end

  test "append/read roundtrip keeps sequence order and reports the last sequence", context do
    path = Event.path(context.tmp, "agent")
    assert path == Path.join([context.tmp, "events", "agent.pbe"])

    first = event(:run_started, 1)
    second = event(:agent_started, 2)

    assert :ok = Event.append(path, first)
    assert :ok = Event.append(path, second)

    assert {:ok, [read_first, read_second]} = Event.read(path)
    assert read_first == first
    assert read_second == second
    assert {:ok, 2} = Event.last_sequence(path)
  end

  test "append/1 repairs a torn tail before writing", context do
    path = Event.path(context.tmp, "agent")
    first = event(:run_started, 1)
    second = event(:agent_started, 2)

    assert :ok = Event.append(path, first)
    File.write!(path, <<1_000::unsigned-big-32, "torn">>, [:append])

    assert :ok = Event.append(path, second)
    assert {:ok, [^first, ^second]} = Event.read(path)
  end

  test "read/1 preserves a partial trailing frame", context do
    path = Event.path(context.tmp, "agent")
    first = event(:run_started, 1)

    assert :ok = Event.append(path, first)

    partial = <<1_000::unsigned-big-32, "incomplete">>
    File.write!(path, partial, [:append])

    assert {:incomplete, [^first], ^partial} = Event.read(path)
  end

  test "missing files read as empty and invalid agent ids are refused", context do
    assert {:ok, []} = Event.read(Path.join(context.tmp, "missing.pbe"))
    assert {:ok, 0} = Event.last_sequence(Path.join(context.tmp, "missing.pbe"))
    assert_raise ArgumentError, fn -> Event.path(context.tmp, "../escape") end
  end

  defp event(type, sequence) do
    {:ok, event} =
      Event.new(%{
        type: type,
        agent_id: "agent",
        sequence: sequence,
        run_id: "run-1",
        definition_revision: 1,
        data: %{reason: :test}
      })

    event
  end
end
