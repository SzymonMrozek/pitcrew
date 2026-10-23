# build-distro: architecture notes

Why build-distro works the way it does. Read this before building your own.

## The problem

Ad hoc iOS builds need a place where testers tap a link and install. Hosted
services (Runway, App Center, Firebase App Distribution, Diawi) either cost
money for the part you need, are gone, or keep your builds on someone else's
servers. The obvious self-hosted version, a web server that accepts an IPA
upload and serves an `itms-services://` link, breaks in the ways that matter:

- **Uploads die with the server.** A redeploy, an OOM or a dropped CI
  connection in the middle of a 200 MB request throws the whole upload away.
- **Pages go stale.** A tester opens the link from a PR while CI is still
  uploading, sees "not found" or a spinner that never moves, and has to keep
  refreshing.
- **Installs fail without a reason.** iOS downloads the manifest and the IPA
  itself, without the browser's cookies, so anything behind a login page
  silently fails to install.

## The shape of the solution

| Part | Role |
| --- | --- |
| Phoenix server (`server/`) | API for CI, LiveView pages for testers, background jobs |
| SQLite (WAL) | The only source of truth for projects, builds, invites and upload progress |
| S3-compatible bucket (R2) | IPA, dSYM and icon bytes. The server never streams them |
| Oban (SQLite engine) | Durable jobs: processing, reconciling, retention |
| Litestream | Streams the SQLite WAL to the same bucket, restores it on boot |
| Swift CLI (`cli/`) | Uploads from CI in parallel parts, resumes, waits for the result, reports to GitHub |
| Cloudflare Tunnel | Public HTTPS without open ports |

The upload, step by step:

1. CI calls `POST /api/v1/builds` with an idempotency key, the git context and
   the size of each artifact. The server creates the build and one S3
   multipart upload per artifact, and answers with the part size.
2. CI asks for presigned part URLs in batches. The answer also lists the parts
   the bucket already has, read with `ListParts`, so a restarted CI job skips
   them.
3. CI uploads parts straight to the bucket, several at a time, and reports
   each finished part. Reports only drive the progress bar.
4. CI calls `POST /api/v1/builds/:id/complete`. The server checks the parts
   against the bucket, completes the multipart uploads and enqueues
   processing.
5. Processing reads only the end of the IPA (the zip central directory), then
   `Info.plist`, `embedded.mobileprovision` and the app icon, with ranged
   GETs. The build becomes `ready`.
6. CI waits for `ready`, then sets the commit status and creates or edits one
   PR comment, with the job's own `GITHUB_TOKEN`.

Right after the build starts, CI also asks GitHub's compare API what the build
adds and sends the commits to `PUT /api/v1/builds/:id/changelog`. The start
response tells it the build's bucket and, for main, the commit of the previous
ready main build.

## Invariants

These are the properties that make it work. If you build your own, keep them,
whatever your stack.

1. **The server never carries artifact bytes.** CI writes to the bucket and
   iOS reads from it with presigned URLs. A server restart can't break a
   transfer, and the server's size and speed don't limit one.
2. **The bucket is the truth about bytes, the database is the truth about
   state.** Resume and completion read `ListParts` and `HeadObject`. Progress
   reports from CI are never trusted for correctness.
3. **Every API call is idempotent.** Creating a build with a known key returns
   the existing build. Completing a completed build returns it. Completing a
   multipart upload that is already gone checks `HeadObject` instead of
   failing. CI can retry any call blindly.
4. **State only moves forward:** `uploading → processing → ready`, or `failed`
   from any of them. A retry with the same idempotency key is the only way back
   from `failed` to `uploading`, and it starts new multipart uploads.
5. **Subscribe before you read.** A LiveView subscribes to PubSub and only then
   loads from the database. The other order loses an update that lands in
   between.
6. **A reconnecting page rebuilds from the database.** LiveView remounts on
   every reconnect, so pages never depend on having seen every broadcast.
   Broadcasts are a hint that something changed, not the data.
7. **Jobs are durable and unique per build.** Processing is an Oban job unique
   on the build ID. On boot and every few minutes a reconciler re-enqueues
   builds stuck in `processing` (the unique constraint makes that a no-op when
   the job exists) and fails uploads that stopped moving.
8. **Install links carry their own authorization.** iOS fetches the manifest
   and IPA without cookies. The manifest URL carries a signed, expiring token,
   and the manifest points at a presigned IPA URL created when it is fetched.
   Pages refresh their tokens long before they expire.
9. **Secrets are never stored in plaintext in the database.** The database is
   replicated to the bucket. API keys and passcodes are stored as hashes. Public links also store
   only hashes; admins can copy a signed version of that hash, authenticated
   with the server's `SECRET_KEY_BASE`. These links last until revoked (or the
   signing secret changes). Original random-token public URLs remain valid.
   Web Push endpoints and subscription keys, which must be recoverable for
   delivery, are encrypted with `SECRET_KEY_BASE`. VAPID private keys stay in
   the environment.
10. **The server holds no repository credentials.** CI reports to GitHub and
   reads changelogs with the job's token, which is scoped to the repository
   and expires with the job. Admin sign-in uses an OAuth App that requests no
   scopes and drops its token after reading the profile. A leaked server can't
   touch your repositories.
11. **Access is decided per request, from the source of truth.** Admins are
   the GitHub logins in `ADMIN_GITHUB_LOGINS`, checked on every request, not
   a flag stored at sign-in. Invites and public links are rows that revocation
   flips. A public link sees exactly one bucket; its pages, icons and install
   links all check that bucket, and it never gets dSYM or IPA downloads.
12. **Changelogs are stored raw and grouped when shown.** Editing a project's
   tooling rules regroups every build, old ones included.
13. **Push follows access and readiness.** Opt-in subscriptions belong to one
   project, bucket and access grant. The ready transition creates durable Oban
   delivery jobs in its database transaction, once per subscribed device.
   Workers recheck grant validity before sending, delete gone endpoints and
   retry transient errors. Network delivery is at least once; a build-specific
   notification tag coalesces duplicates. Public destinations retain a signed
   public token. The root-scoped service worker caches no pages or artifacts.

## Incidental choices

Replace these freely.

- **Elixir and Phoenix LiveView.** Reconnects and remounts are built in, and a
  crash in one upload or page doesn't touch the others. Any stack works if it
  keeps invariants 5 and 6.
- **SQLite with Litestream** instead of Postgres. One file, one process, a
  continuous backup to the bucket you already pay for.
- **Invite links plus a project passcode** for testers, GitHub only for
  admins. Testers such as QA or product people often have no GitHub account.
  An invite alone leaks when forwarded; a passcode alone can't be revoked per
  person.
- **Buckets from the git context**, not configured per build: a PR number
  means Pull requests, the project's main branch means Main, anything else is
  Manual.
- **Cloudflare R2.** Any S3-compatible store works; tests use MinIO.
- **No frontend build step.** LiveView's prebuilt JavaScript and one CSS file
  are served as they are, so a release build needs no Node, esbuild or
  Tailwind download.
- **Reporting to GitHub from CI, not the server.** The price is that GitHub
  only hears about changes while the job runs, so the job waits for `ready`.
  A server with its own token could also report later changes, but it would
  hold a long-lived credential for every repository it serves.
- **A Swift upload client.** Uploads run on macOS runners, where a Swift
  binary links the system's URLSession, TLS and Swift runtime: the universal
  binary is about 220 KB gzipped and starts in about 20 ms. Go or Rust would carry
  their own TLS stack in a binary ten times larger. Keep the protocol, swap
  the language freely.

## Pitfalls

- **R2 custom domains can't serve presigned URLs.** A bucket on your own
  domain is public. Signed downloads must use the S3 endpoint.
- **`&` in the manifest.** Presigned URLs contain `&`, and the manifest is XML.
  Escape it, or iOS reports "Unable to download app" with no other detail.
- **Data descriptors in IPAs.** Local file headers in zips written by Xcode can
  have zero sizes. Take sizes and offsets from the central directory, and read
  the local header only to skip its name and extra fields.
- **Binary property lists.** `Info.plist` inside an IPA is a binary plist; the
  plist in `embedded.mobileprovision` is XML wrapped in a CMS signature.
- **Crushed PNG icons.** Xcode stores icons as Apple's CgBI PNG variant (BGRA,
  raw deflate). Browsers can't show them until they're converted.
- **Multipart part sizes.** Every part except the last must be at least
  5 MiB. The server picks the part size so an artifact never needs more than
  1,000 parts, which is one `ListParts` page, so resume never paginates.
- **S3 servers disagree on gone uploads.** After an abort or a completion, R2
  answers `ListParts` with `NoSuchUpload`; SeaweedFS answers with an empty
  list. Both must lead to "check the object, or start a new upload".
- **An artifact already completed has no multipart upload.** Asking for its
  part URLs must report every part as stored, not start a new upload.
- **Abandoned multipart uploads cost storage silently.** They don't show up as
  objects. Abort them from the reconciler, and add a bucket lifecycle rule as a
  backstop.
- **`github.action_ref` is empty inside composite actions.** The action reads
  its repository and tag from its checkout path instead
  (`_actions/<owner>/<repo>/<ref>/build-distro`).
- **Buffered output in CI.** A piped stdout is block-buffered, so progress
  only appears at the end. The client switches stdout to line buffering.
- **Binding to `::` in Docker.** Containers often have IPv6 disabled, so the
  server binds to `0.0.0.0`.
- **Pull requests from forks get a read-only `GITHUB_TOKEN`.** Reporting
  failures only log a warning, so they never fail an upload (forks don't get
  the upload secret anyway).
- **Passcode guessing.** The passcode form is on the public internet. Attempts
  are rate-limited per client IP, read from `CF-Connecting-IP`, which is
  trustworthy only because the tunnel is the only way in.

## Non-goals

- Symbolication. dSYMs are stored with the build for download; your crash
  reporter symbolicates.
- App Store or TestFlight submission.
- Device registration with Apple. The build page shows how many devices the
  profile includes and when it expires.
