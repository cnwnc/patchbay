defmodule Patchbay.SchedulerTest.Definitions do
  def start_link do
    Agent.start_link(fn -> [] end)
  end

  def put(server, definitions) do
    Agent.update(server, fn _ -> definitions end)
  end

  def definitions(server) do
    Agent.get(server, & &1)
  end
end

defmodule Patchbay.SchedulerTest.Runtime do
  def start_link do
    Agent.start_link(fn -> %{statuses: %{}, starts: [], start_error: nil, start_hook: nil} end)
  end

  def set_status(server, id, status) do
    Agent.update(server, &put_in(&1.statuses[id], status))
  end

  def set_start_error(server, reason) do
    Agent.update(server, &%{&1 | start_error: reason})
  end

  def set_start_hook(server, fun) when is_function(fun, 1) do
    Agent.update(server, &%{&1 | start_hook: fun})
  end

  def starts(server) do
    Agent.get(server, &Enum.reverse(&1.starts))
  end

  def start_agent(server, id, opts) do
    Agent.get_and_update(server, fn state ->
      if is_function(state.start_hook, 1), do: state.start_hook.(id)

      case Map.get(state.statuses, id, :stopped) do
        status when status in [:starting, :running, :stopping] ->
          {{:error, {:not_startable, status}}, state}

        _status when not is_nil(state.start_error) ->
          {{:error, state.start_error}, state}

        _status ->
          state = %{
            state
            | statuses: Map.put(state.statuses, id, :running),
              starts: [{id, opts} | state.starts]
          }

          {{:ok, %{agent_id: id, status: :running}}, state}
      end
    end)
  end

  def get_agent(server, id) do
    status = Agent.get(server, &Map.get(&1.statuses, id, :stopped))
    {:ok, %{agent_id: id, status: status}}
  end
end

defmodule Patchbay.SchedulerTest do
  use ExUnit.Case, async: true

  alias Patchbay.Definition
  alias Patchbay.Scheduler
  alias Patchbay.SchedulerTest.{Definitions, Runtime}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "patchbay-scheduler-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    {:ok, definitions} = Definitions.start_link()
    {:ok, runtime} = Runtime.start_link()

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, definitions: definitions, runtime: runtime}
  end

  test "fires a due scheduled agent and persists last and next fire", context do
    set_definitions(context, [definition("daily", schedule: "0 7 * * *")])
    clock = start_clock(~U[2026-01-01 06:00:00Z])
    scheduler = start_scheduler(context, clock: clock)

    assert %{fired: [], skipped: [], failed: []} = Scheduler.tick(scheduler)

    next_at = unix(~U[2026-01-01 07:00:00Z])

    assert %{
             schedule: "0 7 * * *",
             last_fire: nil,
             next_fire: ^next_at
           } = Scheduler.entries(scheduler)["daily"]

    set_clock(clock, ~U[2026-01-01 07:00:00Z])

    assert %{fired: [%{agent_id: "daily"}]} = Scheduler.tick(scheduler)
    assert Runtime.starts(context.runtime) == [{"daily", []}]

    last_fire = unix(~U[2026-01-01 07:00:00Z])
    following = unix(~U[2026-01-02 07:00:00Z])

    assert %{last_fire: ^last_fire, next_fire: ^following} =
             Scheduler.entries(scheduler)["daily"]

    assert %{"entries" => %{"daily" => persisted}} = read_state(context)
    assert persisted["last_fire"] == unix(~U[2026-01-01 07:00:00Z])
    assert persisted["next_fire"] == unix(~U[2026-01-02 07:00:00Z])
  end

  test "persists the claimed occurrence before dispatching the agent", context do
    set_definitions(context, [definition("daily", schedule: "0 7 * * *")])
    clock = start_clock(~U[2026-01-01 06:00:00Z])
    scheduler = start_scheduler(context, clock: clock)
    assert %{fired: []} = Scheduler.tick(scheduler)

    parent = self()

    Runtime.set_start_hook(context.runtime, fn agent_id ->
      send(parent, {:start_dispatch, agent_id, read_state(context)})
    end)

    set_clock(clock, ~U[2026-01-01 07:00:00Z])
    assert %{fired: [%{agent_id: "daily"}]} = Scheduler.tick(scheduler)

    assert_receive {:start_dispatch, "daily", %{"entries" => %{"daily" => persisted}}}
    assert persisted["last_fire"] == unix(~U[2026-01-01 07:00:00Z])
    assert persisted["next_fire"] == unix(~U[2026-01-02 07:00:00Z])
  end

  test "a failed dispatch keeps the claimed occurrence from retrying", context do
    set_definitions(context, [definition("daily", schedule: "0 7 * * *")])
    Runtime.set_start_error(context.runtime, :spawn_failed)
    clock = start_clock(~U[2026-01-01 06:00:00Z])
    scheduler = start_scheduler(context, clock: clock)
    assert %{fired: []} = Scheduler.tick(scheduler)

    set_clock(clock, ~U[2026-01-01 07:00:00Z])

    assert %{failed: [%{agent_id: "daily", reason: :spawn_failed}]} =
             Scheduler.tick(scheduler)

    assert %{last_fire: last_fire, next_fire: next_fire} = Scheduler.entries(scheduler)["daily"]
    assert last_fire == unix(~U[2026-01-01 07:00:00Z])
    assert next_fire == unix(~U[2026-01-02 07:00:00Z])

    assert %{fired: [], failed: []} = Scheduler.tick(scheduler)
    assert Runtime.starts(context.runtime) == []
  end

  test "overlap forbid skips a due fire while the agent is active", context do
    set_definitions(context, [
      definition("daily", schedule: "0 7 * * *", overlap: "forbid")
    ])

    Runtime.set_status(context.runtime, "daily", :running)
    clock = start_clock(~U[2026-01-01 06:00:00Z])
    scheduler = start_scheduler(context, clock: clock)

    set_clock(clock, ~U[2026-01-01 07:00:00Z])

    assert %{fired: [], skipped: [%{agent_id: "daily", reason: :overlap}]} =
             Scheduler.tick(scheduler)

    assert Runtime.starts(context.runtime) == []

    following = unix(~U[2026-01-02 07:00:00Z])
    assert %{last_fire: nil, next_fire: ^following} = Scheduler.entries(scheduler)["daily"]
  end

  test "catch-up once fires one missed occurrence after downtime", context do
    set_definitions(context, [
      definition("hourly", schedule: "0 * * * *", catch_up: "once")
    ])

    state_dir = Path.join(context.root, "state")
    clock = start_clock(~U[2026-01-01 10:30:00Z])
    scheduler = start_scheduler(context, clock: clock, state_dir: state_dir)

    assert %{fired: []} = Scheduler.tick(scheduler)
    GenServer.stop(scheduler)

    set_clock(clock, ~U[2026-01-01 14:30:00Z])
    restarted = start_scheduler(context, clock: clock, state_dir: state_dir)
    assert Scheduler.next_fire(restarted, "hourly") == {:ok, unix(~U[2026-01-01 11:00:00Z])}

    assert %{fired: [%{agent_id: "hourly"}]} = Scheduler.tick(restarted)
    assert Runtime.starts(context.runtime) == [{"hourly", []}]

    last_fire = unix(~U[2026-01-01 14:30:00Z])
    following = unix(~U[2026-01-01 15:00:00Z])

    assert %{last_fire: ^last_fire, next_fire: ^following} =
             Scheduler.entries(restarted)["hourly"]

    assert %{fired: []} = Scheduler.tick(restarted)
    assert Runtime.starts(context.runtime) == [{"hourly", []}]
  end

  test "catch-up none skips missed occurrences but still advances next", context do
    set_definitions(context, [
      definition("hourly", schedule: "0 * * * *", catch_up: "none")
    ])

    state_dir = Path.join(context.root, "state")
    clock = start_clock(~U[2026-01-01 10:30:00Z])
    scheduler = start_scheduler(context, clock: clock, state_dir: state_dir)

    assert %{fired: []} = Scheduler.tick(scheduler)
    GenServer.stop(scheduler)

    set_clock(clock, ~U[2026-01-01 14:30:00Z])
    restarted = start_scheduler(context, clock: clock, state_dir: state_dir)

    assert %{fired: [], skipped: [%{agent_id: "hourly", reason: :catch_up}]} =
             Scheduler.tick(restarted)

    assert Runtime.starts(context.runtime) == []
    assert Scheduler.next_fire(restarted, "hourly") == {:ok, unix(~U[2026-01-01 15:00:00Z])}
  end

  test "only scheduled definitions are tracked", context do
    set_definitions(context, [
      definition("once", kind: "one-shot"),
      definition("forever", kind: "perpetual"),
      definition("daily", schedule: "0 7 * * *")
    ])

    clock = start_clock(~U[2026-01-01 06:00:00Z])
    scheduler = start_scheduler(context, clock: clock)

    assert Map.keys(Scheduler.entries(scheduler)) == ["daily"]

    set_clock(clock, ~U[2026-01-01 07:00:00Z])
    assert %{fired: [%{agent_id: "daily"}]} = Scheduler.tick(scheduler)
    assert Runtime.starts(context.runtime) == [{"daily", []}]
  end

  @tag capture_log: true
  test "reports an invalid schedule without tracking the agent", context do
    set_definitions(context, [definition("broken", schedule: "every morning")])
    clock = start_clock(~U[2026-01-01 06:00:00Z])
    scheduler = start_scheduler(context, clock: clock)

    assert Scheduler.entries(scheduler) == %{}

    assert %{invalid: [%{agent_id: "broken", reason: {:invalid_schedule, _reason}}]} =
             Scheduler.tick(scheduler)

    assert Runtime.starts(context.runtime) == []
  end

  defp set_definitions(context, definitions) do
    Definitions.put(context.definitions, definitions)
  end

  defp start_scheduler(context, opts) do
    state_dir = Keyword.get(opts, :state_dir, Path.join(context.root, "state"))
    clock = opts |> Keyword.fetch!(:clock) |> clock_fun()

    opts =
      Keyword.merge(
        [
          definitions: {Definitions, context.definitions},
          runtime: {Runtime, context.runtime},
          state_dir: state_dir,
          auto_tick: false,
          name: nil
        ],
        opts
      )
      |> Keyword.put(:clock, clock)

    {:ok, scheduler} = Scheduler.start_link(opts)

    on_exit(fn ->
      if Process.alive?(scheduler) do
        try do
          GenServer.stop(scheduler)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    scheduler
  end

  defp start_clock(datetime) do
    {:ok, clock} = Agent.start_link(fn -> unix(datetime) end)
    clock
  end

  defp clock_fun(clock) when is_pid(clock), do: fn -> Agent.get(clock, & &1) end
  defp clock_fun(clock) when is_function(clock, 0), do: clock
  defp clock_fun(datetime), do: fn -> unix(datetime) end

  defp set_clock(clock, datetime) do
    Agent.update(clock, fn _ -> unix(datetime) end)
  end

  defp unix(datetime), do: DateTime.to_unix(datetime, :second)

  defp read_state(context) do
    context.root
    |> Path.join("state/scheduler.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp definition(id, opts) do
    kind = Keyword.get(opts, :kind, "scheduled")
    schedule = Keyword.get(opts, :schedule, "0 7 * * *")

    lifecycle = ["kind = \"#{kind}\""]

    lifecycle =
      if kind == "scheduled" do
        lifecycle
        |> Kernel.++(["schedule = \"#{schedule}\""])
        |> maybe_line("overlap", Keyword.get(opts, :overlap))
        |> maybe_line("catch-up", Keyword.get(opts, :catch_up))
      else
        lifecycle
      end

    body =
      Enum.join(
        [
          "format-version = 1",
          "id = \"#{id}\"",
          "",
          "[model]",
          "name = \"test-model\"",
          "",
          "[lifecycle]"
        ] ++ lifecycle,
        "\n"
      )

    assert {:ok, definition} = Definition.parse(body)
    definition
  end

  defp maybe_line(lines, _key, nil), do: lines
  defp maybe_line(lines, key, value), do: lines ++ ["#{key} = \"#{value}\""]
end
