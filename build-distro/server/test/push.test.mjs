import test from "node:test"
import assert from "node:assert/strict"
import vm from "node:vm"
import { readFileSync } from "node:fs"

const clientSource = readFileSync(new URL("../priv/static/assets/push.js", import.meta.url), "utf8")
const workerSource = readFileSync(new URL("../priv/static/service-worker.js", import.meta.url), "utf8")
const flush = () => new Promise(resolve => setImmediate(resolve))

function client({ permission = "default", supported = true, subscribed = false, subscription = null, fetcher } = {}) {
  const requests = []
  const button = { disabled: false, textContent: "", addEventListener() {}, removeEventListener() {} }
  const status = { textContent: "" }
  const manifest = {}
  const el = {
    dataset: { url: "/app/p/token/notifications/main", manifest: "/app/p/token/manifest.webmanifest?bucket=main", publicKey: "AQID" },
    querySelector: selector => selector === "[data-push-toggle]" ? button : status,
  }
  let subscribeCalls = 0
  let unsubscribeCalls = 0
  let browserSubscription = subscription
  const registration = { pushManager: {
    getSubscription: async () => browserSubscription,
    subscribe: options => {
      subscribeCalls++
      assert.equal(options.userVisibleOnly, true)
      browserSubscription = { toJSON: () => ({ endpoint: "https://web.push.apple.com/device", keys: {} }),
        unsubscribe: () => { unsubscribeCalls++; return Promise.resolve(true) } }
      return Promise.resolve(browserSubscription)
    },
  } }
  const context = vm.createContext({
    Uint8Array, atob,
    navigator: supported ? { serviceWorker: { register: async () => {}, ready: Promise.resolve(registration) } } : {},
    ...(supported ? { PushManager: {}, Notification: { permission } } : {}),
    document: { querySelector: selector => selector.startsWith("meta") ? { content: "csrf" } : manifest },
    fetch: async (url, options) => {
      const body = JSON.parse(options.body)
      requests.push({ url, options, body })
      if (fetcher) return fetcher(url, options)
      if (body.action === "subscribe") subscribed = true
      if (body.action === "unsubscribe") subscribed = false
      return { ok: true, json: async () => ({ subscribed }) }
    },
  })
  vm.runInContext(clientSource, context)
  const hook = Object.assign({}, context.BuildNotifications, { el })
  hook.mounted()
  return { hook, button, status, manifest, requests, subscribeCalls: () => subscribeCalls,
    unsubscribeCalls: () => unsubscribeCalls }
}

test("iPhone without Home Screen push support gets installation instructions", async () => {
  const c = client({ supported: false })
  await flush()
  assert.equal(c.button.disabled, true)
  assert.match(c.status.textContent, /Home Screen/)
  assert.equal(c.requests.length, 0)
})

test("permission denial explains how to recover without prompting", async () => {
  const c = client({ permission: "denied" })
  await flush()
  assert.equal(c.button.disabled, true)
  assert.match(c.status.textContent, /settings/)
  assert.equal(c.subscribeCalls(), 0)
})

test("an explicit tap subscribes immediately, saves the bucket, and restores state on reload", async () => {
  const c = client()
  await flush()
  assert.equal(c.subscribeCalls(), 0)
  const toggle = c.hook.toggle()
  assert.equal(c.subscribeCalls(), 1)
  await toggle
  assert.match(c.button.textContent, /Turn off/)
  const request = c.requests.find(r => r.body.action === "subscribe")
  assert.equal(request.url, "/app/p/token/notifications/main")
  assert.equal(request.options.headers["x-csrf-token"], "csrf")
  assert.equal(request.options.credentials, "same-origin")
  await c.hook.refresh()
  assert.match(c.button.textContent, /Turn off/)
})

test("opting out removes only this bucket, keeping the shared browser subscription", async () => {
  const c = client()
  await flush()
  await c.hook.toggle()
  await c.hook.toggle()
  assert.match(c.button.textContent, /Notify me/)
  assert.equal(c.unsubscribeCalls(), 0)
  assert.equal(c.requests.at(-2).body.action, "unsubscribe")
})

test("live upload renders do not repeatedly fetch settings; bucket navigation updates the manifest", async () => {
  const c = client()
  await flush()
  const count = c.requests.length
  c.hook.updated()
  await flush()
  assert.equal(c.requests.length, count)
  c.hook.el.dataset.url = "/app/notifications/manual"
  c.hook.el.dataset.manifest = "/app/manifest.webmanifest?bucket=manual"
  c.hook.updated()
  await flush()
  assert.equal(c.requests.at(-1).url, "/app/notifications/manual")
  assert.equal(c.manifest.href, "/app/manifest.webmanifest?bucket=manual")
})

test("a stale request cannot overwrite settings for a newly selected bucket", async () => {
  let resolveOld
  let requests = 0
  const c = client({ fetcher: async () => {
    if (++requests === 1) return new Promise(resolve => { resolveOld = resolve })
    return { ok: true, json: async () => ({ subscribed: false }) }
  } })
  await flush()
  c.hook.el.dataset.url = "/app/notifications/manual"
  await c.hook.updated()
  await flush()
  resolveOld({ ok: true, json: async () => ({ subscribed: true }) })
  await flush()
  assert.match(c.button.textContent, /Notify me/)
})

test("server failures are visible and can be retried", async () => {
  const c = client({ fetcher: async () => ({ ok: false }) })
  await flush()
  assert.match(c.status.textContent, /Try again/)
  assert.equal(c.button.disabled, false)
  assert.match(c.button.textContent, /Retry/)
})

function worker() {
  const listeners = {}
  const notifications = []
  const opened = []
  const self = {
    addEventListener: (name, listener) => { listeners[name] = listener },
    location: { origin: "https://builds.example.com" },
    registration: { showNotification: async (title, options) => notifications.push({ title, options }) },
    clients: { openWindow: async url => opened.push(url), claim: async () => {} },
    skipWaiting: async () => {},
  }
  vm.runInNewContext(workerSource, { self, URL })
  return { listeners, notifications, opened }
}

test("background push shows a notification and its tap preserves the public build URL", async () => {
  const w = worker()
  let pending
  w.listeners.push({ data: { json: () => ({ title: "My App · new build", body: "1.4 (412) is ready", url: "/app/p/public-token/builds/42", tag: "build-42" }) },
    waitUntil: promise => { pending = promise } })
  await pending
  assert.equal(w.notifications[0].title, "My App · new build")
  assert.equal(w.notifications[0].options.tag, "build-42")
  let closed = false
  w.listeners.notificationclick({ notification: { data: w.notifications[0].options.data, close: () => { closed = true } },
    waitUntil: promise => { pending = promise } })
  await pending
  assert.equal(closed, true)
  assert.deepEqual(w.opened, ["https://builds.example.com/app/p/public-token/builds/42"])
  assert.equal(w.listeners.fetch, undefined)
})

test("notification taps never navigate to a different origin", () => {
  const w = worker()
  w.listeners.notificationclick({ notification: { data: { url: "https://evil.example.com" }, close() {} }, waitUntil() {} })
  assert.deepEqual(w.opened, [])
})
