defmodule Patchbay.ContextCompactionTest.Provider do
  @behaviour Patchbay.Provider

  @impl true
  def complete(request, opts) do
    fun = Keyword.fetch!(opts, :respond)
    fun.(request)
  end
end

defmodule Patchbay.ContextCompactionTest do
  use ExUnit.Case, async: true

  alias Patchbay.ContextCompaction
  alias Patchbay.ContextCompaction.{Split, Tokens, Zstd}
  alias Patchbay.ContextCompactionTest.Provider
  alias Patchbay.ContextStore
  alias Patchbay.Definition.Context
  alias Patchbay.Provider.{Error, Message, Response, ToolCall}

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "patchbay-compaction-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    %{state_dir: tmp}
  end

  test "policy resolves threshold and target from context config" do
    {context, []} = Context.from_map(%{"threshold" => 120, "target" => 40}, [])
    assert context.threshold == 120
    assert context.target == 40

    {context, []} = Context.from_map(%{"compact-threshold" => 90, "compact-target" => 30}, [])
    assert context.threshold == 90
    assert context.target == 30

    policy = ContextCompaction.policy(%{context: context})
    assert policy.enabled?
    assert policy.threshold == 90
    assert policy.target == 30

    refute ContextCompaction.policy(%Context{}).enabled?

    clamped = ContextCompaction.policy(%Context{threshold: 10, target: 100})
    assert clamped.target == 9

    messages = [Message.user(String.duplicate("x", 600))]
    assert ContextCompaction.due?(messages, %Context{threshold: 50, target: 10})
    refute ContextCompaction.due?(messages, %Context{threshold: 10_000, target: 10})
  end

  test "estimate is conservative for text and tool calls" do
    plain = Message.user(String.duplicate("a", 300))
    call = ToolCall.new("call-1", "echo", %{"text" => String.duplicate("b", 300)})
    with_call = Message.assistant("done", tool_calls: [call])

    assert Tokens.estimate([plain]) >= 100
    assert Tokens.estimate([with_call]) > Tokens.estimate([plain])
  end

  test "archives the old current context before replacing it", %{state_dir: state_dir} do
    messages = seeded_messages(state_dir, "alpha")
    before = File.read!(ContextStore.path(state_dir, "alpha"))

    respond = fn _request -> {:ok, %Response{content: "  compacted summary  "}} end

    assert {:ok, result} =
             ContextCompaction.maybe_compact(state_dir, "alpha", messages,
               context: %Context{threshold: 40, target: 1},
               run_id: "run-1",
               provider_opts: [provider: Provider, respond: respond]
             )

    assert result.summary.content == "compacted summary"
    assert result.summary.name == "context-summary"
    assert result.messages == [result.summary | result.retained]
    assert result.dropped != []

    archive_files =
      Path.wildcard(Path.join(ContextStore.archive_dir(state_dir, "alpha"), "*.pbc.zst"))

    assert [archive_path] = archive_files

    metadata_path = Path.rootname(archive_path, ".zst") <> ".json"
    assert File.exists?(metadata_path)

    extracted = Path.join(state_dir, "extracted.pbc")
    assert :ok = Zstd.decompress_file(archive_path, extracted)
    assert File.read!(extracted) == before

    assert {:ok, metadata} = metadata_path |> File.read!() |> Jason.decode()
    assert metadata["generation"] == Path.basename(archive_path)
    assert metadata["agent_id"] == "alpha"
    assert metadata["run_id"] == "run-1"
    assert metadata["sha256"] == Base.encode16(:crypto.hash(:sha256, before), case: :lower)
    assert metadata["original_bytes"] == byte_size(before)
    assert metadata["compressed_bytes"] == File.stat!(archive_path).size
    assert metadata["dropped_messages"] == length(result.dropped)
    assert metadata["retained_messages"] == length(result.retained)

    assert {:ok, entries} = ContextStore.read(state_dir, "alpha")
    stored = for {:message, %{message: message}} <- entries, do: message
    assert stored == result.messages
    assert hd(stored).content == "compacted summary"
    assert List.last(stored).content == "recent"

    entries = File.ls!(ContextStore.archive_dir(state_dir, "alpha"))
    refute Enum.any?(entries, &String.starts_with?(&1, "."))
  end

  test "retains complete tool call and result turns", %{state_dir: state_dir} do
    first = ToolCall.new("call-1", "echo", %{"text" => "first"})
    second = ToolCall.new("call-2", "echo", %{"text" => "second"})
    third = ToolCall.new("call-3", "echo", %{"text" => "third"})

    messages = [
      Message.user("start"),
      Message.assistant("older", tool_calls: [first]),
      Message.tool("call-1", "result-1", name: "echo"),
      Message.user("middle"),
      Message.assistant("recent", tool_calls: [second, third]),
      Message.tool("call-2", "result-2", name: "echo"),
      Message.tool("call-3", "result-3", name: "echo")
    ]

    seed(state_dir, "alpha", messages, "run-1")

    assert {:ok, result} =
             ContextCompaction.compact(state_dir, "alpha", messages,
               target: 0,
               run_id: "run-1",
               provider_opts: [
                 provider: Provider,
                 respond: fn _request -> {:ok, %Response{content: "summary"}} end
               ]
             )

    assert result.retained == [
             Message.assistant("recent", tool_calls: [second, third]),
             Message.tool("call-2", "result-2", name: "echo"),
             Message.tool("call-3", "result-3", name: "echo")
           ]

    assert result.dropped == Enum.take(messages, 4)
    assert ContextStore.sanitize(result.messages) == result.messages
    assert_no_orphan_calls(result.messages)
  end

  test "a split never separates a retained tool result from its call" do
    call = ToolCall.new("call-1", "echo", %{"text" => String.duplicate("x", 80)})

    messages = [
      Message.user("start"),
      Message.assistant("working", tool_calls: [call]),
      Message.tool("call-1", String.duplicate("y", 80), name: "echo"),
      Message.user("tail")
    ]

    for target <- [0, 1, 10, 100] do
      result = Split.split(messages, target)
      assert ContextStore.sanitize(result.retained) == result.retained
      assert_no_orphan_calls(result.retained)
      assert result.dropped ++ result.retained == messages
    end
  end

  test "provider failure leaves the current context and archive untouched", %{
    state_dir: state_dir
  } do
    messages = seeded_messages(state_dir, "alpha")
    before = File.read!(ContextStore.path(state_dir, "alpha"))

    assert {:error, {:provider_error, %Error{kind: :api}}} =
             ContextCompaction.maybe_compact(state_dir, "alpha", messages,
               context: %Context{threshold: 40, target: 1},
               run_id: "run-1",
               provider_opts: [
                 provider: Provider,
                 respond: fn _request -> {:error, Error.new(:api, "upstream failed")} end
               ]
             )

    assert File.read!(ContextStore.path(state_dir, "alpha")) == before
    refute File.exists?(ContextStore.archive_dir(state_dir, "alpha"))

    assert {:error, {:provider_exception, _message}} =
             ContextCompaction.maybe_compact(state_dir, "alpha", messages,
               context: %Context{threshold: 40, target: 1},
               run_id: "run-1",
               provider_opts: [
                 provider: Provider,
                 respond: fn _request -> raise "boom" end
               ]
             )

    assert File.read!(ContextStore.path(state_dir, "alpha")) == before
    refute File.exists?(ContextStore.archive_dir(state_dir, "alpha"))
  end

  test "an unavailable zstd executable leaves the current context untouched", %{
    state_dir: state_dir
  } do
    messages = seeded_messages(state_dir, "alpha")
    before = File.read!(ContextStore.path(state_dir, "alpha"))

    assert {:error, {:zstd_not_found, _path}} =
             ContextCompaction.maybe_compact(state_dir, "alpha", messages,
               context: %Context{threshold: 40, target: 1},
               run_id: "run-1",
               zstd_executable: "/nonexistent/zstd",
               provider_opts: [
                 provider: Provider,
                 respond: fn _request -> {:ok, %Response{content: "summary"}} end
               ]
             )

    assert File.read!(ContextStore.path(state_dir, "alpha")) == before
  end

  test "below the threshold compaction is unchanged", %{state_dir: state_dir} do
    messages = seeded_messages(state_dir, "alpha")
    before = File.read!(ContextStore.path(state_dir, "alpha"))

    assert :unchanged =
             ContextCompaction.maybe_compact(state_dir, "alpha", messages,
               context: %Context{threshold: 1_000_000, target: 1},
               provider_opts: [
                 provider: Provider,
                 respond: fn _request -> raise "provider should not run" end
               ]
             )

    assert File.read!(ContextStore.path(state_dir, "alpha")) == before
  end

  test "zstd is invoked through argv rather than a shell", %{state_dir: state_dir} do
    input = Path.join(state_dir, "in file; touch pwned")
    output = Path.join(state_dir, "out $(pwned).zst")

    File.write!(input, "context bytes")

    assert :ok = Zstd.compress_file(input, output)
    assert File.exists?(output)
    refute File.exists?(Path.join(state_dir, "pwned"))
  end

  test "compaction preserves system prompts ahead of the summary", %{state_dir: state_dir} do
    system = Message.system("You are the test agent.")

    messages = [
      system,
      Message.user(String.duplicate("old question ", 20)),
      Message.assistant(String.duplicate("old answer ", 20)),
      Message.user("recent")
    ]

    seed(state_dir, "alpha", messages, "run-1")

    assert {:ok, result} =
             ContextCompaction.compact(state_dir, "alpha", messages,
               target: 0,
               run_id: "run-1",
               provider_opts: [
                 provider: Provider,
                 respond: fn _request -> {:ok, %Response{content: "summary"}} end
               ]
             )

    assert hd(result.messages) == system
    assert Enum.at(result.messages, 1) == result.summary
    assert result.dropped == Enum.slice(messages, 1, 2)

    assert {:ok, entries} = ContextStore.read(state_dir, "alpha")
    stored = for {:message, %{message: message}} <- entries, do: message
    refute Enum.any?(stored, &(&1.role == :system))
    assert hd(stored) == result.summary
  end

  test "prepare archives without replacing the current context", %{state_dir: state_dir} do
    messages = seeded_messages(state_dir, "alpha")
    before = File.read!(ContextStore.path(state_dir, "alpha"))

    assert {:ok, plan} =
             ContextCompaction.prepare(state_dir, "alpha", messages,
               target: 0,
               run_id: "run-1",
               provider_opts: [
                 provider: Provider,
                 respond: fn _request -> {:ok, %Response{content: "summary"}} end
               ]
             )

    assert plan.summary.content == "summary"
    assert File.read!(ContextStore.path(state_dir, "alpha")) == before
    assert File.exists?(plan.archive.path)
    assert File.exists?(plan.archive.metadata_path)

    assert :ok = ContextCompaction.commit(state_dir, "alpha", plan)
    assert File.read!(ContextStore.path(state_dir, "alpha")) != before
  end

  test "the archive exists before the current context swaps", %{state_dir: state_dir} do
    messages = seeded_messages(state_dir, "alpha")

    assert {:ok, plan} =
             ContextCompaction.prepare(state_dir, "alpha", messages,
               target: 0,
               run_id: "run-1",
               provider_opts: [
                 provider: Provider,
                 respond: fn _request -> {:ok, %Response{content: "summary"}} end
               ]
             )

    assert :ok =
             ContextCompaction.commit(state_dir, "alpha", plan,
               replace: fn ->
                 assert File.exists?(plan.archive.path)
                 assert File.exists?(plan.archive.metadata_path)
                 ContextStore.replace(state_dir, "alpha", plan.entries)
               end
             )

    assert File.exists?(plan.archive.path)
  end

  test "a failed context replace removes the prepared archive", %{state_dir: state_dir} do
    messages = seeded_messages(state_dir, "alpha")
    before = File.read!(ContextStore.path(state_dir, "alpha"))

    assert {:ok, plan} =
             ContextCompaction.prepare(state_dir, "alpha", messages,
               target: 0,
               run_id: "run-1",
               provider_opts: [
                 provider: Provider,
                 respond: fn _request -> {:ok, %Response{content: "summary"}} end
               ]
             )

    assert {:error, {:context_replace_failed, :eacces}} =
             ContextCompaction.commit(state_dir, "alpha", plan,
               replace: fn -> {:error, :eacces} end
             )

    assert File.read!(ContextStore.path(state_dir, "alpha")) == before
    refute File.exists?(plan.archive.path)
    refute File.exists?(plan.archive.metadata_path)

    files = File.ls!(ContextStore.archive_dir(state_dir, "alpha"))
    refute Enum.any?(files, &String.ends_with?(&1, [".pbc.zst", ".json"]))
  end

  defp seeded_messages(state_dir, agent_id) do
    messages = [
      Message.user(String.duplicate("old question ", 20)),
      Message.assistant(String.duplicate("old answer ", 20)),
      Message.user("recent")
    ]

    seed(state_dir, agent_id, messages, "run-1")
    messages
  end

  defp seed(state_dir, agent_id, messages, run_id) do
    assert :ok = ContextStore.append_run(state_dir, agent_id, run_id, :started)

    Enum.each(messages, fn message ->
      assert :ok = ContextStore.append_message(state_dir, agent_id, run_id, "attempt-1", message)
    end)
  end

  defp assert_no_orphan_calls(messages) do
    {_calls, _results} =
      Enum.reduce(messages, {MapSet.new(), MapSet.new()}, fn message, {calls, results} ->
        case message do
          %Message{role: :assistant, tool_calls: tool_calls} ->
            {MapSet.union(calls, MapSet.new(tool_calls, & &1.id)), results}

          %Message{role: :tool, tool_call_id: id} ->
            assert MapSet.member?(calls, id)
            {calls, MapSet.put(results, id)}

          _message ->
            {calls, results}
        end
      end)

    assert Enum.all?(messages, fn
             %Message{role: :assistant, tool_calls: tool_calls} ->
               Enum.all?(tool_calls, &result_seen?(messages, &1.id))

             _message ->
               true
           end)
  end

  defp result_seen?(messages, id) do
    Enum.any?(messages, &match?(%Message{role: :tool, tool_call_id: ^id}, &1))
  end
end
