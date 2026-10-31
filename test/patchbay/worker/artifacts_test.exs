defmodule Patchbay.Worker.ArtifactsTest do
  use ExUnit.Case, async: true

  alias Patchbay.ArtifactStore
  alias Patchbay.Provider.JSON
  alias Patchbay.Worker.Artifacts
  alias Patchbay.Worker.Operations

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "patchbay-worker-artifacts-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(tmp, "workspace")
    result_dir = Path.join(tmp, "results")
    File.mkdir_p!(Path.join(workspace, "sub"))
    File.mkdir_p!(result_dir)

    on_exit(fn -> File.rm_rf(tmp) end)

    File.write!(Path.join(workspace, "report.txt"), "artifact body")

    roots = %{"workspace" => workspace, "result" => result_dir}

    %{tmp: tmp, workspace: workspace, result_dir: result_dir, roots: roots}
  end

  test "the read operation is reserved and cannot be declared by a definition" do
    assert Artifacts.read_operation() == "patchbay-read-artifact"
    assert Artifacts.reserved?("patchbay-read-artifact")

    operation = %{name: "patchbay-read-artifact", executable: "/bin/true", argv: []}

    assert {:error, {:reserved_operation_name, "patchbay-read-artifact"}} =
             Operations.validate([operation])
  end

  test "reads a workspace file as base64 json in one chunk", context do
    assert {:ok, %{status: :ok, output: output}} =
             Artifacts.read(context.roots, %{"path" => "report.txt"})

    assert {:ok, payload} = JSON.decode(output)
    assert payload["size"] == byte_size("artifact body")
    assert payload["eof"] == true
    assert payload["offset"] == 0

    assert {:ok, "artifact body"} = Base.decode64(payload["data"])
  end

  test "reads nested paths and arbitrary offsets", context do
    body = :binary.copy("artifact-bytes", 2000)
    File.write!(Path.join([context.workspace, "sub", "deep.txt"]), body)

    assert {:ok, %{output: output}} =
             Artifacts.read(context.roots, %{
               "path" => "sub/deep.txt",
               "offset" => 100,
               "length" => 100
             })

    assert {:ok, payload} = JSON.decode(output)
    assert payload["size"] == byte_size(body)
    assert payload["eof"] == false
    assert byte_size(Base.decode64!(payload["data"])) == 100
  end

  test "accepts an absolute path that stays inside the root", context do
    path = Path.join(context.workspace, "report.txt")

    assert {:ok, %{output: output}} = Artifacts.read(context.roots, %{"path" => path})
    assert {:ok, %{"size" => _}} = JSON.decode(output)
  end

  test "reads a file from the result directory when asked", context do
    File.write!(Path.join(context.result_dir, "final.patch"), "diff --git")

    assert {:ok, %{output: output}} =
             Artifacts.read(context.roots, %{"path" => "final.patch", "root" => "result"})

    assert {:ok, %{"size" => 10, "eof" => true} = payload} = JSON.decode(output)
    assert {:ok, "diff --git"} = Base.decode64(payload["data"])
  end

  test "refuses paths outside its roots", context do
    assert {:error, :path_outside_root} =
             Artifacts.read(context.roots, %{"path" => "../../etc/passwd"})

    assert {:error, :path_outside_root} =
             Artifacts.read(context.roots, %{"path" => "/etc/passwd", "root" => "workspace"})

    secret = Path.join(context.tmp, "secret.txt")
    File.write!(secret, "secret")

    assert {:error, :path_outside_root} =
             Artifacts.read(context.roots, %{"path" => "../secret.txt"})

    symlink = Path.join(context.workspace, "link.txt")
    File.ln_s(secret, symlink)

    assert {:error, :path_outside_root} = Artifacts.read(context.roots, %{"path" => "link.txt"})
  end

  test "refuses missing files, directories, and bad arguments", context do
    assert {:error, :not_found} = Artifacts.read(context.roots, %{"path" => "absent.txt"})
    assert {:error, :not_a_regular_file} = Artifacts.read(context.roots, %{"path" => "sub"})
    assert {:error, :invalid_offset} = escape_offset(context.roots)

    assert {:error, :invalid_path} = Artifacts.read(context.roots, %{"path" => ""})
    assert {:error, :invalid_path} = Artifacts.read(context.roots, %{"path" => :wrong})

    assert {:error, :result_dir_unavailable} =
             Artifacts.read(%{"workspace" => context.workspace}, %{
               "path" => "a.txt",
               "root" => "result"
             })

    assert {:error, :invalid_root} =
             Artifacts.read(context.roots, %{"path" => "a.txt", "root" => "/etc"})

    assert {:error, :invalid_arguments} = Artifacts.read(context.roots, "nope")
    assert {:error, :workspace_unavailable} = Artifacts.read(%{}, %{"path" => "a.txt"})
  end

  test "keeps one read below a frame-safe size", _context do
    assert Artifacts.max_read_bytes() <= 512 * 1024
    assert ArtifactStore.default_max_artifact_bytes() > Artifacts.max_read_bytes()
  end

  defp escape_offset(roots) do
    Artifacts.read(roots, %{"path" => "report.txt", "offset" => -1})
  end
end
