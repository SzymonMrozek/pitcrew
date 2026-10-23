// Do not cache authenticated pages, public tokens, manifests, or build artifacts.
self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", event => event.waitUntil(self.clients.claim()))

self.addEventListener("push", event => {
  const message = event.data?.json() || {}
  event.waitUntil(self.registration.showNotification(message.title || "New build ready", {
    body: message.body || "Open build-distro to install the latest build.",
    icon: "/images/apple-touch-icon.png",
    tag: message.tag,
    data: { url: message.url || "/" },
  }))
})

self.addEventListener("notificationclick", event => {
  event.notification.close()
  const url = new URL(event.notification.data?.url || "/", self.location.origin)
  if (url.origin !== self.location.origin) return
  event.waitUntil(self.clients.openWindow(url.href))
})
