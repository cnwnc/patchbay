defmodule Patchbay.TranscriptTest do
  use ExUnit.Case, async: true

  alias Patchbay.Transcript

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "patchbay-transcript-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    %{tmp: tmp}
  end

  test "creates private transcript directories", %{tmp: tmp} do
    dir = Path.join(tmp, "nested/transcripts")

    assert :ok = Transcript.ensure_dir(dir)
    assert mode(dir) == 0o700

    File.chmod!(dir, 0o755)
    assert :ok = Transcript.ensure_dir(dir)
    assert mode(dir) == 0o700
  end

  test "refuses a symlinked transcript directory", %{tmp: tmp} do
    outside = Path.join(tmp, "outside")
    link = Path.join(tmp, "transcripts")
    File.mkdir_p!(outside)
    File.ln_s!(outside, link)

    assert {:error, :symlink} = Transcript.ensure_dir(link)
  end

  test "creates private transcript files", %{tmp: tmp} do
    path = Path.join(tmp, "worker.pbt")

    assert :ok = Transcript.append(path, "first")
    assert mode(path) == 0o600
    assert File.read!(path) == "first"

    File.chmod!(path, 0o644)
    assert :ok = Transcript.append(path, "second")
    assert mode(path) == 0o600
    assert File.read!(path) == "firstsecond"
  end

  test "refuses to append through a symlink", %{tmp: tmp} do
    target = Path.join(tmp, "target")
    link = Path.join(tmp, "worker.pbt")
    File.write!(target, "original")
    File.ln_s!(target, link)

    assert {:error, :symlink} = Transcript.append(link, "attacker")
    assert File.read!(target) == "original"
  end

  test "refuses a non-regular transcript path", %{tmp: tmp} do
    path = Path.join(tmp, "directory.pbt")
    File.mkdir_p!(path)

    assert {:error, :not_a_regular_file} = Transcript.append(path, "data")
  end

  test "tool history writer refuses a symlinked path and uses private permissions", %{tmp: tmp} do
    alias Patchbay.ToolHistory.Writer

    target = Path.join(tmp, "history-target")
    link = Path.join(tmp, "history.pbt")
    File.write!(target, "original")
    File.ln_s!(target, link)

    assert {:error, :symlink} = Writer.open(link)
    assert File.read!(target) == "original"

    plain = Path.join(tmp, "plain.pbt")
    assert {:ok, writer} = Writer.open(plain)
    assert :ok = Writer.close(writer)
    assert mode(plain) == 0o600
  end

  defp mode(path) do
    {:ok, %File.Stat{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o777)
  end
end
