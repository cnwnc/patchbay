defmodule Patchbay.Worker.NixTest do
  use ExUnit.Case, async: true

  alias Patchbay.Worker.Nix

  setup do
    tmp = Path.join(System.tmp_dir!(), "patchbay-nix-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    nix = Path.join(tmp, "nix")
    File.write!(nix, "#!/bin/sh\nexit 0\n")
    File.chmod!(nix, 0o755)

    %{tmp: tmp, nix: nix}
  end

  test "normalizes simple names and keeps explicit refs" do
    assert {:ok,
            [
              "nixpkgs#git",
              "nixpkgs#ripgrep",
              "nixpkgs#python3.pkgs.requests",
              "nixpkgs#jq",
              "github:owner/repo#pkg",
              "path:/tmp/flake#pkg",
              "nixpkgs",
              "/tmp/flake",
              "./flake",
              "../flake",
              "~/flake"
            ]} =
             Nix.normalize_packages([
               "git",
               "ripgrep",
               "python3.pkgs.requests",
               "nixpkgs#jq",
               "github:owner/repo#pkg",
               "path:/tmp/flake#pkg",
               "nixpkgs",
               "/tmp/flake",
               "./flake",
               "../flake",
               "~/flake"
             ])
  end

  test "rejects refs that are not safe argv" do
    for packages <- [
          ["--impure"],
          ["git", "bad name"],
          [""],
          [42],
          ["git", "bad\tname"],
          [String.duplicate("a", 4097)],
          Enum.map(1..129, &"pkg#{&1}"),
          "git"
        ] do
      assert {:error, :invalid_packages} = Nix.normalize_packages(packages)
    end
  end

  test "empty packages keep the direct worker command" do
    assert {:ok, {"/usr/bin/patchbay", ["run-worker", "arg"]}} =
             Nix.command([], "/usr/bin/patchbay", ["run-worker", "arg"],
               nix_executable: "/does/not/exist"
             )
  end

  test "non-empty packages invoke nix shell with direct argv", %{nix: nix} do
    assert {:ok,
            {^nix,
             [
               "shell",
               "nixpkgs#git",
               "github:owner/repo#pkg",
               "--command",
               "/usr/bin/patchbay",
               "run-worker",
               "--worker-id",
               "agent.one"
             ]}} =
             Nix.command(
               ["git", "github:owner/repo#pkg"],
               "/usr/bin/patchbay",
               ["run-worker", "--worker-id", "agent.one"],
               nix_executable: nix
             )
  end

  test "non-empty packages need an executable nix", %{tmp: tmp} do
    assert {:error, :nix_not_found} =
             Nix.command(["git"], "/usr/bin/patchbay", ["run-worker"],
               nix_executable: Path.join(tmp, "missing")
             )
  end

  test "invalid package input never builds a command", %{nix: nix} do
    assert {:error, :invalid_packages} =
             Nix.command(["--impure"], "/usr/bin/patchbay", ["run-worker"], nix_executable: nix)
  end
end
