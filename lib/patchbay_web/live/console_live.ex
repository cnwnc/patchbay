defmodule PatchbayWeb.ConsoleLive do
  @moduledoc false

  use PatchbayWeb, :live_view

  import PatchbayWeb.Presenter

  alias Patchbay.CLI.Manager
  alias Patchbay.DefinitionRegistry
  alias Patchbay.Runtime

  @pubsub Patchbay.PubSub
  @flash_timeout 6_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(@pubsub, "config")
      :timer.send_interval(1_000, :tick)
    end

    socket =
      assign(socket,
        agents: [],
        visible_agents: [],
        counts: empty_counts(),
        events_by_agent: %{},
        selected: nil,
        selected_agent: nil,
        events: [],
        history: [],
        stream: [],
        stream_delta: nil,
        filter: "all",
        now: DateTime.utc_now(),
        control: control_status(),
        pending: nil,
        pending_text: nil,
        draft: "",
        activity: nil,
        message_count: 0,
        pending_messages: 0,
        runtime_pid: nil,
        runtime_monitor: nil
      )

    socket = if connected?(socket), do: watch_runtime(socket), else: socket

    {:ok, refresh(socket)}
  end

  @impl true
  def handle_event("select", %{"id" => agent_id}, socket) do
    {:noreply, select_agent(socket, agent_id)}
  end

  def handle_event("filter", %{"filter" => filter}, socket) do
    socket = assign(socket, :filter, filter)
    {:noreply, assign_visible(socket)}
  end

  def handle_event("start", %{"id" => agent_id}, socket) do
    {:noreply, start_control(socket, :start, agent_id)}
  end

  def handle_event("stop", %{"id" => agent_id}, socket) do
    {:noreply, start_control(socket, :stop, agent_id)}
  end

  def handle_event("draft", params, socket) do
    {:noreply, assign(socket, :draft, message_content(params, socket.assigns.draft))}
  end

  def handle_event("send", params, socket) do
    {:noreply, submit_message(socket, :send, message_content(params, socket.assigns.draft))}
  end

  def handle_event("steer", params, socket) do
    {:noreply, submit_message(socket, :steer, message_content(params, socket.assigns.draft))}
  end

  def handle_event("dismiss_flash", %{"kind" => kind}, socket) do
    kind = flash_kind(kind)
    paused = MapSet.delete(paused_flashes(socket), kind)

    {:noreply,
     socket
     |> assign(:paused_flashes, paused)
     |> clear_flash(kind)}
  end

  def handle_event("pause_flash", %{"kind" => kind}, socket) do
    {:noreply,
     assign(socket, :paused_flashes, MapSet.put(paused_flashes(socket), flash_kind(kind)))}
  end

  def handle_event("resume_flash", %{"kind" => kind}, socket) do
    kind = flash_kind(kind)

    socket =
      assign(socket, :paused_flashes, MapSet.delete(paused_flashes(socket), kind))

    case Map.fetch(socket.assigns.flash, kind) do
      {:ok, message} ->
        Process.send_after(self(), {:expire_flash, kind, message}, @flash_timeout)
        {:noreply, socket}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:patchbay_event, %{type: :model_delta} = event}, socket) do
    socket =
      if socket.assigns.selected == event.agent_id do
        delta = Map.get(event.data, :delta) || Map.get(event.data, "delta") || ""
        current = socket.assigns.stream_delta || ""
        assign(socket, :stream_delta, current <> delta)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:patchbay_event, %{type: :model_message} = event}, socket) do
    socket =
      if socket.assigns.selected == event.agent_id do
        socket |> refresh() |> assign(:stream_delta, nil)
      else
        refresh_agents(socket)
      end

    {:noreply, socket}
  end

  def handle_info({:patchbay_event, event}, socket) do
    socket =
      if socket.assigns.selected == event.agent_id do
        refresh(socket)
      else
        refresh_agents(socket)
      end

    {:noreply, socket}
  end

  def handle_info({:expire_flash, kind, message}, socket) do
    expired? =
      not MapSet.member?(paused_flashes(socket), kind) and
        Map.get(socket.assigns.flash, kind) == message

    socket =
      if expired? do
        clear_flash(socket, kind)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(:tick, socket) do
    previous = socket.assigns.runtime_pid
    socket = watch_runtime(socket)

    socket =
      if socket.assigns.runtime_pid != previous or stale_agents?(socket) do
        refresh(socket)
      else
        socket
      end

    {:noreply, assign(socket, now: DateTime.utc_now(), control: control_status())}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{assigns: %{runtime_monitor: ref}} = socket
      ) do
    Process.send_after(self(), :runtime_recover, 250)
    {:noreply, assign(socket, runtime_pid: nil, runtime_monitor: nil)}
  end

  def handle_info(:runtime_recover, socket) do
    previous = socket.assigns.runtime_pid
    socket = watch_runtime(socket)
    socket = if socket.assigns.runtime_pid != previous, do: refresh(socket), else: socket
    {:noreply, socket}
  end

  def handle_info({:config, :reloaded}, socket) do
    {:noreply, refresh(socket)}
  end

  def handle_info({:control, action, agent_id, result}, socket) do
    socket = assign(socket, :pending, nil)

    socket =
      case result do
        {:ok, _summary} ->
          notify(socket, :info, outcome_message(action, agent_id, :ok))

        {:error, reason} ->
          notify(socket, :error, outcome_message(action, agent_id, reason))
      end

    {:noreply, socket |> refresh() |> select_if_present(agent_id)}
  end

  def handle_info({:message, action, agent_id, result}, socket) do
    socket = assign(socket, :pending, nil)

    socket =
      case result do
        {:ok, _summary} ->
          socket
          |> assign(pending_text: nil)
          |> notify(:info, outcome_message(action, agent_id, :ok))

        {:error, reason} ->
          socket
          |> assign(draft: socket.assigns.pending_text || "", pending_text: nil)
          |> notify(:error, outcome_message(action, agent_id, reason))
      end

    {:noreply, socket |> refresh() |> select_if_present(agent_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp subscribe_to_runtime do
    safe(fn -> Runtime.subscribe(Runtime) end)
  end

  defp watch_runtime(socket) do
    case Process.whereis(Runtime) do
      nil ->
        socket

      pid when pid == socket.assigns.runtime_pid ->
        socket

      pid ->
        if socket.assigns.runtime_monitor do
          Process.demonitor(socket.assigns.runtime_monitor, [:flush])
        end

        monitor = Process.monitor(pid)
        subscribe_to_runtime()
        assign(socket, runtime_pid: pid, runtime_monitor: monitor)
    end
  end

  defp refresh(socket) do
    socket
    |> refresh_agents()
    |> refresh_selected()
  end

  defp stale_agents?(socket) do
    case safe(fn -> Runtime.list_agents(Runtime) end) do
      {:ok, agents} when is_list(agents) ->
        current = Map.new(socket.assigns.agents, &{&1.agent_id, &1})
        ids = Enum.map(agents, & &1.agent_id)
        selected = socket.assigns.selected

        ids != Enum.map(socket.assigns.agents, & &1.agent_id) or
          (agents != [] and (is_nil(selected) or selected not in ids)) or
          Enum.any?(agents, fn agent ->
            case Map.get(current, agent.agent_id) do
              nil -> true
              existing -> agent_signature(existing) != agent_signature(agent)
            end
          end)

      _other ->
        false
    end
  end

  defp agent_signature(agent) do
    {
      Map.get(agent, :status),
      Map.get(agent, :run_id),
      Map.get(agent, :activity),
      Map.get(agent, :message_count),
      Map.get(agent, :pending_messages)
    }
  end

  defp refresh_agents(socket) do
    agents =
      case safe(fn -> Runtime.list_agents(Runtime) end) do
        {:ok, agents} when is_list(agents) -> agents
        _other -> []
      end

    definitions = definitions_by_id()

    agents =
      Enum.map(agents, fn agent ->
        case Map.get(definitions, agent.agent_id) do
          nil ->
            Map.put(agent, :definition, nil)

          snapshot ->
            agent
            |> Map.put(:definition, snapshot.definition)
            |> Map.put(:registry_revision, snapshot.revision)
        end
      end)

    events_by_agent =
      Map.new(agents, fn agent -> {agent.agent_id, read_events(agent.agent_id)} end)

    socket =
      assign(socket,
        agents: agents,
        events_by_agent: events_by_agent,
        counts: counts(agents),
        now: DateTime.utc_now(),
        control: control_status()
      )

    selected =
      case socket.assigns.selected do
        nil ->
          first_agent_id(agents)

        agent_id ->
          if Enum.any?(agents, &(&1.agent_id == agent_id)),
            do: agent_id,
            else: first_agent_id(agents)
      end

    socket |> assign(:selected, selected) |> assign_visible()
  end

  defp refresh_selected(%{assigns: %{selected: nil}} = socket) do
    assign(socket,
      selected_agent: nil,
      events: [],
      history: [],
      stream: [],
      stream_delta: nil,
      activity: nil,
      message_count: 0,
      pending_messages: 0
    )
  end

  defp refresh_selected(%{assigns: %{selected: agent_id}} = socket) do
    case safe(fn -> Runtime.get_agent(Runtime, agent_id) end) do
      {:ok, agent} ->
        events = Map.get(socket.assigns.events_by_agent, agent_id, [])
        history = read_history(agent_id)
        activity = read_activity(agent_id)
        messages = read_messages(agent_id)

        listed =
          Enum.find(socket.assigns.agents, &(&1.agent_id == agent_id)) ||
            %{}

        agent = Map.merge(agent, Map.take(listed, [:definition, :registry_revision]))
        stream_delta = Map.get(agent, :stream_text)

        assign(socket,
          selected_agent: agent,
          events: events,
          history: history,
          stream: stream_items(events, history),
          stream_delta: stream_delta,
          activity: activity,
          message_count: message_count(messages, agent),
          pending_messages: pending_messages(activity, agent)
        )

      _error ->
        assign(socket,
          selected_agent: nil,
          events: [],
          history: [],
          stream: [],
          stream_delta: nil,
          activity: nil,
          message_count: 0,
          pending_messages: 0
        )
    end
  end

  defp select_agent(socket, agent_id) do
    socket
    |> assign(:selected, agent_id)
    |> refresh_selected()
  end

  defp select_if_present(socket, agent_id) do
    if Enum.any?(socket.assigns.agents, &(&1.agent_id == agent_id)) do
      select_agent(socket, agent_id)
    else
      socket
    end
  end

  defp assign_visible(socket) do
    filter = socket.assigns.filter
    visible = Enum.filter(socket.assigns.agents, &match_filter?(filter, &1))
    assign(socket, visible_agents: visible)
  end

  defp start_control(socket, action, agent_id) do
    if socket.assigns.pending do
      socket
    else
      parent = self()

      Task.start(fn ->
        result =
          case action do
            :start -> safe(fn -> Runtime.start_agent(Runtime, agent_id) end)
            :stop -> safe(fn -> Runtime.stop_agent(Runtime, agent_id) end)
          end

        send(parent, {:control, action, agent_id, result})
      end)

      assign(socket, :pending, {action, agent_id})
    end
  end

  defp submit_message(socket, action, content) do
    content = String.trim(content || "")

    cond do
      content == "" ->
        socket

      socket.assigns.pending ->
        socket

      is_nil(socket.assigns.selected_agent) ->
        socket

      true ->
        agent = socket.assigns.selected_agent
        parent = self()

        Task.start(fn ->
          result = safe(fn -> deliver_message(action, agent, content) end)
          send(parent, {:message, action, agent.agent_id, result})
        end)

        assign(socket, pending: {action, agent.agent_id}, pending_text: content, draft: "")
    end
  end

  defp deliver_message(:send, %{status: status} = agent, content)
       when status in [:stopped, :failed] do
    Runtime.start_agent(Runtime, agent.agent_id, message: content)
  end

  defp deliver_message(:send, agent, content),
    do: Runtime.send_message(Runtime, agent.agent_id, content)

  defp deliver_message(:steer, agent, content),
    do: Runtime.steer(Runtime, agent.agent_id, content)

  defp outcome_message(:start, agent_id, :ok), do: "Started #{agent_id}."
  defp outcome_message(:stop, agent_id, :ok), do: "Stopped #{agent_id}."
  defp outcome_message(:send, agent_id, :ok), do: "Sent message to #{agent_id}."
  defp outcome_message(:steer, agent_id, :ok), do: "Steered #{agent_id}."

  defp outcome_message(:start, agent_id, reason),
    do: "Start failed for #{agent_id}: #{error_detail(reason)}"

  defp outcome_message(:stop, agent_id, reason),
    do: "Stop failed for #{agent_id}: #{error_detail(reason)}"

  defp outcome_message(:send, agent_id, reason),
    do: "Message failed for #{agent_id}: #{error_detail(reason)}"

  defp outcome_message(:steer, agent_id, reason),
    do: "Steer failed for #{agent_id}: #{error_detail(reason)}"

  defp message_content(%{"message" => %{"content" => content}}, _fallback)
       when is_binary(content),
       do: content

  defp message_content(%{"content" => content}, _fallback) when is_binary(content), do: content
  defp message_content(_params, fallback), do: fallback

  defp notify(socket, kind, message) do
    Process.send_after(self(), {:expire_flash, kind, message}, @flash_timeout)
    put_flash(socket, kind, message)
  end

  defp paused_flashes(socket), do: Map.get(socket.assigns, :paused_flashes, MapSet.new())

  defp flash_kind("info"), do: "info"
  defp flash_kind("error"), do: "error"
  defp flash_kind(_kind), do: nil

  defp pending_agent_id({_action, agent_id}), do: agent_id
  defp pending_agent_id(_pending), do: nil

  defp destination_label(agent) do
    case Map.get(agent, :status) do
      status when status in [:running, :starting] ->
        "RUN #{short_run_id(Map.get(agent, :run_id))}"

      :stopping ->
        "RUN STOPPING"

      _status ->
        "NEXT RUN"
    end
  end

  defp activity_value(nil, agent), do: agent && Map.get(agent, :activity)
  defp activity_value(activity, _agent), do: Map.get(activity, :activity)

  defp pending_messages(nil, agent), do: (agent && Map.get(agent, :pending_messages)) || 0
  defp pending_messages(activity, _agent), do: Map.get(activity, :pending_messages) || 0

  defp message_count(messages, _agent) when is_list(messages), do: length(messages)
  defp message_count(_messages, agent), do: (agent && Map.get(agent, :message_count)) || 0

  defp definitions_by_id do
    case safe(fn -> DefinitionRegistry.list() end) do
      definitions when is_list(definitions) -> Map.new(definitions, &{&1.id, &1})
      _other -> %{}
    end
  end

  defp read_events(agent_id) do
    case safe(fn -> Runtime.list_events(Runtime, agent_id) end) do
      {:ok, events} -> events
      {:incomplete, events, _rest} -> events
      _other -> []
    end
  end

  defp read_history(agent_id) do
    case safe(fn -> Runtime.tool_history(Runtime, agent_id) end) do
      {:ok, records} -> records
      {:incomplete, records, _rest} -> records
      _other -> []
    end
  end

  defp read_activity(agent_id) do
    case safe(fn -> Runtime.activity(Runtime, agent_id) end) do
      {:ok, %{} = activity} -> activity
      _other -> nil
    end
  end

  defp read_messages(agent_id) do
    case safe(fn -> Runtime.messages(Runtime, agent_id) end) do
      {:ok, messages} when is_list(messages) -> messages
      _other -> nil
    end
  end

  defp control_status do
    case safe(fn -> Manager.control_status(Manager) end) do
      :connected -> :connected
      _other -> :disconnected
    end
  end

  defp counts(agents) do
    Map.new(filters(), fn {key, _label} -> {key, filter_count(agents, key)} end)
  end

  defp empty_counts, do: Map.new(filters(), fn {key, _label} -> {key, 0} end)

  defp first_agent_id([agent | _rest]), do: agent.agent_id
  defp first_agent_id(_agents), do: nil

  defp safe(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :unavailable}
    _kind, reason -> {:error, reason}
  end

  defp channel_index(agents, agent_id) do
    case Enum.find_index(agents, &(&1.agent_id == agent_id)) do
      nil -> "—"
      index -> String.pad_leading(Integer.to_string(index + 1), 2, "0")
    end
  end

  defp row_class(%{kind: :event}), do: "stream-row row-event"
  defp row_class(%{kind: :chat, role: :operator}), do: "stream-row row-chat is-operator"
  defp row_class(%{kind: :chat}), do: "stream-row row-chat is-agent"

  defp row_class(%{kind: :tool, terminal: true} = item),
    do: "stream-row row-tool is-terminal #{item.tone}"

  defp row_class(%{kind: :tool} = item), do: "stream-row row-tool #{item.tone}"

  defp row_type(%{kind: :tool, terminal: true}), do: "TASK"
  defp row_type(%{kind: :tool}), do: "TOOL"
  defp row_type(%{kind: :chat} = item), do: item.type
  defp row_type(_item), do: "EVENT"

  defp selected_index(nil, _agents), do: "—"
  defp selected_index(agent_id, agents), do: channel_index(agents, agent_id)

  defp policy_summary(nil), do: "—"

  defp policy_summary(%{context: context}) do
    values = [
      context.between_runs && "BETWEEN #{context.between_runs}",
      context.prior_runs && "PRIOR #{context.prior_runs}",
      context.restore_interrupted && "RESTORE #{context.restore_interrupted}"
    ]

    values
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "NO POLICY"
      values -> Enum.join(values, " · ")
    end
  end

  defp context_percent(definition) do
    {count, _title} = context_count(definition)
    round(count / 3 * 100)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="console">
      <header class="masthead">
        <div class="brand">
          <span class="mark" aria-hidden="true"></span>
          <span class="wordmark">PATCHBAY</span>
          <span class="divider" aria-hidden="true"></span>
          <span class="view">CONSOLE</span>
        </div>
        <div class="mast-right">
          <nav class="global-nav" aria-label="Global navigation">
            <a class="nav-link is-active" href={~p"/"} aria-current="page">CONSOLE</a>
            <a class="nav-link" href={~p"/config"}>CONFIG</a>
            <a class="nav-link" href={~p"/toolkits"}>TOOLKITS</a>
          </nav>
          <span class="local">
            <span class={"lamp #{if @control == :connected, do: "live", else: "idle"}"}></span>
            CONTROL <b>{if @control == :connected, do: "CONNECTED", else: "DISCONNECTED"}</b>
          </span>
          <time class="clock">{Calendar.strftime(@now, "%H:%M:%S")} <small>UTC</small></time>
        </div>
      </header>

      <main class="workspace">
        <section class="channels" aria-label="Agent channels">
          <header class="channels-head">
            <h1>CHANNELS <span class="count">{length(@agents)}</span></h1>
            <div class="filters" role="group" aria-label="Channel filters">
              <button
                :for={{key, label} <- filters()}
                class={"filter #{if @filter == key, do: "is-active"}"}
                type="button"
                phx-click="filter"
                phx-value-filter={key}
                aria-pressed={to_string(@filter == key)}
              >
                {label} <span>{@counts[key]}</span>
              </button>
            </div>
            <div class="sort">SORT <b>CH</b> <span class="caret" aria-hidden="true">▾</span></div>
          </header>

          <div class="strip-cols" aria-hidden="true">
            <span>CH</span>
            <span>AGENT</span>
            <span>ACTIVITY</span>
            <span>CTX</span>
            <span>LAST ACTION</span>
            <span>STATE</span>
            <span>RUN</span>
            <span>CTRL</span>
          </div>

          <ol class="strips" role="listbox" aria-label="Agent channels" aria-orientation="vertical">
            <li
              :for={agent <- @visible_agents}
              class={"strip #{if @selected == agent.agent_id, do: "is-selected on-dark"}"}
              role="option"
              aria-selected={@selected == agent.agent_id}
              tabindex="0"
              phx-click="select"
              phx-value-id={agent.agent_id}
            >
              <span class="ch">{channel_index(@agents, agent.agent_id)}</span>
              <div class="agent">
                <span class="agent-name">{agent.agent_id}</span>
                <span class="agent-sub">{agent_sub(agent, agent.definition)}</span>
              </div>
              <div class="trace-wrap">
                <svg
                  class={"trace #{trace_class(agent.status)}"}
                  viewBox="0 0 76 20"
                  preserveAspectRatio="none"
                  aria-hidden="true"
                >
                  <polyline points={trace_points(Map.get(@events_by_agent, agent.agent_id, []), @now)} />
                </svg>
              </div>
              <div class="ctx" aria-label="Context policy">
                <span class="ctx-num">{elem(context_count(agent.definition), 0)}</span>
                <span class="ctx-bar">
                  <i style={"width:#{context_percent(agent.definition)}%"}></i>
                </span>
              </div>
              <div class="last">
                <span class={elem(last_action(Map.get(@events_by_agent, agent.agent_id, [])), 1)}>
                  {elem(last_action(Map.get(@events_by_agent, agent.agent_id, [])), 0)}
                </span>
              </div>
              <div class="state">
                <span class={"lamp #{status_lamp(agent.status)}"}></span>
                <span class="state-copy">
                  <span class="state-name">{status_label(agent.status)}</span>
                  <span class="state-sub">{state_sub(agent, @now)}</span>
                </span>
              </div>
              <div class="run">
                <b>{short_run_id(agent.run_id)}</b>
                <span>{run_state(agent.run_status)}</span>
              </div>
              <div class="rowctl">
                <button
                  :if={agent.status in [:stopped, :failed]}
                  class="mini"
                  type="button"
                  phx-click="start"
                  phx-value-id={agent.agent_id}
                  disabled={pending_agent_id(@pending) == agent.agent_id}
                >
                  START
                </button>
                <button
                  :if={agent.status in [:running, :starting]}
                  class="mini"
                  type="button"
                  phx-click="stop"
                  phx-value-id={agent.agent_id}
                  disabled={pending_agent_id(@pending) == agent.agent_id}
                >
                  STOP
                </button>
                <span :if={agent.status == :stopping} class="mini is-static">STOPPING</span>
              </div>
            </li>
          </ol>

          <footer class="channels-foot">
            <span class="foot-item">
              <span class={"lamp #{if @control == :connected, do: "live", else: "idle"}"}></span>
              CONTROL <b>{if @control == :connected, do: "UP", else: "DOWN"}</b>
            </span>
            <span class="foot-item">AGENTS <b>{length(@agents)}</b></span>
            <span class="foot-item">SELECTED <b>{selected_index(@selected, @agents)}</b></span>
            <span class="foot-item push">EVENTS <b>{length(@events)}</b></span>
          </footer>
        </section>

        <aside class="inspector" aria-label="Selected agent inspector">
          <div :if={is_nil(@selected_agent)} class="empty-state">
            <span class="lamp idle"></span>
            <p>NO AGENT SELECTED</p>
            <p class="muted">
              Definitions are discovered under the configured agents directory.
            </p>
          </div>

          <header :if={@selected_agent} class="insp-head on-dark">
            <div class="kicker">
              <span class="sel">SEL {channel_index(@agents, @selected_agent.agent_id)}</span>
              <span class="kind">{lifecycle_label(@selected_agent.lifecycle_kind)}</span>
              <span class="run-meta">
                RUN <b>{short_run_id(@selected_agent.run_id)}</b>
                · ATT <b>{@selected_agent.attempt_ordinal || "—"}</b>
              </span>
            </div>
            <div class="insp-title">
              <h2>{@selected_agent.agent_id}</h2>
              <span class={"state-pill state-#{@selected_agent.status}"}>
                {status_label(@selected_agent.status)}
              </span>
            </div>
            <div class="transport">
              <button
                class="btn"
                type="button"
                phx-click="start"
                phx-value-id={@selected_agent.agent_id}
                disabled={pending_agent_id(@pending) == @selected_agent.agent_id or @selected_agent.status in [:running, :starting, :stopping]}
              >
                START
              </button>
              <button
                class="btn btn-fail"
                type="button"
                phx-click="stop"
                phx-value-id={@selected_agent.agent_id}
                disabled={pending_agent_id(@pending) == @selected_agent.agent_id or @selected_agent.status in [:stopped, :stopping]}
              >
                STOP
              </button>
              <a class="btn" href={~p"/config/#{@selected_agent.agent_id}"}>DEFINITION</a>
            </div>
          </header>

          <section :if={@selected_agent} class="context" aria-label="Context">
            <div class="ctx-head">
              <span class="label">CONTEXT</span>
              <span class="ctx-tokens">{policy_summary(@selected_agent.definition)}</span>
              <span class="ctx-pct">
                {elem(context_count(@selected_agent.definition), 0)}<span>/3</span>
              </span>
            </div>
            <div class="ctx-meter">
              <span class="fill" style={"width:#{context_percent(@selected_agent.definition)}%"}></span>
            </div>
            <div class="ctx-meta">
              <span>REV <b>{@selected_agent.definition_revision || Map.get(@selected_agent, :registry_revision) || "—"}</b></span>
              <span>BUDGET TOK <b>{budget_label(@selected_agent.definition)}</b></span>
              <span>EVENTS <b>{length(@events)}</b></span>
              <span>TOOLS <b>{length(@history)}</b></span>
            </div>
          </section>

          <section :if={@selected_agent} class="stream" aria-label="Run stream">
            <header class="panel-head">
              <h3>STREAM <span>{length(@stream)}</span></h3>
              <span class="panel-meta">
                <span class={"lamp #{status_lamp(@selected_agent.status)}"}></span>
                {status_label(@selected_agent.status)} · RUN {short_run_id(@selected_agent.run_id)}
              </span>
            </header>

            <div class="stream-cols" aria-hidden="true">
              <span>TIME</span>
              <span>TYPE</span>
              <span>DETAIL</span>
            </div>

            <ol
              id="stream-list"
              class="stream-list"
              aria-live="polite"
              phx-hook="PatchbayStream"
              data-stream-agent={@selected_agent.agent_id}
            >
              <li :for={item <- @stream} :key={item.id} class={row_class(item)}>
                <time class="row-time">{item.time}</time>
                <span class="row-type">{row_type(item)}</span>
                <div class="row-body">
                  <details
                    :if={item.kind == :event}
                    id={"event-detail-#{@selected_agent.agent_id}-#{item.id}"}
                    class="event-details"
                    phx-hook="PatchbayDetails"
                  >
                    <summary class="event-summary">
                      <span class="event-label">{item.label}</span>
                      <span :if={item.preview != ""} class="event-preview">{item.preview}</span>
                    </summary>
                    <div :if={item.detail != ""} class="event-detail">{item.detail}</div>
                  </details>
                  <div :if={item.kind == :chat} class="chat-body">
                    <p class="chat-text">{item.text}</p>
                    <span :if={item.meta} class="chat-meta">{item.meta}</span>
                  </div>
                  <div :if={item.kind == :tool} class="tool-grid">
                    <span class="tool-name">{item.name}</span>
                    <span class="tool-target">{item.target}</span>
                    <span class="tool-src">{item.src}</span>
                    <span class="tool-state">{item.status}</span>
                    <span class="tool-dur"></span>
                  </div>
                  <div :if={item.kind == :tool and item.terminal} class="tool-terminal">
                    <span class="tool-action">{item.action}</span>
                    <pre class="tool-result">{item.result}</pre>
                  </div>
                </div>
              </li>
              <li :if={@stream_delta} class="stream-row row-event row-delta">
                <time class="row-time">LIVE</time>
                <span class="row-type">DELTA</span>
                <div class="row-body">
                  <span class="event-text delta-text">{@stream_delta}</span>
                </div>
              </li>
            </ol>

            <div :if={@stream == [] and is_nil(@stream_delta)} class="empty-state inline">
              <p>NO EVENTS</p>
              <p class="muted">Start this agent to record runtime activity.</p>
            </div>
          </section>

          <footer :if={@selected_agent} class="composer">
            <div class="dest">
              <span class="label">DESTINATION</span>
              <span class="dest-select">
                {@selected_agent.agent_id} <b>{destination_label(@selected_agent)}</b>
              </span>
            </div>
            <form id="message-composer" class="input-row" phx-submit="send" phx-change="draft">
              <input
                type="text"
                name="message[content]"
                value={@draft}
                placeholder={"Message #{@selected_agent.agent_id}..."}
                aria-label={"Message #{@selected_agent.agent_id}"}
                autocomplete="off"
                disabled={not is_nil(@pending)}
              />
              <button class="send" type="submit" disabled={not is_nil(@pending)}>
                SEND
              </button>
              <button
                class="send"
                type="button"
                phx-click="steer"
                disabled={not is_nil(@pending) or @selected_agent.status != :running}
              >
                STEER
              </button>
            </form>
            <div class="composer-foot">
              <span>ATTEMPT <b>{@selected_agent.attempt_ordinal || "—"}</b> · MODEL <b>{@selected_agent.model || "—"}</b></span>
              <span>
                ACTIVITY <b>{activity_label(activity_value(@activity, @selected_agent))}</b>
                · QUEUE <b>{@pending_messages}</b>
              </span>
              <span>MESSAGES <b>{@message_count}</b> · WORKER <b>{@selected_agent.worker_id || "—"}</b></span>
            </div>
          </footer>
        </aside>
      </main>
    </div>
    """
  end
end
