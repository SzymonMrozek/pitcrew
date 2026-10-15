# worktree-simulator

Gives every git worktree its own iOS Simulator device, and removes it with the
worktree.

Builds, tests and agents in one worktree then never share app data, Keychain
state, user defaults or installed builds with another worktree. One script,
Python standard library only, run from
[Worktrunk](https://github.com/max-sixty/worktrunk) hooks or any other worktree
lifecycle.

```bash
python3 worktree_simulator.py create --name "MyApp feature-x"   # prints the UDID
python3 worktree_simulator.py show                              # prints the recorded UDID
python3 worktree_simulator.py delete                            # shuts down, deletes, forgets
```

`create` records the device in `.worktree-simulator/simulator.env`, relative to
the current directory:

```sh
WORKTREE_SIMULATOR_UDID=063F4A18-E330-4371-910E-D104A89F189B
WORKTREE_SIMULATOR_NAME='MyApp feature-x'
```

Values are shell-quoted, so hooks can `source` the file, and other tools can
read it without running it. [local-review](../local-review)'s **Open Simulator**
reads it.

## Choosing the device

`create` reuses the recorded device or an available device with the same
name. Otherwise it creates one:

| Option | Environment | Default |
| --- | --- | --- |
| `--runtime` | `<PREFIX>_RUNTIME` | The newest available iOS runtime |
| `--device-type` | `<PREFIX>_DEVICE_TYPE` | The newest plain numbered iPhone the runtime supports, such as iPhone 17 rather than 17 Pro or 16e |

An explicit runtime or device type that isn't installed is an error, not a
silent fallback. Pin both when snapshot tests depend on the device.

`--metadata` and `--env-prefix` (default `WORKTREE_SIMULATOR`) change where the
record goes and what its variables are called. Pass the same values to `delete`
and `show`.

## With Worktrunk

[examples/wt.toml](examples/wt.toml) shows the hooks:

```toml
pre-start = "python3 tools/pitcrew/worktree-simulator/worktree_simulator.py create --name 'MyApp {{ branch | sanitize_hash }}'"
pre-remove = "python3 tools/pitcrew/worktree-simulator/worktree_simulator.py delete"
```

`sanitize_hash` keeps names unique when two branches sanitize to the same
text. Add `.worktree-simulator/` to `.gitignore`.

## Building and running on the worktree's device

Point CLI builds and tests at the UDID, never at a device name:

```bash
udid=$(python3 tools/pitcrew/worktree-simulator/worktree_simulator.py show)
xcodebuild test -scheme MyApp -destination "id=$udid"
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl install "$udid" path/to/MyApp.app
xcrun simctl launch "$udid" com.example.myapp
```

[examples/mise.local.toml.sh](examples/mise.local.toml.sh) writes the UDID into
a worktree-local `mise.local.toml`, so every task in that worktree targets it.

## Tests

```bash
python3 tests/test_worktree_simulator.py
```

A fake `xcrun` stands in for CoreSimulator, so the tests run anywhere.

Read [ARCHITECTURE.md](ARCHITECTURE.md) before building your own.
