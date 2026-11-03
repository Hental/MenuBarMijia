#!/usr/bin/env bash
# Arguments are name:result pairs from a CI aggregator job.
# Full CI (code changed, not record-only) requires success.
# Docs-only and record-only accept skipped heavy jobs.
set -euo pipefail

if [ "${CHANGES:-}" != "success" ]; then
    echo "❌ changes=${CHANGES:-<unset>}"
    exit 1
fi

strict=0
if [ "${CODE:-}" = "true" ] && [ "${RECORD_ONLY:-}" != "true" ]; then
    strict=1
fi

fail=0
for item in "$@"; do
    name="${item%%:*}"
    result="${item#*:}"
    case "$result" in
        success)
            echo "✅ $name success"
            ;;
        skipped)
            if [ "$strict" -eq 1 ]; then
                echo "❌ $name skipped while full CI was required"
                fail=1
            else
                echo "✅ $name skipped"
            fi
            ;;
        *)
            echo "❌ $name ${result:-<empty>}"
            fail=1
            ;;
    esac
done
exit "$fail"
