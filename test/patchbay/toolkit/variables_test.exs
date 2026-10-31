defmodule Patchbay.Toolkit.VariablesTest do
  use ExUnit.Case, async: true

  alias Patchbay.Toolkit.Variables

  test "renders fixed variables and model arguments" do
    assert {:ok, "/srv/work/.cache"} =
             Variables.render("{%workspace}/.cache", %{"workspace" => "/srv/work"})

    assert {:ok, "alpha /srv/work"} =
             Variables.render("{name} {%workspace}", %{"workspace" => "/srv/work"}, %{
               "name" => "alpha"
             })
  end

  test "a dollar in front of a fixed variable keeps the sequence literal" do
    variables = %{"workspace" => "/srv/work"}

    assert {:ok, "${%workspace}"} = Variables.render("${%workspace}", variables)

    assert {:ok, "a${%workspace}b/srv/work"} =
             Variables.render("a${%workspace}b{%workspace}", variables)

    assert references("${%workspace} {%workspace}") == %{variables: ["workspace"], arguments: []}
  end

  test "dollar-prefixed tokens from a later position are not mistaken for escaped ones" do
    assert references("x${%workspace}{%agent_id}") == %{variables: ["agent_id"], arguments: []}
  end

  test "validation rejects shell-style sequences and unknown variables" do
    assert {:error, [{:unsupported_shell_variable, "${%workspace}"}]} =
             Variables.validate("${%workspace}")

    assert {:error, [{:unknown_variable, "bogus"}]} = Variables.validate("{%bogus}")
    assert :ok = Variables.validate("{%workspace}")
    assert Variables.shell_style_variable?("${%agent_id}")
    refute Variables.shell_style_variable?("{%agent_id}")
  end

  test "collects fixed variables across an argv list" do
    assert Variables.referenced_variables(["{%workspace}", "x", "{%agent_id} {%workspace}"]) ==
             ["workspace", "agent_id"]
  end

  defp references(template), do: Variables.references(template)
end
