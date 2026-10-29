defmodule Patchbay.DefinitionRegistryTest do
  use ExUnit.Case, async: true

  alias Patchbay.Definition.Error
  alias Patchbay.DefinitionRegistry
  alias Patchbay.DefinitionRegistry.{Failure, Snapshot}

  import Patchbay.DefinitionRegistry, only: [get: 2]

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "patchbay-registry-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "config"))
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root}
  end

  test "reload picks up changed, added, and removed directories", %{root: root} do
    write_agent(root, "researcher", agent_body("researcher", "model-a"))
    write_agent(root, "writer", agent_body("writer", "model-a"))

    registry = start_registry(root)

    assert {:ok, %Snapshot{revision: 1} = original} = get("researcher", registry)

    write_agent(root, "researcher", agent_body("researcher", "model-b"))
    File.rm_rf!(agent_dir(root, "writer"))
    write_agent(root, "analyst", agent_body("analyst", "model-a"))

    assert {:ok, report} = DefinitionRegistry.reload(registry)
    assert Enum.map(report.loaded, & &1.id) == ["analyst", "researcher"]
    assert report.unchanged == []
    assert report.removed == ["writer"]
    assert report.rejected == []

    assert {:ok, %Snapshot{revision: 2} = updated} = get("researcher", registry)

    assert updated.definition.model.name == "model-b"
    refute updated == original

    assert {:ok, %Snapshot{revision: 1}} = get("analyst", registry)
    assert {:error, :not_found} = get("writer", registry)
  end

  test "unchanged directories keep their snapshot without re-reading", %{root: root} do
    write_agent(root, "researcher", agent_body("researcher", "model-a"))
    write_agent(root, "writer", agent_body("writer", "model-a"))

    registry = start_registry(root)
    {:ok, writer_snapshot} = get("writer", registry)

    write_agent(root, "researcher", agent_body("researcher", "model-b"))

    assert {:ok, report} = DefinitionRegistry.reload(registry)
    assert Enum.map(report.loaded, & &1.id) == ["researcher"]
    assert Enum.map(report.unchanged, & &1.id) == ["writer"]
    assert {:ok, ^writer_snapshot} = get("writer", registry)
  end

  test "shared prompt changes reload every agent", %{root: root} do
    write_agent(root, "researcher", agent_body("researcher", "model-a"))
    write_agent(root, "writer", agent_body("writer", "model-a"))
    write_prompt(root, "00-shared.md", "first")

    registry = start_registry(root)
    assert {:ok, %Snapshot{revision: 1}} = get("researcher", registry)
    assert {:ok, %Snapshot{revision: 1}} = get("writer", registry)

    write_prompt(root, "00-shared.md", "second")

    assert {:ok, report} = DefinitionRegistry.reload(registry)
    assert Enum.map(report.loaded, & &1.id) == ["researcher", "writer"]
    assert report.unchanged == []

    assert {:ok, %Snapshot{revision: 2, definition: definition}} =
             get("researcher", registry)

    assert [%{content: "second"}] = definition.prompts
  end

  test "toolkit manifest changes reload every agent", %{root: root} do
    write_agent(root, "researcher", toolkit_agent_body("researcher"))
    write_toolkit(root, "shared", "Shared operations.\n")

    registry = start_registry(root)
    assert {:ok, %Snapshot{revision: 1}} = get("researcher", registry)

    write_toolkit(root, "shared", "Changed shared operations.\n")

    assert {:ok, report} = DefinitionRegistry.reload(registry)
    assert Enum.map(report.loaded, & &1.id) == ["researcher"]

    assert {:ok, %Snapshot{revision: 2}} = get("researcher", registry)
  end

  test "an invalid update is rejected and the last good snapshot survives", %{root: root} do
    write_agent(root, "researcher", agent_body("researcher", "model-a"))

    registry = start_registry(root)
    assert {:ok, snapshot} = get("researcher", registry)

    write_agent(root, "researcher", invalid_body("researcher"))

    assert {:ok, report} = DefinitionRegistry.reload(registry)
    assert [%Failure{id: "researcher", error: %Error{}}] = report.rejected
    assert report.loaded == []
    assert {:ok, ^snapshot} = get("researcher", registry)
    assert [%Failure{id: "researcher"}] = DefinitionRegistry.errors(registry)

    assert {:error, %Error{}} =
             DefinitionRegistry.reload_agent("researcher", registry)

    assert {:ok, ^snapshot} = get("researcher", registry)

    write_agent(root, "researcher", agent_body("researcher", "model-b"))

    assert {:ok, report} = DefinitionRegistry.reload(registry)
    assert [%Snapshot{revision: 2, definition: definition}] = report.loaded
    assert definition.model.name == "model-b"
    assert DefinitionRegistry.errors(registry) == []
  end

  test "an invalid new directory is reported and installed after it becomes valid", %{
    root: root
  } do
    write_agent(root, "researcher", agent_body("researcher", "model-a"))
    write_agent(root, "broken", invalid_body("broken"))

    registry = start_registry(root)
    assert Enum.map(DefinitionRegistry.list(registry), & &1.id) == ["researcher"]
    assert [%Failure{id: "broken"}] = DefinitionRegistry.errors(registry)

    write_agent(root, "broken", agent_body("broken", "model-a"))

    assert {:ok, report} = DefinitionRegistry.reload(registry)
    assert Enum.map(report.loaded, & &1.id) == ["broken"]
    assert {:ok, %Snapshot{revision: 1}} = get("broken", registry)
    assert DefinitionRegistry.errors(registry) == []
  end

  test "ignores symlinked agent directories", %{root: root} do
    write_agent(root, "real", agent_body("real", "model-a"))

    target = Path.join(root, "linked-target")
    File.mkdir_p!(target)
    File.write!(Path.join(target, "agent.toml"), agent_body("linked", "model-a"))
    File.ln_s!(target, agent_dir(root, "linked"))

    registry = start_registry(root)

    assert Enum.map(DefinitionRegistry.list(registry), & &1.id) == ["real"]
    assert DefinitionRegistry.errors(registry) == []
  end

  test "ignores an agent whose agent.toml is a symlink", %{root: root} do
    write_agent(root, "real", agent_body("real", "model-a"))

    directory = agent_dir(root, "linked")
    File.mkdir_p!(directory)
    outside = Path.join(root, "outside-agent.toml")
    File.write!(outside, agent_body("linked", "model-a"))
    File.ln_s!(outside, Path.join(directory, "agent.toml"))

    registry = start_registry(root)

    assert Enum.map(DefinitionRegistry.list(registry), & &1.id) == ["real"]
    assert DefinitionRegistry.errors(registry) == []
  end

  defp start_registry(root) do
    start_supervised!({DefinitionRegistry, [config_dir: config_dir(root), name: nil]})
  end

  defp config_dir(root), do: Path.join(root, "config")

  defp agent_dir(root, id), do: Path.join([config_dir(root), "agents", id])

  defp write_agent(root, id, body) do
    directory = agent_dir(root, id)
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "agent.toml"), body)
  end

  defp write_prompt(root, name, content) do
    directory = Path.join([config_dir(root), "shared", "prompts"])
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, name), content)
  end

  defp write_toolkit(root, name, description) do
    directory = Path.join(config_dir(root), "toolkits")
    File.mkdir_p!(directory)
    description = String.trim_trailing(description)

    File.write!(
      Path.join(directory, name <> ".toml"),
      """
      name = "#{name}"
      description = "#{description}"
      """
    )
  end

  defp toolkit_agent_body(id) do
    """
    format-version = 1
    id = "#{id}"

    [model]
    name = "model-a"

    [lifecycle]
    kind = "one-shot"

    [[toolkits]]
    toolkit = "shared"
    """
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

  defp invalid_body(id) do
    """
    format-version = 2
    id = "#{id}"

    [model]
    name = "model-a"

    [lifecycle]
    kind = "one-shot"
    """
  end
end
