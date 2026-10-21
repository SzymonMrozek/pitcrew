# build-distro

Self-hosted ad hoc build distribution for iOS: CI uploads an IPA, testers
open a link on their iPhone and tap Install. Like Firebase App Distribution
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
- **dSYMs stored with each build**, for download.
- **Access by invite.** One link per tester plus a project passcode; revoking
  a link takes effect immediately.

Read [ARCHITECTURE.md](ARCHITECTURE.md) for why it works this way.

## Uploading from GitHub Actions

```yaml
permissions:
  contents: read
  statuses: write        # the commit status
  pull-requests: write   # the PR comment

# ...

- uses: SzymonMrozek/pitcrew/build-distro@build-distro-v0.1.0
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
   git clone --branch build-distro-v0.1.0 https://github.com/SzymonMrozek/pitcrew.git
   cd pitcrew/build-distro
   cp examples/env.example .env   # then fill it in
   docker compose up --detach --build --wait
   ```

5. **Project.** Sign in at `/admin` with `ADMIN_PASSWORD`, create a project and
   save its API key as the `BUILD_DISTRO_API_KEY` secret of your repository.
   Setting the GitHub repository only adds commit and PR links to build pages.
6. **Testers.** Create one invite per tester and send it with the passcode.
   Invites open the project in the browser they're accepted in; testers open
   them in Safari on their iPhone.

To update, check out a newer tag and run `docker compose up --detach --build`.
Open pages reconnect by themselves.

Builds older than `RETENTION_DAYS` (default 30) lose their files; the newest
ready build of each branch is always kept, and `/<project>/latest?branch=main`
always points at it.

## Development

```bash
cd server
docker compose -f test/s3/compose.yaml up -d --wait   # S3 on 127.0.0.1:8333
mix setup
mix test
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
