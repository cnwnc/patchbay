defmodule Patchbay.Worker.TokenTest do
  use ExUnit.Case, async: true

  alias Patchbay.Worker.Token

  setup do
    dir = Path.join(System.tmp_dir!(), "patchbay-token-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "explicit option wins over environment and file", %{dir: dir} do
    path = token_file(dir, "from-file\n")

    assert Token.resolve_control_token(
             [control_token: "from-option"],
             %{
               "PATCHBAY_CONTROL_TOKEN" => "from-env",
               "PATCHBAY_CONTROL_TOKEN_FILE" => path
             }
           ) == "from-option"
  end

  test "environment wins over the token file", %{dir: dir} do
    path = token_file(dir, "from-file\n")

    assert Token.resolve_control_token(%{}, %{
             "PATCHBAY_CONTROL_TOKEN" => "from-env",
             "PATCHBAY_CONTROL_TOKEN_FILE" => path
           }) == "from-env"
  end

  test "reads and trims a token file", %{dir: dir} do
    path = token_file(dir, "from-file\n")

    assert Token.resolve_control_token(%{}, %{"PATCHBAY_CONTROL_TOKEN_FILE" => path}) ==
             "from-file"

    assert Token.resolve_control_token([control_token_file: path], %{}) == "from-file"
  end

  test "missing and empty sources resolve to nil", %{dir: dir} do
    empty = token_file(dir, "  \n")
    missing = Path.join(dir, "missing")

    assert Token.resolve_control_token(%{}, %{}) == nil
    assert Token.resolve_control_token(%{}, %{"PATCHBAY_CONTROL_TOKEN" => ""}) == nil
    assert Token.resolve_control_token(%{}, %{"PATCHBAY_CONTROL_TOKEN_FILE" => empty}) == nil
    assert Token.resolve_control_token(%{}, %{"PATCHBAY_CONTROL_TOKEN_FILE" => missing}) == nil
  end

  defp token_file(dir, contents) do
    path = Path.join(dir, "control-token")
    File.write!(path, contents)
    path
  end
end
