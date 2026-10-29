defmodule Patchbay.Config.SourceTest do
  use ExUnit.Case, async: true

  alias Patchbay.Config.Source

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "patchbay-source-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "config"))
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root, config_dir: Path.join(root, "config")}
  end

  test "reads a source with its hash and writes when the hash matches", %{config_dir: config_dir} do
    write_source(config_dir, "researcher", agent_body("researcher", "model-a"))

    assert {:ok, %{content: original, hash: hash}} = Source.read(config_dir, "researcher")
    assert hash == Source.hash(original)

    updated = agent_body("researcher", "model-b")

    assert {:ok, %{hash: updated_hash}} =
             Source.write(config_dir, "researcher", updated, hash)

    assert updated_hash == Source.hash(updated)
    assert File.read!(source_path(config_dir, "researcher")) == updated
    assert File.ls!(agent_dir(config_dir, "researcher")) == ["agent.toml"]
  end

  test "rejects a stale hash without touching the file", %{config_dir: config_dir} do
    write_source(config_dir, "researcher", agent_body("researcher", "model-a"))
    assert {:ok, %{hash: hash}} = Source.read(config_dir, "researcher")

    external = agent_body("researcher", "external-model")
    File.write!(source_path(config_dir, "researcher"), external)

    assert {:error, :stale} =
             Source.write(config_dir, "researcher", agent_body("researcher", "mine"), hash)

    assert File.read!(source_path(config_dir, "researcher")) == external
  end

  test "requires an expected hash", %{config_dir: config_dir} do
    write_source(config_dir, "researcher", agent_body("researcher", "model-a"))

    assert {:error, :stale} =
             Source.write(config_dir, "researcher", agent_body("researcher", "model-b"), nil)

    assert {:ok, %{content: content}} = Source.read(config_dir, "researcher")
    assert content == agent_body("researcher", "model-a")
  end

  test "derives paths from the agents directory and rejects traversal", %{config_dir: config_dir} do
    assert {:ok, path} = Source.path(config_dir, "researcher")
    assert path == source_path(config_dir, "researcher")

    assert {:error, :invalid_id} = Source.path(config_dir, "../escape")
    assert {:error, :invalid_id} = Source.path(config_dir, "nested/researcher")
    assert {:error, :invalid_id} = Source.path(config_dir, "..")
    assert {:error, :invalid_id} = Source.path(config_dir, "")
  end

  test "missing sources report not found", %{config_dir: config_dir} do
    assert {:error, :not_found} = Source.read(config_dir, "missing")

    assert {:error, :not_found} =
             Source.write(config_dir, "missing", "id = \"missing\"", Source.hash(""))
  end

  test "rejects a symlinked agent directory", %{root: root, config_dir: config_dir} do
    File.mkdir_p!(Path.join(config_dir, "agents"))
    outside = Path.join(root, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "agent.toml"), agent_body("linked", "model-a"))
    File.ln_s!(outside, agent_dir(config_dir, "linked"))

    original = agent_body("linked", "model-a")

    assert {:error, :unsafe_path} = Source.read(config_dir, "linked")

    assert {:error, :unsafe_path} =
             Source.write(
               config_dir,
               "linked",
               agent_body("linked", "model-b"),
               Source.hash(original)
             )

    assert File.read!(Path.join(outside, "agent.toml")) == original
  end

  test "rejects a symlinked agent.toml", %{root: root, config_dir: config_dir} do
    write_source(config_dir, "researcher", agent_body("researcher", "model-a"))

    outside = Path.join(root, "outside-agent.toml")
    File.write!(outside, agent_body("researcher", "external"))
    File.rm!(source_path(config_dir, "researcher"))
    File.ln_s!(outside, source_path(config_dir, "researcher"))

    assert {:error, :unsafe_path} = Source.read(config_dir, "researcher")

    assert {:error, :unsafe_path} =
             Source.write(
               config_dir,
               "researcher",
               agent_body("researcher", "model-b"),
               Source.hash(agent_body("researcher", "external"))
             )

    assert File.read!(outside) == agent_body("researcher", "external")
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(source_path(config_dir, "researcher"))
  end

  defp agent_dir(config_dir, id), do: Path.join([config_dir, "agents", id])

  defp source_path(config_dir, id), do: Path.join(agent_dir(config_dir, id), "agent.toml")

  defp write_source(config_dir, id, body) do
    directory = agent_dir(config_dir, id)
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "agent.toml"), body)
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
