#!/usr/bin/env bash
# Fails when tracked files or commit metadata contain any term from a private list.
# The list stays outside this repository, e.g. ~/.config/pitcrew/forbidden-terms,
# one extended regex per line; blank lines and lines starting with # are ignored.
set -euo pipefail

terms_file="${PITCREW_FORBIDDEN_TERMS:-$HOME/.config/pitcrew/forbidden-terms}"
range="${1:-}"

if [ ! -f "$terms_file" ]; then
  echo "No forbidden-terms list at $terms_file; skipping." >&2
  exit 0
fi

patterns=$(mktemp)
trap 'rm -f "$patterns"' EXIT
grep -vE '^[[:space:]]*(#|$)' "$terms_file" > "$patterns" || true
[ -s "$patterns" ] || exit 0

root=$(git rev-parse --show-toplevel)
status=0

if git -C "$root" grep -n -i -I -E -f "$patterns" >&2; then
  echo "Forbidden terms found in tracked files." >&2
  status=1
fi

if [ -n "$range" ] && git -C "$root" log --format='%H %an <%ae>%n%B' "$range" | grep -n -i -E -f "$patterns" >&2; then
  echo "Forbidden terms found in commits $range." >&2
  status=1
fi

exit "$status"
