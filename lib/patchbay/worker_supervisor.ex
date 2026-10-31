defmodule Patchbay.WorkerSupervisor do
  @moduledoc """
  Long-lived worker supervisor.

  The supervisor listens on a loopback TCP control channel for one or more
  managers. A manager may ask it to start or stop a worker. The supervisor
  chooses the executable and argv itself; requests cannot supply a command or
  shell string. A start request may carry one explicit secret map of
  environment variable name to value. Names are validated and only that
  worker receives the values; secret values never appear in argv or logs.

  Each worker is a separate OS process started with
  `Port.open({:spawn_executable, path}, args: argv)`, so no shell parses the
  arguments. Worker stdout/stderr is captured only for diagnostics.
  """

  use GenServer

  require Logger

  alias Patchbay.Worker.Env
  alias Patchbay.Worker.Exec
  alias Patchbay.Worker.Operations
  alias Patchbay.Worker.ProcessGroup
  alias Patchbay.Worker.Protocol
  alias Patchbay.Worker.Protocol.Stream
  alias Patchbay.Worker.Token
  alias Patchbay.Secrets
  alias Patchbay.Transcript

  @loopback_hosts ["127.0.0.1", "localhost"]
  @worker_id_regex ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/
  @request_id_max 128
  @token_min 16
  @token_max 512
  @default_max_workers 64
  @max_workers_limit 1024

  def start_link(opts \\ []) do
    gen_opts =
      case Keyword.get(opts, :name) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Returns the actual loopback port the control server listens on."
  @spec port(GenServer.server()) :: integer()
  def port(server), do: GenServer.call(server, :port)

  @doc "Returns currently tracked workers."
  @spec list_workers(GenServer.server()) :: [map()]
  def list_workers(server), do: GenServer.call(server, :list_workers)

  @doc false
  def request(server, message), do: GenServer.call(server, {:request, message}, 30_000)

  @doc """
  Runs the supervisor from command-line arguments and blocks.

  The control token comes from `PATCHBAY_CONTROL_TOKEN` or the file named by
  `PATCHBAY_CONTROL_TOKEN_FILE`; it is never accepted through argv.
  """
  @spec main([binary()]) :: no_return()
  def main(argv \\ System.argv()) do
    Patchbay.CLI.ensure_runtime()
    Patchbay.CLI.prepare_service()

    spec = [
      {"listen-port", :listen_port, :integer},
      {"worker-executable", :worker_executable, :string},
      {"operations", :operations_path, :string},
      {"workspace", :workspace, :string},
      {"workspace-root", :workspace_root, :string},
      {"result-root", :result_root, :string},
      {"state-root", :state_root, :string},
      {"worker-cd", :worker_cd, :string},
      {"max-workers", :max_workers, :integer}
    ]

    with {:ok, parsed} <- Patchbay.CLI.Options.parse(argv, spec),
         {:ok, opts} <- options_from_argv(parsed),
         {:ok, pid} <- start_link(opts) do
      IO.puts("patchbay worker-supervisor listening on 127.0.0.1:#{port(pid)}")

      Patchbay.CLI.service_loop(pid, "patchbay worker-supervisor")
    else
      {:error, reason} ->
        IO.puts(:stderr, "patchbay worker-supervisor: #{format_error(reason)}")
        System.halt(1)
    end
  end

  @impl true
  def init(opts) do
    control_token = Token.resolve_control_token(opts)
    max_workers = Keyword.get(opts, :max_workers, @default_max_workers)
    listen_port = Keyword.get(opts, :listen_port, 0)

    with :ok <- validate_token(control_token),
         {:ok, executable} <- resolve_worker_executable(opts[:worker_executable]),
         :ok <- validate_worker_args(Keyword.get(opts, :worker_args, ["run-worker"])),
         :ok <- validate_optional_file(Keyword.get(opts, :operations_path)),
         :ok <- validate_optional_directory(Keyword.get(opts, :workspace)),
         :ok <- validate_optional_directory(Keyword.get(opts, :worker_cd)),
         {:ok, workspace_root} <- ensure_optional_root(Keyword.get(opts, :workspace_root)),
         {:ok, result_root} <- ensure_optional_root(Keyword.get(opts, :result_root)),
         {:ok, state_root} <- ensure_optional_root(Keyword.get(opts, :state_root)),
         :ok <- validate_max_workers(max_workers),
         {:ok, listen} <- listen(listen_port) do
      {:ok, actual_port} = :inet.port(listen)
      supervisor_pid = self()
      acceptor = spawn_link(fn -> accept_loop(listen, supervisor_pid, control_token) end)

      {:ok,
       %{
         listen: listen,
         port: actual_port,
         acceptor: acceptor,
         control_token: control_token,
         worker_executable: executable,
         worker_args: Keyword.get(opts, :worker_args, ["run-worker"]),
         operations_path: Keyword.get(opts, :operations_path),
         workspace: Keyword.get(opts, :workspace),
         workspace_root: workspace_root,
         result_root: result_root,
         state_root: state_root,
         worker_cd: Keyword.get(opts, :worker_cd),
         max_workers: max_workers,
         workers: %{},
         port_to_worker: %{},
         connections: MapSet.new(),
         connection_monitors: %{}
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call(:list_workers, _from, state) do
    workers =
      state.workers
      |> Enum.map(fn {id, worker} ->
        %{worker_id: id, os_pid: worker.os_pid, status: :running}
      end)
      |> Enum.sort_by(& &1.worker_id)

    {:reply, workers, state}
  end

  def handle_call({:register_connection, pid}, _from, state) when is_pid(pid) do
    if MapSet.member?(state.connections, pid) do
      {:reply, :ok, state}
    else
      monitor = Process.monitor(pid)

      {:reply, :ok,
       %{
         state
         | connections: MapSet.put(state.connections, pid),
           connection_monitors: Map.put(state.connection_monitors, monitor, pid)
       }}
    end
  end

  def handle_call({:request, message}, _from, state) do
    {reply, state} = handle_request(message, state)
    {:reply, reply, state}
  end

  @impl true
  def handle_info({:tcp, _socket, _data}, state), do: {:noreply, state}

  def handle_info({port, {:data, data}}, state) when is_port(port) do
    if Map.has_key?(state.port_to_worker, port) do
      Logger.debug(fn ->
        "worker port output: #{inspect(binary_part(data, 0, min(byte_size(data), 2048)))}"
      end)
    end

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    state =
      case Map.fetch(state.port_to_worker, port) do
        {:ok, worker_id} -> cleanup_worker(worker_id, %{exit_status: status}, state)
        :error -> state
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :port, _port, reason}, state) do
    state =
      case Enum.find(state.workers, fn {_id, worker} -> worker.monitor == monitor end) do
        {worker_id, _worker} -> cleanup_worker(worker_id, %{port_down: reason}, state)
        nil -> state
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.connection_monitors, monitor) do
      {nil, _monitors} ->
        {:noreply, state}

      {pid, monitors} ->
        {:noreply,
         %{
           state
           | connections: MapSet.delete(state.connections, pid),
             connection_monitors: monitors
         }}
    end
  end

  def handle_info({:accept_error, reason}, state) do
    Logger.error("worker supervisor accept failed: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.workers, fn {_id, worker} -> stop_worker_process(worker) end)
    if state.listen, do: :gen_tcp.close(state.listen)
    :ok
  end

  defp handle_request({:start_worker, %{} = request}, state) do
    with {:ok, request_id} <- request_id(request),
         {:ok, worker_id} <- worker_id(request),
         {:ok, token} <- worker_token(request),
         {:ok, host} <- manager_host(request),
         {:ok, manager_port} <- manager_port(request),
         :ok <- check_worker_slot(worker_id, state),
         {:ok, secrets} <- worker_secrets(request),
         {:ok, paths} <- prepare_agent_paths(request, worker_id, state),
         {:ok, operations_path} <- prepare_operations(request, worker_id, paths, state) do
      case start_worker_process(
             worker_id,
             token,
             host,
             manager_port,
             operations_path,
             paths.workspace,
             paths.result_dir,
             secrets,
             state
           ) do
        {:ok, worker} ->
          worker = Map.put(worker, :operations_path, operations_path)
          workers = Map.put(state.workers, worker_id, worker)
          port_to_worker = Map.put(state.port_to_worker, worker.port, worker_id)

          response =
            {:start_worker_result,
             %{
               request_id: request_id,
               status: :started,
               worker_id: worker_id,
               os_pid: worker.os_pid
             }}

          {response, %{state | workers: workers, port_to_worker: port_to_worker}}

        {:error, reason} ->
          remove_operations_file(operations_path, state)

          response =
            {:start_worker_result, %{request_id: request_id, status: :error, error: reason}}

          {response, state}
      end
    else
      {:error, reason} ->
        {{:start_worker_result,
          %{request_id: fallback_request_id(request), status: :error, error: reason}}, state}
    end
  end

  defp handle_request({:stop_worker, %{} = request}, state) do
    with {:ok, request_id} <- request_id(request),
         {:ok, worker_id} <- worker_id(request) do
      case Map.fetch(state.workers, worker_id) do
        {:ok, worker} ->
          stop_worker_process(worker)

          response =
            {:stop_worker_result,
             %{request_id: request_id, status: :stopping, worker_id: worker_id}}

          {response, state}

        :error ->
          response =
            {:stop_worker_result,
             %{request_id: request_id, status: :error, error: :unknown_worker}}

          {response, state}
      end
    else
      {:error, reason} ->
        {{:stop_worker_result,
          %{request_id: fallback_request_id(request), status: :error, error: reason}}, state}
    end
  end

  defp handle_request({:list_workers, %{} = request}, state) do
    with {:ok, request_id} <- request_id(request) do
      workers =
        state.workers
        |> Enum.map(fn {id, worker} -> %{worker_id: id, os_pid: worker.os_pid} end)
        |> Enum.sort_by(& &1.worker_id)

      {{:list_workers_result, %{request_id: request_id, status: :ok, workers: workers}}, state}
    else
      {:error, reason} ->
        {{:list_workers_result,
          %{request_id: fallback_request_id(request), status: :error, error: reason}}, state}
    end
  end

  defp handle_request(message, state) do
    request_id =
      case message do
        %{request_id: id} when is_binary(id) and byte_size(id) <= @request_id_max -> id
        _ -> nil
      end

    {{:error_response, %{request_id: request_id, error: :unknown_message}}, state}
  end

  defp request_id(%{request_id: id}) when is_binary(id) and byte_size(id) in 1..@request_id_max,
    do: {:ok, id}

  defp request_id(_request), do: {:error, :invalid_request_id}

  defp fallback_request_id(%{request_id: id})
       when is_binary(id) and byte_size(id) <= @request_id_max,
       do: id

  defp fallback_request_id(_request), do: nil

  defp worker_id(%{worker_id: id}) when is_binary(id) do
    if String.valid?(id) and Regex.match?(@worker_id_regex, id),
      do: {:ok, id},
      else: {:error, :invalid_worker_id}
  end

  defp worker_id(_request), do: {:error, :invalid_worker_id}

  defp worker_token(%{token: token})
       when is_binary(token) and byte_size(token) >= @token_min and byte_size(token) <= @token_max,
       do: {:ok, token}

  defp worker_token(_request), do: {:error, :invalid_worker_token}

  defp manager_host(%{manager_host: host}) when host in @loopback_hosts, do: {:ok, host}
  defp manager_host(_request), do: {:error, :non_loopback_manager}

  defp manager_port(%{manager_port: port}) when is_integer(port) and port in 1..65_535,
    do: {:ok, port}

  defp manager_port(_request), do: {:error, :invalid_manager_port}

  defp worker_secrets(%{secrets: secrets}) do
    case Secrets.validate_map(secrets) do
      :ok -> {:ok, secrets}
      {:error, _reason} -> {:error, :invalid_secrets}
    end
  end

  defp worker_secrets(_request), do: {:ok, %{}}

  defp prepare_agent_paths(request, worker_id, state) do
    with {:ok, workspace} <-
           prepare_workspace(request, worker_id, state),
         {:ok, result_dir} <-
           prepare_agent_dir(request, :result_dir, worker_id, state.result_root, nil),
         {:ok, state_dir} <-
           prepare_agent_dir(request, :state_dir, worker_id, state.state_root, nil) do
      {:ok, %{workspace: workspace, result_dir: result_dir, state_dir: state_dir}}
    end
  end

  # An agent definition may disable its workspace. The explicit flag keeps the
  # default allocation from happening: no directory is created, the worker
  # spawns without a workspace, and `{%workspace}` operations fail.
  defp prepare_workspace(%{workspace_disabled: true} = _request, _worker_id, _state),
    do: {:ok, nil}

  defp prepare_workspace(request, worker_id, state) do
    prepare_agent_dir(request, :workspace, worker_id, state.workspace_root, state.workspace)
  end

  defp prepare_agent_dir(request, key, worker_id, root, fallback) do
    requested =
      case Map.fetch(request, key) do
        {:ok, path} when is_binary(path) -> path
        {:ok, nil} -> nil
        {:ok, _other} -> :invalid
        :error -> nil
      end

    cond do
      requested == :invalid ->
        {:error, path_error(key)}

      is_binary(requested) and root != nil ->
        if absolute_under?(requested, root) do
          ensure_agent_dir(requested, key)
        else
          {:error, path_error(key)}
        end

      is_binary(requested) ->
        case File.stat(requested) do
          {:ok, %File.Stat{type: :directory}} -> {:ok, Path.expand(requested)}
          _other -> {:error, path_error(key)}
        end

      root != nil ->
        ensure_agent_dir(Path.join(root, worker_id), key)

      true ->
        case fallback do
          path when is_binary(path) -> {:ok, Path.expand(path)}
          _other -> {:ok, nil}
        end
    end
  end

  defp ensure_agent_dir(path, _key) do
    case Transcript.ensure_dir(path) do
      :ok -> {:ok, Path.expand(path)}
      {:error, _reason} -> {:error, :agent_directory_unavailable}
    end
  end

  defp absolute_under?(path, root) when is_binary(path) and is_binary(root) do
    expanded = Path.expand(path)
    base = Path.expand(root)

    expanded != base and
      String.starts_with?(expanded, base <> "/") and
      not String.contains?(path, <<0>>)
  end

  defp absolute_under?(_path, _root), do: false

  defp path_error(:workspace), do: :invalid_workspace
  defp path_error(:result_dir), do: :invalid_result_dir
  defp path_error(:state_dir), do: :invalid_state_dir

  defp prepare_operations(request, worker_id, paths, state) do
    case Map.fetch(request, :operations) do
      :error ->
        {:ok, state.operations_path}

      {:ok, nil} ->
        {:ok, state.operations_path}

      {:ok, operations} ->
        with {:ok, operations} <- Operations.validate(operations),
             {:ok, state_dir} <- operations_state_dir(paths, worker_id, state),
             :ok <- write_operations_file(state_dir, operations) do
          {:ok, Path.join(state_dir, "operations.pbt")}
        else
          {:error, reason} -> {:error, {:invalid_operations, reason}}
        end
    end
  end

  defp operations_state_dir(%{state_dir: state_dir}, _worker_id, _state)
       when is_binary(state_dir),
       do: {:ok, state_dir}

  defp operations_state_dir(_paths, worker_id, %{state_root: root}) when is_binary(root),
    do: ensure_agent_dir(Path.join(root, worker_id), :state_dir)

  defp operations_state_dir(_paths, _worker_id, _state),
    do: {:error, :agent_state_root_not_configured}

  defp write_operations_file(state_dir, operations) do
    path = Path.join(state_dir, "operations.pbt")
    _ = File.rm(path)

    with :ok <- Transcript.ensure_file(path),
         {:ok, io} <- File.open(path, [:write, :binary, :exclusive]) do
      written = IO.binwrite(io, :erlang.term_to_binary(operations))
      File.close(io)

      case written do
        :ok -> File.chmod(path, 0o600)
        {:error, _reason} -> {:error, :operations_write_failed}
      end
    else
      _other -> {:error, :operations_write_failed}
    end
  end

  defp check_worker_slot(worker_id, state) do
    cond do
      Map.has_key?(state.workers, worker_id) -> {:error, :already_started}
      map_size(state.workers) >= state.max_workers -> {:error, :worker_limit}
      true -> :ok
    end
  end

  defp start_worker_process(
         worker_id,
         token,
         host,
         manager_port,
         operations_path,
         workspace,
         result_dir,
         secrets,
         state
       ) do
    instance = Token.generate()

    args =
      state.worker_args ++
        optional_arg("--result-dir", result_dir) ++
        [
          "--worker-id",
          worker_id,
          "--manager-host",
          host,
          "--manager-port",
          Integer.to_string(manager_port)
        ]

    env =
      Env.worker_env(
        %{
          "PATCHBAY_HOME" => System.get_env("PATCHBAY_HOME"),
          "PATCHBAY_WORKER_TOKEN" => token,
          "PATCHBAY_OPERATIONS" => operations_path,
          "PATCHBAY_WORKSPACE" => workspace,
          "PATCHBAY_RESULT_DIR" => result_dir,
          Env.instance_variable() => instance
        }
        |> maybe_put_secret_names(secrets),
        System.get_env(),
        secrets
      )

    {spawn_executable, spawn_args} =
      ProcessGroup.command(state.worker_executable, args)

    port_options =
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        {:args, Enum.map(spawn_args, &to_charlist/1)},
        {:env, env}
      ] ++ cd_option(state.worker_cd || workspace)

    try do
      port = Port.open({:spawn_executable, to_charlist(spawn_executable)}, port_options)

      os_pid =
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> pid
          _ -> nil
        end

      Process.unlink(port)
      monitor = :erlang.monitor(:port, port)

      {:ok,
       %{
         port: port,
         os_pid: os_pid,
         monitor: monitor,
         token: token,
         instance: instance,
         group: ProcessGroup.group_leader?(os_pid)
       }}
    rescue
      _error -> {:error, :worker_spawn_failed}
    end
  end

  defp cd_option(nil), do: []
  defp cd_option(path), do: [{:cd, to_charlist(path)}]

  defp optional_arg(_flag, nil), do: []
  defp optional_arg(flag, value), do: [flag, value]

  defp maybe_put_secret_names(extra, secrets) when map_size(secrets) == 0, do: extra

  defp maybe_put_secret_names(extra, secrets) do
    Map.put(extra, Env.secret_names_variable(), Env.encode_secret_names(Map.keys(secrets)))
  end

  defp cleanup_worker(worker_id, status, state) do
    case Map.pop(state.workers, worker_id) do
      {nil, _workers} ->
        state

      {worker, workers} ->
        stop_worker_process(worker)
        :erlang.demonitor(worker.monitor, [:flush])
        remove_worker_operations(worker, state)
        port_to_worker = Map.delete(state.port_to_worker, worker.port)
        notify_connections({:worker_exited, %{worker_id: worker_id, status: status}}, state)

        %{state | workers: workers, port_to_worker: port_to_worker}
    end
  end

  defp remove_worker_operations(worker, state) do
    case Map.get(worker, :operations_path) do
      path when is_binary(path) -> remove_operations_file(path, state)
      _other -> :ok
    end
  end

  defp remove_operations_file(path, state)
       when is_binary(path) and path != state.operations_path do
    File.rm(path)
  end

  defp remove_operations_file(_path, _state), do: :ok

  defp notify_connections(message, state) do
    encoded = Protocol.encode(message)

    if match?({:ok, _frame}, encoded) do
      Enum.each(state.connections, fn pid -> send(pid, message) end)
    end
  end

  defp stop_worker_process(worker) do
    ProcessGroup.terminate(Map.get(worker, :os_pid), Map.get(worker, :group, false))

    try do
      Port.close(worker.port)
    rescue
      _error -> :ok
    end

    ProcessGroup.terminate_instance(Map.get(worker, :instance))
  end

  defp accept_loop(listen, supervisor, token) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        start_connection(socket, supervisor, token)
        accept_loop(listen, supervisor, token)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        send(supervisor, {:accept_error, reason})
        Process.sleep(100)
        accept_loop(listen, supervisor, token)
    end
  end

  defp start_connection(socket, supervisor, token) do
    case GenServer.start(__MODULE__.Connection, [supervisor, token]) do
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

  defp listen(port) do
    :gen_tcp.listen(port, [
      :binary,
      active: false,
      reuseaddr: true,
      ip: {127, 0, 0, 1},
      backlog: 16
    ])
  end

  defp validate_token(nil), do: {:error, :missing_control_token}

  defp validate_token(token) when is_binary(token) do
    if byte_size(token) >= @token_min and byte_size(token) <= @token_max do
      :ok
    else
      {:error, :invalid_control_token}
    end
  end

  defp validate_token(_token), do: {:error, :invalid_control_token}

  defp resolve_worker_executable(nil) do
    case System.get_env("PATCHBAY_EXECUTABLE") do
      nil ->
        case System.find_executable("patchbay") do
          nil -> {:error, :worker_executable_not_found}
          path -> resolve_worker_executable(path)
        end

      path ->
        resolve_worker_executable(path)
    end
  end

  defp resolve_worker_executable(executable) when is_binary(executable) do
    resolved =
      cond do
        Path.type(executable) == :absolute -> executable
        true -> System.find_executable(executable)
      end

    cond do
      is_nil(resolved) -> {:error, :worker_executable_not_found}
      Exec.valid_executable?(resolved) -> {:ok, resolved}
      true -> {:error, {:invalid_worker_executable, executable}}
    end
  end

  defp resolve_worker_executable(_executable), do: {:error, :invalid_worker_executable}

  defp validate_worker_args(args) when is_list(args) do
    if length(args) <= 256 and
         Enum.all?(
           args,
           &(is_binary(&1) and byte_size(&1) <= 65_536 and not contains_nul?(&1))
         ) do
      :ok
    else
      {:error, :invalid_worker_args}
    end
  end

  defp validate_worker_args(_args), do: {:error, :invalid_worker_args}

  defp validate_optional_file(nil), do: :ok

  defp validate_optional_file(path) when is_binary(path) do
    if Path.type(path) == :absolute and
         match?({:ok, %File.Stat{type: :regular}}, File.stat(path)),
       do: :ok,
       else: {:error, {:invalid_operations_path, path}}
  end

  defp validate_optional_file(_path), do: {:error, :invalid_operations_path}

  defp validate_optional_directory(nil), do: :ok

  defp validate_optional_directory(path) when is_binary(path) do
    if Path.type(path) == :absolute and
         match?({:ok, %File.Stat{type: :directory}}, File.stat(path)),
       do: :ok,
       else: {:error, {:invalid_directory, path}}
  end

  defp validate_optional_directory(_path), do: {:error, :invalid_directory}

  defp ensure_optional_root(nil), do: {:ok, nil}

  defp ensure_optional_root(path) when is_binary(path) do
    if Path.type(path) == :absolute and not String.contains?(path, <<0>>) do
      case Transcript.ensure_dir(path) do
        :ok -> {:ok, Path.expand(path)}
        {:error, reason} -> {:error, {:invalid_directory, path, reason}}
      end
    else
      {:error, {:invalid_directory, path}}
    end
  end

  defp ensure_optional_root(_path), do: {:error, :invalid_directory}

  defp validate_max_workers(value)
       when is_integer(value) and value > 0 and value <= @max_workers_limit,
       do: :ok

  defp validate_max_workers(_value), do: {:error, :invalid_max_workers}

  defp options_from_argv(parsed) do
    worker_executable =
      Map.get(parsed, :worker_executable) || System.get_env("PATCHBAY_EXECUTABLE")

    opts = [
      listen_port: Map.get(parsed, :listen_port, 0)
    ]

    opts =
      opts
      |> maybe_put_opt(:worker_executable, worker_executable)
      |> maybe_put_opt(:operations_path, Map.get(parsed, :operations_path))
      |> maybe_put_opt(:workspace, Map.get(parsed, :workspace))
      |> maybe_put_opt(:workspace_root, Map.get(parsed, :workspace_root))
      |> maybe_put_opt(:result_root, Map.get(parsed, :result_root))
      |> maybe_put_opt(:state_root, Map.get(parsed, :state_root))
      |> maybe_put_opt(:worker_cd, Map.get(parsed, :worker_cd))
      |> maybe_put_opt(:max_workers, Map.get(parsed, :max_workers))

    {:ok, opts}
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp contains_nul?(value), do: :binary.match(value, <<0>>) != :nomatch

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end

defmodule Patchbay.WorkerSupervisor.Connection do
  @moduledoc false

  use GenServer

  alias Patchbay.Worker.Protocol
  alias Patchbay.Worker.Protocol.Stream
  alias Patchbay.Worker.Token

  @handshake_timeout 5_000

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init([supervisor, control_token]) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       supervisor: supervisor,
       control_token: control_token,
       socket: nil,
       reader: nil,
       authenticated: false
     }}
  end

  @impl true
  def handle_info({:socket, socket}, state) do
    case handshake(socket, state.control_token) do
      {:ok, stream, leftovers} ->
        :ok = GenServer.call(state.supervisor, {:register_connection, self()}, 5_000)
        reader = start_reader(socket, stream)
        Enum.each(leftovers, &send(self(), {:control_message, &1}))

        {:noreply, %{state | socket: socket, reader: reader, authenticated: true}}

      {:error, _reason} ->
        :gen_tcp.close(socket)
        {:stop, :normal, state}
    end
  end

  def handle_info({:control_message, message}, state) do
    try do
      response = GenServer.call(state.supervisor, {:request, message}, 30_000)

      case send_frame(state.socket, response) do
        :ok -> {:noreply, state}
        {:error, reason} -> {:stop, reason, state}
      end
    catch
      :exit, reason -> {:stop, {:supervisor_unavailable, reason}, state}
    end
  end

  def handle_info({:worker_exited, _event} = message, state) do
    case send_frame(state.socket, message) do
      :ok -> {:noreply, state}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  def handle_info({:control_closed, _reason}, state), do: {:stop, :normal, state}

  def handle_info({:EXIT, reader, reason}, %{reader: reader} = state) do
    {:stop, {:reader_exited, reason}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    :ok
  end

  defp handshake(socket, control_token) do
    stream = Stream.new()

    with {:ok, messages, stream} <- Stream.recv(socket, stream, @handshake_timeout),
         {:ok, hello, leftovers} <- first_message(messages),
         :ok <- validate_hello(hello, control_token),
         :ok <- send_frame(socket, {:welcome, %{version: 1}}) do
      {:ok, stream, leftovers}
    else
      {:error, reason} ->
        _ = send_frame(socket, {:rejected, %{reason: :unauthorized}})
        {:error, reason}
    end
  end

  defp first_message([message | rest]), do: {:ok, message, rest}
  defp first_message([]), do: {:error, :missing_hello}

  defp validate_hello({:hello, %{role: :manager, version: 1, token: token}}, expected) do
    if Token.equal?(token, expected), do: :ok, else: {:error, :unauthorized}
  end

  defp validate_hello(_message, _expected), do: {:error, :invalid_hello}

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
        Enum.each(messages, &send(parent, {:control_message, &1}))
        read_loop(socket, parent, stream)

      {:error, reason} ->
        send(parent, {:control_closed, reason})
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
