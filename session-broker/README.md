# Simulator Session Broker

A local HTTP service that gives every iOS Simulator on your machine the same
OAuth session per backend environment and one device ID. Only one simulator
refreshes a given environment's tokens at a time.
Log in once, and every simulator (one per worktree, one per agent) is logged in.

The workflow it was built for (one worktree, one simulator, one shared
session) is described in my article
[Per-Worktree iOS Simulators with a Shared OAuth Session](https://mrozek.dev/posts/one-worktree-one-simulator-one-shared-session).

> **Local development only.** Tokens are stored unencrypted in a Docker volume.
> Bind the broker to `127.0.0.1` only, and never deploy it.

## Why

Each simulator has its own Keychain, so every simulator holds its own copy of
the session. With refresh-token rotation, two simulators that refresh at about
the same time race each other: one wins and the other's token gets revoked.
The broker fixes this by acting as the single source of truth and by giving
**exactly one** process the right to refresh at a time.

## Quick start

```bash
cd session-broker
docker compose up --detach --build --wait
curl http://127.0.0.1:8765/health
```

Run the tests:

```bash
docker compose run --rm session-broker pytest
```

## HTTP API

| Method | Path | Behavior |
| --- | --- | --- |
| `GET` | `/health` | `200` when ready; includes `"environments": true`. |
| `GET` | `/device-id` | Persistent machine-level device ID (`{"deviceId": "..."}`). |
| `GET` | `/sessions?environment=production` | Canonical session. Waits while a refresh is in progress; `404` when logged out. |
| `POST` | `/sessions/refresh/start?environment=production` | Claims refresh ownership, or waits for the current owner. Returns `{"shouldRefresh": bool}`. |
| `PUT` | `/sessions?environment=production` | Stores a session after login, or conditionally completes an owned refresh. |
| `DELETE` | `/sessions?environment=production` | Logs out this environment, or conditionally removes the session after a failed owned refresh. |

Use `environment=development` (or another backend name) on every session and
refresh request to select its independent session, refresh lease, and waiting
readers. Names contain 1–64 lowercase letters, digits, hyphens, or underscores,
starting with a letter or digit. `/device-id` stays shared across environments.
Requests without an environment select `production`. The legacy `/session` and
`/refresh/start` routes remain aliases for older clients. New clients should use
the plural routes: an older broker returns `404` instead of silently ignoring
an environment parameter and overwriting its shared session.

Production keeps `SESSION_FILE` unchanged. Other environments persist next to
it as `<stem>.<environment><suffix>`, for example `/data/session.development.json`.
All persisted environments are validated at startup. Sessions survive a broker
restart; in-memory refresh ownership is isolated per environment and resets.

Session shape:

```json
{ "accessToken": "...", "refreshToken": "...", "expiresAt": "2030-01-01T00:00:00Z" }
```

Every mutating or refresh request must carry a per-process UUID in the client
ID header (default `X-Session-Client-ID`).

### Refresh protocol

1. A client sees an expired access token and calls `POST /sessions/refresh/start?environment=production` with
   `{"replacingAccessToken": "<the token it holds>"}`.
2. If `shouldRefresh` is `true`, the client owns the refresh. It calls your
   OAuth server, then sends `PUT /sessions?environment=production` with the new session and the same
   `replacingAccessToken`. If the refresh fails, it sends `DELETE /sessions?environment=production` with
   the same `replacingAccessToken` instead.
3. If `shouldRefresh` is `false`, another process already refreshed, so the
   client calls `GET /sessions?environment=production` to read the new session.

Use the same environment parameter throughout this protocol. Ownership expires after 45 seconds. If an owner crashes, exactly one waiter
takes over. A stale owner's conditional `PUT` or `DELETE` gets `409` and cannot
overwrite a newer session. Leaving out `replacingAccessToken` makes the
operation unconditional, which is what login and logout use.

## Configuration

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `SESSION_FILE` | `/data/session.json` | Production session location; named environment sessions and `device-id` are stored next to it. |
| `SESSION_BROKER_CLIENT_ID_HEADER` | `X-Session-Client-ID` | Header name that identifies a client process. |
| `SESSION_BROKER_REFRESH_TIMEOUT` | `45` | Refresh ownership lifetime in seconds. |

Run exactly **one** Uvicorn worker. Refresh coordination is held in memory.

## Using it

- **As it is:** [`examples/consumer`](examples/consumer) is the whole
  integration: a `compose.yaml` that builds the broker from a pinned pitcrew tag.
- **In app code:** [`examples/swift`](examples/swift) has `SessionStore`, one
  type that uses the Keychain on devices and the broker in simulators.
  [`examples/ios-app`](examples/ios-app) is a runnable SwiftUI app built on it.
- **As a reference for your own:** read [ARCHITECTURE.md](ARCHITECTURE.md) for the
  invariants that matter, the parts you can swap out, and the pitfalls.

## Failure modes

- **Invalid persisted JSON or device ID:** the server refuses to start rather
  than silently replace the data. Fix or remove the volume on purpose.
- **Broker restart:** the session is kept, but refresh ownership is not. Clients
  just get a new ownership window.
- **Port `8765` busy:** remap the host port in `compose.yaml` and point your
  client at it.

## License

See [LICENSE](../LICENSE).
