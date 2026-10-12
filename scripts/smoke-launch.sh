#!/bin/bash
# Launches build/Murmur.app's executable for 4 s and fails if it dies early or reports a dyld/library-loading error.
set -uo pipefail
cd "$(dirname "$0")/.."
BIN="build/Murmur.app/Contents/MacOS/Murmur"
LOG="$(mktemp -t murmur-smoke)"
"$BIN" >/dev/null 2>"$LOG" &
PID=$!
sleep 4
ALIVE=1
kill -0 "$PID" 2>/dev/null || ALIVE=0
kill "$PID" 2>/dev/null
wait "$PID" 2>/dev/null
if [ "$ALIVE" = 0 ] || grep -qE 'dyld|Library not loaded|not valid for use in process' "$LOG"; then
    echo "smoke launch FAILED:" >&2
    cat "$LOG" >&2
    rm -f "$LOG"
    exit 1
fi
rm -f "$LOG"
echo "smoke launch OK"
