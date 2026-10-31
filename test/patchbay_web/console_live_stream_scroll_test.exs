defmodule PatchbayWeb.ConsoleLiveStreamScrollTest.FakeRuntime do
  @moduledoc false

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Patchbay.Runtime)

  @impl true
  def init(opts) do
    {:ok,
     %{
       summaries: Keyword.fetch!(opts, :summaries),
       events: Keyword.get(opts, :events, %{})
     }}
  end

  @impl true
  def handle_call(:list_agents, _from, state), do: {:reply, {:ok, state.summaries}, state}

  def handle_call({:get_agent, agent_id}, _from, state) do
    case Enum.find(state.summaries, &(&1.agent_id == agent_id)) do
      nil -> {:reply, {:error, :not_found}, state}
      summary -> {:reply, {:ok, summary}, state}
    end
  end

  def handle_call({:subscribe, _pid}, _from, state), do: {:reply, :ok, state}

  def handle_call({:list_events, agent_id}, _from, state),
    do: {:reply, {:ok, Map.get(state.events, agent_id, [])}, state}

  def handle_call({:tool_history, _agent_id}, _from, state), do: {:reply, {:ok, []}, state}

  def handle_call({:messages, _agent_id}, _from, state), do: {:reply, {:ok, []}, state}

  def handle_call({:activity, agent_id}, _from, state) do
    case Enum.find(state.summaries, &(&1.agent_id == agent_id)) do
      nil -> {:reply, {:ok, %{}}, state}
      summary -> {:reply, {:ok, %{activity: summary.activity, pending_messages: 0}}, state}
    end
  end

  def handle_call(_other, _from, state), do: {:reply, {:ok, nil}, state}
end

defmodule PatchbayWeb.ConsoleLiveStreamScrollTest do
  @moduledoc """
  Markup-level coverage for the stream autoscroll/pinning contract.

  The pinning behavior itself is implemented in the `PatchbayStream` hook
  inside the root layout (`PatchbayWeb.Layouts`), so these tests pin down the
  markup the hook depends on plus the shape of the shipped hook source. The
  runtime contract is:

    * `pinned` starts true on mount.
    * Only user scroll events (and an upward wheel that can actually scroll)
      flip `pinned`; arriving at the bottom edge repins, scrolling away
      unpins. LiveView runs of `updated()`/`beforeUpdate()` never recompute it.
    * While pinned, every LiveView update schedules one rAF pass that scrolls
      back to the bottom, and a ResizeObserver on the list and on each row
      scrolls back to the bottom after any post-layout height change (row
      growth, `<details>` expansion, viewport resize).
    * `data-stream-agent` on the list identifies the rendered agent; when it
      changes, the hook re-pins to the bottom.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Patchbay.DefinitionRegistry
  alias PatchbayWeb.ConsoleLiveStreamScrollTest.FakeRuntime

  @endpoint PatchbayWeb.Endpoint

  setup do
    root =
      Path.join(System.tmp_dir!(), "patchbay-web-scroll-#{System.unique_integer([:positive])}")

    config_dir = Path.join(root, "config")

    for agent_id <- ["researcher", "worker"] do
      agent_dir = Path.join([config_dir, "agents", agent_id])
      File.mkdir_p!(Path.join(agent_dir, "prompts"))

      File.write!(Path.join(agent_dir, "agent.toml"), """
      format-version = 1
      id = "#{agent_id}"

      [model]
      name = "test-model"

      [lifecycle]
      kind = "perpetual"

      [context]
      between-runs = "prompt"
      """)

      File.write!(Path.join(agent_dir, "prompts/00-main.md"), "Agent prompt")
    end

    start_supervised!({DefinitionRegistry, name: DefinitionRegistry, config_dir: config_dir})

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, conn: PatchbayWeb.AuthTestHelper.authenticated_conn()}
  end

  defp start_fake!(summaries, opts \\ []) do
    spec =
      Supervisor.child_spec(
        {FakeRuntime, Keyword.merge(opts, summaries: summaries)},
        id: {:fake_runtime, System.unique_integer([:positive])}
      )

    start_supervised!(spec)
  end

  test "stream list is wired to the pinning hook and ships the pinning client", %{conn: conn} do
    start_fake!([summary("researcher")])
    {:ok, _view, html} = live(conn, "/")

    assert html =~
             ~s(hooks: {PatchbayFlash, PatchbayStream, PatchbaySelection, PatchbayDetails, PatchbayClock})

    assert html =~ ~s{id="stream-list"}
    assert html =~ ~s{phx-hook="PatchbayStream"}
    assert html =~ ~s{data-stream-agent="researcher"}

    # Pinning state is tracked from scroll events, not recomputed around
    # LiveView updates.
    assert html =~ "addEventListener(\"scroll\", this.onScroll, {passive: true})"
    assert html =~ "this.pinned = this.atBottom()"
    refute html =~ "beforeUpdate"

    # Height changes are handled after layout, both per update and per row.
    assert html =~ "new ResizeObserver"
    assert html =~ "requestAnimationFrame(() => this.sync())"
    assert html =~ "addEventListener(\"wheel\", this.onWheel, {passive: true})"
  end

  test "the stream list disables native scroll anchoring so the hook owns the offset" do
    conn = get(build_conn(), "/assets/app.css")
    assert conn.status == 200
    assert conn.resp_body =~ "overflow-anchor: none"
  end

  test "switching agents retargets the stream to the newly selected agent", %{conn: conn} do
    start_fake!([summary("researcher"), summary("worker")])
    {:ok, view, html} = live(conn, "/")

    assert html =~ ~s{data-stream-agent="researcher"}
    refute html =~ ~s{data-stream-agent="worker"}

    view |> element("li[phx-value-id='worker']") |> render_click()

    rendered = render(view)
    assert rendered =~ ~s{data-stream-agent="worker"}
    refute rendered =~ ~s{data-stream-agent="researcher"}
    assert rendered =~ ~s{id="stream-list" class="stream-list"}
  end

  test "event rows keep the details-open hook across stream updates", %{conn: conn} do
    start_fake!([summary("researcher")],
      events: %{
        "researcher" => [
          %Patchbay.Event{
            id: "hook-failed-1",
            sequence: 1,
            at: DateTime.to_iso8601(DateTime.utc_now()),
            type: :hook_failed,
            agent_id: "researcher",
            data: %{"phase" => "pre", "hook" => "tool-filter", "reason" => "beam kaboom"}
          }
        ]
      }
    )

    {:ok, view, html} = live(conn, "/")

    assert html =~ ~s{phx-hook="PatchbayDetails"}
    assert html =~ ~s{id="event-detail-researcher-hook-failed-1"}

    send(
      view.pid,
      {:patchbay_event, %{type: :model_delta, agent_id: "researcher", data: %{delta: "live "}}}
    )

    rendered = render(view)
    assert rendered =~ "live "
    assert rendered =~ ~s{phx-hook="PatchbayDetails"}
    assert rendered =~ ~s{id="event-detail-researcher-hook-failed-1"}
    assert rendered =~ ~s{phx-hook="PatchbayStream"}
  end

  defp summary(agent_id) do
    %{
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
  end
end
