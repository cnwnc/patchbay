defmodule Patchbay.Worker do
  @moduledoc """
  One agent worker process.

  A worker is an independent OS process started by the worker supervisor. It
  connects to the manager over a direct loopback TCP channel, announces itself,
  and executes fixed operations on request. It never writes transcripts and
  never receives model context.

  The worker exits when its manager channel closes.
  """

  use GenServer

  require Logger

  alias Patchbay.Worker.Artifacts
  alias Patchbay.Worker.Env
  alias Patchbay.Worker.Operations
  alias Patchbay.Worker.Protocol
  alias Patchbay.Worker.Protocol.Stream
  alias Patchbay.Worker.Wire

  @default_connect_timeout 5_000
  @default_handshake_timeout 5_000
  @default_execute_timeout 30_000
  @default_max_output 262_144
  @max_output 524_288
  @max_token 512
  @worker_id_regex ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/

  def start_link(opts \\ []) do
    gen_opts =
      case Keyword.get(opts, :name) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Starts a worker from command-line arguments and blocks until it exits.

  Intended for `patchbay run-worker`. The token is read from
  `PATCHBAY_WORKER_TOKEN`, never from argv.
  """
  @spec main([binary()]) :: no_return()
  def main(argv \\ System.argv()) do
    Patchbay.CLI.ensure_runtime()
    Patchbay.CLI.prepare_service()

    case run_from_argv(argv) do
      {:ok, pid} ->
        Patchbay.CLI.service_loop(pid, "patchbay worker")

      {:error, reason} ->
        IO.puts(:stderr, "patchbay worker: #{format_error(reason)}")
        System.halt(1)
    end
  end

  @doc "Starts a worker from parsed argv and returns its pid."
  @spec run_from_argv([binary()]) :: {:ok, pid()} | {:error, term()}
  def run_from_argv(argv) do
    with {:ok, opts} <- parse_argv(argv),
         {:ok, operations} <- load_operations(opts),
         {:ok, pid} <- start_link(opts |> Map.put(:operations, operations) |> Map.to_list()) do
      {:ok, pid}
    end
  end

  @doc "Executes one fixed operation on a running worker."
  def execute(worker, operation, arguments, timeout \\ @default_execute_timeout) do
    GenServer.call(worker, {:execute, operation, arguments, %{}, timeout}, timeout + 1_000)
  end

  @doc """
  Executes one fixed operation with a fixed-variable map.

  The map reaches the same renderer the manager path uses.
  """
  def execute(worker, operation, arguments, variables, timeout)
      when is_map(variables) and is_integer(timeout) do
    GenServer.call(
      worker,
      {:execute, operation, arguments, variables, timeout},
      timeout + 1_000
    )
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, opts} <- validate_options(opts),
         {:ok, socket, stream} <- connect(opts),
         {:ok, stream, leftovers} <- handshake(socket, stream, opts) do
      reader = start_reader(socket, stream)
      Enum.each(leftovers, &send(self(), {:worker_message, &1}))

      {:ok,
       %{
         socket: socket,
         reader: reader,
         worker_id: opts.worker_id,
         operations: opts.operations,
         workspace: opts.workspace,
         result_dir: opts.result_dir,
         execute_timeout: opts.execute_timeout,
         max_output_bytes: opts.max_output_bytes,
         max_frame: opts.max_frame,
         secret_names: Env.secret_names()
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:execute, operation, arguments, variables, timeout}, _from, state)
      when is_map(variables) do
    timeout = min(timeout, state.execute_timeout)

    result = execute_operation(operation, arguments, variables, timeout, state)

    {:reply, result, state}
  end

  @impl true
  def handle_info({:worker_message, {:execute, %{} = request}}, state) do
    result = execute_request(request, state)
    new_state = send_message(state, result)

    case new_state do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> {:stop, reason, state}
    end
  end

  def handle_info({:worker_message, {:ping, %{id: id}}}, state) when is_binary(id) do
    case send_message(state, {:pong, %{id: id}}) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> {:stop, reason, state}
    end
  end

  def handle_info({:worker_message, {:shutdown, %{}}}, state) do
    {:stop, :normal, state}
  end

  def handle_info({:worker_message, message}, state) do
    Logger.warning("worker #{state.worker_id} received unexpected message: #{inspect(message)}")
    {:stop, :unexpected_message, state}
  end

  def handle_info({:worker_closed, _reason}, state) do
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, reader, reason}, %{reader: reader} = state) do
    {:stop, {:reader_exited, reason}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_socket(state.socket)
    :ok
  end

  defp execute_request(%{operation: operation, arguments: arguments} = request, state) do
    call_id = Map.get(request, :call_id)
    variables = Map.get(request, :variables, %{})
    timeout = request_timeout(request, state.execute_timeout)

    if is_binary(call_id) and is_binary(operation) and is_map(variables) do
      case execute_operation(operation, arguments, variables, timeout, state) do
        {:ok, result} ->
          {:result,
           %{
             call_id: call_id,
             status: Map.get(result, :status, :ok),
             output: Map.get(result, :output, ""),
             exit_status: Map.get(result, :exit_status),
             duration_ms: Map.get(result, :duration_ms, 0)
           }}

        {:error, reason} ->
          {:result, %{call_id: call_id, status: :error, error: safe_error(reason)}}
      end
    else
      {:result, %{call_id: call_id, status: :error, error: :invalid_request}}
    end
  end

  defp execute_operation(operation, arguments, variables, timeout, state)
       when is_binary(operation) do
    if Artifacts.reserved?(operation) do
      Artifacts.read(artifact_roots(state), arguments)
    else
      Operations.execute(state.operations, operation, arguments,
        workspace: state.workspace,
        agent_id: state.worker_id,
        variables: variables,
        timeout: timeout,
        max_output_bytes: state.max_output_bytes,
        secret_names: state.secret_names
      )
    end
  end

  defp execute_operation(_operation, _arguments, _variables, _timeout, _state),
    do: {:error, :unknown_operation}

  defp artifact_roots(state) do
    %{"workspace" => state.workspace, "result" => state.result_dir}
  end

  defp request_timeout(request, default) do
    case Map.get(request, :timeout) do
      timeout when is_integer(timeout) and timeout > 0 and timeout <= 3_600_000 ->
        min(timeout, default)

      _other ->
        default
    end
  end

  defp safe_error(reason), do: Wire.error(reason)

  defp validate_options(opts) do
    worker_id = Keyword.get(opts, :worker_id)
    host = Keyword.get(opts, :manager_host, "127.0.0.1")
    port = Keyword.get(opts, :manager_port)
    token = Keyword.get(opts, :token)
    operations = Keyword.get(opts, :operations, [])
    workspace = Keyword.get(opts, :workspace)
    result_dir = Keyword.get(opts, :result_dir)
    execute_timeout = Keyword.get(opts, :execute_timeout, @default_execute_timeout)
    max_output = Keyword.get(opts, :max_output_bytes, @default_max_output)
    max_frame = Keyword.get(opts, :max_frame, Protocol.default_max_frame())

    cond do
      not is_binary(worker_id) or not String.valid?(worker_id) or
          not Regex.match?(@worker_id_regex, worker_id) ->
        {:error, :invalid_worker_id}

      not is_binary(host) or host not in ["127.0.0.1", "localhost", "::1"] ->
        {:error, :non_loopback_manager}

      not is_integer(port) or port < 1 or port > 65_535 ->
        {:error, :invalid_manager_port}

      not is_binary(token) or byte_size(token) < 16 or byte_size(token) > @max_token ->
        {:error, :invalid_token}

      not is_list(operations) ->
        {:error, :invalid_operations}

      not is_nil(workspace) and
          (not is_binary(workspace) or Path.type(workspace) != :absolute) ->
        {:error, :invalid_workspace}

      not is_nil(result_dir) and
          (not is_binary(result_dir) or Path.type(result_dir) != :absolute) ->
        {:error, :invalid_result_dir}

      not is_integer(execute_timeout) or execute_timeout < 1 or execute_timeout > 3_600_000 ->
        {:error, :invalid_execute_timeout}

      not is_integer(max_output) or max_output < 1 or max_output > @max_output ->
        {:error, :invalid_output_limit}

      not is_integer(max_frame) or max_frame < 1024 or max_frame > 16_777_216 ->
        {:error, :invalid_max_frame}

      not valid_timeout?(Keyword.get(opts, :connect_timeout, @default_connect_timeout)) ->
        {:error, :invalid_connect_timeout}

      not valid_timeout?(Keyword.get(opts, :handshake_timeout, @default_handshake_timeout)) ->
        {:error, :invalid_handshake_timeout}

      true ->
        {:ok,
         %{
           worker_id: worker_id,
           manager_host: host,
           manager_port: port,
           token: token,
           operations: operations,
           workspace: workspace,
           result_dir: result_dir,
           execute_timeout: execute_timeout,
           max_output_bytes: max_output,
           max_frame: max_frame,
           connect_timeout: Keyword.get(opts, :connect_timeout, @default_connect_timeout),
           handshake_timeout: Keyword.get(opts, :handshake_timeout, @default_handshake_timeout)
         }}
    end
  end

  defp valid_timeout?(value), do: is_integer(value) and value > 0 and value <= 60_000

  defp connect(opts) do
    case :gen_tcp.connect(
           to_charlist(opts.manager_host),
           opts.manager_port,
           [
             :binary,
             active: false,
             nodelay: true
           ],
           opts.connect_timeout
         ) do
      {:ok, socket} -> {:ok, socket, Stream.new(max_frame: opts.max_frame)}
      {:error, reason} -> {:error, {:connect_failed, reason}}
    end
  end

  defp handshake(socket, stream, opts) do
    hello = {:hello, %{role: :worker, version: 1, worker_id: opts.worker_id, token: opts.token}}

    with :ok <- send_frame(socket, hello, opts.max_frame),
         {:ok, [welcome | leftovers], stream} <- recv(socket, stream, opts.handshake_timeout),
         :ok <- expect_welcome(welcome),
         :ok <- send_frame(socket, {:ready, %{worker_id: opts.worker_id}}, opts.max_frame) do
      {:ok, stream, leftovers}
    else
      {:error, _reason} = error -> error
      _ -> {:error, :handshake_failed}
    end
  end

  defp expect_welcome({:welcome, %{version: 1}}), do: :ok
  defp expect_welcome({:rejected, %{reason: reason}}), do: {:error, {:rejected, reason}}
  defp expect_welcome(_message), do: {:error, :unexpected_handshake}

  defp recv(socket, stream, timeout) do
    case Stream.recv(socket, stream, timeout) do
      {:ok, messages, stream} -> {:ok, messages, stream}
      {:error, reason} -> {:error, {:recv_failed, reason}}
    end
  end

  defp start_reader(socket, stream) do
    parent = self()

    reader =
      spawn_link(fn ->
        receive do
          :start -> read_loop(socket, parent, stream)
        end
      end)

    :ok = :gen_tcp.controlling_process(socket, reader)
    send(reader, :start)
    reader
  end

  defp read_loop(socket, parent, stream) do
    case Stream.recv(socket, stream, :infinity) do
      {:ok, messages, stream} ->
        Enum.each(messages, &send(parent, {:worker_message, &1}))
        read_loop(socket, parent, stream)

      {:error, reason} ->
        send(parent, {:worker_closed, reason})
    end
  end

  defp send_message(state, message) do
    case send_frame(state.socket, message, state.max_frame) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, {:send_failed, reason}, state}
    end
  end

  defp send_frame(socket, message, max_frame) do
    case Protocol.encode(message, max_frame: max_frame) do
      {:ok, frame} ->
        case :gen_tcp.send(socket, frame) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp close_socket(nil), do: :ok

  defp close_socket(socket) do
    :gen_tcp.close(socket)
    :ok
  end

  defp parse_argv(argv) do
    spec = [
      {"manager-host", :manager_host, :string},
      {"manager-port", :manager_port, :integer},
      {"worker-id", :worker_id, :string},
      {"operations", :operations, :string},
      {"workspace", :workspace, :string},
      {"result-dir", :result_dir, :string},
      {"execute-timeout-ms", :execute_timeout, :integer},
      {"max-output-bytes", :max_output_bytes, :integer}
    ]

    with {:ok, parsed} <- Patchbay.CLI.Options.parse(argv, spec) do
      token = System.get_env("PATCHBAY_WORKER_TOKEN")
      operations_path = Map.get(parsed, :operations) || System.get_env("PATCHBAY_OPERATIONS")
      workspace = Map.get(parsed, :workspace) || System.get_env("PATCHBAY_WORKSPACE")
      result_dir = Map.get(parsed, :result_dir) || System.get_env("PATCHBAY_RESULT_DIR")

      opts = %{
        worker_id: Map.get(parsed, :worker_id),
        manager_host: Map.get(parsed, :manager_host, "127.0.0.1"),
        manager_port: Map.get(parsed, :manager_port),
        token: token,
        workspace: workspace,
        result_dir: result_dir,
        operations_path: operations_path
      }

      opts =
        opts
        |> maybe_put(:execute_timeout, Map.get(parsed, :execute_timeout))
        |> maybe_put(:max_output_bytes, Map.get(parsed, :max_output_bytes))

      {:ok, opts}
    end
  end

  defp load_operations(%{operations_path: nil}), do: {:ok, []}
  defp load_operations(%{operations_path: path}), do: Operations.load(path)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Map.put(opts, key, value)

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
