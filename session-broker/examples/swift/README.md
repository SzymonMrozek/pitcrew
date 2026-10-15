# Using the broker from an iOS app

Two small, dependency-free libraries:

- **`SessionStore`**: what your app uses. Keychain on devices, the broker in
  simulators, behind one type.
- **`SessionBrokerClient`**: the raw HTTP client, if you want to build your own.

Add this folder as a local package, or copy `Sources/` into your app.
[`../ios-app`](../ios-app) is a runnable app that uses everything below.

## The swap

App code never asks where the session lives. It holds a `SessionStore`, which
is a plain struct of closures, and `.live` is the only place that chooses:

```swift
import SessionStore

let sessions = SessionStore.live(keychainService: "com.example.app")
let deviceIDs = DeviceIDProvider.live(keychainService: "com.example.app")
```

| Where it runs | `SessionStore.live` | `DeviceIDProvider.live` |
| --- | --- | --- |
| Device (Debug and Release) | Keychain | UUID kept in the Keychain |
| Simulator | Session broker | The machine's broker ID |
| Simulator with `SESSION_STORE=keychain` | Keychain | UUID kept in the Keychain |

The device-or-simulator choice is made with `#if targetEnvironment(simulator)`,
so device builds don't even contain the broker branch. The environment
variable is a per-scheme escape hatch, for debugging Keychain behavior or
running without Docker.

Tests and SwiftUI previews use the in-memory store:

```swift
ContentView(model: SessionModel(store: .inMemory(), ...))
```

`store.name` reports the active backend (`"Keychain"`, `"Session broker"`,
`"In memory"`), which is useful in logs and debug screens.

## Same call sites everywhere

```swift
// Launch
let session = try await sessions.session()

// Login and logout
try await sessions.save(newSession)
try await sessions.clear()              // with the broker, every simulator logs out

// Before each request, when the access token is about to expire
let fresh = try await sessions.refresh(expired) { refreshToken in
    do {
        return try await authAPI.refresh(refreshToken)
    } catch AuthError.invalidGrant {
        throw RefreshTokenRejected()   // the store clears the session and returns nil
    }
}
```

Refresh is part of the store because that's where the backends really differ.
With the Keychain, the store simply runs your closure and saves the result.
With the broker, it first claims refresh ownership: one simulator runs your
closure, and the others wait and pick up its result. That way rotating refresh
tokens never revoke each other. Any error other than `RefreshTokenRejected` is
treated as transient: the session is kept and the error is rethrown.

## Your own backend

`SessionStore` has a public initializer, so you can add another backend (for
example, an App Group container shared with an extension) without changing any
call site:

```swift
SessionStore(name: "App Group", load: { ... }, save: { ... }, clear: { ... }) { expired, refresh in ... }
```

## Things to know

- **Plain HTTP:** add `NSAllowsLocalNetworking` to your Debug `Info.plist`.
  The example app shows how.
- **One broker, one session:** a broker holds exactly one session. If two
  different apps on your machine use it, run one broker per app on different
  ports, and pass `SessionBrokerClient(baseURL:)` to `.live(broker:)`.
- **Custom header:** if you run the broker with `SESSION_BROKER_CLIENT_ID_HEADER`,
  pass the same value to `SessionBrokerClient(clientIDHeader:)`.

## Tests

```bash
docker compose -f ../../compose.yaml up --detach --build --wait
SESSION_BROKER_URL=http://127.0.0.1:8765 swift test --no-parallel
```

The suites share the broker's single session, so run them serially. The
Keychain tests live in the example app, because SwiftPM test bundles have no
Keychain entitlement on the iOS Simulator.
