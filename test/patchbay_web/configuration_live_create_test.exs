defmodule PatchbayWeb.ConfigurationLiveCreateTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Patchbay.Config.Source
  alias Patchbay.DefinitionRegistry

  @endpoint PatchbayWeb.Endpoint

  setup do
    root = Path.join(System.tmp_dir!(), "patchbay-create-#{System.unique_integer([:positive])}")
    config_dir = Path.join(root, "config")

    File.mkdir_p!(Path.join(config_dir, "agents"))
    File.mkdir_p!(Path.join(config_dir, "toolkits"))

    start_supervised!({DefinitionRegistry, name: DefinitionRegistry, config_dir: config_dir})
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, conn: PatchbayWeb.AuthTestHelper.authenticated_conn(), config_dir: config_dir}
  end

  test "creates a new agent and navigates to it", %{conn: conn, config_dir: config_dir} do
    {:ok, view, html} = live(conn, "/config")

    assert html =~ "NEW AGENT"

    render_click(view, "new_agent")
    assert has_element?(view, "form[phx-submit='create_agent'] input[name='agent_id']")

    view
    |> form("form[phx-submit='create_agent']", %{
      "agent_id" => "new-agent",
      "lifecycle" => "perpetual"
    })
    |> render_submit()

    assert_patch(view, "/config/new-agent")

    agent_dir = Path.join([config_dir, "agents", "new-agent"])
    source_path = Path.join(agent_dir, "agent.toml")

    assert File.read!(source_path) == Source.template("new-agent", "perpetual")
    assert File.dir?(Path.join(agent_dir, "prompts"))

    assert {:ok, snapshot} = DefinitionRegistry.get("new-agent")
    assert snapshot.definition.lifecycle.kind == :perpetual
    assert snapshot.definition.model.name == "default"

    html = render(view)
    assert html =~ "new-agent"
    assert html =~ "PERPETUAL"
    assert html =~ "Created agent new-agent"
  end

  test "an existing agent ID is rejected without overwriting", %{
    conn: conn,
    config_dir: config_dir
  } do
    agent_dir = Path.join([config_dir, "agents", "researcher"])
    File.mkdir_p!(Path.join(agent_dir, "prompts"))
    existing = Source.template("researcher", "one-shot")
    File.write!(Path.join(agent_dir, "agent.toml"), existing)

    assert {:ok, _report} = DefinitionRegistry.reload()

    {:ok, view, _html} = live(conn, "/config")
    render_click(view, "new_agent")

    html =
      view
      |> form("form[phx-submit='create_agent']", %{
        "agent_id" => "researcher",
        "lifecycle" => "perpetual"
      })
      |> render_submit()

    assert html =~ "already exists"
    assert File.read!(Path.join(agent_dir, "agent.toml")) == existing
    assert {:ok, snapshot} = DefinitionRegistry.get("researcher")
    assert snapshot.definition.lifecycle.kind == :one_shot
  end

  test "an invalid agent ID is rejected", %{conn: conn, config_dir: config_dir} do
    {:ok, view, _html} = live(conn, "/config")
    render_click(view, "new_agent")

    html =
      view
      |> form("form[phx-submit='create_agent']", %{
        "agent_id" => "Not Simple",
        "lifecycle" => "one-shot"
      })
      |> render_submit()

    assert html =~ "Create failed"
    assert html =~ "lowercase ID"
    refute File.exists?(Path.join([config_dir, "agents", "Not Simple"]))
    assert DefinitionRegistry.list() == []
  end

  test "a blank agent.toml is listed and can be repaired from the editor", %{
    conn: conn,
    config_dir: config_dir
  } do
    agent_dir = Path.join([config_dir, "agents", "blank"])
    File.mkdir_p!(Path.join(agent_dir, "prompts"))
    File.write!(Path.join(agent_dir, "agent.toml"), "")

    assert {:ok, _report} = DefinitionRegistry.reload()
    assert [%{id: "blank"}] = DefinitionRegistry.errors()

    {:ok, view, html} = live(conn, "/config/blank")

    assert html =~ "VALIDATION FAILURE"
    assert html =~ "RESOLVED"
    assert has_element?(view, "form[phx-submit='save'] textarea[name='source']")

    repaired = Source.template("blank", "one-shot")

    html =
      view
      |> form("form[phx-submit='save']", %{"source" => repaired})
      |> render_submit()

    assert html =~ "Source saved"
    assert File.read!(Path.join(agent_dir, "agent.toml")) == repaired

    assert {:ok, snapshot} = DefinitionRegistry.get("blank")
    assert snapshot.definition.id == "blank"
    assert DefinitionRegistry.errors() == []
  end

  test "a directory without agent.toml is surfaced and its source can be created", %{
    conn: conn,
    config_dir: config_dir
  } do
    agent_dir = Path.join([config_dir, "agents", "repair"])
    File.mkdir_p!(agent_dir)

    assert {:ok, _report} = DefinitionRegistry.reload()
    assert [%{id: "repair", error: error}] = DefinitionRegistry.errors()
    assert inspect(error) =~ "agent.toml is missing"

    {:ok, view, html} = live(conn, "/config/repair")

    assert html =~ "invalid definition"
    assert html =~ "VALIDATION FAILURE"

    assert has_element?(
             view,
             "form[phx-submit='save'] input[name='expected_hash'][value='absent']"
           )

    created = Source.template("repair", "one-shot")

    html =
      view
      |> form("form[phx-submit='save']", %{"source" => created})
      |> render_submit()

    assert html =~ "Source saved"
    assert File.read!(Path.join(agent_dir, "agent.toml")) == created
    assert {:ok, _snapshot} = DefinitionRegistry.get("repair")
    assert DefinitionRegistry.errors() == []
  end
end
