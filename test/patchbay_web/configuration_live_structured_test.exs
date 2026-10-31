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
    refute content =~ "overlap"
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

  test "a native toolkit can be added from the manifest picker and its secret references are kept",
       %{
         conn: conn,
         path: path
       } do
    File.write!(path, plain_body())
    assert {:ok, _report} = DefinitionRegistry.reload()

    {:ok, view, _html} = live(conn, "/config/researcher")
    view |> element("button[phx-value-tab='structured']") |> render_click()

    assert has_element?(view, "select[name='new_toolkit'] option[value='secret-env']")
    assert has_element?(view, "select[name='new_toolkit'] option[value='filesystem']")
    assert has_element?(view, "select[name='new_toolkit'] option[value='ops']")
    assert has_element?(view, "select[name='new_toolkit'] option[value='']", "CUSTOM TOOLKIT")

    # The filesystem row lists the tools its manifest exposes.
    assert render(view) =~ "edit_file, list_directory, read_file, write_file"

    view
    |> form("#structured-form", %{"new_toolkit" => "secret-env"})
    |> render_change()

    view |> element("button[phx-click='add_toolkit']") |> render_click()

    assert has_element?(
             view,
             "input[name='structured[toolkits][1][toolkit]'][value='secret-env']"
           )

    assert has_element?(view, "textarea[name='structured[toolkits][1][env]']")
    assert render(view) =~ "NO MODEL-FACING TOOLS"

    html =
      view
      |> form("#structured-form", %{
        "structured" => %{
          "toolkits" => %{
            "0" => %{"root" => "work"},
            "1" => %{"env" => "GH_TOKEN=secret://github-main\nDEPLOY_KEY=secret://deploy"}
          }
        }
      })
      |> render_submit()

    assert html =~ "Structured configuration saved"

    content = File.read!(path)
    assert content =~ ~s(toolkit = "secret-env")
    assert content =~ ~s(GH_TOKEN = "secret://github-main")
    assert content =~ ~s(DEPLOY_KEY = "secret://deploy")

    assert {:ok, snapshot} = DefinitionRegistry.get("researcher")
    secret_toolkit = Enum.find(snapshot.definition.toolkits, &(&1.toolkit == "secret-env"))
    assert secret_toolkit
    assert secret_toolkit.config["env"]["GH_TOKEN"] == "secret://github-main"

    # References are declarations, not secret bytes, so the structured editor
    # keeps showing them after the reload that follows a save.
    assert has_element?(
             view,
             "textarea[name='structured[toolkits][1][env]']"
           )

    env_text = view |> element("textarea[name='structured[toolkits][1][env]']") |> render()
    assert env_text =~ "GH_TOKEN=secret://github-main"

    html =
      view
      |> form("#structured-form", %{
        "structured" => %{
          "toolkits" => %{
            "0" => %{"root" => "work"},
            "1" => %{"env" => "GH_TOKEN=github-main"}
          }
        }
      })
      |> render_submit()

    assert html =~ "must reference a secret as secret://"
    assert File.read!(path) =~ ~s(GH_TOKEN = "secret://github-main")

    html =
      view
      |> form("#structured-form", %{
        "structured" => %{
          "toolkits" => %{
            "0" => %{"root" => "work"},
            "1" => %{"env" => "GH_TOKEN=secret://a\nGH_TOKEN=secret://b"}
          }
        }
      })
      |> render_submit()

    assert html =~ "declares env"
    assert html =~ "more than once"
  end

  test "operation arguments and lifecycle hooks edit and roundtrip", %{
    conn: conn,
    path: path,
    config_dir: config_dir
  } do
    File.write!(path, hooks_body())
    assert {:ok, _report} = DefinitionRegistry.reload()

    {:ok, view, _html} = live(conn, "/config/researcher")
    view |> element("button[phx-value-tab='structured']") |> render_click()

    assert has_element?(
             view,
             "input[name='structured[toolkits][0][operations][0][arguments][0][name]'][value='target']"
           )

    assert has_element?(
             view,
             "select[name='structured[toolkits][0][operations][0][arguments][0][type]'] option[value='path'][selected]"
           )

    assert has_element?(
             view,
             "select[name='structured[toolkits][0][operations][0][arguments][0][required]'] option[value='true'][selected]",
             "YES"
           )

    assert render(view) =~ ">ARGUMENTS<"
    refute render(view) =~ "EXECUTABLE IS SEPARATE"

    values_text =
      view
      |> element("textarea[name='structured[toolkits][0][operations][1][arguments][0][values]']")
      |> render()

    assert values_text =~ "dev
prod"

    assert has_element?(
             view,
             "input[name='structured[lifecycle][init][0][name]'][value='prepare']"
           )

    view |> element("button[phx-click='add_hook']", "ADD FINALIZE HOOK") |> render_click()

    view
    |> element("button[phx-click='add_argument'][phx-value-operation='1']")
    |> render_click()

    html =
      view
      |> form("#structured-form", %{
        "structured" => %{
          "lifecycle" => %{
            "finalize" => %{
              "0" => %{
                "name" => "record",
                "executable" => "/nix/store/.../bin/record",
                "argv" => "{%result_dir}"
              }
            }
          },
          "toolkits" => %{
            "0" => %{
              "root" => "work",
              "operations" => %{
                "1" => %{
                  "arguments" => %{
                    "1" => %{"name" => "count", "type" => "integer", "required" => "false"}
                  }
                }
              }
            }
          }
        }
      })
      |> render_submit()

    assert html =~ "Structured configuration saved"

    content = File.read!(path)
    assert content =~ ~s(name = "record")
    assert content =~ ~s(executable = "/nix/store/.../bin/record")
    assert content =~ ~s(argv = ["{%result_dir}"])
    assert content =~ "[toolkits.operations.arguments.count]"
    assert content =~ ~s(type = "integer")
    assert content =~ ~s(required = false)
    assert content =~ "extra = \"keep\""

    assert {:ok, snapshot} = DefinitionRegistry.get("researcher")

    # Inline operations on a toolbox that resolves to a manifest without those
    # names are dropped during manifest merging, so the arguments are verified
    # through `Definition.parse`, which keeps inline operations.
    assert {:ok, parsed} = Patchbay.Definition.parse(File.read!(path), config_root: config_dir)

    sweep =
      parsed.toolkits
      |> Enum.flat_map(& &1.operations)
      |> Enum.find(&(&1.name == "sweep"))

    assert sweep.arguments["count"].type == :integer
    assert sweep.arguments["count"].required == false
    assert sweep.arguments["mode"].type == :enum

    [fin_hook] = snapshot.definition.lifecycle.finalize
    assert fin_hook.name == "record"
    assert fin_hook.executable == "/nix/store/.../bin/record"
    assert fin_hook.argv == ["{%result_dir}"]
  end

  test "argument reuse of manifest operations keeps inherited tooling", %{
    conn: conn,
    path: path
  } do
    File.write!(path, plain_body())

    File.write!(
      Path.join([Path.dirname(path), "..", "..", "toolkits", "ops.toml"]),
      ops_manifest()
    )

    {:ok, _report} = DefinitionRegistry.reload()

    {:ok, view, _html} = live(conn, "/config/researcher")
    view |> element("button[phx-value-tab='structured']") |> render_click()

    view
    |> form("#structured-form", %{"new_toolkit" => "ops"})
    |> render_change()

    view |> element("button[phx-click='add_toolkit']") |> render_click()

    html =
      view
      |> form("#structured-form", %{
        "structured" => %{"toolkits" => %{"0" => %{"root" => "work"}, "1" => %{}}}
      })
      |> render_submit()

    assert html =~ "Structured configuration saved"
    assert File.read!(path) =~ ~s(toolkit = "ops")

    assert {:ok, snapshot} = DefinitionRegistry.get("researcher")
    ops_toolkit = Enum.find(snapshot.definition.toolkits, &(&1.toolkit == "ops"))
    assert [%{name: "build"}] = ops_toolkit.operations
  end

  test "context recovery selects expose the accepted vocabulary", %{
    conn: conn,
    path: path
  } do
    File.write!(path, context_body())
    assert {:ok, _report} = DefinitionRegistry.reload()

    {:ok, view, _html} = live(conn, "/config/researcher")
    view |> element("button[phx-value-tab='structured']") |> render_click()

    select = "select#structured-context-between-runs"

    assert has_element?(view, "#{select} option[value='handoff'][selected]")
    assert has_element?(view, "#{select} option[value='checkpoint']", "CHECKPOINT — SAME AS KEEP")
    assert has_element?(view, "#{select} option[value='queryable']", "QUERYABLE — SAME AS KEEP")
    assert has_element?(view, "#{select} option[value='drop']", "DROP — SAME AS RESET")

    assert has_element?(
             view,
             "select#structured-context-prior-runs option[value='queryable'][selected]"
           )

    assert has_element?(
             view,
             "select#structured-context-restore-interrupted option[value='checkpoint'][selected]"
           )

    html =
      view
      |> form("#structured-form", %{
        "structured" => %{
          "context" => %{
            "between_runs" => "handoff",
            "prior_runs" => "keep",
            "restore_interrupted" => "resume"
          }
        }
      })
      |> render_submit()

    assert html =~ "Structured configuration saved"

    content = File.read!(path)
    assert content =~ ~s(between-runs = "handoff")
    assert content =~ ~s(prior-runs = "keep")
    assert content =~ ~s(restore-interrupted = "resume")

    assert {:ok, snapshot} = DefinitionRegistry.get("researcher")
    assert snapshot.definition.context.between_runs == "handoff"
    assert snapshot.definition.context.prior_runs == "keep"
    assert snapshot.definition.context.restore_interrupted == "resume"
  end

  test "environment packages and teardown workspace roundtrip", %{
    conn: conn,
    path: path
  } do
    File.write!(path, """
    format-version = 1
    id = "researcher"

    [model]
    name = "model-a"

    [lifecycle]
    kind = "perpetual"

    [environment]
    packages = ["git", "ripgrep"] # keep this comment

    [teardown]
    workspace = "destroy"
    """)

    assert {:ok, _report} = DefinitionRegistry.reload()

    {:ok, view, _html} = live(conn, "/config/researcher")
    view |> element("button[phx-value-tab='structured']") |> render_click()

    assert has_element?(view, "textarea#structured-environment-packages")

    packages_text = view |> element("textarea#structured-environment-packages") |> render()
    assert packages_text =~ "git\nripgrep"

    assert has_element?(
             view,
             "select#structured-teardown-workspace option[value='destroy'][selected]"
           )

    html =
      view
      |> form("#structured-form", %{
        "structured" => %{
          "environment" => %{"packages" => "git\nripgrep\njq"},
          "teardown" => %{"workspace" => "export"}
        }
      })
      |> render_submit()

    assert html =~ "Structured configuration saved"

    content = File.read!(path)
    assert content =~ ~s(packages = ["git", "ripgrep", "jq"])
    assert content =~ "# keep this comment"
    assert content =~ ~s(workspace = "export")

    assert {:ok, snapshot} = DefinitionRegistry.get("researcher")
    assert snapshot.definition.environment.packages == ["git", "ripgrep", "jq"]
    assert snapshot.definition.teardown.workspace == :export
  end

  test "the workspace toggle roundtrips and defaults to enabled", %{
    conn: conn,
    path: path
  } do
    File.write!(path, """
    format-version = 1
    id = "researcher"

    [model]
    name = "model-a"

    [lifecycle]
    kind = "perpetual"

    [[toolkits]]
    toolkit = "filesystem"

    [toolkits.config]
    root = "work"
    """)

    assert {:ok, _report} = DefinitionRegistry.reload()

    {:ok, view, _html} = live(conn, "/config/researcher")
    view |> element("button[phx-value-tab='structured']") |> render_click()

    # The filesystem root field advertises variable support.
    assert has_element?(view, "input#structured-toolkit-root-0")
    assert view |> element("label[for='structured-toolkit-root-0']") |> render() =~ "{%WORKSPACE}"

    assert has_element?(
             view,
             "select#structured-workspace-enabled option[value='enabled'][selected]",
             "YES"
           )

    assert has_element?(
             view,
             "select#structured-teardown-workspace option[value='retain'][selected]",
             "RETAIN"
           )

    html =
      view
      |> form("#structured-form", %{
        "structured" => %{"workspace" => %{"enabled" => "disabled"}}
      })
      |> render_submit()

    assert html =~ "Structured configuration saved"

    content = File.read!(path)
    assert content =~ "enabled = false"

    assert {:ok, snapshot} = DefinitionRegistry.get("researcher")
    assert snapshot.definition.workspace.enabled == false

    # Switching back selects the concrete default and leaves it omitted.
    {:ok, view, _html} = live(conn, "/config/researcher")
    view |> element("button[phx-value-tab='structured']") |> render_click()

    assert has_element?(
             view,
             "select#structured-workspace-enabled option[value='disabled'][selected]",
             "NO"
           )

    html =
      view
      |> form("#structured-form", %{
        "structured" => %{"workspace" => %{"enabled" => "enabled"}}
      })
      |> render_submit()

    assert html =~ "Structured configuration saved"

    content = File.read!(path)
    refute content =~ "enabled = false"
    refute content =~ "enabled = true"

    assert {:ok, snapshot} = DefinitionRegistry.get("researcher")
    assert snapshot.definition.workspace.enabled == true
  end

  test "a definition with every practical option keeps uncovered keys and comments", %{
    conn: conn,
    path: path
  } do
    File.write!(path, full_body())
    assert {:ok, _report} = DefinitionRegistry.reload()

    {:ok, view, _html} = live(conn, "/config/researcher")
    view |> element("button[phx-value-tab='structured']") |> render_click()

    assert has_element?(view, "input[name='structured[model][name]'][value='model-a']")
    assert has_element?(view, "input[name='structured[model][provider]'][value='default']")
    assert has_element?(view, "input[name='structured[model][reasoning]'][value='low']")

    assert has_element?(
             view,
             "input[name='structured[lifecycle][init][0][name]'][value='prepare']"
           )

    assert has_element?(
             view,
             "input[name='structured[lifecycle][finalize][0][name]'][value='record']"
           )

    assert has_element?(
             view,
             "select#structured-teardown-workspace option[value='destroy'][selected]"
           )

    assert has_element?(view, "textarea#structured-environment-packages")

    assert view
           |> element("textarea#structured-environment-packages")
           |> render() =~ "git\nripgrep"

    assert has_element?(
             view,
             "select#structured-context-between-runs option[value='handoff'][selected]"
           )

    assert has_element?(
             view,
             "select#structured-context-prior-runs option[value='queryable'][selected]"
           )

    assert has_element?(
             view,
             "select#structured-context-restore-interrupted option[value='checkpoint'][selected]"
           )

    assert has_element?(
             view,
             "input[name='structured[toolkits][1][toolkit]'][value='secret-env']"
           )

    assert has_element?(
             view,
             "textarea[name='structured[toolkits][1][env]']"
           )

    assert view
           |> element("textarea[name='structured[toolkits][1][env]']")
           |> render() =~ "GH_TOKEN=secret://github-main"

    assert has_element?(
             view,
             "select[name='structured[results][1][form]'] option[value='file'][selected]"
           )

    assert view
           |> element("textarea[name='structured[results][1][extensions]']")
           |> render() =~ "patch\ndiff"

    html =
      view
      |> form("#structured-form", %{
        "structured" => %{
          "model" => %{"name" => "model-b", "reasoning" => "high"},
          "context" => %{"threshold" => "60000", "target" => "20000"},
          "budgets" => %{"run_seconds" => "1800", "tokens" => "1000000"}
        }
      })
      |> render_submit()

    assert html =~ "Structured configuration saved"

    content = File.read!(path)
    assert content =~ ~s(name = "model-b")
    assert content =~ ~s(reasoning = "high")
    assert content =~ "threshold = 60000"
    assert content =~ "target = 20000"
    assert content =~ "run-seconds = 1800"
    assert content =~ "tokens = 1000000"
    assert content =~ "extra = \"keep\" # config comment"
    assert content =~ ~s(between-runs = "handoff")
    assert content =~ ~s(prior-runs = "queryable")
    assert content =~ ~s(restore-interrupted = "checkpoint")
    assert content =~ ~s(GH_TOKEN = "secret://github-main")
    assert content =~ ~s(required-by = "report")
    assert content =~ ~s(extensions = ["patch", "diff", ""])
    assert content =~ "[[lifecycle.init]]"
    assert content =~ "[[lifecycle.finalize]]"

    assert {:ok, snapshot} = DefinitionRegistry.get("researcher")
    assert snapshot.definition.model.name == "model-b"
    assert snapshot.definition.model.reasoning == "high"
    assert snapshot.definition.environment.packages == ["git", "ripgrep"]
    assert snapshot.definition.teardown.workspace == :destroy
    assert snapshot.definition.context.between_runs == "handoff"
    assert length(snapshot.definition.lifecycle.init) == 1
    assert length(snapshot.definition.lifecycle.finalize) == 1
  end

  test "anonymous enums, missing arguments, and bad hooks are rejected before writing", %{
    conn: conn,
    path: path
  } do
    File.write!(path, plain_body())
    assert {:ok, _report} = DefinitionRegistry.reload()

    {:ok, view, _html} = live(conn, "/config/researcher")
    view |> element("button[phx-value-tab='structured']") |> render_click()
    original = File.read!(path)

    view |> element("button[phx-click='add_operation']") |> render_click()

    html =
      render_submit(view, "save_structured", %{
        "structured" => %{
          "toolkits" => %{
            "0" => %{
              "root" => "work",
              "operations" => %{
                "1" => %{
                  "name" => "check",
                  "argv" => "run",
                  "arguments" => %{"0" => %{"name" => "mode", "type" => "enum"}}
                }
              }
            }
          }
        }
      })

    assert html =~ "requires at least one enum value"

    html =
      render_submit(view, "save_structured", %{
        "structured" => %{
          "toolkits" => %{
            "0" => %{
              "root" => "work",
              "operations" => %{
                "1" => %{
                  "name" => "check",
                  "argv" => "run",
                  "arguments" => %{
                    "0" => %{"name" => "mode", "type" => "string", "values" => "dev"}
                  }
                }
              }
            }
          }
        }
      })

    assert html =~ "values are only valid for an enum argument"

    html =
      render_submit(view, "save_structured", %{
        "structured" => %{
          "lifecycle" => %{"init" => %{"0" => %{"name" => "bad", "argv" => ""}}}
        }
      })

    assert html =~ "requires arguments when no executable is set"

    html =
      render_submit(view, "save_structured", %{
        "structured" => %{
          "lifecycle" => %{
            "init" => %{"0" => %{"name" => "", "argv" => "/nix/store/.../bin/x"}}
          }
        }
      })

    assert html =~ "lifecycle init hook 1 requires a name"
    render_click(view, "remove_hook", %{"hook" => "init", "index" => "0"})

    view |> render_click("add_hook", %{"hook" => "finalize"})

    html =
      render_submit(view, "save_structured", %{
        "structured" => %{
          "lifecycle" => %{
            "finalize" => %{"0" => %{"name" => "", "argv" => "/nix/store/.../bin/x"}}
          }
        }
      })

    assert html =~ "lifecycle finalize hook 1 requires a name"
    assert File.read!(path) == original
  end

  test "the lifecycle init section renders once", %{conn: conn, path: path} do
    File.write!(path, hooks_body())
    assert {:ok, _report} = DefinitionRegistry.reload()

    {:ok, view, _html} = live(conn, "/config/researcher")
    view |> element("button[phx-value-tab='structured']") |> render_click()

    assert view |> render() |> String.split("INIT HOOKS") |> length() == 2
  end

  test "removing an operation's last argument drops the arguments table", %{
    conn: conn,
    path: path,
    config_dir: config_dir
  } do
    for body <- [table_arguments_body(), array_arguments_body()] do
      File.write!(path, body)
      assert {:ok, _report} = DefinitionRegistry.reload()

      {:ok, view, _html} = live(conn, "/config/researcher")
      view |> element("button[phx-value-tab='structured']") |> render_click()

      assert has_element?(
               view,
               "input[name='structured[toolkits][0][operations][0][arguments][0][name]'][value='target']"
             )

      view
      |> element(
        "button[phx-click='remove_argument'][phx-value-toolkit='0'][phx-value-operation='0'][phx-value-index='0']"
      )
      |> render_click()

      html = view |> form("#structured-form") |> render_submit()
      assert html =~ "Structured configuration saved"

      content = File.read!(path)
      refute content =~ "arguments.target"
      refute content =~ "arguments]]"
      refute content =~ ~s(type = "path")

      assert {:ok, parsed} = Patchbay.Definition.parse(content, config_root: config_dir)

      read =
        parsed.toolkits
        |> Enum.flat_map(& &1.operations)
        |> Enum.find(&(&1.name == "read"))

      assert read.arguments == %{}
      assert read.argv == ["cat", "notes.txt"]
    end
  end

  defp table_arguments_body do
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

    [[toolkits.operations]]
    name = "read"
    argv = ["cat", "notes.txt"]

    [toolkits.operations.arguments.target]
    type = "path"
    required = true
    """
  end

  defp array_arguments_body do
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

    [[toolkits.operations]]
    name = "read"
    argv = ["cat", "notes.txt"]

    [[toolkits.operations.arguments]]
    name = "target"
    type = "path"
    required = true
    """
  end

  defp context_body do
    """
    format-version = 1
    id = "researcher"

    [model]
    name = "model-a"

    [lifecycle]
    kind = "perpetual"

    [context]
    between-runs = "handoff"
    prior-runs = "queryable"
    restore-interrupted = "checkpoint"

    [[toolkits]]
    toolkit = "filesystem"

    [toolkits.config]
    root = "work"
    """
  end

  defp hooks_body do
    """
    format-version = 1
    id = "researcher"

    [model]
    name = "model-a"

    [lifecycle]
    kind = "one-shot"

    [[lifecycle.init]]
    name = "prepare"
    executable = "/nix/store/.../bin/prep"
    argv = ["{%workspace}"]

    [[toolkits]]
    toolkit = "filesystem"

    [toolkits.config]
    root = "work"
    extra = "keep"

    [[toolkits.operations]]
    name = "read"
    argv = ["cat", "{target}"]

    [toolkits.operations.arguments.target]
    type = "path"
    required = true

    [[toolkits.operations]]
    name = "sweep"
    argv = ["/nix/store/.../bin/sweep", "{mode}"]

    [toolkits.operations.arguments.mode]
    type = "enum"
    values = ["dev", "prod"]
    """
  end

  defp full_body do
    """
    format-version = 1
    id = "researcher"

    [model]
    name = "model-a"
    provider = "default"
    reasoning = "low"

    [lifecycle]
    kind = "one-shot"

    [[lifecycle.init]]
    name = "prepare"
    executable = "/nix/store/.../bin/prep"
    argv = ["{%workspace}"]

    [[lifecycle.finalize]]
    name = "record" # finalize comment
    argv = ["/nix/store/.../bin/record", "{%result_dir}"]

    [environment]
    packages = ["git", "ripgrep"]

    [context]
    between-runs = "handoff"
    prior-runs = "queryable"
    restore-interrupted = "checkpoint"
    threshold = 500
    target = 200

    [teardown]
    workspace = "destroy"

    [budgets]
    run-seconds = 30
    tokens = 1000

    [[toolkits]]
    toolkit = "filesystem"

    [toolkits.config]
    root = "work"
    extra = "keep" # config comment

    [[toolkits]]
    toolkit = "secret-env"

    [toolkits.config.env]
    GH_TOKEN = "secret://github-main"

    [[results]]
    id = "report"
    label = "Summary of completed work"
    form = "prose"

    [[results]]
    id = "patch"
    form = "file"
    required-by = "report"
    extensions = ["patch", "diff", ""]
    label = "Patch artifact, when one was produced"
    """
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
