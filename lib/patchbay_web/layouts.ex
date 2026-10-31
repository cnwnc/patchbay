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
            BOTTOM_EDGE: 8,
            atBottom() {
              return this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < this.BOTTOM_EDGE
            },
            follow() {
              this.el.scrollTop = this.el.scrollHeight
            },
            mounted() {
              this.pinned = true
              this.agentKey = this.el.dataset.streamAgent
              this.observed = new WeakSet()
              this.onScroll = () => {
                this.pinned = this.atBottom()
              }
              this.onWheel = (event) => {
                if (event.deltaY < 0 && this.el.scrollTop > 0) {
                  this.pinned = false
                }
              }
              this.ro = new ResizeObserver(() => {
                if (this.pinned) {
                  this.follow()
                }
              })
              this.el.addEventListener("scroll", this.onScroll, {passive: true})
              this.el.addEventListener("wheel", this.onWheel, {passive: true})
              this.observeContent()
              this.follow()
              window.requestAnimationFrame(() => this.sync())
            },
            updated() {
              window.requestAnimationFrame(() => this.sync())
            },
            destroyed() {
              this.ro.disconnect()
              this.el.removeEventListener("scroll", this.onScroll)
              this.el.removeEventListener("wheel", this.onWheel)
            },
            observeContent() {
              this.ro.observe(this.el)
              this.el.querySelectorAll(":scope > li").forEach((row) => {
                if (!this.observed.has(row)) {
                  this.observed.add(row)
                  this.ro.observe(row)
                }
              })
            },
            sync() {
              if (this.agentKey !== this.el.dataset.streamAgent) {
                this.agentKey = this.el.dataset.streamAgent
                this.pinned = true
              }
              this.observeContent()
              if (this.pinned) {
                this.follow()
              }
            }
          }

          const PatchbayDetails = {
            open: new Set(),
            mounted() {
              this.onToggle = () => {
                if (this.el.open) {
                  PatchbayDetails.open.add(this.el.id)
                } else {
                  PatchbayDetails.open.delete(this.el.id)
                }
              }
              this.el.addEventListener("toggle", this.onToggle)
              this.restore()
            },
            updated() {
              this.restore()
            },
            destroyed() {
              this.el.removeEventListener("toggle", this.onToggle)
            },
            restore() {
              const key = this.el.id

              if (key !== this.key) {
                this.key = key
                this.el.open = PatchbayDetails.open.has(key)
              } else if (PatchbayDetails.open.has(key) && !this.el.open) {
                this.el.open = true
              }
            }
          }

          window.addEventListener("DOMContentLoaded", () => {
            const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
            const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
              params: {_csrf_token: csrfToken},
              hooks: {PatchbayFlash, PatchbayStream, PatchbayDetails}
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
