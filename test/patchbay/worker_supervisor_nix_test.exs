defmodule Patchbay.WorkerSupervisorNixTest do
  use ExUnit.Case, async: false

  alias Patchbay.CLI.Manager
  alias Patchbay.WorkerSupervisor

  @control_token "supervisor-nix-control-token-0123456789"
  @worker_token "worker-nix-token-0123456789"

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "patchbay-supervisor-nix-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    %{tmp: tmp}
  end

  test "runs the worker through fake nix with package argv and bare git resolution", %{
    tmp: tmp
  } do
    nix = fake_nix(tmp)
    worker = worker_script(tmp)
    log = Path.join(tmp, "worker.log")
    argv = Path.join(tmp, "nix.argv")

    {:ok, supervisor} = start_supervisor(tmp, worker, nix_executable: nix)
    {:ok, manager} = start_manager(tmp, supervisor)

    on_exit(fn -> safe_stop(manager) end)

    assert eventually(fn -> Manager.control_status(manager) == :connected end, 10_000)

    assert {:ok, %{worker_id: "agent.nix", status: :starting}} =
             Manager.start_worker(manager, "agent.nix",
               packages: ["git", "github:owner/repo#pkg"],
               timeout: 10_000
             )

    assert eventually(fn -> File.exists?(argv) and File.exists?(log) end, 10_000)

    assert File.read!(argv) |> String.split("\n", trim: true) == [
             "shell",
             "nixpkgs#git",
             "github:owner/repo#pkg",
             "--command",
             worker,
             "run-worker",
             "--worker-id",
             "agent.nix",
             "--manager-host",
             "127.0.0.1",
             "--manager-port",
             Integer.to_string(Manager.endpoint(manager).port)
           ]

    worker_log = File.read!(log)
    assert worker_log =~ "worker-args run-worker --worker-id agent.nix"
    assert worker_log =~ "fake-git --version"
  end

  test "no packages keeps the direct worker spawn", %{tmp: tmp} do
    nix = fake_nix(tmp)
    worker = worker_script(tmp)
    argv = Path.join(tmp, "nix.argv")

    {:ok, supervisor} = start_supervisor(tmp, worker, nix_executable: nix)

    on_exit(fn -> safe_stop(supervisor) end)

    assert {:start_worker_result, %{status: :started}} =
             WorkerSupervisor.request(supervisor, {:start_worker, request()})

    assert eventually(fn -> File.exists?(Path.join(tmp, "worker.log")) end, 10_000)
    refute File.exists?(argv)
  end

  test "reports nix startup failure output to the manager", %{tmp: tmp} do
    worker = worker_script(tmp)
    nix = failing_nix(tmp)

    {:ok, supervisor} = start_supervisor(tmp, worker, nix_executable: nix)
    {:ok, manager} = start_manager(tmp, supervisor)

    on_exit(fn -> safe_stop(manager) end)

    assert eventually(fn -> Manager.control_status(manager) == :connected end, 10_000)

    assert {:ok, %{worker_id: "agent.nix", status: :starting}} =
             Manager.start_worker(manager, "agent.nix", packages: ["missing"], timeout: 10_000)

    assert {:error, {:worker_exited, details}} =
             Manager.await_worker(manager, "agent.nix", 10_000)

    assert details.worker_exited.exit_status == 1
    assert details.worker_exited.output =~ "nix: package not found"
  end

  @tag timeout: 120_000
  test "real nix shell supplies bare git to a worker", %{tmp: tmp} do
    worker = worker_script(tmp)
    log = Path.join(tmp, "worker.log")

    {:ok, supervisor} = start_supervisor(tmp, worker)
    on_exit(fn -> safe_stop(supervisor) end)

    assert {:start_worker_result, %{status: :started}} =
             WorkerSupervisor.request(supervisor, {:start_worker, request(packages: ["git"])})

    assert eventually(fn -> File.exists?(log) end, 60_000)
    assert eventually(fn -> File.read!(log) =~ ~r/git version \d+\./ end, 60_000)
  end

  defp fake_nix(tmp) do
    git = Path.join([tmp, "fake-bin", "git"])
    File.mkdir_p!(Path.dirname(git))
    File.write!(git, "#!/bin/sh\nprintf 'fake-git %s\\n' \"$*\"\n")
    File.chmod!(git, 0o755)

    nix = Path.join(tmp, "nix")
    argv = Path.join(tmp, "nix.argv")

    File.write!(nix, """
    #!/bin/sh
    printf '%s\\n' "$@" > "#{argv}"
    shift
    while [ "$#" -gt 0 ] && [ "$1" != "--command" ]; do shift; done
    [ "$#" -gt 0 ] && shift
    PATH="#{Path.dirname(git)}"
    export PATH
    exec "$@"
    """)

    File.chmod!(nix, 0o755)
    nix
  end

  defp failing_nix(tmp) do
    nix = Path.join(tmp, "nix")

    File.write!(nix, """
    #!/bin/sh
    echo 'nix: package not found' >&2
    exit 1
    """)

    File.chmod!(nix, 0o755)
    nix
  end

  defp worker_script(tmp) do
    log = Path.join(tmp, "worker.log")

    worker = Path.join(tmp, "fake-worker")

    File.write!(worker, """
    #!/bin/sh
    printf 'worker-args %s\\n' "$*" >> "#{log}"
    git --version >> "#{log}"
    """)

    File.chmod!(worker, 0o755)
    worker
  end

  defp start_supervisor(tmp, worker, opts \\ []) do
    WorkerSupervisor.start_link(
      [
        control_token: @control_token,
        listen_port: 0,
        worker_executable: worker,
        worker_args: ["run-worker"],
        state_root: Path.join(tmp, "agents"),
        max_workers: 2
      ] ++ opts
    )
  end

  defp start_manager(tmp, supervisor) do
    Manager.start_link(
      supervisor_host: "127.0.0.1",
      supervisor_port: WorkerSupervisor.port(supervisor),
      control_token: @control_token,
      transcript_dir: Path.join(tmp, "transcripts")
    )
  end

  defp request(opts \\ []) do
    %{
      request_id: "request-#{System.unique_integer([:positive])}",
      worker_id: "agent.nix",
      token: @worker_token,
      manager_host: "127.0.0.1",
      manager_port: 4123
    }
    |> Map.put(:packages, Keyword.get(opts, :packages, []))
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
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
        Process.sleep(25)
        do_eventually(fun, deadline)
      end
    end
  end
end
