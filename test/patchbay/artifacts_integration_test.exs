defmodule Patchbay.ArtifactsIntegrationTest do
  @moduledoc """
  End-to-end artifact publication: a real worker writes a file into its
  workspace, the run submits it as a `file` result, the runtime publishes it
  through the worker read RPC, and the authenticated HTTP route serves the
  manager-owned copy.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Patchbay.ArtifactStore
  alias Patchbay.CLI.Manager
  alias Patchbay.Definition
  alias Patchbay.Provider.ToolCall
  alias Patchbay.Runtime
  alias Patchbay.WorkerSupervisor
  alias PatchbayWeb.AuthTestHelper

  @endpoint PatchbayWeb.Endpoint
  @control_token "artifacts-integration-control-token-0123456789"
  @report_body "the worker wrote this"

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "patchbay-artifacts-integration-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(tmp, "transcripts"))
    on_exit(fn -> File.rm_rf(tmp) end)

    operations_path = Path.join(tmp, "operations.pbt")
    File.write!(operations_path, :erlang.term_to_binary([]))

    %{tmp: tmp, operations_path: operations_path, state_dir: Path.join(tmp, "state")}
  end

  test "worker-produced file survives completion and is served over authenticated HTTP",
       context do
    supervisor = start_supervisor(context)
    manager = start_manager(context, supervisor)
    on_exit(fn -> safe_stop(manager) end)

    assert eventually(fn -> Manager.control_status(manager) == :connected end, 10_000)

    {:ok, runtime} =
      Runtime.start_link(
        definitions: %{"reporter" => definition()},
        state_dir: context.state_dir,
        workspace_dir: Path.join(context.tmp, "workspaces"),
        result_dir: Path.join(context.tmp, "results"),
        manager: manager
      )

    on_exit(fn -> safe_stop(runtime) end)

    assert {:ok, _running} =
             Runtime.start_agent(runtime, "reporter", timeout: 10_000, await_timeout: 20_000)

    # A real worker process (separate OS process, spawned by the supervisor)
    # writes the file into its own workspace.
    assert {:ok, written} =
             Runtime.execute_tool(runtime, "reporter", "write-report", %{"data" => @report_body},
               timeout: 10_000
             )

    assert written.status == :ok

    workspace_file = Path.join([context.tmp, "workspaces", "reporter", "report.txt"])
    assert File.exists?(workspace_file)
    assert File.read!(workspace_file) == @report_body

    assert :ok =
             Runtime.runner_complete(
               runtime,
               "reporter",
               ToolCall.new("call-1", "complete_task", %{}),
               %{"summary" => "done", "report_file" => "report.txt"}
             )

    # The copy out of the worker runs outside the terminal call; the run is
    # only terminal once publication has finished.
    assert {:ok, _completed} = await_stopped(runtime, "reporter")

    assert {:ok, [artifact]} = Runtime.list_artifacts(runtime, "reporter")
    assert artifact.name =~ ~r/\Areport-file-report-[a-z0-9]{4}-[a-z0-9]{8}\.txt\z/
    assert artifact.content_type == "text/plain"

    directory = ArtifactStore.dir(context.state_dir, "reporter")
    assert mode(directory) == 0o700
    assert mode(Path.join(directory, artifact.name)) == 0o600
    assert {:ok, @report_body} = ArtifactStore.read(context.state_dir, "reporter", artifact.name)

    assert {:ok, events} = Runtime.list_events(runtime, "reporter")
    assert Enum.any?(events, &(&1.type == :artifact_published))
    refute Enum.any?(events, &(&1.type == :artifact_publish_failed))

    assert eventually(fn -> WorkerSupervisor.list_workers(supervisor) == [] end, 10_000)

    # The route requires the same UI Basic credentials as the Console, and
    # the served bytes are the manager-owned copy.
    {:ok, named} =
      Runtime.start_link(
        name: Runtime,
        definitions: %{"reporter" => definition()},
        state_dir: context.state_dir,
        manager: manager
      )

    on_exit(fn -> if Process.alive?(named), do: safe_stop(named) end)

    conn = get(AuthTestHelper.authenticated_conn(), "/artifacts/reporter/#{artifact.name}")
    assert conn.status == 200
    assert conn.resp_body == @report_body
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(conn, "content-disposition") == ["inline"]
    assert_secure_artifact_headers(conn)

    # An agent-controlled extension that browsers execute is not in the
    # inline allowlist: it is served as an octet stream attachment, and every
    # response also carries nosniff and a sandboxed CSP.
    html = "<!doctype html><script>window.top.location = '/config'</script>"

    assert {:ok, _written} =
             ArtifactStore.write(context.state_dir, "reporter", "agent-payload.html", html)

    html_conn =
      get(AuthTestHelper.authenticated_conn(), "/artifacts/reporter/agent-payload.html")

    assert html_conn.status == 200
    assert html_conn.resp_body == html
    assert get_resp_header(html_conn, "content-type") == ["application/octet-stream"]

    assert get_resp_header(html_conn, "content-disposition") == [
             ~s(attachment; filename="agent-payload.html")
           ]

    assert_secure_artifact_headers(html_conn)

    unauthenticated = get(build_conn(), "/artifacts/reporter/#{artifact.name}")
    assert unauthenticated.status == 401
    assert get_resp_header(unauthenticated, "www-authenticate") == [~s(Basic realm="Patchbay")]

    for bad <- [
          "/artifacts/reporter/../reporter/" <> artifact.name,
          "/artifacts/reporter/sub/" <> artifact.name,
          "/artifacts/reporter/missing.txt"
        ] do
      conn = get(AuthTestHelper.authenticated_conn(), bad)
      assert conn.status in [404, 301, 400]
    end

    missing = get(AuthTestHelper.authenticated_conn(), "/artifacts/reporter/missing.txt")
    assert missing.status == 404
    assert_secure_artifact_headers(missing)
  end

  defp assert_secure_artifact_headers(conn) do
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    assert get_resp_header(conn, "content-security-policy") == [
             "default-src 'none'; sandbox; frame-ancestors 'none'"
           ]

    assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(conn, "cross-origin-resource-policy") == ["same-origin"]
  end

  defp definition do
    sh = executable!("sh")

    {:ok, definition} =
      Definition.parse("""
      format-version = 1
      id = "reporter"

      [model]
      name = "test-model"

      [lifecycle]
      kind = "one-shot"

      [[toolkits]]
      toolkit = "shell"

      [[toolkits.operations]]
      name = "write-report"
      executable = "#{sh}"
      argv = ["-c", "printf '%s' \\\"$1\\\" > \\\"$2\\\"", "sh", "{data}", "{%workspace}/report.txt"]

      [toolkits.operations.arguments.data]
      type = "string"

      [[results]]
      id = "summary"
      form = "prose"
      label = "Summary"

      [[results]]
      id = "report_file"
      form = "file"
      extensions = ["txt"]
      label = "The report file"
      """)

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
        transcript_dir: Path.join(context.tmp, "transcripts")
      )

    manager
  end

  defp await_stopped(runtime, agent_id, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_stopped(runtime, agent_id, deadline)
  end

  defp do_await_stopped(runtime, agent_id, deadline) do
    case Runtime.get_agent(runtime, agent_id) do
      {:ok, %{status: :stopped} = agent} ->
        {:ok, agent}

      {:ok, _agent} ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("agent #{agent_id} did not stop")
        else
          Process.sleep(20)
          do_await_stopped(runtime, agent_id, deadline)
        end

      other ->
        flunk("agent lookup failed: #{inspect(other)}")
    end
  end

  defp eventually(fun, timeout) do
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
