# Simulator Session Broker

A local HTTP service that gives every iOS Simulator on your machine the same
OAuth session and device ID, and lets only one of them refresh tokens at a time.
Log in once, and every simulator (one per worktree, one per agent) is logged in.

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
| `GET` | `/health` | `200` when ready. |
| `GET` | `/device-id` | Persistent machine-level device ID (`{"deviceId": "..."}`). |
| `GET` | `/session` | Canonical session. Waits while a refresh is in progress; `404` when logged out. |
| `POST` | `/refresh/start` | Claims refresh ownership, or waits for the current owner. Returns `{"shouldRefresh": bool}`. |
| `PUT` | `/session` | Stores a session after login, or conditionally completes an owned refresh. |
| `DELETE` | `/session` | Logs out globally, or conditionally removes the session after a failed owned refresh. |

Session shape:

```json
{ "accessToken": "...", "refreshToken": "...", "expiresAt": "2030-01-01T00:00:00Z" }
```

Every mutating or refresh request must carry a per-process UUID in the client
ID header (default `X-Session-Client-ID`).

### Refresh protocol

1. A client sees an expired access token and calls `POST /refresh/start` with
   `{"replacingAccessToken": "<the token it holds>"}`.
2. If `shouldRefresh` is `true`, the client owns the refresh. It calls your
   OAuth server, then sends `PUT /session` with the new session and the same
   `replacingAccessToken`. If the refresh fails, it sends `DELETE /session` with
   the same `replacingAccessToken` instead.
3. If `shouldRefresh` is `false`, another process already refreshed, so the
   client calls `GET /session` to read the new session.

Ownership expires after 45 seconds. If an owner crashes, exactly one waiter
takes over. A stale owner's conditional `PUT` or `DELETE` gets `409` and cannot
overwrite a newer session. Leaving out `replacingAccessToken` makes the
operation unconditional, which is what login and logout use.

## Configuration

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `SESSION_FILE` | `/data/session.json` | Session location. `device-id` is stored next to it. |
| `SESSION_BROKER_CLIENT_ID_HEADER` | `X-Session-Client-ID` | Header name that identifies a client process. |
| `SESSION_BROKER_REFRESH_TIMEOUT` | `45` | Refresh ownership lifetime in seconds. |

Run exactly **one** Uvicorn worker. Refresh coordination is held in memory.

## Use it in your project

- [`examples/consumer`](examples/consumer): an app repository only needs a
  `compose.yaml` that builds the broker from a pinned pitcrew tag.
- [`examples/swift`](examples/swift): `SessionStore`, a single type that uses
  the Keychain on devices and the broker in simulators, with the same call sites
  for login, logout and token refresh.
- [`examples/ios-app`](examples/ios-app): a runnable SwiftUI app built on it.

## Failure modes

- **Invalid persisted JSON or device ID:** the server refuses to start rather
  than silently replace the data. Fix or remove the volume on purpose.
- **Broker restart:** the session is kept, but refresh ownership is not. Clients
  just get a new ownership window.
- **Port `8765` busy:** remap the host port in `compose.yaml` and point your
  client at it.

## License

See [LICENSE](../LICENSE).
