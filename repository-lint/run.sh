#!/bin/bash
set -euo pipefail

PACKAGE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
SCRATCH="${REPOSITORY_LINT_BUILD_DIR:-$ROOT/.build-tools/repository-lint}"
BINARY="$SCRATCH/release/repository-lint"
STAMP="$SCRATCH/inputs"
TOOLCHAIN="${DEVELOPER_DIR:-$(xcode-select -p)}"
COMPILER="$TOOLCHAIN/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
# Hash the file list and contents: deleted rules and older release checkouts invalidate the cache too.
INPUTS="$(
    printf '%s\n' "$TOOLCHAIN"
    stat -f '%m:%z' "$COMPILER"
    find "$PACKAGE/Sources" -type f -print0 | xargs -0 shasum | LC_ALL=C sort
    shasum "$PACKAGE/Package.swift" "$PACKAGE/Package.resolved" "$PACKAGE/run.sh"
)"
needs_build() {
    [[ ! -x "$BINARY" || ! -f "$STAMP" ]] && return 0
    [[ "$(cat "$STAMP")" != "$INPUTS" ]]
}
if needs_build; then
    mkdir -p "$(dirname "$SCRATCH")"
    # Serialize first builds; shlock recovers stale locks left by killed builders.
    while ! /usr/bin/shlock -p $$ -f "$SCRATCH.lock"; do sleep 1; done
    trap 'rm -f "$SCRATCH.lock"' EXIT
    if needs_build; then
        "$COMPILER" build --package-path "$PACKAGE" --scratch-path "$SCRATCH" -c release --product repository-lint >&2
        printf '%s\n' "$INPUTS" > "$STAMP"
    fi
    rm -f "$SCRATCH.lock"
    trap - EXIT
fi
exec "$BINARY" "$@"
