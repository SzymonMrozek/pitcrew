# Agent instructions for local-review

Copy these sections into your repository's `AGENTS.md` (Claude Code reads it
through `@AGENTS.md` in `CLAUDE.md`). Replace `review` with your launcher, for
example `python3 tools/pitcrew/local-review/server.py` or `mise run review --`.

## Before starting a task

Run `review --queue`. It lists approved merges that haven't landed yet, with
their changed paths and private Git snapshots. Start unrelated work from the
current target. If a pending change affects your component, interfaces or
callers, inspect its snapshot and bring the relevant changes into your own
worktree. Never edit the worktree that's being merged. Wait for those
dependencies to land before approving your own full diff, so it contains only
your task.

## Code review

When the user starts a review, run `review` from the worktree being reviewed
and give the user the printed URL. Never open review or queue pages yourself,
in any browser or through computer use. The user opens them. Read approvals,
comments and merge status through the review CLI.

The user's **Ask agent to merge** confirmation delegates completing the local
merge to you. Inspect the request with `review --merge-request <id>`, then
execute it with `review --execute-merge-request <id>` after validation.
Approval covers necessary code corrections, failing checks, rebasing and
conflict resolution for the existing task. Handle these yourself and retry the
same request until it merges. Don't ask for fresh approval for routine
completion work, and don't require the user to resolve comment flags. Preserve
unrelated edits, keep validation intact, and never merge a withdrawn approval.

Approval workers reserve the repository queue before preparation and hold
their turn through cleanup. Don't prepare or validate a later merge while
another merge owns the queue. Let `--execute-merge-request` run the configured
merge checks and Worktrunk hooks; don't repeat them immediately beforehand on
unchanged content. Resume a stopped worker with
`review --resume-merge-request <id>` from its existing worktree.

## Demo recordings

When a change affects what people see or do in the app, attach demo
recordings that show it working, before finishing the interaction. Record one
demo per scenario and cover every pragmatically reasonable one: the main flow,
plus the states and edge cases the change touches, such as empty, loading,
error, long content or a permission prompt. Launch the app on the worktree's
simulator, then:

```bash
review --record-demo "<scenario, e.g. Reorder from order history>"
# drive the app through the scenario
review --stop-demo
```

Recordings switch the simulator to dark appearance and restore it afterwards;
add `--appearance light` when a scenario needs the light appearance. Start each
recording on a stable screen, then pause briefly at the end so the result is
visible. If later changes alter what a demo shows, record it again
and delete the outdated one with `review --remove-demo <id>`. When files on the
configured UI paths change without any visible effect, run
`review --skip-demo "<reason>"` instead. List the recorded scenarios in your
reply.

## Agent review

Before finishing an interaction that changed files, have a fresh reviewer
agent review it:

```bash
review --agent-review
```

It runs a different agent in a new, read-only session with the repository's
`REVIEW.md`, waits for it and prints its findings as JSON. Each finding is
also a comment on the review. If it prints that the reviewer is still running,
run the same command again to keep waiting. Fix every important finding, then
answer every finding:

```bash
review --reply-comment <id> --reply "<what changed>" --resolve
review --reply-comment <id> --reply "<why it stays as it is>"
```

Run `review --agent-review` again after substantial fixes. Mention findings
you disagreed with in your reply. `--finish-iteration` refuses to finish while
a review is running or a finding has no answer, and, when the repository has a
`REVIEW.md`, when the interaction changed files without a finished review. If
no reviewer can run, for example both CLIs are over quota, record why with
`review --skip-agent-review "<reason>"` and tell the user.

## Review links and interaction history

For every user interaction that involves repository work, record one review
iteration. Before changing files, run:

```bash
review --begin-iteration <id> --request "<brief summary of this user request>"
```

Choose an ID that's unique to this interaction, and keep it through retries,
testing and subagent work. Those internal steps never create iterations.

Before replying, write a complete description of the final branch change and
its validation to a file, then run:

```bash
review --finish-iteration <id> --summary "<result of this interaction>" \
  --title "feat(scope): describe the final change" \
  --description-file /absolute/path/to/description.txt \
  --summary-file /absolute/path/to/summary.json
```

The summary file is the review's **Summary** tab: a JSON change summary of the
whole branch, in the format the local-review README describes. The reviewer
reads it before any code, so write it for a glance:

- The headline says what the branch does for its user, in one line.
- One change per card: what changed and, if it isn't obvious, why. Name the
  types, functions and modules in `backticks`. No adjectives, no "improved",
  no restating the request, no validation details.
- `focus` lists what a reviewer must check: risky assumptions, behavior you
  chose without being asked, untested paths. Leave it out when nothing qualifies.
- Add `design` only when the structure matters, for example new types or
  changed collaborations: the significant types and how they call each other,
  marked added, changed or removed, plus the unchanged ones they connect to.
  Skip it for a change that stays inside one type.

Include both printed URLs as **Full review** and **This iteration** links in
your reply. When the full diff includes imported queued changes or work from
another chat, also link **This thread**: add `&iteration=thread` before the
URL fragment.

The title and description describe the final implementation across all
interactions, because they become the merged commit. Update them when the scope
changes, and leave out internal history and abandoned approaches.

## Review tool feedback

The person leaves notes about the review tool itself from its comment mode.
When asked to analyse them, run `review --feedback <N>` for the latest N open
notes. Each one carries the tab, component path, selector, text, file and view
it was written on. Group them by component, find the code from the selector,
and mark what you ship with `review --implement-feedback <id>`. A note marked
`About: content` asks to change what was said, so its fix belongs where that
content is written, such as your summary instructions, not in the page's code.
