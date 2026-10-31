defmodule Patchbay.WorkerSupervisorTeardownTest do
  use ExUnit.Case, async: false

  alias Patchbay.WorkerSupervisor

  @control_token "supervisor-teardown-control-token-0123456789"
  @worker_token "worker-teardown-token-0123456789"

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "patchbay-supervisor-teardown-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    %{
      tmp: tmp,
      workspaces: Path.join(tmp, "workspaces"),
      results: Path.join(tmp, "results"),
      agents: Path.join(tmp, "agents")
    }
  end

  test "destroy is scoped to the worker's recorded workspace", context do
    supervisor = start_supervisor(context)

    assert {:start_worker_result, %{status: :started}} =
             WorkerSupervisor.request(supervisor, start_request("agent.one"))

    alpha_workspace = Path.join(context.workspaces, "agent.one")
    beta_workspace = Path.join(context.workspaces, "agent.two")
    assert eventually(fn -> File.dir?(alpha_workspace) end)

    assert {:start_worker_result, %{status: :started}} =
             WorkerSupervisor.request(supervisor, start_request("agent.two"))

    assert eventually(fn -> File.dir?(beta_workspace) end)
    File.write!(Path.join(alpha_workspace, "alpha.txt"), "alpha")
    File.write!(Path.join(beta_workspace, "beta.txt"), "beta")

    assert {:teardown_workspace_result, %{status: :ok, action: :destroy, path: ^alpha_workspace}} =
             teardown(supervisor, "agent.one", :destroy)

    refute File.exists?(alpha_workspace)
    assert File.read!(Path.join(beta_workspace, "beta.txt")) == "beta"
  end

  test "export copies the workspace into the worker-owned result area and reports it",
       context do
    supervisor = start_supervisor(context)

    assert {:start_worker_result, %{status: :started}} =
             WorkerSupervisor.request(supervisor, start_request("agent.export"))

    workspace = Path.join(context.workspaces, "agent.export")
    assert eventually(fn -> File.dir?(workspace) end)
    File.mkdir_p!(Path.join(workspace, "notes"))
    File.write!(Path.join(workspace, "notes/result.txt"), "exported bytes")

    result_dir = Path.join(context.results, "agent.export")
    destination = Path.join(result_dir, "workspace")

    assert {:teardown_workspace_result, %{status: :ok, action: :export, path: ^destination}} =
             teardown(supervisor, "agent.export", :export)

    assert File.read!(Path.join(destination, "notes/result.txt")) == "exported bytes"
    refute File.exists?(workspace)
  end

  test "retain leaves the workspace in place", context do
    supervisor = start_supervisor(context)

    assert {:start_worker_result, %{status: :started}} =
             WorkerSupervisor.request(supervisor, start_request("agent.retain"))

    workspace = Path.join(context.workspaces, "agent.retain")
    assert eventually(fn -> File.dir?(workspace) end)
    File.write!(Path.join(workspace, "keep.txt"), "kept")

    assert {:teardown_workspace_result, %{status: :ok, action: :retain, path: nil}} =
             teardown(supervisor, "agent.retain", :retain)

    assert File.read!(Path.join(workspace, "keep.txt")) == "kept"
  end

  test "teardown refuses unknown workers, invalid ids, and symlinked workspaces", context do
    supervisor = start_supervisor(context)

    assert {:teardown_workspace_result, %{status: :error, error: :workspace_not_found}} =
             teardown(supervisor, "agent.unknown", :destroy)

    assert {:teardown_workspace_result, %{status: :error, error: :invalid_worker_id}} =
             teardown(supervisor, "../escape", :destroy)

    assert {:teardown_workspace_result, %{status: :error, error: :invalid_teardown_action}} =
             teardown(supervisor, "agent.one", :shred)

    assert {:start_worker_result, %{status: :started}} =
             WorkerSupervisor.request(supervisor, start_request("agent.symlink"))

    workspace = Path.join(context.workspaces, "agent.symlink")
    assert eventually(fn -> File.dir?(workspace) end)

    sentinel = Path.join(context.tmp, "sentinel")
    File.mkdir_p!(sentinel)
    File.write!(Path.join(sentinel, "must-survive.txt"), "untouched")

    File.rm_rf!(workspace)
    File.ln_s!(sentinel, workspace)

    assert {:teardown_workspace_result, %{status: :error, error: :invalid_workspace}} =
             teardown(supervisor, "agent.symlink", :destroy)

    assert File.read!(Path.join(sentinel, "must-survive.txt")) == "untouched"
  end

  test "destroy and export are refused when no workspace root is configured", context do
    supervisor = start_supervisor(context, workspace_root: nil, result_root: nil, state_root: nil)

    workspace = Path.join(context.tmp, "unrooted-workspace")
    results = Path.join(context.tmp, "unrooted-results")
    File.mkdir_p!(workspace)
    File.mkdir_p!(results)
    File.write!(Path.join(workspace, "keep.txt"), "kept")

    assert {:start_worker_result, %{status: :started}} =
             WorkerSupervisor.request(
               supervisor,
               start_request("agent.unrooted", %{workspace: workspace, result_dir: results})
             )

    assert {:teardown_workspace_result, %{status: :error, error: :invalid_workspace}} =
             teardown(supervisor, "agent.unrooted", :destroy)

    assert File.read!(Path.join(workspace, "keep.txt")) == "kept"

    assert {:teardown_workspace_result, %{status: :error, error: :invalid_workspace}} =
             teardown(supervisor, "agent.unrooted", :export)

    assert File.read!(Path.join(workspace, "keep.txt")) == "kept"
    refute File.exists?(Path.join(results, "workspace"))
  end

  test "export is refused when no result root is configured", context do
    supervisor = start_supervisor(context, result_root: nil, state_root: nil)

    workspace = Path.join(context.workspaces, "agent.export.unrooted")
    results = Path.join(context.tmp, "unrooted-results")
    File.mkdir_p!(results)

    assert {:start_worker_result, %{status: :started}} =
             WorkerSupervisor.request(
               supervisor,
               start_request("agent.export.unrooted", %{
                 workspace: workspace,
                 result_dir: results
               })
             )

    assert eventually(fn -> File.dir?(workspace) end)
    File.write!(Path.join(workspace, "keep.txt"), "kept")

    assert {:teardown_workspace_result, %{status: :error, error: :invalid_result_dir}} =
             teardown(supervisor, "agent.export.unrooted", :export)

    assert File.read!(Path.join(workspace, "keep.txt")) == "kept"
    refute File.exists?(Path.join(results, "workspace"))
  end

  defp start_supervisor(context, overrides \\ []) do
    worker = Path.join(context.tmp, "sleeper")
    File.write!(worker, "#!/bin/sh\nsleep 30\n")
    File.chmod!(worker, 0o755)

    opts =
      Keyword.merge(
        [
          control_token: @control_token,
          worker_executable: worker,
          worker_args: [],
          workspace_root: context.workspaces,
          result_root: context.results,
          state_root: context.agents,
          max_workers: 4
        ],
        overrides
      )

    {:ok, supervisor} = WorkerSupervisor.start_link(opts)

    on_exit(fn -> safe_stop(supervisor) end)
    supervisor
  end

  defp start_request(worker_id, extra \\ %{}) do
    {:start_worker,
     Map.merge(
       %{
         request_id: "start-#{worker_id}-#{System.unique_integer([:positive])}",
         worker_id: worker_id,
         token: @worker_token,
         manager_host: "127.0.0.1",
         manager_port: 4123
       },
       extra
     )}
  end

  defp teardown(supervisor, worker_id, action) do
    WorkerSupervisor.request(
      supervisor,
      {:teardown_workspace,
       %{
         request_id: "teardown-#{worker_id}-#{System.unique_integer([:positive])}",
         worker_id: worker_id,
         action: action
       }}
    )
  end

  defp eventually(fun, attempts \\ 100) do
    Enum.reduce_while(1..attempts, false, fn _attempt, _acc ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(25)
        {:cont, false}
      end
    end)
  end

  defp safe_stop(pid) do
    GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
