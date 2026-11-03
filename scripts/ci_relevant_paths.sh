#!/usr/bin/env bash
# Read a newline-separated path list on stdin.
# Exit 0 when full CI must run. Exit 1 when every path is documentation-only.
# An empty list exits 0 (run CI) so a failed diff never skips the suite.
set -euo pipefail

relevant=0
saw=0
while IFS= read -r path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    saw=1
    case "$path" in
        # Logo SVGs are byte-compared with the app icon in scripts/check.sh.
        docs/assets/*.svg)
            relevant=1
            ;;
        *.md|docs/*|LICENSE|.github/ISSUE_TEMPLATE/*)
            ;;
        # *.md is already docs-only. This arm covers the other skill files, including scripts and licenses.
        .cursor/skills/*)
            ;;
        *)
            relevant=1
            ;;
    esac
done

if [ "$saw" -eq 0 ] || [ "$relevant" -eq 1 ]; then
    exit 0
fi
exit 1
