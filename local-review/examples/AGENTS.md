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
  --description-file /absolute/path/to/description.txt
```

Include both printed URLs as **Full review** and **This iteration** links in
your reply. When the full diff includes imported queued changes or work from
another chat, also link **This thread**: add `&iteration=thread` before the
URL fragment.

The title and description describe the final implementation across all
interactions, because they become the merged commit. Update them when the scope
changes, and leave out internal history and abandoned approaches.
