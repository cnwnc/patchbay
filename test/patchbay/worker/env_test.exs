defmodule Patchbay.Worker.EnvTest do
  use ExUnit.Case, async: false

  alias Patchbay.Worker.Env
  alias Patchbay.Worker.Exec

  @secret "worker-secret-token-0123456789"

  test "exec children receive only the passthrough allowlist" do
    source = %{
      "PATH" => "/usr/bin",
      "HOME" => "/home/agent",
      "PATCHBAY_WORKER_TOKEN" => @secret,
      "PATCHBAY_CONTROL_TOKEN" => @secret,
      "ANTHROPIC_API_KEY" => @secret,
      "OPENAI_API_KEY" => @secret,
      "UNRELATED" => @secret
    }

    env = Env.exec_env(source)

    assert kept(env) == [{~c"HOME", ~c"/home/agent"}, {~c"PATH", ~c"/usr/bin"}]

    assert unset(env) == [
             ~c"ANTHROPIC_API_KEY",
             ~c"OPENAI_API_KEY",
             ~c"PATCHBAY_CONTROL_TOKEN",
             ~c"PATCHBAY_WORKER_TOKEN",
             ~c"UNRELATED"
           ]
  end

  test "worker children receive worker configuration but never the control token" do
    source = %{
      "PATH" => "/usr/bin",
      "HOME" => "/home/agent",
      "PATCHBAY_CONTROL_TOKEN" => "control-secret-token-012345",
      "PATCHBAY_CONTROL_TOKEN_FILE" => "/run/patchbay/control-token",
      "PATCHBAY_PARENT_TOKEN" => "parent-secret-token-012345",
      "ANTHROPIC_API_KEY" => "provider-secret"
    }

    extra = %{
      "PATCHBAY_WORKER_TOKEN" => @secret,
      "PATCHBAY_OPERATIONS" => "/tmp/operations.pbt",
      "PATCHBAY_WORKSPACE" => "/tmp/workspace",
      "PATCHBAY_CONTROL_TOKEN" => "should-not-pass",
      "OPENAI_API_KEY" => "should-not-pass"
    }

    env = Env.worker_env(extra, source)
    kept_names = env |> kept() |> Enum.map(fn {name, _value} -> to_string(name) end)

    assert "PATCHBAY_WORKER_TOKEN" in kept_names
    assert "PATCHBAY_OPERATIONS" in kept_names
    assert "PATCHBAY_WORKSPACE" in kept_names
    assert "PATH" in kept_names
    assert "HOME" in kept_names
    refute "PATCHBAY_CONTROL_TOKEN" in kept_names
    refute "PATCHBAY_CONTROL_TOKEN_FILE" in kept_names
    refute "PATCHBAY_PARENT_TOKEN" in kept_names
    refute "OPENAI_API_KEY" in kept_names
    refute "ANTHROPIC_API_KEY" in kept_names

    assert ~c"PATCHBAY_CONTROL_TOKEN" in unset(env)
    assert ~c"PATCHBAY_CONTROL_TOKEN_FILE" in unset(env)
    assert ~c"PATCHBAY_PARENT_TOKEN" in unset(env)
    assert ~c"OPENAI_API_KEY" in unset(env)
    assert ~c"ANTHROPIC_API_KEY" in unset(env)
  end

  test "a real operation child does not inherit control tokens or provider keys" do
    System.put_env("PATCHBAY_WORKER_TOKEN", @secret)
    System.put_env("PATCHBAY_CONTROL_TOKEN", @secret)
    System.put_env("ANTHROPIC_API_KEY", @secret)
    System.put_env("PATCHBAY_ENV_TEST_UNRELATED", @secret)

    on_exit(fn ->
      Enum.each(
        ~w(PATCHBAY_WORKER_TOKEN PATCHBAY_CONTROL_TOKEN ANTHROPIC_API_KEY PATCHBAY_ENV_TEST_UNRELATED),
        &System.delete_env/1
      )
    end)

    env_executable = executable!("env")

    assert {:ok, result} = Exec.run(env_executable, [])
    refute result.output =~ @secret
    assert result.output =~ "PATH="
  end

  defp kept(env), do: Enum.filter(env, fn {_name, value} -> value != false end)
  defp unset(env), do: env |> Enum.filter(&match?({_name, false}, &1)) |> Enum.map(&elem(&1, 0))

  defp executable!(name) do
    case System.find_executable(name) do
      nil -> flunk("missing executable in test environment: #{name}")
      path -> path
    end
  end
end
