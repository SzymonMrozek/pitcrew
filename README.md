# pitcrew

Tools for developing one iOS app in many places at once: several git worktrees,
several simulators, several coding agents.

| Tool | Problem it solves |
| --- | --- |
| [session-broker](session-broker) | Every simulator needs its own login, and rotating refresh tokens revoke each other. The broker shares one session and one device ID across all simulators. |

## How you use a tool

You don't fork or wrap it. Your repository pins a release tag and configures the
tool, and that's all. Each tool's `examples/` folder shows exactly what to add.

Tags are per tool: `<tool>-vX.Y.Z`, for example `session-broker-v0.1.0`.

## Requirements

- macOS with Xcode for the iOS examples
- Docker (Docker Desktop or Colima) for the session broker

## Status

Each tool here runs every day in a production iOS codebase. APIs can still
change before `1.0`. Pin a tag.

## Contributing

```bash
git config core.hooksPath .githooks
```

The pre-push hook runs [`scripts/check-forbidden-terms.sh`](scripts/check-forbidden-terms.sh)
against your own list of terms in `~/.config/pitcrew/forbidden-terms` (one
regex per line, kept outside the repository), so names from private projects
can't reach a public commit.

## License

[MIT](LICENSE)
