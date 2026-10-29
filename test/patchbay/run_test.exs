defmodule Patchbay.RunTest do
  use ExUnit.Case, async: true

  alias Patchbay.Run
  alias Patchbay.Run.{Attempt, Context}

  defp new_run(attrs \\ %{}) do
    {:ok, run} = Run.new(Map.merge(%{id: "run-1", agent_id: "agent-1"}, attrs))
    run
  end

  defp with_attempt(run, id \\ "attempt-1", instance_id \\ "instance-1") do
    {:ok, run} = Run.begin_attempt(run, %{id: id, instance_id: instance_id})
    run
  end

  defp ready_run(attrs \\ %{}) do
    run = new_run(attrs)
    run = with_attempt(run)
    {:ok, run} = Run.mark_ready(run, "attempt-1")
    run
  end

  test "a new run starts initializing with context revision one" do
    run = new_run(%{definition_revision: 4, toolkit_ids: ["memory-file-io"]})

    assert run.status == :initializing
    assert Run.open?(run)
    refute Run.terminal?(run)
    refute Run.perpetual?(run)
    assert run.definition_revision == 4
    assert run.toolkit_ids == ["memory-file-io"]
    assert Run.context_revision(run) == 1
    assert run.attempts == []
  end

  test "perpetual is a run kind, not a separate run state" do
    assert Run.perpetual?(new_run(%{perpetual: true}))
    assert Run.perpetual?(new_run(%{kind: :perpetual}))

    assert {:error, {:invalid_kind, :continuous}} =
             Run.new(%{id: "r", agent_id: "a", kind: :continuous})
  end

  test "an attempt is active before the run is ready, and only one attempt is active" do
    run = new_run() |> with_attempt()
    [attempt] = run.attempts

    assert run.status == :initializing
    assert attempt.status == :active
    assert attempt.ordinal == 1
    assert Attempt.active?(attempt)

    assert {:error, :attempt_active} =
             Run.begin_attempt(run, %{id: "attempt-2", instance_id: "instance-2"})

    assert {:ok, run} = Run.mark_ready(run, "attempt-1")
    assert run.status == :running
    assert {:error, {:attempt_mismatch, "attempt-1"}} = Run.mark_ready(run, "attempt-2")
  end

  test "interruption keeps the run open and resume adds an attempt to the same run" do
    run = ready_run()

    assert {:ok, run} = Run.interrupt(run, :worker_lost, "t1")

    assert run.status == :interrupted
    assert Run.open?(run)
    refute Run.terminal?(run)
    assert Run.active_attempt(run) == nil
    [first] = run.attempts
    assert first.status == :interrupted
    assert first.reason == :worker_lost
    assert first.ended_at == "t1"

    assert {:ok, run} = Run.resume(run, %{id: "attempt-2", instance_id: "instance-2"})
    assert run.id == "run-1"
    assert run.status == :initializing
    assert Run.attempt_count(run) == 2

    assert [^first, second] = run.attempts
    assert second.ordinal == 2
    assert second.status == :active

    assert {:ok, run} = Run.mark_ready(run, "attempt-2")
    assert run.status == :running
  end

  test "resume is only available from interruption" do
    run = ready_run()

    assert {:error, {:not_interrupted, :running}} =
             Run.resume(run, %{id: "attempt-2", instance_id: "instance-2"})
  end

  test "waiting is an open run state and wake preserves the active attempt" do
    run = ready_run()

    assert {:ok, run} = Run.wait(run, :external_event)
    assert run.status == :waiting
    assert run.wait_reason == :external_event
    assert Run.open?(run)
    assert %Attempt{id: "attempt-1"} = Run.active_attempt(run)

    assert {:ok, run} = Run.wake(run)
    assert run.status == :running
    assert run.wait_reason == nil
  end

  test "completion is terminal and closes the active attempt" do
    run = ready_run()

    assert {:ok, run} = Run.complete(run, %{"pull-request" => "https://example.test/pr/1"}, "t1")

    assert run.status == :completed
    assert Run.terminal?(run)
    refute Run.open?(run)
    assert run.result == %{"pull-request" => "https://example.test/pr/1"}
    assert run.ended_at == "t1"
    [attempt] = run.attempts
    assert attempt.status == :completed

    assert {:error, :terminal} = Run.complete(run, %{})
    assert {:error, :terminal} = Run.interrupt(run, :late)

    assert {:error, {:not_interrupted, :completed}} =
             Run.resume(run, %{id: "attempt-2", instance_id: "instance-2"})
  end

  test "invalid completion results leave the run active" do
    run = ready_run()

    assert {:error, {:invalid_result, :not_a_map}} = Run.complete(run, :not_a_map)
    assert run.status == :running
    assert %Attempt{status: :active} = Run.active_attempt(run)
  end

  test "failure and cancellation are terminal with separate payloads" do
    failed = ready_run() |> then(fn run -> elem(Run.fail(run, :model_refused, "t1"), 1) end)
    assert failed.status == :failed
    assert failed.failure == :model_refused
    assert Run.terminal?(failed)
    assert hd(failed.attempts).status == :failed
    assert hd(failed.attempts).reason == :model_refused

    cancelled = ready_run() |> then(fn run -> elem(Run.cancel(run, :operator_stop, "t2"), 1) end)
    assert cancelled.status == :cancelled
    assert cancelled.cancellation == :operator_stop
    assert Run.terminal?(cancelled)
    assert hd(cancelled.attempts).status == :cancelled
  end

  test "a perpetual run remains open across wait and interruption" do
    run = ready_run(%{kind: :perpetual})
    assert Run.perpetual?(run)

    {:ok, run} = Run.wait(run, :next_event)
    assert run.status == :waiting

    {:ok, run} = Run.wake(run)
    {:ok, run} = Run.interrupt(run, :ordinary_restart)
    assert run.status == :interrupted
    assert Run.open?(run)

    {:ok, run} = Run.resume(run, %{id: "attempt-2", instance_id: "instance-2"})
    assert run.id == "run-1"
    assert Run.attempt_count(run) == 2
    assert Run.open?(run)
  end

  test "context compaction seals a revision without changing run or attempts" do
    run = ready_run()

    assert {:ok, folded} =
             Run.fold_context(run, %{reason: :compaction, at: "t1", archive: "000001.jsonl.zst"})

    assert folded.id == run.id
    assert folded.status == :running
    assert folded.attempts == run.attempts
    assert Run.attempt_count(folded) == 1
    assert Run.context_revision(folded) == 2

    assert [sealed] = Context.sealed_revisions(folded.context)
    assert sealed.revision == 1
    assert sealed.reason == :compaction
    assert sealed.at == "t1"
    assert sealed.archive == "000001.jsonl.zst"
    assert folded.context.folds == 1
  end

  test "manual folds advance the revision within the same run" do
    run = ready_run()

    {:ok, run} = Run.fold_context(run, %{reason: :compaction})
    {:ok, run} = Run.fold_context(run, %{reason: :manual_fold, at: "t2"})

    assert Run.context_revision(run) == 3
    assert Enum.map(Context.sealed_revisions(run.context), & &1.revision) == [1, 2]

    assert Enum.map(Context.sealed_revisions(run.context), & &1.reason) == [
             :compaction,
             :manual_fold
           ]

    assert Run.attempt_count(run) == 1
  end

  test "context folds are allowed while interrupted and rejected after a terminal result" do
    run = ready_run()
    {:ok, run} = Run.interrupt(run, :worker_lost)

    assert {:ok, run} = Run.fold_context(run, %{reason: :compaction})
    assert run.status == :interrupted
    assert Run.context_revision(run) == 2

    {:ok, run} = Run.complete(run, %{})
    assert {:error, :terminal} = Run.fold_context(run, %{reason: :manual_fold})
    assert Run.context_revision(run) == 2
  end

  test "unknown fold reasons are rejected without advancing the revision" do
    run = ready_run()

    assert {:error, {:invalid_reason, :rollover}} =
             Run.fold_context(run, %{reason: :rollover})

    assert Run.context_revision(run) == 1
    assert Context.sealed_revisions(run.context) == []
  end
end
