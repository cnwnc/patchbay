defmodule Patchbay.IntegrationTest do
  use ExUnit.Case, async: false

  alias Patchbay.CLI.Manager
  alias Patchbay.Worker.Operations
  alias Patchbay.Worker.Protocol
  alias Patchbay.Worker.Protocol.Stream
  alias Patchbay.WorkerSupervisor

  @control_token "integration-control-token-0123456789"

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "patchbay-integration-#{System.unique_integer([:positive])}")

    workspace = Path.join(tmp, "workspace")
    transcript_dir = Path.join(tmp, "transcripts")
    File.mkdir_p!(workspace)
    File.mkdir_p!(transcript_dir)
    on_exit(fn -> File.rm_rf(tmp) end)

    echo = executable!("echo")
    sleep = executable!("sleep")
    sh = executable!("sh")
    sleep_pid_path = Path.join(tmp, "sleep.pid")
    operations_path = Path.join(tmp, "operations.pbt")

    operations = [
      %{
        name: "echo",
        executable: echo,
        argv: ["{text}"],
        arguments: %{"text" => %{type: :string, required: true}}
      },
      %{
        name: "sleep",
        executable: sleep,
        argv: ["{seconds}"],
        arguments: %{"seconds" => %{type: :integer, required: true}}
      },
      %{
        name: "record_sleep",
        executable: sh,
        argv: ["-c", "echo $$ > #{sleep_pid_path}; sleep 30"],
        arguments: %{}
      }
    ]

    File.write!(operations_path, :erlang.term_to_binary(operations))

    assert {:ok, [%{name: "echo"}, %{name: "sleep"}, %{name: "record_sleep"}]} =
             Operations.load(operations_path)

    %{
      tmp: tmp,
      workspace: workspace,
      transcript_dir: transcript_dir,
      operations_path: operations_path,
      sleep_pid_path: sleep_pid_path
    }
  end

  test "manager starts an independent worker that executes a fixed operation", context do
    supervisor =
      start_supervisor(context)

    manager =
      start_manager(context, supervisor)

    on_exit(fn ->
      safe_stop(manager)
    end)

    assert eventually(fn -> Manager.control_status(manager) == :connected end, 10_000)

    assert {:ok, %{worker_id: "agent-one", status: :starting}} =
             Manager.start_worker(manager, "agent-one", timeout: 10_000)

    assert {:ok, %{status: :ready}} = Manager.await_worker(manager, "agent-one", 20_000)

    assert {:ok, result} =
             Manager.execute(
               manager,
               "agent-one",
               "echo",
               %{"text" => "hello; echo pwned"},
               10_000
             )

    assert result.status == :ok
    assert result.exit_status == 0
    assert result.output == "hello; echo pwned\n"

    assert {:ok, failed} =
             Manager.execute(manager, "agent-one", "not-an-operation", %{}, 10_000)

    assert failed.status == :error
    assert {:unknown_operation, "not-an-operation"} = failed.error

    assert {:ok, %{status: :stopping}} = Manager.stop_worker(manager, "agent-one")
    assert eventually(fn -> WorkerSupervisor.list_workers(supervisor) == [] end, 10_000)

    transcript = Manager.transcript_path(manager, "agent-one")
    assert File.exists?(transcript)
    assert mode(context.transcript_dir) == 0o700
    assert mode(transcript) == 0o600

    {:ok, messages, _stream} = Stream.feed(Stream.new(), File.read!(transcript))

    events =
      Enum.map(messages, fn
        {:event, event} -> event
        other -> flunk("unexpected transcript record: #{inspect(other)}")
      end)

    assert Enum.any?(events, &(&1.type == :worker_ready and &1.worker_id == "agent-one"))

    assert Enum.any?(events, fn event ->
             event.type == :tool_result and event.output == "hello; echo pwned\n"
           end)

    assert Enum.any?(events, fn event ->
             event.type == :tool_call and event.operation == "echo" and
               event.arguments == %{"text" => "hello; echo pwned"}
           end)

    assert Protocol.term_allowed?(events)
  end

  test "worker exits when its manager channel closes", context do
    supervisor = start_supervisor(context)
    manager = start_manager(context, supervisor)

    assert eventually(fn -> Manager.control_status(manager) == :connected end, 10_000)
    assert {:ok, _} = Manager.start_worker(manager, "agent-two", timeout: 10_000)
    assert {:ok, %{status: :ready}} = Manager.await_worker(manager, "agent-two", 20_000)

    GenServer.stop(manager)

    assert eventually(fn -> WorkerSupervisor.list_workers(supervisor) == [] end, 15_000)
  end

  defp start_supervisor(context) do
    ebin = Path.join(Mix.Project.build_path(), "lib/patchbay/ebin")
    elixir = executable!("elixir")

    assert File.dir?(ebin)

    {:ok, supervisor} =
      WorkerSupervisor.start_link(
        control_token: @control_token,
        worker_executable: elixir,
        worker_args: ["-pa", ebin, "-e", "Patchbay.Worker.main()", "--"],
        operations_path: context.operations_path,
        workspace: context.workspace,
        max_workers: 4
      )

    on_exit(fn ->
      safe_stop(supervisor)
    end)

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
        Process.sleep(50)
        do_eventually(fun, deadline)
      end
    end
  end

  test "worker execution timeout is enforced by the worker and reported as a result", context do
    supervisor = start_supervisor(context)
    manager = start_manager(context, supervisor)

    on_exit(fn -> safe_stop(manager) end)

    assert eventually(fn -> Manager.control_status(manager) == :connected end, 10_000)
    assert {:ok, _} = Manager.start_worker(manager, "agent-timeout", timeout: 10_000)
    assert {:ok, %{status: :ready}} = Manager.await_worker(manager, "agent-timeout", 20_000)

    started = System.monotonic_time(:millisecond)

    assert {:ok, result} =
             Manager.execute(manager, "agent-timeout", "sleep", %{"seconds" => 30}, 300)

    elapsed = System.monotonic_time(:millisecond) - started
    assert result.status == :error
    assert result.error == :timeout
    assert elapsed < 5_000
  end

  test "invalid UTF-8 arguments are execution errors and the worker survives", context do
    supervisor = start_supervisor(context)
    manager = start_manager(context, supervisor)

    on_exit(fn -> safe_stop(manager) end)

    assert eventually(fn -> Manager.control_status(manager) == :connected end, 10_000)
    assert {:ok, _} = Manager.start_worker(manager, "agent-utf8", timeout: 10_000)
    assert {:ok, %{status: :ready}} = Manager.await_worker(manager, "agent-utf8", 20_000)

    assert {:ok, %{status: :error, error: {:invalid_argument, "text"}}} =
             Manager.execute(manager, "agent-utf8", "echo", %{"text" => <<0xFF>>}, 10_000)

    assert {:ok, %{status: :ok, output: "fine\n"}} =
             Manager.execute(manager, "agent-utf8", "echo", %{"text" => "fine"}, 10_000)
  end

  test "a dead session cannot mark a replacement session down", context do
    supervisor = start_supervisor(context)
    manager = start_manager(context, supervisor)

    on_exit(fn -> safe_stop(manager) end)

    assert eventually(fn -> Manager.control_status(manager) == :connected end, 10_000)
    assert {:ok, _} = Manager.start_worker(manager, "agent-session", timeout: 10_000)
    assert {:ok, %{status: :ready}} = Manager.await_worker(manager, "agent-session", 20_000)

    state = :sys.get_state(manager)
    worker = state.workers["agent-session"]
    session = worker.session
    stale = spawn(fn -> Process.sleep(5_000) end)

    GenServer.cast(manager, {:session_down, "agent-session", stale, :stale})

    assert eventually(fn ->
             :sys.get_state(manager).workers["agent-session"].status == :ready
           end)

    Process.exit(session, :kill)

    assert eventually(fn ->
             state = :sys.get_state(manager)

             state.workers["agent-session"].status == :exited and state.sessions == %{} and
               state.session_monitors == %{}
           end)

    assert {:error, :worker_exited} =
             GenServer.call(manager, {:worker_hello, "agent-session", worker.token, stale})
  end

  test "stopping a worker kills its OS process group", context do
    tmp = Path.join(context.tmp, "stopped-worker")
    File.mkdir_p!(tmp)
    pid_file = Path.join(tmp, "pid")
    child_file = Path.join(tmp, "child")
    script = "echo $$ > #{pid_file}; sleep 30 & echo $! > #{child_file}; wait"

    assert {:ok, supervisor} =
             WorkerSupervisor.start_link(
               control_token: @control_token,
               worker_executable: executable!("sh"),
               worker_args: ["-c", script, "--"],
               max_workers: 2
             )

    on_exit(fn -> safe_stop(supervisor) end)

    request = %{
      request_id: "start-1",
      worker_id: "sleeping",
      token: "worker-token-0123456789",
      manager_host: "127.0.0.1",
      manager_port: 4040
    }

    assert {:start_worker_result, %{status: :started, os_pid: os_pid}} =
             WorkerSupervisor.request(supervisor, {:start_worker, request})

    assert eventually(fn -> File.exists?(pid_file) and File.exists?(child_file) end)
    pid = pid_file |> File.read!() |> String.trim() |> String.to_integer()
    child = child_file |> File.read!() |> String.trim() |> String.to_integer()
    assert pid == os_pid

    assert {:stop_worker_result, %{status: :stopping}} =
             WorkerSupervisor.request(
               supervisor,
               {:stop_worker, %{request_id: "stop-1", worker_id: "sleeping"}}
             )

    assert eventually(fn -> not File.exists?("/proc/#{pid}") end)
    assert eventually(fn -> not File.exists?("/proc/#{child}") end)
    assert eventually(fn -> WorkerSupervisor.list_workers(supervisor) == [] end)
  end

  test "stopping a worker kills an in-flight operation process", context do
    supervisor = start_supervisor(context)
    manager = start_manager(context, supervisor)

    on_exit(fn -> safe_stop(manager) end)

    assert eventually(fn -> Manager.control_status(manager) == :connected end, 10_000)
    assert {:ok, _} = Manager.start_worker(manager, "agent-inflight", timeout: 10_000)
    assert {:ok, %{status: :ready}} = Manager.await_worker(manager, "agent-inflight", 20_000)

    task =
      Task.async(fn ->
        Manager.execute(manager, "agent-inflight", "record_sleep", %{}, 20_000)
      end)

    assert eventually(fn -> File.exists?(context.sleep_pid_path) end, 10_000)
    pid = context.sleep_pid_path |> File.read!() |> String.trim() |> String.to_integer()

    assert {:ok, %{status: :stopping}} = Manager.stop_worker(manager, "agent-inflight")

    assert eventually(fn -> not File.exists?("/proc/#{pid}") end, 10_000)

    result = Task.await(task, 10_000)
    refute match?({:ok, %{status: :ok}}, result)
  end

  test "workers do not inherit control tokens or provider credentials", context do
    tmp = Path.join(context.tmp, "env-worker")
    File.mkdir_p!(tmp)
    env_file = Path.join(tmp, "env")
    token = "control-token-0123456789"

    System.put_env("PATCHBAY_CONTROL_TOKEN", token)
    System.put_env("ANTHROPIC_API_KEY", "provider-secret-value")

    on_exit(fn ->
      System.delete_env("PATCHBAY_CONTROL_TOKEN")
      System.delete_env("ANTHROPIC_API_KEY")
    end)

    {:ok, supervisor} =
      WorkerSupervisor.start_link(
        control_token: token,
        worker_executable: executable!("sh"),
        worker_args: ["-c", "env > #{env_file}; sleep 30", "--"],
        max_workers: 2
      )

    on_exit(fn -> safe_stop(supervisor) end)

    request = %{
      request_id: "start-env",
      worker_id: "env-worker",
      token: "worker-token-0123456789",
      manager_host: "127.0.0.1",
      manager_port: 4041
    }

    assert {:start_worker_result, %{status: :started}} =
             WorkerSupervisor.request(supervisor, {:start_worker, request})

    assert eventually(fn -> File.exists?(env_file) end)
    env = File.read!(env_file)
    assert env =~ "PATCHBAY_WORKER_TOKEN="
    refute env =~ token
    refute env =~ "provider-secret-value"
    refute env =~ "PATCHBAY_CONTROL_TOKEN"
  end

  test "an unexpected worker VM death kills its in-flight operation process", context do
    supervisor = start_supervisor(context)
    manager = start_manager(context, supervisor)

    on_exit(fn -> safe_stop(manager) end)

    assert eventually(fn -> Manager.control_status(manager) == :connected end, 10_000)
    assert {:ok, _} = Manager.start_worker(manager, "agent-killed", timeout: 10_000)
    assert {:ok, %{status: :ready}} = Manager.await_worker(manager, "agent-killed", 20_000)

    task =
      Task.async(fn ->
        Manager.execute(manager, "agent-killed", "record_sleep", %{}, 20_000)
      end)

    assert eventually(fn -> File.exists?(context.sleep_pid_path) end, 10_000)
    pid = context.sleep_pid_path |> File.read!() |> String.trim() |> String.to_integer()

    assert [%{worker_id: "agent-killed", os_pid: os_pid}] =
             WorkerSupervisor.list_workers(supervisor)

    assert {_output, 0} =
             System.cmd(executable!("kill"), ["-KILL", Integer.to_string(os_pid)])

    assert eventually(fn -> not File.exists?("/proc/#{pid}") end, 10_000)
    assert eventually(fn -> WorkerSupervisor.list_workers(supervisor) == [] end, 10_000)

    result = Task.await(task, 10_000)
    refute match?({:ok, %{status: :ok}}, result)
  end

  defp safe_stop(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
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
