defmodule Patchbay.Worker.SecretEnvTest do
  use ExUnit.Case, async: false

  alias Patchbay.Worker.Env
  alias Patchbay.Worker.Exec

  @secret "worker-secret-value-0123456789"
  @token "worker-channel-token-0123456789"
  @control "control-token-value-0123456789"

  test "a worker receives only the declared secret map" do
    source = %{
      "PATH" => "/usr/bin",
      "HOME" => "/home/agent",
      "PATCHBAY_WORKER_TOKEN" => "inherited-token",
      "PATCHBAY_CONTROL_TOKEN" => @control,
      "OPENAI_API_KEY" => "manager-provider-key",
      "UNRELATED" => "unrelated"
    }

    secrets = %{"GH_TOKEN" => @secret, "OPENAI_API_KEY" => "declared-provider-key"}

    extra = %{
      "PATCHBAY_WORKER_TOKEN" => @token,
      "PATCHBAY_SECRET_ENV" => Env.encode_secret_names(Map.keys(secrets)),
      "PATCHBAY_CONTROL_TOKEN" => "should-not-pass"
    }

    env = Env.worker_env(extra, source, secrets)
    kept = Map.new(kept(env), fn {name, value} -> {to_string(name), to_string(value)} end)

    assert kept["GH_TOKEN"] == @secret
    assert kept["OPENAI_API_KEY"] == "declared-provider-key"
    assert kept["PATCHBAY_WORKER_TOKEN"] == @token
    assert kept["PATCHBAY_SECRET_ENV"] == "GH_TOKEN,OPENAI_API_KEY"
    assert kept["PATH"] == "/usr/bin"

    refute Map.has_key?(kept, "PATCHBAY_CONTROL_TOKEN")
    refute Map.has_key?(kept, "UNRELATED")
    assert ~c"PATCHBAY_CONTROL_TOKEN" in unset(env)
    assert ~c"UNRELATED" in unset(env)
  end

  test "invalid names in a secret map are not injected" do
    secrets = %{"PATCHBAY_WORKER_TOKEN" => "x", "PATH" => "x", "GH_TOKEN" => @secret}
    env = Env.worker_env(%{}, %{"PATH" => "/usr/bin"}, secrets)

    names = env |> kept() |> Enum.map(fn {name, _value} -> to_string(name) end)
    assert "GH_TOKEN" in names
    assert "PATH" in names
    refute "PATCHBAY_WORKER_TOKEN" in names
    assert "PATCHBAY_SECRET_ENV" in names
  end

  test "operation children receive declared secrets but not control state" do
    source = %{
      "PATH" => "/usr/bin",
      "HOME" => "/home/agent",
      "GH_TOKEN" => @secret,
      "PATCHBAY_WORKER_TOKEN" => @token,
      "PATCHBAY_CONTROL_TOKEN" => @control,
      "PATCHBAY_SECRET_ENV" => "GH_TOKEN",
      "OPENAI_API_KEY" => "manager-provider-key"
    }

    env = Env.exec_env(source, ["GH_TOKEN"])
    kept = Map.new(kept(env), fn {name, value} -> {to_string(name), to_string(value)} end)

    assert kept["GH_TOKEN"] == @secret
    assert kept["PATH"] == "/usr/bin"
    refute Map.has_key?(kept, "PATCHBAY_WORKER_TOKEN")
    refute Map.has_key?(kept, "PATCHBAY_CONTROL_TOKEN")
    refute Map.has_key?(kept, "PATCHBAY_SECRET_ENV")
    refute Map.has_key?(kept, "OPENAI_API_KEY")

    assert ~c"PATCHBAY_WORKER_TOKEN" in unset(env)
    assert ~c"PATCHBAY_SECRET_ENV" in unset(env)
    assert ~c"OPENAI_API_KEY" in unset(env)
  end

  test "a real operation child receives only the declared secret names" do
    System.put_env("GH_TOKEN", @secret)
    System.put_env("PATCHBAY_WORKER_TOKEN", @token)
    System.put_env("PATCHBAY_CONTROL_TOKEN", @control)
    System.put_env("OPENAI_API_KEY", "manager-provider-key")

    on_exit(fn ->
      Enum.each(
        ~w(GH_TOKEN PATCHBAY_WORKER_TOKEN PATCHBAY_CONTROL_TOKEN OPENAI_API_KEY),
        &System.delete_env/1
      )
    end)

    assert {:ok, result} =
             Exec.run(executable!("env"), [], secret_names: ["GH_TOKEN"])

    assert result.output =~ "GH_TOKEN=#{@secret}"
    assert result.output =~ "PATH="
    refute result.output =~ @token
    refute result.output =~ @control
    refute result.output =~ "manager-provider-key"
  end

  test "secret names are read from PATCHBAY_SECRET_ENV" do
    assert Env.secret_names(%{"PATCHBAY_SECRET_ENV" => "B,A,A,lower,PATCHBAY_X"}) == ["A", "B"]
    assert Env.secret_names(%{}) == []
    assert Env.secret_names_variable() == "PATCHBAY_SECRET_ENV"
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
