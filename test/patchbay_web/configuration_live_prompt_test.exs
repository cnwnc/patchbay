defmodule PatchbayWeb.ConfigurationLivePromptTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Patchbay.Config.File, as: ConfigFile
  alias Patchbay.DefinitionRegistry

  @endpoint PatchbayWeb.Endpoint

  setup do
    root =
      Path.join(System.tmp_dir!(), "patchbay-prompt-ui-#{System.unique_integer([:positive])}")

    config_dir = Path.join(root, "config")
    agent_dir = Path.join([config_dir, "agents", "researcher"])
    broken_dir = Path.join([config_dir, "agents", "broken"])

    File.mkdir_p!(Path.join(agent_dir, "prompts"))
    File.mkdir_p!(Path.join(broken_dir, "prompts"))
    File.mkdir_p!(Path.join([config_dir, "shared", "prompts"]))
    File.mkdir_p!(Path.join(config_dir, "toolkits"))

    File.write!(Path.join([config_dir, "shared", "prompts", "00-shared.md"]), "Shared prompt")
    File.write!(Path.join([agent_dir, "prompts", "01-main.md"]), "Agent prompt")
    File.write!(Path.join([agent_dir, "prompts", "02-extra.md"]), "Extra prompt")
    File.write!(Path.join([broken_dir, "prompts", "00-broken.md"]), "Broken prompt")
    File.write!(Path.join(agent_dir, "agent.toml"), agent_body("researcher"))
    File.write!(Path.join(broken_dir, "agent.toml"), "format-version = 2\nid = \"broken\"\n")

    start_supervised!({DefinitionRegistry, name: DefinitionRegistry, config_dir: config_dir})
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok,
     conn: PatchbayWeb.AuthTestHelper.authenticated_conn(),
     config_dir: config_dir,
     agent_dir: agent_dir,
     main_path: Path.join([agent_dir, "prompts", "01-main.md"]),
     broken_prompts: Path.join(broken_dir, "prompts")}
  end

  test "shows shared prompts before agent prompts with filenames visible", %{conn: conn} do
    {:ok, view, html} = live(conn, "/config/researcher")

    assert has_element?(view, "textarea[aria-label='prompt 00-shared.md']")
    assert has_element?(view, "textarea[aria-label='prompt 01-main.md']")
    assert has_element?(view, "textarea[aria-label='prompt 02-extra.md']")
    assert html =~ "SHARED THEN AGENT"

    shared = elem(:binary.match(html, "00-shared.md"), 0)
    main = elem(:binary.match(html, "01-main.md"), 0)
    extra = elem(:binary.match(html, "02-extra.md"), 0)
    assert shared < main
    assert main < extra
  end

  test "creates a new agent prompt", %{conn: conn, config_dir: config_dir} do
    {:ok, view, _html} = live(conn, "/config/researcher")

    html =
      view
      |> form("form[phx-submit='create_prompt']", %{
        "new_prompt" => %{
          "source" => "agent",
          "filename" => "03-new.md",
          "content" => "# New\n\nBody"
        }
      })
      |> render_submit()

    assert html =~ "Prompt 03-new.md created"
    assert has_element?(view, "textarea[aria-label='prompt 03-new.md']")

    path = Path.join([config_dir, "agents", "researcher", "prompts", "03-new.md"])
    assert File.read!(path) == "# New\n\nBody"
  end

  test "saves an edited prompt", %{conn: conn, main_path: main_path} do
    {:ok, view, _html} = live(conn, "/config/researcher")

    html =
      view
      |> form("#prompt-form-1", %{"prompt_content" => "Updated prompt"})
      |> render_submit()

    assert html =~ "Prompt 01-main.md saved"
    assert File.read!(main_path) == "Updated prompt"
  end

  test "a dirty prompt draft survives a reload broadcast", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/config/researcher")

    view
    |> form("#prompt-form-1", %{"prompt_content" => "Draft prompt"})
    |> render_change()

    assert has_element?(view, ".source-dirty", "UNSAVED CHANGES")

    Phoenix.PubSub.broadcast(Patchbay.PubSub, "config", {:config, :reloaded})
    html = render(view)

    assert html =~ "Draft prompt"
    assert html =~ "UNSAVED CHANGES"
  end

  test "deletes a prompt using its loaded revision", %{conn: conn, main_path: main_path} do
    {:ok, view, _html} = live(conn, "/config/researcher")
    hash = ConfigFile.hash("Agent prompt")

    html =
      render_click(view, "delete_prompt", %{
        "prompt_source" => "agent",
        "prompt_name" => "01-main.md",
        "expected_hash" => hash
      })

    assert html =~ "Prompt 01-main.md deleted"
    refute File.exists?(main_path)
    refute has_element?(view, "textarea[aria-label='prompt 01-main.md']")
  end

  test "a stale prompt save reports a conflict and keeps the external bytes", %{
    conn: conn,
    main_path: main_path
  } do
    {:ok, view, _html} = live(conn, "/config/researcher")
    File.write!(main_path, "External prompt")

    html =
      view
      |> form("#prompt-form-1", %{"prompt_content" => "Mine"})
      |> render_submit()

    assert html =~ "Prompt save conflict"
    assert File.read!(main_path) == "External prompt"
  end

  test "prompt creation rejects nested and parent paths", %{conn: conn, config_dir: config_dir} do
    {:ok, view, _html} = live(conn, "/config/researcher")

    for filename <- ["../escape.md", "nested/escape.md"] do
      html =
        view
        |> form("form[phx-submit='create_prompt']", %{
          "new_prompt" => %{"source" => "agent", "filename" => filename, "content" => "x"}
        })
        |> render_submit()

      assert html =~ "Prompt create failed"
      assert html =~ "top-level .md"
    end

    refute File.exists?(Path.join(config_dir, "escape.md"))
    refute File.exists?(Path.join([config_dir, "agents", "researcher", "escape.md"]))
  end

  test "prompt editing works when agent.toml is invalid", %{
    conn: conn,
    broken_prompts: broken_prompts
  } do
    assert [%{id: "broken"}] = DefinitionRegistry.errors()

    {:ok, view, html} = live(conn, "/config/broken")

    assert html =~ "VALIDATION FAILURE"
    assert has_element?(view, "textarea[aria-label='prompt 00-broken.md']")

    html =
      view
      |> form("#prompt-form-1", %{"prompt_content" => "Repaired prompt"})
      |> render_submit()

    assert html =~ "Prompt 00-broken.md saved"
    assert File.read!(Path.join(broken_prompts, "00-broken.md")) == "Repaired prompt"
    assert [%{id: "broken"}] = DefinitionRegistry.errors()
  end

  test "a dirty prompt draft asks before switching agents", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/config/researcher")

    view
    |> form("#prompt-form-1", %{"prompt_content" => "Draft prompt"})
    |> render_change()

    assert has_element?(view, "#prompt-form-1 .source-dirty", "UNSAVED CHANGES")

    render_click(view, "select", %{"id" => "broken"})

    assert has_element?(view, ".source-confirm", "Discard unsaved changes to researcher?")
    assert has_element?(view, "button", "DISCARD AND SWITCH")

    render_click(view, "cancel_select")
    refute has_element?(view, ".source-confirm")
    assert has_element?(view, "#prompt-form-1 textarea", "Draft prompt")
  end

  test "a prompt save retry keeps the loaded revision and cannot clobber an external edit", %{
    conn: conn,
    main_path: main_path
  } do
    {:ok, view, _html} = live(conn, "/config/researcher")
    loaded_hash = ConfigFile.hash("Agent prompt")
    File.write!(main_path, "External prompt")

    html =
      view
      |> form("#prompt-form-1", %{"prompt_content" => "Mine"})
      |> render_submit()

    assert html =~ "Prompt save conflict"
    assert File.read!(main_path) == "External prompt"

    assert has_element?(
             view,
             "#prompt-form-1 input[name='expected_hash'][value='#{loaded_hash}']"
           )

    html =
      view
      |> form("#prompt-form-1", %{"prompt_content" => "Mine again"})
      |> render_submit()

    assert html =~ "Prompt save conflict"
    assert File.read!(main_path) == "External prompt"
  end

  test "a prompt delete retry keeps the loaded revision and cannot remove an external edit", %{
    conn: conn,
    main_path: main_path
  } do
    {:ok, view, _html} = live(conn, "/config/researcher")
    loaded_hash = ConfigFile.hash("Agent prompt")
    File.write!(main_path, "External prompt")

    params = %{
      "prompt_source" => "agent",
      "prompt_name" => "01-main.md",
      "expected_hash" => loaded_hash
    }

    html = render_click(view, "delete_prompt", params)
    assert html =~ "Prompt delete conflict"
    assert File.read!(main_path) == "External prompt"

    assert has_element?(
             view,
             "button[phx-value-prompt_name='01-main.md'][phx-value-expected_hash='#{loaded_hash}']"
           )

    html = render_click(view, "delete_prompt", params)
    assert html =~ "Prompt delete conflict"
    assert File.read!(main_path) == "External prompt"
  end

  test "prompt listing skips directories and FIFOs", %{
    conn: conn,
    agent_dir: agent_dir
  } do
    prompts = Path.join(agent_dir, "prompts")
    File.mkdir_p!(Path.join(prompts, "03-directory.md"))
    File.write!(Path.join(prompts, "04-regular.md"), "Regular prompt")
    {_output, 0} = System.cmd("mkfifo", [Path.join(prompts, "05-pipe.md")])

    {:ok, view, _html} = live(conn, "/config/researcher")

    assert has_element?(view, "textarea[aria-label='prompt 04-regular.md']")
    refute has_element?(view, "textarea[aria-label='prompt 03-directory.md']")
    refute has_element?(view, "textarea[aria-label='prompt 05-pipe.md']")
  end

  defp agent_body(id) do
    """
    format-version = 1
    id = "#{id}"

    [model]
    name = "model-a"

    [lifecycle]
    kind = "one-shot"
    """
  end
end
