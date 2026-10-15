#!/usr/bin/env bash
# Run from a Worktrunk pre-start hook after `worktree_simulator.py create`, so every mise task in
# this worktree builds, tests and runs on its own simulator.
set -euo pipefail

udid="$(python3 tools/pitcrew/worktree-simulator/worktree_simulator.py show)"

cat > mise.local.toml <<EOF
[env]
IOS_SIMULATOR_DESTINATION = "platform=iOS Simulator,id=$udid"
EOF
mise trust --yes mise.local.toml >/dev/null
