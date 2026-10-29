defmodule Patchbay.Worker.WireTest do
  use ExUnit.Case, async: true

  alias Patchbay.Worker.Protocol
  alias Patchbay.Worker.Wire

  test "maps arbitrary execution reasons to wire-safe errors" do
    assert Wire.error({:unknown_operation, "missing"}) == {:unknown_operation, "missing"}
    assert Wire.error({:unknown_arguments, ["b", 3]}) == {:unknown_arguments, ["b"]}
    assert Wire.error({:invalid_argument, "x"}) == {:invalid_argument, "x"}
    assert Wire.error({:path_outside_workspace, "../x"}) == {:path_outside_workspace, "../x"}
    assert Wire.error(:timeout) == :timeout
    assert Wire.error(:invalid_arguments) == :invalid_arguments

    assert Wire.error({:output_limit, %{limit: 4, output: "abcd", os_pid: 1}}) ==
             {:output_limit, %{limit: 4, output: "abcd", os_pid: nil}}

    assert Wire.error({:port_error, %RuntimeError{message: "boom"}}) == :execution_failed
    assert Wire.error({:port_down, :noproc}) == :execution_failed
    assert Wire.error(self()) == :execution_failed
    assert Wire.error(make_ref()) == :execution_failed
    assert Wire.error({:unknown_operation, :not_a_name}) == :execution_failed
  end

  test "error terms only contain vocabulary atoms" do
    reasons = [
      {:unknown_operation, "x"},
      {:unknown_arguments, ["a"]},
      {:missing_arguments, ["a"]},
      {:invalid_argument, "a"},
      {:path_outside_workspace, "a"},
      {:file_not_found, "a"},
      {:directory_not_found, "a"},
      :timeout,
      :execution_failed,
      {:port_error, %RuntimeError{}}
    ]

    Enum.each(reasons, fn reason ->
      error = Wire.error(reason)
      assert Protocol.term_allowed?(error)
      assert atoms(error) |> Enum.all?(&Wire.known_atom?/1)
    end)
  end

  test "representative frames decode in a separate VM with a fresh atom table" do
    frames = representative_messages() |> Enum.map(&encode!/1)
    tmp = Path.join(System.tmp_dir!(), "patchbay-wire-#{System.unique_integer([:positive])}")
    path = Path.join(tmp, "frames.b64")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    File.write!(path, Enum.map_join(frames, "\n", &Base.encode64/1))

    script = """
    ebin = System.fetch_env!("PB_EBIN")
    Code.prepend_path(ebin)
    frames = System.fetch_env!("PB_FRAMES") |> File.read!() |> String.split("\\n", trim: true)

    Enum.each(frames, fn frame ->
      {:ok, _term} = Patchbay.Worker.Protocol.decode_frame(Base.decode64!(frame))
    end)

    IO.puts("decoded")
    """

    elixir = System.find_executable("elixir")

    assert elixir != nil, "elixir executable is required for the separate VM test"

    {output, status} =
      System.cmd(elixir, ["-e", script],
        env: [
          {"PB_EBIN", Path.join(Mix.Project.build_path(), "lib/patchbay/ebin")},
          {"PB_FRAMES", path}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "decoded"
  end

  defp encode!(message) do
    assert {:ok, frame} = Protocol.encode(message)
    frame
  end

  defp representative_messages do
    event = %{type: :tool_result, worker_id: "worker", call_id: "call", status: :ok}

    [
      {:hello, %{role: :worker, version: 1, worker_id: "worker", token: "0123456789abcdef"}},
      {:hello, %{role: :manager, version: 1, token: "0123456789abcdef"}},
      {:welcome, %{version: 1}},
      {:rejected, %{reason: :unauthorized}},
      {:ready, %{worker_id: "worker"}},
      {:execute,
       %{call_id: "call", operation: "echo", arguments: %{"text" => "x"}, timeout: 1_000}},
      {:result, %{call_id: "call", status: :ok, output: "x", exit_status: 0, duration_ms: 3}},
      {:result, %{call_id: "call", status: :error, error: {:unknown_operation, "missing"}}},
      {:result, %{call_id: "call", status: :error, error: :timeout}},
      {:ping, %{id: "1"}},
      {:pong, %{id: "1"}},
      {:shutdown, %{}},
      {:start_worker,
       %{
         request_id: "request",
         worker_id: "worker",
         token: "0123456789abcdef",
         manager_host: "127.0.0.1",
         manager_port: 4000
       }},
      {:start_worker_result,
       %{request_id: "request", status: :started, worker_id: "worker", os_pid: 12}},
      {:start_worker_result, %{request_id: "request", status: :error, error: :worker_limit}},
      {:stop_worker, %{request_id: "request", worker_id: "worker"}},
      {:stop_worker_result, %{request_id: "request", status: :stopping, worker_id: "worker"}},
      {:list_workers, %{request_id: "request"}},
      {:list_workers_result, %{request_id: "request", status: :ok, workers: []}},
      {:worker_exited, %{worker_id: "worker", status: %{exit_status: 0}}},
      {:worker_exited, %{worker_id: "worker", status: %{port_down: :noproc}}},
      {:error_response, %{request_id: nil, error: :unknown_message}},
      {:event, event}
    ]
  end

  defp atoms(term) when is_atom(term), do: [term]
  defp atoms(term) when is_list(term), do: Enum.flat_map(term, &atoms/1)
  defp atoms(term) when is_tuple(term), do: term |> Tuple.to_list() |> Enum.flat_map(&atoms/1)

  defp atoms(term) when is_map(term) do
    Enum.flat_map(term, fn {key, value} -> atoms(key) ++ atoms(value) end)
  end

  defp atoms(_term), do: []
end
