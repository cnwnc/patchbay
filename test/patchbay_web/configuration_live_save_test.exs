defmodule PatchbayWeb.ConfigurationLiveSaveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Patchbay.Config.Source
  alias Patchbay.DefinitionRegistry

  @endpoint PatchbayWeb.Endpoint

  setup do
    root = Path.join(System.tmp_dir!(), "patchbay-save-#{System.unique_integer([:positive])}")
    config_dir = Path.join(root, "config")
    agent_dir = Path.join([config_dir, "agents", "researcher"])

    File.mkdir_p!(Path.join(agent_dir, "prompts"))
    File.mkdir_p!(Path.join(config_dir, "toolkits"))
    File.write!(Path.join([config_dir, "toolkits", "http.toml"]), "name = \"http\"\n")
    File.write!(Path.join(agent_dir, "agent.toml"), agent_body("researcher", "model-a"))

    start_supervised!({DefinitionRegistry, name: DefinitionRegistry, config_dir: config_dir})

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok,
     conn: build_conn(),
     config_dir: config_dir,
     agent_dir: agent_dir,
     path: source_path(agent_dir)}
  end

  test "saving valid source replaces the file and reloads the definition", %{
    conn: conn,
    path: path
  } do
    {:ok, view, _html} = live(conn, "/config")

    original = File.read!(path)
    updated = agent_body("researcher", "model-b")

    html =
      view
      |> form("form[phx-submit='save']", %{"source" => updated})
      |> render_submit()

    assert html =~ "Source saved"
    refute original == updated
    assert File.read!(path) == updated

    assert {:ok, snapshot} = DefinitionRegistry.get("researcher")
    assert snapshot.revision == 2
    assert snapshot.definition.model.name == "model-b"
  end

  test "a stale expected hash shows a conflict and leaves the file alone", %{
    conn: conn,
    path: path
  } do
    {:ok, view, _html} = live(conn, "/config")

    original = File.read!(path)
    stale_hash = Source.hash(original)
    external = agent_body("researcher", "external-model")
    File.write!(path, external)

    html =
      render_submit(view, "save", %{
        "source" => agent_body("researcher", "mine"),
        "expected_hash" => stale_hash
      })

    assert html =~ "Save conflict"
    assert File.read!(path) == external

    assert {:ok, snapshot} = DefinitionRegistry.get("researcher")
    assert snapshot.revision == 1
    assert snapshot.definition.model.name == "model-a"
  end

  test "an invalid source is saved, reported, and leaves the last good definition active", %{
    conn: conn,
    path: path
  } do
    {:ok, view, _html} = live(conn, "/config")

    original = File.read!(path)
    invalid = String.replace(original, "format-version = 1", "format-version = 2")

    html =
      render_submit(view, "save", %{
        "source" => invalid,
        "expected_hash" => Source.hash(original)
      })

    assert File.read!(path) == invalid
    assert html =~ "VALIDATION FAILURE"
    assert html =~ "last good definition remains active"

    assert {:ok, snapshot} = DefinitionRegistry.get("researcher")
    assert snapshot.revision == 1
    assert snapshot.definition.model.name == "model-a"

    assert [failure] = DefinitionRegistry.errors()
    assert failure.id == "researcher"
  end

  test "redacted sources cannot be edited or overwritten with redacted text", %{
    conn: conn,
    path: path
  } do
    secret_source = secret_agent_body("researcher")
    File.write!(path, secret_source)

    assert {:ok, report} = DefinitionRegistry.reload()
    assert Enum.any?(report.loaded, &(&1.id == "researcher"))

    {:ok, view, html} = live(conn, "/config")

    assert html =~ "Editing is disabled"
    refute html =~ "sk-live-raw-value"
    refute has_element?(view, "form[phx-submit='save']")

    html =
      render_submit(view, "save", %{
        "source" => String.replace(secret_source, "sk-live-raw-value", "[REDACTED]"),
        "expected_hash" => Source.hash(secret_source)
      })

    assert html =~ "Save refused"
    assert File.read!(path) == secret_source
  end

  test "the form carries the loaded source hash", %{conn: conn, path: path} do
    {:ok, view, _html} = live(conn, "/config")

    assert has_element?(view, "form[phx-submit='save']")

    assert has_element?(
             view,
             "form[phx-submit='save'] input[name='expected_hash'][value='#{Source.hash(File.read!(path))}']"
           )

    assert has_element?(view, "form[phx-submit='save'] textarea[name='source']")
  end

  defp source_path(agent_dir), do: Path.join(agent_dir, "agent.toml")

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

  defp secret_agent_body(id) do
    """
    format-version = 1
    id = "#{id}"

    [model]
    name = "model-a"

    [lifecycle]
    kind = "one-shot"

    [context]
    between-runs = "prompt"

    [[toolkits]]
    toolkit = "http"

    [toolkits.config]
    api-key = "sk-live-raw-value"
    token-ref = "${PATCHBAY_TOKEN}"
    """
  end
end
