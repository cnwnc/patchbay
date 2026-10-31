defmodule Patchbay.AgentRunnerResultsTest do
  use ExUnit.Case, async: true

  alias Patchbay.AgentRunner
  alias Patchbay.Definition.Result

  setup do
    definition = %{
      results: [
        %Result{id: "summary", form: :prose, required: true, extensions: []},
        %Result{
          id: "patch",
          form: :file,
          required: false,
          required_by: "summary",
          extensions: ["txt", "diff", ""]
        }
      ]
    }

    %{definition: definition}
  end

  test "accepts a submission with every declared result", %{definition: definition} do
    arguments = %{"results" => %{"summary" => "done", "patch" => "out/final.diff"}}

    assert {:ok, given} = AgentRunner.validate_results(definition, arguments)
    assert given == %{"summary" => "done", "patch" => "out/final.diff"}
  end

  test "requires a dependent result whenever its required-by result is submitted", %{
    definition: definition
  } do
    assert {:error, {:missing_dependent_results, [{"patch", "summary"}]}} =
             AgentRunner.validate_results(definition, %{"results" => %{"summary" => "done"}})

    assert {:error, {:missing_required_results, ["summary"]}} =
             AgentRunner.validate_results(definition, %{"results" => %{"patch" => "final.txt"}})
  end

  test "file results must carry an allowed extension", %{definition: definition} do
    assert {:error, {:invalid_result_values, [{"patch", {:extension_not_allowed, "exe"}}]}} =
             AgentRunner.validate_results(definition, %{
               "results" => %{"summary" => "x", "patch" => "evil.exe"}
             })

    assert {:error, {:invalid_result_values, [{"patch", :expected_non_empty_string}]}} =
             AgentRunner.validate_results(definition, %{
               "results" => %{"summary" => "x", "patch" => "  "}
             })
  end

  test "file results may omit an extension when none are declared" do
    definition = %{results: [%Result{id: "state", form: :file, required: true, extensions: []}]}

    assert {:ok, _} =
             AgentRunner.validate_results(definition, %{"results" => %{"state" => "final-state"}})
  end

  test "paths that are not real file names are rejected", _context do
    definition = %{
      results: [
        %Result{id: "summary", form: :prose, required: true},
        %Result{id: "patch", form: :file, required_by: "summary", extensions: ["txt"]}
      ]
    }

    for bad <- ["../../etc/passwd", ".", "..", "tre/versal/\0bin", "evil.exe"] do
      assert {:error, {:invalid_result_values, [{"patch", reason}]}} =
               AgentRunner.validate_results(definition, %{
                 "results" => %{"summary" => "x", "patch" => bad}
               })

      assert reason == :invalid_file_path or match?({:extension_not_allowed, _}, reason)
    end
  end

  test "an extensionless file is accepted when an empty extension is declared", %{
    definition: definition
  } do
    assert {:ok, _} =
             AgentRunner.validate_results(definition, %{
               "results" => %{"summary" => "x", "patch" => "final-state"}
             })

    assert {:error, {:invalid_result_values, [{"patch", {:extension_not_allowed, "bin"}}]}} =
             AgentRunner.validate_results(
               %{results: Enum.map(definition.results, &%{&1 | extensions: ["txt"]})},
               %{"results" => %{"summary" => "x", "patch" => "final-state"}}
             )
  end

  test "number forms still demand numbers" do
    definition = %{results: [%Result{id: "count", form: :number, required: true}]}

    assert {:error, {:invalid_result_values, [{"count", :expected_number}]}} =
             AgentRunner.validate_results(definition, %{"results" => %{"count" => "three"}})
  end
end
