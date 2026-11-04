#!/usr/bin/env bash
# Runs the tests, retrying only if they freeze. GitHub's Mac runners sometimes hang before
# the first test starts. A test that fails is reported straight away, not retried.
set -uo pipefail

ATTEMPTS=3
TIME_LIMIT=420   # seconds, well above a normal run including the build

for attempt in $(seq 1 "$ATTEMPTS"); do
    echo "▸ Test attempt $attempt of $ATTEMPTS"
    swift test &
    tests=$!

    ( sleep "$TIME_LIMIT"; touch "${TMPDIR:-/tmp}/tack-tests-froze.$$"; pkill -TERM -P "$tests"; kill -TERM "$tests" ) 2>/dev/null &
    watchdog=$!

    wait "$tests"
    status=$?
    pkill -P "$watchdog" 2>/dev/null
    kill "$watchdog" 2>/dev/null

    if [[ ! -e "${TMPDIR:-/tmp}/tack-tests-froze.$$" ]]; then
        exit "$status"
    fi
    rm -f "${TMPDIR:-/tmp}/tack-tests-froze.$$"
    pkill -f swiftpm-testing-helper 2>/dev/null
    echo "::warning::Tests froze on attempt $attempt"
done

echo "::error::Tests froze on all $ATTEMPTS attempts"
exit 1
