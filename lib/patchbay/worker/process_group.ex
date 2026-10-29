defmodule Patchbay.Worker.ProcessGroup do
  @moduledoc """
  Spawns external programs in their own process group and terminates the whole
  group.

  Erlang's port driver closes the child's stdin when a port is closed, but a
  child that ignores EOF (or a grandchild that outlives its parent) can keep
  running. Callers that impose a deadline or an output limit therefore ask
  this module to signal the OS process before closing the port.

  On this runtime the port's child is normally placed in its own process
  group, with the reported `os_pid` as group leader. `group_leader?/1` checks
  that after spawning (via `/proc`); when it holds, signalling the negated pid
  reaches every descendant that did not create its own session. Otherwise the
  direct child and its `/proc` descendants are signalled individually.

  A worker's operation children each get their own session from the port
  driver, so they cannot be reached through the worker's process group once
  the worker exits. `terminate_instance/1` finds those orphans through the
  per-worker environment marker that every operation inherits.
  """

  alias Patchbay.Worker.Env

  @sigterm "TERM"
  @sigkill "KILL"
  @grace_ms 250

  @type command :: {binary(), [binary()]}

  @doc "Returns `{executable, argv}` for a `Port.open/2` spawn."
  @spec command(binary(), [binary()]) :: command()
  def command(executable, args) when is_binary(executable) and is_list(args),
    do: {executable, args}

  @doc "Returns true when `os_pid` is the leader of its own process group."
  @spec group_leader?(integer() | nil) :: boolean()
  def group_leader?(nil), do: false

  def group_leader?(os_pid) when is_integer(os_pid) do
    with {:ok, stat} <- File.read("/proc/#{os_pid}/stat"),
         {:ok, pgrp} <- stat_pgrp(stat) do
      pgrp == os_pid
    else
      _other -> false
    end
  end

  defp stat_pgrp(stat) do
    case :binary.matches(stat, ")") do
      [] ->
        :error

      matches ->
        {position, _length} = List.last(matches)
        rest = binary_part(stat, position + 1, byte_size(stat) - position - 1)

        case rest |> String.split() |> Enum.at(2) |> Integer.parse() do
          {pgrp, ""} -> {:ok, pgrp}
          _other -> :error
        end
    end
  end

  @doc """
  Terminates the child and its process group.

  Sends `SIGTERM`, waits briefly for the child to exit, then sends `SIGKILL`.
  Errors from signalling an already-dead process are ignored.
  """
  @spec terminate(integer() | nil, boolean()) :: :ok
  def terminate(nil, _group), do: :ok

  def terminate(os_pid, group) when is_integer(os_pid) and is_boolean(group) do
    # Capture descendants before signalling: killing the leader reparents or
    # reaps them, and Erlang's port children can live in their own groups.
    targets = targets(os_pid, group)
    signal_all(targets, @sigterm)

    if wait_for_death(targets, @grace_ms) do
      :ok
    else
      signal_all(targets, @sigkill)
      :ok
    end
  end

  @doc "Returns true when the OS process still exists."
  @spec alive?(integer() | nil) :: boolean()
  def alive?(nil), do: false

  def alive?(os_pid) when is_integer(os_pid),
    do: signaled?(["-0", "--", Integer.to_string(os_pid)])

  def alive?(_os_pid), do: false

  @doc """
  Terminates every process carrying `token` as its worker instance marker.

  Used when a worker VM dies without running its own cleanup: operation
  children may have been reparented away from the worker, but they still
  inherit its marker in the environment.
  """
  @spec terminate_instance(binary() | nil) :: :ok
  def terminate_instance(nil), do: :ok

  def terminate_instance(token) when is_binary(token) and byte_size(token) > 0 do
    marker = Env.instance_variable() <> "=" <> token

    targets =
      marker
      |> marked_pids()
      |> Enum.flat_map(fn pid -> [pid | descendants(pid)] end)
      |> Enum.uniq()
      |> Enum.map(fn pid -> {pid, group_leader?(pid)} end)

    case targets do
      [] ->
        :ok

      targets ->
        signal_all(targets, @sigterm)

        if wait_for_death(targets, @grace_ms) do
          :ok
        else
          signal_all(targets, @sigkill)
          :ok
        end
    end
  end

  def terminate_instance(_token), do: :ok

  defp targets(os_pid, group) do
    descendants =
      os_pid
      |> descendants()
      |> Enum.reverse()
      |> Enum.map(fn pid -> {pid, group_leader?(pid)} end)

    descendants ++ [{os_pid, group}]
  end

  defp signal_all(targets, signal) do
    Enum.each(targets, fn {pid, group?} -> signal(pid, group?, signal) end)
  end

  defp signal(os_pid, true, signal) do
    run_kill(["-s", signal, "--", "-#{os_pid}"])
  end

  defp signal(os_pid, false, signal) do
    run_kill(["-s", signal, "--", Integer.to_string(os_pid)])
  end

  defp run_kill(args) do
    case kill_path() do
      nil ->
        :ok

      kill ->
        _ = System.cmd(kill, args, stderr_to_stdout: true)
        :ok
    end
  end

  defp kill_path do
    case System.find_executable("kill") do
      nil ->
        first_executable(["/bin/kill", "/usr/bin/kill"])

      path ->
        if absolute_executable?(path),
          do: path,
          else: first_executable(["/bin/kill", "/usr/bin/kill"])
    end
  end

  defp first_executable(paths), do: Enum.find(paths, &absolute_executable?/1)

  defp absolute_executable?(path) when is_binary(path) do
    Path.type(path) == :absolute and
      case File.stat(path) do
        {:ok, %File.Stat{type: :regular, mode: mode}} ->
          Bitwise.band(mode, 0o111) != 0

        _other ->
          false
      end
  end

  defp absolute_executable?(_path), do: false

  defp signaled?(args) do
    case kill_path() do
      nil -> false
      kill -> match?({_output, 0}, System.cmd(kill, args, stderr_to_stdout: true))
    end
  end

  defp wait_for_death(_targets, remaining) when remaining <= 0, do: false

  defp wait_for_death(targets, remaining) do
    if Enum.any?(targets, fn {pid, group?} -> target_alive?(pid, group?) end) do
      Process.sleep(25)
      wait_for_death(targets, remaining - 25)
    else
      true
    end
  end

  defp target_alive?(os_pid, true), do: signaled?(["-0", "--", "-#{os_pid}"])
  defp target_alive?(os_pid, false), do: alive?(os_pid)

  defp marked_pids(marker) do
    case File.ls("/proc") do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(fn entry ->
          case Integer.parse(entry) do
            {pid, ""} -> if marked?(pid, marker), do: [pid], else: []
            _other -> []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp marked?(os_pid, marker) do
    case File.read("/proc/#{os_pid}/environ") do
      {:ok, environ} -> marker in :binary.split(environ, <<0>>, [:global])
      {:error, _reason} -> false
    end
  end

  # Linux exposes direct children under /proc. Used only when the child was
  # not its own process-group leader, as a best-effort descendant cleanup.
  defp descendants(os_pid) do
    children =
      case File.read("/proc/#{os_pid}/task/#{os_pid}/children") do
        {:ok, contents} ->
          contents
          |> String.split()
          |> Enum.flat_map(fn value ->
            case Integer.parse(value) do
              {pid, ""} -> [pid]
              _ -> []
            end
          end)

        {:error, _reason} ->
          []
      end

    Enum.flat_map(children, fn child -> [child | descendants(child)] end)
  end
end
