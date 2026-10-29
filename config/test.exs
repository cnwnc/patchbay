import Config

config :patchbay,
  start_services: false

config :patchbay, :ui_token, "test-ui-token"

config :patchbay, PatchbayWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  server: false,
  check_origin: [
    "http://localhost:4002",
    "http://127.0.0.1:4002"
  ],
  session: [signing_salt: "test-only-session-signing-salt"],
  live_view: [signing_salt: "test-only-live-view-signing-salt"],
  secret_key_base: String.duplicate("t", 64)

config :logger, level: :warning
