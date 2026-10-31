defmodule Patchbay.Config.ManifestTest do
  use ExUnit.Case, async: true

  alias Patchbay.Config.File, as: ConfigFile
  alias Patchbay.Config.Manifest

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "patchbay-manifest-#{System.unique_integer([:positive])}"
      )

    config_dir = Path.join(root, "config")
    File.mkdir_p!(Path.join(config_dir, "toolkits"))
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, config_dir: config_dir}
  end

  test "lists configuration manifests and read-only built-ins", %{config_dir: config_dir} do
    path = Path.join([config_dir, "toolkits", "custom.toml"])
    File.write!(path, "name = \"custom\"\ndescription = \"Custom\"\nnative = \"filesystem\"\n")

    entries = Manifest.entries(config_dir)

    assert [%{id: "custom", source: :config, native: "filesystem"}] = Enum.take(entries, 1)

    builtins = Enum.filter(entries, &(&1.source == :builtin))
    assert "filesystem" in Enum.map(builtins, & &1.id)
    assert "terminal" in Enum.map(builtins, & &1.id)

    assert {:ok, %{read_only?: true, content: content}} =
             Manifest.read(config_dir, "filesystem")

    assert content =~ "name = \"filesystem\""
  end

  test "creates a manifest and refuses to overwrite it", %{config_dir: config_dir} do
    assert {:ok, %{id: "demo", source: :config, native: "filesystem"}} =
             Manifest.create(config_dir, "demo", native: "filesystem")

    path = Path.join([config_dir, "toolkits", "demo.toml"])
    assert File.read!(path) =~ "name = \"demo\""
    assert File.read!(path) =~ "native = \"filesystem\""

    assert {:error, :exists} = Manifest.create(config_dir, "demo")
  end

  test "rejects an unsafe id and an unknown native selection", %{config_dir: config_dir} do
    assert {:error, :invalid_id} = Manifest.create(config_dir, "../escape")
    assert {:error, :invalid_id} = Manifest.create(config_dir, "nested/demo")
    assert {:error, {:invalid, _message}} = Manifest.create(config_dir, "demo", native: "ghost")
    refute File.exists?(Path.join([config_dir, "toolkits", "demo.toml"]))
  end

  test "structured edits cover native selection, tools, config, and operations", %{
    config_dir: config_dir
  } do
    path = Path.join([config_dir, "toolkits", "custom.toml"])

    File.write!(path, """
    name = "custom"
    description = "Custom helpers"
    native = "filesystem"

    # keep the config comment
    [config]
    root = "work"
    keep = "extra"

    # keep the operation comment
    [[operations]]
    name = "echo"
    executable = "/bin/echo"
    argv = ["hello"]
    """)

    assert {:ok, read} = Manifest.read(config_dir, "custom")

    assert {:ok, %{document: document, form: form, errors: []}} =
             Manifest.load(read.content, path)

    form =
      form
      |> Map.put("tools", "read_file\nlist_directory")
      |> Map.put("config_root", "{%workspace}")
      |> Map.put("config_namespace", "notes")
      |> Map.put("operations", [
        Enum.at(form["operations"], 0),
        %{
          "_key" => "1",
          "name" => "build",
          "description" => "Build targets",
          "executable" => "git",
          "argv" => "status\n--short"
        }
      ])

    assert {:ok, content} = Manifest.build(document, form, "custom", config_dir)
    assert content =~ "# keep the config comment"
    assert content =~ "# keep the operation comment"
    assert content =~ ~s(root = "{%workspace}")
    assert content =~ ~s(keep = "extra")
    assert content =~ ~s(namespace = "notes")
    assert content =~ ~s(tools = ["read_file", "list_directory"])
    assert content =~ ~s(name = "build")
    assert content =~ ~s(executable = "git")
    assert content =~ ~s(argv = ["status", "--short"])

    assert {:ok, %{hash: hash}} =
             Manifest.write(config_dir, "custom", content, read.hash)

    assert hash == ConfigFile.hash(content)

    assert {:ok, %{native: "filesystem", operations: operations}} =
             Manifest.get(config_dir, "custom")

    assert operations == ["echo", "build"]
  end

  test "structured edits keep the [toolkit] table form", %{config_dir: config_dir} do
    path = Path.join([config_dir, "toolkits", "table.toml"])

    File.write!(path, """
    [toolkit]
    name = "table"
    description = "Before"
    native = "terminal"

    [toolkit.config]
    keep = "value"
    """)

    assert {:ok, read} = Manifest.read(config_dir, "table")
    assert {:ok, %{document: document, form: form}} = Manifest.load(read.content, path)
    form = Map.put(form, "description", "After")
    assert {:ok, content} = Manifest.build(document, form, "table", config_dir)

    assert content =~ "[toolkit]"
    assert content =~ ~s(description = "After")
    assert content =~ ~s(native = "terminal")
    assert content =~ ~s(keep = "value")

    assert {:ok, %{hash: hash}} = Manifest.write(config_dir, "table", content, read.hash)
    assert hash == ConfigFile.hash(content)

    assert {:ok, %{native: "terminal", description: "After"}} =
             Manifest.get(config_dir, "table")
  end

  test "structured operations with only an executable keep an empty argv", %{
    config_dir: config_dir
  } do
    assert {:ok, _entry} = Manifest.create(config_dir, "demo")
    assert {:ok, read} = Manifest.read(config_dir, "demo")
    assert {:ok, %{document: document, form: form}} = Manifest.load(read.content, read.path)

    form =
      Map.put(form, "operations", [
        %{
          "_key" => "0",
          "name" => "pwd",
          "description" => "",
          "executable" => "pwd",
          "argv" => ""
        }
      ])

    assert {:ok, content} = Manifest.build(document, form, "demo", config_dir)
    assert content =~ ~s(name = "pwd")
    assert content =~ ~s(executable = "pwd")
    assert content =~ "argv = []"
  end

  test "rejects invalid structured operations before writing", %{config_dir: config_dir} do
    assert {:ok, _entry} = Manifest.create(config_dir, "demo")
    assert {:ok, read} = Manifest.read(config_dir, "demo")
    assert {:ok, %{document: document, form: form}} = Manifest.load(read.content, read.path)

    form =
      Map.put(form, "operations", [
        %{"_key" => "0", "name" => "bad", "description" => "", "executable" => "", "argv" => ""}
      ])

    assert {:error, message} = Manifest.build(document, form, "demo", config_dir)
    assert message =~ "requires an executable"
  end

  test "clearing the environment secrets form removes the config env table", %{
    config_dir: config_dir
  } do
    path = Path.join([config_dir, "toolkits", "secret.toml"])

    File.write!(path, """
    name = "secret"
    native = "secret-env"

    [config]
    keep = "value"

    [config.env]
    TOKEN = "secret://token"
    """)

    assert {:ok, read} = Manifest.read(config_dir, "secret")
    assert {:ok, %{document: document, form: form}} = Manifest.load(read.content, path)
    assert form["config_env"] =~ "TOKEN=secret://token"

    form = Map.put(form, "config_env", "")
    assert {:ok, content} = Manifest.build(document, form, "secret", config_dir)

    refute content =~ "config.env"
    refute content =~ "TOKEN"
    assert content =~ ~s(keep = "value")

    assert {:ok, %{hash: hash}} = Manifest.write(config_dir, "secret", content, read.hash)
    assert hash == ConfigFile.hash(content)

    {:ok, read} = Manifest.read(config_dir, "secret")
    {:ok, %{form: form}} = Manifest.load(read.content, path)
    assert form["config_env"] == ""
  end

  test "invalid manifest file names are listed with an error and are not selectable ids", %{
    config_dir: config_dir
  } do
    path = Path.join([config_dir, "toolkits", "Not Valid.toml"])
    File.write!(path, "name = \"not-valid\"\nnative = \"filesystem\"\n")

    entries = Manifest.entries(config_dir)

    assert %{id: "Not Valid", path: ^path, error: error, native: nil, tools: []} =
             Enum.find(entries, &(&1.id == "Not Valid"))

    assert error =~ "not a valid manifest ID"
    assert {:error, :invalid_id} = Manifest.read(config_dir, "Not Valid")
    assert {:error, :invalid_id} = Manifest.get(config_dir, "Not Valid")
  end

  test "a stale write leaves external bytes and reports a conflict", %{config_dir: config_dir} do
    assert {:ok, _entry} = Manifest.create(config_dir, "demo")
    assert {:ok, %{hash: hash}} = Manifest.read(config_dir, "demo")

    path = Path.join([config_dir, "toolkits", "demo.toml"])
    external = "name = \"demo\"\ndescription = \"external\"\n"
    File.write!(path, external)

    assert {:error, :stale} =
             Manifest.write(config_dir, "demo", "name = \"demo\"\n", hash)

    assert File.read!(path) == external
  end

  test "invalid manifest text is rejected without writing", %{config_dir: config_dir} do
    assert {:ok, _entry} = Manifest.create(config_dir, "demo")
    assert {:ok, %{hash: hash, content: original}} = Manifest.read(config_dir, "demo")

    assert {:error, {:invalid, message}} =
             Manifest.write(config_dir, "demo", "name = \"demo\"\nnative = \"ghost\"\n", hash)

    assert message =~ "unknown native toolkit"
    assert File.read!(Path.join([config_dir, "toolkits", "demo.toml"])) == original
  end

  test "embedded manifests are read-only until overridden", %{config_dir: config_dir} do
    assert {:ok, %{hash: hash, content: content}} = Manifest.read(config_dir, "terminal")

    assert {:error, :read_only} =
             Manifest.write(config_dir, "terminal", content <> "\n", hash)

    assert {:ok, %{source: :config, builtin_override?: true}} =
             Manifest.create(config_dir, "terminal")

    overridden = Enum.filter(Manifest.entries(config_dir), &(&1.id == "terminal"))
    assert [%{source: :config, builtin_override?: true}] = overridden
  end

  test "rejects traversal outside the toolkits directory", %{config_dir: config_dir} do
    assert {:error, :invalid_id} = Manifest.path(config_dir, "../escape")
    assert {:error, :invalid_id} = Manifest.path(config_dir, "nested/demo")
    assert {:error, :invalid_id} = Manifest.path(config_dir, ".hidden")
  end
end
