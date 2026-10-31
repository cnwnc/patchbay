defmodule Patchbay.ArtifactStoreTest do
  use ExUnit.Case, async: true

  alias Patchbay.ArtifactStore

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "patchbay-artifact-store-#{System.unique_integer([:positive])}"
      )

    state_dir = Path.join(tmp, "state")
    File.mkdir_p!(state_dir)
    on_exit(fn -> File.rm_rf(tmp) end)

    %{state_dir: state_dir, directory: ArtifactStore.dir(state_dir, "agent-one")}
  end

  test "public names keep the memorable slug, run tag, and extension", _context do
    one = ArtifactStore.public_name(["final_state"], "run-123456", "TXT")
    two = ArtifactStore.public_name(["final_state"], "run-123456", "txt")

    assert one =~ ~r/\Afinal-state-[a-z0-9]{4}-[a-z0-9]{8}\.txt\z/
    assert two =~ ~r/\Afinal-state-[a-z0-9]{4}-[a-z0-9]{8}\.txt\z/
    assert one != two

    assert ArtifactStore.public_name("Report!", nil, ".md") =~
             ~r/\Areport-[a-z0-9]{8}\.md\z/

    assert ArtifactStore.public_name("", nil, "") =~
             ~r/\Aartifact-[a-z0-9]{8}\.bin\z/
  end

  test "writes manager-owned artifacts with private modes", %{
    state_dir: state_dir,
    directory: directory
  } do
    assert {:ok, written} = ArtifactStore.write(state_dir, "agent-one", "report-01.txt", "bytes")
    assert written.size == 5
    assert File.exists?(Path.join(directory, "report-01.txt"))
    assert mode(directory) == 0o700
    assert mode(Path.join(directory, "report-01.txt")) == 0o600
  end

  test "never overwrites an existing artifact name", %{state_dir: state_dir} do
    assert {:ok, _first} = ArtifactStore.write(state_dir, "agent-one", "same.txt", "one")
    assert {:error, :name_taken} = ArtifactStore.write(state_dir, "agent-one", "same.txt", "two")
    assert {:ok, "one"} = ArtifactStore.read(state_dir, "agent-one", "same.txt")
  end

  test "caps published sizes", %{state_dir: state_dir} do
    big = :binary.copy("a", ArtifactStore.default_max_artifact_bytes() + 1)

    assert {:error, :artifact_too_large} =
             ArtifactStore.write(state_dir, "agent-one", "big.bin", big)
  end

  test "lists artifacts newest first with serving metadata", %{state_dir: state_dir} do
    assert {:ok, _} = ArtifactStore.write(state_dir, "agent-one", "older.log", "a")

    File.touch(
      Path.join(ArtifactStore.dir(state_dir, "agent-one"), "older.log"),
      {{2000, 1, 1}, {0, 0, 0}}
    )

    assert {:ok, _} = ArtifactStore.write(state_dir, "agent-one", "newer.exe", "b")

    assert {:ok, [first, second]} = ArtifactStore.list(state_dir, "agent-one")
    assert first.name == "newer.exe"
    assert first.disposition == :attachment
    assert first.content_type == "application/octet-stream"
    assert second.name == "older.log"
    assert second.disposition == :inline
    assert second.content_type == "text/plain"
  end

  test "rejects agent ids that are not one path component", %{state_dir: state_dir} do
    for bad <- ["../other", "a/b", "", "..", "x\\" <> "y", "agent one"] do
      assert {:error, :invalid_agent_id} = ArtifactStore.write(state_dir, bad, "a.txt", "x")
      assert {:error, :invalid_agent_id} = ArtifactStore.list(state_dir, bad)
      assert {:error, :invalid_agent_id} = ArtifactStore.resolve(state_dir, bad, "a.txt")
    end
  end

  test "resolve refuses to leave the agent directory", %{
    state_dir: state_dir,
    directory: directory
  } do
    assert {:ok, _} = ArtifactStore.write(state_dir, "agent-one", "escape.txt", "no")
    sibling = Path.join(Path.dirname(directory), "agent-two")
    File.mkdir_p!(sibling)
    File.write!(Path.join(sibling, "secret.txt"), "nope")

    assert {:error, :invalid_name} =
             ArtifactStore.resolve(state_dir, "agent-one", "../agent-two/secret.txt")

    assert {:error, :invalid_name} =
             ArtifactStore.resolve(state_dir, "agent-one", "sub/thing.txt")

    assert {:error, :invalid_name} = ArtifactStore.resolve(state_dir, "agent-one", "")
    assert {:error, :invalid_name} = ArtifactStore.resolve(state_dir, "agent-one", ".")
    assert {:error, :invalid_name} = ArtifactStore.resolve(state_dir, "agent-one", "..")
    assert {:error, :invalid_name} = ArtifactStore.resolve(state_dir, "agent-one", "a\\b")
    assert {:error, :not_found} = ArtifactStore.resolve(state_dir, "agent-one", "missing.txt")

    assert {:ok, resolved} = ArtifactStore.resolve(state_dir, "agent-one", "escape.txt")
    assert resolved.path == Path.join(directory, "escape.txt")
    assert {:ok, "no"} = ArtifactStore.read(state_dir, "agent-one", "escape.txt")
  end

  test "resolve does not follow symlinks outside the agent directory", %{
    state_dir: state_dir
  } do
    outside = Path.join(Path.dirname(state_dir), "outside-secret.txt")
    File.write!(outside, "secret")

    link = Path.join(ArtifactStore.dir(state_dir, "agent-one"), "linked.txt")
    File.ln_s(outside, link)

    assert {:error, :not_found} = ArtifactStore.resolve(state_dir, "agent-one", "linked.txt")
    assert {:error, :not_found} = ArtifactStore.read(state_dir, "agent-one", "linked.txt")
  end

  test "extension lint accepts declared extensions and bare names", _context do
    assert {:ok, "txt"} = ArtifactStore.lint_source("out/final.txt", ["txt", "diff", ""])
    assert {:ok, "txt"} = ArtifactStore.lint_source("final.TXT", [".txt"])
    assert {:ok, "txt"} = ArtifactStore.lint_source("final.txt", [])
    assert {:ok, "bin"} = ArtifactStore.lint_source("no-extension", [])
    assert {:ok, "bin"} = ArtifactStore.lint_source("no-extension", [""])
    assert {:error, {:extension_not_allowed, "exe"}} = ArtifactStore.lint_source("f.exe", ["txt"])

    assert {:error, {:extension_not_allowed, "bin"}} =
             ArtifactStore.lint_source("no-extension", ["txt"])
  end

  defp mode(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o777)
      _other -> :missing
    end
  end
end
