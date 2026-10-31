defmodule PatchbayWeb.Router do
  use PatchbayWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(PatchbayWeb.Auth)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {PatchbayWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  # Serving artifact bytes: same UI credentials, no session or HTML
  # negotiation requirements so curl and wget work as clients.
  pipeline :artifacts do
    plug(:fetch_session)
    plug(PatchbayWeb.Auth)
  end

  scope "/", PatchbayWeb do
    pipe_through(:browser)

    live_session :authenticated, on_mount: {PatchbayWeb.Auth, :default} do
      live("/", ConsoleLive, :index)
      live("/console", ConsoleLive, :index)
      live("/config", ConfigurationLive, :index)
      live("/config/:id", ConfigurationLive, :show)
      live("/toolkits", ToolkitLive, :index)
      live("/toolkits/:id", ToolkitLive, :show)
    end
  end

  scope "/artifacts", PatchbayWeb do
    pipe_through(:artifacts)

    get("/:agent_id/:filename", ArtifactsController, :show)
  end
end
