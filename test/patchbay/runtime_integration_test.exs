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
