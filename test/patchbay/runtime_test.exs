defmodule Patchbay.RuntimeTest.Definitions do
  @behaviour Patchbay.Runtime.DefinitionSource

  @name :runtime_test_definitions

  def start_link do
    Agent.start_link(fn -> %{} end, name: @name)
  end

  def put(definition) do
    Agent.update(@name, &Map.put(&1, definition.id, definition))
  end

  def list do
    case Process.whereis(@name) do
      nil -> []
      pid -> Agent.get(pid, &Map.values/1)
    end
  end

  def get(id) do
    case Process.whereis(@name) do
      nil ->
        {:error, :not_found}

      pid ->
        case Agent.get(pid, &Map.fetch(&1, id)) do
          {:ok, definition} -> {:ok, definition}
          :error -> {:error, :not_found}
        end
    end
  end
end

defmodule Patchbay.RuntimeTest.Manager do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def calls(pid), do: GenServer.call(pid, :calls)

  def set(pid, key, value), do: GenServer.call(pid, {:set, key, value})

  @impl true
  def init(opts) do
    {:ok,
     %{
       transcript_dir: Keyword.get(opts, :transcript_dir, System.tmp_dir!()),
       start_results: Keyword.get(opts, :start_results, []),
       await_result: Keyword.get(opts, :await_result, {:ok, %{status: :ready}}),
       execute_result:
         Keyword.get(
           opts,
           :execute_result,
           {:ok, %{status: :ok, output: "stub\n", exit_status: 0}}
         ),
       stop_result: Keyword.get(opts, :stop_result, {:ok, %{status: :stopping}}),
       calls: []
     }}
  end

  @impl true
  def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

  def handle_call({:set, key, value}, _from, state) when key in [:start_results, :stop_result] do
    {:reply, :ok, Map.put(state, key, value)}
  end

  def handle_call({:start_worker, worker_id, opts}, _from, state) do
    {result, state} = next_start(state, worker_id)
    {:reply, result, record(state, {:start_worker, worker_id, opts})}
  end

  def handle_call({:await_worker, worker_id, timeout}, _from, state) do
    {:reply, state.await_result, record(state, {:await_worker, worker_id, timeout})}
  end

  def handle_call({:execute, worker_id, operation, arguments, timeout}, _from, state) do
    result =
      case state.execute_result do
        fun when is_function(fun, 2) -> fun.(operation, arguments)
        other -> other
      end

    {:reply, result, record(state, {:execute, worker_id, operation, arguments, timeout})}
  end

  def handle_call({:stop_worker, worker_id, timeout}, _from, state) do
    {:reply, state.stop_result, record(state, {:stop_worker, worker_id, timeout})}
  end

  def handle_call({:transcript_path, worker_id}, _from, state) do
    path = Path.join(state.transcript_dir, worker_id <> ".pbt")
    {:reply, path, record(state, {:transcript_path, worker_id})}
  end

  defp next_start(%{start_results: [result | rest]} = state, _worker_id),
    do: {result, %{state | start_results: rest}}

  defp next_start(state, worker_id),
    do: {{:ok, %{worker_id: worker_id, status: :starting}}, state}

  defp record(state, call), do: %{state | calls: [call | state.calls]}
end

defmodule Patchbay.RuntimeTest.WorkerClient do
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

defmodule Patchbay.RuntimeTest.NativeToolkit do
  @behaviour Patchbay.Toolkit.Native

  @impl true
  def id, do: "runtime-native"

  @impl true
  def tools(_context) do
    [
      %{
        name: "native_echo",
        description: "Native echo.",
        schema: %{"type" => "object", "properties" => %{}}
      }
    ]
  end

  @impl true
  def execute("native_echo", arguments, context) do
    agent_id = context.variables["agent_id"]
    {:ok, %{status: :ok, output: "#{agent_id}:#{Map.get(arguments, "text")}"}}
  end
end

defmodule Patchbay.RuntimeTest.RegistryLike do
  @behaviour Patchbay.Runtime.DefinitionServerSource

  @impl true
  def list(server), do: Agent.get(server, &Map.values/1)

  @impl true
  def get(id, server) do
    Agent.get(server, fn snapshots ->
      case Map.fetch(snapshots, id) do
        {:ok, snapshot} -> {:ok, snapshot}
        :error -> {:error, :not_found}
      end
    end)
  end
end

defmodule Patchbay.RuntimeTest do
  use ExUnit.Case, async: false

  alias Patchbay.Definition
  alias Patchbay.Event
  alias Patchbay.Runtime
  alias Patchbay.RuntimeTest.{Definitions, Manager, RegistryLike, WorkerClient}

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "patchbay-runtime-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)
    {:ok, definitions} = Definitions.start_link()

    stub =
      start_supervised!(
        {Manager,
         transcript_dir: Path.join(tmp, "transcripts"),
         execute_result: {:ok, %{status: :ok, output: "stub\n", exit_status: 0}}}
      )

    on_exit(fn ->
      if Process.alive?(definitions), do: Agent.stop(definitions)
      File.rm_rf(tmp)
    end)

    %{tmp: tmp, definitions: definitions, stub: stub}
  end

  test "lists known definitions and reports stopped agents", context do
    Definitions.put(definition("alpha"))

    runtime = start_runtime(context)

    assert {:ok, [summary]} = Runtime.list_agents(runtime)
    assert summary.agent_id == "alpha"
    assert summary.status == :stopped
    assert summary.lifecycle_kind == :one_shot
    assert summary.definition_revision == nil

    assert {:ok, detail} = Runtime.get_agent(runtime, "alpha")
    assert detail.definition.id == "alpha"
    assert detail.definition.model.name == "test-model"

    assert {:error, :not_found} = Runtime.get_agent(runtime, "missing")

    assert {:ok, []} = Runtime.list_events(runtime, "missing")
    assert {:ok, []} = Runtime.tool_history(runtime, "missing")
    assert {:error, {:invalid_agent_id, "../escape"}} = Runtime.list_events(runtime, "../escape")
  end

  test "start and stop record lifecycle state, durable events, and subscriptions", context do
    Definitions.put(definition("alpha"))
    runtime = start_runtime(context)

    assert :ok = Runtime.subscribe(runtime)

    assert {:ok, running} = Runtime.start_agent(runtime, "alpha")
    assert running.status == :running
    assert running.run_status == :running
    assert running.definition_revision == 1
    assert running.attempt_ordinal == 1
    assert is_binary(running.run_id)
    assert is_binary(running.attempt_id)
    assert is_binary(running.instance_id)
    assert running.worker_id == "agent.alpha"
    assert {:ok, "alpha"} = Patchbay.Worker.Id.agent(running.worker_id)

    assert_receive {:patchbay_event, %Event{type: :run_started, agent_id: "alpha"}}
    assert_receive {:patchbay_event, %Event{type: :attempt_started}}
    assert_receive {:patchbay_event, %Event{type: :instance_ready}}
    assert_receive {:patchbay_event, %Event{type: :agent_started}}

    assert {:ok, events} = Runtime.list_events(runtime, "alpha")

    assert Enum.map(events, & &1.type) == [
             :run_started,
             :attempt_started,
             :instance_ready,
             :agent_started
           ]

    assert Enum.map(events, & &1.sequence) == [1, 2, 3, 4]
    assert Enum.all?(events, &(&1.definition_revision == 1))
    assert Enum.all?(events, &(&1.run_id == running.run_id))

    assert {:ok, stopped} = Runtime.stop_agent(runtime, "alpha")
    assert stopped.status == :stopped
    assert stopped.run_status == :cancelled
    assert stopped.stopped_at != nil

    assert_receive {:patchbay_event, %Event{type: :agent_stopped}}

    assert {:ok, events} = Runtime.list_events(runtime, "alpha")
    assert List.last(events).type == :agent_stopped
    assert List.last(events).data["reason"] == "operator_stop"

    assert :ok = Runtime.unsubscribe(runtime)
    assert {:ok, _again} = Runtime.start_agent(runtime, "alpha")
    refute_receive {:patchbay_event, _event}, 50
  end

  test "registry-shaped snapshots supply definition revisions", context do
    {:ok, source} = Agent.start_link(fn -> %{} end)
    on_exit(fn -> if Process.alive?(source), do: Agent.stop(source) end)

    first_definition = definition("alpha", model: "model-one")

    snapshot = %{
      id: "alpha",
      revision: 7,
      definition: first_definition,
      fingerprint: :erlang.md5(:erlang.term_to_binary(first_definition))
    }

    Agent.update(source, &Map.put(&1, "alpha", snapshot))

    runtime = start_runtime(context, definitions: {RegistryLike, source})

    assert {:ok, first} = Runtime.start_agent(runtime, "alpha")
    assert first.definition_revision == 7
    assert {:ok, _} = Runtime.stop_agent(runtime, "alpha")

    second_definition = definition("alpha", model: "model-two")

    Agent.update(source, fn snapshots ->
      Map.put(snapshots, "alpha", %{
        snapshot
        | revision: 8,
          definition: second_definition,
          fingerprint: :erlang.md5(:erlang.term_to_binary(second_definition))
      })
    end)

    assert {:ok, second} = Runtime.start_agent(runtime, "alpha")
    assert second.definition_revision == 8
    assert second.run_id != first.run_id
  end

  test "the real definition registry supplies snapshots and revisions", context do
    config_dir = Path.join(context.tmp, "config")
    agent_dir = Path.join([config_dir, "agents", "alpha"])
    File.mkdir_p!(agent_dir)
    File.write!(Path.join(agent_dir, "agent.toml"), agent_toml("alpha", "model-one"))

    registry =
      start_supervised!({Patchbay.DefinitionRegistry, [config_dir: config_dir, name: nil]})

    runtime = start_runtime(context, definitions: {Patchbay.DefinitionRegistry, registry})

    assert {:ok, first} = Runtime.start_agent(runtime, "alpha")
    assert first.definition_revision == 1
    assert {:ok, _} = Runtime.stop_agent(runtime, "alpha")

    File.write!(Path.join(agent_dir, "agent.toml"), agent_toml("alpha", "model-two"))
    assert {:ok, _report} = Patchbay.DefinitionRegistry.reload(registry)

    assert {:ok, second} = Runtime.start_agent(runtime, "alpha")
    assert second.definition_revision == 2
    assert second.run_id != first.run_id
  end

  test "a changed definition advances the revision and a restart starts a new run", context do
    Definitions.put(definition("alpha", model: "model-one"))
    runtime = start_runtime(context)

    assert {:ok, first} = Runtime.start_agent(runtime, "alpha")
    assert first.definition_revision == 1
    assert {:ok, _} = Runtime.stop_agent(runtime, "alpha")

    Definitions.put(definition("alpha", model: "model-two"))

    assert {:ok, second} = Runtime.start_agent(runtime, "alpha")
    assert second.definition_revision == 2
    assert second.run_id != first.run_id
    assert {:ok, stopped} = Runtime.stop_agent(runtime, "alpha")
    assert stopped.run_status == :cancelled

    assert {:ok, events} = Runtime.list_events(runtime, "alpha")
    assert events |> Enum.filter(&(&1.type == :run_started)) |> length() == 2
  end

  test "declared tools execute through the worker and produce durable tool history", context do
    Definitions.put(definition("alpha", tools: true))
    runtime = start_runtime(context)

    assert {:ok, _} = Runtime.start_agent(runtime, "alpha")

    assert {:ok, result} = Runtime.execute_tool(runtime, "alpha", "echo", %{"text" => "hi"})
    assert result.status == :ok
    assert result.output == "stub\n"

    assert {:ok, [first]} = Runtime.tool_history(runtime, "alpha")
    assert first.sequence == "1"
    assert first.tool_name == "echo"
    assert first.toolkit_id == "shell"
    assert first.status == "ok"
    assert first.truncated_result == "stub\n"
    assert first.arguments =~ "text"
    assert is_binary(first.call_id) and first.call_id != ""
    assert first.transcript_event_id == first.call_id

    assert {:ok, second} = Runtime.execute_tool(runtime, "alpha", "echo", %{"text" => "again"})
    assert second.output == "stub\n"
    assert {:ok, [_, second_record]} = Runtime.tool_history(runtime, "alpha")
    assert second_record.sequence == "2"

    assert {:ok, events} = Runtime.list_events(runtime, "alpha")
    assert Enum.any?(events, &(&1.type == :tool_call and &1.data["tool_name"] == "echo"))
    assert Enum.any?(events, &(&1.type == :tool_result and &1.data["status"] == "ok"))

    assert {:error, {:unknown_tool, "missing"}} =
             Runtime.execute_tool(runtime, "alpha", "missing", %{})

    assert {:ok, _} = Runtime.stop_agent(runtime, "alpha")
    assert {:error, :not_running} = Runtime.execute_tool(runtime, "alpha", "echo", %{})

    GenServer.stop(runtime)
    restarted = start_runtime(context)

    assert {:ok, [_, _] = records} = Runtime.tool_history(restarted, "alpha")
    assert Enum.map(records, & &1.sequence) == ["1", "2"]
    assert {:ok, events} = Runtime.list_events(restarted, "alpha")
    assert Enum.any?(events, &(&1.type == :agent_stopped))
  end

  test "a native toolkit executes in the runtime without a worker call", context do
    assert :ok =
             Patchbay.Toolkit.Registry.register(
               "runtime-native",
               Patchbay.RuntimeTest.NativeToolkit
             )

    on_exit(fn -> Patchbay.Toolkit.Registry.unregister("runtime-native") end)

    definition = definition("alpha")

    toolkits = [
      %Patchbay.Definition.Toolkit{toolkit: "runtime-native", native: "runtime-native"}
    ]

    Definitions.put(%{definition | toolkits: toolkits})
    runtime = start_runtime(context)

    assert {:ok, _} = Runtime.start_agent(runtime, "alpha")

    assert {:ok, result} =
             Runtime.execute_tool(runtime, "alpha", "native_echo", %{"text" => "hi"})

    assert result.status == :ok
    assert result.output == "alpha:hi"

    refute Enum.any?(
             Manager.calls(context.stub),
             &match?({:execute, "agent.alpha", "native_echo", _arguments, _timeout}, &1)
           )

    assert {:ok, [record]} = Runtime.tool_history(runtime, "alpha")
    assert record.tool_name == "native_echo"
    assert record.toolkit_id == "runtime-native"
  end

  test "implicit terminal tools resolve to a native dispatcher", context do
    Definitions.put(definition("alpha"))
    runtime = start_runtime(context)

    assert {:ok, _} = Runtime.start_agent(runtime, "alpha")

    assert {:error, {:runner_managed_tool, "complete_task"}} =
             Runtime.execute_tool(runtime, "alpha", "complete_task", %{})
  end

  test "lifecycle init and finalize hooks run with fixed variables", context do
    echo = System.find_executable("echo")

    hook = %Patchbay.Definition.Toolkit.Operation{
      name: "hook",
      executable: echo,
      argv: ["{%agent_id}"],
      arguments: %{}
    }

    lifecycle = %Patchbay.Definition.Lifecycle{
      kind: :one_shot,
      init: [%{hook | name: "init"}],
      finalize: [%{hook | name: "finalize"}]
    }

    definition = definition("alpha")
    Definitions.put(%{definition | lifecycle: lifecycle})
    runtime = start_runtime(context)

    assert {:ok, _} = Runtime.start_agent(runtime, "alpha")
    assert {:ok, _} = Runtime.stop_agent(runtime, "alpha")

    assert {:ok, events} = Runtime.list_events(runtime, "alpha")

    assert Enum.any?(
             events,
             &(&1.type == :hook_finished and &1.data["phase"] == "init" and
                 &1.data["hook"] == "init")
           )

    assert Enum.any?(
             events,
             &(&1.type == :hook_finished and &1.data["phase"] == "finalize" and
                 &1.data["hook"] == "finalize")
           )
  end

  test "finalize hooks clean up after a partial init failure", context do
    echo = System.find_executable("echo")
    false_exe = System.find_executable("false")
    sh = System.find_executable("sh")
    marker = Path.join(context.tmp, "finalized")

    hook = %Patchbay.Definition.Toolkit.Operation{
      name: "hook",
      executable: echo,
      argv: ["{%agent_id}"],
      arguments: %{}
    }

    finalize = %Patchbay.Definition.Toolkit.Operation{
      name: "cleanup",
      executable: sh,
      argv: ["-c", "touch #{marker}"],
      arguments: %{}
    }

    fail_hook = %Patchbay.Definition.Toolkit.Operation{
      name: "explode",
      executable: false_exe,
      argv: [],
      arguments: %{}
    }

    lifecycle = %Patchbay.Definition.Lifecycle{
      kind: :one_shot,
      init: [%{hook | name: "init"}, fail_hook],
      finalize: [finalize]
    }

    definition = definition("alpha")
    Definitions.put(%{definition | lifecycle: lifecycle})
    runtime = start_runtime(context)
    manager = context.stub

    Manager.set(manager, :start_results, [{:ok, %{worker_id: "agent.alpha", status: :starting}}])

    assert {:error, {:lifecycle_init, {"explode", _reason}}} =
             Runtime.start_agent(runtime, "alpha")

    assert File.exists?(marker)

    assert {:ok, events} = Runtime.list_events(runtime, "alpha")

    assert Enum.any?(events, fn event ->
             event.type == :hook_finished and event.data["phase"] == "finalize" and
               event.data["hook"] == "cleanup"
           end)
  end

  test "a failed worker start interrupts the run and the next start resumes its attempt",
       context do
    Definitions.put(definition("alpha"))
    Manager.set(context.stub, :start_results, [{:error, :worker_spawn_failed}])
    runtime = start_runtime(context)

    assert {:error, {:worker_start, :worker_spawn_failed}} =
             Runtime.start_agent(runtime, "alpha")

    assert {:ok, failed} = Runtime.get_agent(runtime, "alpha")
    assert failed.status == :failed
    assert failed.run_status == :interrupted
    assert failed.attempt_ordinal == 1
    assert failed.last_error == {:worker_start, :worker_spawn_failed}

    assert {:ok, resumed} = Runtime.start_agent(runtime, "alpha")
    assert resumed.status == :running
    assert resumed.run_id == failed.run_id
    assert resumed.attempt_ordinal == 2

    assert {:ok, events} = Runtime.list_events(runtime, "alpha")
    assert Enum.any?(events, &(&1.type == :agent_start_failed))
    assert Enum.any?(events, &(&1.type == :run_resumed))
  end

  test "a stale worker from a previous runtime is stopped before starting again", context do
    Definitions.put(definition("alpha"))
    Manager.set(context.stub, :start_results, [{:error, :already_started}])
    runtime = start_runtime(context)

    assert {:ok, running} = Runtime.start_agent(runtime, "alpha")
    assert running.status == :running

    calls = Manager.calls(context.stub)
    assert Enum.any?(calls, &match?({:stop_worker, "agent.alpha", _timeout}, &1))
    assert Enum.count(calls, &match?({:start_worker, "agent.alpha", _opts}, &1)) == 2
  end

  test "a worker stop failure leaves the agent running and is recorded", context do
    Definitions.put(definition("alpha"))
    Manager.set(context.stub, :stop_result, {:error, :supervisor_unavailable})
    runtime = start_runtime(context)

    assert {:ok, _} = Runtime.start_agent(runtime, "alpha")
    assert {:error, :supervisor_unavailable} = Runtime.stop_agent(runtime, "alpha")

    assert {:ok, running} = Runtime.get_agent(runtime, "alpha")
    assert running.status == :running

    assert {:ok, events} = Runtime.list_events(runtime, "alpha")
    assert Enum.any?(events, &(&1.type == :agent_stop_failed))

    Manager.set(context.stub, :stop_result, {:ok, %{status: :stopping}})
    assert {:ok, stopped} = Runtime.stop_agent(runtime, "alpha")
    assert stopped.status == :stopped
  end

  defp start_runtime(context, opts \\ []) do
    opts =
      Keyword.merge(
        [
          definitions: Definitions,
          state_dir: Path.join(context.tmp, "state"),
          workspace_dir: Path.join(context.tmp, "workspaces"),
          result_dir: Path.join(context.tmp, "results"),
          manager: context.stub,
          worker_client: WorkerClient
        ],
        opts
      )

    {:ok, runtime} = Runtime.start_link(opts)
    on_exit(fn -> if Process.alive?(runtime), do: GenServer.stop(runtime) end)
    runtime
  end

  defp definition(id, opts \\ []) do
    model = Keyword.get(opts, :model, "test-model")
    kind = Keyword.get(opts, :kind, "one-shot")
    tools = Keyword.get(opts, :tools, false)

    {:ok, definition} = Definition.parse(agent_toml(id, model, kind, tools))
    definition
  end

  defp agent_toml(id, model, kind \\ "one-shot", tools \\ false) do
    body = """
    format-version = 1
    id = "#{id}"

    [model]
    name = "#{model}"

    [lifecycle]
    kind = "#{kind}"
    """

    if tools do
      echo = System.find_executable("echo")

      body <>
        """

        [[toolkits]]
        toolkit = "shell"

        [[toolkits.operations]]
        name = "echo"
        executable = "#{echo}"
        argv = ["{text}"]

        [toolkits.operations.arguments.text]
        type = "string"
        """
    else
      body
    end
  end
end
