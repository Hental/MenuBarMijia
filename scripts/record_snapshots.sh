#!/usr/bin/env bash
# Record the UI snapshot baselines on the CI runner and copy the changed PNGs back.
#
#   scripts/record_snapshots.sh [ref] [--dry-run] [--from <dir>]
#
#   ref        branch to record on (default: current branch; it must be pushed)
#   --from     skip the CI dispatch and diff an already downloaded artifact directory
#   --dry-run  list what would change without touching the baselines
#
# Why CI: the local renderer drifts from the runner for every baseline, so `swift test` on this
# Mac is red regardless of the diff (see PR #120/#121/#122). CI's `snapshot-record` job is the only
# trustworthy source. Baseline PNGs are still reviewed as a normal diff before committing.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ROOT_DIR="$(git rev-parse --show-toplevel)"
SNAPSHOT_DIR="$ROOT_DIR/Tests/MenuBarMijiaAppTests/__Snapshots__/SnapshotTests"
REF=""
FROM=""
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --from) FROM="${2:?--from 需要一个目录}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        -*) echo "❌ 未知参数：$1" >&2; exit 2 ;;
        *) REF="$1"; shift ;;
    esac
done

if [ ! -d "$SNAPSHOT_DIR" ]; then
    echo "❌ 找不到快照目录：$SNAPSHOT_DIR" >&2
    exit 1
fi

download_dir="$FROM"
if [ -z "$download_dir" ]; then
    REF="${REF:-$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)}"
    if [ "$REF" = "HEAD" ]; then
        echo "❌ 当前处于 detached HEAD，请显式传入分支名" >&2
        exit 1
    fi
    if ! git -C "$ROOT_DIR" ls-remote --exit-code --heads origin "$REF" >/dev/null 2>&1; then
        echo "❌ 分支 $REF 还没推到 origin，先 push 再录基线" >&2
        exit 1
    fi
    dirty="$(git -C "$ROOT_DIR" status --porcelain --untracked-files=no)"
    if [ -n "$dirty" ]; then
        echo "❌ 工作树有未提交改动，先提交再录基线；当前改动：" >&2
        printf '%s\n' "$dirty" >&2
        exit 1
    fi

    sha="$(git -C "$ROOT_DIR" rev-parse HEAD)"
    echo "▶ 在 $REF ($(git -C "$ROOT_DIR" rev-parse --short HEAD)) 上派发基线录制…"
    gh workflow run ci.yml --ref "$REF" -f record_only=true >/dev/null

    run_id=""
    for _ in $(seq 1 40); do
        sleep 3
        run_id="$(gh run list --workflow=ci.yml --branch "$REF" --event workflow_dispatch \
            --limit 10 --json databaseId,headSha \
            --jq "map(select(.headSha == \"$sha\")) | .[0].databaseId // empty")"
        [ -n "$run_id" ] && break
    done
    if [ -z "$run_id" ]; then
        echo "❌ 没等到录制任务出现，去 Actions 页面确认" >&2
        exit 1
    fi

    echo "▶ 等待录制任务 $run_id 完成（只跑 snapshot-record）…"
    gh run watch "$run_id" --interval 20 --exit-status >/dev/null || {
        echo "❌ 录制任务失败：https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/actions/runs/$run_id" >&2
        exit 1
    }

    download_dir="$(mktemp -d)"
    gh run download "$run_id" -n snapshot-baselines -D "$download_dir" >/dev/null
fi

if [ ! -d "$download_dir" ]; then
    echo "❌ 找不到 artifact 目录：$download_dir" >&2
    exit 1
fi

changed=0
missing=0
for artifact in "$download_dir"/*.png; do
    [ -e "$artifact" ] || { echo "❌ $download_dir 里没有 PNG" >&2; exit 1; }
    name="$(basename "$artifact")"
    if [ ! -f "$SNAPSHOT_DIR/$name" ]; then
        missing=$((missing + 1))
    fi
    if cmp -s "$artifact" "$SNAPSHOT_DIR/$name"; then
        continue
    fi
    changed=$((changed + 1))
    if [ "$DRY_RUN" = "1" ]; then
        echo "would update: $name"
    else
        cp "$artifact" "$SNAPSHOT_DIR/$name"
        echo "updated: $name"
    fi
done

[ "$missing" -gt 0 ] && echo "⚠️ $missing 张基线在仓库里不存在（新增快照）"
if [ "$changed" -eq 0 ]; then
    echo "✅ 基线无变化（artifact：${download_dir}）"
else
    if [ "$DRY_RUN" = "1" ]; then
        echo "ℹ️ 共 $changed 张会变化（dry run，未写入）"
    else
        echo "✅ 已更新 $changed 张基线，review 后提交；artifact 保留在 $download_dir"
    fi
fi
