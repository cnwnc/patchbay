defmodule PatchbayWeb.ConsoleLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Patchbay.DefinitionRegistry
  alias Patchbay.Runtime

  @endpoint PatchbayWeb.Endpoint

  setup do
    root = Path.join(System.tmp_dir!(), "patchbay-web-#{System.unique_integer([:positive])}")
    config_dir = Path.join(root, "config")
    state_dir = Path.join(root, "state")
    agent_dir = Path.join([config_dir, "agents", "researcher"])
    shared_prompts = Path.join([config_dir, "shared", "prompts"])

    File.mkdir_p!(Path.join(agent_dir, "prompts"))
    File.mkdir_p!(shared_prompts)
    File.mkdir_p!(Path.join(config_dir, "toolkits"))
    File.write!(Path.join([config_dir, "toolkits", "http.toml"]), "name = \"http\"\n")
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

    [[toolkits]]
    toolkit = "http"

    [toolkits.config]
    api-key = "sk-live-raw-value"
    password = "hunter2"
    access-key = "AKIARAWVALUE"
    token-ref = "${PATCHBAY_TOKEN}"
    endpoint = "https://example.test/v1"

    inline-credentials = { token = "inline-raw-value", ref = "${INLINE_TOKEN}" }
    """)

    File.write!(Path.join(agent_dir, "prompts/00-main.md"), "Agent prompt")
    File.write!(Path.join(shared_prompts, "00-shared.md"), "Shared prompt")

    start_supervised!({DefinitionRegistry, name: DefinitionRegistry, config_dir: config_dir})

    start_supervised!(
      {Runtime,
       name: Runtime,
       definitions: {DefinitionRegistry, DefinitionRegistry},
       manager: nil,
       state_dir: state_dir}
    )

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, conn: build_conn()}
  end

  test "console lists definitions and shows the selected agent", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "researcher"
    assert html =~ "PERPETUAL"
    assert html =~ "IDLE"
    assert html =~ "BETWEEN prompt"
    assert html =~ "STREAM"
  end

  test "configuration shows source, resolved data and prompts", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/config")

    assert html =~ "researcher"
    assert html =~ "SOURCE"
    assert html =~ "RESOLVED"
    assert html =~ "Shared prompt"
    assert html =~ "Agent prompt"
    assert html =~ "00-shared.md"
  end

  test "configuration redacts secret values in source and resolved views but keeps refs", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, "/config")

    assert html =~ "[REDACTED]"
    assert html =~ "${PATCHBAY_TOKEN}"
    assert html =~ "${INLINE_TOKEN}"
    assert html =~ "https://example.test/v1"

    refute html =~ "sk-live-raw-value"
    refute html =~ "hunter2"
    refute html =~ "AKIARAWVALUE"
    refute html =~ "inline-raw-value"
  end
end
