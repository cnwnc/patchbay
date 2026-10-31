defmodule Patchbay.Secrets.EnvTest do
  use ExUnit.Case, async: true

  alias Patchbay.Definition.Toolkit
  alias Patchbay.Secrets
  alias Patchbay.Secrets.Env

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "patchbay-secret-env-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    %{tmp: tmp, root: Path.join(tmp, "secrets")}
  end

  test "reads declarations from a secret-env toolkit", %{root: root} do
    definition = definition(%{"GH_TOKEN" => "secret://github-main"})
    :ok = Secrets.put(root, "github-main", "ghp_value\n")

    assert {:ok, %{"GH_TOKEN" => "github-main"}} = Env.declarations(definition)

    assert {:ok, %{"GH_TOKEN" => "ghp_value\n"}} =
             Env.resolve(%{"GH_TOKEN" => "github-main"}, root)
  end

  test "ignores toolkits that are not secret-env" do
    definition = %{toolkits: [%Toolkit{toolkit: "filesystem", native: "filesystem"}]}
    assert Env.declarations(definition) == {:ok, %{}}
  end

  test "recognizes a parsed secret-env toolkit before manifest resolution" do
    definition = %{
      toolkits: [
        %Toolkit{
          toolkit: "secret-env",
          native: nil,
          config: %{"env" => %{"GH_TOKEN" => "secret://github-main"}}
        }
      ]
    }

    assert Env.declarations(definition) == {:ok, %{"GH_TOKEN" => "github-main"}}
  end

  test "rejects literal values and echoes only the variable name" do
    definition = definition(%{"GH_TOKEN" => "hunter2-literal"})

    assert {:error, {path, message}} = Env.declarations(definition)
    assert path == ["env", "GH_TOKEN"]
    assert message == "must reference a secret as secret://<name>"
    refute message =~ "hunter2"
  end

  test "rejects a bare secret name as well as a bad reference name" do
    assert {:error, {_, _}} = Env.declarations(definition(%{"GH_TOKEN" => "github-main"}))
    assert {:error, {_, _}} = Env.declarations(definition(%{"GH_TOKEN" => "secret://../escape"}))
    assert {:error, {_, _}} = Env.declarations(definition(%{"GH_TOKEN" => "secret://Upper"}))
  end

  test "rejects reserved and malformed environment variable names" do
    assert {:error, {["env", "PATCHBAY_WORKER_TOKEN"], _}} =
             Env.declarations(definition(%{"PATCHBAY_WORKER_TOKEN" => "secret://github-main"}))

    assert {:error, {["env", "PATH"], _}} =
             Env.declarations(definition(%{"PATH" => "secret://github-main"}))

    assert {:error, {["env", "lower"], _}} =
             Env.declarations(definition(%{"lower" => "secret://github-main"}))
  end

  test "rejects duplicate variables across declarations" do
    definition = %{
      toolkits: [
        secret_toolkit(%{"GH_TOKEN" => "secret://one"}),
        secret_toolkit(%{"GH_TOKEN" => "secret://two"})
      ]
    }

    assert Env.declarations(definition) == {:error, {:duplicate_variable, "GH_TOKEN"}}
  end

  test "does not touch the store when there are no declarations", %{root: root} do
    assert {:ok, %{}} = Env.resolve(%{}, root)
    refute File.exists?(root)
  end

  test "a missing secret fails resolution without leaking a value", %{root: root} do
    assert {:error, {:missing_secret, "github-main"}} =
             Env.resolve(%{"GH_TOKEN" => "github-main"}, root)

    refute File.exists?(root)
  end

  test "validates a config table for definition load" do
    assert Env.validate_config(%{"env" => %{"GH_TOKEN" => "secret://github-main"}}) == :ok
    assert {:error, ["env"], "must be a table"} = Env.validate_config(%{"env" => "nope"})

    assert {:error, ["env", "GH_TOKEN"], _} =
             Env.validate_config(%{"env" => %{"GH_TOKEN" => "value"}})
  end

  test "loads through the built-in manifest and rejects a literal reference" do
    dirs = [Path.expand("priv/toolkits")]

    assert {:ok, definition} =
             Patchbay.Definition.parse(agent_toml("secret://github-main"), toolkit_dirs: dirs)

    assert [%Toolkit{toolkit: "secret-env", native: "secret-env"}] = definition.toolkits

    assert {:error, error} =
             Patchbay.Definition.parse(agent_toml("hunter2-literal"), toolkit_dirs: dirs)

    message = Exception.message(error)
    refute message =~ "hunter2"
    assert message =~ "secret://<name>"
    assert message =~ "GH_TOKEN"
  end

  defp agent_toml(reference) do
    """
    format-version = 1
    id = "alpha"

    [model]
    name = "test-model"

    [lifecycle]
    kind = "one-shot"

    [[toolkits]]
    toolkit = "secret-env"

    [toolkits.config.env]
    GH_TOKEN = "#{reference}"
    """
  end

  defp definition(env) do
    %{toolkits: [secret_toolkit(env)]}
  end

  defp secret_toolkit(env) do
    %Toolkit{toolkit: "secret-env", native: "secret-env", config: %{"env" => env}}
  end
end
