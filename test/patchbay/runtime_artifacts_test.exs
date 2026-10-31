defmodule Patchbay.RuntimeArtifactsTest.Manager do
  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  def calls(pid), do: GenServer.call(pid, :calls)

  @impl true
  def init(opts) do
    {:ok,
     %{
       execute_result:
         Keyword.get(opts, :execute_result, {:ok, %{status: :ok, output: "stub\n"}}),
       calls: []
     }}
  end

  @impl true
  def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

  def handle_call({:start_worker, worker_id, _opts}, _from, state),
    do:
      {:reply, {:ok, %{worker_id: worker_id, status: :starting}},
       record(state, {:start_worker, worker_id})}

  def handle_call({:await_worker, worker_id, _timeout}, _from, state),
    do: {:reply, {:ok, %{status: :ready}}, record(state, {:await_worker, worker_id})}

  def handle_call({:execute, worker_id, operation, arguments, timeout}, _from, state) do
    result =
      case state.execute_result do
        fun when is_function(fun, 2) -> fun.(operation, arguments)
        other -> other
      end

    {:reply, result, record(state, {:execute, worker_id, operation, arguments, timeout})}
  end

  def handle_call({:stop_worker, worker_id, _timeout}, _from, state),
    do: {:reply, {:ok, %{status: :stopping}}, record(state, {:stop_worker, worker_id})}

  def handle_call({:transcript_path, worker_id}, _from, state),
    do:
      {:reply, Path.join(System.tmp_dir!(), worker_id <> ".pbt"),
       record(state, {:transcript_path, worker_id})}

  defp record(state, call), do: %{state | calls: [call | state.calls]}
end

defmodule Patchbay.RuntimeArtifactsTest.WorkerClient do
  @behaviour Patchbay.Runtime.WorkerClient

  @impl true
  def start_worker(server, worker_id, opts),
    do: GenServer.call(server, {:start_worker, worker_id, opts})

  @impl true
  def await_worker(server, worker_id, timeout),
    do: GenServer.call(server, {:await_worker, worker_id, timeout})

  @impl true
  def execute(server, worker_id, operation, arguments, timeout),
    do: GenServer.call(server, {:execute, worker_id, operation, arguments, timeout})

  @impl true
  def stop_worker(server, worker_id, timeout),
    do: GenServer.call(server, {:stop_worker, worker_id, timeout})

  @impl true
  def transcript_path(server, worker_id),
    do: GenServer.call(server, {:transcript_path, worker_id})
end

defmodule Patchbay.RuntimeArtifactsTest do
  use ExUnit.Case, async: false

  alias Patchbay.ArtifactStore
  alias Patchbay.Definition
  alias Patchbay.Provider.JSON
  alias Patchbay.Provider.ToolCall
  alias Patchbay.Runtime
  alias Patchbay.RuntimeArtifactsTest.Manager
  alias Patchbay.RuntimeArtifactsTest.WorkerClient

  @report "publish me across the UID split"
  @chunk_bytes 512 * 1024
  # Long enough for each chunk round-trip to show on the wall clock, short
  # enough to keep the multi-chunk tests quick.
  @chunk_sleep 150
  @slow_tool_ms 800

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "patchbay-runtime-artifacts-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace = Path.join([tmp, "workspaces", "alpha"])
    File.mkdir_p!(Path.join(workspace, "out"))
    on_exit(fn -> File.rm_rf(tmp) end)

    %{tmp: tmp, workspace: workspace, state_dir: Path.join(tmp, "state")}
  end

  test "publishes a file result through the worker read RPC", context do
    body = @report
    source = Path.join(context.workspace, "out/report.txt")
    File.write!(source, body)

    {:ok, stub} = read_stub(fn offset -> chunk_from(body, offset) end)
    runtime = start_runtime(context, stub)

    assert {:ok, running} = Runtime.start_agent(runtime, "alpha")
    assert running.status == :running

    assert :ok = submit(runtime, "call-1", %{"report" => "out/report.txt"})
    assert {:ok, _agent} = Runtime.await_agent(runtime, "alpha", 10_000)

    assert {:ok, [artifact]} = Runtime.list_artifacts(runtime, "alpha")
    assert artifact.name =~ ~r/\Areport-report-[a-z0-9]{4}-[a-z0-9]{8}\.txt\z/
    assert artifact.size == byte_size(body)
    assert artifact.content_type == "text/plain"

    directory = ArtifactStore.dir(context.state_dir, "alpha")
    assert mode(directory) == 0o700
    assert mode(Path.join(directory, artifact.name)) == 0o600
    assert {:ok, ^body} = ArtifactStore.read(context.state_dir, "alpha", artifact.name)

    reads = executions(stub, "patchbay-read-artifact")
    assert [%{"offset" => 0, "path" => "out/report.txt", "root" => "workspace"} | _] = reads

    assert {:ok, events} = Runtime.list_events(runtime, "alpha")
    published = Enum.find(events, &(&1.type == :artifact_published))
    assert published.data["result"] == "report"
    assert published.data["name"] == artifact.name
    refute Enum.any?(events, &(&1.type == :artifact_publish_failed))
  end

  test "publishes through the worker when the manager cannot traverse agent directories",
       context do
    source = Path.join(context.workspace, "out/report.txt")
    File.write!(source, @report)

    # Cross-UID stand-in: the manager has no search permission below the
    # workspace root, so a manager-side realpath walk over the source fails
    # with EACCES. Publication must still work: confinement is enforced
    # worker-side and the bytes travel over the worker RPC, so the manager
    # never touches the directory.
    File.chmod!(Path.dirname(source), 0o000)
    on_exit(fn -> File.chmod!(Path.dirname(source), 0o755) end)

    {:ok, stub} = read_stub(fn offset -> chunk_from(@report, offset) end)
    runtime = start_runtime(context, stub)

    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")

    assert :ok = submit(runtime, "call-eacces", %{"report" => "out/report.txt"})
    assert {:ok, _agent} = Runtime.await_agent(runtime, "alpha", 10_000)

    assert {:ok, [artifact]} = Runtime.list_artifacts(runtime, "alpha")
    assert {:ok, @report} = ArtifactStore.read(context.state_dir, "alpha", artifact.name)

    reads = executions(stub, "patchbay-read-artifact")
    assert [%{"path" => "out/report.txt", "root" => "workspace"} | _] = reads
  end

  test "falls back to a direct read when the worker RPC is gone", context do
    source = Path.join(context.workspace, "direct.txt")
    File.write!(source, @report <> " via direct read")

    {:ok, stub} = Manager.start_link(execute_result: {:error, :unknown_worker})
    runtime = start_runtime(context, stub)

    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")

    assert :ok = submit(runtime, "call-2", %{"report" => "direct.txt"})
    assert {:ok, _agent} = Runtime.await_agent(runtime, "alpha", 10_000)

    assert {:ok, [artifact]} = Runtime.list_artifacts(runtime, "alpha")

    assert {:ok, @report <> " via direct read"} =
             ArtifactStore.read(context.state_dir, "alpha", artifact.name)
  end

  test "does not retry a read the worker refused, even when the manager could", context do
    source = Path.join(context.workspace, "forbidden.txt")
    File.write!(source, "the manager could read this directly")

    # The worker answered, and its answer was a confinement refusal. The
    # manager must not work around it with a direct read of the same path:
    # the worker's confinement answer is the one that counts.
    {:ok, stub} =
      Manager.start_link(execute_result: {:ok, %{status: :error, error: :path_outside_root}})

    runtime = start_runtime(context, stub)

    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")

    assert :ok = submit(runtime, "call-refused", %{"report" => "forbidden.txt"})
    assert {:ok, agent} = Runtime.await_agent(runtime, "alpha", 10_000)

    assert {:ok, []} = Runtime.list_artifacts(runtime, "alpha")

    {:ok, events} = Runtime.list_events(runtime, "alpha")
    failed = Enum.find(events, &(&1.type == :artifact_publish_failed))
    assert failed.data["result"] == "report"

    # The run still finishes, and the loss shows in the terminal result
    # instead of hiding behind a bare success.
    assert agent.result["report"] =~ "publish failed"
    assert agent.result["report"] =~ "forbidden.txt"
  end

  test "rejects file results that point outside the workspace and result directories", context do
    {:ok, stub} = Manager.start_link(execute_result: {:error, :unknown_worker})
    runtime = start_runtime(context, stub)

    outside = Path.join(context.tmp, "outside.txt")
    File.write!(outside, "nope")

    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")

    assert :ok = submit(runtime, "call-3", %{"report" => "../../outside.txt"})
    assert {:ok, _agent} = Runtime.await_agent(runtime, "alpha", 10_000)

    assert {:ok, []} = Runtime.list_artifacts(runtime, "alpha")

    {:ok, events} = Runtime.list_events(runtime, "alpha")
    failed = Enum.find(events, &(&1.type == :artifact_publish_failed))

    assert failed.data["result"] == "report"
    assert failed.data["reason"] == ["artifact_path_outside_workspace", "../../outside.txt"]
  end

  test "reports a missing artifact file without failing the run", context do
    {:ok, stub} = Manager.start_link(execute_result: {:error, :unknown_worker})
    runtime = start_runtime(context, stub)

    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")

    assert :ok = submit(runtime, "call-4", %{"report" => "missing.txt"})
    assert {:ok, agent} = Runtime.await_agent(runtime, "alpha", 10_000)

    assert {:ok, []} = Runtime.list_artifacts(runtime, "alpha")

    {:ok, events} = Runtime.list_events(runtime, "alpha")
    assert Enum.any?(events, &(&1.type == :artifact_publish_failed))
    assert agent.result["report"] =~ "publish failed"
  end

  test "fails a source that shrinks while being copied", context do
    # The first chunk promises a megabyte, the second reports a smaller
    # file: the copy must stop instead of looping on the missing bytes.
    {:ok, stub} = read_stub(&shrinking_chunk/1)
    runtime = start_runtime(context, stub)

    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")

    assert :ok = submit(runtime, "call-shrink", %{"report" => "shrinking.bin"})
    assert {:ok, agent} = Runtime.await_agent(runtime, "alpha", 10_000)

    reads = executions(stub, "patchbay-read-artifact")
    assert length(reads) == 2

    assert {:ok, []} = Runtime.list_artifacts(runtime, "alpha")

    {:ok, events} = Runtime.list_events(runtime, "alpha")
    failed = Enum.find(events, &(&1.type == :artifact_publish_failed))
    assert failed.data["result"] == "report"
    assert failed.data["reason"] in [:artifact_read_mismatch, "artifact_read_mismatch"]
    assert agent.result["report"] =~ "publish failed"
  end

  test "fails an empty chunk that still promises more bytes", context do
    # An empty chunk while the size header says more bytes remain would
    # spin the loop forever without a progress rule.
    {:ok, stub} = read_stub(fn _offset -> chunk_header("", 0, 16) end)
    runtime = start_runtime(context, stub)

    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")

    assert :ok = submit(runtime, "call-empty", %{"report" => "empty.bin"})
    assert {:ok, _agent} = Runtime.await_agent(runtime, "alpha", 10_000)

    reads = executions(stub, "patchbay-read-artifact")
    assert length(reads) == 1

    assert {:ok, []} = Runtime.list_artifacts(runtime, "alpha")

    {:ok, events} = Runtime.list_events(runtime, "alpha")
    failed = Enum.find(events, &(&1.type == :artifact_publish_failed))
    assert failed.data["reason"] in [:artifact_read_stalled, "artifact_read_stalled"]
  end

  test "keeps serving other agents while a multi-chunk copy is in flight", context do
    {:ok, stub} = slow_read_stub()
    runtime = start_runtime(context, stub)

    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")

    # The copy takes at least three chunk round-trips. The terminal call
    # returns immediately, and the runtime keeps answering calls for every
    # other agent while the copy proceeds.
    started = System.monotonic_time(:millisecond)

    assert :ok =
             Runtime.runner_complete(
               runtime,
               "alpha",
               complete_task("call-slow"),
               %{"summary" => "ok", "report" => "out/big.bin"}
             )

    assert System.monotonic_time(:millisecond) - started < @chunk_sleep

    worst = worst_probe_delay(runtime)

    # A publication run inside the runtime call would stack every probe
    # behind the outstanding chunk round-trips; here each probe is answered
    # while the copy is still going.
    assert worst < 2 * @chunk_sleep

    assert {:ok, _agent} = Runtime.await_agent(runtime, "alpha", 10_000)

    assert {:ok, [artifact]} = Runtime.list_artifacts(runtime, "alpha")

    assert {:ok, bytes} = ArtifactStore.read(context.state_dir, "alpha", artifact.name)
    assert bytes == multi_chunk_body()
  end

  test "keeps the worker alive until the copy finishes and then honors a stop", context do
    {:ok, stub} = slow_read_stub()
    runtime = start_runtime(context, stub)

    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")

    assert :ok =
             Runtime.runner_complete(
               runtime,
               "alpha",
               complete_task("call-stop"),
               %{"summary" => "ok", "report" => "out/big.bin"}
             )

    parent = self()

    _stopper =
      spawn_link(fn ->
        send(parent, {:stop_reply, Runtime.stop_agent(runtime, "alpha", timeout: 2_000)})
      end)

    assert_receive {:stop_reply, {:ok, stopped}}, 10_000
    assert stopped.status == :stopped
    assert stopped.run_status == :cancelled
    assert stopped.result == nil

    {:ok, events} = Runtime.list_events(runtime, "alpha")
    refute Enum.any?(events, &(&1.type == :run_completed))
    assert Enum.count(events, &(&1.type == :agent_stopped)) == 1

    # The worker outlived the copy: every read precedes the single stop.
    calls = Manager.calls(stub)

    read_positions =
      for {call, index} <- Enum.with_index(calls),
          match?({:execute, _, "patchbay-read-artifact", _, _}, call),
          do: index

    stop_positions =
      for {call, index} <- Enum.with_index(calls),
          match?({:stop_worker, _worker_id}, call),
          do: index

    assert length(read_positions) == 3
    assert length(stop_positions) == 1
    assert Enum.max(read_positions) < Enum.min(stop_positions)

    assert {:ok, [artifact]} = Runtime.list_artifacts(runtime, "alpha")
    assert artifact.size == byte_size(multi_chunk_body())
  end

  test "a stop requested during publication ends the run cancelled after the copy",
       context do
    source = Path.join(context.workspace, "out/report.txt")
    File.write!(source, @report)
    parent = self()

    # Hold the first worker read until the test has seen the stop request.
    # The runtime stays responsive because publication runs outside it.
    {:ok, stub} =
      read_stub(fn offset ->
        send(parent, {:publication_read, self()})

        receive do
          :release -> chunk_from(@report, offset)
        after
          10_000 -> {:error, :publication_blocked}
        end
      end)

    runtime = start_runtime(context, stub)

    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")

    assert :ok =
             Runtime.runner_complete(
               runtime,
               "alpha",
               complete_task("call-stop-during-publish"),
               %{"summary" => "ok", "report" => "out/report.txt"}
             )

    assert_receive {:publication_read, publisher}, 5_000

    assert eventually(fn ->
             match?({:ok, %{activity: :publishing}}, Runtime.get_agent(runtime, "alpha"))
           end)

    _stopper =
      spawn_link(fn ->
        send(parent, {:stop_reply, Runtime.stop_agent(runtime, "alpha", timeout: 10_000)})
      end)

    assert eventually(fn ->
             match?({:ok, %{status: :stopping}}, Runtime.get_agent(runtime, "alpha"))
           end)

    send(publisher, :release)

    assert_receive {:stop_reply, {:ok, stopped}}, 10_000
    assert stopped.status == :stopped
    assert stopped.run_status == :cancelled
    assert stopped.result == nil
    assert stopped.worker_id == nil

    {:ok, events} = Runtime.list_events(runtime, "alpha")
    refute Enum.any?(events, &(&1.type == :run_completed))

    terminal =
      events
      |> Enum.map(& &1.type)
      |> Enum.filter(&(&1 in [:run_completed, :run_failed, :agent_stopped]))

    assert terminal == [:agent_stopped]

    assert Enum.any?(events, &(&1.type == :artifact_published))
    assert {:ok, [artifact]} = Runtime.list_artifacts(runtime, "alpha")
    assert {:ok, @report} = ArtifactStore.read(context.state_dir, "alpha", artifact.name)
  end

  test "a caller that times out on the terminal call still ends in a consistent terminal state",
       context do
    {:ok, stub} =
      Manager.start_link(
        execute_result: fn operation, arguments ->
          case operation do
            "patchbay-read-artifact" -> chunk_from(multi_chunk_body(), arguments["offset"])
            "slow" -> Process.sleep(@slow_tool_ms) && {:ok, %{status: :ok, output: "slow"}}
            _other -> {:ok, %{status: :error}}
          end
        end
      )

    runtime = start_runtime(context, stub)

    assert {:ok, _running} = Runtime.start_agent(runtime, "alpha")

    # Occupy the runtime for a bounded moment with one tool call, then have
    # a caller give up on the terminal call while the runtime is busy. The
    # run must still reach a single, consistent terminal state.
    _tool_caller =
      spawn_link(fn ->
        _ = Runtime.execute_tool(runtime, "alpha", "slow", %{}, timeout: 10_000)
      end)

    Process.sleep(100)

    outcome =
      try do
        GenServer.call(
          runtime,
          {:runner_complete, "alpha", complete_task("call-timeout"),
           %{"summary" => "ok", "report" => "out/big.bin"}},
          10
        )
      catch
        :exit, {:timeout, _details} -> :timed_out
      end

    assert outcome == :timed_out

    assert {:ok, agent} = Runtime.await_agent(runtime, "alpha", 10_000)
    assert agent.status == :stopped

    # A late duplicate terminal call cannot transition the finished run
    # again.
    assert {:error, {:not_running, _}} =
             GenServer.call(
               runtime,
               {:runner_complete, "alpha", complete_task("call-late"),
                %{"summary" => "again", "report" => "out/big.bin"}},
               5_000
             )

    {:ok, events} = Runtime.list_events(runtime, "alpha")
    assert Enum.count(events, &(&1.type == :run_completed)) == 1
    assert Enum.count(events, &(&1.type == :artifact_published)) == 1

    assert {:ok, [artifact]} = Runtime.list_artifacts(runtime, "alpha")

    assert {:ok, bytes} = ArtifactStore.read(context.state_dir, "alpha", artifact.name)
    assert bytes == multi_chunk_body()
  end

  test "artifact lookup refuses unknown agents and names", context do
    {:ok, stub} = Manager.start_link(execute_result: {:error, :unknown_worker})
    runtime = start_runtime(context, stub)

    assert {:error, :not_found} = Runtime.list_artifacts(runtime, "ghost")

    assert {:error, _invalid} = Runtime.artifact(runtime, "alpha", "../evil")
    assert {:error, _invalid} = Runtime.artifact(runtime, "alpha", "sub/thing.txt")
    assert {:error, _unknown} = Runtime.artifact(runtime, "ghost", "file.txt")
    assert {:error, _unknown} = Runtime.artifact(runtime, "alpha", "nothing.txt")
  end

  # Submits the file results; the terminal reply comes back immediately and
  # the caller waits for publication to finish writing the manager-owned
  # copy.
  defp submit(runtime, call_id, results) do
    Runtime.runner_complete(
      runtime,
      "alpha",
      complete_task(call_id),
      Map.merge(%{"summary" => "ok"}, results)
    )
  end

  defp complete_task(call_id), do: ToolCall.new(call_id, "complete_task", %{})

  defp start_runtime(context, stub) do
    {:ok, runtime} =
      Runtime.start_link(
        definitions: %{"alpha" => definition("alpha"), "beta" => definition("beta")},
        state_dir: context.state_dir,
        workspace_dir: Path.join(context.tmp, "workspaces"),
        result_dir: Path.join(context.tmp, "results"),
        manager: stub,
        worker_client: WorkerClient
      )

    on_exit(fn -> if Process.alive?(runtime), do: GenServer.stop(runtime) end)
    runtime
  end

  defp definition(id) do
    {:ok, definition} =
      Definition.parse("""
      format-version = 1
      id = "#{id}"

      [model]
      name = "test-model"

      [lifecycle]
      kind = "one-shot"

      [[toolkits]]
      toolkit = "shell"

      [[toolkits.operations]]
      name = "slow"
      executable = "#{executable!("sh")}"
      argv = ["-c", "true"]

      [[results]]
      id = "summary"
      form = "prose"
      label = "Summary"

      [[results]]
      id = "report"
      form = "file"
      extensions = ["txt", "bin"]
      label = "The final report"
      """)

    definition
  end

  defp read_stub(fun) do
    Manager.start_link(
      execute_result: fn operation, arguments ->
        if operation == "patchbay-read-artifact",
          do: fun.(arguments["offset"]),
          else: {:ok, %{status: :error}}
      end
    )
  end

  defp slow_read_stub do
    read_stub(fn offset ->
      Process.sleep(@chunk_sleep)
      chunk_from(multi_chunk_body(), offset)
    end)
  end

  # Built at runtime instead of as a module attribute: a megabyte-plus
  # binary literal the compiler has to keep expanding is its own worst
  # enemy.
  defp multi_chunk_body do
    String.duplicate("A", @chunk_bytes) <> String.duplicate("B", @chunk_bytes) <> "tail"
  end

  # Polls another agent's summary while `waited` is still publishing, and
  # returns the slowest observed round-trip on the central runtime.
  defp worst_probe_delay(runtime) do
    deadline = System.monotonic_time(:millisecond) + 10_000
    do_worst_probe_delay(runtime, 0, deadline)
  end

  defp do_worst_probe_delay(runtime, worst, deadline) do
    started = System.monotonic_time(:millisecond)
    {:ok, _beta} = Runtime.get_agent(runtime, "beta")
    delay = System.monotonic_time(:millisecond) - started

    case Runtime.get_agent(runtime, "alpha") do
      {:ok, %{status: :stopped}} ->
        max(delay, worst)

      _publishing ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("publication never finished for alpha")
        end

        Process.sleep(5)
        do_worst_probe_delay(runtime, max(delay, worst), deadline)
    end
  end

  defp eventually(fun, timeout \\ 5_000) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(10)
        do_eventually(fun, deadline)
      end
    end
  end

  defp executions(stub, operation) do
    stub
    |> Manager.calls()
    |> Enum.filter(fn
      {_kind, _worker, ^operation, _arguments, _timeout} -> true
      _other -> false
    end)
    |> Enum.map(fn {_kind, _worker, _operation, arguments, _timeout} -> arguments end)
  end

  defp chunk_from(body, offset) do
    got = min(@chunk_bytes, max(byte_size(body) - offset, 0))
    data = binary_part(body, offset, got)
    chunk_header(data, offset, byte_size(body))
  end

  # The source shrinks between the first read and the second: the second
  # chunk reports a smaller total size than the first promised.
  defp shrinking_chunk(0) do
    data = String.duplicate("A", @chunk_bytes)
    chunk_header(data, 0, byte_size(multi_chunk_body()))
  end

  defp shrinking_chunk(_offset) do
    data = String.duplicate("B", @chunk_bytes)
    chunk_header(data, @chunk_bytes, @chunk_bytes)
  end

  defp chunk_header(data, offset, size) do
    header = %{
      "size" => size,
      "offset" => offset,
      "length" => byte_size(data),
      "eof" => offset + byte_size(data) >= size,
      "data" => Base.encode64(data)
    }

    case JSON.encode(header) do
      {:ok, encoded} -> {:ok, %{status: :ok, output: encoded}}
      {:error, _reason} -> {:error, :invalid_chunk}
    end
  end

  defp mode(path) do
    {:ok, %File.Stat{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o777)
  end

  defp executable!(name) do
    case System.find_executable(name) do
      nil -> flunk("missing executable in test environment: #{name}")
      path -> path
    end
  end
end
