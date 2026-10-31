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

          const PatchbaySelection = {
            selectable(el) {
              if (!el) return false
              if (el.tagName !== "INPUT" && el.tagName !== "TEXTAREA") return false
              if (el.disabled || el.readOnly) return false
              if (el.tagName === "INPUT") {
                const types = ["text", "search", "url", "tel", "password"]
                if (!types.includes((el.type || "text").toLowerCase())) return false
              }
              return typeof el.selectionStart === "number" && typeof el.selectionEnd === "number"
            },
            indexOf(el) {
              const all = document.querySelectorAll("input, textarea")
              for (let index = 0; index < all.length; index++) {
                if (all[index] === el) return index
              }
              return -1
            },
            remember(el) {
              if (!this.selectable(el)) return
              this.saved = {
                el,
                id: el.id || null,
                name: el.getAttribute("name"),
                type: el.getAttribute("type") || el.tagName.toLowerCase(),
                index: this.indexOf(el),
                start: el.selectionStart,
                end: el.selectionEnd,
                direction: el.selectionDirection || "none",
                focused: document.activeElement === el
              }
            },
            resolve(saved) {
              if (saved.el && saved.el.isConnected && this.selectable(saved.el)) return saved.el
              if (saved.id) {
                const byId = document.getElementById(saved.id)
                if (this.selectable(byId)) return byId
              }
              if (saved.name) {
                const named = document.querySelectorAll(
                  "input[name='" + saved.name + "'], textarea[name='" + saved.name + "']"
                )
                const same = Array.from(named).filter((el) => {
                  const type = el.getAttribute("type") || el.tagName.toLowerCase()
                  return this.selectable(el) && type === saved.type
                })
                if (same.length === 1) return same[0]
              }
              if (saved.index >= 0) {
                const candidate = document.querySelectorAll("input, textarea")[saved.index]
                if (this.selectable(candidate)) return candidate
              }
              return null
            },
            restore() {
              const saved = this.saved
              if (!saved) return
              const el = this.resolve(saved)
              if (!el) return
              const active = document.activeElement
              const lost = active == null || active === document.body
              if (!saved.focused || (!lost && active !== el)) return

              if (active !== el) {
                try {
                  el.focus({preventScroll: true})
                } catch (_error) {
                  el.focus()
                }
              }

              try {
                const max = el.value == null ? 0 : el.value.length
                el.setSelectionRange(
                  Math.min(saved.start, max),
                  Math.min(saved.end, max),
                  saved.direction
                )
              } catch (_error) {
                // Inputs without a selection range simply keep focus.
              }
            },
            mounted() {
              this.saved = null
              this.restoring = false
              this.onFocusIn = (event) => this.remember(event.target)
              this.onKeyUp = (event) => this.remember(event.target)
              this.onMouseUp = (event) => this.remember(event.target)
              this.onSelectionChange = () => {
                if (this.restoring) return
                const active = document.activeElement
                if (this.selectable(active)) this.remember(active)
              }
              this.onFocusOut = () => {
                if (this.saved && document.activeElement !== this.saved.el) {
                  this.saved.focused = false
                }
              }
              this.onUpdate = () => {
                if (this.restoring) return
                this.restoring = true
                try {
                  this.restore()
                } finally {
                  this.restoring = false
                }
              }
              document.addEventListener("focusin", this.onFocusIn, true)
              document.addEventListener("focusout", this.onFocusOut, true)
              document.addEventListener("keyup", this.onKeyUp, true)
              document.addEventListener("mouseup", this.onMouseUp, true)
              document.addEventListener("selectionchange", this.onSelectionChange)
              document.addEventListener("phx:update", this.onUpdate)
            },
            updated() {
              this.onUpdate()
            },
            destroyed() {
              document.removeEventListener("focusin", this.onFocusIn, true)
              document.removeEventListener("focusout", this.onFocusOut, true)
              document.removeEventListener("keyup", this.onKeyUp, true)
              document.removeEventListener("mouseup", this.onMouseUp, true)
              document.removeEventListener("selectionchange", this.onSelectionChange)
              document.removeEventListener("phx:update", this.onUpdate)
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

          const PatchbayClock = {
            mounted() {
              this.time = this.el.querySelector("[data-clock-time]")
              this.tick = () => {
                if (!this.time) return
                const now = new Date()
                const pad = (value) => String(value).padStart(2, "0")
                this.time.textContent =
                  pad(now.getUTCHours()) + ":" + pad(now.getUTCMinutes()) + ":" + pad(now.getUTCSeconds())
              }
              this.tick()
              this.timer = window.setInterval(this.tick, 1000)
            },
            updated() {
              if (this.tick) this.tick()
            },
            destroyed() {
              window.clearInterval(this.timer)
            }
          }

          window.addEventListener("DOMContentLoaded", () => {
            const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
            const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
              params: {_csrf_token: csrfToken},
              hooks: {PatchbayFlash, PatchbayStream, PatchbaySelection, PatchbayDetails, PatchbayClock}
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
    <div id="patchbay-root" phx-hook="PatchbaySelection" style="display: contents">
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
    </div>
    """
  end
end
