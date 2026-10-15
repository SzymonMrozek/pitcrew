# Consuming the broker from your project

Your app repository doesn't need a copy of the broker. Add the
[`compose.yaml`](compose.yaml) from this folder, then change three things in it:

- the project name and the volume name
- the pitcrew tag you pin
- `SESSION_BROKER_CLIENT_ID_HEADER`, if your app already sends a different header

Start the broker idempotently, for example from a worktree-creation hook or a
task runner:

```bash
curl --fail --silent --max-time 1 http://127.0.0.1:8765/health \
  || docker compose up --detach --build --wait session-broker
```

Use one fixed compose project name and volume across all your worktrees. If each
worktree had its own, they would compete for port `8765` and each keep a
separate session, which defeats sharing.

To upgrade, bump the tag and run `docker compose up --detach --build --wait`.
The session and device ID survive because they live in the named volume.
