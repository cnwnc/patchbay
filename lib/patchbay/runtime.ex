defmodule Patchbay.Runtime.DefinitionSource do
  @moduledoc """
  Injected source of agent definitions for `Patchbay.Runtime`.

  The runtime accepts a module with `list/0` and `get/1`, a `{module, server}`
  pair with `list/1` and `get/2`, or a `%{agent_id => definition}` map. The
  runtime never loads the filesystem itself.

  `Patchbay.DefinitionRegistry` satisfies the module form through its default
  server name, and its snapshots' `:revision` values are recorded.
  """

  alias Patchbay.Definition

  @callback list() ::
              [Definition.t() | map()] | {:ok, [Definition.t() | map()]} | {:error, term()}
  @callback get(term()) :: {:ok, Definition.t() | map()} | {:error, term()}
end

defmodule Patchbay.Runtime.DefinitionServerSource do
  @moduledoc """
  Server-backed source shape accepted as `{module, server}`.

  `Patchbay.DefinitionRegistry` already exposes `list(server)` and
  `get(id, server)` returning snapshots. A snapshot may carry `:revision` and
  `:fingerprint`; the runtime records the registry revision when present.

  Use `definitions: {Patchbay.DefinitionRegistry, server}` for an unnamed or
  custom registry process.
  """

  @callback list(server :: term()) :: [map()] | {:ok, [map()]} | {:error, term()}
  @callback get(id :: term(), server :: term()) :: {:ok, map()} | {:error, term()}
end

defmodule Patchbay.Runtime.WorkerClient do
  @moduledoc """
  Adapter between the runtime and the manager-owned worker process.

  `Patchbay.Runtime.CLIManagerClient` is the default and delegates to
  `Patchbay.CLI.Manager`.
  """

  @callback start_worker(term(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback await_worker(term(), binary(), timeout()) :: {:ok, map()} | {:error, term()}
  @callback execute(term(), binary(), binary(), map(), keyword() | timeout()) ::
              {:ok, map()} | {:error, term()}
  @callback stop_worker(term(), binary(), timeout()) :: {:ok, map()} | {:error, term()}
  @callback transcript_path(term(), binary()) :: binary()
end

defmodule Patchbay.Runtime.CLIManagerClient do
  @moduledoc false

  @behaviour Patchbay.Runtime.WorkerClient

  alias Patchbay.CLI.Manager

  @impl true
  def start_worker(manager, worker_id, opts), do: Manager.start_worker(manager, worker_id, opts)

  @impl true
  def await_worker(manager, worker_id, timeout),
    do: Manager.await_worker(manager, worker_id, timeout)

  @impl true
  def execute(manager, worker_id, operation, arguments, timeout),
    do: Manager.execute(manager, worker_id, operation, arguments, timeout)

  @impl true
  def stop_worker(manager, worker_id, timeout),
    do: Manager.stop_worker(manager, worker_id, timeout)

  @impl true
  def transcript_path(manager, worker_id), do: Manager.transcript_path(manager, worker_id)
end

defmodule Patchbay.Runtime do
  @moduledoc """
  Runtime orchestration for agent definitions, lifecycle, workers, and durable
  history.

  The runtime binds three existing pieces together:

    * a definition source implementing `Patchbay.Runtime.DefinitionSource`
    * `Patchbay.Lifecycle` for run, attempt, and instance identity
    * a manager worker (`Patchbay.CLI.Manager` by default) for process control
      and fixed-operation execution

  Every lifecycle transition is appended to a per-agent event file under
  `PATCHBAY_STATE_DIR`, and every executed tool produces one tool-history
  record under the same root. Each agent gets workspace, result, and state
  directories derived from `Patchbay.Config`; the worker receives only its
  workspace and a manager-written per-agent operations file. Worker processes
  receive no transcript or manager state paths; the manager owns transcripts
  and the runtime owns events and tool history.

  Passing `:provider` and `:provider_opts` enables the model loop. The runtime
  then starts `Patchbay.AgentRunner` after the worker is ready, exposes
  `send_message/4`, `steer/4`, `await_agent/3`, and keeps the current provider
  message list in memory. Without `:provider` the runtime stays worker-only.
  Provider setup is validated before a run starts; incomplete configuration is
  returned as `{:error, {:provider_not_configured, detail}}`.

  Calls that start or stop workers are synchronous. Agent state is held in
  this process; durable events and tool history allow a future layer to
  reconstruct history, but this module does not replay a previous runtime's
  lifecycle state on boot. Provider messages are checkpointed to
  `Patchbay.ContextStore` and selectively restored when the definition's
  `[context]` policy calls for them. An interrupted run restores at a complete
  turn boundary; tool outcomes are recorded before dispatch, so a half-executed
  tool turn restores as an unknown outcome rather than being replayed.
  """

  use GenServer

  require Logger

  alias Patchbay.AgentRunner
  alias Patchbay.ArtifactStore
  alias Patchbay.Config
  alias Patchbay.ContextCompaction
  alias Patchbay.ContextStore
  alias Patchbay.Event
  alias Patchbay.Lifecycle
  alias Patchbay.Provider.{Message, Request, Response, ToolCall}
  alias Patchbay.Run
  alias Patchbay.Secrets.Env, as: SecretEnv
  alias Patchbay.Secrets.Redact
  alias Patchbay.ToolHistory
  alias Patchbay.ToolHistory.Writer
  alias Patchbay.Toolkit.{Hooks, Manifest, Registry, Variables}
  alias Patchbay.Definition.Workspace
  alias Patchbay.Transcript
  alias Patchbay.Worker.Operations

  @default_timeout 10_000
  @default_await_timeout 20_000
  @default_execute_timeout 30_000
  @default_hook_timeout 30_000
  @artifact_read_timeout 10_000
  @artifact_chunk_bytes 512 * 1024
  # Wall-clock cap for copying one run's file results out through the worker;
  # bounds the publication task even if every chunk takes its full timeout.
  @artifact_publication_timeout 120_000
  @history_result_bytes 16_384
  @history_arguments_bytes 16_384

  @type agent_id :: term()
  @type status :: :stopped | :starting | :running | :stopping | :failed
  @type activity :: :idle | :thinking | :executing_tool | :waiting | :publishing

  @type agent_summary :: %{
          agent_id: term(),
          status: status(),
          activity: activity(),
          stream_text: binary() | nil,
          definition_revision: pos_integer() | nil,
          lifecycle_kind: atom() | nil,
          model: binary() | nil,
          toolkit_ids: [binary()],
          tools: [binary()],
          worker_id: binary() | nil,
          run_id: term() | nil,
          run_status: atom() | nil,
          attempt_id: term() | nil,
          attempt_ordinal: pos_integer() | nil,
          instance_id: term() | nil,
          message_count: non_neg_integer(),
          pending_messages: non_neg_integer(),
          result: map() | nil,
          failure: term() | nil,
          started_at: term() | nil,
          stopped_at: term() | nil,
          last_error: term() | nil
        }

  def start_link(opts \\ []) do
    gen_opts =
      case Keyword.get(opts, :name) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Lists every definition known to the source plus any agent this runtime has
  seen, with its current lifecycle summary.
  """
  @spec list_agents(GenServer.server()) :: {:ok, [agent_summary()]} | {:error, term()}
  def list_agents(server), do: GenServer.call(server, :list_agents)

  @doc "Returns one agent summary plus its current definition."
  @spec get_agent(GenServer.server(), agent_id()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def get_agent(server, agent_id), do: GenServer.call(server, {:get_agent, agent_id})

  @doc """
  Starts one agent, its run/attempt/instance, and its worker.

  When a runner provider is configured, the model loop starts asynchronously
  after the worker is ready. Options: `:timeout` for the worker start request,
  `:await_timeout` for the worker handshake, and `:message` to seed one user
  message before the first provider turn.
  """
  @spec start_agent(GenServer.server(), agent_id(), keyword()) ::
          {:ok, agent_summary()} | {:error, term()}
  def start_agent(server, agent_id, opts \\ []),
    do: GenServer.call(server, {:start_agent, agent_id, opts}, call_timeout(opts))

  @doc """
  Stops one agent's worker and cancels its open run.

  Options: `:reason` (default `:operator_stop`) and `:timeout`.
  """
  @spec stop_agent(GenServer.server(), agent_id(), keyword()) ::
          {:ok, agent_summary()} | {:error, term()}
  def stop_agent(server, agent_id, opts \\ []),
    do: GenServer.call(server, {:stop_agent, agent_id, opts}, call_timeout(opts))

  @doc """
  Sends a user message to a running agent.

  If the model loop is waiting for input the agent wakes immediately. If a
  provider turn or tool call is in flight, the message is queued for the next
  turn (steering).
  """
  @spec send_message(GenServer.server(), agent_id(), binary(), keyword()) ::
          {:ok, agent_summary()} | {:error, term()}
  def send_message(server, agent_id, content, opts \\ []),
    do: GenServer.call(server, {:send_message, agent_id, content, opts}, call_timeout(opts))

  @doc "Alias for `send_message/4`."
  @spec steer(GenServer.server(), agent_id(), binary(), keyword()) ::
          {:ok, agent_summary()} | {:error, term()}
  def steer(server, agent_id, content, opts \\ []),
    do: send_message(server, agent_id, content, opts)

  @doc "Returns the current in-memory provider messages for one agent."
  @spec messages(GenServer.server(), agent_id()) :: {:ok, [Message.t()]} | {:error, term()}
  def messages(server, agent_id), do: GenServer.call(server, {:messages, agent_id})

  @doc """
  Waits until an agent is waiting for input or has reached a terminal state.

  This polls the runtime rather than blocking it. Returns `{:error, :timeout}`
  when the deadline passes.
  """
  @spec await_agent(GenServer.server(), agent_id(), timeout()) ::
          {:ok, agent_summary()} | {:error, :timeout | term()}
  def await_agent(server, agent_id, timeout \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_agent(server, agent_id, deadline)
  end

  @doc "Alias for `await_agent/3`."
  @spec wait_agent(GenServer.server(), agent_id(), timeout()) ::
          {:ok, agent_summary()} | {:error, :timeout | term()}
  def wait_agent(server, agent_id, timeout \\ 30_000),
    do: await_agent(server, agent_id, timeout)

  @doc "Returns the current runner activity for one agent."
  @spec activity(GenServer.server(), agent_id()) :: {:ok, map()} | {:error, term()}
  def activity(server, agent_id), do: GenServer.call(server, {:activity, agent_id})

  @doc """
  Compacts the current context of a running agent now.

  The full old context is archived before replacement. The run's context
  revision is folded and a durable `:context_compacted` event is emitted.
  Without a configured compaction policy the target defaults to half of the
  current estimate. Options: `:target`, `:threshold`, and `:timeout`.
  """
  @spec compact_agent(GenServer.server(), agent_id(), keyword()) ::
          {:ok, agent_summary()} | :unchanged | {:error, term()}
  def compact_agent(server, agent_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_await_timeout)
    GenServer.call(server, {:compact_agent, agent_id, opts}, timeout + 5_000)
  end

  @doc false
  def runner_compact(server, agent_id),
    do: GenServer.call(server, {:runner_compact, agent_id}, 60_000)

  @doc false
  def runner_model_delta(server, agent_id, text),
    do: GenServer.call(server, {:runner_model_delta, agent_id, text}, 30_000)

  @doc false
  def runner_context(server, agent_id),
    do: GenServer.call(server, {:runner_context, agent_id}, 30_000)

  @doc false
  def runner_record_model(server, agent_id, response),
    do: GenServer.call(server, {:runner_record_model, agent_id, response}, 30_000)

  @doc false
  def runner_tool_message(server, agent_id, call, output),
    do: GenServer.call(server, {:runner_tool_message, agent_id, call, output}, 30_000)

  @doc false
  def runner_tool_result(server, agent_id, call, status, output),
    do: GenServer.call(server, {:runner_tool_result, agent_id, call, status, output}, 30_000)

  @doc false
  def runner_complete(server, agent_id, call, results),
    do: GenServer.call(server, {:runner_complete, agent_id, call, results}, 30_000)

  @doc false
  def runner_fail(server, agent_id, call, reason),
    do: GenServer.call(server, {:runner_fail, agent_id, call, reason}, 30_000)

  @doc false
  def runner_wait(server, agent_id),
    do: GenServer.call(server, {:runner_wait, agent_id}, 30_000)

  @doc false
  def runner_provider_error(server, agent_id, error),
    do: GenServer.call(server, {:runner_provider_error, agent_id, error}, 30_000)

  @doc """
  Executes one declared tool for the agent.

  Fixed operations run through the agent's worker. Native tools, declared by a
  toolkit manifest that names a registered native toolkit, run in the runtime
  and receive the fixed variable context. When the same tool name appears in
  more than one toolkit, the first declaration wins.

  The manager does not expose its per-call transcript id, so the tool-history
  `call_id` and `transcript_event_id` fields carry the durable runtime
  `:tool_call` event id instead.

  Options are `:timeout` and `:tool_call_id`, the latter recorded on the
  `:tool_call` and `:tool_result` events when the operation came from a model
  tool call.

  If the tool runs but its history record cannot be appended, the call returns
  `{:error, {:tool_history_write_failed, reason}}`.
  """
  @spec execute_tool(GenServer.server(), agent_id(), binary(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute_tool(server, agent_id, tool_name, arguments, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_execute_timeout)
    opts = Keyword.put(opts, :timeout, timeout)

    GenServer.call(
      server,
      {:execute_tool, agent_id, tool_name, arguments, opts},
      timeout + 5_000
    )
  end

  @doc "Subscribes `pid` to durable events emitted by this runtime."
  @spec subscribe(GenServer.server(), pid()) :: :ok | {:error, term()}
  def subscribe(server, pid \\ self()), do: GenServer.call(server, {:subscribe, pid})

  @doc "Removes a previous subscription."
  @spec unsubscribe(GenServer.server(), pid()) :: :ok
  def unsubscribe(server, pid \\ self()), do: GenServer.call(server, {:unsubscribe, pid})

  @doc "Reads the durable event file for one agent."
  @spec list_events(GenServer.server(), agent_id()) ::
          {:ok, [Event.t()]} | {:incomplete, [Event.t()], binary()} | {:error, term()}
  def list_events(server, agent_id), do: GenServer.call(server, {:list_events, agent_id})

  @doc "Reads the durable tool-history file for one agent."
  @spec tool_history(GenServer.server(), agent_id()) ::
          {:ok, [ToolHistory.t()]}
          | {:incomplete, [ToolHistory.t()], binary()}
          | {:error, term()}
  def tool_history(server, agent_id), do: GenServer.call(server, {:tool_history, agent_id})

  @doc "Returns the manager-owned transcript path for an agent's worker."
  @spec transcript_path(GenServer.server(), agent_id()) :: {:ok, Path.t()} | {:error, term()}
  def transcript_path(server, agent_id),
    do: GenServer.call(server, {:transcript_path, agent_id})

  @doc """
  Lists an agent's published artifacts, newest first.

  Artifacts are copied out of the agent's workspace when a run submits its
  `file` results, before the workspace can be torn down. They are
  manager-owned under `<state_dir>/artifacts/<agent-id>/`.
  """
  @spec list_artifacts(GenServer.server(), agent_id()) ::
          {:ok, [ArtifactStore.artifact()]} | {:error, term()}
  def list_artifacts(server, agent_id),
    do: GenServer.call(server, {:list_artifacts, agent_id})

  @doc """
  Resolves one published artifact for serving.

  Returns the artifact's size, content type, disposition, and absolute
  manager-owned path. Access control is the caller's job; the UI route behind
  `PATCHBAY_UI_TOKEN` is the intended caller.
  """
  @spec artifact(GenServer.server(), agent_id(), binary()) ::
          {:ok, ArtifactStore.artifact() | map()} | {:error, term()}
  def artifact(server, agent_id, name), do: GenServer.call(server, {:artifact, agent_id, name})

  @max_artifact_name_bytes 255

  @impl true
  def init(opts) do
    config =
      Config.load(
        Keyword.take(opts, [
          :home,
          :config_dir,
          :state_dir,
          :runtime_dir,
          :secrets_dir,
          :workspace_dir,
          :result_dir,
          :env
        ])
      )

    state_dir = config.state_dir

    with {:ok, definitions} <- resolve_definitions(opts),
         :ok <- ensure_dirs(state_dir) do
      base = %{
        manager: Keyword.get(opts, :manager),
        worker_client: Keyword.get(opts, :worker_client, Patchbay.Runtime.CLIManagerClient),
        provider: Keyword.get(opts, :provider),
        provider_opts: Keyword.get(opts, :provider_opts, []),
        definitions: definitions,
        state_dir: state_dir,
        runtime_dir: config.runtime_dir,
        secrets_dir: Keyword.get(opts, :secrets_dir) || config.secrets_dir,
        workspace_dir: Keyword.get(opts, :workspace) || config.workspace_dir,
        result_dir: config.result_dir,
        hook_timeout: Keyword.get(opts, :hook_timeout, @default_hook_timeout),
        max_artifact_bytes:
          Keyword.get(opts, :max_artifact_bytes, ArtifactStore.default_max_artifact_bytes()),
        agents: %{},
        event_sequences: %{},
        tool_sequences: %{},
        compactions: %{},
        context_ready: MapSet.new(),
        secret_values: %{},
        subscribers: %{}
      }

      {:ok, refresh(base)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:list_agents, _from, state) do
    state = refresh(state)

    summaries =
      state.agents
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&summarize/1)

    {:reply, {:ok, summaries}, state}
  end

  def handle_call({:get_agent, agent_id}, _from, state) do
    state = refresh(state)

    case Map.fetch(state.agents, agent_id) do
      {:ok, agent} ->
        summary = agent |> summarize() |> Map.put(:definition, agent.definition)
        {:reply, {:ok, summary}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:start_agent, agent_id, opts}, _from, state) do
    state = refresh(state)

    case do_start(state, agent_id, opts) do
      {:ok, summary, state} -> {:reply, {:ok, summary}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop_agent, agent_id, opts}, from, state) do
    state = refresh(state)

    case Map.fetch(state.agents, agent_id) do
      {:ok, agent} ->
        if publishing?(agent) do
          # The worker must outlive the artifact copy; acknowledge the stop
          # when publication completes instead of killing the source. A
          # second attempt takes the spot, and the first caller is told the
          # stop is already underway.
          reason = Keyword.get(opts, :reason, :operator_stop)

          case agent.stop_waiter do
            {previous, _reason} -> GenServer.reply(previous, {:error, :stopping})
            nil -> :ok
          end

          agent = %{agent | status: :stopping, stop_waiter: {from, reason}}
          {:noreply, put_agent(state, agent)}
        else
          case do_stop(state, agent_id, opts) do
            {:ok, summary, state} -> {:reply, {:ok, summary}, state}
            {:error, reason, state} -> {:reply, {:error, reason}, state}
          end
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:send_message, agent_id, content, _opts}, _from, state) do
    case do_send_message(state, agent_id, content) do
      {:ok, summary, state} -> {:reply, {:ok, summary}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:messages, agent_id}, _from, state) do
    case Map.fetch(state.agents, agent_id) do
      {:ok, agent} -> {:reply, {:ok, agent.messages}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:activity, agent_id}, _from, state) do
    case Map.fetch(state.agents, agent_id) do
      {:ok, agent} ->
        run = lifecycle_run(agent)

        {:reply,
         {:ok,
          %{
            agent_id: agent.id,
            status: agent.status,
            activity: agent.activity,
            run_status: run && run.status,
            pending_messages: agent.pending_user,
            message_count: length(agent.messages)
          }}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:runner_context, agent_id}, _from, state) do
    case runner_agent(state, agent_id) do
      {:ok, agent} ->
        agent = %{agent | pending_user: 0}

        request = %Request{
          model: model_name(agent.definition),
          messages: agent.messages,
          tools: AgentRunner.tools(agent.definition),
          tool_choice: :auto
        }

        context = %{
          request: request,
          provider: state.provider,
          provider_opts: state.provider_opts,
          definition: agent.definition
        }

        {:reply, {:ok, context}, put_agent(state, agent)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:runner_record_model, agent_id, %Response{} = response}, _from, state) do
    with {:ok, agent} <- runner_agent(state, agent_id) do
      calls = normalize_tool_calls(response.tool_calls || [])
      message = Message.assistant(response.content, tool_calls: calls)

      agent = %{
        agent
        | messages: agent.messages ++ [message],
          stream_text: nil,
          activity: if(calls == [], do: :thinking, else: :executing_tool)
      }

      state = put_agent(state, agent)
      state = record_context_message(state, agent, message)

      state =
        emit(
          state,
          agent.id,
          :model_message,
          run_attrs(lifecycle_run(agent), active_attempt(agent), %{
            content: response.content,
            finish_reason: response.finish_reason,
            tool_call_count: length(calls)
          })
        )

      state =
        Enum.reduce(calls, state, fn call, state ->
          emit(
            state,
            agent.id,
            :model_tool_call,
            run_attrs(lifecycle_run(agent), active_attempt(agent), %{
              tool_call_id: call.id,
              tool_name: call.name,
              arguments: call.arguments
            })
          )
        end)

      state = record_in_flight_calls(state, agent, calls)
      {:reply, {:ok, calls}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:runner_tool_message, agent_id, call, output}, _from, state) do
    with {:ok, agent} <- runner_agent(state, agent_id) do
      output = Redact.redact(output, agent_secret_values(state, agent_id))
      {agent, message} = append_tool_message(agent, call, output)
      agent = %{agent | activity: :thinking}
      state = put_agent(state, agent)
      state = record_context_message(state, agent, message)
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:runner_tool_result, agent_id, call, status, output}, _from, state) do
    with {:ok, agent} <- runner_agent(state, agent_id) do
      output = Redact.redact(output, agent_secret_values(state, agent_id))
      {agent, message} = append_tool_message(agent, call, output)
      agent = %{agent | activity: :thinking}
      state = put_agent(state, agent)
      state = record_context_message(state, agent, message)

      state =
        emit(
          state,
          agent.id,
          :tool_result,
          run_attrs(lifecycle_run(agent), active_attempt(agent), %{
            tool_name: call.name,
            tool_call_id: call.id,
            status: status,
            result: output
          })
        )

      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:runner_complete, agent_id, call, results}, _from, state) do
    with {:ok, agent} <- runner_agent(state, agent_id) do
      results = Redact.redact(results, agent_secret_values(state, agent_id))
      {agent, message} = append_tool_message(agent, call, terminal_output("completed", results))
      state = put_agent(state, agent)
      state = record_context_message(state, agent, message)

      state =
        emit(
          state,
          agent.id,
          :tool_result,
          run_attrs(lifecycle_run(agent), active_attempt(agent), %{
            tool_name: call.name,
            tool_call_id: call.id,
            status: "ok",
            result: terminal_output("completed", results),
            builtin: true
          })
        )

      case publication_jobs(agent, results) do
        [] ->
          {:reply, :ok, complete_run(state, agent, results, [])}

        jobs ->
          # The copy runs outside the call so the runner cannot block on it;
          # the terminal transition happens once, when the copy finishes.
          run_id = agent.lifecycle && lifecycle_run(agent) && lifecycle_run(agent).id
          {:reply, :ok, start_publication(state, agent, results, run_id, jobs)}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:runner_fail, agent_id, call, reason}, _from, state) do
    with {:ok, agent} <- runner_agent(state, agent_id) do
      reason = Redact.redact(reason, agent_secret_values(state, agent_id))
      output = terminal_output("failed", reason)
      {agent, message} = append_tool_message(agent, call, output)
      state = put_agent(state, agent)
      state = record_context_message(state, agent, message)

      state =
        emit(
          state,
          agent.id,
          :tool_result,
          run_attrs(lifecycle_run(agent), active_attempt(agent), %{
            tool_name: call.name,
            tool_call_id: call.id,
            status: "ok",
            result: output,
            builtin: true
          })
        )

      {:reply, :ok, fail_run(state, agent, reason)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:runner_wait, agent_id}, _from, state) do
    with {:ok, agent} <- runner_agent(state, agent_id) do
      if agent.pending_user > 0 do
        {:reply, {:ok, :continue}, put_agent(state, %{agent | activity: :thinking})}
      else
        lifecycle = wait_lifecycle(agent.lifecycle)
        agent = %{agent | lifecycle: lifecycle, activity: :waiting, stream_text: nil}
        state = put_agent(state, agent)

        state =
          emit(
            state,
            agent.id,
            :agent_waiting,
            run_attrs(lifecycle_run(agent), active_attempt(agent), %{reason: "awaiting_input"})
          )

        {:reply, {:ok, :wait}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:runner_provider_error, agent_id, error}, _from, state) do
    with {:ok, agent} <- runner_agent(state, agent_id) do
      agent = %{agent | stream_text: nil}
      state = put_agent(state, agent)
      reason = {:provider_error, error.kind, error.message}

      state =
        emit(
          state,
          agent.id,
          :provider_error,
          run_attrs(lifecycle_run(agent), active_attempt(agent), %{
            kind: error.kind,
            message: error.message,
            status: error.status,
            retryable: error.retryable
          })
        )

      {:reply, :ok, fail_run(state, agent, reason)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:runner_model_delta, agent_id, text}, _from, state) do
    with {:ok, agent} <- runner_agent(state, agent_id) do
      text = if is_binary(text), do: text, else: ""
      accumulated = (agent.stream_text || "") <> text
      agent = %{agent | stream_text: accumulated, activity: :thinking}
      state = put_agent(state, agent)
      publish_delta(state, agent, text)
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:runner_compact, agent_id}, from, state) do
    start_compaction(state, agent_id, :maybe, from)
  end

  def handle_call({:compact_agent, agent_id, opts}, from, state) do
    start_compaction(state, agent_id, {:manual, opts}, from)
  end

  def handle_call({:execute_tool, agent_id, tool_name, arguments, opts}, _from, state) do
    state = refresh(state)

    case do_execute_tool(state, agent_id, tool_name, arguments, opts) do
      {:executed, result, state} -> {:reply, result, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:subscribe, pid}, _from, state) when is_pid(pid) do
    if Map.has_key?(state.subscribers, pid) do
      {:reply, :ok, state}
    else
      monitor = Process.monitor(pid)
      {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, pid, monitor)}}
    end
  end

  def handle_call({:subscribe, _pid}, _from, state), do: {:reply, {:error, :invalid_pid}, state}

  def handle_call({:unsubscribe, pid}, _from, state) when is_pid(pid) do
    {monitor, subscribers} = Map.pop(state.subscribers, pid)
    if monitor, do: Process.demonitor(monitor, [:flush])
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call({:list_events, agent_id}, _from, state) do
    case event_path(state, agent_id) do
      {:ok, path} -> {:reply, Event.read(path), state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:tool_history, agent_id}, _from, state) do
    case tool_history_path(state, agent_id) do
      {:ok, path} -> {:reply, read_tool_history(path), state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:transcript_path, agent_id}, _from, state) do
    reply =
      cond do
        is_nil(state.manager) ->
          {:error, :manager_unavailable}

        not Event.valid_agent_id?(agent_id) ->
          {:error, {:invalid_agent_id, agent_id}}

        true ->
          worker_id =
            case Map.fetch(state.agents, agent_id) do
              {:ok, %{worker_id: worker_id}} when is_binary(worker_id) -> {:ok, worker_id}
              _ -> worker_id_for(agent_id)
            end

          case worker_id do
            {:ok, worker_id} ->
              safe_worker_call(fn ->
                case state.worker_client.transcript_path(state.manager, worker_id) do
                  path when is_binary(path) -> {:ok, path}
                  other -> {:error, {:invalid_transcript_path, other}}
                end
              end)

            {:error, reason} ->
              {:error, reason}
          end
      end

    {:reply, reply, state}
  end

  def handle_call({:list_artifacts, agent_id}, _from, state) do
    state = refresh(state)

    reply =
      with {:ok, _agent} <- fetch_agent(state, agent_id),
           {:ok, artifacts} <- ArtifactStore.list(state.state_dir, agent_id) do
        {:ok, artifacts}
      else
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:artifact, agent_id, name}, _from, state) do
    reply =
      with {:ok, _agent} <- fetch_agent(state, agent_id),
           true <- is_binary(name) and byte_size(name) <= @max_artifact_name_bytes,
           {:ok, artifact} <- ArtifactStore.resolve(state.state_dir, agent_id, name) do
        {:ok, artifact}
      else
        false -> {:error, {:invalid_artifact_name, name}}
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({:compaction_prepared, agent_id, generation, result}, state) do
    case Map.fetch(state.compactions, agent_id) do
      {:ok, %{generation: ^generation, monitor: monitor} = entry} ->
        Process.demonitor(monitor, [:flush])
        state = %{state | compactions: Map.delete(state.compactions, agent_id)}
        {reply, state} = finish_compaction(state, agent_id, generation, result)
        reply_waiters(entry.waiters, reply)
        {:noreply, state}

      :error ->
        discard_plan(result)
        {:noreply, state}

      {:ok, _entry} ->
        discard_plan(result)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, pid, reason}, state) do
    case compaction_for_monitor(state, monitor, pid) do
      {:ok, agent_id, entry} ->
        state = %{state | compactions: Map.delete(state.compactions, agent_id)}
        reply_waiters(entry.waiters, {:error, {:compaction_failed, reason}})
        {:noreply, state}

      :error ->
        handle_process_down(state, monitor, pid, reason)
    end
  end

  def handle_info({:artifact_publication_done, agent_id, pid, outcomes}, state) do
    case Map.fetch(state.agents, agent_id) do
      {:ok, %{publisher: %{pid: ^pid} = publisher} = agent} ->
        Process.demonitor(publisher.monitor, [:flush])
        {:noreply, finish_publication(state, agent, publisher, outcomes)}

      _other ->
        # Stale completion from a publication the runtime already abandoned.
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_process_down(state, monitor, pid, reason) do
    case publication_for_monitor(state, monitor, pid) do
      {:ok, _agent_id, agent, publisher} ->
        # The copy process died; the run still reaches a terminal state so
        # waiters are not stranded, with the loss reported per result.
        outcomes = failed_publication_outcomes(publisher, reason)
        {:noreply, finish_publication(state, agent, publisher, outcomes)}

      :error ->
        case runner_for_monitor(state, monitor, pid) do
          {:ok, agent_id} ->
            {:noreply, handle_runner_down(state, agent_id, reason)}

          :error ->
            case Map.fetch(state.subscribers, pid) do
              {:ok, ^monitor} ->
                {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

              _other ->
                {:noreply, state}
            end
        end
    end
  end

  defp publication_for_monitor(state, monitor, pid) do
    Enum.find_value(state.agents, :error, fn {_agent_id, agent} ->
      case agent.publisher do
        %{pid: ^pid, monitor: ^monitor} = publisher -> {:ok, agent.id, agent, publisher}
        _other -> nil
      end
    end)
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.compactions, fn {_agent_id, entry} ->
      if is_pid(entry.pid) and Process.alive?(entry.pid) do
        Process.exit(entry.pid, :kill)
      end
    end)

    Enum.each(state.agents, fn {_agent_id, agent} ->
      terminate_runner(agent)
      terminate_publisher(agent)
    end)

    :ok
  end

  defp terminate_publisher(agent) do
    case agent.publisher do
      %{pid: pid, monitor: monitor} ->
        Process.demonitor(monitor, [:flush])

        if is_pid(pid) and Process.alive?(pid) do
          Process.exit(pid, :kill)
        end

        :ok

      _other ->
        :ok
    end
  end

  defp terminate_runner(agent) do
    if is_reference(agent.runner_monitor) do
      Process.demonitor(agent.runner_monitor, [:flush])
    end

    if is_pid(agent.runner_pid) and Process.alive?(agent.runner_pid) do
      Process.exit(agent.runner_pid, :kill)
    end

    :ok
  end

  defp do_start(state, agent_id, opts) do
    with {:ok, agent} <- fetch_agent(state, agent_id),
         :ok <- ensure_startable(agent),
         {:ok, definition, source_revision, source_fingerprint} <-
           fetch_definition(state, agent_id, agent),
         :ok <- ensure_runner_configured(state, definition),
         {:ok, operations} <- resolved_operations(definition),
         {:ok, secret_values} <- resolve_secret_env(state, definition),
         {:ok, worker_id} <- worker_id_for(agent_id),
         {:ok, dirs} <- ensure_agent_dirs(state, agent_id, definition) do
      {revision, fingerprint} =
        next_revision(agent, definition, source_revision, source_fingerprint)

      {:ok, lifecycle} = new_or_existing_lifecycle(agent, agent_id, definition)

      recovery = Lifecycle.recovery(lifecycle)
      now = now()

      attrs = %{
        id: unique_id("run"),
        attempt_id: unique_id("attempt"),
        instance_id: unique_id("instance"),
        started_at: now,
        definition_revision: revision,
        toolkit_ids: toolkit_ids(definition),
        metadata: %{definition_revision: revision}
      }

      case Lifecycle.activate(lifecycle, attrs) do
        {:ok, lifecycle} ->
          run = Lifecycle.current_run(lifecycle)
          attempt = Lifecycle.active_attempt(lifecycle)

          messages =
            AgentRunner.system_messages(definition) ++
              restored_messages(state, agent_id, definition, recovery, run.id)

          agent = %{
            agent
            | definition: definition,
              revision: revision,
              fingerprint: fingerprint,
              lifecycle: lifecycle,
              status: :starting,
              worker_id: worker_id,
              workspace: dirs.workspace,
              result_dir: dirs.result_dir,
              state_dir: dirs.state_dir,
              started_at: now,
              stopped_at: nil,
              last_error: nil,
              messages: messages,
              activity: :idle,
              stream_text: nil,
              pending_user: 0,
              runner_pid: nil,
              runner_monitor: nil,
              in_flight_tools: MapSet.new(),
              context_generation: next_context_generation(),
              terminal_result: nil,
              terminal_failure: nil,
              finalize_state: nil
          }

          state = put_agent(state, agent)
          state = emit_activation(state, agent, run, attempt, recovery)
          state = record_context_run(state, agent, :started)
          # Remember the values before the worker exists: a failed start still
          # writes an error event and runs finalize hooks, and both must be
          # redacted. fail_start forgets them once it is done.
          state = remember_secret_values(state, agent.id, secret_values)
          finish_start(state, agent, run, attempt, operations, secret_values, opts)

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp start_worker_reconciled(state, agent, timeout, operations, secrets) do
    client = state.worker_client

    opts =
      [timeout: timeout, operations: operations, workspace: agent.workspace]
      |> maybe_put_workspace_disabled(Workspace.enabled?(agent.definition))
      |> maybe_put_result_dir(agent)
      |> maybe_put_packages(agent.definition.environment.packages)
      |> maybe_put_secrets(secrets)

    case safe_worker_call(fn ->
           client.start_worker(state.manager, agent.worker_id, opts)
         end) do
      {:error, :already_started} ->
        _ =
          safe_worker_call(fn ->
            client.stop_worker(state.manager, agent.worker_id, timeout)
          end)

        safe_worker_call(fn ->
          client.start_worker(state.manager, agent.worker_id, opts)
        end)

      other ->
        other
    end
  end

  defp finish_start(state, agent, run, attempt, operations, secret_values, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    await_timeout = Keyword.get(opts, :await_timeout, @default_await_timeout)
    client = state.worker_client

    started = start_worker_reconciled(state, agent, timeout, operations, secret_values)

    case started do
      {:ok, _info} ->
        case safe_worker_call(fn ->
               client.await_worker(state.manager, agent.worker_id, await_timeout)
             end) do
          {:ok, _info} ->
            case Lifecycle.ready(agent.lifecycle, attempt.instance_id) do
              {:ok, lifecycle} ->
                agent = %{agent | lifecycle: lifecycle, status: :running}
                state = put_agent(state, agent)

                case run_hooks(state, agent, :init, run, attempt) do
                  {:ok, state} ->
                    state =
                      state
                      |> emit(agent.id, :instance_ready, run_attrs(run, attempt, %{}))
                      |> emit(
                        agent.id,
                        :agent_started,
                        run_attrs(run, attempt, %{worker_id: agent.worker_id})
                      )

                    state = maybe_seed_message(state, agent, run, attempt, opts)
                    state = start_runner(state, agent)
                    agent = Map.fetch!(state.agents, agent.id)

                    {:ok, summarize(agent), state}

                  {:error, reason, state} ->
                    fail_start(state, agent, run, attempt, :lifecycle_init, reason)
                end

              {:error, reason} ->
                fail_start(state, agent, run, attempt, :instance_ready, reason)
            end

          {:error, reason} ->
            fail_start(state, agent, run, attempt, :worker_ready, reason)
        end

      {:error, reason} ->
        fail_start(state, agent, run, attempt, :worker_start, reason)
    end
  end

  # A failed start still runs finalize hooks and then tears the worker down,
  # in that order: hooks travel the worker protocol, so the worker must exist
  # while they run. The secret values stay in state until both the error
  # record and the finalize hooks are written, so their outputs are redacted;
  # they are forgotten on the way out.
  defp fail_start(state, agent, run, attempt, stage, reason) do
    reason =
      {stage, reason}
      |> Redact.redact(agent_secret_values(state, agent.id))

    lifecycle =
      case Lifecycle.interrupt(agent.lifecycle, reason, now()) do
        {:ok, lifecycle} -> lifecycle
        {:error, _reason} -> agent.lifecycle
      end

    agent = %{agent | lifecycle: lifecycle}
    hook_agent = agent

    agent = %{
      agent
      | status: :failed,
        worker_id: nil,
        last_error: reason
    }

    state =
      state
      |> put_agent(agent)
      |> emit(
        agent.id,
        :agent_start_failed,
        run_attrs(run, attempt, %{stage: stage, reason: reason})
      )

    state = finalize_once(state, hook_agent, run, attempt)
    stop_worker_best_effort(state, hook_agent)
    state = forget_secret_values(state, agent.id)
    state = record_context_run(state, agent, :interrupted)
    {:error, reason, state}
  end

  defp do_stop(state, agent_id, opts) do
    with {:ok, agent} <- fetch_agent(state, agent_id) do
      state = cancel_compaction(state, agent_id)

      cond do
        agent.status == :stopped ->
          state = stop_runner(state, agent)
          state = forget_secret_values(state, agent_id)
          agent = Map.fetch!(state.agents, agent_id)
          {:ok, summarize(agent), state}

        agent.status == :stopping ->
          {:error, :stopping, state}

        true ->
          reason = Keyword.get(opts, :reason, :operator_stop)
          timeout = Keyword.get(opts, :timeout, @default_timeout)

          attempt = active_attempt(agent)

          # Finalize hooks run before the worker is stopped: they execute in
          # the worker that owns the workspace, and the manager cannot reach
          # it once the stop completes. The completed phase is recorded first,
          # so a stop that fails and is retried does not run them twice.
          state = finalize_once(state, agent, lifecycle_run(agent), attempt)
          agent = Map.fetch!(state.agents, agent_id)

          case stop_worker(state, agent, timeout) do
            :ok ->
              state = stop_runner(state, agent)
              state = forget_secret_values(state, agent_id)
              agent = Map.fetch!(state.agents, agent_id)
              lifecycle = stop_lifecycle(agent.lifecycle, reason, now())
              run = lifecycle && Lifecycle.current_run(lifecycle)

              agent = %{
                agent
                | lifecycle: lifecycle,
                  status: :stopped,
                  worker_id: nil,
                  stopped_at: now(),
                  activity: :idle,
                  stream_text: nil,
                  pending_user: 0
              }

              state =
                state
                |> put_agent(agent)

              state =
                emit(
                  state,
                  agent.id,
                  :agent_stopped,
                  run_attrs(run, attempt, %{reason: reason})
                )

              state = record_context_run(state, agent, :cancelled)
              {:ok, summarize(agent), state}

            {:error, stop_reason} ->
              agent = %{agent | last_error: stop_reason}

              state =
                state
                |> put_agent(agent)
                |> emit(
                  agent.id,
                  :agent_stop_failed,
                  run_attrs(lifecycle_run(agent), active_attempt(agent), %{
                    reason: stop_reason
                  })
                )

              {:error, stop_reason, state}
          end
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp do_send_message(state, agent_id, content) do
    with {:ok, agent} <- fetch_agent(state, agent_id),
         :ok <- validate_message(content) do
      cond do
        not runner_enabled?(state) ->
          {:error, :agent_runner_disabled, state}

        agent.status != :running ->
          {:error, {:not_running, agent.status}, state}

        true ->
          message = Message.user(content)

          agent = %{
            agent
            | messages: agent.messages ++ [message],
              pending_user: agent.pending_user + 1
          }

          state = put_agent(state, agent)
          state = record_context_message(state, agent, message)

          state =
            emit(
              state,
              agent.id,
              :user_message,
              run_attrs(lifecycle_run(agent), active_attempt(agent), %{content: content})
            )

          if agent.activity == :waiting do
            agent = %{agent | lifecycle: wake_lifecycle(agent.lifecycle), activity: :thinking}
            state = put_agent(state, agent)

            state =
              emit(
                state,
                agent.id,
                :agent_woken,
                run_attrs(lifecycle_run(agent), active_attempt(agent), %{content: content})
              )

            state = wake_runner(state, agent)
            agent = Map.fetch!(state.agents, agent_id)
            {:ok, summarize(agent), state}
          else
            {:ok, summarize(agent), state}
          end
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp validate_message(content) when is_binary(content) do
    if String.trim(content) == "", do: {:error, :empty_message}, else: :ok
  end

  defp validate_message(content), do: {:error, {:invalid_message, content}}

  defp ensure_runner_configured(%{provider: nil}, _definition), do: :ok

  defp ensure_runner_configured(state, definition) do
    AgentRunner.validate_provider(state.provider, state.provider_opts, definition)
  end

  defp runner_enabled?(state), do: not is_nil(state.provider)

  defp maybe_seed_message(state, agent, run, attempt, opts) do
    content = Keyword.get(opts, :message)

    if runner_enabled?(state) and is_binary(content) and String.trim(content) != "" do
      message = Message.user(content)

      agent = %{
        agent
        | messages: agent.messages ++ [message],
          pending_user: agent.pending_user + 1
      }

      state = put_agent(state, agent)
      state = record_context_message(state, agent, message)

      emit(
        state,
        agent.id,
        :user_message,
        run_attrs(run, attempt, %{content: content})
      )
    else
      state
    end
  end

  defp restored_messages(state, agent_id, definition, recovery, current_run_id) do
    if runner_enabled?(state) and ContextStore.valid_agent_id?(agent_id) do
      entries =
        case ContextStore.read(state.state_dir, agent_id) do
          {:ok, entries} ->
            entries

          {:incomplete, entries, _rest} ->
            entries

          {:error, reason} ->
            Logger.warning("context restore failed for #{inspect(agent_id)}: #{inspect(reason)}")
            []
        end

      {decision, messages} =
        ContextStore.restore(
          entries,
          Map.get(definition, :context),
          lifecycle_kind(definition),
          recovery,
          current_run_id
        )

      if decision == :reset and recovery == :fresh do
        clear_context(state, agent_id)
      end

      messages
    else
      []
    end
  end

  defp clear_context(state, agent_id) do
    case ContextStore.clear(state.state_dir, agent_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("context reset failed for #{inspect(agent_id)}: #{inspect(reason)}")
    end
  end

  defp record_context_message(state, agent, %Message{} = message) do
    case append_context_message(state, agent, message) do
      {:ok, state} -> state
      {:error, _reason, state} -> state
    end
  end

  defp append_context_message(state, %{id: agent_id} = agent, %Message{} = message, opts \\ []) do
    if runner_enabled?(state) and ContextStore.valid_agent_id?(agent_id) do
      message = Redact.redact(message, agent_secret_values(state, agent_id))
      {run_id, attempt_id} = context_ids(agent)
      repair? = not MapSet.member?(state.context_ready, agent_id)
      sync? = Keyword.get(opts, :sync, false)

      case ContextStore.append_message(
             state.state_dir,
             agent_id,
             run_id,
             attempt_id,
             message,
             repair: repair?,
             sync: sync?
           ) do
        :ok ->
          state = %{state | context_ready: MapSet.put(state.context_ready, agent_id)}
          {:ok, bump_context_generation(state, agent_id)}

        {:error, reason} ->
          Logger.warning(
            "context store write failed for #{inspect(agent_id)}: #{inspect(reason)}"
          )

          {:error, reason, state}
      end
    else
      {:ok, state}
    end
  end

  defp record_context_run(state, %{id: agent_id} = agent, status) do
    if runner_enabled?(state) and ContextStore.valid_agent_id?(agent_id) do
      {run_id, _attempt_id} = context_ids(agent)

      if is_binary(run_id) do
        repair? = not MapSet.member?(state.context_ready, agent_id)

        case ContextStore.append_run(state.state_dir, agent_id, run_id, status, repair: repair?) do
          :ok ->
            state = %{state | context_ready: MapSet.put(state.context_ready, agent_id)}
            bump_context_generation(state, agent_id)

          {:error, reason} ->
            Logger.warning(
              "context store write failed for #{inspect(agent_id)}: #{inspect(reason)}"
            )

            state
        end
      else
        state
      end
    else
      state
    end
  end

  defp context_ids(agent) do
    run = lifecycle_run(agent)
    attempt = active_attempt(agent)
    {run && run.id, attempt && attempt.id}
  end

  defp start_runner(state, agent) do
    agent = Map.get(state.agents, agent.id, agent)

    cond do
      not runner_enabled?(state) ->
        state

      agent.status != :running ->
        state

      is_pid(agent.runner_pid) and Process.alive?(agent.runner_pid) ->
        state

      true ->
        server = self()
        agent_id = agent.id
        {pid, monitor} = spawn_monitor(fn -> AgentRunner.run(server, agent_id) end)

        agent = %{
          agent
          | runner_pid: pid,
            runner_monitor: monitor,
            activity: :thinking
        }

        put_agent(state, agent)
    end
  end

  defp stop_runner(state, agent) do
    if is_pid(agent.runner_pid) or is_reference(agent.runner_monitor) do
      if is_reference(agent.runner_monitor) do
        Process.demonitor(agent.runner_monitor, [:flush])
      end

      if is_pid(agent.runner_pid) and Process.alive?(agent.runner_pid) do
        Process.exit(agent.runner_pid, :kill)
      end

      put_agent(state, %{agent | runner_pid: nil, runner_monitor: nil, activity: :idle})
    else
      state
    end
  end

  defp wake_runner(state, agent) do
    if is_pid(agent.runner_pid) and Process.alive?(agent.runner_pid) do
      send(agent.runner_pid, {:patchbay_runner_wake, agent.id})
      state
    else
      start_runner(state, agent)
    end
  end

  defp publishing?(%{publisher: nil}), do: false
  defp publishing?(%{publisher: _publisher}), do: true

  # Copies the run's file results in a supervised-but-detached process: the
  # reads and writes never run inside a runtime call, and the worker is kept
  # alive until the copy is done, because the agent-owned source disappears
  # with it. The runtime reports completion through
  # `{:artifact_publication_done, ...}`, preserving job order.
  defp start_publication(state, agent, results, run_id, jobs) do
    server = self()
    agent_id = agent.id
    deadline = System.monotonic_time(:millisecond) + @artifact_publication_timeout

    {pid, monitor} =
      spawn_monitor(fn ->
        outcomes = publication_outcomes(state, agent, jobs, run_id, deadline)
        send(server, {:artifact_publication_done, agent_id, self(), outcomes})
      end)

    agent = %{
      agent
      | status: :stopping,
        activity: :publishing,
        publisher: %{pid: pid, monitor: monitor, jobs: jobs, results: results}
    }

    put_agent(state, agent)
  end

  defp finish_publication(state, agent, publisher, outcomes) do
    case agent.stop_waiter do
      {from, reason} ->
        state = finish_publication_stopped(state, agent, publisher, outcomes, reason)
        agent = Map.fetch!(state.agents, agent.id)
        GenServer.reply(from, {:ok, summarize(agent)})
        state

      nil ->
        agent = %{agent | publisher: nil, stop_waiter: nil, status: :running, activity: :idle}
        complete_run(state, agent, publisher.results, outcomes)
    end
  end

  # An operator stop requested while publication is in flight still lets the
  # copy finish, then ends the run as cancelled. The publication events stay,
  # but no run_completed is written: the run's terminal lifecycle is the stop.
  defp finish_publication_stopped(state, agent, _publisher, outcomes, reason) do
    attempt = active_attempt(agent)
    run = lifecycle_run(agent)
    agent = %{agent | publisher: nil, stop_waiter: nil, status: :running, activity: :idle}
    state = emit_publication_outcomes(state, agent, run, attempt, outcomes)
    # Finalize hooks run before the worker is stopped; see do_stop.
    state = finalize_once(state, agent, run, attempt)
    stop_worker_best_effort(state, agent)
    state = forget_secret_values(state, agent.id)

    lifecycle = stop_lifecycle(agent.lifecycle, reason, now())
    run = lifecycle && Lifecycle.current_run(lifecycle)

    agent = %{
      agent
      | lifecycle: lifecycle,
        publisher: nil,
        stop_waiter: nil,
        status: :stopped,
        activity: :idle,
        stream_text: nil,
        pending_user: 0,
        worker_id: nil,
        stopped_at: now(),
        last_error: nil,
        terminal_result: nil
    }

    state = put_agent(state, agent)

    state =
      emit(
        state,
        agent.id,
        :agent_stopped,
        run_attrs(run, attempt, %{reason: reason})
      )

    record_context_run(state, agent, :cancelled)
  end

  defp runner_agent(state, agent_id) do
    case Map.fetch(state.agents, agent_id) do
      {:ok, %{status: :running} = agent} -> {:ok, agent}
      {:ok, agent} -> {:error, {:not_running, agent.status}}
      :error -> {:error, :not_found}
    end
  end

  defp runner_for_monitor(state, monitor, pid) do
    Enum.find_value(state.agents, :error, fn {agent_id, agent} ->
      if agent.runner_monitor == monitor and agent.runner_pid == pid do
        {:ok, agent_id}
      end
    end)
  end

  defp handle_runner_down(state, agent_id, reason) do
    case Map.fetch(state.agents, agent_id) do
      {:ok, agent} ->
        agent = %{agent | runner_pid: nil, runner_monitor: nil}
        state = put_agent(state, agent)

        cond do
          agent.status != :running ->
            state

          reason == :normal and agent.activity in [:waiting, :idle] ->
            state

          true ->
            fail_run(state, agent, {:runner_crashed, reason})
        end

      :error ->
        state
    end
  end

  defp normalize_tool_calls(calls) when is_list(calls) do
    Enum.map(calls, fn
      %ToolCall{id: id} = call when is_binary(id) and id != "" -> call
      %ToolCall{} = call -> %{call | id: unique_id("call")}
      other -> other
    end)
  end

  defp normalize_tool_calls(_calls), do: []

  defp record_in_flight_calls(state, agent, calls) do
    Enum.reduce(calls, state, fn
      %ToolCall{id: id, name: name}, state
      when is_binary(id) and id != "" and is_binary(name) ->
        append_in_flight_message(state, agent_id(agent), id, name)

      _call, state ->
        state
    end)
  end

  defp agent_id(%{id: id}), do: id

  defp append_in_flight_message(state, agent_id, tool_call_id, tool_name) do
    case Map.fetch(state.agents, agent_id) do
      {:ok, agent} ->
        if MapSet.member?(agent.in_flight_tools, tool_call_id) do
          state
        else
          message = Message.tool(tool_call_id, in_flight_output(tool_name), name: tool_name)

          agent = %{
            agent
            | messages: agent.messages ++ [message],
              in_flight_tools: MapSet.put(agent.in_flight_tools, tool_call_id)
          }

          case append_context_message(put_agent(state, agent), agent, message, sync: true) do
            {:ok, state} -> state
            {:error, _reason, state} -> state
          end
        end

      :error ->
        state
    end
  end

  defp record_in_flight_tool(state, agent, tool_name, tool_call_id)
       when is_binary(tool_call_id) and tool_call_id != "" do
    cond do
      MapSet.member?(agent.in_flight_tools, tool_call_id) ->
        {:ok, state, agent}

      true ->
        record_in_flight_tool_message(state, agent, tool_name, tool_call_id)
    end
  end

  defp record_in_flight_tool(state, agent, _tool_name, _tool_call_id),
    do: {:ok, state, agent}

  defp record_in_flight_tool_message(state, agent, tool_name, tool_call_id) do
    if runner_enabled?(state) and ContextStore.valid_agent_id?(agent.id) do
      message = Message.tool(tool_call_id, in_flight_output(tool_name), name: tool_name)

      agent = %{
        agent
        | messages: agent.messages ++ [message],
          in_flight_tools: MapSet.put(agent.in_flight_tools, tool_call_id)
      }

      case append_context_message(put_agent(state, agent), agent, message, sync: true) do
        {:ok, state} -> {:ok, state, agent}
        {:error, reason, state} -> {:error, reason, state}
      end
    else
      {:ok, state, agent}
    end
  end

  defp in_flight_output(tool_name) do
    terminal_output("in_flight", %{
      "tool_name" => tool_name,
      "warning" => "the tool may have run; its outcome is unknown"
    })
  end

  defp append_tool_message(agent, call, output) do
    id = if is_binary(call.id) and call.id != "", do: call.id, else: unique_id("call")
    content = if is_binary(output), do: output, else: inspect(output)
    message = Message.tool(id, content, name: call.name)
    in_flight = Map.get(agent, :in_flight_tools, MapSet.new())

    if MapSet.member?(in_flight, id) do
      messages =
        Enum.map(agent.messages, fn
          %Message{role: :tool, tool_call_id: ^id} -> message
          other -> other
        end)

      {%{
         agent
         | messages: messages,
           in_flight_tools: MapSet.delete(in_flight, id)
       }, message}
    else
      {%{agent | messages: agent.messages ++ [message]}, message}
    end
  end

  defp terminal_output(status, value) do
    case Patchbay.Provider.JSON.encode(%{"status" => status, "value" => value}) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> inspect(value, limit: 20, printable_limit: 4096)
    end
  end

  # Publication runs outside this GenServer: a multi-chunk copy can spend
  # minutes of bounded worker RPCs, and the central runtime must keep
  # serving other agents' calls while it proceeds. The job list preserves
  # the definition's declaration order, and the outcomes come back in that
  # same order so the terminal events read in sequence.
  defp publication_jobs(agent, results) when is_map(results) do
    agent.definition
    |> Map.get(:results, [])
    |> Enum.flat_map(fn result ->
      if Map.get(result, :form) == :file do
        case Map.get(results, result.id) do
          value when is_binary(value) and value != "" -> [{result, value}]
          _other -> []
        end
      else
        []
      end
    end)
  end

  defp publication_jobs(_agent, _results), do: []

  defp publication_outcomes(state, agent, jobs, run_id, deadline) do
    Enum.map(jobs, fn {result, value} ->
      try do
        case publish_artifact(state, agent, result, value, run_id, deadline) do
          {:ok, published} ->
            {:ok, %{result: result.id, name: published.name, size: published.size, source: value}}

          {:error, reason} ->
            {:error, %{result: result.id, reason: reason, source: value}}
        end
      catch
        kind, reason -> {:error, %{result: result.id, reason: {kind, reason}, source: value}}
      end
    end)
  end

  defp failed_publication_outcomes(publisher, reason) do
    Enum.map(publisher.jobs, fn {result, value} ->
      {:error, %{result: result.id, reason: {:publication_crashed, reason}, source: value}}
    end)
  end

  defp emit_publication_outcomes(state, agent, run, attempt, outcomes) do
    Enum.reduce(outcomes, state, fn
      {:ok, published}, state ->
        emit(state, agent.id, :artifact_published, run_attrs(run, attempt, published))

      {:error, failed}, state ->
        emit(state, agent.id, :artifact_publish_failed, run_attrs(run, attempt, failed))
    end)
  end

  # A failed capture stays visible in the terminal result instead of hiding
  # behind a success: the run completes, but the failing result's value says
  # so.
  defp apply_result_warnings(results, outcomes) when is_map(results) do
    Enum.reduce(outcomes, results, fn
      {:error, %{result: id, reason: reason, source: source}}, acc ->
        Map.put(
          acc,
          id,
          "artifact publish failed: " <> inspect(reason) <> " (source: " <> source <> ")"
        )

      _other, acc ->
        acc
    end)
  end

  defp apply_result_warnings(results, _outcomes), do: results

  defp publish_artifact(state, agent, result, value, run_id, deadline) do
    with :ok <- validate_artifact_path(value),
         {:ok, ext} <- ArtifactStore.lint_source(value, Map.get(result, :extensions, [])),
         {:ok, source} <- artifact_source(state, agent, value),
         {:ok, bytes} <- artifact_bytes(state, agent, source, deadline),
         name =
           ArtifactStore.public_name(
             [result.id, Path.basename(Path.rootname(source.path))],
             run_id,
             ext
           ),
         {:ok, published} <- ArtifactStore.write(state.state_dir, agent.id, name, bytes) do
      {:ok, published}
    end
  end

  defp validate_artifact_path(value) do
    cond do
      String.contains?(value, <<0>>) -> {:error, :invalid_artifact_path}
      Path.basename(value) in ["", ".", ".."] -> {:error, :invalid_artifact_path}
      true -> :ok
    end
  end

  # The manager never canonicalizes or stats a source path inside the
  # agent-owned workspace: those dirs belong to the agent user, so traversing
  # them can fail with EACCES on a cross-UID deployment. Confinement of the
  # read itself is enforced worker-side (`Patchbay.Worker.Artifacts` resolves
  # symlinks and refuses anything outside its roots); the manager only makes
  # the lexical decision of which root was named.
  defp artifact_source(state, agent, value) do
    workspace = agent_workspace(state, agent)
    result_dir = agent_result_dir(state, agent)

    absolute =
      if Path.type(value) == :absolute,
        do: Path.expand(value),
        else: Path.expand(value, workspace || ".")

    cond do
      inside_root?(workspace, absolute) ->
        {:ok, %{root: "workspace", path: absolute, relative: relative_under(workspace, absolute)}}

      inside_root?(result_dir, absolute) ->
        {:ok, %{root: "result", path: absolute, relative: relative_under(result_dir, absolute)}}

      true ->
        {:error, {:artifact_path_outside_workspace, value}}
    end
  end

  defp inside_root?(base, path) when is_binary(base),
    do: String.starts_with?(path, Path.expand(base) <> "/")

  defp inside_root?(_base, _path), do: false

  defp relative_under(base, path),
    do: String.replace_prefix(path, Path.expand(base) <> "/", "")

  # A worker error other than these means the worker looked at the request
  # and refused it (or failed the read), so the manager must not retry the
  # same path on its own: the worker's confinement answer is the one that
  # counts.
  defp worker_availability_error?(:worker_unavailable), do: true
  defp worker_availability_error?(:unknown_worker), do: true
  defp worker_availability_error?(:worker_exited), do: true

  defp worker_availability_error?({:worker_unavailable, _reason}), do: true
  defp worker_availability_error?({:worker_not_available, _status}), do: true

  defp worker_availability_error?(_other), do: false

  defp artifact_bytes(state, agent, source, deadline) do
    case read_via_worker(state, agent, source, deadline) do
      {:ok, bytes} ->
        {:ok, bytes}

      {:error, reason} ->
        if worker_availability_error?(reason),
          do: read_directly(state, agent, source, reason),
          else: {:error, reason}
    end
  end

  defp read_via_worker(state, agent, source, deadline) do
    requested = source.relative || source.path
    arguments = %{"path" => requested, "root" => source.root}

    with {:ok, worker_id} <- worker_id(agent),
         {:ok, payload} <- read_artifact_chunk(state, worker_id, arguments, 0),
         :ok <- check_artifact_size(state, payload["size"]),
         {:ok, chunk} <- verify_artifact_chunk(payload, 0, payload["size"]) do
      collect_artifact_chunks(
        state,
        worker_id,
        arguments,
        payload["size"],
        chunk,
        byte_size(chunk),
        deadline
      )
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp worker_id(%{worker_id: worker_id}) when is_binary(worker_id), do: {:ok, worker_id}

  defp worker_id(%{worker_id: worker_id}) when is_binary(worker_id), do: {:ok, worker_id}
  defp worker_id(_agent), do: {:error, :worker_unavailable}

  defp check_artifact_size(state, size) do
    if is_integer(size) and size >= 0 and size <= max_artifact_bytes(state) do
      :ok
    else
      {:error, :artifact_too_large}
    end
  end

  # Bound the loop: every chunk must carry the same size, land at the offset
  # that was asked for, and make progress toward the end. A source that
  # shrinks mid-copy, a worker that repeats an offset, or a chunk arriving
  # empty while more bytes are promised each terminate with an error instead
  # of spinning, and the deadline caps the whole transfer no matter how slow
  # the worker is.
  defp collect_artifact_chunks(state, worker_id, arguments, size, bytes, total, deadline) do
    cond do
      total > size ->
        {:error, :artifact_read_mismatch}

      total > max_artifact_bytes(state) ->
        {:error, :artifact_too_large}

      total == size ->
        {:ok, bytes}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :artifact_read_timeout}

      true ->
        case read_artifact_chunk(state, worker_id, arguments, total) do
          {:ok, payload} ->
            case verify_artifact_chunk(payload, total, size) do
              {:ok, chunk} ->
                collect_artifact_chunks(
                  state,
                  worker_id,
                  arguments,
                  size,
                  bytes <> chunk,
                  total + byte_size(chunk),
                  deadline
                )

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp verify_artifact_chunk(payload, offset, size) do
    chunk = payload["chunk"]

    cond do
      payload["size"] != size ->
        {:error, :artifact_read_mismatch}

      payload["offset"] != offset ->
        {:error, :artifact_read_mismatch}

      payload["length"] != byte_size(chunk) ->
        {:error, :artifact_read_mismatch}

      payload["eof"] == true and size > offset + payload["length"] ->
        {:error, :artifact_read_mismatch}

      byte_size(chunk) == 0 and offset < size ->
        {:error, :artifact_read_stalled}

      true ->
        {:ok, chunk}
    end
  end

  defp read_artifact_chunk(state, worker_id, arguments, offset) do
    arguments = Map.merge(arguments, %{"offset" => offset, "length" => @artifact_chunk_bytes})

    result =
      safe_worker_call(fn ->
        state.worker_client.execute(
          state.manager,
          worker_id,
          Patchbay.Worker.Artifacts.read_operation(),
          arguments,
          timeout: @artifact_read_timeout
        )
      end)

    with {:ok, %{status: :ok} = result} <- result,
         {:ok, decoded} <- decode_artifact_chunk(result) do
      {:ok, decoded}
    else
      {:ok, %{status: _other} = result} ->
        {:error, {:worker_read_failed, Map.get(result, :error)}}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :invalid_artifact_chunk}
    end
  end

  defp decode_artifact_chunk(%{output: output}) when is_binary(output) do
    with {:ok, %{"data" => data, "size" => size} = decoded}
         when is_binary(data) and is_integer(size) <-
           Patchbay.Provider.JSON.decode(output),
         {:ok, chunk} <- decode_artifact_data(data) do
      {:ok, Map.put(decoded, "chunk", chunk)}
    else
      _other -> {:error, :invalid_artifact_chunk}
    end
  end

  defp decode_artifact_chunk(_result), do: {:error, :invalid_artifact_chunk}

  defp decode_artifact_data(data) do
    case Base.decode64(data) do
      {:ok, chunk} -> {:ok, chunk}
      :error -> {:error, :invalid_artifact_data}
    end
  end

  # Only reachable when the worker itself is unavailable. A same-UID
  # deployment can still read the file directly, so the manager applies the
  # containment the worker would have. On a cross-UID deployment the
  # canonicalization or the read fails and the result reports the loss.
  defp read_directly(state, agent, source, worker_reason) do
    base =
      if source.root == "result",
        do: agent_result_dir(state, agent),
        else: agent_workspace(state, agent)

    with {:ok, real_base} <- Operations.canonical(base),
         {:ok, real} <- Operations.canonical(source.path),
         :ok <- confine_direct(real_base, real) do
      read_source_file(state, real, worker_reason)
    else
      {:error, reason} -> {:error, {:artifact_read_failed, worker_reason, reason}}
    end
  end

  defp confine_direct(base, path) do
    if path != base and String.starts_with?(path, base <> "/") do
      :ok
    else
      {:error, {:artifact_path_outside_workspace, path}}
    end
  end

  defp read_source_file(state, path, worker_reason) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        if size > max_artifact_bytes(state) do
          {:error, :artifact_too_large}
        else
          case File.read(path) do
            {:ok, bytes} -> {:ok, bytes}
            {:error, reason} -> {:error, {:artifact_read_failed, worker_reason, reason}}
          end
        end

      {:ok, _other_type} ->
        {:error, {:artifact_read_failed, worker_reason, :not_a_regular_file}}

      {:error, reason} ->
        {:error, {:artifact_read_failed, worker_reason, reason}}
    end
  end

  defp max_artifact_bytes(state) do
    Map.get(state, :max_artifact_bytes) || ArtifactStore.default_max_artifact_bytes()
  end

  defp complete_run(state, agent, results, outcomes) do
    attempt = active_attempt(agent)
    run = lifecycle_run(agent)
    state = emit_publication_outcomes(state, agent, run, attempt, outcomes)
    # Finalize hooks run before the worker is stopped; see do_stop.
    state = finalize_once(state, agent, run, attempt)
    stop_worker_best_effort(state, agent)
    state = forget_secret_values(state, agent.id)
    results = apply_result_warnings(results, outcomes)

    lifecycle =
      case agent.lifecycle do
        nil ->
          nil

        lifecycle ->
          case Lifecycle.complete(lifecycle, results, now()) do
            {:ok, lifecycle} -> lifecycle
            {:error, _reason} -> lifecycle
          end
      end

    run = lifecycle && Lifecycle.current_run(lifecycle)

    agent = %{
      agent
      | lifecycle: lifecycle,
        status: :stopped,
        activity: :idle,
        stream_text: nil,
        pending_user: 0,
        worker_id: nil,
        stopped_at: now(),
        last_error: nil,
        terminal_result: results
    }

    state =
      state
      |> put_agent(agent)

    state =
      emit(
        state,
        agent.id,
        :run_completed,
        run_attrs(run, attempt, %{result: results})
      )

    record_context_run(state, agent, :completed)
  end

  defp fail_run(state, agent, reason) do
    attempt = active_attempt(agent)
    # Finalize hooks run before the worker is stopped; see do_stop.
    state = finalize_once(state, agent, lifecycle_run(agent), attempt)
    stop_worker_best_effort(state, agent)
    state = forget_secret_values(state, agent.id)

    lifecycle =
      case agent.lifecycle do
        nil ->
          nil

        lifecycle ->
          case Lifecycle.fail(lifecycle, reason, now()) do
            {:ok, lifecycle} -> lifecycle
            {:error, _reason} -> lifecycle
          end
      end

    run = lifecycle && Lifecycle.current_run(lifecycle)

    agent = %{
      agent
      | lifecycle: lifecycle,
        status: :stopped,
        activity: :idle,
        stream_text: nil,
        pending_user: 0,
        worker_id: nil,
        stopped_at: now(),
        last_error: reason,
        terminal_failure: reason
    }

    state =
      state
      |> put_agent(agent)

    state =
      emit(
        state,
        agent.id,
        :run_failed,
        run_attrs(run, attempt, %{reason: reason})
      )

    record_context_run(state, agent, :failed)
  end

  defp wait_lifecycle(nil), do: nil

  defp wait_lifecycle(lifecycle) do
    case Lifecycle.wait(lifecycle, :awaiting_input) do
      {:ok, lifecycle} -> lifecycle
      {:error, _reason} -> lifecycle
    end
  end

  defp wake_lifecycle(nil), do: nil

  defp wake_lifecycle(lifecycle) do
    case Lifecycle.wake(lifecycle) do
      {:ok, lifecycle} -> lifecycle
      {:error, _reason} -> lifecycle
    end
  end

  defp do_await_agent(server, agent_id, deadline) do
    case get_agent(server, agent_id) do
      {:ok, agent} ->
        # :stopping during a publication is a transition, not a terminal
        # state; keep polling until the terminal record is in.
        awaited? =
          agent.status not in [:running, :stopping] or agent.activity in [:idle, :waiting]

        if awaited? do
          {:ok, agent}
        else
          if System.monotonic_time(:millisecond) >= deadline do
            {:error, :timeout}
          else
            Process.sleep(20)
            do_await_agent(server, agent_id, deadline)
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_execute_tool(state, agent_id, tool_name, arguments, opts) do
    with {:ok, agent} <- fetch_agent(state, agent_id) do
      cond do
        agent.status != :running ->
          {:error, :not_running, state}

        not is_map(arguments) ->
          {:error, {:invalid_arguments, arguments}, state}

        true ->
          case find_tool(agent.definition, tool_name) do
            :error ->
              {:error, {:unknown_tool, tool_name}, state}

            {:ok, declared} ->
              timeout = Keyword.get(opts, :timeout, @default_execute_timeout)
              tool_call_id = Keyword.get(opts, :tool_call_id)
              run = lifecycle_run(agent)
              attempt = Lifecycle.active_attempt(agent.lifecycle)

              {state, call_event} =
                emit_with_event(
                  state,
                  agent.id,
                  :tool_call,
                  run_attrs(run, attempt, %{
                    tool_name: tool_name,
                    toolkit_id: declared.toolkit_id,
                    tool_call_id: tool_call_id,
                    arguments: arguments
                  })
                )

              case record_in_flight_tool(state, agent, tool_name, tool_call_id) do
                {:ok, state, agent} ->
                  result =
                    execute_declared(
                      state,
                      agent,
                      declared,
                      tool_name,
                      arguments,
                      timeout,
                      run,
                      attempt
                    )
                    |> redact_result(state, agent.id)

                  state =
                    emit(
                      state,
                      agent.id,
                      :tool_result,
                      run_attrs(run, attempt, %{
                        tool_name: tool_name,
                        toolkit_id: declared.toolkit_id,
                        tool_call_id: tool_call_id,
                        status: result_status(result),
                        result: result_summary(result, @history_result_bytes),
                        call_event_id: call_event && call_event.id
                      })
                    )

                  case record_tool_history(
                         state,
                         agent,
                         declared,
                         tool_name,
                         arguments,
                         result,
                         call_event && call_event.id
                       ) do
                    {:ok, state} ->
                      {:executed, result, state}

                    {:error, reason, state} ->
                      {:error, {:tool_history_write_failed, reason}, state}
                  end

                {:error, reason, state} ->
                  state =
                    emit(
                      state,
                      agent.id,
                      :tool_result,
                      run_attrs(run, attempt, %{
                        tool_name: tool_name,
                        toolkit_id: declared.toolkit_id,
                        tool_call_id: tool_call_id,
                        status: "error",
                        result: result_summary({:error, reason}, @history_result_bytes),
                        call_event_id: call_event && call_event.id
                      })
                    )

                  {:error, {:tool_outcome_not_recorded, reason}, state}
              end
          end
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp execute_declared(
         state,
         agent,
         %{kind: :native, module: module} = declared,
         tool_name,
         arguments,
         timeout,
         run,
         attempt
       ) do
    context =
      native_context(state, agent, run, attempt)
      |> Map.put(:config, Map.get(declared, :config) || %{})

    if worker_native?(module) do
      execute_in_worker(state, agent, module, tool_name, arguments, timeout, context)
    else
      safe_worker_call(fn -> Registry.execute(module, tool_name, arguments, context) end)
      |> normalize_native_result()
    end
  end

  defp execute_declared(state, agent, _declared, tool_name, arguments, timeout, run, attempt) do
    safe_worker_call(fn ->
      state.worker_client.execute(
        state.manager,
        agent.worker_id,
        tool_name,
        arguments,
        timeout: timeout,
        variables: variables(state, agent, run, attempt)
      )
    end)
  end

  defp native_context(state, agent, run, attempt) do
    %{
      definition: agent.definition,
      agent_id: agent.id,
      config_root: Map.get(agent.definition, :config_root),
      state_dir: state.state_dir,
      runtime_dir: state.runtime_dir,
      variables: variables(state, agent, run, attempt)
    }
  end

  # Native toolkits that export a worker operation run in the agent worker.
  # The manager renders and checks the request, but never traverses the
  # agent-owned tree, so a symlink the agent controls cannot redirect it into
  # manager state.
  defp worker_native?(module) when is_atom(module) and not is_nil(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :worker_operation, 0) and
      function_exported?(module, :worker_request, 3) and
      function_exported?(module, :worker_result, 1)
  end

  defp worker_native?(_module), do: false

  defp execute_in_worker(state, agent, module, tool_name, arguments, timeout, context) do
    with {:ok, worker_id} <- worker_id(agent) do
      safe_worker_call(fn ->
        with {:ok, request} <- module.worker_request(tool_name, arguments, context) do
          state.worker_client.execute(
            state.manager,
            worker_id,
            module.worker_operation(),
            request,
            timeout: timeout,
            variables: context.variables
          )
        end
      end)
      |> module.worker_result()
    end
  end

  defp normalize_native_result({:ok, %{} = result}) do
    status =
      case Map.get(result, :status, :ok) do
        status when status in [:ok, :error] -> status
        "ok" -> :ok
        "error" -> :error
        _other -> :error
      end

    {:ok, result |> Map.put_new(:output, "") |> Map.put(:status, status)}
  end

  defp normalize_native_result({:error, _reason} = error), do: error
  defp normalize_native_result(other), do: {:error, {:invalid_native_result, other}}

  defp variables(state, agent, run, attempt) do
    Variables.context(agent.definition,
      workspace: agent_workspace(state, agent),
      result_dir: agent_result_dir(state, agent),
      agent_id: agent.id,
      run_id: run && run.id,
      attempt_id: attempt && attempt.id,
      agent_state: agent.status,
      run_state: run && run.status
    )
  end

  defp agent_workspace(_state, agent), do: Map.get(agent, :workspace, nil)
  defp agent_result_dir(state, agent), do: Map.get(agent, :result_dir) || state.result_dir

  defp finalize_hooks(state, agent, run, attempt) do
    case run_hooks(state, agent, :finalize, run, attempt) do
      {:ok, state} -> state
      {:error, _reason, state} -> state
    end
  end

  # Finalize hooks run at most once per run, and always before the worker is
  # stopped. Recording the completed phase keeps a failed worker stop from
  # running cleanup again when the operator retries.
  defp finalize_once(state, agent, run, attempt) do
    case Map.fetch(state.agents, agent.id) do
      {:ok, %{finalize_state: :done}} ->
        state

      {:ok, stored} ->
        state = finalize_hooks(state, agent, run, attempt)
        put_agent(state, Map.put(stored, :finalize_state, :done))

      :error ->
        state
    end
  end

  # Hooks run inside the agent worker as fixed operations. The worker owns
  # the agent workspace, so init and finalize hooks write agent-owned files
  # across the UID boundary; the manager only relays the execute request.
  defp run_hooks(state, agent, phase, run, attempt) do
    entries = hook_plan(state, agent, phase)

    Enum.reduce_while(entries, {:ok, state}, fn entry, {:ok, state} ->
      name = entry.declared

      state =
        emit(
          state,
          agent.id,
          :hook_started,
          run_attrs(run, attempt, %{phase: phase, hook: name})
        )

      case execute_hook(state, agent, entry, run, attempt) do
        {:ok, result} ->
          state =
            emit(
              state,
              agent.id,
              :hook_finished,
              run_attrs(run, attempt, %{
                phase: phase,
                hook: name,
                output: Map.get(result, :output, "")
              })
            )

          {:cont, {:ok, state}}

        {:error, reason} ->
          state =
            emit(
              state,
              agent.id,
              :hook_failed,
              run_attrs(run, attempt, %{phase: phase, hook: name, reason: reason})
            )

          {:halt, {:error, {name, reason}, state}}
      end
    end)
  end

  defp hook_plan(_state, agent, phase) do
    reserved =
      agent.definition
      |> Map.get(:toolkits, [])
      |> Enum.flat_map(&Map.get(&1, :operations, []))
      |> declared_names()

    Hooks.plan(Map.get(agent.definition, :lifecycle), reserved)
    |> Map.fetch!(phase)
  end

  defp execute_hook(state, agent, entry, run, attempt) do
    if is_nil(agent.worker_id) do
      {:error, :worker_unavailable}
    else
      safe_worker_call(fn ->
        state.worker_client.execute(
          state.manager,
          agent.worker_id,
          entry.worker_name,
          %{},
          timeout: Map.get(state, :hook_timeout, @default_hook_timeout),
          variables: variables(state, agent, run, attempt)
        )
      end)
      |> hook_outcome()
    end
  end

  defp hook_outcome({:ok, %{status: :error} = result}) do
    {:error, {:exit_status, Map.get(result, :exit_status), Map.get(result, :output, "")}}
  end

  defp hook_outcome({:ok, result}), do: {:ok, result}
  defp hook_outcome({:error, reason}), do: {:error, reason}

  defp record_tool_history(state, agent, declared, tool_name, arguments, result, event_id) do
    path = Path.join(tool_history_dir(state.state_dir), agent.id <> ".pbth")
    secret_values = agent_secret_values(state, agent.id)
    arguments = Redact.redact(arguments, secret_values)
    result = Redact.redact(result, secret_values)

    with {:ok, sequence} <- next_tool_sequence(state, agent.id, path),
         :ok <- Transcript.ensure_dir(Path.dirname(path)),
         {:ok, writer} <- Writer.open(path) do
      record = %ToolHistory{
        sequence: Integer.to_string(sequence),
        timestamp: Integer.to_string(System.system_time(:millisecond)),
        call_id: event_id || "",
        toolkit_id: declared.toolkit_id || "",
        tool_name: tool_name,
        arguments: arguments_text(arguments),
        status: result_status(result),
        truncated_result: result_summary(result, @history_result_bytes),
        transcript_event_id: event_id || ""
      }

      append_result =
        try do
          Writer.append(writer, record)
        after
          Writer.close(writer)
        end

      case append_result do
        :ok ->
          {:ok, %{state | tool_sequences: Map.put(state.tool_sequences, agent.id, sequence + 1)}}

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp stop_worker(state, %{status: status, worker_id: worker_id}, timeout)
       when status in [:running, :starting] and is_binary(worker_id) do
    if is_nil(state.manager) do
      {:error, :manager_unavailable}
    else
      case safe_worker_call(fn ->
             state.worker_client.stop_worker(state.manager, worker_id, timeout)
           end) do
        {:ok, _info} -> :ok
        {:error, reason} -> normalize_stop_error(reason)
      end
    end
  end

  defp stop_worker(_state, _agent, _timeout), do: :ok

  defp normalize_stop_error(:unknown_worker), do: :ok
  defp normalize_stop_error(:worker_exited), do: :ok
  defp normalize_stop_error({:worker_not_available, _status}), do: :ok
  defp normalize_stop_error(reason), do: {:error, reason}

  defp stop_worker_best_effort(state, agent) do
    try do
      stop_worker(state, agent, @default_timeout)
    catch
      _kind, _reason -> :ok
    end
  end

  defp stop_lifecycle(nil, _reason, _at), do: nil

  defp stop_lifecycle(lifecycle, reason, at) do
    case Lifecycle.cancel(lifecycle, reason, at) do
      {:ok, lifecycle} -> lifecycle
      {:error, :terminal} -> lifecycle
      {:error, :no_run} -> lifecycle
      {:error, _reason} -> lifecycle
    end
  end

  defp start_compaction(state, agent_id, mode, from) do
    case Map.fetch(state.compactions, agent_id) do
      {:ok, entry} ->
        entry = %{entry | waiters: [from | entry.waiters]}
        {:noreply, %{state | compactions: Map.put(state.compactions, agent_id, entry)}}

      :error ->
        begin_compaction(state, agent_id, mode, from)
    end
  end

  defp begin_compaction(state, agent_id, mode, from) do
    with {:ok, agent} <- runner_agent(state, agent_id) do
      cond do
        not runner_enabled?(state) ->
          {:reply, :unchanged, state}

        mode == :maybe and not ContextCompaction.due?(agent.messages, agent.definition) ->
          {:reply, :unchanged, state}

        true ->
          opts = compaction_opts(state, agent, mode)
          generation = agent.context_generation
          messages = Redact.redact(agent.messages, agent_secret_values(state, agent_id))
          state_dir = state.state_dir
          server = self()

          {pid, monitor} =
            spawn_monitor(fn ->
              result = safe_prepare(state_dir, agent_id, messages, opts)
              send(server, {:compaction_prepared, agent_id, generation, result})
            end)

          entry = %{
            pid: pid,
            monitor: monitor,
            generation: generation,
            mode: mode,
            waiters: [from]
          }

          {:noreply, %{state | compactions: Map.put(state.compactions, agent_id, entry)}}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp compaction_opts(state, agent, mode) do
    {run_id, attempt_id} = context_ids(agent)

    base = [
      definition: agent.definition,
      run_id: run_id,
      attempt_id: attempt_id,
      model: model_name(agent.definition),
      provider: state.provider,
      provider_opts: state.provider_opts
    ]

    case mode do
      {:manual, opts} -> Keyword.merge(base, Keyword.drop(opts, [:timeout]))
      :maybe -> base
    end
  end

  defp safe_prepare(state_dir, agent_id, messages, opts) do
    try do
      ContextCompaction.prepare(state_dir, agent_id, messages, opts)
    rescue
      error -> {:error, {:compaction_exception, Exception.message(error)}}
    catch
      kind, reason -> {:error, {:compaction_exception, {kind, reason}}}
    end
  end

  defp finish_compaction(state, agent_id, generation, {:ok, plan}) do
    case Map.fetch(state.agents, agent_id) do
      {:ok, %{status: :running, context_generation: ^generation} = agent} ->
        case ContextCompaction.commit(state.state_dir, agent_id, plan) do
          :ok ->
            agent = %{
              agent
              | messages: plan.messages,
                context_generation: next_context_generation()
            }

            state = put_agent(state, agent)
            {state, agent} = fold_compacted_context(state, agent, plan)
            state = emit_compaction(state, agent, plan)
            {{:ok, summarize(agent)}, state}

          {:error, reason} ->
            Logger.warning(
              "context compaction commit failed for #{inspect(agent_id)}: #{inspect(reason)}"
            )

            {{:error, reason}, state}
        end

      _stale ->
        _ = ContextCompaction.discard(plan)
        {:unchanged, state}
    end
  end

  defp finish_compaction(state, _agent_id, _generation, :unchanged), do: {:unchanged, state}

  defp finish_compaction(state, agent_id, _generation, {:error, reason}) do
    Logger.warning("context compaction failed for #{inspect(agent_id)}: #{inspect(reason)}")
    {{:error, reason}, state}
  end

  defp finish_compaction(state, _agent_id, _generation, _other), do: {:unchanged, state}

  defp reply_waiters(waiters, reply) do
    Enum.each(waiters, fn from -> GenServer.reply(from, reply) end)
  end

  defp compaction_for_monitor(state, monitor, pid) do
    Enum.find_value(state.compactions, :error, fn {agent_id, entry} ->
      if entry.monitor == monitor and entry.pid == pid do
        {:ok, agent_id, entry}
      end
    end)
  end

  defp discard_plan({:ok, plan}), do: ContextCompaction.discard(plan)
  defp discard_plan(_other), do: :ok

  defp cancel_compaction(state, agent_id) do
    case Map.pop(state.compactions, agent_id) do
      {nil, _compactions} ->
        state

      {entry, compactions} ->
        Process.demonitor(entry.monitor, [:flush])
        if is_pid(entry.pid) and Process.alive?(entry.pid), do: Process.exit(entry.pid, :kill)
        reply_waiters(entry.waiters, {:error, :compaction_cancelled})
        %{state | compactions: compactions}
    end
  end

  defp next_context_generation, do: System.unique_integer([:positive, :monotonic])

  defp bump_context_generation(state, agent_id) do
    case Map.fetch(state.agents, agent_id) do
      {:ok, agent} ->
        put_agent(state, %{agent | context_generation: next_context_generation()})

      :error ->
        state
    end
  end

  defp fold_compacted_context(state, %{lifecycle: nil} = agent, _result), do: {state, agent}

  defp fold_compacted_context(state, agent, result) do
    attrs = %{
      reason: :compaction,
      at: now(),
      archive: result.archive[:generation]
    }

    case Lifecycle.fold_context(agent.lifecycle, attrs) do
      {:ok, lifecycle} ->
        agent = %{agent | lifecycle: lifecycle}
        {put_agent(state, agent), agent}

      {:error, reason} ->
        Logger.warning("context fold failed for #{inspect(agent.id)}: #{inspect(reason)}")
        {state, agent}
    end
  end

  defp emit_compaction(state, agent, result) do
    archive = result.archive

    data = %{
      revision: context_revision(agent),
      archive_generation: archive[:generation],
      archive_path: archive[:path],
      messages: length(result.messages),
      dropped_messages: length(result.dropped),
      retained_messages: length(result.retained),
      threshold: result.policy.threshold,
      target: result.policy.target,
      summary_tokens: archive[:summary_tokens]
    }

    emit(
      state,
      agent.id,
      :context_compacted,
      run_attrs(lifecycle_run(agent), active_attempt(agent), data)
    )
  end

  defp context_revision(%{lifecycle: nil}), do: nil

  defp context_revision(agent) do
    case lifecycle_run(agent) do
      nil -> nil
      run -> Run.context_revision(run)
    end
  end

  defp publish_delta(state, agent, delta) do
    event = %{
      type: :model_delta,
      agent_id: agent.id,
      data: %{delta: delta}
    }

    Enum.each(state.subscribers, fn {pid, _monitor} -> send(pid, {:patchbay_event, event}) end)
  end

  defp emit_activation(state, agent, run, attempt, recovery) do
    state =
      case recovery do
        :fresh ->
          emit(state, agent.id, :run_started, run_attrs(run, attempt, %{kind: run.kind}))

        {:resume, _run_id} ->
          emit(state, agent.id, :run_resumed, run_attrs(run, attempt, %{kind: run.kind}))

        {:refuse, _run_id} ->
          state
      end

    emit(
      state,
      agent.id,
      :attempt_started,
      run_attrs(run, attempt, %{
        ordinal: attempt.ordinal,
        worker_id: agent.worker_id,
        definition_revision: agent.revision
      })
    )
  end

  defp emit(state, agent_id, type, attrs) do
    case emit_with_event(state, agent_id, type, attrs) do
      {state, _event} -> state
    end
  end

  defp emit_with_event(state, agent_id, type, attrs) do
    attrs = Redact.redact(attrs, agent_secret_values(state, agent_id))
    path = Event.path(state.state_dir, agent_id)
    repair? = not Map.has_key?(state.event_sequences, agent_id)

    with {:ok, sequence} <- current_event_sequence(state, agent_id, path),
         {:ok, event} <-
           Event.new(
             attrs
             |> Map.put(:agent_id, agent_id)
             |> Map.put(:type, type)
             |> Map.put(:sequence, sequence + 1)
           ),
         :ok <- Event.append(path, event, repair: repair?) do
      publish(state, event)
      {%{state | event_sequences: Map.put(state.event_sequences, agent_id, sequence + 1)}, event}
    else
      {:error, reason} ->
        Logger.warning(
          "runtime event write failed for #{inspect(agent_id)} #{inspect(type)}: #{inspect(reason)}"
        )

        {state, nil}
    end
  end

  defp current_event_sequence(state, agent_id, path) do
    case Map.fetch(state.event_sequences, agent_id) do
      {:ok, sequence} -> {:ok, sequence}
      :error -> Event.last_sequence(path)
    end
  end

  defp publish(state, event) do
    Enum.each(state.subscribers, fn {pid, _monitor} -> send(pid, {:patchbay_event, event}) end)
  end

  defp next_tool_sequence(state, agent_id, path) do
    case Map.fetch(state.tool_sequences, agent_id) do
      {:ok, sequence} ->
        {:ok, sequence}

      :error ->
        case read_tool_history(path) do
          {:ok, records} -> {:ok, length(records) + 1}
          {:incomplete, records, _rest} -> {:ok, length(records) + 1}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp read_tool_history(path) do
    with :ok <- Transcript.ensure_file(path) do
      case File.read(path) do
        {:ok, data} -> ToolHistory.decode_stream(data)
        {:error, :enoent} -> {:ok, []}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp refresh(state) do
    case source_list(state) do
      {:ok, entries} ->
        Enum.reduce(entries, state, fn entry, state ->
          case Map.fetch(state.agents, entry.id) do
            :error ->
              put_agent(state, new_agent(entry))

            {:ok, agent} ->
              if agent.status in [:starting, :running, :stopping] do
                state
              else
                put_agent(state, %{agent | definition: entry.definition})
              end
          end
        end)

      {:error, reason} ->
        Logger.warning("runtime definition source list failed: #{inspect(reason)}")
        state
    end
  end

  defp source_list(state) do
    try do
      case state.definitions do
        {module, server} when is_atom(module) ->
          normalize_definition_list(module.list(server))

        module when is_atom(module) ->
          normalize_definition_list(module.list())

        definitions when is_map(definitions) ->
          normalize_definition_list(Map.values(definitions))
      end
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp source_get(state, agent_id) do
    try do
      case state.definitions do
        {module, server} when is_atom(module) ->
          normalize_definition(module.get(agent_id, server))

        module when is_atom(module) ->
          normalize_definition(module.get(agent_id))

        definitions when is_map(definitions) ->
          case Map.fetch(definitions, agent_id) do
            {:ok, definition} -> normalize_definition(definition)
            :error -> {:error, :not_found}
          end
      end
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp fetch_definition(state, agent_id, agent) do
    case source_get(state, agent_id) do
      {:ok, %{id: ^agent_id, definition: definition} = entry} ->
        if Event.valid_agent_id?(agent_id) do
          {:ok, definition, entry.revision, entry.fingerprint}
        else
          {:error, {:invalid_agent_id, agent_id}}
        end

      {:ok, %{id: other} = _entry} ->
        {:error, {:definition_id_mismatch, agent_id, other}}

      {:ok, other} ->
        {:error, {:invalid_definition, other}}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, _reason} when is_map(agent.definition) ->
        {:ok, agent.definition, nil, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_definition_list({:ok, definitions}) when is_list(definitions),
    do: normalize_entries(definitions)

  defp normalize_definition_list({:error, reason}), do: {:error, reason}

  defp normalize_definition_list(definitions) when is_list(definitions),
    do: normalize_entries(definitions)

  defp normalize_definition_list(other), do: {:error, {:invalid_definitions, other}}

  defp normalize_entries(definitions) do
    definitions
    |> Enum.reduce_while({:ok, []}, fn definition, {:ok, acc} ->
      case normalize_entry(definition) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.sort_by(entries, & &1.id)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_definition({:ok, item}), do: normalize_definition(item)
  defp normalize_definition(nil), do: {:error, :not_found}
  defp normalize_definition({:error, reason}), do: {:error, reason}
  defp normalize_definition(item), do: normalize_entry(item)

  defp normalize_entry(%{id: id, definition: %{} = definition} = entry) when is_binary(id) do
    {:ok,
     %{
       id: id,
       definition: definition,
       revision: Map.get(entry, :revision),
       fingerprint: Map.get(entry, :fingerprint)
     }}
  end

  defp normalize_entry(%{id: id} = definition) when is_binary(id) do
    {:ok, %{id: id, definition: definition, revision: nil, fingerprint: nil}}
  end

  defp normalize_entry(other), do: {:error, {:invalid_definition, other}}

  defp new_agent(entry) do
    %{
      id: entry.id,
      definition: entry.definition,
      revision: nil,
      fingerprint: nil,
      lifecycle: nil,
      status: :stopped,
      worker_id: nil,
      workspace: nil,
      result_dir: nil,
      state_dir: nil,
      started_at: nil,
      stopped_at: nil,
      last_error: nil,
      messages: [],
      activity: :idle,
      stream_text: nil,
      pending_user: 0,
      runner_pid: nil,
      runner_monitor: nil,
      in_flight_tools: MapSet.new(),
      context_generation: next_context_generation(),
      terminal_result: nil,
      terminal_failure: nil,
      finalize_state: nil,
      publisher: nil,
      stop_waiter: nil
    }
  end

  defp put_agent(state, agent), do: %{state | agents: Map.put(state.agents, agent.id, agent)}

  defp fetch_agent(state, agent_id) do
    case Map.fetch(state.agents, agent_id) do
      {:ok, agent} -> {:ok, agent}
      :error -> {:error, :not_found}
    end
  end

  defp ensure_startable(%{status: status}) when status in [:starting, :running, :stopping],
    do: {:error, {:not_startable, status}}

  defp ensure_startable(_agent), do: :ok

  defp new_or_existing_lifecycle(%{lifecycle: nil}, agent_id, definition) do
    Lifecycle.new(%{agent_id: agent_id, kind: lifecycle_kind(definition)})
  end

  defp new_or_existing_lifecycle(%{lifecycle: lifecycle}, _agent_id, _definition),
    do: {:ok, lifecycle}

  defp next_revision(agent, definition, source_revision, source_fingerprint) do
    fingerprint = source_fingerprint || :erlang.md5(:erlang.term_to_binary(definition))

    revision =
      cond do
        is_integer(source_revision) and source_revision > 0 ->
          if is_integer(agent.revision),
            do: max(agent.revision, source_revision),
            else: source_revision

        is_nil(agent.fingerprint) ->
          1

        agent.fingerprint == fingerprint ->
          agent.revision || 1

        true ->
          (agent.revision || 0) + 1
      end

    {revision, fingerprint}
  end

  defp lifecycle_kind(%{lifecycle: %{kind: kind}})
       when kind in [:one_shot, :scheduled, :perpetual],
       do: kind

  defp lifecycle_kind(%{lifecycle: %{"kind" => "scheduled"}}), do: :scheduled
  defp lifecycle_kind(%{lifecycle: %{"kind" => "perpetual"}}), do: :perpetual
  defp lifecycle_kind(_definition), do: :one_shot

  defp toolkit_ids(definition) do
    definition
    |> Map.get(:toolkits, [])
    |> Enum.map(&Map.get(&1, :toolkit))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp find_tool(definition, tool_name) when is_binary(tool_name) do
    definition
    |> declared_tools()
    |> Map.fetch(tool_name)
  end

  defp find_tool(_definition, _tool_name), do: :error

  defp declared_tools(definition) do
    context = %{definition: definition}

    implicit =
      implicit_declared_tools(definition, context)
      |> Enum.reduce(%{}, fn {name, declared}, acc -> Map.put_new(acc, name, declared) end)

    explicit =
      definition
      |> Map.get(:toolkits, [])
      |> Enum.with_index()
      |> Enum.flat_map(fn {toolkit, index} ->
        toolkit_id = Map.get(toolkit, :toolkit) || "toolkit-#{index + 1}"

        native_tools =
          case Map.get(toolkit, :native) do
            nil ->
              []

            native ->
              module = Registry.native_module(native)

              native
              |> Registry.tools(context, Map.get(toolkit, :tools, []))
              |> Enum.map(fn tool ->
                {tool.name,
                 %{
                   toolkit_id: toolkit_id,
                   kind: :native,
                   module: module,
                   native_tool: tool,
                   config: Map.get(toolkit, :config) || %{}
                 }}
              end)
          end

        fixed_tools =
          toolkit
          |> Map.get(:operations, [])
          |> Enum.map(fn operation ->
            {Map.get(operation, :name),
             %{toolkit_id: toolkit_id, kind: :fixed, operation: operation}}
          end)

        native_tools ++ fixed_tools
      end)
      |> Enum.reject(fn {name, _declared} -> is_nil(name) end)
      |> Enum.reduce(%{}, fn {name, declared}, acc -> Map.put_new(acc, name, declared) end)

    Map.merge(implicit, explicit)
  end

  defp implicit_declared_tools(definition, context) do
    opts = [config_root: Map.get(definition, :config_root)]

    opts
    |> Manifest.implicit()
    |> Enum.flat_map(fn manifest ->
      module = Registry.native_module(manifest.native)

      manifest
      |> Map.get(:native)
      |> Registry.tools(context, manifest.tools)
      |> Enum.map(fn tool ->
        {tool.name,
         %{
           toolkit_id: manifest.name,
           kind: :native,
           module: module,
           native_tool: tool,
           config: Map.get(manifest, :config) || %{}
         }}
      end)
    end)
  end

  defp summarize(agent) do
    run = lifecycle_run(agent)
    active = if agent.lifecycle, do: Lifecycle.active_attempt(agent.lifecycle)
    attempt = active || (run && Run.current_attempt(run))

    instance =
      if agent.lifecycle && attempt && attempt.instance_id do
        Lifecycle.get_instance(agent.lifecycle, attempt.instance_id)
      end

    %{
      agent_id: agent.id,
      status: agent.status,
      definition_revision: agent.revision,
      lifecycle_kind: lifecycle_kind(agent.definition),
      model: model_name(agent.definition),
      toolkit_ids: toolkit_ids(agent.definition),
      tools: agent.definition |> declared_tools() |> Map.keys() |> Enum.sort(),
      worker_id: agent.worker_id,
      run_id: run && run.id,
      run_status: run && run.status,
      attempt_id: attempt && attempt.id,
      attempt_ordinal: attempt && attempt.ordinal,
      instance_id: instance && instance.id,
      activity: agent.activity,
      stream_text: agent.stream_text,
      message_count: length(agent.messages),
      pending_messages: agent.pending_user,
      result: run && run.result,
      failure: run && run.failure,
      started_at: agent.started_at,
      stopped_at: agent.stopped_at,
      last_error: agent.last_error
    }
  end

  defp lifecycle_run(nil), do: nil
  defp lifecycle_run(%{lifecycle: nil}), do: nil
  defp lifecycle_run(%{lifecycle: lifecycle}), do: Lifecycle.current_run(lifecycle)

  defp active_attempt(%{lifecycle: nil}), do: nil
  defp active_attempt(%{lifecycle: lifecycle}), do: Lifecycle.active_attempt(lifecycle)

  defp model_name(%{model: %{name: name}}), do: name
  defp model_name(_definition), do: nil

  defp run_attrs(nil, _attempt, data), do: %{data: data}

  defp run_attrs(run, attempt, data) do
    %{
      run_id: run.id,
      attempt_id: attempt && attempt.id,
      instance_id: attempt && attempt.instance_id,
      definition_revision: run.definition_revision,
      data: data
    }
  end

  defp worker_id_for(agent_id), do: Patchbay.Worker.Id.for_agent(agent_id)

  defp resolve_definitions(opts) do
    value = Keyword.get(opts, :definitions) || Keyword.get(opts, :definition_source)

    case value do
      nil -> {:error, :missing_definitions}
      {module, server} when is_atom(module) -> {:ok, {module, server}}
      module when is_atom(module) -> {:ok, module}
      definitions when is_map(definitions) -> {:ok, definitions}
      definitions when is_list(definitions) -> {:ok, Map.new(definitions, &{&1.id, &1})}
      other -> {:error, {:invalid_definitions, other}}
    end
  end

  defp ensure_dirs(state_dir) do
    with :ok <- Transcript.ensure_dir(state_dir),
         :ok <- Transcript.ensure_dir(Event.dir(state_dir)),
         :ok <- Transcript.ensure_dir(tool_history_dir(state_dir)),
         :ok <- Transcript.ensure_dir(ContextStore.dir(state_dir)) do
      :ok
    end
  end

  defp resolve_secret_env(state, definition) do
    with {:ok, declarations} <- SecretEnv.declarations(definition),
         {:ok, values} <- SecretEnv.resolve(declarations, state.secrets_dir) do
      {:ok, values}
    end
  end

  defp maybe_put_result_dir(opts, agent) do
    case Map.get(agent, :result_dir) do
      nil -> opts
      result_dir -> Keyword.put(opts, :result_dir, result_dir)
    end
  end

  # The manager relays an explicit "no workspace" flag so the supervisor does
  # not allocate its default workspace directory for an agent that disabled
  # its workspace.
  defp maybe_put_workspace_disabled(opts, false), do: Keyword.put(opts, :workspace_disabled, true)
  defp maybe_put_workspace_disabled(opts, _enabled), do: opts

  defp maybe_put_secrets(opts, secrets) when map_size(secrets) == 0, do: opts
  defp maybe_put_secrets(opts, secrets), do: Keyword.put(opts, :secrets, secrets)

  defp maybe_put_packages(opts, []), do: opts
  defp maybe_put_packages(opts, packages), do: Keyword.put(opts, :packages, packages)

  defp remember_secret_values(state, _agent_id, values) when map_size(values) == 0, do: state

  defp remember_secret_values(state, agent_id, values) do
    %{state | secret_values: Map.put(state.secret_values, agent_id, values)}
  end

  defp forget_secret_values(state, agent_id) do
    %{state | secret_values: Map.delete(state.secret_values, agent_id)}
  end

  defp agent_secret_values(state, agent_id) do
    Map.get(state.secret_values, agent_id, %{})
  end

  defp resolved_operations(definition) do
    declared =
      definition
      |> Map.get(:toolkits, [])
      |> Enum.flat_map(&Map.get(&1, :operations, []))
      |> first_of_each_name()

    hooks_plan = Hooks.plan(Map.get(definition, :lifecycle), declared_names(declared))

    (declared ++ hooks_plan.operations)
    |> Operations.from_definition()
    |> case do
      {:ok, operations} -> {:ok, operations}
      {:error, reason} -> {:error, {:invalid_operations, reason}}
    end
  end

  defp declared_names(operations) do
    operations |> Enum.map(&Map.get(&1, :name)) |> Enum.reject(&is_nil/1)
  end

  defp first_of_each_name(operations) do
    {kept, _names} =
      Enum.reduce(operations, {[], MapSet.new()}, fn operation, {kept, names} ->
        name = Map.get(operation, :name)

        if is_binary(name) and not MapSet.member?(names, name) do
          {[operation | kept], MapSet.put(names, name)}
        else
          {kept, names}
        end
      end)

    Enum.reverse(kept)
  end

  # The result and state directories are always allocated. The workspace is
  # allocated only for definitions that enable it; a disabled workspace stays
  # nil, so `{%workspace}` renders as unavailable instead of silently pointing
  # somewhere else.
  defp ensure_agent_dirs(state, agent_id, definition) do
    if Event.valid_agent_id?(agent_id) do
      dirs = %{
        workspace: workspace_dir(state, agent_id, definition),
        result_dir: Path.join(state.result_dir, agent_id),
        state_dir: Path.join([state.state_dir, "agents", agent_id])
      }

      with :ok <- Transcript.ensure_dir(dirs.state_dir) do
        {:ok, dirs}
      else
        {:error, reason} -> {:error, {:agent_dirs_failed, reason}}
      end
    else
      {:error, {:invalid_agent_id, agent_id}}
    end
  end

  defp workspace_dir(state, agent_id, definition) do
    if Workspace.enabled?(definition),
      do: Path.join(state.workspace_dir, agent_id),
      else: nil
  end

  defp tool_history_dir(state_dir), do: Path.join(state_dir, "tool-history")

  defp event_path(state, agent_id) do
    if Event.valid_agent_id?(agent_id) do
      {:ok, Event.path(state.state_dir, agent_id)}
    else
      {:error, {:invalid_agent_id, agent_id}}
    end
  end

  defp tool_history_path(state, agent_id) do
    if Event.valid_agent_id?(agent_id) do
      {:ok, Path.join(tool_history_dir(state.state_dir), agent_id <> ".pbth")}
    else
      {:error, {:invalid_agent_id, agent_id}}
    end
  end

  defp result_status({:ok, %{status: :ok}}), do: "ok"
  defp result_status({:ok, %{status: :error}}), do: "error"
  defp result_status({:error, _reason}), do: "error"
  defp result_status(_result), do: "error"

  defp redact_result(result, state, agent_id) do
    Redact.redact(result, agent_secret_values(state, agent_id))
  end

  defp result_summary(result, limit) do
    result
    |> case do
      {:ok, %{output: output}} when is_binary(output) -> output
      {:ok, %{error: error}} -> inspect(error)
      {:error, reason} -> inspect(reason)
      other -> inspect(other)
    end
    |> truncate(limit)
  end

  defp arguments_text(arguments) do
    arguments
    |> inspect(limit: :infinity, printable_limit: @history_arguments_bytes)
    |> truncate(@history_arguments_bytes)
  end

  defp truncate(value, limit) when byte_size(value) <= limit, do: value

  defp truncate(value, limit) do
    binary_part(value, 0, limit) <> "...<truncated>"
  end

  defp safe_worker_call(fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:worker_unavailable, safe_exit_reason(reason)}}
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_exit_reason({reason, _details}), do: reason
  defp safe_exit_reason(reason), do: reason

  defp call_timeout(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    await_timeout = Keyword.get(opts, :await_timeout, @default_await_timeout)
    max(timeout, await_timeout) + 5_000
  end

  defp unique_id(prefix) do
    prefix <>
      "-" <>
      Integer.to_string(System.system_time(:microsecond), 36) <>
      "-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
