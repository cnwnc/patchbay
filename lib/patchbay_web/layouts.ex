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
          const PatchbayFlash = {
            mounted() {
              this.onEnter = () => this.pushEvent("pause_flash", {kind: this.el.dataset.kind})
              this.onLeave = () => this.pushEvent("resume_flash", {kind: this.el.dataset.kind})
              this.el.addEventListener("mouseenter", this.onEnter)
              this.el.addEventListener("mouseleave", this.onLeave)
            },
            destroyed() {
              this.el.removeEventListener("mouseenter", this.onEnter)
              this.el.removeEventListener("mouseleave", this.onLeave)
            }
          }

          const PatchbayStream = {
            atBottom() {
              return this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 8
            },
            follow() {
              this.el.scrollTop = this.el.scrollHeight
            },
            mounted() {
              this.wasAtBottom = true
              this.follow()
            },
            beforeUpdate() {
              this.wasAtBottom = this.atBottom()
            },
            updated() {
              if (this.wasAtBottom) {
                this.follow()
              }
            }
          }

          window.addEventListener("DOMContentLoaded", () => {
            const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
            const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
              params: {_csrf_token: csrfToken},
              hooks: {PatchbayFlash, PatchbayStream}
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
      <div
        :for={{kind, message} <- @flash}
        id={"flash-" <> to_string(kind)}
        class={"flash flash-#{kind}"}
        role="status"
        phx-hook="PatchbayFlash"
        phx-click="dismiss_flash"
        phx-value-kind={kind}
        data-kind={kind}
        data-flash-timeout="6000"
      >
        {message}
      </div>
    </div>
    {@inner_content}
    """
  end
end
