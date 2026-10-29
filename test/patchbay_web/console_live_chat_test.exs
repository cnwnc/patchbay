defmodule PatchbayWeb.ConsoleLiveChatTest.FakeRuntime do
  @moduledoc false

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Patchbay.Runtime)

  def calls(server), do: GenServer.call(server, :calls)

  @impl true
  def init(opts) do
    {:ok, %{summary: Keyword.fetch!(opts, :summary), messages: [], calls: []}}
  end

  @impl true
  def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

  def handle_call(:list_agents, _from, state) do
    {:reply, {:ok, [state.summary]}, record(state, :list_agents)}
  end

  def handle_call({:get_agent, agent_id}, _from, state) do
    if agent_id == state.summary.agent_id do
      {:reply, {:ok, state.summary}, record(state, {:get_agent, agent_id})}
    else
      {:reply, {:error, :not_found}, record(state, {:get_agent, agent_id})}
    end
  end

  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, record(state, {:subscribe, pid})}
  end

  def handle_call({:set_summary, summary}, _from, state) do
    {:reply, :ok, %{state | summary: summary}}
  end

  def handle_call({:start_agent, agent_id, opts}, _from, state) do
    summary =
      state.summary
      |> Map.put(:status, :running)
      |> Map.put(:activity, :thinking)
      |> Map.put(:run_id, "run-2")
      |> Map.put(:run_status, :running)

    {:reply, {:ok, summary}, record(%{state | summary: summary}, {:start_agent, agent_id, opts})}
  end

  def handle_call({:stop_agent, agent_id, opts}, _from, state) do
    summary = %{state.summary | status: :stopped, activity: :idle, run_status: :cancelled}
    {:reply, {:ok, summary}, record(%{state | summary: summary}, {:stop_agent, agent_id, opts})}
  end

  def handle_call({:send_message, agent_id, content, opts}, _from, state) do
    summary = %{state.summary | activity: :thinking, pending_messages: 1}

    {:reply, {:ok, summary},
     record(%{state | summary: summary}, {:send_message, agent_id, content, opts})}
  end

  def handle_call({:steer, agent_id, content, opts}, _from, state) do
    summary = %{state.summary | activity: :thinking, pending_messages: 1}

    {:reply, {:ok, summary},
     record(%{state | summary: summary}, {:steer, agent_id, content, opts})}
  end

  def handle_call({:activity, agent_id}, _from, state) do
    summary = state.summary

    reply =
      {:ok,
       %{
         agent_id: agent_id,
         status: summary.status,
         activity: summary.activity,
         run_status: summary.run_status,
         pending_messages: summary.pending_messages,
         message_count: summary.message_count
       }}

    {:reply, reply, record(state, {:activity, agent_id})}
  end

  def handle_call({:messages, agent_id}, _from, state) do
    {:reply, {:ok, state.messages}, record(state, {:messages, agent_id})}
  end

  def handle_call({:list_events, agent_id}, _from, state) do
    {:reply, {:ok, []}, record(state, {:list_events, agent_id})}
  end

  def handle_call({:tool_history, agent_id}, _from, state) do
    {:reply, {:ok, []}, record(state, {:tool_history, agent_id})}
  end

  defp record(state, call), do: %{state | calls: [call | state.calls]}
end

defmodule PatchbayWeb.ConsoleLiveChatTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Patchbay.DefinitionRegistry
  alias PatchbayWeb.ConsoleLiveChatTest.FakeRuntime

  @endpoint PatchbayWeb.Endpoint

  setup do
    root = Path.join(System.tmp_dir!(), "patchbay-web-chat-#{System.unique_integer([:positive])}")
    config_dir = Path.join(root, "config")
    state_dir = Path.join(root, "state")
    agent_dir = Path.join([config_dir, "agents", "researcher"])

    File.mkdir_p!(Path.join(agent_dir, "prompts"))
    File.mkdir_p!(state_dir)

    File.write!(Path.join(agent_dir, "agent.toml"), """
    format-version = 1
    id = "researcher"

    [model]
    name = "test-model"

    [lifecycle]
    kind = "perpetual"

    [context]
    between-runs = "prompt"
    """)

    File.write!(Path.join(agent_dir, "prompts/00-main.md"), "Agent prompt")

    start_supervised!({DefinitionRegistry, name: DefinitionRegistry, config_dir: config_dir})

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, conn: PatchbayWeb.AuthTestHelper.authenticated_conn()}
  end

  test "send submits a message through Runtime.send_message", %{conn: conn} do
    runtime = start_fake(summary("researcher", activity: :waiting))
    {:ok, view, html} = live(conn, "/")

    assert html =~ "DESTINATION"
    assert html =~ "STEER"
    assert html =~ "WAITING"

    view
    |> form("form.input-row", message: %{content: "hello there"})
    |> render_submit()

    assert eventually(fn ->
             Enum.any?(FakeRuntime.calls(runtime), fn
               {:send_message, "researcher", "hello there", _opts} -> true
               _call -> false
             end)
           end)

    assert render(view) =~ "Sent message to researcher."
  end

  test "steer submits the draft through Runtime.steer", %{conn: conn} do
    runtime = start_fake(summary("researcher", activity: :waiting))
    {:ok, view, _html} = live(conn, "/")

    changed =
      view
      |> form("form.input-row", message: %{content: "stay on target"})
      |> render_change()

    assert changed =~ ~s(value="stay on target")

    view |> element("button[phx-click='steer']") |> render_click()

    assert eventually(fn ->
             Enum.any?(FakeRuntime.calls(runtime), fn
               {:send_message, "researcher", "stay on target", _opts} -> true
               _call -> false
             end)
           end)

    assert render(view) =~ "Steered researcher."
  end

  test "send starts a stopped agent with the message as the initial turn", %{conn: conn} do
    runtime = start_fake(summary("researcher", status: :stopped, activity: :idle))
    {:ok, view, html} = live(conn, "/")

    assert html =~ "NEXT RUN"

    view
    |> form("form.input-row", message: %{content: "begin work"})
    |> render_submit()

    assert eventually(fn ->
             {:start_agent, "researcher", [message: "begin work"]} in FakeRuntime.calls(runtime)
           end)
  end

  test "renders the accumulated live text delta for the selected agent", %{conn: conn} do
    _runtime = start_fake(summary("researcher", stream_text: "partial answer"))
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "DELTA"
    assert html =~ "partial answer"
  end

  test "appends stream delta events without duplicating them into the event list", %{conn: conn} do
    _runtime = start_fake(summary("researcher", activity: :thinking))
    {:ok, view, html} = live(conn, "/")

    refute html =~ "live text"

    send(
      view.pid,
      {:patchbay_event, %{type: :model_delta, agent_id: "researcher", data: %{delta: "live "}}}
    )

    send(
      view.pid,
      {:patchbay_event, %{type: :model_delta, agent_id: "researcher", data: %{delta: "text"}}}
    )

    assert eventually(fn -> render(view) =~ "live text" end)
    assert render(view) =~ "DELTA"
  end

  test "reloads and resubscribes when the Runtime process is replaced", %{conn: conn} do
    first = start_fake(summary("researcher", activity: :waiting))
    {:ok, view, html} = live(conn, "/")

    assert html =~ "researcher"
    refute html =~ "successor"

    :ok = GenServer.stop(first)
    _second = start_fake(summary("successor", activity: :waiting))

    assert eventually(fn -> render(view) =~ "successor" end, 100)
  end

  test "reloads agents and selection when the Runtime list changes", %{conn: conn} do
    runtime = start_fake(summary("researcher", activity: :waiting))
    {:ok, view, html} = live(conn, "/")

    assert html =~ "researcher"

    :ok = GenServer.call(runtime, {:set_summary, summary("successor", activity: :waiting)})
    send(view.pid, :tick)

    assert eventually(fn -> render(view) =~ "successor" end)
    refute render(view) =~ "researcher"
  end

  defp start_fake(summary) do
    spec =
      Supervisor.child_spec({FakeRuntime, summary: summary},
        id: {:fake_runtime, System.unique_integer([:positive])},
        restart: :temporary
      )

    start_supervised!(spec)
  end

  defp summary(agent_id, overrides) do
    defaults = %{
      agent_id: agent_id,
      status: :running,
      activity: :waiting,
      definition_revision: 1,
      lifecycle_kind: :perpetual,
      model: "test-model",
      toolkit_ids: [],
      tools: [],
      worker_id: "worker-#{agent_id}",
      run_id: "run-#{agent_id}",
      run_status: :waiting,
      attempt_id: "attempt-#{agent_id}",
      attempt_ordinal: 1,
      instance_id: "instance-#{agent_id}",
      message_count: 2,
      pending_messages: 0,
      result: nil,
      failure: nil,
      started_at: nil,
      stopped_at: nil,
      last_error: nil
    }

    Map.merge(defaults, Map.new(overrides))
  end

  defp eventually(fun, attempts \\ 60) do
    Enum.reduce_while(1..attempts, false, fn _attempt, _acc ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(25)
        {:cont, false}
      end
    end)
  end
end
