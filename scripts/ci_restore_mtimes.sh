#!/usr/bin/env bash
# Stamp each tracked file with the commit time of its last change.
# A git checkout sets every mtime to "now", so a restored Swift/Xcode build
# cache treats every input as dirty. The build database records these stamps;
# the next run that stamps the same unchanged files can skip them.
# Requires a non-shallow checkout (fetch-depth: 0); a depth-1 clone reports
# every file as introduced by HEAD.
set -euo pipefail
python3 - << 'PY'
import os
import subprocess

log = subprocess.check_output(
    ["git", "log", "--pretty=format:COMMIT:%ct", "--name-only"],
    text=True,
)
stamp = None
seen = set()
for line in log.splitlines():
    if not line:
        continue
    if line.startswith("COMMIT:"):
        stamp = int(line.split(":", 1)[1])
        continue
    if stamp is None or line in seen or not os.path.isfile(line):
        continue
    seen.add(line)
    os.utime(line, (stamp, stamp))
print(f"stamped {len(seen)} tracked files")
PY
