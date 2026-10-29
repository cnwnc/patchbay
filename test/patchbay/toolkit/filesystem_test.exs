defmodule Patchbay.Toolkit.Native.FilesystemTest do
  use ExUnit.Case, async: true

  alias Patchbay.Definition
  alias Patchbay.Definition.Toolkit
  alias Patchbay.Toolkit.Manifest
  alias Patchbay.Toolkit.Native.Filesystem
  alias Patchbay.Toolkit.Registry

  @tools ["read_file", "list_directory", "write_file", "edit_file"]

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "patchbay-filesystem-#{System.unique_integer([:positive])}"
      )

    config_root = Path.join(base, "config")
    work_root = Path.join(config_root, "agents/alpha/work")
    File.mkdir_p!(work_root)

    on_exit(fn -> File.rm_rf!(base) end)

    {:ok,
     base: base,
     config_root: config_root,
     work_root: work_root,
     outside: Path.join(base, "outside")}
  end

  describe "registration" do
    test "the toolkit is registered and loaded from priv/toolkits" do
      assert Registry.native_module("filesystem") == Filesystem

      assert {:ok, %Manifest{} = manifest} = Manifest.load("filesystem")
      assert manifest.name == "filesystem"
      assert manifest.native == "filesystem"
      assert manifest.tools == @tools
      assert Enum.map(Filesystem.tools(%{}), & &1.name) == @tools
    end

    test "agent tool lists include the filesystem tools", %{config_root: config_root} do
      context = context(config_root, "agents/alpha/work")
      definition = context.definition

      names =
        definition
        |> Patchbay.AgentRunner.tools()
        |> Enum.map(& &1.name)

      assert Enum.all?(@tools, &(&1 in names))
    end
  end

  describe "strict nested roots" do
    test "a nested root supports files and directories", %{
      config_root: config_root,
      work_root: work_root
    } do
      context = context(config_root, "agents/alpha/work")

      assert {:ok, %{status: :ok, bytes: 11}} =
               Filesystem.execute(
                 "write_file",
                 %{"path" => "notes/a.txt", "content" => "hello world"},
                 context
               )

      assert File.read!(Path.join(work_root, "notes/a.txt")) == "hello world"

      assert {:ok, %{output: "hello world", path: "notes/a.txt"}} =
               Filesystem.execute("read_file", %{"path" => "notes/a.txt"}, context)

      assert {:ok, %{output: "f a.txt (11 bytes)\n", entries: 1}} =
               Filesystem.execute("list_directory", %{"path" => "notes"}, context)

      assert {:ok, %{output: "edited notes/a.txt\n"}} =
               Filesystem.execute(
                 "edit_file",
                 %{
                   "path" => "notes/a.txt",
                   "old_string" => "world",
                   "new_string" => "there"
                 },
                 context
               )

      assert {:ok, %{output: "hello there"}} =
               Filesystem.execute("read_file", %{"path" => "notes/a.txt"}, context)
    end

    test "the root must be a strict subdirectory of the config root", %{config_root: config_root} do
      for root <- [".", ".."] do
        assert {:error, {:root_not_strictly_below_config_root, _root, _base}} =
                 Filesystem.execute(
                   "read_file",
                   %{"path" => "a.txt"},
                   context(config_root, root)
                 )
      end
    end

    test "an absolute root outside the config root is trusted and confines model paths", %{
      base: base,
      config_root: config_root
    } do
      outside = Path.join(base, "elsewhere")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "a.txt"), "trusted root")
      File.write!(Path.join(base, "outside-root.txt"), "outside")

      context = context(config_root, outside)

      assert {:ok, %{output: "trusted root"}} =
               Filesystem.execute("read_file", %{"path" => "a.txt"}, context)

      assert {:error, {:path_traversal_not_allowed, "../outside-root.txt"}} =
               Filesystem.execute("read_file", %{"path" => "../outside-root.txt"}, context)

      assert {:error, {:absolute_path_not_allowed, _path}} =
               Filesystem.execute(
                 "read_file",
                 %{"path" => Path.join(base, "outside-root.txt")},
                 context
               )
    end

    test "missing roots and missing config roots are rejected", %{
      base: base,
      config_root: config_root
    } do
      assert {:error, {:root, :enoent, _path}} =
               Filesystem.execute(
                 "read_file",
                 %{"path" => "a.txt"},
                 context(config_root, "agents/alpha/missing")
               )

      assert {:error, {:config_root, :enoent, _path}} =
               Filesystem.execute(
                 "read_file",
                 %{"path" => "a.txt"},
                 context(Path.join(base, "missing-config"), "work")
               )
    end

    test "a missing or blank root config is rejected", %{config_root: config_root} do
      definition = %{
        id: "alpha",
        config_root: config_root,
        toolkits: [%Toolkit{toolkit: "filesystem", native: "filesystem"}]
      }

      assert {:error, :filesystem_root_not_configured} =
               Filesystem.execute("read_file", %{"path" => "a.txt"}, %{definition: definition})

      assert {:error, :filesystem_root_not_configured} =
               Filesystem.execute(
                 "read_file",
                 %{"path" => "a.txt"},
                 context(config_root, "")
               )

      assert {:error, :filesystem_config_root_not_configured} =
               Filesystem.execute(
                 "read_file",
                 %{"path" => "a.txt"},
                 %{
                   definition: %{
                     id: "alpha",
                     toolkits: [
                       %Toolkit{
                         toolkit: "filesystem",
                         native: "filesystem",
                         config: %{"root" => "work"}
                       }
                     ]
                   }
                 }
               )
    end

    test "a root symlink inside the config root is allowed", %{
      config_root: config_root,
      outside: outside
    } do
      File.mkdir_p!(outside)
      File.ln_s!(Path.join(config_root, "agents/alpha/work"), Path.join(config_root, "alias"))

      context = context(config_root, "alias")

      assert {:ok, %{status: :ok}} =
               Filesystem.execute("write_file", %{"path" => "a.txt", "content" => "ok"}, context)
    end

    test "a root symlink outside the config root is rejected", %{
      config_root: config_root,
      outside: outside
    } do
      File.mkdir_p!(outside)
      File.ln_s!(outside, Path.join(config_root, "linked-root"))

      assert {:error, {:root_not_strictly_below_config_root, _root, _base}} =
               Filesystem.execute(
                 "read_file",
                 %{"path" => "a.txt"},
                 context(config_root, "linked-root")
               )
    end

    test "sibling directory names sharing the root prefix are outside the root", %{
      config_root: config_root,
      work_root: work_root
    } do
      sibling = Path.join(config_root, "agents/alpha/work-other")
      File.mkdir_p!(sibling)
      File.write!(Path.join(sibling, "secret.txt"), "sibling")
      File.ln_s!(sibling, Path.join(work_root, "sneaky"))

      context = context(config_root, "agents/alpha/work")

      assert {:error, {:path_escapes_root, _link}} =
               Filesystem.execute("read_file", %{"path" => "sneaky/secret.txt"}, context)
    end
  end

  describe "protected roots" do
    test "rejects /proc, manager state, manager runtime, and their ancestors", %{
      base: base,
      config_root: config_root
    } do
      state = Path.join(base, "manager-state")
      runtime = Path.join(state, "runtime")
      File.mkdir_p!(runtime)
      protected = %{state_dir: state, runtime_dir: runtime}

      for root <- ["/proc", "/proc/self", state, runtime, base] do
        assert {:error, {:root_protected, _root, _protected}} =
                 Filesystem.execute(
                   "read_file",
                   %{"path" => "a.txt"},
                   context(config_root, root) |> Map.merge(protected)
                 )
      end
    end

    test "protects explicit secret paths and their ancestors", %{
      base: base,
      config_root: config_root
    } do
      secret_root = Path.join(base, "secrets")
      File.mkdir_p!(secret_root)
      secret = Path.join(secret_root, "ui-token.env")
      File.write!(secret, "secret")

      assert {:error, {:root_protected, _root, _protected}} =
               Filesystem.execute(
                 "read_file",
                 %{"path" => "a.txt"},
                 context(config_root, secret_root)
                 |> Map.put(:secret_roots, [secret])
               )
    end
  end

  describe "model path confinement" do
    test "absolute paths and traversal are rejected", %{config_root: config_root} do
      context = context(config_root, "agents/alpha/work")

      for path <- [
            "/etc/passwd",
            "//etc/passwd",
            "../outside.txt",
            "notes/../../outside.txt",
            "notes/../outside.txt"
          ] do
        assert {:error, error} =
                 Filesystem.execute("read_file", %{"path" => path}, context)

        assert error in [
                 {:absolute_path_not_allowed, path},
                 {:path_traversal_not_allowed, path}
               ]
      end
    end

    test "root-level reads and writes are rejected unless listing", %{config_root: config_root} do
      context = context(config_root, "agents/alpha/work")

      assert {:error, {:invalid_path, "."}} =
               Filesystem.execute("read_file", %{"path" => "."}, context)

      assert {:error, {:invalid_path, "."}} =
               Filesystem.execute("write_file", %{"path" => ".", "content" => "x"}, context)

      assert {:error, {:invalid_path, nil}} =
               Filesystem.execute("read_file", %{}, context)

      assert {:ok, %{path: ".", entries: 0}} =
               Filesystem.execute("list_directory", %{}, context)
    end

    test "symlinks to files outside the root are rejected", %{
      config_root: config_root,
      outside: outside
    } do
      File.mkdir_p!(outside)
      outside_file = Path.join(outside, "secret.txt")
      File.write!(outside_file, "outside")
      link = Path.join(config_root, "agents/alpha/work/escape.txt")
      File.ln_s!(outside_file, link)
      context = context(config_root, "agents/alpha/work")

      assert {:error, {:path_escapes_root, _link}} =
               Filesystem.execute("read_file", %{"path" => "escape.txt"}, context)

      assert {:error, {:path_escapes_root, _link}} =
               Filesystem.execute(
                 "write_file",
                 %{"path" => "escape.txt", "content" => "changed"},
                 context
               )

      assert File.read!(outside_file) == "outside"
    end

    test "missing paths below symlinked directories outside the root are rejected", %{
      config_root: config_root,
      outside: outside,
      work_root: work_root
    } do
      File.mkdir_p!(outside)
      File.ln_s!(outside, Path.join(work_root, "escape-dir"))
      context = context(config_root, "agents/alpha/work")

      assert {:error, {:path_escapes_root, _link}} =
               Filesystem.execute(
                 "write_file",
                 %{"path" => "escape-dir/new.txt", "content" => "nope"},
                 context
               )

      refute File.exists?(Path.join(outside, "new.txt"))
    end

    test "dangling symlinks are rejected without creating their targets", %{
      config_root: config_root,
      outside: outside,
      work_root: work_root
    } do
      File.mkdir_p!(outside)
      File.ln_s!(Path.join(outside, "missing.txt"), Path.join(work_root, "dangling"))
      context = context(config_root, "agents/alpha/work")

      assert {:error, {:broken_symlink, _link}} =
               Filesystem.execute(
                 "write_file",
                 %{"path" => "dangling", "content" => "nope"},
                 context
               )

      refute File.exists?(Path.join(outside, "missing.txt"))
    end

    test "symlinks that stay inside the root are followed", %{
      config_root: config_root,
      work_root: work_root
    } do
      File.write!(Path.join(work_root, "target.txt"), "inside")
      File.ln_s!(Path.join(work_root, "target.txt"), Path.join(work_root, "inside-link"))
      context = context(config_root, "agents/alpha/work")

      assert {:ok, %{output: "inside"}} =
               Filesystem.execute("read_file", %{"path" => "inside-link"}, context)
    end
  end

  describe "bounded operations" do
    test "reads, writes, edits, and listings honour configured limits", %{
      config_root: config_root,
      work_root: work_root
    } do
      context =
        context(config_root, "agents/alpha/work", %{
          "max_read_bytes" => 4,
          "max_write_bytes" => 4,
          "max_list_entries" => 2
        })

      assert {:error, {:content_too_large, "big.txt", 4}} =
               Filesystem.execute(
                 "write_file",
                 %{"path" => "big.txt", "content" => "abcde"},
                 context
               )

      refute File.exists?(Path.join(work_root, "big.txt"))

      assert {:ok, _result} =
               Filesystem.execute(
                 "write_file",
                 %{"path" => "small.txt", "content" => "abcd"},
                 context
               )

      File.write!(Path.join(work_root, "direct.txt"), "abcde")

      assert {:error, {:file_too_large, "direct.txt", 4}} =
               Filesystem.execute("read_file", %{"path" => "direct.txt"}, context)

      assert {:error, {:content_too_large, "small.txt", 4}} =
               Filesystem.execute(
                 "edit_file",
                 %{
                   "path" => "small.txt",
                   "old_string" => "a",
                   "new_string" => "ab"
                 },
                 context
               )

      assert File.read!(Path.join(work_root, "small.txt")) == "abcd"

      for name <- ["one.txt", "two.txt", "three.txt"] do
        File.write!(Path.join(work_root, name), "x")
      end

      assert {:ok, %{entries: 2, truncated: true}} =
               Filesystem.execute("list_directory", %{}, context)
    end

    test "non-text reads are rejected", %{config_root: config_root, work_root: work_root} do
      File.write!(Path.join(work_root, "binary.bin"), <<255, 0, 1>>)
      context = context(config_root, "agents/alpha/work")

      assert {:error, {:not_a_text_file, "binary.bin"}} =
               Filesystem.execute("read_file", %{"path" => "binary.bin"}, context)
    end
  end

  describe "writes and edits" do
    test "overwrites are atomic and leave no temporary files", %{
      config_root: config_root,
      work_root: work_root
    } do
      context = context(config_root, "agents/alpha/work")
      path = Path.join(work_root, "a.txt")
      File.write!(path, "first")

      assert {:ok, %{bytes: 6}} =
               Filesystem.execute(
                 "write_file",
                 %{"path" => "a.txt", "content" => "second"},
                 context
               )

      assert File.read!(path) == "second"
      assert File.ls!(work_root) == ["a.txt"]
    end

    test "parent directories are created and non-directory parents fail", %{
      config_root: config_root,
      work_root: work_root
    } do
      context = context(config_root, "agents/alpha/work")

      assert {:ok, _result} =
               Filesystem.execute(
                 "write_file",
                 %{"path" => "a/b/c.txt", "content" => "nested"},
                 context
               )

      assert File.read!(Path.join(work_root, "a/b/c.txt")) == "nested"

      File.write!(Path.join(work_root, "plain"), "x")

      assert {:error, {:not_a_directory, _path}} =
               Filesystem.execute(
                 "write_file",
                 %{"path" => "plain/child.txt", "content" => "x"},
                 context
               )

      assert {:error, {:is_directory, "a"}} =
               Filesystem.execute("write_file", %{"path" => "a", "content" => "x"}, context)
    end

    test "edits require the old text and support replace_all", %{
      config_root: config_root,
      work_root: work_root
    } do
      context = context(config_root, "agents/alpha/work")
      File.write!(Path.join(work_root, "a.txt"), "one one")

      assert {:error, {:edit_text_not_found, "a.txt"}} =
               Filesystem.execute(
                 "edit_file",
                 %{"path" => "a.txt", "old_string" => "missing", "new_string" => "x"},
                 context
               )

      assert {:ok, _result} =
               Filesystem.execute(
                 "edit_file",
                 %{
                   "path" => "a.txt",
                   "old_string" => "one",
                   "new_string" => "two",
                   "replace_all" => true
                 },
                 context
               )

      assert File.read!(Path.join(work_root, "a.txt")) == "two two"

      assert {:error, :empty_old_string} =
               Filesystem.execute(
                 "edit_file",
                 %{"path" => "a.txt", "old_string" => "", "new_string" => "x"},
                 context
               )
    end
  end

  describe "definition-time root validation" do
    test "a filesystem toolkit requires a root at load time", %{config_root: config_root} do
      agent_dir = write_agent(config_root, "alpha", "[[toolkits]]\ntoolkit = \"filesystem\"\n")

      assert {:error, %Definition.Error{errors: errors}} = Definition.load(agent_dir)

      assert Enum.any?(errors, fn issue ->
               issue.path == ["toolkits", 0, "config", "root"] and
                 issue.message =~ "required"
             end)
    end

    test "a relative root must stay below the config root at load time", %{
      config_root: config_root
    } do
      agent_dir =
        write_agent(
          config_root,
          "alpha",
          """
          [[toolkits]]
          toolkit = "filesystem"

          [toolkits.config]
          root = "../outside"
          """
        )

      assert {:error, %Definition.Error{errors: errors}} = Definition.load(agent_dir)

      assert Enum.any?(errors, fn issue ->
               issue.path == ["toolkits", 0, "config", "root"] and
                 issue.message =~ "strictly below"
             end)
    end

    test "an absolute agent workspace root is trusted configuration", %{
      base: base,
      config_root: config_root
    } do
      workspace = Path.join(base, "agent-workspace")
      File.mkdir_p!(workspace)

      agent_dir =
        write_agent(
          config_root,
          "alpha",
          """
          [[toolkits]]
          toolkit = "filesystem"

          [toolkits.config]
          root = "#{workspace}"
          """
        )

      assert {:ok, definition} = Definition.load(agent_dir)
      context = %{definition: definition}

      assert {:ok, %{status: :ok}} =
               Filesystem.execute("write_file", %{"path" => "a.txt", "content" => "ok"}, context)

      assert File.read!(Path.join(workspace, "a.txt")) == "ok"
    end

    test "protected absolute roots are rejected at load time", %{config_root: config_root} do
      state_dir = Patchbay.Config.load().state_dir

      for root <- ["/proc", state_dir] do
        agent_dir =
          write_agent(
            config_root,
            "alpha",
            """
            [[toolkits]]
            toolkit = "filesystem"

            [toolkits.config]
            root = "#{root}"
            """
          )

        assert {:error, %Definition.Error{errors: errors}} = Definition.load(agent_dir)

        assert Enum.any?(errors, fn issue ->
                 issue.path == ["toolkits", 0, "config", "root"] and
                   issue.message =~ "must not target"
               end)
      end
    end
  end

  defp write_agent(config_root, id, toolkit_body) do
    agent_dir = Path.join([config_root, "agents", id])
    File.mkdir_p!(agent_dir)

    File.write!(
      Path.join(agent_dir, "agent.toml"),
      """
      format-version = 1
      id = "#{id}"

      [model]
      name = "test-model"

      [lifecycle]
      kind = "one-shot"

      #{toolkit_body}
      """
    )

    agent_dir
  end

  defp context(config_root, root, extra_config \\ %{}) do
    config = Map.merge(extra_config, %{"root" => root})

    definition = %{
      id: "alpha",
      config_root: config_root,
      toolkits: [
        %Toolkit{toolkit: "filesystem", native: "filesystem", config: config}
      ]
    }

    %{definition: definition}
  end
end
