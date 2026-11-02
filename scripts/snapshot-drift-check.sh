#!/usr/bin/env bash
# Reports snapshot mismatches introduced by the working tree, ignoring known local drift.
# Runs SnapshotTests on a clean HEAD worktree and on the current tree, then prints only the
# snapshot names that fail here and pass on HEAD. Empty output means "only existing drift".
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/snapshot-drift.XXXXXX")"
cleanup() {
    git worktree remove --force "$TMP" >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

git worktree add --detach "$TMP" HEAD >/dev/null

failures() {
    ( cd "$1" && swift test --filter SnapshotTests 2>&1 || true ) \
        | grep -oE 'Snapshot "[^"]+" does not match reference' \
        | sed -E 's/^Snapshot "(.*)" does not match reference$/\1/' \
        | sort -u
}

BASELINE="$(failures "$TMP")"
CURRENT="$(failures "$ROOT")"

BASE_COUNT=$(printf '%s' "$BASELINE" | grep -c . || true)
CURR_COUNT=$(printf '%s' "$CURRENT" | grep -c . || true)
echo "HEAD (clean):   $BASE_COUNT mismatching snapshot(s)" >&2
echo "working tree:   $CURR_COUNT mismatching snapshot(s)" >&2

NEW="$(comm -13 <(printf '%s\n' "$BASELINE") <(printf '%s\n' "$CURRENT") | sed '/^$/d' || true)"
if [ -z "$NEW" ]; then
    echo "No new snapshot mismatches beyond existing drift." >&2
else
    echo "New mismatches introduced by this tree:" >&2
    printf '%s\n' "$NEW"
fi
