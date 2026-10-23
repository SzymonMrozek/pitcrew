# build-distro

Self-hosted build distribution for iOS, ad hoc and in-house: CI uploads an
IPA, testers open a link on their iPhone and tap Install. Like Firebase App Distribution
or Runway's build distro, on a server you own, for the price of a small VM
and an S3 bucket.

- **Uploads that survive anything.** CI sends parts straight to the bucket,
  in parallel, and resumes after a dropped connection, a CI retry or a server
  restart. The server never carries the bytes.
- **Pages that never need a refresh.** A link shared while CI is still
  uploading shows live progress and turns into an Install button by itself.
  Pages reconnect and catch up after a redeploy.
- **Recovery built in.** The database streams to the same bucket with
  Litestream; a new VM restores it on first boot.
- **GitHub without any stored token.** The upload step sets a commit status
  and keeps one PR comment up to date, using the job's own short-lived token.
  The server never talks to GitHub.
- **Main, Pull requests and Manual.** Builds are listed by where they came
  from: the main branch, a pull request (one row per PR), or any other branch.
- **Changelogs that mean something.** A pull request lists what it adds to
  main; a main build lists every commit since the previous main build.
  Conventional Commits marked as tooling (types like `chore` or `refactor`,
  scopes like `tooling`) go last, folded away. The rules are per project.
- **Ad hoc and in-house signing.** In-house builds say they install on any
  device and how to trust the team; ad hoc builds show the profile's devices.
- **dSYMs stored with each build**, for download.
- **Three ways in.** Admins sign in with GitHub. Testers get one invite link
  each plus a project passcode. A public link shows one bucket to anyone who
  has it. Revoking any of them takes effect immediately.
- **Opt-in new-build notifications.** Add a bucket to your Home Screen and
  enable Web Push. A notification opens the build as soon as it is ready.

Read [ARCHITECTURE.md](ARCHITECTURE.md) for why it works this way.

## Uploading from GitHub Actions

```yaml
permissions:
  contents: read
  statuses: write        # the commit status
  pull-requests: write   # the PR comment

# ...

- uses: SzymonMrozek/pitcrew/build-distro@build-distro-v0.3.0
  with:
    server: https://builds.example.com
    api-key: ${{ secrets.BUILD_DISTRO_API_KEY }}
    ipa: build/MyApp.ipa
    dsyms: build/MyApp.xcarchive/dSYMs
```

The action downloads the upload client released with its tag (a 220 KB
universal macOS binary), checks its SHA-256 and caches it. It reads the
branch, commit, PR, PR title and run link from GitHub, and waits until the
build is ready. Outputs: `url` and `number`. A full workflow is in
[examples/github-actions.yml](examples/github-actions.yml).

The changelog comes from GitHub's compare API with the same token, which needs
`contents: read`: what a pull request adds to its base branch, what a main
build adds to the previous ready main build, or what another branch adds to
main. Merge commits are left out.

GitHub reporting uses the job's `GITHUB_TOKEN`, which GitHub creates for each
job, limits to the repository and the `permissions` above, and revokes when
the job ends. While uploading, the commit status is pending; once the build is
ready or failed, it links to the build page. On pull requests one comment per
build-distro project is created and then edited by later builds; it's found
again by a hidden marker, so nothing is stored. Missing permissions only log a
warning: the build is distributed either way. Set `github-token: ""` to skip
reporting.

Outside GitHub Actions, run the client yourself:

```bash
BUILD_DISTRO_API_KEY=bd_... build-distro-upload --server https://builds.example.com \
  --ipa MyApp.ipa --dsyms MyApp.xcarchive/dSYMs --branch main --wait
```

`build-distro-upload --help` lists every option. The same `--idempotency-key`
resumes the same build; on GitHub it defaults to the run, attempt and job.

## Running a server

You need a machine that runs Docker, an S3-compatible bucket and a domain. The
setup below costs nothing beyond the domain: an Oracle Cloud Always Free ARM
VM, Cloudflare R2 and a Cloudflare Tunnel.

1. **Bucket.** Create an R2 bucket and an API token with Object Read & Write
   on that bucket only. Add a lifecycle rule that aborts incomplete multipart
   uploads after one day. Don't add a custom domain: those are public, and
   installs use presigned URLs.
2. **Tunnel.** In Cloudflare Zero Trust, create a tunnel and give it a public
   hostname whose service is `http://app:4000`. Keep the tunnel token.
3. **VM.** Any Linux machine with Docker Engine and the Compose plugin. It
   needs no open ports except SSH: the tunnel connects outwards.
4. **Deploy.**

   ```bash
   git clone --branch build-distro-v0.3.0 https://github.com/SzymonMrozek/pitcrew.git
   cd pitcrew/build-distro
   cp examples/env.example .env   # then fill it in
   docker compose up --detach --build --wait
   ```

5. **Admins.** Create a GitHub OAuth App (Settings → Developer settings →
   OAuth Apps) with the callback `https://<your host>/auth/github/callback`.
   It requests no scopes and can't touch repositories. Put its client ID and
   secret in `.env`, with the GitHub logins allowed in as `ADMIN_GITHUB_LOGINS`.
6. **Project.** Sign in at `/admin`, create a project and save its API key as
   the `BUILD_DISTRO_API_KEY` secret of your repository. The GitHub repository
   adds commit, PR and compare links; the main branch decides which builds go
   to Main; the tooling rules decide what goes last in changelogs.
7. **Testers.** Create one invite per tester and send it with the passcode.
   Invites open the project in the browser they're accepted in; testers open
   them in Safari on their iPhone. For people without an invite, create a
   public link for a bucket, such as Main. Use Copy beside Revoke to share an
   existing public link again, including links created before this version.

To update, check out a newer tag and run `docker compose up --detach --build`.
Open pages reconnect by themselves.

Builds older than `RETENTION_DAYS` (default 30) lose their files; the newest
ready build of each branch is always kept, and `/<project>/latest?branch=main`
always points at it.

## New-build notifications

Push is optional. Generate a VAPID keypair once, from `server/`:

```bash
mix web_push.gen.vapid
```

Set `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` and `VAPID_SUBJECT` in the server's
`.env`, then rebuild and restart the app. The subject is an HTTPS contact URL
or `mailto:admin@example.com`. Keep the same keypair across deployments. The
notification controls stay hidden when these settings are absent. Partial or
invalid settings stop startup with an error. No paid push provider or Apple
Developer membership is needed; the browser's push service delivers messages.

On iPhone/iPad (iOS/iPadOS 16.4 or later):

1. Open the bucket you want to follow, using your invite or public link.
2. Choose Share → Add to Home Screen, then open the installed web app.
3. If needed, paste your invite into **Open your invite** on the installed
   app's home page, then enter the passcode; admins can sign in there too.
   Public links keep their access in the app's launch URL.
4. Tap **Notify me about new builds** and allow notifications.

Each bucket opts in separately on each device. **Turn off notifications**
disables only that bucket; other subscriptions on the device keep working.
Supported desktop/Android browsers can subscribe directly. Permission denial
requires changing the browser/device notification setting before trying again.

Notifications are queued in the same transaction that makes a build ready;
uploads, failures, and existing builds do not generate notifications. Jobs
retry temporary delivery errors and remove expired subscriptions. They recheck
the original invite, allowed admin login, or public link before sending.
Revoking access stops future sends; it cannot recall a notification already
accepted by the browser's push service. Public notification taps open the
public build page, without requiring an invite. A repeated delivery of the
same build uses the same notification tag.

The service worker handles notifications only: it does not cache private
pages, public links, or build artifacts. Push endpoints and subscription keys
are encrypted in the database using `SECRET_KEY_BASE`; changing it requires
subscribers to opt in again. Changing the VAPID keypair requires resetting
the browser's push subscription and opting in again. Outbound HTTPS is
restricted to Apple, Google, Mozilla and Microsoft push endpoints; HTTP
redirects are never followed. Allow these push services through any outbound
firewall, including `*.push.apple.com` for Safari.

## Development

```bash
cd server
docker compose -f test/s3/compose.yaml up -d --wait   # S3 on 127.0.0.1:8333
mix setup
mix test
node --test test/*.test.mjs
mix phx.server   # http://localhost:4000, admin password "admin"
```

```bash
cd cli
swift test
```

The tests run against SeaweedFS, which checks presigned signatures the way R2
does.

## License

See [LICENSE](../LICENSE).
