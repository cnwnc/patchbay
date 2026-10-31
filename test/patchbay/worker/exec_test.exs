defmodule Patchbay.Worker.ExecTest do
  use ExUnit.Case, async: true

  alias Patchbay.Worker.Exec

  setup do
    tmp = Path.join(System.tmp_dir!(), "patchbay-exec-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    %{tmp: tmp}
  end

  test "passes each argument directly without shell interpretation" do
    echo = executable!("echo")

    assert {:ok, result} = Exec.run(echo, ["hello; echo pwned", "$(id)", "`id`"])
    assert result.output == "hello; echo pwned $(id) `id`\n"
    assert result.exit_status == 0
  end

  test "reports a nonzero exit status" do
    false_cmd = executable!("false")

    assert {:ok, result} = Exec.run(false_cmd, [])
    assert result.exit_status == 1
    assert result.output == ""
  end

  test "merges stderr into bounded output" do
    ls = executable!("ls")

    assert {:ok, result} = Exec.run(ls, ["/definitely/not/a/patchbay/path"])
    assert result.exit_status != 0
    assert result.output =~ "No such file"
  end

  test "stops collecting at the output limit" do
    head = executable!("head")

    assert {:error, {:output_limit, %{limit: 1024, output: output}}} =
             Exec.run(head, ["-c", "100000", "/dev/zero"], max_output_bytes: 1024)

    assert byte_size(output) == 1024
  end

  test "stops a command at the deadline" do
    sleep = executable!("sleep")

    assert {:error, :timeout} = Exec.run(sleep, ["5"], timeout: 100)
  end

  test "resolves bare executables on PATH and rejects invalid argv" do
    assert Exec.valid_executable?("echo")
    refute Exec.valid_executable?("definitely-not-a-patchbay-command")

    assert {:ok, result} = Exec.run("echo", ["bare command"])
    assert result.output == "bare command\n"

    assert {:error, :invalid_executable} =
             Exec.run("definitely-not-a-patchbay-command", [])

    assert {:error, :invalid_executable} = Exec.run("/definitely/not/a/command", [])

    echo = executable!("echo")
    assert {:error, :invalid_arguments} = Exec.run(echo, ["a" <> <<0>> <> "b"])
    assert {:error, :invalid_arguments} = Exec.run(echo, [:not_a_binary])
  end

  test "rejects a non-executable file", %{tmp: tmp} do
    path = Path.join(tmp, "plain")
    File.write!(path, "#!/bin/sh\necho hi\n")
    File.chmod!(path, 0o644)

    assert {:error, :invalid_executable} = Exec.run(path, [])
  end

  test "runs in the requested working directory", %{tmp: tmp} do
    pwd = executable!("pwd")

    assert {:ok, result} = Exec.run(pwd, [], cd: tmp)
    assert String.trim(result.output) == tmp
  end

  test "rejects invalid limits and working directories", %{tmp: tmp} do
    echo = executable!("echo")

    assert {:error, :invalid_timeout} = Exec.run(echo, [], timeout: 0)
    assert {:error, :invalid_output_limit} = Exec.run(echo, [], max_output_bytes: 0)

    assert {:error, :invalid_working_directory} =
             Exec.run(echo, [], cd: Path.join(tmp, "missing"))
  end

  test "kills the child and its descendants at the deadline", %{tmp: tmp} do
    parent_file = Path.join(tmp, "parent.pid")
    child_file = Path.join(tmp, "child.pid")

    script =
      "echo $$ > #{parent_file}; sleep 30 & echo $! > #{child_file}; wait"

    assert {:error, :timeout} =
             Exec.run(executable!("sh"), ["-c", script], timeout: 300)

    parent = read_pid!(parent_file)
    child = read_pid!(child_file)

    assert eventually(fn -> not File.exists?("/proc/#{parent}") end)
    assert eventually(fn -> not File.exists?("/proc/#{child}") end)
  end

  test "kills the child at the output limit", %{tmp: tmp} do
    parent_file = Path.join(tmp, "output.pid")

    assert {:error, {:output_limit, %{output: output}}} =
             Exec.run(
               executable!("sh"),
               ["-c", "echo $$ > #{parent_file}; yes"],
               max_output_bytes: 1024
             )

    assert byte_size(output) == 1024

    parent = read_pid!(parent_file)
    assert eventually(fn -> not File.exists?("/proc/#{parent}") end)
  end

  test "rejects invalid UTF-8 arguments without raising" do
    echo = executable!("echo")

    assert {:error, :invalid_arguments} = Exec.run(echo, [<<0xFF>>])
    assert {:error, :invalid_arguments} = Exec.run(echo, ["ok", <<0xC3>>])
    assert {:error, :invalid_executable} = Exec.run("/tmp/" <> <<0xFF>>, [])
  end

  test "closing the port before the group kill bounds the mailbox", %{tmp: _tmp} do
    sh = executable!("sh")
    parent = self()

    worker =
      spawn(fn ->
        result =
          Exec.run(sh, ["-c", "trap '' TERM; yes"],
            max_output_bytes: 1024,
            timeout: 10_000
          )

        Process.sleep(50)
        send(parent, {:done, result, mailbox_messages([])})
      end)

    peak = watch_queue(worker, 0)

    assert_receive {:done, {:error, {:output_limit, %{output: output}}}, messages}, 10_000
    assert byte_size(output) == 1024
    refute Enum.any?(messages, &match?({port, _message} when is_port(port), &1))
    assert peak < 64
  end

  defp watch_queue(pid, peak) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, length} ->
        Process.sleep(2)
        watch_queue(pid, max(peak, length))

      nil ->
        peak
    end
  end

  defp mailbox_messages(acc) do
    receive do
      message -> mailbox_messages([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp read_pid!(path) do
    assert eventually(fn -> File.exists?(path) end)
    path |> File.read!() |> String.trim() |> String.to_integer()
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
