defmodule Patchbay.ToolkitTest.FakeNative do
  @behaviour Patchbay.Toolkit.Native

  @impl true
  def id, do: "fake-test-native"

  @impl true
  def tools(_context) do
    [
      %{
        name: "fake_tool",
        description: "A fake native tool.",
        schema: %{"type" => "object", "properties" => %{}}
      }
    ]
  end

  @impl true
  def execute(_name, _arguments, _context), do: {:ok, %{status: :ok, output: "fake\n"}}
end

defmodule Patchbay.ToolkitTest do
  use ExUnit.Case, async: true

  alias Patchbay.AgentRunner
  alias Patchbay.Definition
  alias Patchbay.Definition.Toolkit
  alias Patchbay.Toolkit.{Hooks, Manifest, Registry, Variables}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "patchbay-toolkit-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root}
  end

  describe "manifests" do
    test "loads a manifest with native composition and fixed operations", %{root: root} do
      dir = Path.join(root, "toolkits")

      write_manifest(dir, "combo", """
      name = "combo"
      description = "Both mechanisms."
      native = "terminal"

      [[operations]]
      name = "echo"
      argv = ["/bin/echo", "{text}"]

      [operations.arguments.text]
      type = "string"
      """)

      assert {:ok, %Manifest{} = manifest} = Manifest.load("combo", toolkit_dirs: [dir])
      assert manifest.name == "combo"
      assert manifest.native == "terminal"
      assert [%{name: "echo", argv: ["/bin/echo", "{text}"]}] = manifest.operations
    end

    test "earlier manifest directories take precedence", %{root: root} do
      config = Path.join(root, "config-toolkits")
      priv = Path.join(root, "priv-toolkits")

      write_manifest(config, "dup", """
      name = "dup"
      description = "from config"
      """)

      write_manifest(priv, "dup", """
      name = "dup"
      description = "from priv"
      """)

      assert {:ok, manifest} =
               Manifest.load("dup", toolkit_dirs: [config, priv])

      assert manifest.description == "from config"
    end

    test "rejects a manifest that names an unregistered native toolkit", %{root: root} do
      dir = Path.join(root, "toolkits")
      path = write_manifest(dir, "ghost", ~s(name = "ghost"\nnative = "ghost-native"\n))

      assert {:error, %Definition.Error{errors: [issue]}} = Manifest.load_file(path)
      assert issue.path == ["native"]
      assert issue.message =~ "unknown native toolkit"
    end

    test "definition loading resolves a manifest from the config root", %{root: root} do
      agent_dir = Path.join([root, "agents", "alpha"])
      File.mkdir_p!(agent_dir)

      File.write!(
        Path.join(agent_dir, "agent.toml"),
        """
        format-version = 1
        id = "alpha"

        [[toolkits]]
        toolkit = "resolved"

        [model]
        name = "test-model"

        [lifecycle]
        kind = "one-shot"
        """
      )

      write_manifest(Path.join(root, "toolkits"), "resolved", """
      name = "resolved"
      description = "Resolved fixed operations."

      [[operations]]
      name = "status"
      argv = ["/bin/echo", "{%agent_id}"]
      """)

      assert {:ok, definition} = Definition.load(agent_dir)

      assert [%Toolkit{toolkit: "resolved", operations: [operation]}] = definition.toolkits
      assert operation.name == "status"
      assert operation.description == nil
      assert definition.toolkits |> hd() |> Map.get(:manifest_path) =~ "toolkits/resolved.toml"
    end

    test "definition parsing resolves manifests only when toolkit dirs are given", %{root: root} do
      dir = Path.join(root, "toolkits")

      write_manifest(dir, "late", """
      name = "late"

      [[operations]]
      name = "late-op"
      argv = ["/bin/echo"]
      """)

      body = agent_toml("[[toolkits]]\ntoolkit = \"late\"")

      assert {:ok, %{toolkits: [toolkit]}} = Definition.parse(body)
      assert toolkit.operations == []

      assert {:ok, %{toolkits: [resolved]}} =
               Definition.parse(body, toolkit_dirs: [dir])

      assert [%{name: "late-op"}] = resolved.operations
    end

    test "embedded built-in manifests load without a priv directory" do
      assert "terminal" in Manifest.builtin_names()
      assert "filesystem" in Manifest.builtin_names()

      assert {:ok, %Manifest{native: "terminal"}} =
               Manifest.load("terminal", toolkit_dirs: [])

      assert {:ok, %Manifest{native: "filesystem"}} =
               Manifest.load("filesystem", toolkit_dirs: [])
    end

    test "a missing or misspelled toolkit is a definition error", %{root: root} do
      agent_dir = Path.join([root, "agents", "alpha"])
      File.mkdir_p!(agent_dir)

      File.write!(
        Path.join(agent_dir, "agent.toml"),
        agent_toml("""
        [[toolkits]]
        toolkit = "termnal"
        """)
      )

      assert {:error, %Definition.Error{errors: errors}} = Definition.load(agent_dir)

      assert Enum.any?(errors, fn issue ->
               issue.path == ["toolkits", 0, "toolkit"] and
                 issue.message =~ "unknown toolkit \"termnal\""
             end)
    end

    test "malformed manifests return validation errors instead of raising", %{root: root} do
      dir = Path.join(root, "toolkits")

      malformed = [
        "not = [valid",
        "name = 42\noperations = 1\n",
        "[[operations]]\nname = 7\nargv = [1]\n",
        "name = \"bad\"\nnative = {}\n",
        "name = \"bad\"\n[[operations]]\nname = \"ok\"\nargv = [\"{%nope}\"]\n"
      ]

      Enum.with_index(malformed)
      |> Enum.each(fn {body, index} ->
        path = write_manifest(dir, "bad-#{index}", body)

        assert {:error, %Definition.Error{errors: errors}} = Manifest.load_file(path)
        assert errors != []
      end)

      agent_dir = Path.join([root, "agents", "alpha"])
      File.mkdir_p!(agent_dir)

      File.write!(
        Path.join(agent_dir, "agent.toml"),
        agent_toml("[[toolkits]]\ntoolkit = \"bad-0\"")
      )

      assert {:error, %Definition.Error{errors: errors}} = Definition.load(agent_dir)
      assert errors != []
    end
  end

  describe "inline operations" do
    test "top-level [[operations]] becomes a fixed toolkit" do
      body =
        agent_toml("""
        [[operations]]
        name = "echo"
        argv = ["/bin/echo", "{text}"]

        [operations.arguments.text]
        type = "string"
        """)

      assert {:ok, %{toolkits: [toolkit]}} = Definition.parse(body)
      assert toolkit.toolkit == "fixed"
      assert toolkit.source == :inline
      assert [%{name: "echo"}] = toolkit.operations
    end

    test "arguments may be declared as child tables below argv" do
      body =
        agent_toml("""
        [[operations]]
        name = "build"
        argv = ["nix", "build", "{target}"]

        [operations.target]
        type = "string"
        required = true
        """)

      assert {:ok, %{toolkits: [toolkit]}} = Definition.parse(body)
      assert [%{arguments: arguments}] = toolkit.operations
      assert %{type: :string, required: true} = arguments["target"]
    end

    test "arguments may be declared as an inline map" do
      body =
        agent_toml("""
        [[operations]]
        name = "build"
        argv = ["nix", "build", "{target}"]
        arguments = { target = { type = "string" }, mode = { type = "enum", values = ["dev", "prod"] } }
        """)

      assert {:ok, %{toolkits: [toolkit]}} = Definition.parse(body)
      assert [%{arguments: arguments}] = toolkit.operations
      assert arguments["target"].type == :string
      assert arguments["mode"].values == ["dev", "prod"]
    end

    test "rejects an argument declared twice" do
      body =
        agent_toml("""
        [[operations]]
        name = "build"
        argv = ["nix", "build", "{target}"]
        arguments = { target = { type = "string" } }

        [operations.target]
        type = "string"
        """)

      assert {:error, %Definition.Error{errors: errors}} = Definition.parse(body)

      assert Enum.any?(errors, fn issue ->
               issue.path == ["operations", 0, "target"] and issue.message =~ "more than once"
             end)
    end
  end

  describe "fixed variables" do
    test "lists the registry names" do
      assert Variables.names() == [
               "workspace",
               "result_dir",
               "agent_id",
               "run_id",
               "attempt_id",
               "agent_state",
               "run_state",
               "agent_scripts",
               "shared_scripts"
             ]
    end

    test "renders fixed variables once and preserves literal braces" do
      variables = %{"workspace" => "/ws", "agent_id" => "alpha"}
      arguments = %{"target" => "{%workspace}"}

      assert {:ok, "/ws/{literal}/{agent_id}"} =
               Variables.render("{%workspace}/{{literal}}/{{agent_id}}", variables, %{})

      assert {:ok, "{%workspace}"} = Variables.render("{target}", variables, arguments)
    end

    test "leaves brace sequences that are not tokens literal" do
      assert {:ok, "a{b c}d"} = Variables.render("a{b c}d", %{}, %{})
      assert {:ok, "{}"} = Variables.render("{}", %{}, %{})
    end

    test "reports an unavailable fixed variable" do
      assert {:error, {:unavailable_variable, "run_id"}} =
               Variables.render("{%run_id}", %{"run_id" => nil}, %{})
    end

    test "reports an unknown fixed variable at definition time" do
      body =
        agent_toml("""
        [[operations]]
        name = "bad"
        argv = ["/bin/echo", "{%registry}"]
        """)

      assert {:error, %Definition.Error{errors: errors}} = Definition.parse(body)

      assert Enum.any?(errors, fn issue ->
               issue.path == ["operations", 0, "argv", 1] and
                 issue.message =~ "unsupported built-in variable"
             end)
    end

    test "reports an undeclared model argument at definition time" do
      body =
        agent_toml("""
        [[operations]]
        name = "bad"
        argv = ["/bin/echo", "{target}"]
        """)

      assert {:error, %Definition.Error{errors: errors}} = Definition.parse(body)

      assert Enum.any?(errors, fn issue ->
               issue.path == ["operations", 0, "argv", 1] and
                 issue.message =~ "undeclared argument"
             end)
    end

    test "validation ignores escaped literal tokens just like rendering" do
      assert Variables.validate("{{%registry}}", %{}) == :ok
      assert Variables.validate("prefix {{%registry}} suffix", %{}) == :ok
      assert {:ok, "{%registry}"} = Variables.render("{{%registry}}", %{}, %{})

      assert {:error, [{:unknown_variable, "registry"}]} =
               Variables.validate("{%registry}", %{})
    end

    test "operation names use the provider function-name shape" do
      body =
        agent_toml("""
        [[operations]]
        name = "bad.name"
        argv = ["/bin/echo"]
        """)

      assert {:error, %Definition.Error{errors: errors}} = Definition.parse(body)

      assert Enum.any?(errors, fn issue ->
               issue.path == ["operations", 0, "name"] and
                 issue.message =~ "provider-safe identifier"
             end)

      operation = %{name: "bad.name", argv: ["/bin/echo"], arguments: %{}}

      assert {:error, {:invalid_operation_name, "bad.name"}} =
               Patchbay.Worker.Operations.validate([operation])
    end

    test "context resolves agent scripts and shared scripts directories" do
      definition = %{
        id: "alpha",
        agent_dir: "/tmp/alpha",
        config_root: "/tmp/root"
      }

      context = Variables.context(definition, agent_id: "alpha", run_id: "run-1")

      assert context["agent_scripts"] == "/tmp/alpha/scripts"
      assert context["shared_scripts"] == "/tmp/root/scripts"
      assert context["agent_id"] == "alpha"
      assert context["run_id"] == "run-1"
      assert context["workspace"] == nil
    end
  end

  describe "native toolkits" do
    test "the terminal toolkit is registered and declared by an implicit manifest" do
      assert Registry.native_module("terminal") == Patchbay.Toolkit.Native.Terminal

      implicit = Manifest.implicit()
      assert Enum.any?(implicit, &(&1.name == "terminal" and &1.native == "terminal"))

      names =
        Registry.implicit_tools(%{definition: %{results: []}})
        |> Enum.map(& &1.name)

      assert "complete_task" in names
      assert "fail_task" in names
    end

    test "implicit manifests are constrained to the terminal toolkit", %{root: root} do
      dir = Path.join(root, "toolkits")

      write_manifest(dir, "global-files", """
      name = "global-files"
      native = "filesystem"
      implicit = true
      tools = ["read_file"]
      """)

      write_manifest(dir, "global-terminal", """
      name = "global-terminal"
      native = "terminal"
      implicit = true
      tools = ["complete_task"]
      """)

      names = Manifest.implicit(config_root: root) |> Enum.map(& &1.name)

      assert "global-terminal" in names
      refute "global-files" in names
      assert Enum.all?(Manifest.implicit(config_root: root), &(&1.native == "terminal"))
    end

    test "a runtime-registered native toolkit supplies model tools" do
      assert :ok = Registry.register("fake-test", Patchbay.ToolkitTest.FakeNative)
      on_exit(fn -> Registry.unregister("fake-test") end)

      assert Registry.native_module("fake-test") == Patchbay.ToolkitTest.FakeNative

      definition = %{
        id: "alpha",
        results: [],
        toolkits: [
          %Toolkit{toolkit: "fake-test", native: "fake-test", tools: ["fake_tool"]}
        ]
      }

      names = definition |> AgentRunner.tools() |> Enum.map(& &1.name)
      assert "fake_tool" in names
      assert "complete_task" in names
      assert "fail_task" in names
    end
  end

  describe "lifecycle hooks" do
    test "parses init and finalize hooks that use fixed variables" do
      body =
        hook_agent("""
        [[lifecycle.init]]
        name = "prepare"
        argv = ["/bin/echo", "{%agent_id}"]

        [[lifecycle.finalize]]
        name = "cleanup"
        executable = "/bin/echo"
        argv = ["{%run_state}"]
        """)

      assert {:ok, %{lifecycle: lifecycle}} = Definition.parse(body)
      assert [%{name: "prepare", argv: ["/bin/echo", "{%agent_id}"]}] = lifecycle.init

      assert [%{name: "cleanup", executable: "/bin/echo", argv: ["{%run_state}"]}] =
               lifecycle.finalize
    end

    test "rejects model arguments in a lifecycle hook" do
      body =
        hook_agent("""
        [[lifecycle.init]]
        name = "bad"
        argv = ["/bin/echo", "{target}"]
        """)

      assert {:error, %Definition.Error{errors: errors}} = Definition.parse(body)

      assert Enum.any?(errors, fn issue ->
               issue.path == ["lifecycle", "init", 0, "argv", 1] and
                 issue.message =~ "cannot reference model argument"
             end)
    end

    test "rejects declared arguments in a lifecycle hook" do
      body =
        hook_agent("""
        [[lifecycle.init]]
        name = "bad"
        argv = ["/bin/echo"]

        [lifecycle.init.arguments.target]
        type = "string"
        """)

      assert {:error, %Definition.Error{errors: errors}} = Definition.parse(body)

      assert Enum.any?(errors, fn issue ->
               issue.message =~ "cannot declare arguments"
             end)
    end

    test "expands and executes a hook with fixed variables" do
      echo = System.find_executable("echo")

      body =
        hook_agent("""
        [[lifecycle.init]]
        name = "prepare"
        argv = ["#{echo}", "{%agent_id}"]
        """)

      assert {:ok, %{lifecycle: lifecycle}} = Definition.parse(body)
      variables = %{"agent_id" => "alpha"}

      assert {:ok, [hook]} = Hooks.expand(lifecycle, :init, variables)
      assert hook == %{name: "prepare", executable: echo, argv: ["alpha"]}
      assert {:ok, %{output: "alpha\n", exit_status: 0}} = Hooks.execute(hook)
    end
  end

  defp agent_toml(extra) do
    """
    format-version = 1
    id = "alpha"

    #{extra}

    [model]
    name = "test-model"

    [lifecycle]
    kind = "one-shot"
    """
  end

  defp hook_agent(extra) do
    """
    format-version = 1
    id = "alpha"

    [model]
    name = "test-model"

    [lifecycle]
    kind = "one-shot"

    #{extra}
    """
  end

  defp write_manifest(dir, name, body) do
    File.mkdir_p!(dir)
    path = Path.join(dir, name <> ".toml")
    File.write!(path, body)
    path
  end
end
