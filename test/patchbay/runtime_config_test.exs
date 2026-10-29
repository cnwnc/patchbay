defmodule Patchbay.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @config_path Path.expand(Path.join([__DIR__, "..", "..", "config", "runtime.exs"]))
  @env_names [
    "SECRET_KEY_BASE",
    "PATCHBAY_SESSION_SIGNING_SALT",
    "PATCHBAY_LIVE_VIEW_SIGNING_SALT",
    "PATCHBAY_UI_TOKEN",
    "PATCHBAY_WEB_PORT"
  ]

  setup do
    previous =
      Map.new(@env_names, fn name -> {name, System.get_env(name)} end)

    Enum.each(@env_names, &System.delete_env/1)
    previous_argv = System.argv()

    on_exit(fn ->
      System.argv(previous_argv)

      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  test "worker and supervisor VMs do not require a secret or web config" do
    for argv <- [["run-worker"], ["run-worker-supervisor", "--listen-port", "0"]] do
      config = evaluate(argv)

      endpoint = Keyword.fetch!(config[:patchbay], PatchbayWeb.Endpoint)
      assert endpoint[:server] == false
      refute Keyword.has_key?(endpoint, :secret_key_base)
      refute Keyword.has_key?(config[:patchbay], :manager)
    end
  end

  test "the manager VM requires the secret, both signing salts, and the UI token" do
    assert_raise RuntimeError, ~r/SECRET_KEY_BASE/, fn -> evaluate(["run-manager"]) end

    System.put_env("SECRET_KEY_BASE", String.duplicate("s", 64))

    assert_raise RuntimeError, ~r/PATCHBAY_SESSION_SIGNING_SALT/, fn ->
      evaluate(["run-manager"])
    end

    System.put_env("PATCHBAY_SESSION_SIGNING_SALT", "session-salt")
    System.put_env("PATCHBAY_LIVE_VIEW_SIGNING_SALT", "live-view-salt")

    assert_raise RuntimeError, ~r/PATCHBAY_UI_TOKEN/, fn -> evaluate(["run-manager"]) end

    System.put_env("PATCHBAY_UI_TOKEN", "ui-token")

    config = evaluate(["run-manager"])

    endpoint = Keyword.fetch!(config[:patchbay], PatchbayWeb.Endpoint)
    assert endpoint[:server] == true
    assert endpoint[:secret_key_base] == String.duplicate("s", 64)
    assert endpoint[:session][:signing_salt] == "session-salt"
    assert endpoint[:live_view][:signing_salt] == "live-view-salt"
    assert endpoint[:check_origin] == ["http://localhost:4000", "http://127.0.0.1:4000"]
    assert endpoint[:url] == [host: "localhost", port: 4000]
    assert endpoint[:http][:port] == 4000
    assert config[:patchbay][:ui_token] == "ui-token"
    assert Keyword.has_key?(config[:patchbay], :manager)
  end

  test "the manager web port comes from PATCHBAY_WEB_PORT" do
    System.put_env("SECRET_KEY_BASE", String.duplicate("s", 64))
    System.put_env("PATCHBAY_SESSION_SIGNING_SALT", "session-salt")
    System.put_env("PATCHBAY_LIVE_VIEW_SIGNING_SALT", "live-view-salt")
    System.put_env("PATCHBAY_UI_TOKEN", "ui-token")
    System.put_env("PATCHBAY_WEB_PORT", "4321")

    config = evaluate(["run-manager"])

    endpoint = Keyword.fetch!(config[:patchbay], PatchbayWeb.Endpoint)
    assert endpoint[:url] == [host: "localhost", port: 4321]
    assert endpoint[:http][:port] == 4321
    assert endpoint[:check_origin] == ["http://localhost:4321", "http://127.0.0.1:4321"]
  end

  test "normal application starts still require a secret" do
    assert_raise RuntimeError, ~r/SECRET_KEY_BASE/, fn -> evaluate([]) end
  end

  test "help does not require a secret" do
    config = evaluate(["help"])

    endpoint = Keyword.fetch!(config[:patchbay], PatchbayWeb.Endpoint)
    assert endpoint[:server] == false
    refute Keyword.has_key?(endpoint, :secret_key_base)
  end

  defp evaluate(argv) do
    System.argv(argv)

    Config.Reader.eval!(
      @config_path,
      File.read!(@config_path),
      env: :prod,
      target: :host,
      imports: :disabled
    )
  end
end
