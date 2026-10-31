defmodule PatchbayWeb.ConfigurationLiveStructuredTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Patchbay.DefinitionRegistry

  @endpoint PatchbayWeb.Endpoint

  setup do
    root =
      Path.join(System.tmp_dir!(), "patchbay-structured-#{System.unique_integer([:positive])}")

    config_dir = Path.join(root, "config")

    researcher_dir = Path.join([config_dir, "agents", "researcher"])
    File.mkdir_p!(Path.join(researcher_dir, "prompts"))
    File.write!(Path.join(researcher_dir, "agent.toml"), agent_body())

    blank_dir = Path.join([config_dir, "agents", "blank"])
    File.mkdir_p!(Path.join(blank_dir, "prompts"))
    File.write!(Path.join(blank_dir, "agent.toml"), "")

    File.mkdir_p!(Path.join(config_dir, "toolkits"))
    File.write!(Path.join([config_dir, "toolkits", "ops.toml"]), ops_manifest())

    start_supervised!({DefinitionRegistry, name: DefinitionRegistry, config_dir: config_dir})
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok,
     conn: PatchbayWeb.AuthTestHelper.authenticated_conn(),
     config_dir: config_dir,
     path: Path.join(researcher_dir, "agent.toml")}
  end

  test "the structured tab edits an existing definition and preserves comments", %{
    conn: conn,
    path: path
  } do
    {:ok, view, _html} = live(conn, "/config/researcher")

    refute has_element?(view, "#structured-form")

    view |> element("button[phx-value-tab='structured']") |> render_click()

    assert has_element?(view, "#structured-form")
    assert has_element?(view, "#structured-id[readonly]")

    view
    |> form("#structured-form", %{
      "structured" => %{
        "model" => %{"name" => "model-b", "reasoning" => "high"},
        "lifecycle" => %{"kind" => "scheduled"},
        "context" => %{"threshold" => "700", "target" => "300"},
        "budgets" => %{"run_seconds" => "45", "tokens" => "2000"}
      }
    })
    |> render_change()

    assert has_element?(view, ".source-dirty", "UNSAVED CHANGES")

    html =
      view
      |> form("#structured-form", %{
        "structured" => %{
          "lifecycle" => %{
            "kind" => "scheduled",
            "schedule" => "0 7 * * *",
            "overlap" => "forbid"
          }
        }
      })
      |> render_submit()

    assert html =~ "Structured configuration saved"
    refute has_element?(view, ".source-dirty", "UNSAVED CHANGES")

    content = File.read!(path)
    assert content =~ "# top-level comment"
    assert content =~ "# model comment"
    assert content =~ ~s(name = "model-b" # keep this comment)
    assert content =~ ~s(kind = "scheduled")
    assert content =~ ~s(schedule = "0 7 * * *")
    assert content =~ ~s(overlap = "forbid")
    assert content =~ "threshold = 700"
    assert content =~ "target = 300"
    assert content =~ "run-seconds = 45"
    assert content =~ "tokens = 2000"
    assert content =~ ~s(extra = "keep")

    assert {:ok, snapshot} = DefinitionRegistry.get("researcher")
    assert snapshot.revision == 2
    assert snapshot.definition.model.name == "model-b"
    assert snapshot.definition.lifecycle.kind == :scheduled
  end

  test "a stale structured save reports a conflict and leaves the file alone", %{
    conn: conn,
    path: path
  } do
    {:ok, view, _html} = live(conn, "/config/researcher")
    view |> element("button[phx-value-tab='structured']") |> render_click()

    external = String.replace(agent_body(), ~s(name = "model-a"), ~s(name = "external-model"))
    File.write!(path, external)

    html =
      view
      |> form("#structured-form", %{"structured" => %{"model" => %{"name" => "model-b"}}})
      |> render_submit()

    assert html =~ "Save conflict"
    assert File.read!(path) == external

    assert {:ok, snapshot} = DefinitionRegistry.get("researcher")
    assert snapshot.revision == 1
    assert snapshot.definition.model.name == "model-a"
  end

  test "toolkits and results can be added, removed, and configured", %{
    conn: conn,
    path: path
  } do
    {:ok, view, _html} = live(conn, "/config/researcher")
    view |> element("button[phx-value-tab='structured']") |> render_click()

    assert has_element?(view, "input[name='structured[toolkits][0][root]']")

    view |> element("button[phx-click='add_toolkit']") |> render_click()
    assert has_element?(view, "input[name='structured[toolkits][1][toolkit]']")

    render_click(view, "remove_toolkit", %{"index" => "1"})
    refute has_element?(view, "input[name='structured[toolkits][1][toolkit]']")

    view |> element("button[phx-click='add_operation']") |> render_click()
    assert has_element?(view, "input[name='structured[toolkits][0][operations][1][name]']")

    view |> element("button[phx-click='add_result']") |> render_click()
    assert has_element?(view, "input[name='structured[results][2][id]']")

    html =
      view
      |> form("#structured-form", %{
        "structured" => %{
          "toolkits" => %{
            "0" => %{
              "root" => "work2",
              "operations" => %{"1" => %{"name" => "build", "argv" => "echo\nbuilt"}}
            }
          },
          "results" => %{
            "0" => %{"required_by" => "b"},
            "2" => %{"id" => "c", "label" => "C", "form" => "url", "required_by" => "a"}
          }
        }
      })
      |> render_submit()

    assert html =~ "Structured configuration saved"

    content = File.read!(path)
    assert content =~ ~s(root = "work2")
    assert content =~ ~s(name = "build")
    assert content =~ ~s(argv = ["echo", "built"])
    assert content =~ ~s(id = "c")
    assert content =~ ~s(label = "C")
    assert content =~ ~s(required-by = "a")
    assert content =~ ~s(required-by = "b")

    assert {:ok, snapshot} = DefinitionRegistry.get("researcher")
    ids = Enum.map(snapshot.definition.results, & &1.id)
    assert "c" in ids
  end

  test "structured saves reject invalid lifecycle, toolkits, and results", %{
    conn: conn,
    path: path
  } do
    {:ok, view, _html} = live(conn, "/config/researcher")
    view |> element("button[phx-value-tab='structured']") |> render_click()
    original = File.read!(path)

    html =
      render_submit(view, "save_structured", %{
        "structured" => %{"lifecycle" => %{"kind" => "one-shot", "schedule" => "0 7 * * *"}}
      })

    assert html =~ "only valid for a scheduled lifecycle"

    html =
      render_submit(view, "save_structured", %{
        "structured" => %{
          "toolkits" => %{"0" => %{"toolkit" => "unknown-toolkit", "root" => "work"}}
        }
      })

    assert html =~ "unknown toolkit"

    html =
      render_submit(view, "save_structured", %{
        "structured" => %{"toolkits" => %{"0" => %{"toolkit" => "filesystem", "root" => ""}}}
      })

    assert html =~ "requires a filesystem root"

    html =
      render_submit(view, "save_structured", %{
        "structured" => %{
          "toolkits" => %{"0" => %{"root" => "work"}},
          "results" => %{
            "0" => %{"required_by" => "b"},
            "1" => %{"required_by" => "a"}
          }
        }
      })

    assert html =~ "dependency cycle"

    html =
      render_submit(view, "save_structured", %{
        "structured" => %{
          "results" => %{
            "0" => %{"id" => "a", "required_by" => ""},
            "1" => %{"id" => "a", "required_by" => ""}
          }
        }
      })

    assert html =~ "declared more than once"
    assert File.read!(path) == original
  end

  test "a dirty structured form survives a tick and a config reload", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/config/researcher")
    view |> element("button[phx-value-tab='structured']") |> render_click()

    view
    |> form("#structured-form", %{"structured" => %{"model" => %{"name" => "model-draft"}}})
    |> render_change()

    send(view.pid, :tick)
    html = render(view)

    assert html =~ "model-draft"
    assert html =~ "UNSAVED CHANGES"

    Phoenix.PubSub.broadcast(Patchbay.PubSub, "config", {:config, :reloaded})
    html = render(view)

    assert html =~ "model-draft"
    assert html =~ "UNSAVED CHANGES"
  end

  test "an invalid definition keeps structured editing unavailable", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/config/blank")

    assert has_element?(view, "button[phx-value-tab='structured'][disabled]")
    refute has_element?(view, "#structured-form")
    assert has_element?(view, "form[phx-submit='save'] textarea[name='source']")
  end

  test "a blank model name is saved as the configured default", %{conn: conn, path: path} do
    {:ok, view, _html} = live(conn, "/config/researcher")
    view |> element("button[phx-value-tab='structured']") |> render_click()

    view
    |> form("#structured-form", %{
      "structured" => %{"model" => %{"name" => "", "provider" => "", "reasoning" => ""}}
    })
    |> render_submit()

    content = File.read!(path)
    assert content =~ ~s(name = "default")
    refute content =~ ~s(name = "")
  end

  test "saving the source does not discard a dirty structured draft", %{
    conn: conn,
    path: path
  } do
    File.write!(path, plain_body())
    assert {:ok, _report} = DefinitionRegistry.reload()

    {:ok, view, _html} = live(conn, "/config/researcher")
    view |> element("button[phx-value-tab='structured']") |> render_click()

    view
    |> form("#structured-form", %{"structured" => %{"model" => %{"name" => "model-draft"}}})
    |> render_change()

    view |> element("button[phx-value-tab='source']") |> render_click()
    original = File.read!(path)

    html =
      view
      |> form("form[phx-submit='save']", %{"source" => original})
      |> render_submit()

    assert html =~ "Save blocked"
    assert html =~ "structured editor has unsaved changes"
    assert File.read!(path) == original

    view |> element("button[phx-value-tab='structured']") |> render_click()
    assert has_element?(view, "input[name='structured[model][name]'][value='model-draft']")
    assert has_element?(view, ".source-dirty", "UNSAVED CHANGES")
  end

  test "saving structured does not discard a dirty source draft", %{conn: conn, path: path} do
    File.write!(path, plain_body())
    assert {:ok, _report} = DefinitionRegistry.reload()

    {:ok, view, _html} = live(conn, "/config/researcher")

    draft = String.replace(plain_body(), ~s(name = "model-a"), ~s(name = "model-draft"))

    view
    |> form("form[phx-submit='save']", %{"source" => draft})
    |> render_change()

    view |> element("button[phx-value-tab='structured']") |> render_click()
    original = File.read!(path)

    html =
      view
      |> form("#structured-form", %{"structured" => %{"model" => %{"name" => "model-a"}}})
      |> render_submit()

    assert html =~ "Save blocked"
    assert html =~ "source editor has unsaved changes"
    assert File.read!(path) == original

    view |> element("button[phx-value-tab='source']") |> render_click()
    assert render(view) =~ "model-draft"
  end

  test "removing middle entries merges by identity instead of position", %{
    conn: conn,
    path: path
  } do
    File.write!(path, multi_entry_body())
    assert {:ok, _report} = DefinitionRegistry.reload()

    {:ok, view, _html} = live(conn, "/config/researcher")
    view |> element("button[phx-value-tab='structured']") |> render_click()

    render_click(view, "remove_toolkit", %{"index" => "1"})
    render_click(view, "remove_operation", %{"toolkit" => "0", "index" => "1"})
    render_click(view, "remove_result", %{"index" => "1"})

    html = render_submit(view, "save_structured", %{"structured" => %{}})
    assert html =~ "Structured configuration saved"

    content = File.read!(path)

    assert content =~ ~s(extra = "alpha" # alpha extra)
    assert content =~ ~s(extra = "gamma" # gamma extra)
    refute content =~ "# beta extra"

    assert content =~ ~s(extra = "op-one")
    assert content =~ ~s(extra = "op-three")
    refute content =~ ~s(extra = "op-two")

    assert content =~ ~s(note = "a-note" # alpha note)
    assert content =~ ~s(note = "c-note" # gamma note)
    refute content =~ "# beta note"

    assert {:ok, snapshot} = DefinitionRegistry.get("researcher")
    assert Enum.map(snapshot.definition.results, & &1.id) == ["a", "c"]
    assert length(snapshot.definition.toolkits) == 2
  end

  test "a stale structured save keeps the edits for review and retry", %{conn: conn, path: path} do
    {:ok, view, _html} = live(conn, "/config/researcher")
    view |> element("button[phx-value-tab='structured']") |> render_click()

    view
    |> form("#structured-form", %{"structured" => %{"model" => %{"name" => "model-draft"}}})
    |> render_change()

    external = String.replace(agent_body(), ~s(name = "model-a"), ~s(name = "external-model"))
    File.write!(path, external)

    html =
      view
      |> form("#structured-form", %{"structured" => %{"model" => %{"name" => "model-draft"}}})
      |> render_submit()

    assert html =~ "Save conflict"
    assert File.read!(path) == external
    assert has_element?(view, "input[name='structured[model][name]'][value='model-draft']")
    assert has_element?(view, ".source-dirty", "UNSAVED CHANGES")

    html =
      view
      |> form("#structured-form", %{"structured" => %{"model" => %{"name" => "model-draft"}}})
      |> render_submit()

    assert html =~ "Structured configuration saved"
    content = File.read!(path)
    assert content =~ ~s(name = "model-draft")
    refute content =~ "external-model"
  end

  test "a no-op structured save does not add a model name default", %{conn: conn, path: path} do
    File.write!(path, """
    format-version = 1
    id = "researcher"

    [model]
    provider = "default"

    [lifecycle]
    kind = "one-shot"
    """)

    assert {:ok, _report} = DefinitionRegistry.reload()

    {:ok, view, _html} = live(conn, "/config/researcher")
    view |> element("button[phx-value-tab='structured']") |> render_click()

    html = render_submit(view, "save_structured", %{"structured" => %{}})
    assert html =~ "Structured configuration saved"

    content = File.read!(path)
    refute content =~ ~s(name = "default")
    refute content =~ ~s(name = "")
  end

  test "clean drafts refresh when a reload broadcast arrives", %{conn: conn, path: path} do
    {:ok, view, _html} = live(conn, "/config/researcher")

    external = String.replace(agent_body(), ~s(name = "model-a"), ~s(name = "external-model"))
    File.write!(path, external)

    Phoenix.PubSub.broadcast(Patchbay.PubSub, "config", {:config, :reloaded})
    html = render(view)

    assert html =~ "external-model"
    refute html =~ "UNSAVED CHANGES"

    view |> element("button[phx-value-tab='structured']") |> render_click()
    assert has_element?(view, "input[name='structured[model][name]'][value='external-model']")
  end

  test "lifecycle toggles retain the typed schedule", %{conn: conn, path: path} do
    {:ok, view, _html} = live(conn, "/config/researcher")
    view |> element("button[phx-value-tab='structured']") |> render_click()

    view
    |> form("#structured-form", %{"structured" => %{"lifecycle" => %{"kind" => "scheduled"}}})
    |> render_change()

    view
    |> form("#structured-form", %{
      "structured" => %{"lifecycle" => %{"kind" => "scheduled", "schedule" => "0 7 * * *"}}
    })
    |> render_change()

    assert has_element?(view, "input[name='structured[lifecycle][schedule]'][value='0 7 * * *']")

    view
    |> form("#structured-form", %{"structured" => %{"lifecycle" => %{"kind" => "one-shot"}}})
    |> render_change()

    refute has_element?(view, "input[name='structured[lifecycle][schedule]']")

    view
    |> form("#structured-form", %{"structured" => %{"lifecycle" => %{"kind" => "scheduled"}}})
    |> render_change()

    assert has_element?(view, "input[name='structured[lifecycle][schedule]'][value='0 7 * * *']")

    html =
      view
      |> form("#structured-form", %{"structured" => %{"lifecycle" => %{"kind" => "scheduled"}}})
      |> render_submit()

    assert html =~ "Structured configuration saved"
    assert File.read!(path) =~ ~s(schedule = "0 7 * * *")
  end

  test "the personal-memory namespace is editable and saved", %{conn: conn, path: path} do
    {:ok, view, _html} = live(conn, "/config/researcher")
    view |> element("button[phx-value-tab='structured']") |> render_click()
    view |> element("button[phx-click='add_toolkit']") |> render_click()

    assert has_element?(
             view,
             "input[name='structured[toolkits][1][toolkit]'][phx-debounce='200']"
           )

    view
    |> form("#structured-form", %{
      "structured" => %{
        "toolkits" => %{
          "0" => %{"toolkit" => "filesystem", "root" => "work"},
          "1" => %{"toolkit" => "personal-memory"}
        }
      }
    })
    |> render_change()

    assert has_element?(view, "input[name='structured[toolkits][1][namespace]']")

    html =
      view
      |> form("#structured-form", %{
        "structured" => %{
          "toolkits" => %{
            "0" => %{"toolkit" => "filesystem", "root" => "work"},
            "1" => %{"toolkit" => "personal-memory", "namespace" => "team"}
          }
        }
      })
      |> render_submit()

    assert html =~ "Structured configuration saved"

    content = File.read!(path)
    assert content =~ ~s(toolkit = "personal-memory")
    assert content =~ ~s(namespace = "team")

    assert has_element?(
             view,
             "input[name='structured[toolkits][1][namespace]'][value='team']"
           )
  end

  defp multi_entry_body do
    """
    format-version = 1
    id = "researcher"

    [model]
    name = "model-a"

    [lifecycle]
    kind = "one-shot"

    [[toolkits]]
    toolkit = "filesystem"
    description = "Alpha"

    [toolkits.config]
    root = "work-a"
    extra = "alpha" # alpha extra

    [[toolkits.operations]]
    name = "op-one"
    argv = ["echo", "one"]
    extra = "op-one"

    [[toolkits.operations]]
    name = "op-two"
    argv = ["echo", "two"]
    extra = "op-two"

    [[toolkits.operations]]
    name = "op-three"
    argv = ["echo", "three"]
    extra = "op-three"

    [[toolkits]]
    toolkit = "filesystem"
    description = "Beta"

    [toolkits.config]
    root = "work-b"
    extra = "beta" # beta extra

    [[toolkits]]
    toolkit = "filesystem"
    description = "Gamma"

    [toolkits.config]
    root = "work-c"
    extra = "gamma" # gamma extra

    [[results]]
    id = "a"
    label = "Alpha"
    form = "prose"
    note = "a-note" # alpha note

    [[results]]
    id = "b"
    label = "Beta"
    form = "prose"
    note = "b-note" # beta note

    [[results]]
    id = "c"
    label = "Gamma"
    form = "prose"
    note = "c-note" # gamma note
    """
  end

  defp plain_body do
    """
    format-version = 1
    id = "researcher"

    [model]
    name = "model-a"

    [lifecycle]
    kind = "one-shot"

    [[toolkits]]
    toolkit = "filesystem"

    [toolkits.config]
    root = "work"
    """
  end

  defp agent_body do
    """
    format-version = 1
    id = "researcher" # top-level comment

    [model]
    # model comment
    name = "model-a" # keep this comment
    provider = "default"

    [lifecycle]
    kind = "one-shot"

    [context]
    between-runs = "keep"
    threshold = 500
    target = 200

    [budgets]
    run-seconds = 30
    tokens = 1000

    [[toolkits]]
    toolkit = "filesystem"
    description = "Workspace files"

    [toolkits.config]
    root = "work"
    extra = "keep"

    [[toolkits.operations]]
    name = "read"
    argv = ["cat", "notes.txt"]

    [[results]]
    id = "a"
    label = "Alpha"
    form = "prose"

    [[results]]
    id = "b"
    label = "Beta"
    form = "url"
    """
  end

  defp ops_manifest do
    """
    name = "ops"
    description = "Fixed operations"

    [[operations]]
    name = "build"
    argv = ["echo", "build"]
    """
  end
end
