# local-review: architecture notes

Why the review tool works the way it does. Read this before building your own.

## The problem

When coding agents write most of the code, review becomes the bottleneck, and
merging becomes a coordination problem:

- **Hosted pull requests are slow for local work.** Each agent works in its own
  worktree, often with uncommitted changes. Pushing every iteration to a
  review site adds latency and noise.
- **Reviewers can't tell what changed in the last turn.** An agent's branch
  mixes many user requests. "What did it do since I last looked?" has no answer
  in a plain diff.
- **Merging is real work.** Someone has to rebase, address comments, rerun
  validation and write the commit message. That person should be the agent that
  wrote the change, not the reviewer.
- **Parallel merges collide.** Several approved branches rebasing and running
  tests at once waste compute, and each one invalidates the others.

## The shape of the solution

One local server per repository renders reviews for every worktree. Approval
is a durable record, not an action: it hands the merge back to the
originating agent. A single repository-wide queue serializes merges.

| State | Where it lives | Why there |
| --- | --- | --- |
| Reviews, comments, approvals, logs, settings | `<git-common-dir>/<name>/` | Shared by all worktrees, survives worktree removal, never committed |
| Interaction snapshots | Git trees under `refs/<name>/…` | Immutable, cheap, readable after the worktree is gone |
| Pending approval snapshots | Private commits under `refs/<name>/queue/…` | Other agents can diff or merge them |
| Server port and token | `shared-server.json` | Links posted in chats keep working across restarts |
| Demo recordings | `<git-common-dir>/<name>/demos/<review>/` | Large binaries stay out of the diff, the approval and Git objects, and outlive the worktree |
| Last **Run** status and output | `<git-common-dir>/<name>/runs/` | Survives a server restart, so the page can still explain what happened |

## Invariants

Keep these, whatever your stack.

1. **Approval is bound to the reviewed content, not to commits.** The
   approval revision hashes each file's path, before/after bytes and mode.
   Another worktree advancing the target, or committing the same content, keeps
   the approval valid. A content change the reviewer didn't see invalidates it.
2. **Execution re-freezes content at every step.** Configured preparation runs
   before freezing content and expensive validation. Content is checked after
   the merge checks run, after staging and after committing. Any drift stops
   the attempt. Files can change while a long validation runs.
3. **A withdrawn approval never merges.** Every attempt rereads the request
   status under a lock before touching the index.
4. **The queue lock is held from preparation through cleanup.** It isn't just
   held around the merge. Rebasing and testing against a target that's about to
   move is wasted work. Waiting holds no agent and runs nothing.
5. **The worker belongs to the conversation that wrote the change.** The
   provider, session and CLI path are recorded when the agent starts the review
   or an iteration. The approval freezes that choice. The tool never falls back
   to whichever CLI happens to be installed.
6. **Snapshots never touch the user's index or `HEAD`.** They're written with a
   private `GIT_INDEX_FILE`, so recording history is invisible to the branch.
7. **Interaction boundaries are recorded, never inferred.** Git can't
   reconstruct where one user request ended. Without a recorded baseline, the
   tool disables the thread scope rather than guessing.
8. **A review identity never changes meaning.** Links carry
   `?review=<identity>`, derived from the worktree path, branch, target and the
   worktree's creation time. Opening another worktree, or recreating one with the
   same name, never changes what an existing link shows.
9. **Nothing opens a browser.** Not the tool, and not the agents. The person
   opens review pages.
10. **Failure returns the same approval to pending.** Retries don't create new
    approvals, new iterations or new queue positions.

The recorded CLI follows the actual ancestor agent binary (or an explicit
`CODEX_CLI_PATH`), since a desktop app and `PATH` can contain different Codex
versions. A stopped approval resumed by its same originating conversation may
refresh that CLI path; it never changes providers or conversations. Delivery
probes queue capabilities instead of guessing from a version number, and never
falls back to `exec resume` for an open desktop conversation.

## Incidental choices

Replace these freely:

- **Python standard library and plain browser JavaScript.** These are about not
  having a build step, not about the languages.
- **Worktrunk for merging.** The default merge command is
  `wt merge --no-commit --no-rebase`, so the repository's merge hooks (lint,
  affected tests, cleanup) run in one place. Any command that merges a prepared,
  committed branch works.
- **Jev for ranking.** Any evaluator that returns a 0–1 likelihood per question
  fits. The path-based fallback is always there.
- **Swift and Elixir for code navigation.** Definitions and callers come from
  `git grep` and regular expressions, one provider per language on each side:
  `NAVIGATION` in `server.py` indexes declarations and finds calls, and
  `NAVIGATION` in `definitions.mjs` picks which highlighted tokens link. Another
  language needs a grammar in `highlight.mjs` and both providers. Elixir finds
  the module around a line from indentation, which `mix format` guarantees.
- **Codex and Claude.** Supporting another agent means detecting its session,
  delivering the prompt to its originating conversation.

## Pitfalls

Each of these cost real debugging time.

- **Merging removes the code that's running.** The worktree that runs the server
  can be the one being merged. The server keeps its web assets in memory, and it
  copies `server.py` and `agent.py` to a versioned runtime directory in the Git
  common dir before it launches workers.
- **A shell timeout can kill a merge halfway through validation.** The execution
  CLI launches a separate session with file-backed output and no inherited stdin.
  It records the worker PID before returning; repeated launches reuse a live
  worker. An exited PID returns the approval to pending. Agents poll the saved
  request until completion instead of owning the merge's process lifetime.
- **Agents launched by agents inherit session markers.** A Claude session
  started from Codex has both `CLAUDECODE` and `CODEX_THREAD_ID` set. The nearest
  agent process in the ancestry decides which one is calling. Workers clear every
  inherited marker and set `<NAME>_HANDOFF`, so a worker can't overwrite the
  original conversation.
- **Focus isn't attention.** A merge agent's background Chrome tab reported
  focus and counted a whole merge as review time. Time now needs real input in
  the last two minutes, and it stops once a merge is requested.
- **Recreated worktrees inherited merged reviews.** A worktree recreated with
  the name of a merged branch got the old review's status and comments. The
  identity now includes when the linked worktree was created, which comes from
  the `commondir` file's mtime. Only interactions that finished or began after
  that time carry over, so another agent's unfinished interaction in the old
  worktree can't block the new worktree's first `--begin-iteration`.
- **Resuming a running headless Claude session interrupts it.** The resume
  controls stay disabled until the worker exits. **Send to agent** resumes the
  originating conversation itself, so it waits until no interaction is pending
  and no previous review is still being handled.
- **A desktop Codex chat already has a persistence writer.** Starting
  `codex exec resume` from another process conflicts with that writer even
  between turns. Send review feedback with `codex queue` instead. Successful
  queueing confirms delivery, not completion; the reply stays in the original
  chat. Failed deliveries make their comments retryable.
- **Tool upgrades must not break posted links.** A changed tool restarts an
  idle server on the same port and token. A merge in progress finishes on the old
  server first. The health endpoint reports the content version and the
  numeric `RELEASE`. A launcher whose release is older than the running
  server's reuses it instead of downgrading it, so a stale worktree can't
  replace a newer tool. Same-release launchers with different content still
  restart it, which keeps unreleased edits testable. Bump `RELEASE` with every
  `local-review-v*` tag. Launchers released before 0.7.0 don't compare
  releases and still replace a newer server.
- **One build reads every worktree's configuration.** The shared server and
  the merge workers it launches run one build for all worktrees, which can be
  older than a worktree's checkout: a same-release edit or a launcher released
  before 0.7.0 restarts it. Unknown settings fail only when the tool reads the
  repository it's checked out in, where they're typos; any other build skips
  them with a warning.
- **Git LFS pointers aren't images.** Compare the LFS objects when they're
  present locally. Report missing ones; never fetch them.
- **A simulator recording is only a movie once it's interrupted.**
  `simctl io recordVideo` writes the movie header when it receives SIGINT; a
  killed recorder leaves a file QuickTime can't open. The recorder runs in its
  own session so it outlives the agent's command, its PID is checked against
  its command line before it's signalled, and a demo is kept only after its
  movie header parses.
- **Video elements can't send headers.** The API token travels in a header,
  so a `<video>` can't use it. Demo URLs carry an HMAC of the review and demo
  IDs, keyed by the token; the token itself never enters a URL. The movie
  endpoint must answer byte ranges: Safari won't play a video without them,
  and no browser can seek.
- **A run outlives the server that started it.** A build runs in its own process
  group, so a restarted server can't learn its exit status. The page reports
  it as ended with an unknown result instead of guessing.
- **The browser can't tell a script-driven scroll from a real one.**
  Programmatic scrolling and zero-distance pointer events don't count as input.

- **Queued delivery is not a completed merge.** Merge requests use the same
  original-conversation delivery as comments. A separate delivery process holds
  the repository queue reservation until the approval finishes or is withdrawn.
  Only that saved conversation may reuse its reservation for execution; legacy
  workers still pass their reservation through the worker PID environment.
