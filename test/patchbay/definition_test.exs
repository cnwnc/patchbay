defmodule Patchbay.DefinitionTest do
  use ExUnit.Case, async: true

  alias Patchbay.Definition
  alias Patchbay.Definition.Agent
  alias Patchbay.Definition.Error
  alias Patchbay.Definition.Result

  @illustrative """
  format-version = 1
  id = "researcher"

  [model]
  provider = "default"
  name = "model-name"
  reasoning = "medium"

  [lifecycle]
  kind = "scheduled"
  schedule = "0 7 * * *"
  overlap = "forbid"
  catch-up = "once"

  [environment]
  packages = ["git", "ripgrep"]

  [[toolkits]]
  toolkit = "memory-file-io"

  [toolkits.config]
  persistence = "run"

  [[toolkits]]
  toolkit = "personal-memory"

  [toolkits.config]
  namespace = "researcher"

  [context]
  between-runs = "handoff"
  prior-runs = "queryable"
  restore-interrupted = "checkpoint"

  [teardown]
  workspace = "destroy"

  [budgets]
  run-seconds = 1800
  tokens = 1000000

  [[results]]
  id = "pull-request"
  form = "url"
  required = false
  label = "The GitHub URL of your submitted pull request"

  [[results]]
  id = "patch-file"
  form = "file"
  required-by = "pull-request"
  extensions = ["patch", "diff", ""]
  label = "A patch containing your pull request's changes"

  [[results]]
  id = "status-message"
  form = "prose"
  label = "Report on what has changed"
  """

  @results """
  [[results]]
  id = "pull-request"
  form = "url"
  required = false
  label = "The GitHub URL of your submitted pull request"

  [[results]]
  id = "patch-file"
  form = "file"
  required-by = "pull-request"
  extensions = ["patch", "diff", ""]
  label = "A patch containing your pull request's changes"

  [[results]]
  id = "status-message"
  form = "prose"
  label = "Report on what has changed"
  """

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "patchbay-definition-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root}
  end

  describe "loading an agent directory" do
    test "loads the illustrative declaration", %{root: root} do
      agent_dir = write_agent(root, "researcher", @illustrative)
      write_prompts(Path.join(agent_dir, "prompts"), ["00-identity.md", "10-behavior.md"])
      write_scripts(Path.join(root, "scripts"), ["publish-update", "check-workspace"])
      write_scripts(Path.join(agent_dir, "scripts"), ["summarize-source"])
      write_toolkit(root, "memory-file-io")
      write_toolkit(root, "personal-memory")

      assert {:ok, %Agent{} = agent} = Definition.load(agent_dir)

      assert agent.id == "researcher"
      assert agent.format_version == 1
      assert agent.path == Path.join(agent_dir, "agent.toml")
      assert agent.agent_dir == agent_dir
      assert agent.config_root == root

      assert agent.model.provider == "default"
      assert agent.model.name == "model-name"
      assert agent.model.reasoning == "medium"

      assert agent.lifecycle.kind == :scheduled
      assert agent.lifecycle.schedule == "0 7 * * *"
      assert agent.lifecycle.overlap == :forbid
      assert agent.lifecycle.catch_up == :once

      assert agent.environment.packages == ["git", "ripgrep"]
      assert agent.context.between_runs == "handoff"
      assert agent.context.prior_runs == "queryable"
      assert agent.context.restore_interrupted == "checkpoint"
      assert agent.teardown.workspace == :destroy
      assert agent.budgets.run_seconds == 1800
      assert agent.budgets.tokens == 1_000_000

      assert [%{toolkit: "memory-file-io", config: %{"persistence" => "run"}}, second] =
               agent.toolkits

      assert second.toolkit == "personal-memory"
      assert second.config == %{"namespace" => "researcher"}

      assert Enum.map(agent.results, &{&1.id, &1.form}) == [
               {"pull-request", :url},
               {"patch-file", :file},
               {"status-message", :prose}
             ]

      assert Enum.map(agent.results, & &1.required) == [false, false, true]

      patch = Enum.find(agent.results, &(&1.id == "patch-file"))
      assert patch.required_by == "pull-request"
      assert patch.extensions == ["patch", "diff", ""]

      assert Enum.map(agent.prompts, & &1.name) == ["00-identity.md", "10-behavior.md"]

      assert Enum.map(agent.shared_scripts, &Path.basename/1) == [
               "check-workspace",
               "publish-update"
             ]

      assert Enum.map(agent.agent_scripts, &Path.basename/1) == ["summarize-source"]
    end

    test "orders shared prompts before agent prompts and ignores other files", %{root: root} do
      agent_dir = write_agent(root, "researcher", minimal())

      write_prompts(Path.join(root, "shared/prompts"), [
        "20-shared.md",
        "00-shared.md",
        "notes.txt"
      ])

      write_prompts(Path.join(agent_dir, "prompts"), [
        "10-behavior.md",
        "00-identity.markdown",
        "helper.exs"
      ])

      File.mkdir_p!(Path.join(agent_dir, "prompts/nested"))
      File.write!(Path.join(agent_dir, "prompts/nested/30-nested.md"), "nested")

      assert {:ok, agent} = Definition.load(agent_dir)

      assert Enum.map(agent.prompts, &{&1.source, &1.name}) == [
               {:shared, "00-shared.md"},
               {:shared, "20-shared.md"},
               {:agent, "00-identity.markdown"},
               {:agent, "10-behavior.md"}
             ]

      assert Enum.map(agent.prompts, & &1.content) == [
               "prompt 00-shared.md",
               "prompt 20-shared.md",
               "prompt 00-identity.markdown",
               "prompt 10-behavior.md"
             ]
    end

    test "records shared and agent script paths in lexical order", %{root: root} do
      agent_dir = write_agent(root, "researcher", minimal())
      write_scripts(Path.join(root, "scripts"), ["b-shared", "a-shared"])
      write_scripts(Path.join(agent_dir, "scripts"), ["z-agent", "a-agent"])
      File.mkdir_p!(Path.join(root, "shared/scripts"))
      File.write!(Path.join(root, "shared/scripts/not-shared"), "decoy")

      assert {:ok, agent} = Definition.load(agent_dir)

      assert Enum.map(agent.shared_scripts, &Path.basename/1) == ["a-shared", "b-shared"]
      assert Enum.map(agent.agent_scripts, &Path.basename/1) == ["a-agent", "z-agent"]

      assert Enum.all?(agent.shared_scripts, &(Path.type(&1) == :absolute))
      assert Enum.all?(agent.agent_scripts, &(Path.type(&1) == :absolute))
    end

    test "requires the agent id to match its directory", %{root: root} do
      agent_dir = write_agent(root, "wrong-name", minimal())

      assert {:error, %Error{errors: errors}} = Definition.load(agent_dir)
      assert error?(errors, ["id"], "must match the agent directory name")
    end

    test "accepts an explicit config root outside the agent tree", %{root: root} do
      agent_dir = Path.join([root, "definitions", "researcher"])
      File.mkdir_p!(agent_dir)
      File.write!(Path.join(agent_dir, "agent.toml"), minimal())

      config_root = Path.join(root, "configuration")
      write_prompts(Path.join(config_root, "shared/prompts"), ["00-shared.md"])
      write_scripts(Path.join(config_root, "scripts"), ["shared-tool"])

      assert {:ok, agent} = Definition.load(agent_dir, config_root: config_root)
      assert agent.config_root == config_root
      assert Enum.map(agent.prompts, & &1.name) == ["00-shared.md"]
      assert Enum.map(agent.shared_scripts, &Path.basename/1) == ["shared-tool"]
    end

    test "load! raises on invalid definitions", %{root: root} do
      agent_dir = write_agent(root, "researcher", minimal(format_version: 2))

      assert_raise Error, ~r/format-version: must be 1/, fn ->
        Definition.load!(agent_dir)
      end
    end
  end

  describe "format and TOML validation" do
    test "rejects an unsupported format version" do
      errors = parse_errors(minimal(format_version: 2))
      assert error?(errors, ["format-version"], "must be 1")
    end

    test "reports TOML syntax errors" do
      assert {:error, %Error{errors: [issue]}} = Definition.parse("not = [valid")
      assert issue.path == []
      assert issue.message =~ "invalid TOML"
    end

    test "requires id, model, and lifecycle" do
      errors =
        parse_errors("""
        format-version = 1
        """)

      assert error?(errors, ["id"], "is required")
      assert error?(errors, ["model"], "is required")
      assert error?(errors, ["lifecycle"], "is required")
    end

    test "rejects non-table sections and non-list declarations" do
      errors =
        parse_errors("""
        format-version = 1
        id = "researcher"
        lifecycle = "scheduled"
        toolkits = "memory"
        results = "pull-request"
        """)

      assert error?(errors, ["lifecycle"], "must be a table")
      assert error?(errors, ["toolkits"], "must be an array of tables")
      assert error?(errors, ["results"], "must be an array of tables")
    end
  end

  describe "lifecycle kinds" do
    test "accepts one-shot and perpetual lifecycles" do
      assert {:ok, %{lifecycle: %{kind: :one_shot, schedule: nil}}} =
               Definition.parse(minimal(lifecycle: ~s(kind = "one-shot")))

      assert {:ok, %{lifecycle: %{kind: :perpetual}}} =
               Definition.parse(minimal(lifecycle: ~s(kind = "perpetual")))
    end

    test "rejects an unknown lifecycle kind" do
      errors = parse_errors(minimal(lifecycle: ~s(kind = "sometimes")))

      assert error?(errors, ["lifecycle", "kind"], "must be one of")
    end

    test "requires a schedule for a scheduled lifecycle" do
      errors = parse_errors(minimal(lifecycle: ~s(kind = "scheduled")))

      assert error?(errors, ["lifecycle", "schedule"], "is required for a scheduled lifecycle")
    end

    test "rejects a schedule on a one-shot lifecycle" do
      errors =
        parse_errors(minimal(lifecycle: ~s(kind = "one-shot"\nschedule = "0 7 * * *")))

      assert error?(errors, ["lifecycle", "schedule"], "only valid for a scheduled lifecycle")
    end

    test "validates scheduled overlap and catch-up values" do
      errors =
        parse_errors(
          minimal(
            lifecycle:
              ~s(kind = "scheduled"\nschedule = "0 7 * * *"\noverlap = "sometimes"\ncatch-up = "later")
          )
        )

      assert error?(errors, ["lifecycle", "overlap"], "must be one of")
      assert error?(errors, ["lifecycle", "catch-up"], "must be one of")
    end

    test "rejects unsupported overlap policies at load time" do
      for overlap <- ["allow", "queue"] do
        errors =
          parse_errors(
            minimal(
              lifecycle: ~s(kind = "scheduled"\nschedule = "0 7 * * *"\noverlap = "#{overlap}")
            )
          )

        assert error?(errors, ["lifecycle", "overlap"], "must be one of")
      end
    end
  end

  describe "result declarations" do
    test "results are required by default and required-by makes them conditional" do
      assert {:ok, %{results: results}} = Definition.parse(minimal(extra: @results))

      assert Enum.map(results, & &1.id) == ["pull-request", "patch-file", "status-message"]
      assert Enum.map(results, & &1.required) == [false, false, true]
      assert Enum.at(results, 1).required_by == "pull-request"
    end

    test "rejects required and required-by on the same result" do
      errors =
        parse_errors(
          minimal(
            extra: """
            [[results]]
            id = "patch"
            form = "file"
            required = true
            required-by = "pull-request"
            label = "Patch"

            [[results]]
            id = "pull-request"
            form = "url"
            label = "PR"
            """
          )
        )

      assert error?(errors, ["results", 0, "required-by"], "mutually exclusive")
    end

    test "rejects references to undeclared results" do
      errors =
        parse_errors(
          minimal(
            extra: """
            [[results]]
            id = "patch"
            form = "file"
            required-by = "pull-request"
            label = "Patch"
            """
          )
        )

      assert error?(errors, ["results", 0, "required-by"], "references undeclared result")
    end

    test "rejects result dependency cycles" do
      errors =
        parse_errors(
          minimal(
            extra: """
            [[results]]
            id = "a"
            form = "prose"
            required-by = "b"
            label = "A"

            [[results]]
            id = "b"
            form = "prose"
            required-by = "a"
            label = "B"
            """
          )
        )

      assert error?(errors, ["results"], "result dependency cycle")
    end

    test "allows acyclic result dependency chains" do
      assert {:ok, %{results: results}} =
               Definition.parse(
                 minimal(
                   extra: """
                   [[results]]
                   id = "artifact"
                   form = "file"
                   required-by = "summary"
                   label = "Artifact"

                   [[results]]
                   id = "summary"
                   form = "prose"
                   required-by = "report"
                   label = "Summary"

                   [[results]]
                   id = "report"
                   form = "prose"
                   label = "Report"
                   """
                 )
               )

      assert Enum.map(results, &{&1.id, &1.required_by}) == [
               {"artifact", "summary"},
               {"summary", "report"},
               {"report", nil}
             ]
    end

    test "rejects duplicate result ids" do
      errors =
        parse_errors(
          minimal(
            extra: """
            [[results]]
            id = "status"
            form = "prose"
            label = "One"

            [[results]]
            id = "status"
            form = "prose"
            label = "Two"
            """
          )
        )

      assert error?(errors, ["results", 1, "id"], "duplicates result")
    end

    test "validation errors keep declared indices after a non-table entry" do
      results = [
        "not-a-table",
        %{"id" => "status", "form" => "prose", "label" => "One"},
        %{"id" => "status", "form" => "prose", "label" => "Two"},
        %{"id" => "extra", "form" => "prose", "label" => "Extra", "required-by" => "missing"}
      ]

      assert {[first, second, third], errors} = Result.from_list(results, [])
      assert first.label == "One"
      assert second.label == "Two"
      assert third.label == "Extra"
      assert error?(errors, ["results", 0], "must be a table")
      assert error?(errors, ["results", 2, "id"], "duplicates result")
      assert error?(errors, ["results", 3, "required-by"], "references undeclared result")
    end

    test "validates forms, labels, and file-only extensions" do
      errors =
        parse_errors(
          minimal(
            extra: """
            [[results]]
            id = "missing-label"
            form = "prose"

            [[results]]
            id = "bad-form"
            form = "table"
            label = "Bad"

            [[results]]
            id = "prose-extensions"
            form = "prose"
            extensions = ["md"]
            label = "Bad extensions"
            """
          )
        )

      assert error?(errors, ["results", 0, "label"], "is required")
      assert error?(errors, ["results", 1, "form"], "must be one of")
      assert error?(errors, ["results", 2, "extensions"], "only valid for a file result")
    end

    test "result structs default to required" do
      assert %Result{required: true, required_by: nil, extensions: []} = %Result{}
    end
  end

  describe "toolkit declarations" do
    test "loads fixed operations with typed arguments" do
      body =
        minimal(
          extra: """
          [[toolkits]]
          toolkit = "fixed-operations"

          [[toolkits.operations]]
          name = "build"
          argv = ["nix", "build", "{%workspace}\#{target}"]

          [toolkits.operations.arguments.target]
          type = "string"
          """
        )

      assert {:ok, %{toolkits: [toolkit]}} = Definition.parse(body)
      assert toolkit.toolkit == "fixed-operations"

      assert [
               %{
                 name: "build",
                 argv: ["nix", "build", "{%workspace}\#{target}"],
                 arguments: arguments
               }
             ] =
               toolkit.operations

      assert arguments["target"].type == :string
    end

    test "accepts an explicit executable with an empty argv" do
      body =
        minimal(
          extra: """
          [[toolkits]]
          toolkit = "fixed-operations"

          [[toolkits.operations]]
          name = "status"
          executable = "/bin/echo"
          argv = []
          """
        )

      assert {:ok, %{toolkits: [toolkit]}} = Definition.parse(body)

      assert [%{name: "status", executable: "/bin/echo", argv: []}] = toolkit.operations
    end

    test "rejects a relative operation executable" do
      errors =
        parse_errors(
          minimal(
            extra: """
            [[toolkits]]
            toolkit = "fixed-operations"

            [[toolkits.operations]]
            name = "status"
            executable = "echo"
            argv = []
            """
          )
        )

      assert error?(errors, ["toolkits", 0, "operations", 0, "executable"], "absolute path")
    end

    test "rejects toolkit declarations without a provider" do
      errors =
        parse_errors(
          minimal(
            extra: """
            [[toolkits]]
            config = { persistence = "run" }
            """
          )
        )

      assert error?(errors, ["toolkits", 0, "toolkit"], "is required")
    end

    test "rejects undeclared argv placeholders" do
      errors =
        parse_errors(
          minimal(
            extra: """
            [[toolkits]]
            toolkit = "fixed-operations"

            [[toolkits.operations]]
            name = "build"
            argv = ["build", "{target}"]
            """
          )
        )

      assert error?(errors, ["toolkits", 0, "operations", 0, "argv", 1], "undeclared argument")
    end

    test "rejects unsupported built-in placeholders" do
      errors =
        parse_errors(
          minimal(
            extra: """
            [[toolkits]]
            toolkit = "fixed-operations"

            [[toolkits.operations]]
            name = "build"
            argv = ["{%registry}"]
            """
          )
        )

      assert error?(errors, ["toolkits", 0, "operations", 0, "argv", 0], "unsupported built-in")
    end

    test "rejects duplicate operation names" do
      errors =
        parse_errors(
          minimal(
            extra: """
            [[toolkits]]
            toolkit = "fixed-operations"

            [[toolkits.operations]]
            name = "build"
            argv = ["nix", "build"]

            [[toolkits.operations]]
            name = "build"
            argv = ["nix", "build", "--rebuild"]
            """
          )
        )

      assert error?(errors, ["toolkits", 0, "operations", 1, "name"], "duplicates operation")
    end

    test "rejects invalid argument types and enum arguments without values" do
      errors =
        parse_errors(
          minimal(
            extra: """
            [[toolkits]]
            toolkit = "fixed-operations"

            [[toolkits.operations]]
            name = "build"
            argv = ["build"]

            [toolkits.operations.arguments.mode]
            type = "enum"

            [toolkits.operations.arguments.target]
            type = "unknown"
            """
          )
        )

      assert error?(
               errors,
               ["toolkits", 0, "operations", 0, "arguments", "mode", "values"],
               "is required for an enum"
             )

      assert error?(
               errors,
               ["toolkits", 0, "operations", 0, "arguments", "target", "type"],
               "must be one of"
             )
    end
  end

  defp minimal(opts \\ []) do
    format_version = Keyword.get(opts, :format_version, 1)
    lifecycle = Keyword.get(opts, :lifecycle, ~s(kind = "one-shot"))
    extra = Keyword.get(opts, :extra, "")

    """
    format-version = #{format_version}
    id = "researcher"

    [model]
    provider = "default"
    name = "model-name"

    [lifecycle]
    #{lifecycle}

    #{extra}
    """
  end

  defp parse_errors(body) do
    assert {:error, %Error{errors: errors}} = Definition.parse(body)
    errors
  end

  defp error?(errors, path, message) do
    Enum.any?(errors, fn issue ->
      issue.path == path and issue.message =~ message
    end)
  end

  defp write_agent(root, id, body) do
    agent_dir = Path.join([root, "agents", id])
    File.mkdir_p!(agent_dir)
    File.write!(Path.join(agent_dir, "agent.toml"), body)
    agent_dir
  end

  defp write_prompts(prompts_dir, names) do
    File.mkdir_p!(prompts_dir)

    Enum.each(names, fn name ->
      File.write!(Path.join(prompts_dir, name), "prompt #{name}")
    end)
  end

  defp write_scripts(scripts_dir, names) do
    File.mkdir_p!(scripts_dir)
    Enum.each(names, fn name -> File.write!(Path.join(scripts_dir, name), "#!/bin/sh\n") end)
  end

  defp write_toolkit(root, name) do
    dir = Path.join(root, "toolkits")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name <> ".toml"), "name = \"#{name}\"\n")
  end
end
