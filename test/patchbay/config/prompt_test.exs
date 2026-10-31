defmodule Patchbay.Config.PromptTest do
  use ExUnit.Case, async: true

  alias Patchbay.Config.File, as: ConfigFile
  alias Patchbay.Config.Prompt

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "patchbay-prompt-#{System.unique_integer([:positive])}"
      )

    config_dir = Path.join(root, "config")
    agent_dir = Path.join([config_dir, "agents", "researcher"])
    File.mkdir_p!(Path.join(agent_dir, "prompts"))
    File.mkdir_p!(Path.join([config_dir, "shared", "prompts"]))
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, config_dir: config_dir, agent_dir: agent_dir}
  end

  test "lists shared prompts before agent prompts, ordered by filename", %{config_dir: config_dir} do
    File.write!(Path.join([config_dir, "shared", "prompts", "02-shared.md"]), "shared two")
    File.write!(Path.join([config_dir, "shared", "prompts", "01-shared.md"]), "shared one")

    File.write!(
      Path.join([config_dir, "agents", "researcher", "prompts", "01-agent.md"]),
      "agent"
    )

    File.write!(Path.join([config_dir, "agents", "researcher", "prompts", "ignore.txt"]), "no")
    File.mkdir_p!(Path.join([config_dir, "agents", "researcher", "prompts", "nested"]))

    File.write!(
      Path.join([config_dir, "agents", "researcher", "prompts", "nested", "x.md"]),
      "no"
    )

    prompts = Prompt.list(config_dir, "researcher")

    assert Enum.map(prompts, &{&1.name, &1.source}) == [
             {"01-shared.md", :shared},
             {"02-shared.md", :shared},
             {"01-agent.md", :agent}
           ]

    assert Enum.map(prompts, & &1.content) == ["shared one", "shared two", "agent"]
  end

  test "lists prompt files while skipping directories, FIFOs, and dangling entries", %{
    config_dir: config_dir,
    agent_dir: agent_dir
  } do
    prompts = Path.join(agent_dir, "prompts")
    File.write!(Path.join(prompts, "01-main.md"), "main")
    File.mkdir_p!(Path.join(prompts, "02-directory.md"))

    File.ln_s!(
      Path.join(Path.dirname(config_dir), "missing.md"),
      Path.join(prompts, "03-gone.md")
    )

    fifo = Path.join(prompts, "04-pipe.md")
    {_output, 0} = System.cmd("mkfifo", [fifo])

    listed = Prompt.list(config_dir, "researcher")

    assert Enum.map(listed, & &1.name) == ["01-main.md", "03-gone.md"]
    assert Enum.find(listed, &(&1.name == "03-gone.md")).error =~ "not editable"
  end

  test "creates, updates, and deletes an agent prompt", %{config_dir: config_dir} do
    assert {:ok, %{hash: hash, source: :agent}} =
             Prompt.create(config_dir, "researcher", "agent", "01-system.md", "first")

    path = Path.join([config_dir, "agents", "researcher", "prompts", "01-system.md"])
    assert File.read!(path) == "first"

    assert {:ok, %{hash: updated_hash}} =
             Prompt.write(config_dir, "researcher", "agent", "01-system.md", "second", hash)

    assert updated_hash == ConfigFile.hash("second")
    assert File.read!(path) == "second"

    assert :ok =
             Prompt.delete(config_dir, "researcher", "agent", "01-system.md", updated_hash)

    refute File.exists?(path)
  end

  test "creates missing shared prompt directories", %{config_dir: config_dir} do
    File.rm_rf!(Path.join([config_dir, "shared", "prompts"]))

    assert {:ok, %{path: path}} =
             Prompt.create(config_dir, "researcher", "shared", "00-shared.md", "hello")

    assert path == Path.join([config_dir, "shared", "prompts", "00-shared.md"])
    assert File.read!(path) == "hello"
  end

  test "refuses to overwrite an existing prompt", %{config_dir: config_dir} do
    assert {:ok, _entry} =
             Prompt.create(config_dir, "researcher", "agent", "01-system.md", "first")

    assert {:error, :exists} =
             Prompt.create(config_dir, "researcher", "agent", "01-system.md", "second")
  end

  test "a stale update leaves the external bytes in place", %{config_dir: config_dir} do
    assert {:ok, %{hash: hash}} =
             Prompt.create(config_dir, "researcher", "agent", "01-system.md", "first")

    path = Path.join([config_dir, "agents", "researcher", "prompts", "01-system.md"])
    File.write!(path, "external")

    assert {:error, :stale} =
             Prompt.write(config_dir, "researcher", "agent", "01-system.md", "mine", hash)

    assert File.read!(path) == "external"
  end

  test "a stale delete leaves the file in place", %{config_dir: config_dir} do
    assert {:ok, %{hash: hash}} =
             Prompt.create(config_dir, "researcher", "agent", "01-system.md", "first")

    path = Path.join([config_dir, "agents", "researcher", "prompts", "01-system.md"])
    File.write!(path, "external")

    assert {:error, :stale} =
             Prompt.delete(config_dir, "researcher", "agent", "01-system.md", hash)

    assert File.read!(path) == "external"
  end

  test "rejects nested and parent paths", %{config_dir: config_dir} do
    assert {:error, :invalid_filename} =
             Prompt.create(config_dir, "researcher", "agent", "../escape.md", "x")

    assert {:error, :invalid_filename} =
             Prompt.create(config_dir, "researcher", "agent", "nested/x.md", "x")

    assert {:error, :invalid_filename} =
             Prompt.create(config_dir, "researcher", "agent", "x.txt", "x")

    assert {:error, :invalid_id} =
             Prompt.create(config_dir, "../researcher", "agent", "x.md", "x")

    refute File.exists?(Path.join(config_dir, "escape.md"))
  end

  test "rejects a symlinked prompt directory", %{config_dir: config_dir} do
    prompts = Path.join([config_dir, "agents", "researcher", "prompts"])
    outside = Path.join(Path.dirname(config_dir), "outside-prompts")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "outside.md"), "outside")
    File.rm_rf!(prompts)
    File.ln_s!(outside, prompts)

    assert {:error, :unsafe_path} =
             Prompt.path(config_dir, "researcher", "agent", "outside.md")

    assert Prompt.list(config_dir, "researcher") == []
  end

  test "rejects a symlinked prompt file", %{config_dir: config_dir} do
    outside = Path.join(Path.dirname(config_dir), "outside.md")
    File.write!(outside, "outside")
    link = Path.join([config_dir, "agents", "researcher", "prompts", "linked.md"])
    File.ln_s!(outside, link)

    assert {:error, :unsafe_path} = Prompt.read(config_dir, "researcher", "agent", "linked.md")

    assert {:error, :unsafe_path} =
             Prompt.write(
               config_dir,
               "researcher",
               "agent",
               "linked.md",
               "changed",
               ConfigFile.hash("outside")
             )

    assert File.read!(outside) == "outside"
  end
end
