# Session broker: architecture notes

Why the broker works the way it does. Read this before building your own.

## The problem

Each iOS Simulator has its own Keychain. When you run one app in several
simulators (one per git worktree, one per coding agent), you get:

- **A login per simulator.** Every new worktree starts logged out.
- **Refresh races.** With refresh-token rotation, a refresh invalidates the old
  refresh token. Two simulators that refresh at about the same time race each
  other: one wins, and the other is logged out without any visible reason.
- **Many "devices".** A backend that binds sessions to a device ID sees a new
  device for each simulator.

## The shape of the solution

One local process is the single source of truth for three things:

| State | Where it lives | Survives a restart |
| --- | --- | --- |
| The session (`accessToken`, `refreshToken`, `expiresAt`) | JSON file in a volume | Yes |
| A machine-level device ID | File next to the session | Yes |
| Who is refreshing right now | Memory only | No, on purpose |

Simulators read and write through it over HTTP on `127.0.0.1`. Devices never
see it: the app picks the Keychain on devices and the broker in simulators at
compile time.

## Invariants

These are the properties that make it work. If you build your own, keep them,
whatever your stack.

1. **One writer of truth.** All simulators read the same session. None of them
   keeps its own copy as the authority.
2. **At most one refresh at a time.** A client asks for refresh ownership
   before calling the OAuth server. Everyone else waits for the result instead
   of refreshing too.
3. **Ownership is a lease, not a lock.** It expires (45 seconds by default). A
   crashed owner can't block the others forever, and when the lease runs out,
   exactly one waiter takes over.
4. **Writes after a refresh are compare-and-set.** Completing a refresh sends
   the access token it replaces. The write is accepted only when the caller
   still owns an unexpired lease and the stored token still matches. Otherwise
   it gets `409`, so a stale owner can't overwrite a newer session.
5. **Login and logout are unconditional.** The user's explicit action always
   wins, including over a refresh in progress.
6. **Readers don't see a session that's about to be replaced.** `GET /session`
   waits while a refresh is running.
7. **A change is detected by version, not by value.** An in-memory generation
   counter goes up on every write. A waiter that wakes up compares
   generations, so a reused token string can't hide that the session changed.
8. **Bad persisted data stops startup.** A corrupt session or device ID file
   makes startup fail instead of silently resetting it. Resetting the device ID
   would make every simulator look like a new device to your backend.
9. **Device builds never contain the broker code path.** The choice is
   compile-time (`#if targetEnvironment(simulator)`), not a runtime flag.

## Incidental choices

Replace any of these freely:

- **Python, FastAPI and one Uvicorn worker.** Anything that can hold a mutex and
  a condition variable in one process works.
- **Docker and Compose.** They're just an easy way to get one long-lived
  process with a named volume. A launchd agent would work too.
- **HTTP and JSON on port 8765,** the header name, the 45-second lease.
- **The Swift client.** `SessionStore` is a struct of closures. A protocol with
  classes, as in my own app, works just as well.
- **iOS.** For Android emulators, the same broker is reachable from the
  emulator at `10.0.2.2`.

## Client-side design

App code holds one `SessionStore` value and never asks where the session lives:

- **`.live` is the only place that decides:** Keychain on devices, broker in
  simulators.
- **Refresh belongs to the store,** because that's where the backends really
  differ. With the Keychain, the store refreshes and saves. With the broker, it
  claims the lease first. Call sites are identical.
- **`RefreshTokenRejected` logs out; every other error is transient.** A
  rejected refresh token means the session is dead for everyone. A network
  failure isn't, so the session is kept and the error is rethrown.
- **`SESSION_STORE=keychain` is an escape hatch** for running a simulator
  without Docker or debugging Keychain behavior.
- **The device ID is swapped the same way** (`DeviceIDProvider`), so a backend
  sees one device per developer machine.

## Pitfalls I hit

Each of these cost real debugging time.

- **Several server workers.** Lease coordination lives in memory, so a second
  worker process would grant a second lease. Run exactly one.
- **Comparing token strings to detect changes.** It works until it doesn't.
  Use a generation counter (invariant 7).
- **Building the app object at import time.** The default broker writes to
  `/data` as soon as the module loads, so tests outside Docker failed on a
  read-only filesystem. `tests/conftest.py` points `SESSION_FILE` at a temp
  directory.
- **Date formats.** Pydantic writes fractional seconds only when they're not
  zero. Swift's `.iso8601` decoding strategy rejects fractional seconds, so the
  client tries both formats.
- **Keychain tests in a Swift package.** On the iOS Simulator, SwiftPM test
  bundles have no host app and therefore no Keychain entitlement:
  `SecItem*` returns `-34018` (`errSecMissingEntitlement`). Host the Keychain
  tests in an app, as `examples/ios-app` does.
- **Parallel integration tests.** Every test shares the broker's one session.
  Run them serially (`swift test --no-parallel`, `.serialized` suites).
- **One broker per app, one broker per machine.** A broker holds exactly one
  session. Two different apps need two brokers on two ports. One app across
  many worktrees needs one fixed Compose project and volume name. Per-worktree
  names fight over the port and split the session.
- **App Transport Security.** Plain HTTP to `127.0.0.1` needs
  `NSAllowsLocalNetworking` in Debug builds.
- **First-launch race for the device ID.** Two concurrent first reads can each
  generate an ID. Add-only Keychain writes (`errSecDuplicateItem`, then read
  back) make them agree.
- **Transient refresh failures stall other readers.** While a lease is held,
  `GET /session` waits, for up to 45 seconds if the owner never finishes. That's
  the trade-off for not logging everyone out on a network blip. A shorter lease
  shortens the stall.

## Non-goals

- **Security.** Tokens are stored as plaintext in a local volume. Bind to
  `127.0.0.1` only, and never deploy the broker.
- **Several machines.** Each developer machine has its own broker.
- **Production.** Physical devices and release builds on devices use the
  Keychain.
