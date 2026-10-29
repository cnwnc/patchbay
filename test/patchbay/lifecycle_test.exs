defmodule Patchbay.LifecycleTest do
  use ExUnit.Case, async: true

  alias Patchbay.Lifecycle
  alias Patchbay.Run

  defp new_lifecycle(kind \\ :one_shot) do
    {:ok, lifecycle} = Lifecycle.new(%{agent_id: "agent-1", kind: kind})
    lifecycle
  end

  defp activation(n, run_id \\ "run-1", overrides \\ %{}) do
    Map.merge(
      %{
        id: run_id,
        attempt_id: "attempt-#{n}",
        instance_id: "instance-#{n}",
        started_at: "t#{n}"
      },
      overrides
    )
  end

  defp started_lifecycle(kind \\ :one_shot) do
    lifecycle = new_lifecycle(kind)
    {:ok, lifecycle} = Lifecycle.activate(lifecycle, activation(1))
    {:ok, lifecycle} = Lifecycle.ready(lifecycle, "instance-1")
    lifecycle
  end

  test "fresh activation creates one run, attempt, and instance" do
    lifecycle = new_lifecycle()

    assert Lifecycle.recovery(lifecycle) == :fresh

    assert {:ok, lifecycle} = Lifecycle.activate(lifecycle, activation(1))

    run = Lifecycle.current_run(lifecycle)
    assert run.id == "run-1"
    assert run.status == :initializing
    assert Run.attempt_count(run) == 1

    instance = Lifecycle.get_instance(lifecycle, "instance-1")
    assert instance.state == :starting
    assert instance.run_id == "run-1"
    assert instance.attempt_id == "attempt-1"
    assert Lifecycle.active_attempt(lifecycle).id == "attempt-1"

    assert {:error, {:run_active, "run-1"}} = Lifecycle.activate(lifecycle, activation(2))
    assert {:error, {:run_open, "run-1"}} = Lifecycle.start_run(lifecycle, activation(2))
  end

  test "activation continues a run started without attempts" do
    lifecycle = new_lifecycle(:scheduled)

    assert {:ok, lifecycle} = Lifecycle.start_run(lifecycle, activation(1))
    run = Lifecycle.current_run(lifecycle)
    assert run.id == "run-1"
    assert run.status == :initializing
    assert Run.attempt_count(run) == 0
    assert Lifecycle.recovery(lifecycle) == {:resume, "run-1"}

    assert {:ok, lifecycle} = Lifecycle.activate(lifecycle, activation(2))

    run = Lifecycle.current_run(lifecycle)
    assert run.id == "run-1"
    assert run.status == :initializing
    assert Run.attempt_count(run) == 1
    assert Lifecycle.active_attempt(lifecycle).id == "attempt-2"
    assert Lifecycle.get_instance(lifecycle, "instance-2").state == :starting
  end

  test "ready marks both the instance and its run runnable and blocks another activation" do
    lifecycle = new_lifecycle()
    {:ok, lifecycle} = Lifecycle.activate(lifecycle, activation(1))

    assert {:ok, lifecycle} = Lifecycle.ready(lifecycle, "instance-1")

    assert Lifecycle.current_run(lifecycle).status == :running
    assert Lifecycle.get_instance(lifecycle, "instance-1").state == :ready
    assert Lifecycle.recovery(lifecycle) == {:refuse, "run-1"}

    assert {:error, {:run_active, "run-1"}} = Lifecycle.activate(lifecycle, activation(2))
  end

  test "interrupted scheduled work resumes the same run with another attempt" do
    lifecycle = started_lifecycle(:scheduled)

    assert {:ok, lifecycle} = Lifecycle.interrupt(lifecycle, :worker_lost, "t2")

    assert Lifecycle.recovery(lifecycle) == {:resume, "run-1"}
    assert Lifecycle.current_run(lifecycle).status == :interrupted
    assert Lifecycle.get_instance(lifecycle, "instance-1").state == :stopped
    assert Lifecycle.get_instance(lifecycle, "instance-1").stop_reason == :worker_lost

    assert {:ok, lifecycle} = Lifecycle.activate(lifecycle, activation(2))

    run = Lifecycle.current_run(lifecycle)
    assert run.id == "run-1"
    assert run.status == :initializing
    assert Run.attempt_count(run) == 2
    assert [%{status: :interrupted}, %{status: :active}] = run.attempts
    assert map_size(lifecycle.runs) == 1

    assert Lifecycle.get_instance(lifecycle, "instance-2").attempt_id == "attempt-2"
    assert {:ok, lifecycle} = Lifecycle.ready(lifecycle, "instance-2")
    assert Lifecycle.current_run(lifecycle).status == :running
  end

  test "a terminal result closes the run and the next activation starts a new run" do
    lifecycle = started_lifecycle(:scheduled)

    assert {:ok, lifecycle} = Lifecycle.complete(lifecycle, %{"status-message" => "done"}, "t2")

    completed = Lifecycle.current_run(lifecycle)
    assert completed.status == :completed
    assert completed.result == %{"status-message" => "done"}
    assert Lifecycle.get_instance(lifecycle, "instance-1").state == :stopped
    assert Lifecycle.get_instance(lifecycle, "instance-1").stop_reason == :completed
    assert Lifecycle.recovery(lifecycle) == :fresh

    assert {:ok, lifecycle} = Lifecycle.activate(lifecycle, activation(1, "run-2"))

    assert Lifecycle.current_run(lifecycle).id == "run-2"
    assert Run.attempt_count(Lifecycle.current_run(lifecycle)) == 1
    assert map_size(lifecycle.runs) == 2
    assert Lifecycle.get_run(lifecycle, "run-1").status == :completed
  end

  test "failure is terminal and is not undone by a restart policy" do
    lifecycle = started_lifecycle(:perpetual)

    assert {:ok, lifecycle} = Lifecycle.fail(lifecycle, :model_refused, "t2")

    failed = Lifecycle.current_run(lifecycle)
    assert failed.status == :failed
    assert failed.failure == :model_refused
    assert Lifecycle.get_instance(lifecycle, "instance-1").stop_reason == :model_refused
    assert Lifecycle.recovery(lifecycle) == :fresh

    assert {:ok, lifecycle} = Lifecycle.activate(lifecycle, activation(1, "run-2"))
    assert Lifecycle.current_run(lifecycle).id == "run-2"
    assert Run.open?(Lifecycle.current_run(lifecycle))
  end

  test "cancellation is terminal" do
    lifecycle = started_lifecycle(:perpetual)

    assert {:ok, lifecycle} = Lifecycle.cancel(lifecycle, :operator_stop, "t2")
    assert Lifecycle.current_run(lifecycle).status == :cancelled
    assert Lifecycle.get_instance(lifecycle, "instance-1").stop_reason == :operator_stop
    assert Lifecycle.recovery(lifecycle) == :fresh
  end

  test "a perpetual run remains open across waits and ordinary restarts" do
    lifecycle = started_lifecycle(:perpetual)
    assert Lifecycle.perpetual?(lifecycle)

    assert {:ok, lifecycle} = Lifecycle.wait(lifecycle, :next_event)
    assert Lifecycle.current_run(lifecycle).status == :waiting
    assert Lifecycle.current_run(lifecycle).wait_reason == :next_event
    assert Lifecycle.open_run?(lifecycle)
    assert Lifecycle.recovery(lifecycle) == {:refuse, "run-1"}

    assert {:ok, lifecycle} = Lifecycle.wake(lifecycle)
    assert Lifecycle.current_run(lifecycle).status == :running

    assert {:ok, lifecycle} = Lifecycle.interrupt(lifecycle, :ordinary_restart, "t2")
    assert Lifecycle.current_run(lifecycle).status == :interrupted
    assert Lifecycle.recovery(lifecycle) == {:resume, "run-1"}

    assert {:ok, lifecycle} = Lifecycle.activate(lifecycle, activation(2))
    run = Lifecycle.current_run(lifecycle)
    assert run.id == "run-1"
    assert Run.attempt_count(run) == 2
    assert Lifecycle.open_run?(lifecycle)
    assert Lifecycle.get_instance(lifecycle, "instance-2").attempt_id == "attempt-2"

    assert {:ok, lifecycle} = Lifecycle.ready(lifecycle, "instance-2")
    assert {:ok, lifecycle} = Lifecycle.complete(lifecycle, %{})
    assert Lifecycle.current_run(lifecycle).status == :completed
    assert Lifecycle.recovery(lifecycle) == :fresh
  end

  test "an explicit new run supersedes an open perpetual run" do
    lifecycle = started_lifecycle(:perpetual)

    assert {:ok, lifecycle} =
             Lifecycle.start_new_run(lifecycle, activation(2, "run-2", %{at: "t2"}))

    old = Lifecycle.get_run(lifecycle, "run-1")
    assert old.status == :cancelled
    assert old.cancellation == :superseded
    assert Lifecycle.get_instance(lifecycle, "instance-1").state == :stopped
    assert Lifecycle.get_instance(lifecycle, "instance-1").stop_reason == :superseded

    new = Lifecycle.current_run(lifecycle)
    assert new.id == "run-2"
    assert new.status == :initializing
    assert Run.attempt_count(new) == 1
    assert Lifecycle.get_instance(lifecycle, "instance-2").state == :starting
  end

  test "context folds keep run and attempt identity and leave instances running" do
    lifecycle = started_lifecycle()
    before = Lifecycle.current_run(lifecycle)

    assert {:ok, lifecycle} =
             Lifecycle.fold_context(lifecycle, %{reason: :compaction, at: "t2"})

    after_fold = Lifecycle.current_run(lifecycle)
    assert after_fold.id == before.id
    assert after_fold.attempts == before.attempts
    assert Run.attempt_count(after_fold) == 1
    assert Run.context_revision(after_fold) == 2
    assert Lifecycle.get_instance(lifecycle, "instance-1").state == :ready

    assert {:ok, lifecycle} =
             Lifecycle.fold_context(lifecycle, %{reason: :manual_fold, at: "t3"})

    assert Run.context_revision(Lifecycle.current_run(lifecycle)) == 3
    assert map_size(lifecycle.runs) == 1
    assert map_size(lifecycle.instances) == 1
  end

  test "context folds work while interrupted and fail after terminal" do
    lifecycle = started_lifecycle()
    {:ok, lifecycle} = Lifecycle.interrupt(lifecycle, :worker_lost, "t2")

    assert {:ok, lifecycle} =
             Lifecycle.fold_context(lifecycle, %{reason: :compaction, at: "t3"})

    run = Lifecycle.current_run(lifecycle)
    assert run.status == :interrupted
    assert Run.context_revision(run) == 2

    {:ok, lifecycle} = Lifecycle.complete(lifecycle, %{}, "t4")
    assert {:error, :terminal} = Lifecycle.fold_context(lifecycle, %{reason: :manual_fold})
  end
end
