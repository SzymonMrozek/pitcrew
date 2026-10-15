#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# Initialize at the consumer's pinned revision before invoking the tool.
git submodule update --init Tools/pitcrew
exec Tools/pitcrew/repository-lint/run.sh --rules-config .config/repository-lint.json "$@"
