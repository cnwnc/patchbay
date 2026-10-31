defmodule Patchbay.Worker.Exec do
  @moduledoc """
  Runs one external program with an argv list, never through a shell.

  Output is collected with a hard byte limit and a wall-clock deadline. When
  either limit is reached the child's process group is signalled and the port
  is closed before the partial output is returned with an error tagged by the
  limit that fired.

  The executable may be an absolute path, a relative path, or a bare command
  name. Bare names and relative paths are resolved at execution time from the
  worker's `PATH` or working directory before the port is opened. Arguments
  must already be binaries; each becomes exactly one argv element.
  """

  import Bitwise

  alias Patchbay.Worker.Env
  alias Patchbay.Worker.ProcessGroup

  @default_timeout 30_000
  @max_timeout 3_600_000
  @default_max_output 262_144
  @max_output 4_194_304
  @max_args 256
  @max_arg_bytes 65_536
  @max_total_arg_bytes 262_144

  @type result :: %{
          output: binary(),
          exit_status: non_neg_integer(),
          os_pid: integer() | nil,
          duration_ms: non_neg_integer()
        }

  @doc """
  Runs `executable` with `args`.

  Options:
  - `:timeout` - milliseconds, defaults to #{@default_timeout}
  - `:max_output_bytes` - defaults to #{@default_max_output}
  - `:cd` - absolute working directory
  - `:secret_names` - environment variable names from `PATCHBAY_SECRET_ENV`
    that the child may receive from the current environment
  """
  @spec run(binary(), [binary()], keyword()) ::
          {:ok, result()}
          | {:error,
             :invalid_executable
             | :invalid_arguments
             | :invalid_timeout
             | :invalid_output_limit
             | :invalid_working_directory
             | :timeout
             | {:output_limit, %{limit: non_neg_integer(), output: binary()}}
             | {:port_error, term()}
             | {:port_down, term()}}
  def run(executable, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_output = Keyword.get(opts, :max_output_bytes, @default_max_output)
    cd = Keyword.get(opts, :cd)
    secret_names = Keyword.get(opts, :secret_names, [])

    with :ok <- validate_executable_name(executable),
         :ok <- validate_args(args),
         :ok <- validate_timeout(timeout),
         :ok <- validate_output_limit(max_output),
         :ok <- validate_working_directory(cd),
         {:ok, executable} <- resolve_executable(executable, cd) do
      do_run(executable, args, cd, timeout, max_output, secret_names)
    end
  end

  @doc "Checks that `path` names a resolvable executable file."
  @spec valid_executable?(term()) :: boolean()
  def valid_executable?(path) when is_binary(path) do
    validate_executable_name(path) == :ok and
      match?({:ok, _path}, resolve_executable(path, nil))
  end

  def valid_executable?(_path), do: false

  @doc "Validates an argv list without running anything."
  @spec validate_arguments(term()) :: :ok | {:error, :invalid_arguments}
  def validate_arguments(args), do: validate_args(args)

  defp resolve_executable(executable, cd) do
    cond do
      Path.type(executable) == :absolute ->
        resolve_file(executable)

      String.contains?(executable, "/") ->
        resolve_file(Path.expand(executable, cd || File.cwd!()))

      true ->
        find_in_path(executable)
    end
  end

  defp resolve_file(path) do
    if executable_file?(path), do: {:ok, path}, else: {:error, :invalid_executable}
  end

  defp find_in_path(name) do
    System.get_env("PATH", "")
    |> String.split(":", trim: true)
    |> Enum.filter(&(Path.type(&1) == :absolute))
    |> Enum.map(&Path.join(&1, name))
    |> Enum.find(&executable_file?/1)
    |> case do
      nil -> {:error, :invalid_executable}
      path -> {:ok, path}
    end
  end

  defp validate_executable_name(path) do
    cond do
      not is_binary(path) ->
        {:error, :invalid_executable}

      byte_size(path) == 0 or byte_size(path) > 4096 ->
        {:error, :invalid_executable}

      not String.valid?(path) ->
        {:error, :invalid_executable}

      contains_nul?(path) ->
        {:error, :invalid_executable}

      String.trim(path) == "" ->
        {:error, :invalid_executable}

      true ->
        :ok
    end
  end

  defp executable_file?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> (mode &&& 0o111) != 0
      _other -> false
    end
  end

  defp validate_args(args) when is_list(args) do
    if Enum.all?(args, &is_binary/1) do
      total_bytes = Enum.reduce(args, 0, fn arg, acc -> acc + byte_size(arg) end)

      if length(args) <= @max_args and total_bytes <= @max_total_arg_bytes and
           Enum.all?(args, &valid_arg?/1) do
        :ok
      else
        {:error, :invalid_arguments}
      end
    else
      {:error, :invalid_arguments}
    end
  end

  defp validate_args(_args), do: {:error, :invalid_arguments}

  defp valid_arg?(arg) when is_binary(arg) do
    byte_size(arg) <= @max_arg_bytes and String.valid?(arg) and not contains_nul?(arg)
  end

  defp valid_arg?(_arg), do: false

  defp validate_timeout(timeout)
       when is_integer(timeout) and timeout > 0 and timeout <= @max_timeout,
       do: :ok

  defp validate_timeout(_timeout), do: {:error, :invalid_timeout}

  defp validate_output_limit(limit) when is_integer(limit) and limit > 0 and limit <= @max_output,
    do: :ok

  defp validate_output_limit(_limit), do: {:error, :invalid_output_limit}

  defp validate_working_directory(nil), do: :ok

  defp validate_working_directory(cd) when is_binary(cd) do
    cond do
      not String.valid?(cd) -> {:error, :invalid_working_directory}
      contains_nul?(cd) -> {:error, :invalid_working_directory}
      Path.type(cd) != :absolute -> {:error, :invalid_working_directory}
      match?({:ok, %File.Stat{type: :directory}}, File.stat(cd)) -> :ok
      true -> {:error, :invalid_working_directory}
    end
  end

  defp validate_working_directory(_cd), do: {:error, :invalid_working_directory}

  defp do_run(executable, args, cd, timeout, max_output, secret_names) do
    started_at = System.monotonic_time(:millisecond)
    {spawn_executable, spawn_args} = ProcessGroup.command(executable, args)

    port_options =
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        {:args, Enum.map(spawn_args, &to_charlist/1)},
        {:env, Env.exec_env(System.get_env(), secret_names)}
      ] ++ if(cd, do: [{:cd, to_charlist(cd)}], else: [])

    port = Port.open({:spawn_executable, to_charlist(spawn_executable)}, port_options)

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    Process.unlink(port)
    monitor = :erlang.monitor(:port, port)
    deadline = started_at + timeout

    collect(
      port,
      monitor,
      os_pid,
      ProcessGroup.group_leader?(os_pid),
      deadline,
      max_output,
      started_at,
      [],
      0
    )
  rescue
    error in [ArgumentError, ErlangError] ->
      {:error, {:port_error, error}}
  end

  defp collect(port, monitor, os_pid, group?, deadline, max_output, started_at, chunks, size) do
    receive do
      {^port, {:data, data}} ->
        case size + byte_size(data) do
          new_size when new_size > max_output ->
            keep = max(max_output - size, 0)
            partial = IO.iodata_to_binary([chunks, binary_part(data, 0, keep)])
            close_port(port, monitor, os_pid, group?)

            {:error, {:output_limit, %{limit: max_output, output: partial, os_pid: os_pid}}}

          new_size ->
            collect(
              port,
              monitor,
              os_pid,
              group?,
              deadline,
              max_output,
              started_at,
              [chunks, data],
              new_size
            )
        end

      {^port, {:exit_status, status}} ->
        :erlang.demonitor(monitor, [:flush])

        {:ok,
         %{
           output: IO.iodata_to_binary(chunks),
           exit_status: status,
           os_pid: os_pid,
           duration_ms: System.monotonic_time(:millisecond) - started_at
         }}

      {:DOWN, ^monitor, :port, ^port, reason} ->
        {:error, {:port_down, reason}}
    after
      remaining_timeout(deadline) ->
        close_port(port, monitor, os_pid, group?)
        {:error, :timeout}
    end
  end

  defp remaining_timeout(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp close_port(port, monitor, os_pid, group?) do
    # Close the port first so no further data messages can queue while the
    # process-group shutdown is waiting for the child to exit.
    try do
      Port.close(port)
    rescue
      _error -> :ok
    end

    :erlang.demonitor(monitor, [:flush])
    ProcessGroup.terminate(os_pid, group?)
    flush_port(port)
  end

  defp flush_port(port) do
    receive do
      {^port, _message} -> flush_port(port)
    after
      0 -> :ok
    end
  end

  defp contains_nul?(value), do: :binary.match(value, <<0>>) != :nomatch
end
