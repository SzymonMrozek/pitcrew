# worktree-simulator: architecture notes

## The problem

Several worktrees of one iOS app, each with its own agent, all building and
testing at once. With a shared simulator:

- one worktree's install replaces another's app mid-test
- Keychain items, user defaults and app containers leak between branches
- "booted simulator" targets whichever device happens to be booted

## The shape of the solution

One CoreSimulator device per worktree, created when the worktree is created
and deleted when it's removed. The worktree keeps a small record of its device.
Everything that builds, tests, runs or opens the app reads the UDID from that
record.

## Invariants

1. **Target by UDID, never by name or "booted".** Names can repeat, and
   "booted" is whatever another worktree last started.
2. **The record is data, not a script.** It's written shell-quoted so hooks can
   source it, but tools parse it, and `delete` refuses a value that isn't a UDID.
   A worktree's files come from the branch, which an agent may have edited.
3. **Creation is idempotent.** A rerun hook reuses the recorded device, or an
   available device with the same name, instead of piling up duplicates.
4. **Deletion is idempotent and exact.** Only the recorded device is touched. A
   device that's already gone counts as deleted. A failed delete keeps the
   record, so a retry can finish the job.
5. **Explicit requests fail loudly.** A pinned runtime or device type that
   isn't installed stops creation. A silent fallback would change snapshot
   output without anyone noticing.

## Incidental choices

- **Python.** It's preinstalled with Xcode's command line tools and parses
  `simctl --json` output reliably. A shell script would need `jq` or embedded
  Python anyway.
- **Worktrunk hooks.** Any create and remove lifecycle works: plain
  `git worktree` wrappers, a Makefile, an agent harness.
- **The env-file format.** Anything both shells and your other tools can read
  works.

## Pitfalls

- **"The first iPhone" is usually a Pro.** simctl lists device types newest
  first, starting with the Pro models, and nothing guarantees that order. Pick
  by name and model number instead.
- **The Xcode GUI has its own run destination.** Xcode stores the selected
  destination in the workspace's per-user `UserInterfaceState.xcuserstate`,
  not in anything the CLI reads. Decide deliberately whether people running from
  Xcode get the worktree device or a shared one.
- **Inherited environment beats metadata in surprising ways.** A shell that
  exported another worktree's UDID will happily target it. Read the record from
  the worktree you're in.
- **Deleting a booted device fails.** Shut it down first. Shutting down a
  device that's already shut down is also an error, so check its state first.
