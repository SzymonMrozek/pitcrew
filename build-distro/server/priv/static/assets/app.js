// LiveView's prebuilt bundles define the Phoenix and LiveView globals, so the
// app needs no JavaScript build step.
(() => {
  const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

  const relative = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" })
  const units = [
    ["year", 31536000], ["month", 2592000], ["week", 604800],
    ["day", 86400], ["hour", 3600], ["minute", 60],
  ]

  function formatRelative(date) {
    const seconds = (date.getTime() - Date.now()) / 1000
    for (const [unit, size] of units) {
      if (Math.abs(seconds) >= size) return relative.format(Math.round(seconds / size), unit)
    }
    return "just now"
  }

  const Hooks = {
    BuildNotifications: globalThis.BuildNotifications,
    RelativeTime: {
      mounted() {
        this.render()
        this.timer = setInterval(() => this.render(), 30000)
      },
      updated() { this.render() },
      destroyed() { clearInterval(this.timer) },
      render() { this.el.textContent = formatRelative(new Date(this.el.dateTime)) },
    },
    Copy: {
      mounted() {
        this.el.addEventListener("click", async () => {
          await navigator.clipboard.writeText(this.el.dataset.copy)
          this.el.textContent = "Copied"
          setTimeout(() => { this.el.textContent = "Copy" }, 1500)
        })
      },
    },
  }

  // Redeploys take seconds, so retry quickly before backing off.
  const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
    params: { _csrf_token: csrfToken },
    hooks: Hooks,
    reconnectAfterMs: (tries) => [100, 250, 500, 1000, 2000][tries - 1] || 3000,
  })

  liveSocket.connect()
  window.liveSocket = liveSocket
})()
