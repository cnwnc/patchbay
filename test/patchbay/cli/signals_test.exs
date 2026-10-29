defmodule Patchbay.CLI.SignalsTest do
  use ExUnit.Case, async: false

  alias Patchbay.CLI.Signals

  test "the handler forwards sigterm to its target" do
    {:ok, manager} = :gen_event.start_link()
    :ok = :gen_event.add_handler(manager, Signals, self())

    :gen_event.notify(manager, :sigterm)

    assert_receive {:signal, :sigterm}
    :gen_event.stop(manager)
  end

  test "a real SIGTERM stops the service and cleans up its OS child" do
    tmp = Path.join(System.tmp_dir!(), "patchbay-signal-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    term_path = Path.join(tmp, "terminated")
    child_pid_path = Path.join(tmp, "child.pid")
    ebin = Path.join(Mix.Project.build_path(), "lib/patchbay/ebin")
    assert File.dir?(ebin)

    code = """
    defmodule PatchbaySignalsTestService do
      use GenServer

      def start_link(details), do: GenServer.start_link(__MODULE__, details)

      def init(%{term: term_path, child_pid: child_pid_path}) do
        port =
          Port.open({:spawn_executable, System.find_executable("sh")}, [
            :binary,
            :exit_status,
            :hide,
            {:args, ["-c", "echo $$ > \#{child_pid_path}; sleep 30"]}
          ])

        {:os_pid, os_pid} = Port.info(port, :os_pid)
        Process.unlink(port)
        {:ok, %{term: term_path, port: port, os_pid: os_pid}}
      end

      def terminate(reason, state) do
        group = Patchbay.Worker.ProcessGroup.group_leader?(state.os_pid)
        :ok = Patchbay.Worker.ProcessGroup.terminate(state.os_pid, group)

        try do
          Port.close(state.port)
        rescue
          _error -> :ok
        end

        File.write!(state.term, inspect(reason))
      end
    end

    Patchbay.CLI.ensure_runtime()
    Patchbay.CLI.prepare_service()

    details = %{
      term: System.get_env("PB_TERM_PATH"),
      child_pid: System.get_env("PB_CHILD_PID_PATH")
    }

    {:ok, pid} = PatchbaySignalsTestService.start_link(details)
    IO.puts("ready")
    Patchbay.CLI.service_loop(pid, "signal test")
    """

    port =
      Port.open({:spawn_executable, to_charlist(executable!("elixir"))}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        {:args, Enum.map(["-pa", ebin, "-e", code], &to_charlist/1)},
        {:env,
         [
           {~c"PB_TERM_PATH", to_charlist(term_path)},
           {~c"PB_CHILD_PID_PATH", to_charlist(child_pid_path)}
         ]}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      if Patchbay.Worker.ProcessGroup.alive?(os_pid) do
        System.cmd(executable!("kill"), ["-KILL", Integer.to_string(os_pid)])
      end
    end)

    await_ready(port, "")

    assert eventually(fn -> File.exists?(child_pid_path) end)
    child_pid = child_pid_path |> File.read!() |> String.trim() |> String.to_integer()

    assert {_output, 0} =
             System.cmd(executable!("kill"), ["-TERM", Integer.to_string(os_pid)])

    assert_receive {^port, {:exit_status, 0}}, 10_000
    assert File.read!(term_path) == ":normal"
    assert eventually(fn -> not File.exists?("/proc/#{child_pid}") end)
  end

  defp await_ready(port, acc, timeout \\ 20_000) do
    receive do
      {^port, {:data, data}} ->
        output = acc <> data
        if output =~ "ready", do: output, else: await_ready(port, output, timeout)
    after
      timeout -> flunk("service did not become ready: #{inspect(acc)}")
    end
  end

  defp eventually(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(25)
        do_eventually(fun, deadline)
    end
  end

  defp executable!(name) do
    case System.find_executable(name) do
      nil -> flunk("missing executable in test environment: #{name}")
      path -> path
    end
  end
end
