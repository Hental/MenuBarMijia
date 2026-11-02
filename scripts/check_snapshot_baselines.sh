#!/usr/bin/env bash
# Fails when UI rendering sources changed without any committed snapshot baseline update.
# Local drift triage answers "were these mismatches already here", never "does this UI change
# owe a new baseline" (#123: the macos job surfaced nine stale baselines after a green local story).
#
# Usage:
#   scripts/check_snapshot_baselines.sh [base] [head]
#   scripts/check_snapshot_baselines.sh --paths <file>
#
# base defaults to origin/main, head to HEAD. --paths reads a newline-separated changed-file list
# instead of asking git, so a CI job can feed an API result.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

SOURCE_PREFIX="Sources/MenuBarMijiaApp/"
BASELINE_PREFIX="Tests/MenuBarMijiaAppTests/__Snapshots__/"
PATHS_FILE=""
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --paths)
            PATHS_FILE="${2:-}"
            shift 2
            ;;
        -h|--help)
            awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
            exit 0
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

if [ -n "$PATHS_FILE" ]; then
    [ -f "$PATHS_FILE" ] || { echo "❌ 找不到改动文件列表：$PATHS_FILE" >&2; exit 1; }
    CHANGED="$(sed '/^[[:space:]]*$/d' "$PATHS_FILE")"
else
    BASE="${POSITIONAL[0]:-origin/main}"
    HEAD_REF="${POSITIONAL[1]:-HEAD}"
    if ! git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null; then
        echo "❌ 无法解析基线 ref：$BASE（先 git fetch origin）" >&2
        exit 1
    fi
    if [ "$HEAD_REF" = "HEAD" ]; then
        # Default mode is the local pre-PR check: compare base against the working tree so
        # uncommitted edits count, and add untracked files because `git diff` omits them.
        CHANGED="$(git diff --name-only "$BASE")
$(git ls-files --others --exclude-standard)"
    else
        CHANGED="$(git diff --name-only "$BASE...$HEAD_REF")"
    fi
fi

SOURCES="$(printf '%s\n' "$CHANGED" | grep -E "^${SOURCE_PREFIX}" || true)"
BASELINES="$(printf '%s\n' "$CHANGED" | grep -E "^${BASELINE_PREFIX}" || true)"

if [ -z "$SOURCES" ]; then
    echo "✅ 未改动面板渲染源码，无需刷新快照基线。"
    exit 0
fi
if [ -n "$BASELINES" ]; then
    echo "✅ 面板渲染源码与快照基线一并更新。"
    exit 0
fi

cat >&2 <<'MSG'
❌ 改了面板渲染源码，却没有更新 UI 快照基线。

改动到的渲染文件：
MSG
printf '%s\n' "$SOURCES" | sed 's/^/  - /' >&2
cat >&2 <<'MSG'

本地既有漂移不代表基线仍然有效：scripts/snapshot-drift-check.sh 只回答“这些失配是不是早就存在”，
回答不了“这次 UI 改动是否欠一批新基线”。重录流程：
  1. gh workflow run ci.yml --ref <branch>
  2. gh run download <run-id> -n snapshot-baselines -D /tmp/snap
  3. 只把本次改动涉及的 PNG 拷进 Tests/MenuBarMijiaAppTests/__Snapshots__/SnapshotTests/ 并提交
确实不影响渲染时，给 PR 加 no-snapshot-change 标签跳过本检查。
MSG
exit 1
