#!/usr/bin/env bash
# Arguments are name:result[:relevant] triples from a CI aggregator job.
# result is the needs.<job>.result; relevant is true/false/always (default always).
# Full CI (code changed, not record-only) requires success for relevant jobs.
# Docs-only, record-only, and jobs whose surface did not change accept skipped.
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
    rest="${item#*:}"
    result="${rest%%:*}"
    relevant="${rest#*:}"
    if [ "$relevant" = "$rest" ]; then
        relevant=always
    fi
    case "$result" in
        success)
            echo "✅ $name success"
            ;;
        skipped)
            if [ "$strict" -eq 1 ] && [ "$relevant" != "false" ]; then
                echo "❌ $name skipped while full CI required it"
                fail=1
            elif [ "$relevant" = "false" ]; then
                echo "✅ $name skipped (surface not affected)"
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
