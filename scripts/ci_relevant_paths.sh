#!/usr/bin/env bash
# Read a newline-separated path list on stdin and print which CI surfaces are affected:
#   code=true     run repository-wide checks (lint, secret scan)
#   macos=true    run macOS tests, App Intents, and the release build
#   windows=true  run Windows frontend tests and the Tauri installer
#   core=true     run the Linux MijiaCore suite
# Unknown paths and empty input fall back to every surface, so a failed diff never skips CI.
set -euo pipefail

code=false
macos=false
windows=false
core=false
saw=0

mark_all() {
    code=true
    macos=true
    windows=true
    core=true
}

while IFS= read -r path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    saw=1
    case "$path" in
        # Logo SVGs are byte-compared with the app icon in scripts/check.sh.
        docs/assets/*.svg)
            code=true
            ;;
        *.md|docs/*|LICENSE|.github/ISSUE_TEMPLATE/*)
            ;;
        # *.md is already docs-only. This arm covers the other skill files, including scripts and licenses.
        .cursor/skills/*)
            ;;
        windows/*)
            code=true
            windows=true
            ;;
        Sources/MijiaCore/*)
            code=true
            macos=true
            core=true
            ;;
        Sources/MenuBarMijiaApp/*)
            code=true
            macos=true
            ;;
        # Shared golden corpora pin both the Swift and TypeScript implementations.
        Tests/Fixtures/*)
            code=true
            macos=true
            windows=true
            core=true
            ;;
        Tests/MijiaCoreTests/*)
            code=true
            macos=true
            core=true
            ;;
        Tests/MenuBarMijiaAppTests/*)
            code=true
            macos=true
            ;;
        Resources/*)
            code=true
            macos=true
            ;;
        scripts/linux-check/*)
            code=true
            core=true
            ;;
        *)
            mark_all
            ;;
    esac
done

if [ "$saw" -eq 0 ]; then
    mark_all
fi

printf 'code=%s\nmacos=%s\nwindows=%s\ncore=%s\n' "$code" "$macos" "$windows" "$core"
