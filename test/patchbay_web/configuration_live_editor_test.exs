defmodule PatchbayWeb.ConfigurationLiveEditorTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Patchbay.DefinitionRegistry

  @endpoint PatchbayWeb.Endpoint

  setup do
    root = Path.join(System.tmp_dir!(), "patchbay-editor-#{System.unique_integer([:positive])}")
    config_dir = Path.join(root, "config")

    for id <- ["researcher", "writer"] do
      agent_dir = Path.join([config_dir, "agents", id])
      File.mkdir_p!(Path.join(agent_dir, "prompts"))
      File.write!(Path.join(agent_dir, "agent.toml"), agent_body(id, "model-a"))
    end

    File.mkdir_p!(Path.join(config_dir, "toolkits"))
    File.write!(Path.join([config_dir, "toolkits", "http.toml"]), "name = \"http\"\n")

    start_supervised!({DefinitionRegistry, name: DefinitionRegistry, config_dir: config_dir})

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok,
     conn: PatchbayWeb.AuthTestHelper.authenticated_conn(),
     config_dir: config_dir,
     researcher_path: Path.join([config_dir, "agents", "researcher", "agent.toml"]),
     writer_path: Path.join([config_dir, "agents", "writer", "agent.toml"])}
  end

  test "clicking the selected definition does not reset an unsaved draft", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/config/researcher")

    draft = agent_body("researcher", "model-draft")

    view
    |> form("form[phx-submit='save']", %{"source" => draft})
    |> render_change()

    assert has_element?(view, ".source-dirty", "UNSAVED CHANGES")

    html =
      view
      |> element("li[phx-value-id='researcher']")
      |> render_click()

    assert html =~ "model-draft"
    assert html =~ "UNSAVED CHANGES"
  end

  test "a reload broadcast keeps an unsaved draft", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/config/researcher")

    draft = agent_body("researcher", "model-draft")

    view
    |> form("form[phx-submit='save']", %{"source" => draft})
    |> render_change()

    Phoenix.PubSub.broadcast(Patchbay.PubSub, "config", {:config, :reloaded})
    html = render(view)

    assert html =~ "model-draft"
    assert html =~ "UNSAVED CHANGES"
  end

  test "selecting another definition while dirty asks before discarding", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/config/researcher")

    draft = agent_body("researcher", "model-draft")

    view
    |> form("form[phx-submit='save']", %{"source" => draft})
    |> render_change()

    html =
      view
      |> element("li[phx-value-id='writer']")
      |> render_click()

    assert html =~ "Discard unsaved changes to researcher?"
    assert html =~ "model-draft"
    refute_patched(view)

    html = render_click(view, "cancel_select")
    refute html =~ "Discard unsaved changes"
    assert html =~ "model-draft"

    view |> element("li[phx-value-id='writer']") |> render_click()
    html = render_click(view, "confirm_select")

    assert_patch(view, "/config/writer")
    assert html =~ "model-a"
    refute html =~ "model-draft"
    refute html =~ "UNSAVED CHANGES"
  end

  test "a route change with unsaved edits discards them and says so", %{
    conn: conn,
    writer_path: writer_path
  } do
    {:ok, view, _html} = live(conn, "/config/researcher")

    draft = agent_body("researcher", "model-draft")

    view
    |> form("form[phx-submit='save']", %{"source" => draft})
    |> render_change()

    html = render_patch(view, "/config/writer")

    assert html =~ "Discarded unsaved changes to researcher."
    assert html =~ "model-a"
    refute html =~ "model-draft"
    assert File.read!(writer_path) == agent_body("writer", "model-a")
  end

  test "a dirty draft is still saved against the loaded revision", %{
    conn: conn,
    researcher_path: researcher_path
  } do
    {:ok, view, _html} = live(conn, "/config/researcher")

    original = File.read!(researcher_path)
    draft = agent_body("researcher", "model-draft")

    view
    |> form("form[phx-submit='save']", %{"source" => draft})
    |> render_change()

    html =
      view
      |> form("form[phx-submit='save']", %{"source" => draft})
      |> render_submit()

    assert html =~ "Source saved"
    assert File.read!(researcher_path) == draft
    refute original == draft
  end

  test "a save after an external change reports a conflict instead of overwriting", %{
    conn: conn,
    researcher_path: researcher_path
  } do
    {:ok, view, _html} = live(conn, "/config/researcher")

    draft = agent_body("researcher", "model-draft")

    view
    |> form("form[phx-submit='save']", %{"source" => draft})
    |> render_change()

    external = agent_body("researcher", "external-model")
    File.write!(researcher_path, external)

    html =
      view
      |> form("form[phx-submit='save']", %{"source" => draft})
      |> render_submit()

    assert html =~ "Save conflict"
    assert File.read!(researcher_path) == external
  end

  test "the editor shows no implementation narration", %{conn: conn} do
    {:ok, view, html} = live(conn, "/config/researcher")

    refute html =~ "ATOMIC REPLACE"
    refute html =~ "STALE WRITES"
    refute html =~ ">agent.toml source<"
    refute html =~ "sr-only"
    assert has_element?(view, "textarea[name='source'][aria-label='agent.toml source']")
  end

  test "an explicit reload re-reads the source from disk", %{
    conn: conn,
    researcher_path: researcher_path
  } do
    {:ok, view, _html} = live(conn, "/config/researcher")

    draft = agent_body("researcher", "model-draft")

    view
    |> form("form[phx-submit='save']", %{"source" => draft})
    |> render_change()

    external = agent_body("researcher", "external-model")
    File.write!(researcher_path, external)

    html = render_click(view, "reload")

    assert html =~ "external-model"
    refute html =~ "model-draft"
    refute html =~ "UNSAVED CHANGES"
  end

  defp agent_body(id, model) do
    """
    format-version = 1
    id = "#{id}"

    [model]
    name = "#{model}"

    [lifecycle]
    kind = "one-shot"
    """
  end
end
