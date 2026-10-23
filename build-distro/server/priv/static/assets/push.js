// A subscription belongs to the browser; each bucket opts in separately on the server.
globalThis.BuildNotifications = {
  mounted() {
    this.button = this.el.querySelector("[data-push-toggle]")
    this.status = this.el.querySelector("[data-push-status]")
    this.click = () => this.toggle()
    this.button.addEventListener("click", this.click)
    this.refresh()
  },

  updated() {
    if (this.loadedUrl !== this.el.dataset.url) this.refresh()
  },

  destroyed() {
    this.version = (this.version || 0) + 1
    this.button.removeEventListener("click", this.click)
  },

  async request(action, subscription, url = this.el.dataset.url) {
    const response = await fetch(url, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "content-type": "application/json",
        "accept": "application/json",
        "x-csrf-token": document.querySelector("meta[name='csrf-token']").content,
      },
      body: JSON.stringify({ action, subscription: subscription?.toJSON() || {} }),
    })
    if (!response.ok) throw new Error("Notification settings could not be saved. Try again.")
    return response.json()
  },

  async refresh() {
    this.loadedUrl = this.el.dataset.url
    const version = this.version = (this.version || 0) + 1
    const current = () => version === this.version
    const manifest = document.querySelector("link[rel='manifest']")
    if (manifest) manifest.href = this.el.dataset.manifest
    this.button.disabled = true

    if (!("serviceWorker" in navigator) || !("PushManager" in globalThis) || !("Notification" in globalThis)) {
      this.button.textContent = "Notifications unavailable"
      this.status.textContent = "On iPhone or iPad, add this page to your Home Screen, open it there, then enable notifications."
      return
    }

    if (Notification.permission === "denied") {
      this.button.textContent = "Notifications blocked"
      this.status.textContent = "Allow notifications in your browser or device settings, then reopen this page."
      return
    }

    try {
      await navigator.serviceWorker.register("/service-worker.js", { scope: "/", updateViaCache: "none" })
      const registration = await navigator.serviceWorker.ready
      const subscription = await registration.pushManager.getSubscription()
      const { subscribed } = await this.request("status", subscription)
      if (!current()) return
      this.registration = registration
      this.subscription = subscription
      this.subscribed = subscribed
      this.button.disabled = false
      this.button.textContent = subscribed ? "Turn off notifications" : "Notify me about new builds"
      this.status.textContent = subscribed ? "Notifications are on for this bucket on this device." : ""
    } catch (error) {
      if (!current()) return
      this.button.textContent = "Retry notifications"
      this.status.textContent = error.message
      this.registration = null
      this.button.disabled = false
    }
  },

  async toggle() {
    if (this.button.disabled) return
    if (!this.registration) return this.refresh()
    const version = this.version
    const url = this.el.dataset.url
    const subscribed = this.subscribed
    this.button.disabled = true
    this.button.textContent = subscribed ? "Turning off notifications…" : "Enabling notifications…"
    this.status.textContent = subscribed ? "" : "Allow notifications when your browser asks."
    try {
      let subscription = this.subscription
      if (!subscribed && !subscription) {
        // Subscribe directly from the tap so iOS can show its permission prompt.
        const key = this.el.dataset.publicKey.replace(/-/g, "+").replace(/_/g, "/")
        const applicationServerKey = Uint8Array.from(atob(key), character => character.charCodeAt(0))
        subscription = await this.registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey })
      }
      await this.request(subscribed ? "unsubscribe" : "subscribe", subscription, url)
      if (version === this.version) await this.refresh()
    } catch (error) {
      if (version !== this.version) return
      if (Notification.permission === "denied") return this.refresh()
      this.button.disabled = false
      this.button.textContent = subscribed ? "Turn off notifications" : "Notify me about new builds"
      this.status.textContent = error.message
    }
  },
}
