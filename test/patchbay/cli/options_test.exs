defmodule Patchbay.CLI.OptionsTest do
  use ExUnit.Case, async: true

  alias Patchbay.CLI.Options

  @option_spec [
    {"host", :host, :string},
    {"port", :port, :integer},
    {"quiet", :quiet, :boolean}
  ]

  test "parses string, integer, boolean, and equals forms" do
    assert {:ok, %{host: "127.0.0.1", port: 4000, quiet: true}} =
             Options.parse(["--host", "127.0.0.1", "--port=4000", "--quiet"], @option_spec)
  end

  test "rejects unknown, missing, and positional arguments" do
    assert {:error, {:unknown_option, "nope"}} = Options.parse(["--nope", "1"], @option_spec)
    assert {:error, {:missing_value, "host"}} = Options.parse(["--host"], @option_spec)
    assert {:error, {:unexpected_argument, "stray"}} = Options.parse(["stray"], @option_spec)
  end

  test "rejects malformed values" do
    assert {:error, {:invalid_integer, "port", "x"}} =
             Options.parse(["--port", "x"], @option_spec)

    assert {:error, {:invalid_integer, "port", "-1"}} =
             Options.parse(["--port", "-1"], @option_spec)
  end

  test "parses ports and endpoints" do
    assert {:ok, 0} = Options.parse_port("0")
    assert {:ok, 65_535} = Options.parse_port("65535")
    assert {:error, _reason} = Options.parse_port("65536")
    assert {:ok, {"127.0.0.1", 4000}} = Options.endpoint("127.0.0.1:4000")
    assert {:ok, {"127.0.0.1", 4000}} = Options.endpoint("4000")
  end
end
