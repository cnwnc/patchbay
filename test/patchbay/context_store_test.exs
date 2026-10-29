defmodule Patchbay.ContextStoreTest do
  use ExUnit.Case, async: true

  alias Patchbay.ContextStore
  alias Patchbay.Definition.Context
  alias Patchbay.Provider.{Message, ToolCall}

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "patchbay-context-store-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    %{state_dir: tmp}
  end

  test "stores provider messages with private directory and file modes", %{state_dir: state_dir} do
    message = Message.user("hello")

    assert :ok = ContextStore.append_run(state_dir, "alpha", "run-1", :started)
    assert :ok = ContextStore.append_message(state_dir, "alpha", "run-1", "attempt-1", message)

    path = ContextStore.path(state_dir, "alpha")
    dir_stat = File.stat!(ContextStore.dir(state_dir))
    file_stat = File.stat!(path)

    assert Bitwise.band(dir_stat.mode, 0o777) == 0o700
    assert Bitwise.band(file_stat.mode, 0o777) == 0o600

    assert {:ok, [{:run, run}, {:message, record}]} = ContextStore.read(state_dir, "alpha")
    assert run.run_id == "run-1"
    assert run.status == "started"
    assert record.run_id == "run-1"
    assert record.message == message
  end

  test "round-trips assistant tool calls and tool results", %{state_dir: state_dir} do
    call = ToolCall.new("call-1", "echo", %{"text" => "hi"})
    assistant = Message.assistant("looking", tool_calls: [call])
    tool = Message.tool("call-1", "echo:hi", name: "echo")

    assert :ok = ContextStore.append_message(state_dir, "alpha", "run-1", nil, assistant)
    assert :ok = ContextStore.append_message(state_dir, "alpha", "run-1", nil, tool)

    assert {:ok, entries} = ContextStore.read(state_dir, "alpha")
    messages = for {:message, %{message: message}} <- entries, do: message

    assert messages == [assistant, tool]
  end

  test "sanitize drops a trailing unanswered tool turn and orphaned results" do
    call = ToolCall.new("call-1", "echo", %{"text" => "hi"})
    other = ToolCall.new("call-2", "echo", %{"text" => "next"})

    messages = [
      Message.user("start"),
      Message.assistant("working", tool_calls: [call]),
      Message.tool("call-1", "echo:hi"),
      Message.assistant("more", tool_calls: [other]),
      Message.tool("orphan", "ignored")
    ]

    assert ContextStore.sanitize(messages) == [
             Message.user("start"),
             Message.assistant("working", tool_calls: [call]),
             Message.tool("call-1", "echo:hi")
           ]
  end

  test "sanitize drops duplicate or invalid tool call ids" do
    duplicate = [
      ToolCall.new("same", "echo", %{}),
      ToolCall.new("same", "echo", %{})
    ]

    messages = [
      Message.user("start"),
      Message.assistant("working", tool_calls: duplicate),
      Message.tool("same", "result")
    ]

    assert ContextStore.sanitize(messages) == [Message.user("start")]
  end

  test "recovery_mode follows context policy and lifecycle defaults" do
    assert ContextStore.recovery_mode(%Context{}, :one_shot, :closed) == :reset
    assert ContextStore.recovery_mode(%Context{}, :perpetual, :closed) == :restore_all

    assert ContextStore.recovery_mode(%Context{prior_runs: "queryable"}, :one_shot, :closed) ==
             :restore_all

    assert ContextStore.recovery_mode(
             %Context{restore_interrupted: "checkpoint"},
             :one_shot,
             :interrupted
           ) == :restore_run

    assert ContextStore.recovery_mode(%Context{between_runs: "reset"}, :perpetual, :closed) ==
             :reset

    assert ContextStore.recovery_mode(%Context{between_runs: "handoff"}, :one_shot, :interrupted) ==
             :restore_all
  end

  test "scheduled interrupted runs restore the current run by default" do
    assert ContextStore.recovery_mode(%Context{}, :scheduled, :interrupted) == :restore_run

    assert ContextStore.recovery_mode(
             %Context{prior_runs: "queryable"},
             :scheduled,
             :interrupted
           ) == :restore_all

    assert ContextStore.recovery_mode(
             %Context{restore_interrupted: "reset", prior_runs: "queryable"},
             :scheduled,
             :interrupted
           ) == :reset
  end

  test "sanitize keeps the final tool result when an in-flight result was recorded first" do
    call = ToolCall.new("call-1", "echo", %{"text" => "hi"})

    messages = [
      Message.user("start"),
      Message.assistant("working", tool_calls: [call]),
      Message.tool("call-1", ~s({"status":"in_flight"})),
      Message.tool("call-1", "echo:hi")
    ]

    assert ContextStore.sanitize(messages) == [
             Message.user("start"),
             Message.assistant("working", tool_calls: [call]),
             Message.tool("call-1", "echo:hi")
           ]
  end

  test "restore keeps only the interrupted run unless the policy keeps prior runs",
       %{state_dir: state_dir} do
    older = Message.user("older")
    current = Message.user("current")

    assert :ok = ContextStore.append_run(state_dir, "alpha", "run-1", :completed)
    assert :ok = ContextStore.append_message(state_dir, "alpha", "run-1", nil, older)
    assert :ok = ContextStore.append_run(state_dir, "alpha", "run-2", :started)
    assert :ok = ContextStore.append_message(state_dir, "alpha", "run-2", nil, current)

    assert {:ok, entries} = ContextStore.read(state_dir, "alpha")

    assert {_, [%Message{content: "current"}]} =
             ContextStore.restore(
               entries,
               %Context{restore_interrupted: "checkpoint"},
               :one_shot,
               :fresh,
               "run-3"
             )

    assert {_, [%Message{content: "older"}, %Message{content: "current"}]} =
             ContextStore.restore(
               entries,
               %Context{between_runs: "keep"},
               :one_shot,
               :fresh,
               "run-3"
             )
  end

  test "append repairs a partial trailing frame", %{state_dir: state_dir} do
    assert :ok =
             ContextStore.append_message(state_dir, "alpha", "run-1", nil, Message.user("one"))

    path = ContextStore.path(state_dir, "alpha")
    File.write!(path, File.read!(path) <> <<0, 0, 0, 40, "partial">>)

    assert :ok =
             ContextStore.append_message(state_dir, "alpha", "run-1", nil, Message.user("two"))

    assert {:ok, entries} = ContextStore.read(state_dir, "alpha")
    contents = for {:message, %{message: message}} <- entries, do: message.content
    assert contents == ["one", "two"]
  end

  test "replace atomically swaps the context file with encoded entries", %{state_dir: state_dir} do
    assert :ok = ContextStore.append_run(state_dir, "alpha", "run-1", :started)

    assert :ok =
             ContextStore.append_message(state_dir, "alpha", "run-1", nil, Message.user("old"))

    entries =
      [{:run, %{run_id: "run-2", status: "started", at: "2026-01-01T00:00:00Z"}}] ++
        ContextStore.message_entries([Message.user("new")],
          run_id: "run-2",
          attempt_id: "attempt-2",
          at: "2026-01-01T00:00:00Z"
        )

    assert :ok = ContextStore.replace(state_dir, "alpha", entries)
    assert {:ok, decoded} = ContextStore.read(state_dir, "alpha")
    assert decoded == entries

    stat = File.stat!(ContextStore.path(state_dir, "alpha"))
    assert Bitwise.band(stat.mode, 0o777) == 0o600
    assert File.ls!(ContextStore.dir(state_dir)) == ["alpha.pbc"]
  end

  test "message entries encode into the framed context format", %{state_dir: state_dir} do
    message = Message.user("hello")
    entries = ContextStore.message_entries([message], run_id: "run-1", at: "2026-01-01T00:00:00Z")

    assert {:ok, data} = ContextStore.encode_entries(entries)
    assert {:ok, ^entries} = ContextStore.decode_stream(data)

    assert :ok = ContextStore.replace(state_dir, "alpha", entries)
    assert {:ok, data} = ContextStore.snapshot(state_dir, "alpha")
    assert {:ok, ^entries} = ContextStore.decode_stream(data)
  end

  test "archive paths stay under the agent directory and reject invalid names",
       %{state_dir: state_dir} do
    archive_dir = ContextStore.archive_dir(state_dir, "alpha")
    assert archive_dir == Path.join([state_dir, "context", "alpha", "archive"])

    generation = "20260101T000000000Z-abc.pbc.zst"
    archive_path = ContextStore.archive_path(state_dir, "alpha", generation)
    assert archive_path == Path.join(archive_dir, generation)

    assert ContextStore.archive_metadata_path(state_dir, "alpha", generation) ==
             Path.join(archive_dir, "20260101T000000000Z-abc.pbc.json")

    assert_raise ArgumentError, fn ->
      ContextStore.archive_path(state_dir, "alpha", "../x.pbc.zst")
    end

    assert_raise ArgumentError, fn -> ContextStore.archive_path(state_dir, "alpha", "x.pbc") end
    assert_raise ArgumentError, fn -> ContextStore.archive_dir(state_dir, "../alpha") end
  end
end
