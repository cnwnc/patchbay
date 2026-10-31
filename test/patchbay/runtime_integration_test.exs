defmodule Patchbay.RuntimeIntegrationTest do
  use ExUnit.Case, async: false

  alias Patchbay.CLI.Manager
  alias Patchbay.Definition
  alias Patchbay.Runtime
  alias Patchbay.Worker.Operations
  alias Patchbay.WorkerSupervisor

  @control_token "runtime-integration-control-token-0123456789"

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "patchbay-runtime-integration-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace = Path.join(tmp, "workspace")
    transcript_dir = Path.join(tmp, "transcripts")
    state_dir = Path.join(tmp, "state")
    operations_path = Path.join(tmp, "operations.pbt")
    File.mkdir_p!(workspace)
    File.mkdir_p!(transcript_dir)
    on_exit(fn -> File.rm_rf(tmp) end)

    echo = executable!("echo")

    operations = [
      %{
        name: "echo",
        executable: echo,
        argv: ["{text}"],
        arguments: %{"text" => %{type: :string, required: true}}
      }
    ]

    File.write!(operations_path, :erlang.term_to_binary(operations))
    assert {:ok, [%{name: "echo"}]} = Operations.load(operations_path)

    %{
      tmp: tmp,
      workspace: workspace,
      transcript_dir: transcript_dir,
      state_dir: state_dir,
      operations_path: operations_path,
      echo: echo
    }
  end

  test "the runtime starts a real worker and executes a declared tool", context do
    supervisor = start_supervisor(context)
    manager = start_manager(context, supervisor)
    on_exit(fn -> safe_stop(manager) end)

    assert eventually(fn -> Manager.control_status(manager) == :connected end, 10_000)

    definition = definition(context.echo)

    {:ok, runtime} =
      Runtime.start_link(
        definitions: %{"agent-one" => definition},
        state_dir: context.state_dir,
        workspace_dir: Path.join(context.tmp, "workspaces"),
        result_dir: Path.join(context.tmp, "results"),
        manager: manager
      )

    on_exit(fn -> safe_stop(runtime) end)

    assert {:ok, running} =
             Runtime.start_agent(runtime, "agent-one", timeout: 10_000, await_timeout: 20_000)

    assert running.status == :running
    assert running.definition_revision == 1
    assert running.lifecycle_kind == :one_shot

    assert {:ok, result} =
             Runtime.execute_tool(runtime, "agent-one", "echo", %{"text" => "hello"},
               timeout: 10_000
             )

    assert result.status == :ok
    assert result.output == "hello\n"

    assert {:ok, transcript} = Runtime.transcript_path(runtime, "agent-one")
    assert File.exists?(transcript)

    assert {:ok, events} = Runtime.list_events(runtime, "agent-one")
    assert Enum.any?(events, &(&1.type == :run_started))
    assert Enum.any?(events, &(&1.type == :tool_call))
    assert Enum.any?(events, &(&1.type == :tool_result))

    assert {:ok, [record]} = Runtime.tool_history(runtime, "agent-one")
    assert record.tool_name == "echo"
    assert record.status == "ok"
    assert record.truncated_result == "hello\n"
    assert record.transcript_event_id != ""

    assert {:ok, stopped} = Runtime.stop_agent(runtime, "agent-one")
    assert stopped.status == :stopped
    assert stopped.run_status == :cancelled

    assert eventually(fn -> WorkerSupervisor.list_workers(supervisor) == [] end, 10_000)
  end

  test "the runtime distributes manifest fixed operations and fixed variables to a real worker",
       context do
    definition = manifest_definition(context)
    supervisor = start_supervisor(context)
    manager = start_manager(context, supervisor)
    on_exit(fn -> safe_stop(manager) end)

    assert eventually(fn -> Manager.control_status(manager) == :connected end, 10_000)

    {:ok, runtime} =
      Runtime.start_link(
        definitions: %{"probe-agent" => definition},
        state_dir: context.state_dir,
        workspace_dir: Path.join(context.tmp, "workspaces"),
        result_dir: Path.join(context.tmp, "results"),
        manager: manager
      )

    on_exit(fn -> safe_stop(runtime) end)

    assert {:ok, running} =
             Runtime.start_agent(runtime, "probe-agent", timeout: 10_000, await_timeout: 20_000)

    assert {:ok, result} =
             Runtime.execute_tool(runtime, "probe-agent", "probe", %{}, timeout: 10_000)

    assert result.status == :ok

    assert result.output ==
             "#{running.run_id} running #{running.attempt_id}\n"

    assert File.dir?(Path.join([context.tmp, "workspaces", "probe-agent"]))
    assert File.dir?(Path.join([context.tmp, "results", "probe-agent"]))
    assert File.dir?(Path.join([context.state_dir, "agents", "probe-agent"]))

    agent_state = Path.join([context.tmp, "agent-state", running.worker_id])
    operations_file = Path.join(agent_state, "operations.pbt")
    assert File.exists?(operations_file)
    assert mode(operations_file) == 0o600
    refute File.dir?(Path.join(context.transcript_dir, "operations"))

    assert {:ok, stopped} = Runtime.stop_agent(runtime, "probe-agent")
    assert stopped.status == :stopped

    assert eventually(fn -> WorkerSupervisor.list_workers(supervisor) == [] end, 10_000)
  end

  test "lifecycle hooks run inside the agent worker and write its workspace", context do
    sh = System.find_executable("sh")

    definition = hook_definition(context, "hook-agent", sh)
    supervisor = start_supervisor(context)
    manager = start_manager(context, supervisor)
    on_exit(fn -> safe_stop(manager) end)

    assert eventually(fn -> Manager.control_status(manager) == :connected end, 10_000)

    {:ok, runtime} =
      Runtime.start_link(
        definitions: %{"hook-agent" => definition},
        state_dir: context.state_dir,
        workspace_dir: Path.join(context.tmp, "workspaces"),
        result_dir: Path.join(context.tmp, "results"),
        manager: manager
      )

    on_exit(fn -> safe_stop(runtime) end)

    assert {:ok, _running} =
             Runtime.start_agent(runtime, "hook-agent", timeout: 10_000, await_timeout: 20_000)

    workspace = Path.join([context.tmp, "workspaces", "hook-agent"])

    # The init hook created the file through the worker, including the
    # leading directories, which the manager UID cannot do cross-UID.
    assert File.read!(Path.join(workspace, "run/deep/nested/proof.txt")) == "worker-written\n"

    # The hook ran inside the worker: only worker-spawned children see the
    # worker instance environment the supervisor injects.
    instance = String.trim(File.read!(Path.join(workspace, "worker-instance.txt")))
    assert byte_size(instance) > 0

    assert {:ok, stopped} = Runtime.stop_agent(runtime, "hook-agent")
    assert stopped.status == :stopped

    # Finalize hooks run before the worker is stopped, so they can still
    # write agent-owned files through the worker.
    assert File.read!(Path.join(workspace, "finalized.txt")) == "done\n"

    assert eventually(fn -> WorkerSupervisor.list_workers(supervisor) == [] end, 10_000)
  end

  test "a disabled workspace starts a worker without a workspace directory", context do
    echo = System.find_executable("echo")
    id = "workspace-off"

    config_root = Path.join(context.tmp, "config")
    agent_dir = Path.join([config_root, "agents", id])
    File.mkdir_p!(agent_dir)

    toolkit_dir = Path.join(config_root, "toolkits")
    File.mkdir_p!(toolkit_dir)

    File.write!(Path.join(agent_dir, "agent.toml"), """
    format-version = 1
    id = "#{id}"

    [model]
    name = "test-model"

    [lifecycle]
    kind = "one-shot"

    [workspace]
    enabled = false

    [[toolkits]]
    toolkit = "probe"

    [[toolkits.operations]]
    name = "probe"
    executable = "#{echo}"
    argv = ["{%agent_id}"]
    """)

    File.write!(Path.join(toolkit_dir, "probe.toml"), """
    name = "probe"
    description = "Probe."

    [[operations]]
    name = "probe"
    argv = ["echo", "{%agent_id}"]
    """)

    assert {:ok, definition} = Definition.load(agent_dir)

    supervisor = start_supervisor(context)
    manager = start_manager(context, supervisor)
    on_exit(fn -> safe_stop(manager) end)

    assert eventually(fn -> Manager.control_status(manager) == :connected end, 10_000)

    {:ok, runtime} =
      Runtime.start_link(
        definitions: %{id => definition},
        state_dir: context.state_dir,
        workspace_dir: Path.join(context.tmp, "workspaces"),
        result_dir: Path.join(context.tmp, "results"),
        manager: manager
      )

    on_exit(fn -> safe_stop(runtime) end)

    assert {:ok, _running} =
             Runtime.start_agent(runtime, id, timeout: 10_000, await_timeout: 20_000)

    # Neither the runtime nor the supervisor allocate a workspace directory.
    refute File.dir?(Path.join([context.tmp, "workspaces", id]))

    assert {:ok, result} = Runtime.execute_tool(runtime, id, "probe", %{}, timeout: 10_000)
    assert result.status == :ok
    assert result.output == "#{id}\n"

    assert {:ok, stopped} = Runtime.stop_agent(runtime, id)
    assert stopped.status == :stopped

    assert eventually(fn -> WorkerSupervisor.list_workers(supervisor) == [] end, 10_000)
  end

  test "a filesystem toolkit rooted at {%workspace} reads and writes through the runtime",
       context do
    id = "fs-root-agent"

    config_root = Path.join(context.tmp, "config")
    agent_dir = Path.join([config_root, "agents", id])
    File.mkdir_p!(agent_dir)

    File.write!(
      Path.join(agent_dir, "agent.toml"),
      """
      format-version = 1
      id = "#{id}"

      [model]
      name = "test-model"

      [lifecycle]
      kind = "one-shot"

      [[toolkits]]
      toolkit = "filesystem"

      [toolkits.config]
      root = "{%workspace}"
      """
    )

    assert {:ok, definition} = Definition.load(agent_dir)

    supervisor = start_supervisor(context)
    manager = start_manager(context, supervisor)
    on_exit(fn -> safe_stop(manager) end)

    assert eventually(fn -> Manager.control_status(manager) == :connected end, 10_000)

    {:ok, runtime} =
      Runtime.start_link(
        definitions: %{id => definition},
        state_dir: context.state_dir,
        workspace_dir: Path.join(context.tmp, "workspaces"),
        result_dir: Path.join(context.tmp, "results"),
        manager: manager
      )

    on_exit(fn -> safe_stop(runtime) end)

    assert {:ok, _running} =
             Runtime.start_agent(runtime, id, timeout: 10_000, await_timeout: 20_000)

    assert {:ok, written} =
             Runtime.execute_tool(
               runtime,
               id,
               "write_file",
               %{"path" => "notes/a.txt", "content" => "from the model"},
               timeout: 10_000
             )

    assert written.status == :ok

    assert File.read!(Path.join([context.tmp, "workspaces", id, "notes/a.txt"])) ==
             "from the model"

    assert {:ok, read} =
             Runtime.execute_tool(runtime, id, "read_file", %{"path" => "notes/a.txt"},
               timeout: 10_000
             )

    assert read.output == "from the model"

    assert {:error, {:path_traversal_not_allowed, "../escape.txt"}} =
             Runtime.execute_tool(
               runtime,
               id,
               "write_file",
               %{"path" => "../escape.txt", "content" => "no"},
               timeout: 10_000
             )

    # A link the agent planted in its own workspace still cannot lead the
    # tool into manager-owned state: the worker resolves it and refuses.
    File.ln_s!(context.state_dir, Path.join([context.tmp, "workspaces", id, "manager"]))

    assert {:error, {:path_escapes_root, _link}} =
             Runtime.execute_tool(runtime, id, "read_file", %{"path" => "manager/events"},
               timeout: 10_000
             )

    assert {:ok, _stopped} = Runtime.stop_agent(runtime, id)
  end

  test "a filesystem toolkit rooted at {%result_dir} reads and writes through the runtime",
       context do
    id = "fs-result-agent"

    config_root = Path.join(context.tmp, "config")
    agent_dir = Path.join([config_root, "agents", id])
    File.mkdir_p!(agent_dir)

    File.write!(
      Path.join(agent_dir, "agent.toml"),
      """
      format-version = 1
      id = "#{id}"

      [model]
      name = "test-model"

      [lifecycle]
      kind = "one-shot"

      [[toolkits]]
      toolkit = "filesystem"

      [toolkits.config]
      root = "{%result_dir}"
      """
    )

    assert {:ok, definition} = Definition.load(agent_dir)

    supervisor = start_supervisor(context)
    manager = start_manager(context, supervisor)
    on_exit(fn -> safe_stop(manager) end)

    assert eventually(fn -> Manager.control_status(manager) == :connected end, 10_000)

    {:ok, runtime} =
      Runtime.start_link(
        definitions: %{id => definition},
        state_dir: context.state_dir,
        workspace_dir: Path.join(context.tmp, "workspaces"),
        result_dir: Path.join(context.tmp, "results"),
        manager: manager
      )

    on_exit(fn -> safe_stop(runtime) end)

    assert {:ok, _running} =
             Runtime.start_agent(runtime, id, timeout: 10_000, await_timeout: 20_000)

    assert {:ok, written} =
             Runtime.execute_tool(
               runtime,
               id,
               "write_file",
               %{"path" => "report.txt", "content" => "result-owned"},
               timeout: 10_000
             )

    assert written.status == :ok

    assert File.read!(Path.join([context.tmp, "results", id, "report.txt"])) ==
             "result-owned"

    assert {:ok, read} =
             Runtime.execute_tool(runtime, id, "read_file", %{"path" => "report.txt"},
               timeout: 10_000
             )

    assert read.output == "result-owned"

    assert {:ok, _stopped} = Runtime.stop_agent(runtime, id)
  end

  defp hook_definition(context, id, sh) do
    config_root = Path.join(context.tmp, "config")
    agent_dir = Path.join([config_root, "agents", id])
    File.mkdir_p!(agent_dir)

    File.write!(Path.join(agent_dir, "agent.toml"), """
    format-version = 1
    id = "#{id}"

    [model]
    name = "test-model"

    [lifecycle]
    kind = "one-shot"

    [[lifecycle.init]]
    name = "scratch"
    executable = "#{sh}"
    argv = ["-c", "mkdir -p {%workspace}/run/deep/nested && echo worker-written > {%workspace}/run/deep/nested/proof.txt && printf %s $PATCHBAY_WORKER_INSTANCE > {%workspace}/worker-instance.txt"]

    [[lifecycle.finalize]]
    name = "leave"
    executable = "#{sh}"
    argv = ["-c", "echo done > {%workspace}/finalized.txt"]
    """)

    assert {:ok, definition} = Definition.load(agent_dir)
    definition
  end

  defp manifest_definition(context) do
    config_root = Path.join(context.tmp, "config")
    toolkit_dir = Path.join(config_root, "toolkits")
    agent_dir = Path.join([config_root, "agents", "probe-agent"])
    File.mkdir_p!(toolkit_dir)
    File.mkdir_p!(agent_dir)

    File.write!(
      Path.join(toolkit_dir, "probe.toml"),
      """
      name = "probe"
      description = "Reports runtime fixed variables."

      [[operations]]
      name = "probe"
      argv = ["#{context.echo}", "{%run_id}", "{%agent_state}", "{%attempt_id}"]
      """
    )

    File.write!(
      Path.join(agent_dir, "agent.toml"),
      """
      format-version = 1
      id = "probe-agent"

      [model]
      name = "test-model"

      [lifecycle]
      kind = "one-shot"

      [[toolkits]]
      toolkit = "probe"
      """
    )

    assert {:ok, definition} = Definition.load(agent_dir)
    definition
  end

  defp definition(echo) do
    body = """
    format-version = 1
    id = "agent-one"

    [model]
    name = "test-model"

    [lifecycle]
    kind = "one-shot"

    [[toolkits]]
    toolkit = "shell"

    [[toolkits.operations]]
    name = "echo"
    executable = "#{echo}"
    argv = ["{text}"]

    [toolkits.operations.arguments.text]
    type = "string"
    """

    {:ok, definition} = Definition.parse(body)
    definition
  end

  defp start_supervisor(context) do
    ebin = Path.join(Mix.Project.build_path(), "lib/patchbay/ebin")
    elixir = executable!("elixir")

    {:ok, supervisor} =
      WorkerSupervisor.start_link(
        control_token: @control_token,
        worker_executable: elixir,
        worker_args: ["-pa", ebin, "-e", "Patchbay.Worker.main()", "--"],
        operations_path: context.operations_path,
        workspace: context.workspace,
        workspace_root: Path.join(context.tmp, "workspaces"),
        result_root: Path.join(context.tmp, "results"),
        state_root: Path.join(context.tmp, "agent-state"),
        max_workers: 2
      )

    on_exit(fn -> safe_stop(supervisor) end)
    supervisor
  end

  defp start_manager(context, supervisor) do
    {:ok, manager} =
      Manager.start_link(
        supervisor_host: "127.0.0.1",
        supervisor_port: WorkerSupervisor.port(supervisor),
        control_token: @control_token,
        transcript_dir: context.transcript_dir
      )

    manager
  end

  defp eventually(fun, timeout) when is_function(fun, 0) do
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
        Process.sleep(50)
        do_eventually(fun, deadline)
      end
    end
  end

  defp safe_stop(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp executable!(name) do
    case System.find_executable(name) do
      nil -> flunk("missing executable in test environment: #{name}")
      path -> path
    end
  end

  defp mode(path) do
    %File.Stat{mode: mode} = File.stat!(path)
    Bitwise.band(mode, 0o777)
  end
end
