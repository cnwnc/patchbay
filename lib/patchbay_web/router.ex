defmodule PatchbayWeb.Router do
  use PatchbayWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {PatchbayWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", PatchbayWeb do
    pipe_through(:browser)

    live("/", ConsoleLive, :index)
    live("/console", ConsoleLive, :index)
    live("/config", ConfigurationLive, :index)
    live("/config/:id", ConfigurationLive, :show)
  end
end
