#!/usr/bin/env bash
# One command for the whole test suite: swift build (DEBUG, the default — the
# self-tests are compiled only into DEBUG builds), every `--*-selftest` flag
# registered in Entry.swift, tests/dump-fixtures.sh, the plugin's pytest
# (plugin/tests) and the hooks.json ↔ hook event check.
# Prints one summary line per suite (with PASS/FAIL counts) and exits non-zero
# if any suite fails. Full output of failing suites is shown. No `timeout`
# (macOS): suites are bounded by their own design.
#
# Safe by construction: selftests use temp dirs; nothing here writes under
# ~/.claude, runs install.sh / build-app.sh or launches the GUI.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

LOGDIR="$(mktemp -d -t claude-sessions-run-all)"
trap 'rm -rf "$LOGDIR"' EXIT

FAILED=0
SUMMARY=()

record() {   # record <ok:0|1> <suite> <detail>
    local ok="$1" suite="$2" detail="$3"
    if [ "$ok" -eq 0 ]; then
        SUMMARY+=("$(printf 'PASS  %-24s %s' "$suite" "$detail")")
    else
        SUMMARY+=("$(printf 'FAIL  %-24s %s' "$suite" "$detail")")
        FAILED=$((FAILED + 1))
    fi
}

# --- 1. build ---------------------------------------------------------------
echo "→ swift build"
swift build > "$LOGDIR/build.log" 2>&1
BUILD_RC=$?
WARNINGS="$(grep -c 'warning:' "$LOGDIR/build.log" || true)"
cat "$LOGDIR/build.log" | tail -5
if [ "$BUILD_RC" -ne 0 ]; then
    cat "$LOGDIR/build.log"
    record 1 "swift build" "exit $BUILD_RC"
    printf '\n== summary ==\n%s\n' "${SUMMARY[@]}"
    echo "FAILED: build broken, nothing else run"
    exit 1
fi
if [ "$WARNINGS" -ne 0 ]; then
    grep 'warning:' "$LOGDIR/build.log"
    record 1 "swift build" "$WARNINGS warning(s)"
else
    record 0 "swift build" "ok, 0 warnings"
fi

BIN="$(swift build --show-bin-path)/ClaudeSessions"
[ -x "$BIN" ] || { echo "✗ binary not found at $BIN"; exit 1; }

# --- 2. every --*-selftest flag registered in Entry.swift --------------------
FLAGS="$(grep -o '"--[a-z0-9-]*-selftest"' Sources/ClaudeSessions/Entry.swift | tr -d '"' | sort -u)"
[ -n "$FLAGS" ] || { echo "✗ no --*-selftest flags found in Entry.swift"; exit 1; }

for flag in $FLAGS; do
    echo
    echo "→ $flag"
    "$BIN" "$flag" > "$LOGDIR/suite.log" 2>&1 < /dev/null
    rc=$?
    cat "$LOGDIR/suite.log"
    pass="$(grep -c '^PASS' "$LOGDIR/suite.log" || true)"
    fail="$(grep -c '^FAIL' "$LOGDIR/suite.log" || true)"
    if [ "$rc" -ne 0 ] || [ "$fail" -ne 0 ] || [ "$pass" -eq 0 ]; then
        record 1 "$flag" "$pass passed, $fail failed, exit $rc"
    else
        record 0 "$flag" "$pass passed, $fail failed"
    fi
done

# --- 3. dump fixtures (state-file contract v1, end to end) ------------------
echo
echo "→ tests/dump-fixtures.sh"
bash tests/dump-fixtures.sh > "$LOGDIR/fixtures.log" 2>&1 < /dev/null
rc=$?
cat "$LOGDIR/fixtures.log"
if [ "$rc" -eq 0 ] && grep -q '^✓ PASS' "$LOGDIR/fixtures.log"; then
    record 0 "dump-fixtures" "$(grep '^✓ PASS' "$LOGDIR/fixtures.log" | cut -c1-70)…"
else
    record 1 "dump-fixtures" "exit $rc"
fi

# --- 4. plugin pytest (the hook in this repo) --------------------------------
echo
echo "→ pytest plugin/tests"
PYTHONDONTWRITEBYTECODE=1 python3 -m pytest -q -p no:cacheprovider plugin/tests > "$LOGDIR/pytest.log" 2>&1 < /dev/null
rc=$?
cat "$LOGDIR/pytest.log"
last="$(grep -E '[0-9]+ (passed|failed|error)' "$LOGDIR/pytest.log" | tail -1 | sed 's/^=* *//; s/ *=*$//')"
if [ "$rc" -eq 0 ]; then
    record 0 "hook pytest" "${last:-ok}"
else
    record 1 "hook pytest" "${last:-exit $rc}"
fi

# --- 5. hooks.json registers exactly the events the hook dispatches ----------
echo
echo "→ tests/check_hook_events.py"
out="$(python3 tests/check_hook_events.py plugin/hooks/hooks.json plugin/scripts/session-state.py 2>&1 < /dev/null)"
rc=$?
echo "$out"
if [ "$rc" -eq 0 ]; then record 0 "hook events" "$out"; else record 1 "hook events" "exit $rc"; fi

# --- summary -----------------------------------------------------------------
echo
echo "== summary =="
printf '%s\n' "${SUMMARY[@]}"
if [ "$FAILED" -ne 0 ]; then
    echo "FAILED: $FAILED suite(s)"
    exit 1
fi
echo "ALL ${#SUMMARY[@]} SUITES PASSED"
