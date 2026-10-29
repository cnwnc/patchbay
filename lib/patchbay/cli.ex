defmodule Patchbay.CLI do
  @moduledoc """
  Command-line entry points for the Patchbay release.

  The release's `main` should dispatch to `main/1`:

      patchbay run-manager
      patchbay run-worker-supervisor
      patchbay run-worker

  `run-manager` and `run-worker-supervisor` are long-lived services. `run-worker`
  is started by the worker supervisor as a separate OS process.
  """

  @usage """
  Usage: patchbay <command>

    run-manager             Run the manager service
    run-worker-supervisor   Run the worker supervisor service
    run-worker              Run one worker (started by the worker supervisor)
    help                    Show this message
  """

  @doc "Dispatches a release entry point."
  @spec main([binary()]) :: no_return()
  def main(argv \\ System.argv()) do
    ensure_runtime()

    case argv do
      ["run-manager" | rest] ->
        Patchbay.CLI.Manager.main(rest)

      ["run-worker-supervisor" | rest] ->
        Patchbay.WorkerSupervisor.main(rest)

      ["run-worker" | rest] ->
        Patchbay.Worker.main(rest)

      ["help"] ->
        IO.puts(@usage)
        System.halt(0)

      ["--help"] ->
        IO.puts(@usage)
        System.halt(0)

      [] ->
        IO.puts(:stderr, @usage)
        System.halt(2)

      [unknown | _] ->
        IO.puts(:stderr, "patchbay: unknown command #{inspect(unknown)}\n")
        IO.puts(:stderr, @usage)
        System.halt(2)
    end
  end

  @doc false
  def usage, do: @usage

  @doc false
  def ensure_runtime do
    _ = Application.ensure_all_started(:logger)
    _ = Application.ensure_all_started(:crypto)
    :ok
  end

  @doc """
  Prepares a service entry point to own its GenServer and handle signals.

  Must be called before starting the service with `start_link/1`, otherwise a
  service crash takes down the CLI process before it can report the failure.
  Installs `Patchbay.CLI.Signals` so SIGTERM reaches `service_loop/2`.
  """
  @spec prepare_service() :: :ok
  def prepare_service do
    Process.flag(:trap_exit, true)
    Patchbay.CLI.Signals.install(self())
  end

  @doc """
  Blocks until `pid` exits or a termination signal arrives, then halts.

  SIGTERM stops the service with `GenServer.stop/3`, which runs its
  `terminate/2`. SIGINT is not subscribable through OTP; see
  `Patchbay.CLI.Signals`.
  """
  @spec service_loop(pid(), binary()) :: no_return()
  def service_loop(pid, label) do
    reference = Process.monitor(pid)

    receive do
      {:DOWN, ^reference, :process, ^pid, :normal} ->
        System.halt(0)

      {:DOWN, ^reference, :process, ^pid, reason} ->
        fail(label, reason)

      {:EXIT, ^pid, :normal} ->
        System.halt(0)

      {:EXIT, ^pid, reason} ->
        fail(label, reason)

      {:signal, :sigterm} ->
        stop(pid)
        System.halt(0)

      {:signal, :sigint} ->
        stop(pid)
        System.halt(130)
    end
  end

  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, _reason -> :ok
  end

  defp fail(label, reason) do
    IO.puts(:stderr, "#{label}: #{format_error(reason)}")
    System.halt(1)
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end

defmodule Patchbay.CLI.Options do
  @moduledoc false

  @type option_type :: :string | :integer | :boolean
  @type spec :: [{binary(), atom(), option_type()}]

  @doc """
  Parses `--flag value`, `--flag=value`, and boolean flags.

  `spec` maps flag names (without `--`) to option keys and value types. Unknown
  flags and positional arguments are errors.
  """
  @spec parse([binary()], spec()) :: {:ok, map()} | {:error, term()}
  def parse(args, spec) when is_list(args) do
    spec_map = Map.new(spec, fn {flag, key, type} -> {flag, {key, type}} end)
    parse_args(args, spec_map, %{})
  end

  @doc "Fetches a required parsed option."
  @spec fetch_required(map(), atom(), binary()) :: {:ok, term()} | {:error, term()}
  def fetch_required(options, key, flag) do
    case Map.fetch(options, key) do
      {:ok, nil} -> {:error, {:missing_option, flag}}
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_option, flag}}
    end
  end

  @doc "Parses `host:port` or a bare port."
  @spec endpoint(binary()) :: {:ok, {binary(), integer()}} | {:error, term()}
  def endpoint(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [host, port] -> with {:ok, port} <- parse_port(port), do: {:ok, {host, port}}
      [port] -> with {:ok, port} <- parse_port(port), do: {:ok, {"127.0.0.1", port}}
    end
  end

  @doc "Parses a non-negative TCP port."
  @spec parse_port(term()) :: {:ok, integer()} | {:error, term()}
  def parse_port(port) when is_integer(port) and port >= 0 and port <= 65_535, do: {:ok, port}

  def parse_port(port) when is_binary(port) do
    case Integer.parse(port) do
      {value, ""} when value >= 0 and value <= 65_535 -> {:ok, value}
      _ -> {:error, {:invalid_port, port}}
    end
  end

  def parse_port(port), do: {:error, {:invalid_port, port}}

  defp parse_args([], _spec, acc), do: {:ok, acc}

  defp parse_args([arg | rest], spec, acc) when is_binary(arg) do
    case String.split(arg, "=", parts: 2) do
      ["--" <> flag, value] ->
        with {:ok, {key, type}} <- fetch_spec(spec, flag),
             {:ok, parsed} <- parse_value(type, value, flag) do
          parse_args(rest, spec, Map.put(acc, key, parsed))
        end

      ["--" <> flag] ->
        with {:ok, {key, type}} <- fetch_spec(spec, flag) do
          case type do
            :boolean ->
              parse_args(rest, spec, Map.put(acc, key, true))

            _other ->
              case rest do
                [value | tail] ->
                  if String.starts_with?(value, "--") do
                    {:error, {:missing_value, flag}}
                  else
                    with {:ok, parsed} <- parse_value(type, value, flag) do
                      parse_args(tail, spec, Map.put(acc, key, parsed))
                    end
                  end

                [] ->
                  {:error, {:missing_value, flag}}
              end
          end
        end

      [_positional] ->
        {:error, {:unexpected_argument, arg}}
    end
  end

  defp parse_args([arg | _rest], _spec, _acc), do: {:error, {:invalid_argument, arg}}

  defp fetch_spec(spec, flag) do
    case Map.fetch(spec, flag) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, {:unknown_option, flag}}
    end
  end

  defp parse_value(:string, value, _flag), do: {:ok, value}

  defp parse_value(:integer, value, flag) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _ -> {:error, {:invalid_integer, flag, value}}
    end
  end

  defp parse_value(:boolean, value, flag) do
    case value do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, {:invalid_boolean, flag, value}}
    end
  end
end
