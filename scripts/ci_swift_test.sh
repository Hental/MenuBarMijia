#!/usr/bin/env bash
# `swift test` with a stall watchdog for the macOS CI runner.
#
# A deadlocked test can suspend a checked continuation forever: the suite time limit records an
# issue but cannot resume the continuation, so the job sits silent until its 45-minute timeout.
# After SWIFT_TEST_STALL_SECONDS without new output this script samples every swiftpm-testing
# process (Swift stacks) into the job log. It fails the step only when that log has no passing
# summary. A suite that already printed one and then hung at exit is a pass.
#
# Success is decided by Swift Testing's own summary line, never by the exit code or by the
# watchdog. A passing run can fail to exit on macos-26 (SwiftPM #8394), and `script` does not
# reliably forward the child status. A run with no summary line is a failure.
#
# Usage: bash scripts/ci_swift_test.sh [swift test arguments...]
set -uo pipefail

stall_seconds="${SWIFT_TEST_STALL_SECONDS:-300}"
tick=10
log="$(mktemp -t swift-test)"
echo "swift test log: $log"

# A pty keeps stdout line-buffered: without it the final summary can sit in a 4 KiB buffer
# forever when the process hangs at exit, and the watchdog would never see the result.
script -q /dev/null swift test "$@" >"$log" 2>&1 &
test_pid=$!
# Stream the log into the job output so a killed job still leaves the last test visible.
tail -n +1 -f "$log" &
tail_pid=$!

sample_process() {
    for pid in $(pgrep -f swiftpm-testing || true); do
        echo "=== sample ${pid}"
        sample "$pid" 5 -mayDie 2>/dev/null || true
    done
}

stalled=0
last_size=-1
stall_detected=0
while kill -0 "$test_pid" 2>/dev/null; do
    sleep "$tick"
    size="$(wc -c <"$log" | tr -d ' ')"
    if [ "$size" = "$last_size" ]; then
        stalled=$((stalled + tick))
    else
        stalled=0
        last_size="$size"
    fi
    if [ "$stalled" -ge "$stall_seconds" ]; then
        sample_process
        kill -TERM "$test_pid" 2>/dev/null || true
        sleep 2
        pkill -TERM -f swiftpm-testing 2>/dev/null || true
        sleep 2
        pkill -KILL -f swiftpm-testing 2>/dev/null || true
        stall_detected=1
        break
    fi
done
wait "$test_pid" 2>/dev/null
exit_code=$?
kill "$tail_pid" 2>/dev/null || true
wait "$tail_pid" 2>/dev/null || true

echo "=== swift test process exit: $exit_code (stalled=${stall_detected})"
# Read the summary before treating a stall as failure. The macos-26 exit hang writes a passing
# summary and then stays alive, so the watchdog sets stall_detected on a suite that already passed.
if grep -qE 'Test run with [0-9]+ tests? in [0-9]+ suites? passed' "$log"; then
    if [ "$stall_detected" -eq 1 ] || [ "$exit_code" -ne 0 ]; then
        echo "::warning::the suite passed but swift test did not exit cleanly (exit ${exit_code}, stalled=${stall_detected}); accepting the passing summary"
    fi
    exit 0
fi
if [ "$stall_detected" -eq 1 ]; then
    echo "::error::swift test produced no output for ${stall_seconds}s; the test process is deadlocked"
    exit 1
fi
echo "::error::swift test produced no passing summary"
exit 1
