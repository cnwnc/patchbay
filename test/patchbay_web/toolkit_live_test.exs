defmodule PatchbayWeb.ToolkitLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Patchbay.Config.File, as: ConfigFile
  alias Patchbay.Config.Manifest
  alias Patchbay.DefinitionRegistry

  @endpoint PatchbayWeb.Endpoint

  setup do
    root = Path.join(System.tmp_dir!(), "patchbay-toolkit-#{System.unique_integer([:positive])}")
    config_dir = Path.join(root, "config")

    File.mkdir_p!(Path.join(config_dir, "toolkits"))
    File.mkdir_p!(Path.join(config_dir, "agents"))

    File.write!(Path.join([config_dir, "toolkits", "custom.toml"]), """
    name = "custom"
    description = "Custom helpers"
    native = "filesystem"

    # keep comment
    [config]
    root = "work"
    """)

    start_supervised!({DefinitionRegistry, name: DefinitionRegistry, config_dir: config_dir})
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok,
     conn: PatchbayWeb.AuthTestHelper.authenticated_conn(),
     config_dir: config_dir,
     custom_path: Path.join([config_dir, "toolkits", "custom.toml"])}
  end

  test "lists configuration manifests and built-ins with the fixed nav order", %{conn: conn} do
    {:ok, view, html} = live(conn, "/toolkits")

    assert html =~ "TOOLKIT MANIFESTS"
    assert html =~ "custom"
    assert html =~ "filesystem"
    assert html =~ "BUILT-IN"

    nav = view |> element("nav.global-nav") |> render()
    assert nav =~ ~r/CONSOLE.*CONFIG.*TOOLKITS/s

    assert has_element?(view, "#manifest-source-form")
    refute has_element?(view, "#manifest-structured-form")
  end

  test "built-in manifests are read-only", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/toolkits/filesystem")

    assert has_element?(view, "button[phx-value-tab='structured'][disabled]")
    assert has_element?(view, "pre.code-block")

    html = render_submit(view, "save_source", %{"source" => "name = \"filesystem\"\n"})
    assert html =~ "read-only"

    assert File.read!(
             Path.join([to_string(:code.priv_dir(:patchbay)), "toolkits", "filesystem.toml"])
           ) =~
             "name = \"filesystem\""
  end

  test "creates a new configuration manifest", %{conn: conn, config_dir: config_dir} do
    {:ok, view, _html} = live(conn, "/toolkits")

    render_click(view, "new_manifest")

    html =
      view
      |> form("form[phx-submit='create_manifest']", %{
        "manifest_id" => "demo",
        "native" => "personal-memory"
      })
      |> render_submit()

    assert_patch(view, "/toolkits/demo")
    assert html =~ "Created manifest demo"

    path = Path.join([config_dir, "toolkits", "demo.toml"])
    assert File.read!(path) =~ "name = \"demo\""
    assert File.read!(path) =~ "native = \"personal-memory\""
    assert has_element?(view, "#manifest-source-form")
    assert has_element?(view, "button[phx-value-tab='structured']")
  end

  test "an invalid or duplicate manifest id is rejected", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/toolkits")
    render_click(view, "new_manifest")

    html =
      view
      |> form("form[phx-submit='create_manifest']", %{
        "manifest_id" => "Not Simple",
        "native" => ""
      })
      |> render_submit()

    assert html =~ "Create failed"
    assert html =~ "lowercase ID"

    html =
      view
      |> form("form[phx-submit='create_manifest']", %{
        "manifest_id" => "custom",
        "native" => ""
      })
      |> render_submit()

    assert html =~ "already exists"
  end

  test "structured editing saves native selection, tools, config, and operations", %{
    conn: conn,
    custom_path: custom_path
  } do
    {:ok, view, _html} = live(conn, "/toolkits/custom")
    view |> element("button[phx-value-tab='structured']") |> render_click()
    render_click(view, "add_operation")

    html =
      view
      |> form("#manifest-structured-form", %{
        "manifest" => %{
          "description" => "Updated helpers",
          "implicit" => "false",
          "native" => "filesystem",
          "tools" => "read_file\nlist_directory",
          "config_root" => "{%workspace}",
          "config_namespace" => "notes",
          "config_env" => "TOKEN=secret://token",
          "operations" => %{
            "0" => %{
              "name" => "echo",
              "description" => "Echo text",
              "executable" => "/bin/echo",
              "argv" => "hello"
            }
          }
        }
      })
      |> render_submit()

    assert html =~ "Structured manifest saved"

    content = File.read!(custom_path)
    assert content =~ "# keep comment"
    assert content =~ ~s(description = "Updated helpers")
    assert content =~ ~s(native = "filesystem")
    assert content =~ ~s(tools = ["read_file", "list_directory"])
    assert content =~ ~s(root = "{%workspace}")
    assert content =~ ~s(namespace = "notes")
    assert content =~ ~s(TOKEN = "secret://token")
    assert content =~ ~s(name = "echo")
    assert content =~ ~s(executable = "/bin/echo")
    assert content =~ ~s(argv = ["hello"])

    assert {:ok, %{operations: ["echo"], native: "filesystem"}} =
             Manifest.get(Path.dirname(Path.dirname(custom_path)), "custom")
  end

  test "a structured save after an external change reports a conflict", %{
    conn: conn,
    custom_path: custom_path
  } do
    {:ok, view, _html} = live(conn, "/toolkits/custom")
    view |> element("button[phx-value-tab='structured']") |> render_click()
    original = File.read!(custom_path)

    external =
      String.replace(original, ~s(description = "Custom helpers"), ~s(description = "External"))

    File.write!(custom_path, external)

    html =
      view
      |> form("#manifest-structured-form", %{
        "manifest" => %{"description" => "Mine"}
      })
      |> render_submit()

    assert html =~ "Save conflict"
    assert File.read!(custom_path) == external
  end

  test "a structured save rejects an unknown native toolkit", %{
    conn: conn,
    custom_path: custom_path
  } do
    {:ok, view, _html} = live(conn, "/toolkits/custom")
    view |> element("button[phx-value-tab='structured']") |> render_click()
    original = File.read!(custom_path)

    html =
      render_submit(view, "save_structured", %{"manifest" => %{"native" => "ghost"}})

    assert html =~ "unknown native toolkit"
    assert File.read!(custom_path) == original
  end

  test "a structured save retry keeps the loaded revision and cannot clobber an external edit", %{
    conn: conn,
    custom_path: custom_path
  } do
    {:ok, view, _html} = live(conn, "/toolkits/custom")
    view |> element("button[phx-value-tab='structured']") |> render_click()
    original = File.read!(custom_path)
    loaded_hash = ConfigFile.hash(original)

    external =
      String.replace(original, ~s(description = "Custom helpers"), ~s(description = "External"))

    File.write!(custom_path, external)

    html =
      view
      |> form("#manifest-structured-form", %{"manifest" => %{"description" => "Mine"}})
      |> render_submit()

    assert html =~ "Save conflict"
    assert File.read!(custom_path) == external

    assert has_element?(
             view,
             "#manifest-structured-form input[name='expected_hash'][value='#{loaded_hash}']"
           )

    html =
      view
      |> form("#manifest-structured-form", %{"manifest" => %{"description" => "Mine again"}})
      |> render_submit()

    assert html =~ "Save conflict"
    assert File.read!(custom_path) == external
  end

  test "a source save retry keeps the loaded revision and cannot clobber an external edit", %{
    conn: conn,
    custom_path: custom_path
  } do
    {:ok, view, _html} = live(conn, "/toolkits/custom")
    loaded_hash = ConfigFile.hash(File.read!(custom_path))
    external = "name = \"custom\"\ndescription = \"External\"\n"
    File.write!(custom_path, external)

    params = %{
      "source" => "name = \"custom\"\ndescription = \"Mine\"\n",
      "expected_hash" => loaded_hash
    }

    html = render_submit(view, "save_source", params)
    assert html =~ "Save conflict"
    assert File.read!(custom_path) == external

    assert has_element?(
             view,
             "#manifest-source-form input[name='expected_hash'][value='#{loaded_hash}']"
           )

    html = render_submit(view, "save_source", params)
    assert html =~ "Save conflict"
    assert File.read!(custom_path) == external
  end

  test "clearing the structured environment secrets removes config.env", %{
    conn: conn,
    config_dir: config_dir
  } do
    path = Path.join([config_dir, "toolkits", "secret.toml"])

    File.write!(path, """
    name = "secret"
    native = "secret-env"

    [config.env]
    TOKEN = "secret://token"
    """)

    {:ok, view, _html} = live(conn, "/toolkits/secret")
    view |> element("button[phx-value-tab='structured']") |> render_click()

    html =
      view
      |> form("#manifest-structured-form", %{
        "manifest" => %{
          "description" => "",
          "implicit" => "false",
          "native" => "secret-env",
          "tools" => "",
          "config_env" => "",
          "operations" => %{}
        }
      })
      |> render_submit()

    assert html =~ "Structured manifest saved"

    content = File.read!(path)
    refute content =~ "config.env"
    refute content =~ "TOKEN"
  end

  test "invalid manifest file names are shown as failures and cannot be selected", %{
    conn: conn,
    config_dir: config_dir
  } do
    path = Path.join([config_dir, "toolkits", "Not Valid.toml"])
    File.write!(path, "name = \"not-valid\"\nnative = \"filesystem\"\n")

    {:ok, view, html} = live(conn, "/toolkits")

    assert html =~ "Not Valid"
    assert has_element?(view, "li[aria-disabled='true']", "Not Valid")
    assert has_element?(view, "li.is-selected", "custom")

    render_click(view, "select", %{"id" => "Not Valid"})
    assert has_element?(view, "li.is-selected", "custom")
  end

  test "a manifest save rejects invalid source bytes", %{conn: conn, custom_path: custom_path} do
    {:ok, view, _html} = live(conn, "/toolkits/custom")
    original = File.read!(custom_path)
    hash = ConfigFile.hash(original)

    html =
      render_submit(view, "save_source", %{
        "source" => "name = \"custom\"\nnative = \"ghost\"\n",
        "expected_hash" => hash
      })

    assert html =~ "Save rejected"
    assert html =~ "unknown native toolkit"
    assert File.read!(custom_path) == original
  end
end
