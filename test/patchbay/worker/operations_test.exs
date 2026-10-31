defmodule Patchbay.Worker.OperationsTest do
  use ExUnit.Case, async: true

  alias Patchbay.Worker.Operations

  setup do
    tmp = Path.join(System.tmp_dir!(), "patchbay-ops-#{System.unique_integer([:positive])}")
    workspace = Path.join(tmp, "workspace")
    File.mkdir_p!(Path.join(workspace, "sub"))
    on_exit(fn -> File.rm_rf(tmp) end)

    %{tmp: tmp, workspace: workspace, echo: executable!("echo")}
  end

  test "loads operations from a safe external term file", %{
    tmp: tmp,
    workspace: workspace,
    echo: echo
  } do
    specs = [
      %{
        name: "echo",
        executable: echo,
        argv: ["{%workspace}", "{text}"],
        arguments: %{"text" => %{type: :string, required: true}}
      }
    ]

    path = Path.join(tmp, "operations.pbt")
    File.write!(path, :erlang.term_to_binary(specs))

    assert {:ok, [operation]} = Operations.load(path)
    assert operation.name == "echo"
    assert Operations.names([operation]) == ["echo"]

    assert {:ok, result} =
             Operations.execute([operation], "echo", %{"text" => "a b; echo pwned"},
               workspace: workspace
             )

    assert result.status == :ok
    assert result.output == "#{workspace} a b; echo pwned\n"
  end

  test "validates and converts typed arguments", %{workspace: workspace, echo: echo} do
    operation = %{
      name: "count",
      executable: echo,
      argv: ["{count}", "{enabled}", "{kind}", "{file}"],
      arguments: %{
        "count" => %{type: :integer, required: true},
        "enabled" => %{type: :boolean},
        "kind" => %{type: :enum, values: ["alpha", "beta"]},
        "file" => %{type: :path}
      }
    }

    assert {:ok, result} =
             Operations.execute(
               [operation],
               "count",
               %{
                 "count" => 42,
                 "enabled" => false,
                 "kind" => "beta",
                 "file" => "sub/note.txt"
               },
               workspace: workspace
             )

    assert result.output == "42 false beta #{Path.join(workspace, "sub/note.txt")}\n"
  end

  test "rejects unknown, missing, and invalid arguments", %{workspace: workspace, echo: echo} do
    operation = %{
      name: "echo",
      executable: echo,
      argv: ["{text}"],
      arguments: %{"text" => %{type: :string, required: true}}
    }

    assert {:error, {:unknown_arguments, ["extra"]}} =
             Operations.execute([operation], "echo", %{"text" => "x", "extra" => "y"},
               workspace: workspace
             )

    assert {:error, {:missing_arguments, ["text"]}} =
             Operations.execute([operation], "echo", %{}, workspace: workspace)

    assert {:error, {:invalid_argument, "text"}} =
             Operations.execute([operation], "echo", %{"text" => 12}, workspace: workspace)
  end

  test "rejects unknown operations", %{workspace: workspace} do
    assert {:error, {:unknown_operation, "missing"}} =
             Operations.execute([], "missing", %{}, workspace: workspace)
  end

  test "confines path arguments to the workspace", %{workspace: workspace, echo: echo} do
    operation = %{
      name: "read",
      executable: echo,
      argv: ["{file}"],
      arguments: %{"file" => %{type: :path, required: true}}
    }

    assert {:error, {:path_outside_workspace, "../escape"}} =
             Operations.execute([operation], "read", %{"file" => "../escape"},
               workspace: workspace
             )

    assert {:error, :workspace_required} =
             Operations.execute([operation], "read", %{"file" => "sub/file"})
  end

  test "requires file and directory arguments to exist inside the workspace", %{
    workspace: workspace,
    echo: echo
  } do
    File.write!(Path.join(workspace, "note.txt"), "hello")

    operation = %{
      name: "inspect",
      executable: echo,
      argv: ["{file}", "{dir}"],
      arguments: %{
        "file" => %{type: :file, required: true},
        "dir" => %{type: :directory, required: true}
      }
    }

    assert {:ok, result} =
             Operations.execute([operation], "inspect", %{"file" => "note.txt", "dir" => "sub"},
               workspace: workspace
             )

    assert result.output ==
             "#{Path.join(workspace, "note.txt")} #{Path.join(workspace, "sub")}\n"

    assert {:error, {:file_not_found, "missing.txt"}} =
             Operations.execute(
               [operation],
               "inspect",
               %{"file" => "missing.txt", "dir" => "sub"},
               workspace: workspace
             )

    assert {:error, {:directory_not_found, "note.txt"}} =
             Operations.execute(
               [operation],
               "inspect",
               %{"file" => "note.txt", "dir" => "note.txt"},
               workspace: workspace
             )
  end

  test "validates operation declarations", %{echo: echo} do
    assert {:ok, [bare]} =
             Operations.validate([%{name: "bare", executable: "echo", argv: []}])

    assert bare.executable == "echo"

    assert {:error, :invalid_executable} =
             Operations.validate([%{name: "blank", executable: " ", argv: []}])

    assert {:error, {:invalid_operation_name, "Bad Name"}} =
             Operations.validate([%{name: "Bad Name", executable: echo, argv: []}])

    assert {:error, {:undeclared_placeholders, ["target"]}} =
             Operations.validate([
               %{name: "bad", executable: echo, argv: ["{target}"], arguments: %{}}
             ])

    assert {:error, {:duplicate_operation, ["same"]}} =
             Operations.validate([
               %{name: "same", executable: echo, argv: []},
               %{name: "same", executable: echo, argv: []}
             ])
  end

  test "executes an operation whose executable is a bare PATH name", %{
    workspace: workspace
  } do
    operation = %{name: "say", executable: "echo", argv: ["bare-path"], arguments: %{}}

    assert {:ok, result} =
             Operations.execute([operation], "say", %{}, workspace: workspace)

    assert result.status == :ok
    assert result.output == "bare-path\n"
  end

  test "rejects unsafe operation files", %{tmp: tmp} do
    path = Path.join(tmp, "unsafe.pbt")
    File.write!(path, :erlang.term_to_binary([self()]))

    assert {:error, :invalid_term} = Operations.load(path)
  end

  test "rejects a symlink inside the workspace that points outside it", %{
    tmp: tmp,
    workspace: workspace,
    echo: echo
  } do
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.txt"), "secret")
    File.ln_s!(outside, Path.join(workspace, "escape"))

    operation = %{
      name: "read",
      executable: echo,
      argv: ["{file}"],
      arguments: %{"file" => %{type: :file, required: true}}
    }

    assert {:error, {:path_outside_workspace, "escape/secret.txt"}} =
             Operations.execute([operation], "read", %{"file" => "escape/secret.txt"},
               workspace: workspace
             )
  end

  test "omits argv elements whose optional placeholders were not supplied", %{
    workspace: workspace,
    echo: echo
  } do
    operation = %{
      name: "optional",
      executable: echo,
      argv: ["{name}", "--label={label}", "tail"],
      arguments: %{
        "name" => %{type: :string},
        "label" => %{type: :string}
      }
    }

    assert {:ok, result} = Operations.execute([operation], "optional", %{}, workspace: workspace)
    assert result.output == "--label= tail\n"

    assert {:ok, result} =
             Operations.execute([operation], "optional", %{"name" => "value", "label" => "x"},
               workspace: workspace
             )

    assert result.output == "value --label=x tail\n"
  end

  test "converts definition operations to the worker schema", %{echo: echo} do
    alias Patchbay.Definition.Toolkit.Operation

    derived = %Operation{
      name: "derived",
      argv: [echo, "{text}"],
      arguments: %{"text" => %{type: :string, required: true}}
    }

    explicit = %Operation{
      name: "explicit",
      executable: echo,
      argv: [],
      arguments: %{}
    }

    assert {:ok, [derived_worker, explicit_worker]} =
             Operations.from_definition([derived, explicit])

    assert derived_worker == %{
             name: "derived",
             executable: echo,
             argv: ["{text}"],
             arguments: %{"text" => %{type: :string, required: true, values: nil}}
           }

    assert explicit_worker.executable == echo
    assert explicit_worker.argv == []
  end

  test "derives an executable from argv when a raw operation omits it", %{echo: echo} do
    assert {:ok, [operation]} =
             Operations.validate([%{name: "direct", argv: [echo, "--version"]}])

    assert operation.executable == echo
    assert operation.argv == ["--version"]
  end

  test "rejects invalid UTF-8 string and enum arguments", %{workspace: workspace, echo: echo} do
    operation = %{
      name: "echo",
      executable: echo,
      argv: ["{text}", "{kind}"],
      arguments: %{
        "text" => %{type: :string},
        "kind" => %{type: :enum, values: ["alpha", "beta"]}
      }
    }

    assert {:error, {:invalid_argument, "text"}} =
             Operations.execute([operation], "echo", %{"text" => <<0xFF>>}, workspace: workspace)

    assert {:error, {:invalid_argument, "kind"}} =
             Operations.execute([operation], "echo", %{"kind" => <<0xC3>>}, workspace: workspace)
  end

  test "rejects home-relative path arguments without expanding them", %{
    workspace: workspace,
    echo: echo
  } do
    operation = %{
      name: "read",
      executable: echo,
      argv: ["{file}"],
      arguments: %{"file" => %{type: :path, required: true}}
    }

    assert {:error, {:path_outside_workspace, "~/note.txt"}} =
             Operations.execute([operation], "read", %{"file" => "~/note.txt"},
               workspace: workspace
             )

    assert {:error, {:path_outside_workspace, "~"}} =
             Operations.execute([operation], "read", %{"file" => "~"}, workspace: workspace)
  end

  test "stops resolving a symlink loop inside the workspace", %{
    workspace: workspace,
    echo: echo
  } do
    File.ln_s!(Path.join(workspace, "b"), Path.join(workspace, "a"))
    File.ln_s!(Path.join(workspace, "a"), Path.join(workspace, "b"))

    operation = %{
      name: "read",
      executable: echo,
      argv: ["{file}"],
      arguments: %{"file" => %{type: :path, required: true}}
    }

    assert {:error, :invalid_path} =
             Operations.execute([operation], "read", %{"file" => "a"}, workspace: workspace)
  end

  test "expands fixed variables supplied at execution time", %{workspace: workspace, echo: echo} do
    operation = %{
      name: "vars",
      executable: echo,
      argv: ["{%workspace}", "{%agent_id}", "{%result_dir}"],
      arguments: %{}
    }

    assert {:ok, result} =
             Operations.execute([operation], "vars", %{},
               workspace: workspace,
               agent_id: "alpha",
               variables: %{"result_dir" => "/tmp/results"}
             )

    assert result.output == "#{workspace} alpha /tmp/results\n"

    operation = %{operation | argv: ["{%run_id}"]}

    assert {:error, {:unavailable_variable, "run_id"}} =
             Operations.execute([operation], "vars", %{}, workspace: workspace)
  end

  test "definition argument structs infer required arguments from argv placeholders", %{
    echo: echo
  } do
    alias Patchbay.Definition.Toolkit.Argument
    alias Patchbay.Definition.Toolkit.Operation

    operation = %Operation{
      name: "inferred",
      argv: [echo, "{text}"],
      arguments: %{"text" => %Argument{type: :string}}
    }

    assert {:ok, [worker_operation]} = Operations.from_definition([operation])
    assert worker_operation.arguments["text"] == %{type: :string, required: true, values: nil}
  end

  defp executable!(name) do
    case System.find_executable(name) do
      nil -> flunk("missing executable in test environment: #{name}")
      path -> path
    end
  end
end
