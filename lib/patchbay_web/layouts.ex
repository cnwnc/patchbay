defmodule PatchbayWeb.Layouts do
  @moduledoc false

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Patchbay Console</title>
        <link rel="stylesheet" href="/assets/app.css" />
        <script defer src="/assets/phoenix.js"></script>
        <script defer src="/assets/phoenix_live_view.js"></script>
      </head>
      <body>
        {@inner_content}
        <script>
          window.addEventListener("DOMContentLoaded", () => {
            const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
            const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
              params: {_csrf_token: csrfToken}
            })
            liveSocket.connect()
            window.liveSocket = liveSocket
          })
        </script>
      </body>
    </html>
    """
  end

  def app(assigns) do
    ~H"""
    <div class="flash-stack" aria-live="polite">
      <div :for={{kind, message} <- @flash} class={"flash flash-#{kind}"}>{message}</div>
    </div>
    {@inner_content}
    """
  end
end
