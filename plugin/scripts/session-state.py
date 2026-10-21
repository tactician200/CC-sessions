#!/usr/bin/env python3
"""Per-session Claude Code state for the Claude Sessions menu bar app.

Registered (through the plugin's hooks.json) on SessionStart, SessionEnd,
UserPromptSubmit, Notification, Stop, SubagentStop, PreToolUse, PostToolUse
and PostToolUseFailure. Writes/deletes `~/.claude/sessions-state/<session_id>.json`
(override with env CLAUDE_SESSIONS_STATE_DIR) using an atomic write
(temp file + os.replace) so the menu bar app never reads a half-written file.

Hot path (PreToolUse/PostToolUse/UserPromptSubmit/Stop/Notification): no
subprocesses. `claude_pid`/`host_pid` are recomputed on every SessionStart (and
once when adopting a session that started before the hook was installed).
Editor window resolution is delegated to a detached child process
(`--resolve <session_id> <generation>`) so the hook never blocks. Every
read -> modify -> replace (including the resolver merge and SessionEnd) runs
under a per-session flock (`STATE_DIR/<sid>.lock`, non-blocking with a ~1 s
timeout) to avoid lost updates between concurrent invocations.

Never raises outside main() and always exits 0: a broken hook would affect
every Claude Code session.
"""
from __future__ import annotations  # keeps `str | None` annotations valid on Python 3.9

import contextlib
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path
from urllib.parse import unquote

HOME = Path.home()
STATE_DIR = Path(
    os.environ.get("CLAUDE_SESSIONS_STATE_DIR") or str(HOME / ".claude" / "sessions-state")
)

# ---------------------------------------------------------------------------
# Editor profiles
# ---------------------------------------------------------------------------
# Everything editor-specific lives here. Only profiles marked `enabled` are
# used; add a new editor only after its values have been verified on a real
# install.
#   entrypoint        value of CLAUDE_CODE_ENTRYPOINT when the session runs
#                     inside that editor's Claude Code extension
#   helper_process    substring of the extension host process name
#   cli               editor CLI used for `--status`
#   workspace_storage per-window folder registry (workspace.json files)
EDITOR_PROFILES: dict[str, dict] = {
    "vscode": {
        "enabled": True,
        "entrypoint": "claude-vscode",
        "helper_process": "Code Helper (Plugin)",
        "cli": "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
        "workspace_storage": HOME / "Library/Application Support/Code/User/workspaceStorage",
    },
}
EDITOR = EDITOR_PROFILES["vscode"]
CODE_CLI = EDITOR["cli"]
EXT_HOST_PROCESS = EDITOR["helper_process"]
VSCODE_WORKSPACES = EDITOR["workspace_storage"]


def is_editor_entrypoint(entrypoint: str | None) -> bool:
    """True when the session runs inside an enabled editor extension."""
    return any(
        p.get("enabled") and p.get("entrypoint") == entrypoint
        for p in EDITOR_PROFILES.values()
    )


# Process names that do NOT count as "the Claude process": shells and python
# wrappers that only relaunch the hook or the CLI.
_SHELL_COMMS = {"sh", "bash", "zsh", "dash", "env"}

RE_PERMISSION_TOOL = re.compile(r"permission to use (\S+)", re.IGNORECASE)
RE_SESSION_ID = re.compile(r"[^A-Za-z0-9_-]")


# ---------------------------------------------------------------------------
# State file helpers
# ---------------------------------------------------------------------------

def load_state(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except Exception:
        return {}


def atomic_write(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # The temp suffix must not be ".json": the app scans STATE_DIR/*.json and a
    # concurrent reader could otherwise open this file while half-written.
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(state, f, separators=(",", ":"))
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def sanitize_session_id(session_id: str) -> str:
    return RE_SESSION_ID.sub("", session_id or "")[:36]


# ---------------------------------------------------------------------------
# Per-session lock (prevents lost updates between the hook and the detached
# resolver, and between concurrent hook invocations for parallel tools)
# ---------------------------------------------------------------------------

LOCK_TIMEOUT_S = 1.0


def _lock_path(session_id: str) -> Path:
    return STATE_DIR / f"{session_id}.lock"


@contextlib.contextmanager
def session_lock(session_id: str, timeout: float = LOCK_TIMEOUT_S):
    """Exclusive flock on STATE_DIR/<sid>.lock. The .json file itself is not
    locked: it is replaced with os.replace on every write, so locking its fd
    would not protect against the next writer. Non-blocking with a short poll:
    it must never hang the hook. Yields `acquired` (bool); when the lock is
    not obtained within the timeout each caller decides whether to continue
    best-effort or skip its critical section (documented at each call site)."""
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    lock_path = _lock_path(session_id)
    try:
        fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o644)
    except OSError:
        yield False
        return
    acquired = False
    # time.monotonic(): time.time() can jump (clock changes, NTP) and produce
    # erratic timeouts; deadlines always use the monotonic clock.
    deadline = time.monotonic() + timeout
    try:
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
                break
            except OSError:
                if time.monotonic() >= deadline:
                    break
                time.sleep(0.02)
        yield acquired
    finally:
        if acquired:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            except OSError:
                pass
        os.close(fd)


PENDING_TOOLS_CAP = 50


def _prune_pending(pending: dict, cap: int = PENDING_TOOLS_CAP) -> None:
    """Bounds pending_tools when a PostToolUse never arrives (a tool that never
    finishes, a payload without tool_use_id, etc.) so it cannot grow without
    limit during a long session."""
    while len(pending) > cap:
        try:
            pending.pop(next(iter(pending)))
        except StopIteration:
            break


# A wait whose tool cannot be identified (the tool name could not be parsed
# from the message, or it matches no pending tool) uses this sentinel id in
# `waiting_on`. Only this sentinel is cleared by any PostToolUse /
# PostToolUseFailure.
UNKNOWN_WAIT_ID = "?"


# A wait whose tool finished without a PostToolUse / PostToolUseFailure event
# (failed tool, rejected plan, unregistered event) would otherwise stay
# "waiting" until Stop. The transcript is the source of truth: if it already
# holds a tool_result for that id, the tool finished (success, error or
# rejection). A live wait never has a tool_result, so this cannot release it.
TRANSCRIPT_TAIL_BYTES = 1_048_576


def resolved_wait_ids(transcript_path: str | None, ids: list[str]) -> set[str]:
    ids = {i for i in ids if i and i != UNKNOWN_WAIT_ID}
    if not transcript_path or not ids:
        return set()
    try:
        with open(transcript_path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - TRANSCRIPT_TAIL_BYTES))
            tail = f.read()
    except OSError:
        return set()
    found: set[str] = set()
    for line in tail.splitlines():
        if b"tool_result" not in line or not any(i.encode() in line for i in ids):
            continue
        try:
            obj = json.loads(line)  # the first line of the tail may be cut: skipped
        except ValueError:
            continue
        content = (obj.get("message") or {}).get("content") if isinstance(obj, dict) else None
        if not isinstance(content, list):
            continue
        for block in content:
            if isinstance(block, dict) and block.get("type") == "tool_result" and block.get("tool_use_id") in ids:
                found.add(block["tool_use_id"])
    return found


def _tool_ids_by_name(pending: dict, tool_name: str) -> list[str]:
    return [tid for tid, name in (pending or {}).items() if name == tool_name]


def _merge_waits(existing: list | None, new: list) -> list:
    """Order-preserving union: a new notification never drops live waits."""
    merged = list(existing or [])
    for wid in new:
        if wid not in merged:
            merged.append(wid)
    return merged


# Reason strings are shown verbatim by the app's UI.
def _reason_for(pending: dict, ids: list) -> str | None:
    for wid in ids:
        name = (pending or {}).get(wid)
        if name == "AskUserQuestion":
            return "Pregunta"
        if name == "ExitPlanMode":
            return "Plan por aprobar"
        if name:
            return f"Permiso: {name}"
    return None


def settle_waits(state: dict, now: float, remaining: list) -> None:
    """Sets `remaining` as the wait set; with nothing pending, back to working.
    When waits remain, the reason is derived from a live one (not the resolved one)."""
    if remaining:
        state["waiting_on"] = remaining
        state["waiting_reason"] = _reason_for(state.get("pending_tools") or {}, remaining) or state.get("waiting_reason")
    else:
        set_status(state, now, "working")
        state["waiting_on"] = None


def set_status(state: dict, now: float, status: str, reason: str | None = None) -> None:
    """Applies status + working; status_since only changes when status changes."""
    if state.get("status") != status:
        state["status_since"] = now
    state["status"] = status
    state["working"] = status == "working"
    state["waiting_reason"] = reason if status == "waiting" else None


def truncate_oneline(text: str, maxlen: int) -> str:
    text = (text or "").replace("\n", " ").replace("\r", " ")
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) > maxlen:
        text = text[: maxlen - 1] + "…"
    return text


# ---------------------------------------------------------------------------
# claude_pid / host_pid (SessionStart and adoption only)
# ---------------------------------------------------------------------------

def _is_shell_comm(comm: str) -> bool:
    name = (comm or "").strip().rsplit("/", 1)[-1]
    if not name:
        return True
    if name in _SHELL_COMMS:
        return True
    if name.startswith("python"):
        return True
    return False


PID_PROBE_BUDGET_S = 1.0  # total time budget for identity probes


def compute_claude_pid(budget_s: float = PID_PROBE_BUDGET_S) -> int | None:
    """Walks up the ppid chain from os.getppid() to the first non-shell ancestor.

    Bounded to `budget_s` in total (time.monotonic()): without the budget, up
    to 12 `ps` calls with timeout=5 each could add up to 60 s, far above any
    reasonable hook timeout. Always called outside the session lock: it is
    the slow part."""
    deadline = time.monotonic() + budget_s
    pid = os.getppid()
    for _ in range(12):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        try:
            out = subprocess.run(
                ["ps", "-o", "ppid=,comm=", "-p", str(pid)],
                capture_output=True, text=True, timeout=max(0.05, remaining),
            ).stdout.strip()
        except Exception:
            return None
        if not out:
            return None
        ppid_s, _, comm = out.partition(" ")
        if not _is_shell_comm(comm):
            return pid
        ppid_s = ppid_s.strip()
        if not ppid_s or ppid_s == "1" or not ppid_s.isdigit():
            return None
        pid = int(ppid_s)
    return None


# ---------------------------------------------------------------------------
# Editor window helpers (extension host lookup and `--status` parsing)
# ---------------------------------------------------------------------------

# "  1  25332747904  75700  window [18] (<active tab> — <rootName>)"
RE_WINDOW = re.compile(r"^\s*\S+\s+\S+\s+(\d+)\s+window \[(\d+)\]\s*\((.*)\)\s*$")
RE_EXTHOST = re.compile(r"^\s*\S+\s+\S+\s+(\d+)\s+extension-host \[(\d+)\]\s*$")


def ext_host_pid() -> str | None:
    """Walks up the process tree to the editor's extension host for this window."""
    pid = str(os.getpid())
    for _ in range(12):
        try:
            out = subprocess.run(
                ["ps", "-o", "ppid=,comm=", "-p", pid],
                capture_output=True, text=True, timeout=5,
            ).stdout.strip()
        except Exception:
            return None
        if not out:
            return None
        ppid, _, comm = out.partition(" ")
        if EXT_HOST_PROCESS in comm:
            return pid
        pid = ppid.strip()
        if not pid or pid == "1":
            return None
    return None


def root_name_for(host_pid: str) -> str | None:
    """Workspace rootName of the window that owns the given extension host."""
    try:
        status = subprocess.run(
            [CODE_CLI, "--status"], capture_output=True, text=True, timeout=15
        ).stdout
    except Exception:
        return None

    windows, host_win = {}, None
    for line in status.splitlines():
        m = RE_WINDOW.match(line)
        if m:
            windows[m.group(2)] = m.group(3)
            continue
        m = RE_EXTHOST.match(line)
        if m and m.group(1) == host_pid:
            host_win = m.group(2)
    title = windows.get(host_win or "")
    if not title:
        return None
    # Title = "<active tab> — <rootName>"; with no editor open it is just rootName.
    return title.split("—")[-1].strip() or None


def compute_host_pid(budget_s: float = PID_PROBE_BUDGET_S) -> int | None:
    """`ext_host_pid()` uses the same `ps` loop as compute_claude_pid but with
    a per-call timeout and no overall budget, so the call is bounded from a
    daemon thread with join(budget_s). If it does not return in time the hook
    continues without it (the orphaned thread/subprocess ends on its own and
    does not block process exit)."""
    result: list[int | None] = [None]

    def _run() -> None:
        try:
            pid = ext_host_pid()
            result[0] = int(pid) if pid else None
        except Exception:
            result[0] = None

    t = threading.Thread(target=_run, daemon=True)
    t.start()
    t.join(budget_s)
    return result[0]


def spawn_resolver(session_id: str, generation: str | None) -> None:
    """Launches this same script as `--resolve <session_id> <generation>`, detached.

    `generation` is a per-life nonce (uuid4 hex) assigned on SessionStart or
    adoption: the resolver re-checks it for EQUALITY before merging so it never
    writes over a session whose identity changed. An integer counter is not
    enough: if the session is deleted (SessionEnd) and recreated with the same
    session_id, a counter restarts at the same value and an old resolver would
    collide with the new life; a uuid4 does not collide."""
    try:
        argv = [sys.executable, str(Path(__file__).resolve()), "--resolve", session_id]
        if generation is not None:
            argv.append(str(generation))
        subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except Exception:
        pass


RE_STATUS_FOLDER = re.compile(r"^\|\s+Folder \((.+?)\):")


def process_cwd(pid: int | None) -> str | None:
    """Working directory of a live process (lsof, ~30 ms). The editor extension
    launches `claude` in its window's folder and that cwd does not change even
    if the session later changes directory, unlike the payload's `cwd`."""
    if not pid:
        return None
    try:
        out = subprocess.run(
            ["/usr/sbin/lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"],
            capture_output=True, text=True, timeout=2,
        ).stdout
    except Exception:
        return None
    for line in out.splitlines():
        if line.startswith("n") and len(line) > 1:
            return line[1:]
    return None


def open_folder_names(status_text: str) -> set[str]:
    """Folders open as windows according to `code --status` ("|    Folder (x): N files").
    Unlike window titles, they do not depend on the active tab."""
    return {m.group(1) for line in status_text.splitlines() if (m := RE_STATUS_FOLDER.match(line))}


def code_status_text() -> str:
    try:
        return subprocess.run(
            [CODE_CLI, "--status"], capture_output=True, text=True, timeout=15,
        ).stdout
    except Exception:
        return ""


RESOLVE_RETRY_S = 600
# In-process resolver retries (seconds to wait before each one).
RESOLVE_BACKOFF_S: tuple[float, ...] = (3, 10, 30)
_resolver_sleep = time.sleep


def _workspace_folders(storage: Path = VSCODE_WORKSPACES) -> list[tuple[float, Path]]:
    """Folders known to the editor: (mtime, folder) for every
    workspaceStorage/<hash>/workspace.json with {"folder": "file:///…"} whose
    folder still exists. The directory mtime marks the last use."""
    found: list[tuple[float, Path]] = []
    try:
        entries = list(storage.iterdir())
    except Exception:
        return found
    for d in entries:
        try:
            uri = json.loads((d / "workspace.json").read_text()).get("folder") or ""
            if not uri.startswith("file://"):
                continue
            folder = Path(unquote(uri[len("file://"):]))
            if not folder.is_dir():
                continue
            found.append((d.stat().st_mtime, folder))
        except Exception:
            continue
    return found


def known_folder_paths(storage: Path = VSCODE_WORKSPACES) -> set[str]:
    """Full paths (as stored and resolved) of the folders the editor knows."""
    out: set[str] = set()
    for _, folder in _workspace_folders(storage):
        out.add(str(folder))
        try:
            out.add(str(folder.resolve()))
        except Exception:
            pass
    return out


def proc_dir_is_open_window(proc_dir: str, open_names: set[str], known_paths: set[str]) -> bool:
    """The process cwd is only accepted as window_dir when its basename is an
    open window (`code --status`) AND its full path is a folder the editor
    knows. Matching the basename alone would accept a checkout such as
    /tmp/x/<name> while another folder with the same name is open, and
    `code <dir>` would then open a new window."""
    if not proc_dir or Path(proc_dir).name not in open_names:
        return False
    try:
        resolved = str(Path(proc_dir).resolve())
    except Exception:
        resolved = proc_dir
    return proc_dir in known_paths or resolved in known_paths


def workspace_folder_for(root: str, storage: Path = VSCODE_WORKSPACES) -> str | None:
    """Folder open in the editor whose basename == root (the most recent one if several).

    Each window that opened a folder leaves workspaceStorage/<hash>/workspace.json
    with {"folder": "file:///…"}; the directory mtime marks the last use.
    """
    best: tuple[float, str] | None = None
    for mtime, folder in _workspace_folders(storage):
        if folder.name != root:
            continue
        if best is None or mtime > best[0]:
            best = (mtime, str(folder))
    return best[1] if best else None


def run_resolver(session_id: str, generation: str | None) -> None:
    """--resolve mode: computes window_root/window_dir and merges them into the state.

    Resolution (ps, workspaceStorage) runs WITHOUT the lock: it is the slow
    part. The merge runs under `session_lock` and re-reads the fresh state: if
    the session identity changed while resolving (another SessionStart or
    adoption after a crash) or the session ended, the result is discarded
    instead of overwriting newer data.

    A new editor tab sometimes starts before its window appears in
    `code --status` / workspaceStorage, so a single attempt at SessionStart can
    miss it. The resolver therefore retries in this same background process
    (RESOLVE_BACKOFF_S)."""
    session_id = sanitize_session_id(session_id)
    if not session_id:
        return
    state_path = STATE_DIR / f"{session_id}.json"
    window_dir, window_root = _resolve_window_once(load_state(state_path))
    for delay in RESOLVE_BACKOFF_S:
        if window_dir:
            break
        _resolver_sleep(delay)
        state = load_state(state_path)
        if not state or (generation is not None and state.get("generation") != generation):
            return  # ended or identity changed: nothing to resolve
        if state.get("window_dir"):
            return  # another resolver already found it
        window_dir, window_root = _resolve_window_once(state)

    with session_lock(session_id) as acquired:
        if not acquired:
            # The resolver is a non-interactive background process: losing
            # this resolution (retried on the next prompt/Stop, at most once
            # every 10 min) is preferable to writing without the lock.
            return
        state = load_state(state_path)
        if not state:
            return  # session ended / file missing: never create one from scratch
        if generation is not None and state.get("generation") != generation:
            return  # identity changed since launch: stale result
        state["resolve_at"] = time.time()
        if window_root:
            state["window_root"] = window_root
        if window_dir:
            state["window_dir"] = window_dir
        atomic_write(state_path, state)


def _resolve_window_once(state: dict) -> tuple[str | None, str | None]:
    """One attempt at (window_dir, window_root); window_dir is None on failure."""
    cwd = state.get("cwd") or ""
    host = state.get("host_pid")
    claude_pid = state.get("claude_pid")

    # Do not walk the process tree from THIS process: once the hook exits the
    # resolver is reparented to launchd and no longer reaches the extension
    # host. host_pid was computed by the hook while the chain was intact.
    window_dir: str | None = None
    window_root: str | None = None
    # 1) cwd of the claude process: the extension launched it in the window's
    #    folder. Only accepted if the editor has that folder open as a window;
    #    `code <dir>` on a folder that is not open creates another window.
    #    (Window titles are unreliable: they depend on the active tab, and a
    #    window can be missing from the --status process table.)
    try:
        proc_dir = process_cwd(claude_pid)
        if proc_dir and proc_dir_is_open_window(
                proc_dir, open_folder_names(code_status_text()), known_folder_paths()):
            window_dir = proc_dir
            window_root = Path(proc_dir).name
    except Exception:
        pass
    # 2) Fallback: rootName from the extension host window title.
    if not window_dir:
        try:
            window_root = root_name_for(str(host)) if host else None
            if window_root and cwd:
                p = Path(cwd).resolve()
                for cand in [p, *p.parents]:
                    if cand.name == window_root and cand.is_dir():
                        window_dir = str(cand)
                        break
            if window_root and not window_dir:
                # cwd outside the window's folder (a sibling folder, or the
                # session's memory under ~/.claude/projects/…): look it up in
                # the editor's folder registry.
                window_dir = workspace_folder_for(window_root)
        except Exception:
            pass
    return window_dir, window_root


# ---------------------------------------------------------------------------
# last_activity / last_prompt / notifications
# ---------------------------------------------------------------------------

def _basename(path: str) -> str:
    return Path(path).name if path else ""


def summarize_activity(tool_name: str, tool_input: dict) -> str:
    tool_input = tool_input or {}
    if tool_name == "Bash":
        desc = (tool_input.get("description") or "").strip()
        cmd = (tool_input.get("command") or "").strip()
        text = desc or cmd[:60]
        return truncate_oneline(f"Bash: {text}", 80)
    if tool_name in ("Edit", "Write", "Read", "NotebookEdit"):
        path = (
            tool_input.get("file_path")
            or tool_input.get("notebook_path")
            or tool_input.get("path")
            or ""
        )
        return truncate_oneline(f"{tool_name}: {_basename(path)}", 80)
    if tool_name in ("Grep", "Glob"):
        pattern = tool_input.get("pattern") or ""
        return truncate_oneline(f"{tool_name}: {pattern}", 80)
    if tool_name in ("Agent", "Task"):
        desc = tool_input.get("description") or ""
        return truncate_oneline(f"Agent: {desc}", 80)
    return truncate_oneline(tool_name or "", 80)


def extract_permission_tool(message: str) -> str | None:
    m = RE_PERMISSION_TOOL.search(message or "")
    if not m:
        return None
    tool = m.group(1).strip().strip(".,:;!?")
    return tool or None


def classify_notification(payload: dict) -> tuple[str, str | None] | None:
    """(status, reason) to apply, or None when the notification is ignored.

    status == "idle" is a special marker: the caller decides whether it
    overrides the current status (only when it is not already "done").
    """
    ntype = (payload.get("notification_type") or "").strip()
    message = payload.get("message") or ""
    low = message.lower()

    if ntype == "auth_success":
        return None
    if ntype == "permission_prompt" or "permission" in low:
        tool = extract_permission_tool(message)
        reason = f"Permiso: {tool}" if tool else "Permiso"
        return ("waiting", reason)
    if ntype == "elicitation_dialog":
        return ("waiting", "Pregunta")
    if ntype == "idle_prompt" or "waiting for your input" in low:
        reason = truncate_oneline(message, 120) or None
        return ("idle", reason)
    reason = truncate_oneline(message, 120) or None
    return ("waiting", reason)


# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------

def _handle_event(payload: dict) -> int:
    event = payload.get("hook_event_name")
    raw_session_id = payload.get("session_id")
    if not event or not raw_session_id:
        return 0
    session_id = sanitize_session_id(raw_session_id)
    if not session_id:
        return 0
    state_path = STATE_DIR / f"{session_id}.json"

    # Identity probes (ps, extension host lookup) are the slow part and ALWAYS
    # run before taking the lock, never inside it. The "peek" below is an
    # unlocked read used only to decide whether that cost is worth paying; the
    # real decision (whether adoption is still needed) is re-checked against
    # the fresh state under the lock, so a stale peek can never cause a wrong
    # mutation. Worst case, identity is computed and discarded.
    precomputed_identity: tuple[int | None, int | None] | None = None
    if event == "SessionStart":
        precomputed_identity = (compute_claude_pid(), compute_host_pid())
    elif event in ("UserPromptSubmit", "Stop"):
        peek = load_state(state_path)
        if "claude_pid" not in peek:
            precomputed_identity = (compute_claude_pid(), compute_host_pid())

    # Reading the transcript is I/O too, so it also happens outside the lock.
    # Under the lock it is only intersected with the fresh waiting_on.
    resolved_ids: set[str] = set()
    if event in ("PreToolUse", "PostToolUse", "PostToolUseFailure"):
        peek = load_state(state_path)
        if peek.get("status") == "waiting" and peek.get("waiting_on"):
            resolved_ids = resolved_wait_ids(
                payload.get("transcript_path") or peek.get("transcript_path"),
                peek["waiting_on"],
            )

    spawn_generation: str | None = None
    do_spawn = False

    # The whole read -> modify -> replace of the event runs under the
    # per-session flock. If the lock is not obtained within LOCK_TIMEOUT_S,
    # nothing is read, written or deleted: the hook exits best-effort without
    # touching the file. It must never block Claude Code (hence the timeout),
    # and it must never mutate without the lock.
    with session_lock(session_id) as acquired:
        if not acquired:
            return 0
        if event == "SessionEnd":
            try:
                state_path.unlink()
            except FileNotFoundError:
                pass
            except Exception:
                pass
        else:
            state = load_state(state_path)
            now = time.time()

            state["v"] = 1
            state["session_id"] = raw_session_id
            if payload.get("cwd"):
                state["cwd"] = payload["cwd"]
            if payload.get("transcript_path"):
                state["transcript_path"] = payload["transcript_path"]
            state.setdefault("started_at", now)
            state["updated_at"] = now

            if event == "SessionStart":
                set_status(state, now, "done")
                entrypoint = os.environ.get("CLAUDE_CODE_ENTRYPOINT") or state.get("entrypoint")
                state["entrypoint"] = entrypoint

                # Recompute identity on EVERY SessionStart, not only when it is
                # missing: a session resumed after a crash may carry a stale,
                # dead claude_pid/host_pid/window_dir. ANY difference in the
                # (claude_pid, host_pid) pair invalidates the window, including
                # a transition to None: a failed probe means the identity is
                # unverified, so the old window must not be trusted either.
                had_identity = "claude_pid" in state
                old_claude_pid = state.get("claude_pid")
                old_host_pid = state.get("host_pid")
                new_claude_pid, new_host_pid = precomputed_identity or (None, None)
                identity_changed = had_identity and (
                    new_claude_pid != old_claude_pid or new_host_pid != old_host_pid
                )
                state["claude_pid"] = new_claude_pid
                state["host_pid"] = new_host_pid
                if identity_changed:
                    state["window_root"] = None
                    state["window_dir"] = None
                    state["resolve_at"] = None
                # New session life: tool bookkeeping from the previous process
                # no longer means anything.
                state["pending_tools"] = {}
                state["waiting_on"] = None
                # Per-life nonce (not a counter); see spawn_resolver().
                state["generation"] = uuid.uuid4().hex

                atomic_write(state_path, state)
                if is_editor_entrypoint(entrypoint) and not state.get("window_dir"):
                    do_spawn = True
                    spawn_generation = state["generation"]
            else:
                write_needed = True

                # Sessions opened before the hook was installed never saw
                # SessionStart: they are adopted on the first prompt/Stop (off
                # the hot tool path). A missing key (not None) means "never
                # computed"; a computed None is not retried.
                adopt = False
                if (
                    event in ("UserPromptSubmit", "Stop")
                    and "claude_pid" not in state
                    and precomputed_identity is not None
                ):
                    state["entrypoint"] = os.environ.get("CLAUDE_CODE_ENTRYPOINT") or state.get("entrypoint")
                    state["claude_pid"], state["host_pid"] = precomputed_identity
                    state["generation"] = uuid.uuid4().hex  # per-life nonce, not a counter
                    adopt = is_editor_entrypoint(state["entrypoint"]) and not state.get("window_dir")
                elif (
                    event in ("UserPromptSubmit", "Stop")
                    and is_editor_entrypoint(state.get("entrypoint"))
                    and (state.get("host_pid") or state.get("claude_pid"))
                    and not state.get("window_dir")
                    and now - (state.get("resolve_at") or 0) > RESOLVE_RETRY_S
                ):
                    adopt = True  # retry a failed resolution (at most once every 10 min)

                if resolved_ids and state.get("status") == "waiting" and state.get("waiting_on"):
                    settle_waits(state, now, [t for t in state["waiting_on"] if t not in resolved_ids])

                if event == "UserPromptSubmit":
                    set_status(state, now, "working")
                    # Turn start for the app, on EVERY prompt, including
                    # harness-injected ones (<task-notification>…) that do not
                    # update last_prompt_at.
                    state["turn_started_at"] = now
                    # New turn: tool ids from the previous turn no longer
                    # mean anything.
                    state["pending_tools"] = {}
                    state["waiting_on"] = None
                    prompt = (payload.get("prompt") or "").lstrip()
                    # Harness notices (<task-notification>, <system-reminder>…)
                    # arrive as prompts but are not requests typed by the user.
                    if not prompt.startswith("<"):
                        state["last_prompt"] = truncate_oneline(prompt, 120)
                        state["last_prompt_at"] = now

                elif event == "PreToolUse":
                    tool_name = payload.get("tool_name") or ""
                    tool_use_id = payload.get("tool_use_id")
                    if tool_use_id:
                        pending = state.setdefault("pending_tools", {})
                        pending[tool_use_id] = tool_name
                        _prune_pending(pending)

                    if tool_name in ("AskUserQuestion", "ExitPlanMode"):
                        # JOIN the existing wait set instead of replacing it,
                        # so a pending question survives an additional
                        # interactive tool running in parallel.
                        reason = "Pregunta" if tool_name == "AskUserQuestion" else "Plan por aprobar"
                        waiting_on = list(state.get("waiting_on") or [])
                        wid = tool_use_id or UNKNOWN_WAIT_ID
                        if wid not in waiting_on:
                            waiting_on.append(wid)
                        set_status(state, now, "waiting", reason)
                        state["waiting_on"] = waiting_on
                    else:
                        state["last_activity"] = summarize_activity(tool_name, payload.get("tool_input") or {})
                        state["last_tool"] = tool_name
                        state["last_tool_at"] = now
                        # An ordinary tool does NOT clear an unresolved wait
                        # (another question/plan, or a permission for a
                        # DIFFERENT tool). Status derives from whether anything
                        # is still pending in `waiting_on`, not from "some
                        # PreToolUse arrived".
                        if not (state.get("status") == "waiting" and state.get("waiting_on")):
                            set_status(state, now, "working")
                            state["waiting_on"] = None

                elif event in ("PostToolUse", "PostToolUseFailure"):
                    # A PostToolUse from an UNRELATED tool must not clear a
                    # "waiting" that depends on ANOTHER still-pending tool
                    # (permission or interaction). Waiting ends only once no
                    # id in `waiting_on` remains pending, except for the
                    # UNKNOWN_WAIT_ID sentinel, which identifies no tool and is
                    # cleared by any PostToolUse/Failure (explicit fallback).
                    tool_use_id = payload.get("tool_use_id")
                    pending = state.get("pending_tools")
                    if isinstance(pending, dict) and tool_use_id:
                        pending.pop(tool_use_id, None)
                    waiting_on = state.get("waiting_on")
                    if state.get("status") == "waiting" and waiting_on:
                        # The sentinel only removes itself; it never drags a
                        # known id (an unanswered question) along with it.
                        settle_waits(state, now, [
                            t for t in waiting_on if t != UNKNOWN_WAIT_ID and t != tool_use_id
                        ])
                    elif state.get("status") != "waiting":
                        set_status(state, now, "working")
                        state["waiting_on"] = None
                    else:
                        # status == waiting but no tracked waiting_on (e.g. a
                        # payload without tool_use_id): fall back to working.
                        set_status(state, now, "working")
                        state["waiting_on"] = None

                elif event == "Notification":
                    result = classify_notification(payload)
                    if result is None:
                        write_needed = False  # auth_success: the file is not touched
                    else:
                        status, reason = result
                        if status == "idle":
                            if state.get("status") != "done":
                                prior = state.get("waiting_on")
                                set_status(state, now, "waiting", reason)
                                state["waiting_on"] = _merge_waits(prior, [UNKNOWN_WAIT_ID])
                        else:
                            prior = state.get("waiting_on")
                            set_status(state, now, status, reason)
                            if status == "waiting":
                                # Do NOT wait on every running tool: correlate
                                # by name with the notification message. If no
                                # name can be parsed, or it matches no pending
                                # tool, the wait has no identified tool
                                # (explicit sentinel).
                                message = payload.get("message") or ""
                                tool = extract_permission_tool(message)
                                matched = (
                                    _tool_ids_by_name(state.get("pending_tools") or {}, tool)
                                    if tool else []
                                )
                                # JOIN the live wait set: a pending question
                                # does not disappear because a permission
                                # prompt arrived.
                                state["waiting_on"] = _merge_waits(prior, matched or [UNKNOWN_WAIT_ID])

                elif event == "Stop":
                    set_status(state, now, "done")
                    state["pending_tools"] = {}
                    state["waiting_on"] = None

                elif event == "SubagentStop":
                    pass  # only updated_at changes (already done above)

                else:
                    pass  # unmapped events: generic bookkeeping only

                if write_needed:
                    atomic_write(state_path, state)
                    if (STATE_DIR / ".debug").exists():  # diagnostics: touch <state dir>/.debug
                        with open(STATE_DIR / ".events.log", "a") as log:
                            log.write(f"{now:.3f} {session_id[:8]} {event} {payload.get('tool_name') or payload.get('notification_type') or ''} → {state.get('status')}\n")
                if adopt:
                    do_spawn = True
                    spawn_generation = state.get("generation")

    if do_spawn:
        spawn_resolver(session_id, spawn_generation)
    return 0


def main() -> int:
    argv = sys.argv[1:]
    try:
        if argv and argv[0] == "--resolve":
            session_id = argv[1] if len(argv) > 1 else ""
            # The nonce is an opaque string (uuid4 hex) compared for equality
            # as-is, without casting, so an old integer `generation` simply
            # never matches a new nonce instead of raising.
            generation: str | None = argv[2] if len(argv) > 2 else None
            if session_id:
                run_resolver(session_id, generation)
            return 0
        try:
            payload = json.load(sys.stdin)
        except Exception:
            return 0
        if not isinstance(payload, dict):
            return 0
        return _handle_event(payload)
    except Exception:
        return 0


if __name__ == "__main__":
    sys.exit(main())
