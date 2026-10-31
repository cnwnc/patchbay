defmodule Patchbay.Toolkit.Native.PersonalMemoryTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Patchbay.Definition
  alias Patchbay.Definition.Toolkit
  alias Patchbay.Toolkit.Manifest
  alias Patchbay.Toolkit.Native.PersonalMemory
  alias Patchbay.Toolkit.Registry

  @tools [
    "remember",
    "append_memory",
    "read_memory",
    "list_memories",
    "recall",
    "delete_memory"
  ]

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "patchbay-personal-memory-#{System.unique_integer([:positive])}"
      )

    state_dir = Path.join(base, "state")
    File.mkdir_p!(state_dir)
    on_exit(fn -> File.rm_rf!(base) end)

    {:ok, base: base, state_dir: state_dir}
  end

  describe "registration" do
    test "the toolkit is registered and its manifest lists every tool" do
      assert Registry.native_module("personal-memory") == PersonalMemory

      assert {:ok, %Manifest{} = manifest} = Manifest.load("personal-memory")
      assert manifest.name == "personal-memory"
      assert manifest.native == "personal-memory"
      assert manifest.tools == @tools
      assert Enum.map(PersonalMemory.tools(%{}), & &1.name) == @tools
    end

    test "agent tool lists include the personal memory tools" do
      definition = %{
        id: "alpha",
        toolkits: [
          %Toolkit{toolkit: "personal-memory", native: "personal-memory", config: %{}}
        ]
      }

      names =
        definition
        |> Patchbay.AgentRunner.tools()
        |> Enum.map(& &1.name)

      assert Enum.all?(@tools, &(&1 in names))
    end

    test "the namespace config is validated as one directory name" do
      assert :ok = PersonalMemory.validate_config(%{}, nil)
      assert :ok = PersonalMemory.validate_config(%{"namespace" => "default"}, nil)

      assert {:error, _message} =
               PersonalMemory.validate_config(%{"namespace" => "../escape"}, nil)

      assert {:error, _message} =
               PersonalMemory.validate_config(%{"namespace" => ".trash"}, nil)
    end
  end

  describe "definition-time validation" do
    test "a traversal namespace fails definition load", %{base: base} do
      config_root = Path.join(base, "config")
      agent_dir = Path.join([config_root, "agents", "alpha"])
      File.mkdir_p!(agent_dir)

      File.write!(
        Path.join(agent_dir, "agent.toml"),
        """
        format-version = 1
        id = "alpha"

        [model]
        name = "test-model"

        [lifecycle]
        kind = "one-shot"

        [[toolkits]]
        toolkit = "personal-memory"

        [toolkits.config]
        namespace = "../outside"
        """
      )

      assert {:error, %Definition.Error{errors: errors}} = Definition.load(agent_dir)

      assert Enum.any?(errors, fn issue ->
               issue.path == ["toolkits", 0, "config", "namespace"]
             end)
    end
  end

  describe "persistence" do
    test "memories and appends survive later calls", %{state_dir: state_dir} do
      alpha = context(state_dir, "alpha")

      assert {:ok, %{status: :ok, path: "projects/acme.md"}} =
               PersonalMemory.execute(
                 "remember",
                 %{
                   "topic" => "projects/acme",
                   "summary" => "Acme rollout",
                   "content" => "First note."
                 },
                 alpha
               )

      assert {:ok, %{output: "# Acme rollout\n\nFirst note.\n"}} =
               PersonalMemory.execute("read_memory", %{"topic" => "projects/acme"}, alpha)

      assert {:ok, %{status: :ok, summary: nil}} =
               PersonalMemory.execute(
                 "append_memory",
                 %{"topic" => "projects/acme", "content" => "Second note."},
                 alpha
               )

      assert {:ok, %{output: output, summary: "Acme rollout"}} =
               PersonalMemory.execute(
                 "read_memory",
                 %{"topic" => "projects/acme"},
                 context(state_dir, "alpha")
               )

      assert output == "# Acme rollout\n\nFirst note.\n\nSecond note.\n"

      assert {:ok, %{summary: "Fresh topic"}} =
               PersonalMemory.execute(
                 "append_memory",
                 %{
                   "topic" => "notes/fresh",
                   "summary" => "Fresh topic",
                   "content" => "Created by append."
                 },
                 alpha
               )

      assert {:ok, %{output: listing, entries: 2, truncated: false}} =
               PersonalMemory.execute("list_memories", %{}, alpha)

      assert listing == "notes/fresh.md\tFresh topic\nprojects/acme.md\tAcme rollout\n"
    end

    test "remember overwrites an existing memory", %{state_dir: state_dir} do
      alpha = context(state_dir, "alpha")

      assert {:ok, _result} =
               PersonalMemory.execute(
                 "remember",
                 %{"topic" => "topic", "summary" => "First", "content" => "old"},
                 alpha
               )

      assert {:ok, _result} =
               PersonalMemory.execute(
                 "remember",
                 %{"topic" => "topic.md", "summary" => "Second", "content" => "new"},
                 alpha
               )

      assert {:ok, %{output: "# Second\n\nnew\n", summary: "Second"}} =
               PersonalMemory.execute("read_memory", %{"topic" => "topic"}, alpha)
    end

    test "append on a new memory requires a summary", %{state_dir: state_dir} do
      assert {:error, :summary_required_for_new_memory} =
               PersonalMemory.execute(
                 "append_memory",
                 %{"topic" => "missing", "content" => "body"},
                 context(state_dir, "alpha")
               )
    end

    test "directories are private and memory files are owner-only", %{state_dir: state_dir} do
      alpha = context(state_dir, "alpha")

      assert {:ok, _result} =
               PersonalMemory.execute(
                 "remember",
                 %{"topic" => "secrets", "summary" => "Private", "content" => "body"},
                 alpha
               )

      agent_root = Path.join([state_dir, "personal-memory", "alpha"])
      namespace = Path.join(agent_root, "default")

      assert mode(agent_root) == 0o700
      assert mode(namespace) == 0o700
      assert mode(Path.join(namespace, "secrets.md")) == 0o600
    end
  end

  describe "per-agent isolation" do
    test "the same topic in two agents stays separate", %{state_dir: state_dir} do
      for {agent, summary} <- [{"alpha", "Alpha memory"}, {"beta", "Beta memory"}] do
        assert {:ok, _result} =
                 PersonalMemory.execute(
                   "remember",
                   %{"topic" => "shared", "summary" => summary, "content" => agent},
                   context(state_dir, agent)
                 )
      end

      assert {:ok, %{output: "# Alpha memory\n\nalpha\n"}} =
               PersonalMemory.execute(
                 "read_memory",
                 %{"topic" => "shared"},
                 context(state_dir, "alpha")
               )

      assert {:ok, %{output: "# Beta memory\n\nbeta\n"}} =
               PersonalMemory.execute(
                 "read_memory",
                 %{"topic" => "shared"},
                 context(state_dir, "beta")
               )

      assert {:ok, %{entries: 1, output: alpha_listing}} =
               PersonalMemory.execute("list_memories", %{}, context(state_dir, "alpha"))

      assert alpha_listing == "shared.md\tAlpha memory\n"
    end

    test "the configured namespace separates memory from the default namespace", %{
      state_dir: state_dir
    } do
      assert {:ok, _result} =
               PersonalMemory.execute(
                 "remember",
                 %{"topic" => "topic", "summary" => "Work", "content" => "body"},
                 context(state_dir, "alpha", %{"namespace" => "work"})
               )

      assert File.exists?(Path.join([state_dir, "personal-memory", "alpha", "work", "topic.md"]))

      assert {:ok, %{entries: 0, output: ""}} =
               PersonalMemory.execute("list_memories", %{}, context(state_dir, "alpha"))
    end
  end

  describe "path confinement" do
    test "traversal and absolute topics are rejected", %{state_dir: state_dir} do
      alpha = context(state_dir, "alpha")

      for topic <- ["../escape", "a/../../escape", "/absolute"] do
        assert {:error, _reason} =
                 PersonalMemory.execute(
                   "remember",
                   %{"topic" => topic, "summary" => "No", "content" => "body"},
                   alpha
                 )
      end
    end

    test "a traversal namespace is rejected", %{state_dir: state_dir} do
      assert {:error, {:namespace, _detail, "../escape"}} =
               PersonalMemory.execute(
                 "list_memories",
                 %{},
                 context(state_dir, "alpha", %{"namespace" => "../escape"})
               )
    end

    test "an invalid agent id is rejected", %{state_dir: state_dir} do
      assert {:error, {:agent_id, _detail, "../alpha"}} =
               PersonalMemory.execute("list_memories", %{}, context(state_dir, "../alpha"))
    end

    test "symlinked directories cannot redirect a write or read", %{
      base: base,
      state_dir: state_dir
    } do
      alpha = context(state_dir, "alpha")

      assert {:ok, _result} =
               PersonalMemory.execute(
                 "remember",
                 %{"topic" => "seed", "summary" => "Seed", "content" => "body"},
                 alpha
               )

      outside = Path.join(base, "outside")
      File.mkdir_p!(outside)

      namespace = Path.join([state_dir, "personal-memory", "alpha", "default"])
      File.ln_s!(outside, Path.join(namespace, "link"))

      assert {:error, {:path_escapes_namespace, _path}} =
               PersonalMemory.execute(
                 "remember",
                 %{"topic" => "link/evil", "summary" => "No", "content" => "body"},
                 alpha
               )

      assert {:error, {:path_escapes_namespace, _path}} =
               PersonalMemory.execute("read_memory", %{"topic" => "link/evil"}, alpha)

      assert {:error, {:path_escapes_namespace, _path}} =
               PersonalMemory.execute("delete_memory", %{"topic" => "link/evil"}, alpha)

      refute File.exists?(Path.join(outside, "evil.md"))
    end

    test "a symlinked target file cannot be read", %{base: base, state_dir: state_dir} do
      alpha = context(state_dir, "alpha")

      assert {:ok, _result} =
               PersonalMemory.execute(
                 "remember",
                 %{"topic" => "seed", "summary" => "Seed", "content" => "body"},
                 alpha
               )

      outside = Path.join(base, "outside.md")
      File.write!(outside, "outside")

      namespace = Path.join([state_dir, "personal-memory", "alpha", "default"])
      File.ln_s!(outside, Path.join(namespace, "linked.md"))

      assert {:error, {:path_escapes_namespace, _path}} =
               PersonalMemory.execute("read_memory", %{"topic" => "linked"}, alpha)
    end
  end

  describe "recall" do
    setup %{state_dir: state_dir} do
      alpha = context(state_dir, "alpha")

      for {topic, summary, content} <- [
            {"summary-match", "Deploy pipeline notes", "Unrelated body"},
            {"body-match", "Other topic", "The deploy appears only in this body"},
            {"unmatched", "Nothing here", "No related words"}
          ] do
        assert {:ok, _result} =
                 PersonalMemory.execute(
                   "remember",
                   %{"topic" => topic, "summary" => summary, "content" => content},
                   alpha
                 )
      end

      {:ok, alpha: alpha}
    end

    test "summary matches rank above body matches", %{alpha: alpha} do
      assert {:ok, %{results: results, count: 2, output: output, truncated: false}} =
               PersonalMemory.execute("recall", %{"query" => "deploy"}, alpha)

      assert Enum.map(results, & &1.path) == ["summary-match.md", "body-match.md"]
      scores = Enum.map(results, & &1.score)
      assert scores == Enum.sort(scores, :desc)
      assert Enum.all?(scores, &(&1 > 0))
      assert output == "summary-match.md\tDeploy pipeline notes\nbody-match.md\tOther topic\n"
    end

    test "the result limit and output bytes are bounded", %{alpha: alpha} do
      assert {:ok, %{count: 1}} =
               PersonalMemory.execute("recall", %{"query" => "deploy", "limit" => 1}, alpha)

      bounded = context(state_dir(alpha), "alpha", %{"max_output_bytes" => 12})

      assert {:ok, %{truncated: true, output: output}} =
               PersonalMemory.execute("recall", %{"query" => "deploy"}, bounded)

      assert byte_size(output) <= 12
    end

    test "a missing match returns an empty result", %{alpha: alpha} do
      assert {:ok, %{count: 0, output: "", truncated: false}} =
               PersonalMemory.execute("recall", %{"query" => "absent"}, alpha)
    end
  end

  describe "deletion" do
    test "delete moves the memory into trash and hides it from reads", %{state_dir: state_dir} do
      alpha = context(state_dir, "alpha")

      for topic <- ["keep", "remove"] do
        assert {:ok, _result} =
                 PersonalMemory.execute(
                   "remember",
                   %{"topic" => topic, "summary" => topic, "content" => "body"},
                   alpha
                 )
      end

      assert {:ok, %{trash: trash, path: "remove.md"}} =
               PersonalMemory.execute("delete_memory", %{"topic" => "remove"}, alpha)

      agent_root = Path.join([state_dir, "personal-memory", "alpha"])
      namespace = Path.join(agent_root, "default")

      refute File.exists?(Path.join(namespace, "remove.md"))
      assert File.exists?(Path.join(agent_root, trash))
      assert File.read!(Path.join(agent_root, trash)) == "# remove\n\nbody\n"

      assert {:error, {:not_found, "remove.md"}} =
               PersonalMemory.execute("read_memory", %{"topic" => "remove"}, alpha)

      assert {:ok, %{entries: 1, output: "keep.md\tkeep\n"}} =
               PersonalMemory.execute("list_memories", %{}, alpha)

      assert {:error, {:not_found, "remove.md"}} =
               PersonalMemory.execute("delete_memory", %{"topic" => "remove"}, alpha)
    end
  end

  defp context(state_dir, agent_id, config \\ %{}) do
    definition = %{
      id: agent_id,
      toolkits: [
        %Toolkit{toolkit: "personal-memory", native: "personal-memory", config: config}
      ]
    }

    %{definition: definition, agent_id: agent_id, state_dir: state_dir}
  end

  defp state_dir(%{state_dir: state_dir}), do: state_dir

  defp mode(path) do
    path
    |> File.stat!()
    |> Map.fetch!(:mode)
    |> band(0o777)
  end
end
