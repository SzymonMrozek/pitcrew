# Session store example app

A small SwiftUI app that shows the active storage backend, the session, and the
device ID, with Log in, Refresh and Log out buttons backed by a fake OAuth
server.

```bash
mise install
tuist generate
```

Run it on two simulators: log in on one, then reopen the app on the other and
it's already logged in, with the same device ID. Add `SESSION_STORE=keychain`
to the scheme's environment to see the same app fall back to its own Keychain.

The whole swap is two lines in
[`SessionStoreExampleApp.swift`](Sources/SessionStoreExampleApp.swift).
Everything else in the app talks to `SessionStore` and never asks where the
session lives.

> The app reads `SESSION_BROKER_URL` (default `http://127.0.0.1:8765`). If your
> own app already uses a broker on that port, point the example at a separate
> broker, so its fake logins don't replace your real session.

The hosted tests in `Tests/` cover the Keychain backend and the `.live` swap:

```bash
xcodebuild test -workspace SessionStoreExample.xcworkspace -scheme SessionStoreExample \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```
