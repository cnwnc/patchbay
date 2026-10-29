import Config

if config_env() == :prod do
  escript? = match?({:ok, _}, :init.get_argument(:patchbay_escript))

  role =
    case System.argv() do
      ["run-manager" | _rest] -> :manager
      ["run-worker-supervisor" | _rest] -> :worker_supervisor
      ["run-worker" | _rest] -> :worker
      ["help" | _rest] -> :cli
      ["--help" | _rest] -> :cli
      _argv -> if escript?, do: :cli, else: :app
    end

  endpoint_config = Application.get_env(:patchbay, PatchbayWeb.Endpoint, [])
  web_host = endpoint_config |> Keyword.get(:url, []) |> Keyword.get(:host, "localhost")
  web_port = String.to_integer(System.get_env("PATCHBAY_WEB_PORT", "4000"))

  if role in [:app, :manager] do
    secret_key_base =
      System.get_env("SECRET_KEY_BASE") ||
        raise "SECRET_KEY_BASE is not set"

    session_signing_salt =
      System.get_env("PATCHBAY_SESSION_SIGNING_SALT") ||
        raise "PATCHBAY_SESSION_SIGNING_SALT is not set"

    live_view_signing_salt =
      System.get_env("PATCHBAY_LIVE_VIEW_SIGNING_SALT") ||
        raise "PATCHBAY_LIVE_VIEW_SIGNING_SALT is not set"

    config :patchbay, PatchbayWeb.Endpoint,
      secret_key_base: secret_key_base,
      server: true,
      session: [signing_salt: session_signing_salt],
      live_view: [signing_salt: live_view_signing_salt],
      url: [host: web_host, port: web_port],
      http: [
        ip: {127, 0, 0, 1},
        port: web_port
      ]

    config :patchbay, :manager,
      supervisor_host: System.get_env("PATCHBAY_SUPERVISOR_HOST", "127.0.0.1"),
      supervisor_port: String.to_integer(System.get_env("PATCHBAY_SUPERVISOR_PORT", "7001"))
  else
    config :patchbay, PatchbayWeb.Endpoint, server: false
  end
end
