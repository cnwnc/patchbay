import Config

config :patchbay,
  start_services: true

config :patchbay, PatchbayWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PatchbayWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: Patchbay.PubSub,
  session: [
    store: :cookie,
    key: "_patchbay_key",
    same_site: "Lax"
  ]

config :phoenix, :json_library, Jason

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
