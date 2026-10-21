#!/bin/bash
# Launcher for session-state.py.
#
# Finds a working Python 3.9+ interpreter, runs the hook with the event read
# from stdin, and never disturbs Claude Code: it always exits 0 and never
# writes to stdout or stderr.
#
# - stdin is read once into a variable before anything else.
# - Candidates (override with CS_PY_CANDIDATES, space-separated):
#   Homebrew (Apple silicon, Intel), python.org, /usr/bin/python3 only when the
#   developer tools are installed (otherwise it is a stub that opens an install
#   dialog), and finally `python3` from PATH.
# - Each candidate is probed for Python >= 3.9; the probe also catches the
#   system stub that exits 69 when the Xcode license has not been accepted.
# - The chosen interpreter is cached in $STATE_DIR/.python and re-probed on
#   every run; if it stops working the candidates are probed again.
# - The event is re-sent to another interpreter only when the interpreter
#   failed before the hook ran (probe failure, or exit 69 from the stub);
#   never after the hook ran, so an event is never applied twice.
# - The hook's stderr is appended to $STATE_DIR/.hook.log (reset above 256 KB).
# - With no usable interpreter, $STATE_DIR/.hook-unavailable is written so the
#   app can tell the user; it is removed as soon as an interpreter passes.

STATE_DIR="${CLAUDE_SESSIONS_STATE_DIR:-$HOME/.claude/sessions-state}"
CACHE_FILE="$STATE_DIR/.python"
MARKER="$STATE_DIR/.hook-unavailable"
LOG_FILE="$STATE_DIR/.hook.log"
LOG_MAX_BYTES=262144
EXIT_STUB=69
set -f  # candidate paths are never globbed

probe() {
    [ -n "$1" ] && [ -x "$1" ] || return 1
    "$1" -c 'import sys;sys.exit(sys.version_info<(3,9))' >/dev/null 2>&1 </dev/null
}

has_dev_tools() {
    xcode-select -p >/dev/null 2>&1
}

candidates() {
    if [ -n "${CS_PY_CANDIDATES+set}" ]; then
        printf '%s\n' $CS_PY_CANDIDATES
        return
    fi
    printf '%s\n' /opt/homebrew/bin/python3 /usr/local/bin/python3 \
        /Library/Frameworks/Python.framework/Versions/Current/bin/python3
    local dev=0
    if has_dev_tools; then
        dev=1
        printf '%s\n' /usr/bin/python3
    fi
    local from_path
    from_path="$(command -v python3 2>/dev/null)"
    # Without developer tools /usr/bin/python3 is the install stub: skip it.
    if [ -n "$from_path" ] && { [ "$dev" -eq 1 ] || [ "$from_path" != /usr/bin/python3 ]; }; then
        printf '%s\n' "$from_path"
    fi
}

run_hook() {   # run_hook <python> ; returns the interpreter's exit code
    local size
    if [ -f "$LOG_FILE" ]; then
        size="$(wc -c <"$LOG_FILE" 2>/dev/null | tr -d ' ')"
        if [ -n "$size" ] && [ "$size" -gt "$LOG_MAX_BYTES" ]; then
            : >"$LOG_FILE"
        fi
    fi
    printf '%s' "$INPUT" | "$1" "$HOOK" >/dev/null 2>>"$LOG_FILE"
}

main() {
    # Trailing sentinel keeps trailing newlines that $(...) would strip.
    INPUT="$(cat; printf x)"
    INPUT="${INPUT%x}"

    local here
    here="$(cd "$(dirname "$0")" && pwd)" || return 0
    HOOK="$here/session-state.py"

    mkdir -p "$STATE_DIR" 2>/dev/null

    local cached="" py tried=" " rc
    [ -f "$CACHE_FILE" ] && cached="$(head -n 1 "$CACHE_FILE" 2>/dev/null)"

    for py in $cached $(candidates); do
        case "$tried" in *" $py "*) continue ;; esac
        tried="$tried$py "
        probe "$py" || continue
        rm -f "$MARKER" 2>/dev/null
        [ "$py" = "$cached" ] || printf '%s\n' "$py" >"$CACHE_FILE" 2>/dev/null
        run_hook "$py"
        rc=$?
        # Exit 69 comes from the system stub refusing to start (the hook itself
        # always exits 0), so the hook never ran: safe to try the next one.
        [ "$rc" -eq "$EXIT_STUB" ] || return 0
        rm -f "$CACHE_FILE" 2>/dev/null
        cached=""
    done

    : >"$MARKER" 2>/dev/null
    return 0
}

main "$@" >/dev/null 2>&1
exit 0
