import Config

web_port = String.to_integer(System.get_env("PATCHBAY_WEB_PORT", "4000"))

config :patchbay, PatchbayWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: web_port],
  url: [port: web_port],
  server: true,
  check_origin: [
    "http://localhost:#{web_port}",
    "http://127.0.0.1:#{web_port}"
  ],
  code_reloader: false,
  debug_errors: true,
  session: [
    signing_salt: System.get_env("PATCHBAY_SESSION_SIGNING_SALT", "dev-only-session-signing-salt")
  ],
  live_view: [
    signing_salt:
      System.get_env("PATCHBAY_LIVE_VIEW_SIGNING_SALT", "dev-only-live-view-signing-salt")
  ],
  secret_key_base: System.get_env("SECRET_KEY_BASE") || String.duplicate("p", 64)

config :logger, level: :info
