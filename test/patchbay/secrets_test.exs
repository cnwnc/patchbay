defmodule Patchbay.SecretsTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Patchbay.Secrets

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "patchbay-secrets-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    %{tmp: tmp, root: Path.join(tmp, "secrets")}
  end

  test "creates a private store and private files", %{root: root} do
    assert :ok = Secrets.put(root, "github-main", "ghp_value")
    assert File.stat!(root).mode |> band(0o777) == 0o700
    assert File.stat!(Path.join(root, "github-main")).mode |> band(0o777) == 0o600
    assert Secrets.fetch(root, "github-main") == {:ok, "ghp_value"}
  end

  test "stored values are raw bytes, while CLI input drops one line ending", %{root: root} do
    assert :ok = Secrets.put(root, "raw", "value\nwith\nlines\n")
    assert Secrets.fetch(root, "raw") == {:ok, "value\nwith\nlines\n"}

    assert Secrets.strip_input_newline("value\n") == "value"
    assert Secrets.strip_input_newline("value\r\n") == "value"
    assert Secrets.strip_input_newline("value\n\n") == "value\n"
    assert Secrets.strip_input_newline("value") == "value"
    assert Secrets.strip_input_newline("") == ""
  end

  test "lists valid names only, sorted", %{root: root} do
    :ok = Secrets.put(root, "zeta", "z")
    :ok = Secrets.put(root, "alpha", "a")
    File.write!(Path.join(root, "Invalid"), "x")
    File.write!(Path.join(root, ".tmp-leftover"), "x")
    File.ln_s!(Path.join(root, "alpha"), Path.join(root, "link"))

    assert Secrets.list(root) == {:ok, ["alpha", "zeta"]}
    assert Secrets.list(Path.join(root, "missing")) == {:ok, []}
  end

  test "rejects names before building a path", %{tmp: tmp, root: root} do
    canary = Path.join(tmp, "canary")
    File.write!(canary, "outside")

    for name <- ["../canary", "/etc/passwd", "a/b", ".", "..", "", "Upper", "has space", "nul\0"] do
      assert Secrets.fetch(root, name) == {:error, :invalid_secret_name}
      assert Secrets.put(root, name, "value") == {:error, :invalid_secret_name}
      assert Secrets.delete(root, name) == {:error, :invalid_secret_name}
    end

    assert File.read!(canary) == "outside"
    refute File.exists?(root)
  end

  test "refuses symlinked secret files and directories", %{tmp: tmp, root: root} do
    target = Path.join(tmp, "target")
    File.write!(target, "outside")
    File.mkdir_p!(root)
    File.ln_s!(target, Path.join(root, "linked"))

    assert Secrets.fetch(root, "linked") == {:error, :invalid_secret_file}
    assert Secrets.put(root, "linked", "new") == {:error, :invalid_secret_file}
    assert Secrets.delete(root, "linked") == {:error, :invalid_secret_file}
    assert File.read!(target) == "outside"

    File.rm!(Path.join(root, "linked"))
    File.mkdir!(Path.join(root, "directory"))
    assert Secrets.fetch(root, "directory") == {:error, :invalid_secret_file}
    assert Secrets.put(root, "directory", "new") == {:error, :invalid_secret_file}
  end

  test "refuses a symlinked store root", %{tmp: tmp, root: root} do
    real = Path.join(tmp, "real")
    File.mkdir_p!(real)
    File.ln_s!(real, root)

    assert Secrets.put(root, "name", "value") == {:error, :invalid_secret_file}
    assert Secrets.fetch(root, "name") == {:error, :invalid_secret_file}
    assert Secrets.list(root) == {:error, :invalid_secret_file}
  end

  test "deletes an existing secret and reports a missing one", %{root: root} do
    :ok = Secrets.put(root, "gone", "value")
    assert Secrets.delete(root, "gone") == :ok
    assert Secrets.fetch(root, "gone") == {:error, :not_found}
    assert Secrets.delete(root, "gone") == {:error, :not_found}
  end

  test "validates injected variable maps without echoing values", %{root: root} do
    assert :ok = Secrets.validate_map(%{"GH_TOKEN" => "value"})

    assert {:error, {:invalid_variable, "PATCHBAY_WORKER_TOKEN"}} =
             Secrets.validate_map(%{"PATCHBAY_WORKER_TOKEN" => "value"})

    assert {:error, {:invalid_variable, "PATH"}} = Secrets.validate_map(%{"PATH" => "value"})
    assert {:error, {:invalid_variable, "lower"}} = Secrets.validate_map(%{"lower" => "value"})
    assert {:error, :invalid_entry} = Secrets.validate_map(%{"GH_TOKEN" => 1})

    assert {:error, {:invalid_value, "GH_TOKEN"}} =
             Secrets.validate_map(%{"GH_TOKEN" => "a\0b"})

    assert {:error, {:value_too_large, "GH_TOKEN"}} =
             Secrets.validate_map(%{
               "GH_TOKEN" => String.duplicate("a", Secrets.max_value_bytes() + 1)
             })

    assert {:error, reason} =
             Secrets.validate_map(%{"GH_TOKEN" => "hunter2" <> String.duplicate("x", 70_000)})

    refute inspect(reason) =~ "hunter2"
    assert {:error, :invalid_map} = Secrets.validate_map([])
    _ = root
  end

  test "encodes and parses secret name lists" do
    assert Secrets.encode_names(["B", "A", "A", "PATCHBAY_X", "bad-name"]) == "A,B"
    assert Secrets.parse_names("B,A,A,PATCHBAY_X,lower") == ["A", "B"]
    assert Secrets.parse_names(nil) == []
  end

  test "the CLI resolves the store directory and rejects unknown options" do
    alias Patchbay.CLI.Secrets, as: SecretsCLI

    assert SecretsCLI.store_dir(state_dir: "/tmp/patchbay-state") ==
             "/tmp/patchbay-state/secrets"

    assert SecretsCLI.store_dir(secrets_dir: "/tmp/patchbay-secrets") == "/tmp/patchbay-secrets"

    assert {:error, message, 2} = SecretsCLI.run(["--frobnicate"])
    assert message =~ "unknown option"
  end
end
