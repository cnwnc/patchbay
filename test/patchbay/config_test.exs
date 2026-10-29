defmodule Patchbay.ConfigTest do
  use ExUnit.Case, async: true

  alias Patchbay.Config

  test "PATCHBAY_HOME supplies default config and state directories" do
    home = Path.join(System.tmp_dir!(), "patchbay-home-#{System.unique_integer([:positive])}")

    assert %Config{
             home: ^home,
             config_dir: config,
             state_dir: state,
             runtime_dir: runtime,
             workspace_dir: workspace,
             result_dir: results
           } = Config.load(env: %{"PATCHBAY_HOME" => home})

    assert config == Path.join(home, "config")
    assert state == Path.join(home, "state")
    assert runtime == Path.join(state, "runtime")
    assert workspace == Path.join(home, "workspaces")
    assert results == Path.join(home, "results")
  end

  test "environment paths resolve with bare state/runtime fallbacks and option precedence" do
    root = Path.join(System.tmp_dir!(), "patchbay-config-#{System.unique_integer([:positive])}")

    env = %{
      "PATCHBAY_CONFIG_DIR" => Path.join(root, "from-env-config"),
      "STATE_DIR" => Path.join(root, "from-env-state"),
      "RUNTIME_DIR" => Path.join(root, "from-env-runtime")
    }

    assert %Config{
             config_dir: config,
             state_dir: state,
             runtime_dir: runtime
           } = Config.load(env: env)

    assert config == Path.join(root, "from-env-config")
    assert state == Path.join(root, "from-env-state")
    assert runtime == Path.join(root, "from-env-runtime")

    assert %Config{config_dir: config, state_dir: state} =
             Config.load(env: env, config_dir: Path.join(root, "override-config"))

    assert config == Path.join(root, "override-config")
    assert state == Path.join(root, "from-env-state")

    assert %Config{runtime_dir: runtime} = Config.load(env: %{"STATE_DIR" => state})
    assert runtime == Path.join(state, "runtime")
  end
end
