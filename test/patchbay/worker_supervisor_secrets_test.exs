defmodule Patchbay.WorkerSupervisorSecretsTest do
  use ExUnit.Case, async: false

  alias Patchbay.WorkerSupervisor

  @control_token "supervisor-control-token-0123456789"
  @worker_token "worker-channel-token-0123456789"

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "patchbay-supervisor-secrets-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    executable =
      case System.find_executable("true") do
        nil -> flunk("missing true executable")
        path -> path
      end

    {:ok, supervisor} =
      WorkerSupervisor.start_link(
        control_token: @control_token,
        listen_port: 0,
        worker_executable: executable,
        state_root: Path.join(tmp, "agents"),
        max_workers: 2
      )

    on_exit(fn ->
      if Process.alive?(supervisor), do: GenServer.stop(supervisor)
    end)

    %{supervisor: supervisor}
  end

  test "rejects reserved names in a start request secret map", %{supervisor: supervisor} do
    for secrets <- [
          %{"PATCHBAY_WORKER_TOKEN" => "value"},
          %{"PATH" => "value"},
          %{"GH_TOKEN" => "a\0b"}
        ] do
      assert {:start_worker_result, %{status: :error, error: :invalid_secrets}} =
               WorkerSupervisor.request(supervisor, {:start_worker, request(secrets)})
    end
  end

  test "rejects a non-map secret payload", %{supervisor: supervisor} do
    assert {:start_worker_result, %{status: :error, error: :invalid_secrets}} =
             WorkerSupervisor.request(supervisor, {:start_worker, request(["not", "a", "map"])})
  end

  test "accepts an explicit valid secret map", %{supervisor: supervisor} do
    assert {:start_worker_result, %{status: :started}} =
             WorkerSupervisor.request(
               supervisor,
               {:start_worker, request(%{"GH_TOKEN" => "github-value"})}
             )
  end

  defp request(secrets) do
    %{
      request_id: "request-#{System.unique_integer([:positive])}",
      worker_id: "agent.secret-test-#{System.unique_integer([:positive])}",
      token: @worker_token,
      manager_host: "127.0.0.1",
      manager_port: 4123,
      secrets: secrets
    }
  end
end
