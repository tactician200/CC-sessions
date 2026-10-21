#!/usr/bin/env bash
# Headless grader for the state-file contract v1: builds the app, writes
# fixtures into a temp state dir, runs `ClaudeSessions --dump` and asserts
# filtering, ordering, dead-pid hiding (never deleting: the hook may have
# replaced the file), and that hidden temporaries / mismatched filenames are
# not sessions. Exit non-zero on any failure.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "→ swift build (debug)"
swift build 2>&1 | tail -3
BIN="$(swift build --show-bin-path)/ClaudeSessions"
[ -x "$BIN" ] || { echo "✗ binary not found at $BIN"; exit 1; }

STATE_DIR="$(mktemp -d -t claude-sessions-fixtures)"
trap 'rm -rf "$STATE_DIR"' EXIT

NOW="$(python3 -c 'import time; print(time.time())')"
# A live pid must now also *look like* Claude (a recycled pid owned by another
# program counts as dead): run a throwaway copy of /bin/sleep named `claude`.
# Copied system binaries lose their signature and are killed on exec → re-sign ad hoc.
cp /bin/sleep "$STATE_DIR/claude"
codesign -s - -f "$STATE_DIR/claude" >/dev/null 2>&1
"$STATE_DIR/claude" 600 &
LIVE_PID=$!
disown "$LIVE_PID" 2>/dev/null || true   # no "Terminated" job notice when the trap kills it
trap 'kill "$LIVE_PID" 2>/dev/null || true; rm -rf "$STATE_DIR"' EXIT
sleep 0 &
DEAD_PID=$!
wait "$DEAD_PID" || true
if kill -0 "$DEAD_PID" 2>/dev/null; then
    echo "✗ could not obtain a dead pid"; exit 1
fi

python3 - "$STATE_DIR" "$NOW" "$LIVE_PID" "$DEAD_PID" "$$" <<'PY'
import json, os, sys
d, now, live, dead, recycled = sys.argv[1], float(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])

def write(sid, status, status_since, updated_at, pid=live, filename=None, **extra):
    obj = {
        "v": 1,
        "session_id": sid,
        "cwd": f"/tmp/fixtures/{sid}",
        "transcript_path": f"/nonexistent/claude-sessions-fixtures/{sid}.jsonl",
        "entrypoint": "claude-vscode",
        "status": status,
        "working": status == "working",
        "status_since": status_since,
        "updated_at": updated_at,
        "claude_pid": pid,
        "window_root": sid,
        "window_dir": f"/tmp/fixtures/{sid}",
    }
    obj.update(extra)
    with open(os.path.join(d, filename or f"{sid}.json"), "w") as f:
        json.dump(obj, f)

write("waiting-old", "waiting", now - 600, now - 600, waiting_reason="Permiso: Bash")
write("waiting-new", "waiting", now - 60, now - 60, waiting_reason="Pregunta")
write("working", "working", now - 30, now - 5, last_activity="Bash: run tests")
write("done", "done", now - 120, now - 120, last_activity="Edit: app.py")
write("dead-pid", "working", now - 10, now - 10, pid=dead)
write("stale-13h", "done", now - 13 * 3600, now - 13 * 3600)
# A live claude pid is authoritative: waiting for 13 h stays visible (and first: oldest).
write("waiting-13h", "waiting", now - 13 * 3600, now - 13 * 3600, waiting_reason="Pregunta vieja")
# Live pid that is NOT Claude (this bash script) = recycled pid → hidden, file kept.
write("recycled-pid", "working", now - 10, now - 10, pid=recycled)
# Atomic-write temporary left by the hook (newer copy of an existing session):
# hidden → must not show up nor duplicate "working".
write("working", "done", now - 1, now - 1, filename=".tmp-abc123.json")
# Hidden file with its own id: still not a session.
write("hidden-only", "working", now - 1, now - 1, filename=".hidden-only.json")
# Filename doesn't match the session_id inside → rejected.
write("waiting-new", "working", now - 1, now - 1, filename="mismatch.json")
PY

echo "→ $BIN --dump  (CLAUDE_SESSIONS_STATE_DIR=$STATE_DIR)"
OUT="$(CLAUDE_SESSIONS_STATE_DIR="$STATE_DIR" "$BIN" --dump)"
echo "$OUT"

python3 - "$STATE_DIR" "$OUT" <<'PY'
import json, os, sys
d, out = sys.argv[1], sys.argv[2]
sessions = json.loads(out)
fails = []

ids = [s["id"] for s in sessions]
expected = ["waiting-13h", "waiting-old", "waiting-new", "working", "done"]
if len(sessions) != 5:
    fails.append(f"expected exactly 5 sessions, got {len(sessions)}: {ids}")
if ids != expected:
    fails.append(f"order: expected {expected}, got {ids}")

by_id = {s["id"]: s for s in sessions}
if by_id.get("waiting-old", {}).get("waitingReason") != "Permiso: Bash":
    fails.append("waiting-old.waitingReason != 'Permiso: Bash'")
if by_id.get("working", {}).get("status") != "working":
    fails.append("working.status != working")
if by_id.get("done", {}).get("projectName") != "done":
    fails.append("projectName should come from window_root")
if by_id.get("working", {}).get("windowDir") != "/tmp/fixtures/working":
    fails.append("windowDir not propagated")

if len(set(ids)) != len(ids):
    fails.append(f"duplicate session ids: {ids}")
for hidden in ("hidden-only", "mismatch"):
    if hidden in ids:
        fails.append(f"{hidden} should not be listed")
if by_id.get("working", {}).get("status") != "working":
    fails.append("working was overridden by the .tmp-*.json copy")
if by_id.get("waiting-new", {}).get("status") != "waiting":
    fails.append("waiting-new was overridden by mismatch.json")
if "recycled-pid" in ids:
    fails.append("recycled-pid (live non-claude process) should be hidden")
if not os.path.exists(os.path.join(d, "recycled-pid.json")):
    fails.append("recycled-pid.json must NOT be deleted")
if "dead-pid" in ids:
    fails.append("dead-pid should be hidden")
if not os.path.exists(os.path.join(d, "dead-pid.json")):
    fails.append("dead-pid.json must NOT be deleted (race with the hook replacing it)")
if not os.path.exists(os.path.join(d, "stale-13h.json")):
    fails.append("stale-13h.json should still be on disk")

if fails:
    print("✗ FAIL")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("✓ PASS: 5 sessions (incl. waiting-13h with live pid), order ok, no dupes, hidden/.tmp/mismatched files ignored, dead-pid and recycled-pid hidden and NOT deleted, 13h done file hidden but kept")
PY
