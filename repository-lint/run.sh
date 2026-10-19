#!/bin/bash
set -euo pipefail

PACKAGE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(git rev-parse --show-toplevel)"
COMMON="$(git rev-parse --path-format=absolute --git-common-dir)"
cd "$ROOT"
# Worktrees share the cache through the Git common directory.
CACHE="${REPOSITORY_LINT_CACHE_DIR:-$COMMON/repository-lint}"
SCRATCH="${REPOSITORY_LINT_BUILD_DIR:-$CACHE/build}"
TOOLCHAIN="${DEVELOPER_DIR:-$(xcode-select -p)}"
COMPILER="$TOOLCHAIN/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
# Hash the file list and contents: deleted rules and older release checkouts get their own key.
# Paths are package-relative so every worktree computes the same key.
INPUTS="$(
    cd "$PACKAGE"
    printf '%s\n' "$TOOLCHAIN"
    stat -f '%m:%z' "$COMPILER"
    find Sources -type f -print0 | xargs -0 shasum | LC_ALL=C sort
    shasum Package.swift Package.resolved run.sh
)"
KEY="$(printf '%s\n' "$INPUTS" | shasum | cut -c1-16)"
EXECUTABLES="$CACHE/bin"
RELEASE="$EXECUTABLES/$KEY"
BINARY="$RELEASE/repository-lint"
KEEP=5
if [[ ! -x "$BINARY" ]]; then
    mkdir -p "$EXECUTABLES"
    # Serialize builds; shlock recovers stale locks left by killed builders.
    while ! /usr/bin/shlock -p $$ -f "$CACHE/build.lock"; do sleep 1; done
    trap 'rm -f "$CACHE/build.lock"; rm -rf "$EXECUTABLES/.$KEY.$$"' EXIT
    if [[ ! -x "$BINARY" ]]; then
        "$COMPILER" build --package-path "$PACKAGE" --scratch-path "$SCRATCH" -c release --product repository-lint >&2
        # Publish the executable and its resource bundles with one rename so readers never see a partial copy.
        STAGING="$EXECUTABLES/.$KEY.$$"
        mkdir "$STAGING"
        shopt -s nullglob
        cp -R "$SCRATCH/release/repository-lint" "$SCRATCH/release/"*.bundle "$STAGING/"
        shopt -u nullglob
        printf '%s\n' "$INPUTS" > "$STAGING/inputs"
        rm -rf "$RELEASE"
        mv "$STAGING" "$RELEASE"
        # Keep the most recently used versions; warm runs refresh their directory's mtime.
        ls -t "$EXECUTABLES" | tail -n +$((KEEP + 1)) | while read -r stale; do rm -rf "${EXECUTABLES:?}/$stale"; done
    fi
    rm -f "$CACHE/build.lock"
    trap - EXIT
else
    touch "$RELEASE"
fi
exec "$BINARY" "$@"
