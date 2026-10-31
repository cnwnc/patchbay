defmodule Patchbay.CLI.Manager do
  @moduledoc """
  Manager-side worker control service.

  The manager owns transcripts and the worker control relationship. It listens
  on a loopback TCP channel for workers started by the worker supervisor, and
  connects to the supervisor's loopback control channel to request worker
  start/stop and execute fixed operations.

  Model calls, native toolkits, run state, and agent scheduling live in
  `Patchbay.Runtime` and `Patchbay.AgentRunner`, which supervise this service.
  """

  use GenServer

  require Logger

  alias Patchbay.CLI.Manager.Control
  alias Patchbay.Secrets
  alias Patchbay.Secrets.Redact
  alias Patchbay.Transcript
  alias Patchbay.Worker.Operations
  alias Patchbay.Worker.Nix
  alias Patchbay.Worker.Protocol
  alias Patchbay.Worker.Protocol.Stream
  alias Patchbay.Worker.Token

  @loopback_hosts ["127.0.0.1", "localhost"]
  @worker_id_regex ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/
  @control_retry_ms 1_000
  @default_call_timeout 30_000
  @token_min 16
  @token_max 512

  def start_link(opts \\ []) do
    gen_opts =
      case Keyword.get(opts, :name) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Returns the manager's worker-facing loopback endpoint."
  @spec endpoint(GenServer.server()) :: %{host: binary(), port: integer()}
  def endpoint(server), do: GenServer.call(server, :endpoint)

  @doc "Returns `:connected` or `:disconnected` for the supervisor control channel."
  @spec control_status(GenServer.server()) :: :connected | :disconnected
  def control_status(server), do: GenServer.call(server, :control_status)

  @doc "Requests that the worker supervisor start a worker."
  @spec start_worker(GenServer.server(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_worker(server, worker_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    GenServer.call(server, {:start_worker, worker_id, opts}, timeout + 1_000)
  end

  @doc "Waits for a worker to complete its handshake and announce readiness."
  @spec await_worker(GenServer.server(), binary(), timeout()) :: {:ok, map()} | {:error, term()}
  def await_worker(server, worker_id, timeout \\ 10_000) do
    GenServer.call(server, {:await_worker, worker_id}, timeout + 1_000)
  end

  @doc """
  Executes one fixed operation on a ready worker.

  The last argument is a timeout or an options keyword list. Options:
  `:timeout` and `:variables`, a fixed-variable map forwarded to the worker
  unchanged. The map is passed as strings so rendering is identical to native
  toolkit execution.
  """
  @spec execute(GenServer.server(), binary(), binary(), map(), keyword() | timeout()) ::
          {:ok, map()} | {:error, term()}
  def execute(server, worker_id, operation, arguments, opts \\ []) do
    {timeout, variables} = execute_options(opts)

    with {:ok, prepared} <-
           GenServer.call(
             server,
             {:prepare_execute, worker_id, operation, arguments, variables, timeout},
             5_000
           ) do
      result =
        try do
          GenServer.call(
            prepared.session,
            {:execute, prepared.call_id, operation, arguments, variables, timeout},
            timeout + 1_000
          )
        catch
          :exit, {:timeout, _details} -> {:error, :timeout}
          :exit, reason -> {:error, {:worker_unavailable, safe_exit_reason(reason)}}
        end

      GenServer.cast(server, {:execution_result, worker_id, prepared.call_id, result})
      result
    end
  end

  @doc "Asks the supervisor to stop one worker."
  @spec stop_worker(GenServer.server(), binary(), timeout()) :: {:ok, map()} | {:error, term()}
  def stop_worker(server, worker_id, timeout \\ 10_000) do
    GenServer.call(server, {:stop_worker, worker_id}, timeout + 1_000)
  end

  @doc """
  Asks the supervisor to apply a workspace teardown action for one worker.

  The supervisor runs as the agent user and owns the workspace and result
  directories, so it can remove or export them after the worker exits. Only
  the worker id travels in the request; the paths are the ones the supervisor
  allocated for that worker.
  """
  @spec teardown_workspace(GenServer.server(), binary(), atom(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def teardown_workspace(server, worker_id, action, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    GenServer.call(server, {:teardown_workspace, worker_id, action, opts}, timeout + 1_000)
  end

  @doc "Lists workers tracked by the manager."
  @spec list_workers(GenServer.server()) :: [map()]
  def list_workers(server), do: GenServer.call(server, :list_workers)

  @doc "Returns the manager-owned transcript path for a worker."
  @spec transcript_path(GenServer.server(), binary()) :: binary()
  def transcript_path(server, worker_id) do
    GenServer.call(server, {:transcript_path, worker_id})
  end

  @doc """
  Runs the manager service from command-line arguments and blocks.
  """
  @spec main([binary()]) :: no_return()
  def main(argv \\ System.argv()) do
    Patchbay.CLI.ensure_runtime()
    Patchbay.CLI.prepare_service()

    spec = [
      {"supervisor-host", :supervisor_host, :string},
      {"supervisor-port", :supervisor_port, :integer},
      {"transcript-dir", :transcript_dir, :string},
      {"listen-port", :listen_port, :integer}
    ]

    with {:ok, parsed} <- Patchbay.CLI.Options.parse(argv, spec),
         {:ok, opts} <- options_from_argv(parsed),
         {:ok, pid} <- start_link(Keyword.put(opts, :name, __MODULE__)) do
      endpoint = endpoint(pid)
      IO.puts("patchbay manager listening on #{endpoint.host}:#{endpoint.port}")

      Patchbay.CLI.service_loop(pid, "patchbay manager")
    else
      {:error, reason} ->
        IO.puts(:stderr, "patchbay manager: #{format_error(reason)}")
        System.halt(1)
    end
  end

  @impl true
  def init(opts) do
    with {:ok, options} <- validate_options(opts),
         :ok <- Transcript.ensure_dir(options.transcript_dir),
         {:ok, listen} <- listen(options.listen_port) do
      {:ok, actual_port} = :inet.port(listen)
      manager_pid = self()
      acceptor = spawn_link(fn -> accept_loop(listen, manager_pid) end)

      state = %{
        listen: listen,
        port: actual_port,
        acceptor: acceptor,
        supervisor_host: options.supervisor_host,
        supervisor_port: options.supervisor_port,
        control_token: options.control_token,
        transcript_dir: options.transcript_dir,
        control_socket: nil,
        control_reader: nil,
        control_monitor: nil,
        control_retry: nil,
        workers: %{},
        waiters: %{},
        requests: %{},
        sessions: %{},
        session_monitors: %{}
      }

      send(self(), :connect_control)
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:endpoint, _from, state) do
    {:reply, %{host: "127.0.0.1", port: state.port}, state}
  end

  def handle_call(:control_status, _from, state) do
    {:reply, if(state.control_socket, do: :connected, else: :disconnected), state}
  end

  def handle_call(:list_workers, _from, state) do
    workers =
      state.workers
      |> Enum.map(fn {id, worker} ->
        %{worker_id: id, status: worker.status, os_pid: worker.os_pid}
      end)
      |> Enum.sort_by(& &1.worker_id)

    {:reply, workers, state}
  end

  def handle_call({:transcript_path, worker_id}, _from, state) do
    {:reply, worker_transcript_path(state, worker_id), state}
  end

  def handle_call({:start_worker, worker_id, opts}, from, state) do
    with {:ok, worker_id} <- validate_worker_id(worker_id),
         :ok <- ensure_control_connected(state),
         :ok <- ensure_worker_absent(worker_id, state),
         {:ok, workspace} <- optional_absolute_path(opts, :workspace),
         :ok <- workspace_disabled(opts, workspace),
         {:ok, result_dir} <- optional_absolute_path(opts, :result_dir),
         {:ok, state_dir} <- optional_absolute_path(opts, :state_dir),
         {:ok, secrets} <- validate_secrets(opts),
         {:ok, packages} <- validate_packages(opts),
         {:ok, operations} <- validate_operations(opts) do
      token = Token.generate()
      request_id = Token.generate()
      path = worker_transcript_path(state, worker_id)

      worker = %{
        token: token,
        status: :starting,
        session: nil,
        os_pid: nil,
        transcript: path,
        secrets: secrets || %{},
        started_at_ms: System.system_time(:millisecond)
      }

      request = %{from: from, type: :start_worker, worker_id: worker_id}

      state = %{
        state
        | workers: Map.put(state.workers, worker_id, worker),
          requests: Map.put(state.requests, request_id, request)
      }

      message =
        {:start_worker,
         %{
           request_id: request_id,
           worker_id: worker_id,
           token: token,
           manager_host: "127.0.0.1",
           manager_port: state.port
         }
         |> maybe_put_message(:operations, operations)
         |> maybe_put_message(:workspace, workspace)
         |> maybe_put_message(:workspace_disabled, workspace_disabled(opts))
         |> maybe_put_message(:result_dir, result_dir)
         |> maybe_put_message(:state_dir, state_dir)
         |> maybe_put_message(:packages, packages)
         |> maybe_put_message(:secrets, secrets)}

      case Control.send_message(state.control_socket, message) do
        :ok ->
          {:noreply, state}

        {:error, reason} ->
          state = %{
            state
            | workers: Map.delete(state.workers, worker_id),
              requests: Map.delete(state.requests, request_id)
          }

          {:reply, {:error, {:control_send_failed, reason}}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:await_worker, worker_id}, from, state) do
    case Map.fetch(state.workers, worker_id) do
      :error ->
        {:reply, {:error, :unknown_worker}, state}

      {:ok, %{status: :ready} = worker} ->
        {:reply, {:ok, worker_summary(worker_id, worker)}, state}

      {:ok, %{status: status}} when status in [:starting, :connected] ->
        waiters = Map.update(state.waiters, worker_id, [from], &[from | &1])
        {:noreply, %{state | waiters: waiters}}

      {:ok, %{status: status}} ->
        {:reply, {:error, {:worker_not_available, status}}, state}
    end
  end

  def handle_call({:worker_hello, worker_id, token, session}, _from, state) do
    with {:ok, worker_id} <- validate_worker_id(worker_id),
         {:ok, worker} <- Map.fetch(state.workers, worker_id),
         :ok <- ensure_worker_accepts_session(worker),
         true <- Token.equal?(token, worker.token),
         true <- worker.session == nil or not Process.alive?(worker.session) do
      # A reused worker id may still carry records from a session that died
      # before its DOWN was processed. Drop them before installing the new one.
      state = clear_session(state, worker_id)
      monitor = Process.monitor(session)

      worker = %{worker | session: session, status: :connected}

      state = %{
        state
        | workers: Map.put(state.workers, worker_id, worker),
          sessions: Map.put(state.sessions, worker_id, session),
          session_monitors: Map.put(state.session_monitors, monitor, {worker_id, session})
      }

      write_event(state, %{type: :worker_connected, worker_id: worker_id})
      {:reply, :ok, state}
    else
      :error -> {:reply, {:error, :unknown_worker}, state}
      false -> {:reply, {:error, :unauthorized}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:prepare_execute, worker_id, operation, arguments, variables, timeout},
        _from,
        state
      ) do
    with {:ok, worker} <- Map.fetch(state.workers, worker_id),
         true <-
           worker.status == :ready and is_pid(worker.session) and Process.alive?(worker.session),
         true <- is_binary(operation),
         true <- wire_arguments?(arguments),
         true <- wire_map?(variables),
         true <- is_integer(timeout) and timeout > 0 and timeout <= 3_600_000 do
      call_id = Token.generate()

      write_event(state, %{
        type: :tool_call,
        worker_id: worker_id,
        call_id: call_id,
        operation: operation,
        arguments: arguments
      })

      {:reply, {:ok, %{session: worker.session, call_id: call_id}}, state}
    else
      :error -> {:reply, {:error, :unknown_worker}, state}
      false -> {:reply, {:error, :worker_not_ready_or_invalid_request}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop_worker, worker_id}, from, state) do
    with {:ok, worker} <- Map.fetch(state.workers, worker_id),
         :ok <- ensure_control_connected(state) do
      request_id = Token.generate()
      request = %{from: from, type: :stop_worker, worker_id: worker_id}

      message = {:stop_worker, %{request_id: request_id, worker_id: worker_id}}

      case Control.send_message(state.control_socket, message) do
        :ok ->
          workers = Map.put(state.workers, worker_id, %{worker | status: :stopping})

          {:noreply,
           %{state | workers: workers, requests: Map.put(state.requests, request_id, request)}}

        {:error, reason} ->
          {:reply, {:error, {:control_send_failed, reason}}, state}
      end
    else
      :error -> {:reply, {:error, :unknown_worker}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:teardown_workspace, worker_id, action, _opts}, from, state) do
    with {:ok, worker_id} <- validate_worker_id(worker_id),
         {:ok, action} <- validate_teardown_action(action),
         :ok <- ensure_control_connected(state) do
      request_id = Token.generate()
      request = %{from: from, type: :teardown_workspace, worker_id: worker_id}

      message =
        {:teardown_workspace, %{request_id: request_id, worker_id: worker_id, action: action}}

      case Control.send_message(state.control_socket, message) do
        :ok ->
          {:noreply, %{state | requests: Map.put(state.requests, request_id, request)}}

        {:error, reason} ->
          {:reply, {:error, {:control_send_failed, reason}}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:worker_ready, worker_id, session}, state) do
    case Map.fetch(state.workers, worker_id) do
      {:ok, %{session: ^session} = worker} ->
        worker = %{worker | status: :ready}
        state = %{state | workers: Map.put(state.workers, worker_id, worker)}
        write_event(state, %{type: :worker_ready, worker_id: worker_id})
        state = notify_waiters(state, worker_id, {:ok, worker_summary(worker_id, worker)})
        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  def handle_cast({:session_down, worker_id, session, reason}, state) do
    case Map.fetch(state.workers, worker_id) do
      {:ok, %{session: ^session}} ->
        {:noreply, mark_worker_down(state, worker_id, %{session_closed: reason}, session)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_cast({:execution_result, worker_id, call_id, result}, state) do
    event =
      case result do
        {:ok, result} ->
          %{
            type: :tool_result,
            worker_id: worker_id,
            call_id: call_id,
            status: Map.get(result, :status, :error),
            output: Map.get(result, :output, ""),
            error: Map.get(result, :error)
          }

        {:error, reason} ->
          %{
            type: :tool_result,
            worker_id: worker_id,
            call_id: call_id,
            status: :error,
            error: reason
          }
      end

    write_event(state, event)
    {:noreply, state}
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info(:connect_control, state) do
    cond do
      state.control_socket != nil ->
        {:noreply, state}

      true ->
        case Control.connect(
               self(),
               state.supervisor_host,
               state.supervisor_port,
               state.control_token
             ) do
          {:ok, socket, reader} ->
            monitor = Process.monitor(reader)

            {:noreply,
             %{
               state
               | control_socket: socket,
                 control_reader: reader,
                 control_monitor: monitor,
                 control_retry: nil
             }}

          {:error, reason} ->
            Logger.warning("manager control connection failed: #{inspect(reason)}")
            retry = Process.send_after(self(), :connect_control, @control_retry_ms)
            {:noreply, %{state | control_retry: retry}}
        end
    end
  end

  def handle_info(
        {:control_message, {:start_worker_result, %{request_id: request_id} = result}},
        state
      ) do
    case Map.pop(state.requests, request_id) do
      {nil, _requests} ->
        {:noreply, state}

      {request, requests} ->
        state = %{state | requests: requests}

        case result do
          %{status: :started, worker_id: worker_id, os_pid: os_pid} ->
            worker = Map.get(state.workers, worker_id)

            state =
              if worker do
                %{state | workers: Map.put(state.workers, worker_id, %{worker | os_pid: os_pid})}
              else
                state
              end

            GenServer.reply(
              request.from,
              {:ok, %{worker_id: worker_id, os_pid: os_pid, status: :starting}}
            )

            {:noreply, state}

          %{status: :error, error: reason} ->
            state = %{state | workers: Map.delete(state.workers, request.worker_id)}
            GenServer.reply(request.from, {:error, reason})
            {:noreply, state}

          _other ->
            GenServer.reply(request.from, {:error, :invalid_supervisor_response})
            {:noreply, state}
        end
    end
  end

  def handle_info(
        {:control_message, {:stop_worker_result, %{request_id: request_id} = result}},
        state
      ) do
    case Map.pop(state.requests, request_id) do
      {nil, _requests} ->
        {:noreply, state}

      {request, requests} ->
        reply =
          case result do
            %{status: :stopping} -> {:ok, %{worker_id: request.worker_id, status: :stopping}}
            %{status: :error, error: reason} -> {:error, reason}
            _other -> {:error, :invalid_supervisor_response}
          end

        state =
          case result do
            %{status: :stopping} ->
              state

            _other ->
              state
          end

        GenServer.reply(request.from, reply)
        {:noreply, %{state | requests: requests}}
    end
  end

  def handle_info(
        {:control_message, {:teardown_workspace_result, %{request_id: request_id} = result}},
        state
      ) do
    case Map.pop(state.requests, request_id) do
      {nil, _requests} ->
        {:noreply, state}

      {request, requests} ->
        reply =
          case result do
            %{status: :ok, action: action} ->
              {:ok,
               %{
                 worker_id: request.worker_id,
                 action: action,
                 path: Map.get(result, :path)
               }}

            %{status: :error, error: reason} ->
              {:error, reason}

            _other ->
              {:error, :invalid_supervisor_response}
          end

        GenServer.reply(request.from, reply)
        {:noreply, %{state | requests: requests}}
    end
  end

  def handle_info({:control_message, {:worker_exited, %{worker_id: worker_id} = event}}, state) do
    state = mark_worker_down(state, worker_id, %{worker_exited: Map.get(event, :status)})
    {:noreply, state}
  end

  def handle_info({:control_message, _message}, state), do: {:noreply, state}

  def handle_info({:control_closed, reader, reason}, state) do
    if state.control_reader == reader do
      state = drop_control(state, {:control_closed, reason})
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    cond do
      state.control_monitor == monitor ->
        state = drop_control(state, {:control_reader_down, reason})
        {:noreply, state}

      Map.has_key?(state.session_monitors, monitor) ->
        {{worker_id, session}, monitors} = Map.pop(state.session_monitors, monitor)
        state = %{state | session_monitors: monitors}

        state =
          case Map.fetch(state.workers, worker_id) do
            {:ok, %{session: ^session}} ->
              mark_worker_down(state, worker_id, %{session_down: reason}, session)

            _other ->
              state
          end

        {:noreply, state}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.control_socket, do: :gen_tcp.close(state.control_socket)
    if state.listen, do: :gen_tcp.close(state.listen)
    Enum.each(state.sessions, fn {_id, session} -> GenServer.cast(session, :shutdown) end)
    :ok
  end

  defp validate_options(opts) do
    supervisor_host = Keyword.get(opts, :supervisor_host, "127.0.0.1")
    supervisor_port = Keyword.get(opts, :supervisor_port)
    control_token = Token.resolve_control_token(opts)
    transcript_dir = Keyword.get(opts, :transcript_dir)
    listen_port = Keyword.get(opts, :listen_port, 0)

    cond do
      supervisor_host not in @loopback_hosts ->
        {:error, :non_loopback_supervisor}

      not is_integer(supervisor_port) or supervisor_port < 1 or supervisor_port > 65_535 ->
        {:error, :invalid_supervisor_port}

      not is_binary(control_token) or byte_size(control_token) < @token_min or
          byte_size(control_token) > @token_max ->
        {:error, :invalid_control_token}

      not is_binary(transcript_dir) or Path.type(transcript_dir) != :absolute ->
        {:error, :invalid_transcript_dir}

      not is_integer(listen_port) or listen_port < 0 or listen_port > 65_535 ->
        {:error, :invalid_listen_port}

      true ->
        {:ok,
         %{
           supervisor_host: supervisor_host,
           supervisor_port: supervisor_port,
           control_token: control_token,
           transcript_dir: Path.expand(transcript_dir),
           listen_port: listen_port
         }}
    end
  end

  defp validate_worker_id(worker_id) when is_binary(worker_id) do
    if String.valid?(worker_id) and Regex.match?(@worker_id_regex, worker_id),
      do: {:ok, worker_id},
      else: {:error, :invalid_worker_id}
  end

  defp validate_worker_id(_worker_id), do: {:error, :invalid_worker_id}

  defp validate_teardown_action(action) when action in [:retain, :export, :destroy],
    do: {:ok, action}

  defp validate_teardown_action(_action), do: {:error, :invalid_teardown_action}

  defp ensure_worker_accepts_session(%{status: status})
       when status in [:starting, :connected, :ready],
       do: :ok

  defp ensure_worker_accepts_session(%{status: :exited}), do: {:error, :worker_exited}

  defp ensure_worker_accepts_session(%{status: status}),
    do: {:error, {:worker_not_available, status}}

  defp wire_arguments?(arguments) when is_map(arguments) do
    Enum.all?(arguments, fn {name, value} -> is_binary(name) and wire_value?(value) end)
  end

  defp wire_arguments?(_arguments), do: false

  defp wire_map?(map) when is_map(map) do
    Enum.all?(map, fn {key, value} -> is_binary(key) and wire_value?(value) end)
  end

  defp wire_map?(_map), do: false

  defp execute_options(timeout) when is_integer(timeout), do: {timeout, %{}}

  defp execute_options(opts) when is_list(opts) do
    {Keyword.get(opts, :timeout, @default_call_timeout), Keyword.get(opts, :variables, %{})}
  end

  defp execute_options(_opts), do: {@default_call_timeout, %{}}

  defp optional_absolute_path(opts, key) do
    case Keyword.fetch(opts, key) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, path} when is_binary(path) and path != "" ->
        if Path.type(path) == :absolute and not String.contains?(path, <<0>>) do
          {:ok, Path.expand(path)}
        else
          {:error, path_error(key, path)}
        end

      {:ok, path} ->
        {:error, path_error(key, path)}
    end
  end

  # A definition may disable its workspace. The flag travels to the supervisor
  # so it does not allocate a default workspace directory, and neither request
  # flag nor path may be missing when the other is present.
  defp workspace_disabled(opts, workspace) do
    disabled = Keyword.get(opts, :workspace_disabled) == true

    cond do
      disabled and is_binary(workspace) -> {:error, :invalid_workspace}
      true -> :ok
    end
  end

  defp workspace_disabled(opts), do: Keyword.get(opts, :workspace_disabled) == true

  defp path_error(:workspace, path), do: {:invalid_workspace, path}
  defp path_error(:result_dir, path), do: {:invalid_result_dir, path}
  defp path_error(:state_dir, path), do: {:invalid_state_dir, path}

  defp validate_operations(opts) do
    if Keyword.has_key?(opts, :operations) do
      case Operations.validate(Keyword.get(opts, :operations)) do
        {:ok, operations} -> {:ok, operations}
        {:error, reason} -> {:error, {:invalid_operations, reason}}
      end
    else
      {:ok, nil}
    end
  end

  defp validate_secrets(opts) do
    case Keyword.fetch(opts, :secrets) do
      :error ->
        {:ok, nil}

      {:ok, secrets} ->
        case Secrets.validate_map(secrets) do
          :ok when map_size(secrets) > 0 -> {:ok, secrets}
          :ok -> {:ok, nil}
          {:error, reason} -> {:error, {:invalid_secrets, reason}}
        end
    end
  end

  defp validate_packages(opts) do
    case Nix.normalize_packages(Keyword.get(opts, :packages, [])) do
      {:ok, []} -> {:ok, nil}
      {:ok, normalized} -> {:ok, normalized}
      {:error, :invalid_packages} -> {:error, :invalid_packages}
    end
  end

  defp maybe_put_message(map, _key, nil), do: map
  defp maybe_put_message(map, key, value), do: Map.put(map, key, value)

  defp wire_value?(value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value),
       do: true

  defp wire_value?(nil), do: true
  defp wire_value?(_value), do: false

  defp ensure_control_connected(%{control_socket: nil}), do: {:error, :supervisor_unavailable}
  defp ensure_control_connected(_state), do: :ok

  defp ensure_worker_absent(worker_id, state) do
    case Map.fetch(state.workers, worker_id) do
      :error -> :ok
      {:ok, %{status: :exited}} -> :ok
      {:ok, _worker} -> {:error, :already_started}
    end
  end

  defp worker_summary(worker_id, worker) do
    %{worker_id: worker_id, os_pid: worker.os_pid, status: :ready}
  end

  defp notify_waiters(state, worker_id, reply) do
    case Map.pop(state.waiters, worker_id) do
      {nil, _waiters} ->
        state

      {waiters, waiters_map} ->
        Enum.each(waiters, &GenServer.reply(&1, reply))
        %{state | waiters: waiters_map}
    end
  end

  defp mark_worker_down(state, worker_id, details, session \\ nil) do
    case Map.fetch(state.workers, worker_id) do
      :error ->
        state

      {:ok, %{status: :exited}} ->
        state

      {:ok, worker} ->
        session = session || worker.session
        worker = %{worker | status: :exited, os_pid: nil, session: nil}
        state = %{state | workers: Map.put(state.workers, worker_id, worker)}
        state = clear_session(state, worker_id, session)

        state =
          write_event(state, Map.merge(%{type: :worker_exited, worker_id: worker_id}, details))

        state = clear_worker_secrets(state, worker_id)
        state = notify_waiters(state, worker_id, {:error, {:worker_exited, details}})

        if is_pid(session) and Process.alive?(session),
          do: GenServer.cast(session, :shutdown)

        state
    end
  end

  defp clear_session(state, worker_id, session \\ nil) do
    session =
      case {session, Map.fetch(state.workers, worker_id)} do
        {nil, {:ok, %{session: worker_session}}} -> worker_session
        {session, _worker} -> session
      end

    {monitors, kept} =
      Enum.split_with(state.session_monitors, fn {_monitor, {id, pid}} ->
        id == worker_id and (is_nil(session) or pid == session)
      end)

    Enum.each(monitors, fn {monitor, _entry} -> Process.demonitor(monitor, [:flush]) end)

    %{
      state
      | sessions: Map.delete(state.sessions, worker_id),
        session_monitors: Map.new(kept)
    }
  end

  defp drop_control(state, reason) do
    if state.control_socket, do: :gen_tcp.close(state.control_socket)
    if state.control_monitor, do: Process.demonitor(state.control_monitor, [:flush])
    if state.control_retry, do: Process.cancel_timer(state.control_retry)

    state = %{
      state
      | control_socket: nil,
        control_reader: nil,
        control_monitor: nil,
        control_retry: nil
    }

    state = fail_pending_requests(state, {:control_unavailable, reason})
    retry = Process.send_after(self(), :connect_control, @control_retry_ms)
    %{state | control_retry: retry}
  end

  defp fail_pending_requests(state, reason) do
    Enum.each(state.requests, fn {_id, request} ->
      GenServer.reply(request.from, {:error, reason})
    end)

    %{state | requests: %{}}
  end

  defp worker_transcript_path(state, worker_id) do
    Path.join(state.transcript_dir, worker_id <> ".pbt")
  end

  defp write_event(state, event) do
    event = redact_event(event, state)

    frame =
      case Protocol.encode({:event, event}) do
        {:ok, frame} ->
          frame

        {:error, reason} ->
          Logger.warning("transcript event encoding failed: #{inspect(reason)}")
          nil
      end

    if frame do
      path = worker_transcript_path(state, Map.fetch!(event, :worker_id))

      case Transcript.append(path, frame) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("transcript write failed: #{inspect(reason)}")
      end
    end

    state
  end

  defp redact_event(event, state) do
    case Map.fetch(state.workers, Map.get(event, :worker_id)) do
      {:ok, %{secrets: secrets}} when map_size(secrets) > 0 -> Redact.redact(event, secrets)
      _other -> event
    end
  end

  defp clear_worker_secrets(state, worker_id) do
    case Map.fetch(state.workers, worker_id) do
      {:ok, worker} ->
        %{state | workers: Map.put(state.workers, worker_id, %{worker | secrets: %{}})}

      :error ->
        state
    end
  end

  defp safe_exit_reason({reason, _details}), do: reason
  defp safe_exit_reason(reason), do: reason

  defp listen(port) do
    :gen_tcp.listen(port, [
      :binary,
      active: false,
      reuseaddr: true,
      ip: {127, 0, 0, 1},
      backlog: 16
    ])
  end

  defp accept_loop(listen, manager) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        start_session(socket, manager)
        accept_loop(listen, manager)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        Process.sleep(100)
        accept_loop(listen, manager)
    end
  end

  defp start_session(socket, manager) do
    case GenServer.start(__MODULE__.Session, [manager]) do
      {:ok, pid} ->
        case :gen_tcp.controlling_process(socket, pid) do
          :ok ->
            send(pid, {:socket, socket})

          {:error, _reason} ->
            :gen_tcp.close(socket)
            GenServer.stop(pid)
        end

      {:error, _reason} ->
        :gen_tcp.close(socket)
    end
  end

  defp options_from_argv(parsed) do
    opts = [
      supervisor_host: Map.get(parsed, :supervisor_host, "127.0.0.1"),
      transcript_dir: Map.get(parsed, :transcript_dir) || Path.expand("state/transcripts"),
      listen_port: Map.get(parsed, :listen_port, 0)
    ]

    opts =
      case Map.fetch(parsed, :supervisor_port) do
        {:ok, port} -> Keyword.put(opts, :supervisor_port, port)
        :error -> opts
      end

    {:ok, opts}
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end

defmodule Patchbay.CLI.Manager.Control do
  @moduledoc false

  alias Patchbay.Worker.Protocol
  alias Patchbay.Worker.Protocol.Stream

  @connect_timeout 2_000

  def connect(manager, host, port, token) do
    case :gen_tcp.connect(
           to_charlist(host),
           port,
           [:binary, active: false, nodelay: true],
           @connect_timeout
         ) do
      {:ok, socket} ->
        case handshake(socket, token) do
          {:ok, stream, leftovers} ->
            reader = start_reader(socket, manager, stream)
            Enum.each(leftovers, &send(manager, {:control_message, &1}))
            {:ok, socket, reader}

          {:error, reason} ->
            :gen_tcp.close(socket)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handshake(socket, token) do
    with :ok <- send_message(socket, {:hello, %{role: :manager, version: 1, token: token}}),
         {:ok, messages, stream} <- Stream.recv(socket, Stream.new(), @connect_timeout),
         {:ok, welcome, leftovers} <- first_message(messages),
         :ok <- expect_welcome(welcome) do
      {:ok, stream, leftovers}
    end
  end

  def send_message(socket, message) do
    case Protocol.encode(message) do
      {:ok, frame} ->
        case :gen_tcp.send(socket, frame) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp first_message([message | rest]), do: {:ok, message, rest}
  defp first_message([]), do: {:error, :missing_welcome}

  defp expect_welcome({:welcome, %{version: 1}}), do: :ok
  defp expect_welcome({:rejected, %{reason: reason}}), do: {:error, {:rejected, reason}}
  defp expect_welcome(_message), do: {:error, :unexpected_handshake}

  defp start_reader(socket, manager, stream) do
    reader =
      spawn(fn ->
        receive do
          :start -> read_loop(socket, manager, stream)
        end
      end)

    :ok = :gen_tcp.controlling_process(socket, reader)
    send(reader, :start)
    reader
  end

  defp read_loop(socket, manager, stream) do
    case Stream.recv(socket, stream, :infinity) do
      {:ok, messages, stream} ->
        Enum.each(messages, &send(manager, {:control_message, &1}))
        read_loop(socket, manager, stream)

      {:error, reason} ->
        send(manager, {:control_closed, self(), reason})
    end
  end
end

defmodule Patchbay.CLI.Manager.Session do
  @moduledoc false

  use GenServer

  alias Patchbay.Worker.Protocol
  alias Patchbay.Worker.Protocol.Stream

  @handshake_timeout 5_000
  @max_pending 64
  @result_grace_ms 500

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init([manager]) do
    Process.flag(:trap_exit, true)
    manager_monitor = Process.monitor(manager)

    {:ok,
     %{
       manager: manager,
       manager_monitor: manager_monitor,
       socket: nil,
       worker_id: nil,
       reader: nil,
       pending: %{}
     }}
  end

  @impl true
  def handle_info({:socket, socket}, state) do
    stream = Stream.new()

    with {:ok, messages, stream} <- Stream.recv(socket, stream, @handshake_timeout),
         {:ok, hello, after_hello} <- first_message(messages),
         {:ok, worker_id, token} <- parse_hello(hello),
         :ok <- GenServer.call(state.manager, {:worker_hello, worker_id, token, self()}, 5_000),
         :ok <- send_frame(socket, {:welcome, %{version: 1}}),
         {:ok, ready, leftovers, stream} <-
           next_message(after_hello, socket, stream, @handshake_timeout),
         :ok <- expect_ready(ready, worker_id) do
      GenServer.cast(state.manager, {:worker_ready, worker_id, self()})
      reader = start_reader(socket, stream)
      Enum.each(leftovers, &send(self(), {:session_message, &1}))
      {:noreply, %{state | socket: socket, worker_id: worker_id, reader: reader}}
    else
      {:error, reason} ->
        _ = send_frame(socket, {:rejected, %{reason: :unauthorized}})
        :gen_tcp.close(socket)
        {:stop, {:handshake_failed, reason}, state}
    end
  end

  def handle_info({:session_message, {:result, %{call_id: call_id} = result}}, state)
      when is_binary(call_id) do
    case Map.pop(state.pending, call_id) do
      {nil, _pending} ->
        {:noreply, state}

      {pending, pending_map} ->
        if pending.timer, do: Process.cancel_timer(pending.timer)
        GenServer.reply(pending.from, {:ok, result})
        {:noreply, %{state | pending: pending_map}}
    end
  end

  def handle_info({:session_message, {:pong, _payload}}, state), do: {:noreply, state}
  def handle_info({:session_message, _message}, state), do: {:noreply, state}

  def handle_info({:session_closed, reason}, state) do
    fail_pending(state, {:worker_closed, reason})

    if state.worker_id,
      do: GenServer.cast(state.manager, {:session_down, state.worker_id, self(), reason})

    {:stop, :normal, state}
  end

  def handle_info({:request_timeout, call_id}, state) do
    case Map.pop(state.pending, call_id) do
      {nil, _pending} ->
        {:noreply, state}

      {pending, pending_map} ->
        GenServer.reply(pending.from, {:error, :timeout})
        {:noreply, %{state | pending: pending_map}}
    end
  end

  def handle_info(:shutdown, state) do
    fail_pending(state, :shutdown)
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, reader, reason}, %{reader: reader} = state) do
    {:stop, {:reader_exited, reason}, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{manager_monitor: monitor} = state) do
    fail_pending(state, {:manager_down, reason})
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call({:execute, call_id, operation, arguments, variables, timeout}, from, state) do
    cond do
      state.socket == nil ->
        {:reply, {:error, :not_connected}, state}

      map_size(state.pending) >= @max_pending ->
        {:reply, {:error, :busy}, state}

      true ->
        message =
          {:execute,
           %{
             call_id: call_id,
             operation: operation,
             arguments: arguments,
             variables: variables,
             timeout: timeout
           }}

        case send_frame(state.socket, message) do
          :ok ->
            timer =
              Process.send_after(self(), {:request_timeout, call_id}, timeout + @result_grace_ms)

            pending = Map.put(state.pending, call_id, %{from: from, timer: timer})
            {:noreply, %{state | pending: pending}}

          {:error, reason} ->
            {:reply, {:error, {:send_failed, reason}}, state}
        end
    end
  end

  def handle_call(_message, _from, state), do: {:reply, {:error, :unsupported}, state}

  @impl true
  def handle_cast(:shutdown, state) do
    fail_pending(state, :shutdown)
    if state.socket, do: :gen_tcp.close(state.socket)
    {:stop, :normal, state}
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    fail_pending(state, :terminated)
    if state.socket, do: :gen_tcp.close(state.socket)
    :ok
  end

  defp fail_pending(state, reason) do
    Enum.each(state.pending, fn {_call_id, pending} ->
      if pending.timer, do: Process.cancel_timer(pending.timer)
      GenServer.reply(pending.from, {:error, reason})
    end)

    %{state | pending: %{}}
  end

  defp first_message([message | rest]), do: {:ok, message, rest}
  defp first_message([]), do: {:error, :missing_message}

  defp next_message([message | rest], _socket, stream, _timeout),
    do: {:ok, message, rest, stream}

  defp next_message([], socket, stream, timeout) do
    case Stream.recv(socket, stream, timeout) do
      {:ok, [message | rest], stream} -> {:ok, message, rest, stream}
      {:ok, [], _stream} -> {:error, :missing_message}
      {:error, _reason} = error -> error
    end
  end

  defp parse_hello({:hello, %{role: :worker, version: 1, worker_id: worker_id, token: token}})
       when is_binary(worker_id) and is_binary(token),
       do: {:ok, worker_id, token}

  defp parse_hello(_message), do: {:error, :invalid_hello}

  defp expect_ready({:ready, %{worker_id: worker_id}}, worker_id), do: :ok
  defp expect_ready(_message, _worker_id), do: {:error, :invalid_ready}

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
        Enum.each(messages, &send(parent, {:session_message, &1}))
        read_loop(socket, parent, stream)

      {:error, reason} ->
        send(parent, {:session_closed, reason})
    end
  end

  defp send_frame(socket, message) do
    case Protocol.encode(message) do
      {:ok, frame} ->
        case :gen_tcp.send(socket, frame) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
