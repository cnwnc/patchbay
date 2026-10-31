defmodule Patchbay.Secrets.RedactTest do
  use ExUnit.Case, async: true

  alias Patchbay.Provider.Message
  alias Patchbay.Secrets.Redact

  @secret "ghp_supersecretvalue"

  test "replaces literal values in text and nested structures" do
    values = %{"GH_TOKEN" => @secret, "OTHER" => "another-secret"}

    assert Redact.redact("token=#{@secret}", values) == "token=[redacted]"

    assert Redact.redact(%{output: "x #{@secret} y"}, values) == %{output: "x [redacted] y"}

    assert Redact.redact(["#{@secret}", %{"k" => "another-secret"}], values) == [
             "[redacted]",
             %{"k" => "[redacted]"}
           ]

    assert Redact.redact({:error, {:failed, @secret}}, values) ==
             {:error, {:failed, "[redacted]"}}
  end

  test "replaces the longest value first" do
    values = %{"A" => "abcdefgh", "B" => "abcd"}
    assert Redact.redact("abcdefgh", values) == "[redacted]"
  end

  test "leaves short values and safe text alone" do
    assert Redact.redact("abc", %{"A" => "abc"}) == "abc"
    assert Redact.redact("hello", %{"A" => "absent"}) == "hello"
    assert Redact.redact("hello", %{}) == "hello"
    assert Redact.redact(42, %{"A" => @secret}) == 42
  end

  test "walks structs without losing their type" do
    message = Message.tool("call-1", "echo #{@secret}", name: "op")
    redacted = Redact.redact(message, %{"GH_TOKEN" => @secret})

    assert %Message{role: :tool, tool_call_id: "call-1", name: "op"} = redacted
    assert redacted.content == "echo [redacted]"
  end

  test "ignores non-map values" do
    assert Redact.redact("text", nil) == "text"
  end
end
