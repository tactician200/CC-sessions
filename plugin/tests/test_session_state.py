"""Contract tests for plugin/scripts/session-state.py (state file v1 and its
status transitions).

Every run goes through a subprocess (like a real hook) with
CLAUDE_SESSIONS_STATE_DIR pointing at tmp_path and CLAUDE_CODE_ENTRYPOINT
unset, so SessionStart never launches the editor window resolver (that would
be a real subprocess calling `code --status` outside the test).
"""

import fcntl
import importlib.util
import json
import time
import os
import subprocess
import sys
from pathlib import Path

import pytest

PLUGIN = Path(__file__).resolve().parent.parent
HOOK = PLUGIN / "scripts" / "session-state.py"
HOOKS_JSON = PLUGIN / "hooks" / "hooks.json"
ENV = {
    "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
    "HOME": str(Path.home()),
}


def import_hook_module():
    """Loads session-state.py as a module (the dash in its name makes it not
    importable normally). Used by tests that call internals directly instead
    of going through a subprocess (resolver, atomic_write)."""
    spec = importlib.util.spec_from_file_location("session_state", HOOK)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.RESOLVE_BACKOFF_S = ()  # no retries with sleeps unless a test asks for them
    return mod


def run(tmp_path, payload) -> None:
    """Runs the hook with the given payload; asserts exit 0 and empty stdout."""
    out = subprocess.run(
        [sys.executable, str(HOOK)],
        input=json.dumps(payload),
        capture_output=True, text=True, timeout=15,
        env={**ENV, "CLAUDE_SESSIONS_STATE_DIR": str(tmp_path)},
    )
    assert out.returncode == 0
    assert out.stdout == ""


def run_raw(tmp_path, stdin_text: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(HOOK)],
        input=stdin_text,
        capture_output=True, text=True, timeout=15,
        env={**ENV, "CLAUDE_SESSIONS_STATE_DIR": str(tmp_path)},
    )


def state_file(tmp_path, session_id="s1") -> Path:
    return tmp_path / f"{session_id}.json"


def read_state(tmp_path, session_id="s1") -> dict:
    return json.loads(state_file(tmp_path, session_id).read_text())


def base(event, **extra):
    payload = {
        "hook_event_name": event,
        "session_id": "s1",
        "cwd": "/Users/alex/dev/acme-api",
        "transcript_path": "/tmp/t.jsonl",
    }
    payload.update(extra)
    return payload


# --- SessionStart --------------------------------------------------------

def test_session_start_sets_done_and_pids(tmp_path):
    run(tmp_path, base("SessionStart"))
    st = read_state(tmp_path)
    assert st["status"] == "done"
    assert st["working"] is False
    assert st["v"] == 1
    assert "started_at" in st
    assert "claude_pid" in st
    assert "host_pid" in st
    # Without CLAUDE_CODE_ENTRYPOINT there is no resolver: it must not block
    # nor leave a bogus window_dir behind.
    assert "window_dir" not in st or st["window_dir"] is None


def test_session_start_started_at_setdefault(tmp_path):
    run(tmp_path, base("SessionStart"))
    first = read_state(tmp_path)["started_at"]
    run(tmp_path, base("UserPromptSubmit", prompt="hello"))
    run(tmp_path, base("SessionStart"))
    second = read_state(tmp_path)["started_at"]
    assert first == second


# --- UserPromptSubmit -----------------------------------------------------

def test_user_prompt_submit_sets_working_and_prompt(tmp_path):
    run(tmp_path, base("UserPromptSubmit", prompt="summarize the changelog"))
    st = read_state(tmp_path)
    assert st["status"] == "working"
    assert st["working"] is True
    assert st["last_prompt"] == "summarize the changelog"
    assert "last_prompt_at" in st


# --- PreToolUse ------------------------------------------------------------

def test_pretooluse_ask_user_question_waits_pregunta(tmp_path):
    run(tmp_path, base("PreToolUse", tool_name="AskUserQuestion", tool_input={}))
    st = read_state(tmp_path)
    assert st["status"] == "waiting"
    assert st["working"] is False
    assert st["waiting_reason"] == "Pregunta"


def test_pretooluse_exit_plan_mode_waits_plan(tmp_path):
    run(tmp_path, base("PreToolUse", tool_name="ExitPlanMode", tool_input={}))
    st = read_state(tmp_path)
    assert st["status"] == "waiting"
    assert st["waiting_reason"] == "Plan por aprobar"


def test_pretooluse_other_tool_sets_working_and_activity(tmp_path):
    run(tmp_path, base(
        "PreToolUse", tool_name="Bash",
        tool_input={"command": "ls -la", "description": "list files"},
    ))
    st = read_state(tmp_path)
    assert st["status"] == "working"
    assert st["waiting_reason"] is None
    assert st["last_activity"] == "Bash: list files"
    assert st["last_tool"] == "Bash"
    assert "last_tool_at" in st


def test_pretooluse_bash_without_description_uses_command_prefix(tmp_path):
    run(tmp_path, base(
        "PreToolUse", tool_name="Bash",
        tool_input={"command": "x" * 200},
    ))
    st = read_state(tmp_path)
    assert st["last_activity"].startswith("Bash: " + "x" * 60)
    assert len(st["last_activity"]) <= 80


def test_pretooluse_edit_uses_basename(tmp_path):
    run(tmp_path, base(
        "PreToolUse", tool_name="Edit",
        tool_input={"file_path": "/Users/alex/dev/acme-api/app.py"},
    ))
    st = read_state(tmp_path)
    assert st["last_activity"] == "Edit: app.py"


def test_pretooluse_grep_uses_pattern(tmp_path):
    run(tmp_path, base(
        "PreToolUse", tool_name="Grep",
        tool_input={"pattern": "TODO"},
    ))
    st = read_state(tmp_path)
    assert st["last_activity"] == "Grep: TODO"


def test_pretooluse_task_uses_agent_description(tmp_path):
    run(tmp_path, base(
        "PreToolUse", tool_name="Task",
        tool_input={"description": "explore repo"},
    ))
    st = read_state(tmp_path)
    assert st["last_activity"] == "Agent: explore repo"


# --- PostToolUse -------------------------------------------------------------

def test_posttooluse_clears_waiting(tmp_path):
    run(tmp_path, base("PreToolUse", tool_name="AskUserQuestion", tool_input={}))
    before = read_state(tmp_path)
    assert before["status"] == "waiting"

    run(tmp_path, base("PostToolUse", tool_name="AskUserQuestion", tool_input={}))
    after = read_state(tmp_path)
    assert after["status"] == "working"
    assert after["working"] is True
    assert after["waiting_reason"] is None
    # waiting -> working, so status_since moves
    assert after["status_since"] != before["status_since"]


# --- Notification ------------------------------------------------------------

def test_notification_permission_prompt_extracts_tool(tmp_path):
    run(tmp_path, base(
        "Notification", notification_type="permission_prompt",
        message="Claude needs your permission to use Bash",
    ))
    st = read_state(tmp_path)
    assert st["status"] == "waiting"
    assert st["waiting_reason"] == "Permiso: Bash"


def test_notification_permission_via_message_text(tmp_path):
    run(tmp_path, base(
        "Notification", notification_type="",
        message="Claude needs your permission to use Write",
    ))
    st = read_state(tmp_path)
    assert st["status"] == "waiting"
    assert st["waiting_reason"] == "Permiso: Write"


def test_notification_elicitation_dialog_waits_pregunta(tmp_path):
    run(tmp_path, base(
        "Notification", notification_type="elicitation_dialog",
        message="need more details",
    ))
    st = read_state(tmp_path)
    assert st["status"] == "waiting"
    assert st["waiting_reason"] == "Pregunta"


def test_notification_idle_from_working_goes_waiting(tmp_path):
    run(tmp_path, base("UserPromptSubmit", prompt="continue"))
    run(tmp_path, base(
        "Notification", notification_type="idle_prompt",
        message="Claude is waiting for your input",
    ))
    st = read_state(tmp_path)
    assert st["status"] == "waiting"


def test_notification_idle_from_done_stays_done(tmp_path):
    run(tmp_path, base("Stop"))
    before = read_state(tmp_path)
    assert before["status"] == "done"

    run(tmp_path, base(
        "Notification", notification_type="idle_prompt",
        message="waiting for your input",
    ))
    after = read_state(tmp_path)
    assert after["status"] == "done"
    assert after["status_since"] == before["status_since"]


def test_notification_auth_success_is_ignored(tmp_path):
    run(tmp_path, base("Stop"))
    before = state_file(tmp_path).read_text()

    run(tmp_path, base("Notification", notification_type="auth_success", message="ok"))
    after = state_file(tmp_path).read_text()
    assert before == after


def test_notification_auth_success_without_prior_state_creates_no_file(tmp_path):
    run(tmp_path, base("Notification", notification_type="auth_success", message="ok", session_id="fresh"))
    assert not state_file(tmp_path, "fresh").exists()


def test_notification_unknown_waits_with_truncated_message(tmp_path):
    run(tmp_path, base(
        "Notification", notification_type="something_new",
        message="some unmapped message",
    ))
    st = read_state(tmp_path)
    assert st["status"] == "waiting"
    assert st["waiting_reason"] == "some unmapped message"


# --- Stop / SubagentStop / SessionEnd ---------------------------------------

def test_stop_sets_done(tmp_path):
    run(tmp_path, base("UserPromptSubmit", prompt="anything"))
    run(tmp_path, base("Stop"))
    st = read_state(tmp_path)
    assert st["status"] == "done"
    assert st["working"] is False
    assert st["waiting_reason"] is None


def test_subagent_stop_only_touches_updated_at(tmp_path):
    run(tmp_path, base("UserPromptSubmit", prompt="anything"))
    before = read_state(tmp_path)

    run(tmp_path, base("SubagentStop"))
    after = read_state(tmp_path)

    assert after["status"] == before["status"]
    assert after["status_since"] == before["status_since"]
    assert after["waiting_reason"] == before["waiting_reason"]
    assert after["updated_at"] >= before["updated_at"]


def test_session_end_deletes_file(tmp_path):
    run(tmp_path, base("SessionStart"))
    assert state_file(tmp_path).exists()
    run(tmp_path, base("SessionEnd"))
    assert not state_file(tmp_path).exists()


# --- status_since invariant ---------------------------------------------------

def test_status_since_unchanged_when_status_repeats(tmp_path):
    run(tmp_path, base("PreToolUse", tool_name="Bash", tool_input={"command": "ls"}))
    first = read_state(tmp_path)["status_since"]

    run(tmp_path, base("PreToolUse", tool_name="Read", tool_input={"file_path": "/x/y.md"}))
    second = read_state(tmp_path)["status_since"]

    assert first == second  # still working -> working, status_since untouched


# --- truncation ---------------------------------------------------------------

def test_last_prompt_truncated_to_120_single_line(tmp_path):
    long_prompt = ("line one\nwith a break\n" + "a" * 200)
    run(tmp_path, base("UserPromptSubmit", prompt=long_prompt))
    st = read_state(tmp_path)
    assert len(st["last_prompt"]) <= 120
    assert "\n" not in st["last_prompt"]


def test_last_activity_truncated_to_80(tmp_path):
    run(tmp_path, base(
        "PreToolUse", tool_name="Bash",
        tool_input={"description": "d" * 200},
    ))
    st = read_state(tmp_path)
    assert len(st["last_activity"]) <= 80
    assert "\n" not in st["last_activity"]


# --- malformed / edge input -----------------------------------------------

def test_malformed_stdin_exits_0_no_file(tmp_path):
    out = run_raw(tmp_path, "{not valid json")
    assert out.returncode == 0
    assert out.stdout == ""
    assert not any(tmp_path.glob("*.json"))


def test_missing_session_id_exits_0_no_file(tmp_path):
    payload = {"hook_event_name": "UserPromptSubmit", "prompt": "hello"}
    out = run_raw(tmp_path, json.dumps(payload))
    assert out.returncode == 0
    assert out.stdout == ""
    assert not any(tmp_path.glob("*.json"))


def test_missing_event_exits_0_no_file(tmp_path):
    payload = {"session_id": "s1"}
    out = run_raw(tmp_path, json.dumps(payload))
    assert out.returncode == 0
    assert not any(tmp_path.glob("*.json"))


def test_empty_stdin_exits_0(tmp_path):
    out = run_raw(tmp_path, "")
    assert out.returncode == 0
    assert out.stdout == ""


def test_adopts_session_without_sessionstart(tmp_path):
    """A session opened before the hook was installed: the first prompt computes the pids once."""
    sid = "adopt-1"
    run(tmp_path, {"hook_event_name": "PreToolUse", "session_id": sid, "cwd": "/tmp", "tool_name": "Read", "tool_input": {"file_path": "/tmp/x.md"}})
    assert "claude_pid" not in read_state(tmp_path, sid)
    run(tmp_path, {"hook_event_name": "UserPromptSubmit", "session_id": sid, "cwd": "/tmp", "prompt": "hello"})
    state = read_state(tmp_path, sid)
    assert "claude_pid" in state and "host_pid" in state
    assert state["status"] == "working"


def test_injected_notification_does_not_replace_last_prompt(tmp_path):
    sid = "inj-1"
    run(tmp_path, {"hook_event_name": "UserPromptSubmit", "session_id": sid, "cwd": "/tmp", "prompt": "fix the sidebar"})
    run(tmp_path, {"hook_event_name": "UserPromptSubmit", "session_id": sid, "cwd": "/tmp", "prompt": "<task-notification> <task-id>x</task-id>"})
    state = read_state(tmp_path, sid)
    assert state["last_prompt"] == "fix the sidebar"
    assert state["status"] == "working"


def test_turn_started_at_moves_on_every_prompt_including_injected(tmp_path):
    """The app measures holds from the start of the turn: a harness notice also
    opens a turn, even though it does not touch last_prompt_at."""
    sid = "turn-1"
    run(tmp_path, {"hook_event_name": "UserPromptSubmit", "session_id": sid, "cwd": "/tmp", "prompt": "hello"})
    first = read_state(tmp_path, sid)
    time.sleep(0.01)
    run(tmp_path, {"hook_event_name": "UserPromptSubmit", "session_id": sid, "cwd": "/tmp", "prompt": "<task-notification>x"})
    second = read_state(tmp_path, sid)
    assert second["last_prompt_at"] == first["last_prompt_at"]
    assert second["turn_started_at"] > first["turn_started_at"]


def test_workspace_folder_for_picks_vscode_registry(tmp_path):
    """The 'acme-api' window, with the session cwd in a sibling folder, is found in workspaceStorage."""
    mod = import_hook_module()
    folder = tmp_path / "projects" / "acme-api"
    folder.mkdir(parents=True)
    store = tmp_path / "ws"
    for name, target in (("a", folder), ("b", tmp_path / "other")):
        (store / name).mkdir(parents=True)
        (store / name / "workspace.json").write_text(json.dumps({"folder": "file://" + str(target).replace(" ", "%20")}))
    assert mod.workspace_folder_for("acme-api", store) == str(folder)
    assert mod.workspace_folder_for("nothing", store) is None


# --- atomic_write temp file suffix -------------------------------------------

def test_atomic_write_tmp_suffix_is_not_json(tmp_path, monkeypatch):
    """The atomic_write temp file must NOT end in .json: the app scans
    STATE_DIR/*.json and could open the file while half-written."""
    mod = import_hook_module()
    captured = {}
    orig_replace = mod.os.replace

    def fake_replace(src, dst):
        captured["tmp"] = str(src)
        orig_replace(src, dst)

    monkeypatch.setattr(mod.os, "replace", fake_replace)
    target = tmp_path / "s1.json"
    mod.atomic_write(target, {"a": 1})

    assert captured.get("tmp"), "atomic_write did not call os.replace"
    assert not captured["tmp"].endswith(".json")
    assert json.loads(target.read_text()) == {"a": 1}
    # no temp file may be left behind
    leftovers = [p for p in tmp_path.iterdir() if p.name != "s1.json"]
    assert leftovers == []


# --- lock + resolver merge never overwrites newer state ----------------------

def test_resolver_merge_preserves_newer_status(tmp_path, monkeypatch):
    """The resolver was launched with generation=1; while it resolved the
    window, the hook wrote "waiting" (e.g. a permission prompt). The resolver
    merge may only touch window_root/window_dir/resolve_at."""
    mod = import_hook_module()
    monkeypatch.setattr(mod, "STATE_DIR", tmp_path)
    sid = "res-1"
    path = tmp_path / f"{sid}.json"
    path.write_text(json.dumps({
        "v": 1, "session_id": sid, "cwd": "/tmp", "status": "waiting",
        "waiting_reason": "Permiso: Bash", "generation": 1, "host_pid": None,
    }))

    mod.run_resolver(sid, 1)

    st = json.loads(path.read_text())
    assert st["status"] == "waiting"
    assert st["waiting_reason"] == "Permiso: Bash"


def test_resolver_discards_stale_generation(tmp_path, monkeypatch):
    """The resolver was launched for generation=1, but a new SessionStart
    moved the generation to 2 meanwhile: the result is stale and must not be
    merged."""
    mod = import_hook_module()
    monkeypatch.setattr(mod, "STATE_DIR", tmp_path)
    sid = "res-2"
    path = tmp_path / f"{sid}.json"
    path.write_text(json.dumps({
        "v": 1, "session_id": sid, "cwd": "/tmp", "status": "done",
        "generation": 2, "host_pid": None, "window_dir": None,
    }))

    mod.run_resolver(sid, 1)

    st = json.loads(path.read_text())
    assert st.get("window_dir") is None
    assert "resolve_at" not in st or st.get("resolve_at") is None


# --- waiting_on gates leaving "waiting" by tool_use_id ------------------------
# (correlated by tool NAME, not "every running tool")

def test_permission_wait_correlates_by_tool_name_not_every_running_tool(tmp_path):
    """Slow Bash (slow) + Write asking for permission: finishing Write clears
    the wait even though Bash keeps running; the wait does NOT include Bash."""
    sid = "perm-1"

    def ev(event, **extra):
        payload = {"hook_event_name": event, "session_id": sid, "cwd": "/tmp"}
        payload.update(extra)
        return payload

    run(tmp_path, ev("PreToolUse", tool_name="Bash", tool_input={"command": "sleep 5"}, tool_use_id="slow"))
    run(tmp_path, ev("PreToolUse", tool_name="Write", tool_input={"file_path": "/tmp/x"}, tool_use_id="w1"))
    run(tmp_path, ev(
        "Notification", notification_type="permission_prompt",
        message="Claude needs your permission to use Write",
    ))
    st = read_state(tmp_path, sid)
    assert st["status"] == "waiting"
    assert st["waiting_on"] == ["w1"]  # NOT "slow": Bash did not ask for permission

    run(tmp_path, ev("PostToolUse", tool_name="Write", tool_use_id="w1"))
    st = read_state(tmp_path, sid)
    assert st["status"] == "working"  # resolved even though "slow" is still pending
    assert st["waiting_on"] is None


def test_permission_wait_multiple_ids_same_tool_name(tmp_path):
    """Two parallel Writes + a permission for "Write": both ids are waited on."""
    sid = "perm-2"

    def ev(event, **extra):
        payload = {"hook_event_name": event, "session_id": sid, "cwd": "/tmp"}
        payload.update(extra)
        return payload

    run(tmp_path, ev("PreToolUse", tool_name="Write", tool_input={"file_path": "/tmp/a"}, tool_use_id="w1"))
    run(tmp_path, ev("PreToolUse", tool_name="Write", tool_input={"file_path": "/tmp/b"}, tool_use_id="w2"))
    run(tmp_path, ev(
        "Notification", notification_type="permission_prompt",
        message="Claude needs your permission to use Write",
    ))
    st = read_state(tmp_path, sid)
    assert set(st["waiting_on"]) == {"w1", "w2"}

    run(tmp_path, ev("PostToolUse", tool_name="Write", tool_use_id="w1"))
    st = read_state(tmp_path, sid)
    assert st["status"] == "waiting"
    assert st["waiting_on"] == ["w2"]

    run(tmp_path, ev("PostToolUse", tool_name="Write", tool_use_id="w2"))
    st = read_state(tmp_path, sid)
    assert st["status"] == "working"
    assert st["waiting_on"] is None


def test_unparseable_notification_waits_unknown_cleared_by_next_posttooluse(tmp_path):
    """When the tool cannot be parsed/matched from the message the wait uses
    the "?" sentinel, and ANY PostToolUse/Failure clears it, not only the one
    from the "right" tool."""
    sid = "unk-1"
    run(tmp_path, {
        "hook_event_name": "PreToolUse", "session_id": sid, "cwd": "/tmp",
        "tool_name": "Bash", "tool_input": {"command": "x"}, "tool_use_id": "b1",
    })
    run(tmp_path, {
        "hook_event_name": "Notification", "session_id": sid, "cwd": "/tmp",
        "notification_type": "something_new", "message": "some unmapped message",
    })
    st = read_state(tmp_path, sid)
    assert st["status"] == "waiting"
    assert st["waiting_on"] == ["?"]

    run(tmp_path, {
        "hook_event_name": "PostToolUse", "session_id": sid, "cwd": "/tmp",
        "tool_name": "Bash", "tool_use_id": "b1",
    })
    st = read_state(tmp_path, sid)
    assert st["status"] == "working"
    assert st["waiting_on"] is None


def test_permission_tool_name_no_match_falls_back_to_unknown(tmp_path):
    """The message names a tool that is not in pending_tools (already finished,
    or never registered): a wait with no identified tool, not an empty set."""
    sid = "perm-3"
    run(tmp_path, {
        "hook_event_name": "PreToolUse", "session_id": sid, "cwd": "/tmp",
        "tool_name": "Bash", "tool_input": {"command": "x"}, "tool_use_id": "b1",
    })
    run(tmp_path, {
        "hook_event_name": "Notification", "session_id": sid, "cwd": "/tmp",
        "notification_type": "permission_prompt",
        "message": "Claude needs your permission to use Write",
    })
    st = read_state(tmp_path, sid)
    assert st["status"] == "waiting"
    assert st["waiting_on"] == ["?"]


def test_posttooluse_failure_clears_waiting(tmp_path):
    sid = "fail-1"
    run(tmp_path, {
        "hook_event_name": "PreToolUse", "session_id": sid, "cwd": "/tmp",
        "tool_name": "Bash", "tool_input": {"command": "x"}, "tool_use_id": "f1",
    })
    run(tmp_path, {
        "hook_event_name": "Notification", "session_id": sid, "cwd": "/tmp",
        "notification_type": "permission_prompt",
        "message": "Claude needs your permission to use Bash",
    })
    st = read_state(tmp_path, sid)
    assert st["status"] == "waiting"
    assert st["waiting_on"] == ["f1"]

    run(tmp_path, {
        "hook_event_name": "PostToolUseFailure", "session_id": sid, "cwd": "/tmp",
        "tool_name": "Bash", "tool_use_id": "f1",
    })
    st = read_state(tmp_path, sid)
    assert st["status"] == "working"
    assert st["waiting_on"] is None


def test_asuserquestion_waiting_cleared_by_own_posttooluse_with_id(tmp_path):
    """AskUserQuestion is still cleared by its own PostToolUse now that the
    mechanism goes through waiting_on."""
    run(tmp_path, base(
        "PreToolUse", tool_name="AskUserQuestion", tool_input={}, tool_use_id="q1",
    ))
    before = read_state(tmp_path)
    assert before["status"] == "waiting"
    assert before["waiting_on"] == ["q1"]

    run(tmp_path, base("PostToolUse", tool_name="AskUserQuestion", tool_input={}, tool_use_id="q1"))
    after = read_state(tmp_path)
    assert after["status"] == "working"
    assert after["waiting_on"] is None


# --- an ordinary PreToolUse does not clear a pending wait --------------------

def test_askuserquestion_survives_parallel_pretooluse(tmp_path):
    """AskUserQuestion(q1) pending; a parallel PreToolUse for Read(r1) arrives:
    bookkeeping (last_activity) updates but the session KEEPS waiting on q1
    instead of switching to "working"."""
    sid = "q-par-1"
    run(tmp_path, {
        "hook_event_name": "PreToolUse", "session_id": sid, "cwd": "/tmp",
        "tool_name": "AskUserQuestion", "tool_input": {}, "tool_use_id": "q1",
    })
    st = read_state(tmp_path, sid)
    assert st["status"] == "waiting"
    assert st["waiting_on"] == ["q1"]

    run(tmp_path, {
        "hook_event_name": "PreToolUse", "session_id": sid, "cwd": "/tmp",
        "tool_name": "Read", "tool_input": {"file_path": "/tmp/x.md"}, "tool_use_id": "r1",
    })
    st = read_state(tmp_path, sid)
    assert st["status"] == "waiting"  # still waiting for the question
    assert st["waiting_on"] == ["q1"]
    assert st["last_activity"] == "Read: x.md"  # ordinary bookkeeping still updates

    run(tmp_path, {
        "hook_event_name": "PostToolUse", "session_id": sid, "cwd": "/tmp",
        "tool_name": "AskUserQuestion", "tool_use_id": "q1",
    })
    st = read_state(tmp_path, sid)
    assert st["status"] == "working"
    assert st["waiting_on"] is None


def test_exitplanmode_unions_with_existing_wait(tmp_path):
    """Two interactive tools in parallel (edge case): they are joined in
    waiting_on instead of the second one replacing the first."""
    sid = "union-1"
    run(tmp_path, {
        "hook_event_name": "PreToolUse", "session_id": sid, "cwd": "/tmp",
        "tool_name": "AskUserQuestion", "tool_input": {}, "tool_use_id": "q1",
    })
    run(tmp_path, {
        "hook_event_name": "PreToolUse", "session_id": sid, "cwd": "/tmp",
        "tool_name": "ExitPlanMode", "tool_input": {}, "tool_use_id": "p1",
    })
    st = read_state(tmp_path, sid)
    assert st["status"] == "waiting"
    assert set(st["waiting_on"]) == {"q1", "p1"}


# --- SessionStart with a stale pid recomputes identity ----------------------

def test_session_start_stale_identity_clears_window(tmp_path):
    sid = "stale-1"
    path = state_file(tmp_path, sid)
    path.write_text(json.dumps({
        "v": 1, "session_id": sid, "cwd": "/tmp", "status": "done",
        "claude_pid": 999999, "host_pid": 888888,
        "window_root": "acme-api", "window_dir": "/tmp/acme-api",
        "generation": "old-nonce", "started_at": 1000.0,
    }))

    run(tmp_path, base("SessionStart", session_id=sid, cwd="/tmp"))

    st = read_state(tmp_path, sid)
    assert st["claude_pid"] != 999999  # recomputed: the old pid was a dead sentinel
    assert st.get("window_dir") is None
    assert st.get("window_root") is None
    assert st["started_at"] == 1000.0  # preserved
    # per-life nonce (uuid4 hex), not an integer counter
    assert isinstance(st["generation"], str) and st["generation"] != "old-nonce"


def test_session_start_fresh_session_no_identity_change(tmp_path):
    """A new session (no previous claude_pid) does not trigger the "identity
    changed" logic: nothing to clear, but it still gets a nonce."""
    run(tmp_path, base("SessionStart"))
    st = read_state(tmp_path)
    assert st["status"] == "done"
    assert isinstance(st["generation"], str) and st["generation"]


# --- a failed identity probe also invalidates the window --------------------

def test_session_start_failed_probes_still_clears_window(tmp_path, monkeypatch):
    """When BOTH probes (claude_pid, host_pid) fail (None), the old window is
    still invalidated: an unverified identity must not stay "protected" by a
    failed probe. pending_tools/waiting_on are reset too (new session life)."""
    mod = import_hook_module()
    monkeypatch.setattr(mod, "STATE_DIR", tmp_path)
    monkeypatch.setattr(mod, "compute_claude_pid", lambda *a, **k: None)
    monkeypatch.setattr(mod, "compute_host_pid", lambda *a, **k: None)
    monkeypatch.setattr(mod, "spawn_resolver", lambda *a, **k: None)
    monkeypatch.delenv("CLAUDE_CODE_ENTRYPOINT", raising=False)

    sid = "failed-probe-1"
    path = tmp_path / f"{sid}.json"
    path.write_text(json.dumps({
        "v": 1, "session_id": sid, "cwd": "/tmp", "status": "done",
        "claude_pid": 12345, "host_pid": 23456,
        "window_root": "acme-api", "window_dir": "/tmp/acme-api",
        "generation": "old-nonce", "started_at": 1000.0,
        "pending_tools": {"x1": "Bash"}, "waiting_on": ["x1"],
    }))

    rc = mod._handle_event({"hook_event_name": "SessionStart", "session_id": sid, "cwd": "/tmp"})
    assert rc == 0

    st = json.loads(path.read_text())
    assert st["claude_pid"] is None
    assert st["host_pid"] is None
    assert st.get("window_dir") is None
    assert st.get("window_root") is None
    assert st["generation"] != "old-nonce"
    assert st["pending_tools"] == {}
    assert st["waiting_on"] is None


# --- lock not acquired -> no mutation ----------------------------------------

def test_lock_not_acquired_leaves_file_unchanged(tmp_path):
    """If the lock is not obtained within the timeout, the hook exits without
    reading, writing or deleting: it never mutates without the lock."""
    sid = "locked-1"
    run(tmp_path, base("UserPromptSubmit", session_id=sid, prompt="before"))
    before = state_file(tmp_path, sid).read_text()

    lock_path = tmp_path / f"{sid}.lock"
    fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o644)
    fcntl.flock(fd, fcntl.LOCK_EX)  # the test holds the lock during the invocation
    try:
        out = run_raw(tmp_path, json.dumps(base("UserPromptSubmit", session_id=sid, prompt="during")))
        assert out.returncode == 0
        assert out.stdout == ""
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)

    after = state_file(tmp_path, sid).read_text()
    assert after == before  # nothing changed while the lock was held


# --- the per-life nonce survives delete/recreate -----------------------------

def test_resolver_nonce_survives_delete_recreate(tmp_path):
    """With an integer counter, deleting (SessionEnd) and recreating
    (SessionStart) the same session could reset the generation to the same
    value and an old resolver would overwrite new data. A uuid4 nonce does
    not collide."""
    sid = "nonce-1"
    run(tmp_path, base("SessionStart", session_id=sid, cwd="/tmp"))
    old_generation = read_state(tmp_path, sid)["generation"]
    assert isinstance(old_generation, str) and old_generation

    run(tmp_path, base("SessionEnd", session_id=sid))
    assert not state_file(tmp_path, sid).exists()

    run(tmp_path, base("SessionStart", session_id=sid, cwd="/tmp"))
    new_generation = read_state(tmp_path, sid)["generation"]
    assert new_generation != old_generation

    mod = import_hook_module()
    mod.STATE_DIR = tmp_path
    mod.run_resolver(sid, old_generation)  # resolution from the previous life: stale

    st = read_state(tmp_path, sid)
    assert st["generation"] == new_generation  # not overwritten by the old result


# --- waits resolved from the transcript --------------------------------------

def _transcript(tmp_path, *results) -> str:
    """Minimal transcript: one assistant line + one tool_result per (id, is_error)."""
    path = tmp_path / "transcript.jsonl"
    lines = [json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "hello"}]}})]
    for tid, is_error in results:
        lines.append(json.dumps({"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": tid, "is_error": is_error, "content": "x"}]}}))
    path.write_text("\n".join(lines) + "\n")
    return str(path)


def _ev(sid, transcript, event, **extra):
    payload = {"hook_event_name": event, "session_id": sid, "cwd": "/tmp", "transcript_path": transcript}
    payload.update(extra)
    return payload


def test_failed_permission_tool_without_failure_event_unsticks_on_next_tool(tmp_path):
    """An approved Bash that fails without PostToolUseFailure: the next tool
    sees its tool_result (is_error) in the transcript and returns to working."""
    t = str(tmp_path / "transcript.jsonl")
    _transcript(tmp_path)
    run(tmp_path, _ev("pa", t, "PreToolUse", tool_name="Bash", tool_input={"command": "false"}, tool_use_id="b1"))
    run(tmp_path, _ev("pa", t, "Notification", notification_type="permission_prompt",
                      message="Claude needs your permission to use Bash"))
    assert read_state(tmp_path, "pa")["waiting_on"] == ["b1"]

    _transcript(tmp_path, ("b1", True))  # Bash finished with an error; the event never arrived
    run(tmp_path, _ev("pa", t, "PreToolUse", tool_name="Read", tool_input={"file_path": "/a"}, tool_use_id="r1"))
    st = read_state(tmp_path, "pa")
    assert st["status"] == "working"
    assert st["waiting_on"] is None
    assert st["last_activity"].startswith("Read")


def test_rejected_plan_unsticks_on_next_tool(tmp_path):
    t = _transcript(tmp_path)
    run(tmp_path, _ev("pb", t, "PreToolUse", tool_name="ExitPlanMode", tool_use_id="p1"))
    assert read_state(tmp_path, "pb")["status"] == "waiting"
    _transcript(tmp_path, ("p1", True))  # plan rejected
    run(tmp_path, _ev("pb", t, "PreToolUse", tool_name="Grep", tool_input={"pattern": "x"}, tool_use_id="g1"))
    st = read_state(tmp_path, "pb")
    assert st["status"] == "working"
    assert st["waiting_on"] is None


def test_live_wait_without_tool_result_is_kept(tmp_path):
    """A real wait (no tool_result) is NOT released when another tool runs and
    finishes, even if the transcript holds results for OTHER ids."""
    t = _transcript(tmp_path, ("r0", False))
    run(tmp_path, _ev("pc", t, "PreToolUse", tool_name="AskUserQuestion", tool_use_id="q1"))
    run(tmp_path, _ev("pc", t, "PreToolUse", tool_name="Read", tool_input={"file_path": "/a"}, tool_use_id="r1"))
    _transcript(tmp_path, ("r0", False), ("r1", False))
    run(tmp_path, _ev("pc", t, "PostToolUse", tool_name="Read", tool_use_id="r1"))
    st = read_state(tmp_path, "pc")
    assert st["status"] == "waiting"
    assert st["waiting_on"] == ["q1"]


def test_partial_resolution_keeps_other_waits(tmp_path):
    t = _transcript(tmp_path)
    run(tmp_path, _ev("pd", t, "PreToolUse", tool_name="AskUserQuestion", tool_use_id="q1"))
    run(tmp_path, _ev("pd", t, "PreToolUse", tool_name="ExitPlanMode", tool_use_id="p1"))
    _transcript(tmp_path, ("p1", True))
    run(tmp_path, _ev("pd", t, "PreToolUse", tool_name="Read", tool_input={"file_path": "/a"}, tool_use_id="r1"))
    st = read_state(tmp_path, "pd")
    assert st["status"] == "waiting"
    assert st["waiting_on"] == ["q1"]


def test_resolved_wait_ids_tolerates_missing_and_truncated_transcript(tmp_path):
    mod = import_hook_module()
    assert mod.resolved_wait_ids(str(tmp_path / "nope.jsonl"), ["a"]) == set()
    assert mod.resolved_wait_ids(None, ["a"]) == set()
    p = tmp_path / "t.jsonl"
    good = json.dumps({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "a"}]}})
    p.write_text('"tool_result" "a" {broken\n' + good + "\n")
    assert mod.resolved_wait_ids(str(p), ["a", "?"]) == {"a"}


def test_hooks_json_registers_post_tool_use_failure():
    """The PostToolUseFailure handler is useless unless the plugin registers
    the event and points it at the launcher."""
    hooks = json.loads(HOOKS_JSON.read_text())["hooks"]
    blocks = hooks.get("PostToolUseFailure", [])
    commands = [h.get("command", "") for b in blocks for h in b.get("hooks", [])]
    assert any(c.endswith("/scripts/run-hook.sh") for c in commands)


# --- notifications and the sentinel never drop known waits -------------------

def test_permission_notification_merges_with_pending_question(tmp_path):
    t = _transcript(tmp_path)
    run(tmp_path, _ev("m1", t, "PreToolUse", tool_name="AskUserQuestion", tool_use_id="q1"))
    run(tmp_path, _ev("m1", t, "PreToolUse", tool_name="Write", tool_input={"file_path": "/x"}, tool_use_id="w1"))
    run(tmp_path, _ev("m1", t, "Notification", notification_type="permission_prompt",
                      message="Claude needs your permission to use Write"))
    assert read_state(tmp_path, "m1")["waiting_on"] == ["q1", "w1"]
    run(tmp_path, _ev("m1", t, "PostToolUse", tool_name="Write", tool_use_id="w1"))
    st = read_state(tmp_path, "m1")
    assert st["status"] == "waiting"
    assert st["waiting_on"] == ["q1"]
    assert st["waiting_reason"] == "Pregunta"  # does not stay on "Permiso: Write"


def test_idle_notification_merges_with_pending_question(tmp_path):
    t = _transcript(tmp_path)
    run(tmp_path, _ev("m2", t, "PreToolUse", tool_name="AskUserQuestion", tool_use_id="q1"))
    run(tmp_path, _ev("m2", t, "Notification", notification_type="idle_prompt",
                      message="Claude is waiting for your input"))
    st = read_state(tmp_path, "m2")
    assert st["status"] == "waiting"
    assert "q1" in st["waiting_on"]


@pytest.mark.parametrize("post_event", ["PostToolUse", "PostToolUseFailure"])
def test_unknown_sentinel_does_not_clear_known_wait(tmp_path, post_event):
    t = _transcript(tmp_path)
    run(tmp_path, _ev("m3", t, "PreToolUse", tool_name="Read", tool_input={"file_path": "/a"}, tool_use_id="r1"))
    run(tmp_path, _ev("m3", t, "Notification", notification_type="permission_prompt",
                      message="Claude needs your permission to use fs - write (MCP)"))
    run(tmp_path, _ev("m3", t, "PreToolUse", tool_name="AskUserQuestion", tool_use_id="q2"))
    assert read_state(tmp_path, "m3")["waiting_on"] == ["?", "q2"]
    run(tmp_path, _ev("m3", t, post_event, tool_name="Read", tool_use_id="r1"))
    st = read_state(tmp_path, "m3")
    assert st["status"] == "waiting"
    assert st["waiting_on"] == ["q2"]
    assert st["waiting_reason"] == "Pregunta"


def test_unknown_sentinel_alone_still_clears_on_any_post(tmp_path):
    t = _transcript(tmp_path)
    run(tmp_path, _ev("m4", t, "PreToolUse", tool_name="Read", tool_input={"file_path": "/a"}, tool_use_id="r1"))
    run(tmp_path, _ev("m4", t, "Notification", notification_type="permission_prompt",
                      message="Claude needs your permission to use fs - write (MCP)"))
    run(tmp_path, _ev("m4", t, "PostToolUse", tool_name="Read", tool_use_id="r1"))
    st = read_state(tmp_path, "m4")
    assert st["status"] == "working"
    assert st["waiting_on"] is None


# --- window from the claude process cwd ---------------------------------------

STATUS_SAMPLE = """Workspace Stats:
|  Window (◆ Release checklist — Billing dashboard draft…)
|  Window (Meeting notes and follow… — acme-api)
|    Folder (demo-web): more than 20000 files
|      File types: ts(7986)
|    Folder (acme-api): 11404 files
"""


def test_open_folder_names_parses_status():
    mod = import_hook_module()
    assert mod.open_folder_names(STATUS_SAMPLE) == {"demo-web", "acme-api"}


def _resolver_env(tmp_path, mod, proc_dir, status=STATUS_SAMPLE, title_root=None, known=None):
    mod.STATE_DIR = tmp_path
    mod.process_cwd = lambda pid: proc_dir
    mod.code_status_text = lambda: status
    # Full paths the editor knows (workspaceStorage). Defaults to proc_dir
    # itself, for tests that only exercise the basename.
    mod.known_folder_paths = lambda: set(known) if known is not None else ({proc_dir} if proc_dir else set())
    mod.root_name_for = lambda host: title_root


def test_resolver_uses_claude_process_cwd_when_title_lies(tmp_path):
    """Window title without the folder name (active tab title containing '—'):
    window_dir must still come from the claude process cwd."""
    folder = tmp_path / "demo-web"
    folder.mkdir()
    sid = "win-1"
    run(tmp_path, base("SessionStart", session_id=sid, cwd=str(folder / "sub")))
    mod = import_hook_module()
    _resolver_env(tmp_path, mod, str(folder), title_root="Billing dashboard draft…")
    st = read_state(tmp_path, sid)
    st["claude_pid"], st["host_pid"] = 4242, 4343
    state_file(tmp_path, sid).write_text(json.dumps(st))
    mod.run_resolver(sid, st["generation"])
    st = read_state(tmp_path, sid)
    assert st["window_dir"] == str(folder)
    assert st["window_root"] == "demo-web"


def test_resolver_rejects_process_cwd_not_open_as_window(tmp_path):
    """A cwd that is not an open folder is NOT used (code <dir> would open another window)."""
    stray = tmp_path / "scratch"
    stray.mkdir()
    sid = "win-2"
    run(tmp_path, base("SessionStart", session_id=sid, cwd=str(stray)))
    mod = import_hook_module()
    _resolver_env(tmp_path, mod, str(stray), title_root=None)
    st = read_state(tmp_path, sid)
    st["claude_pid"] = 4242
    state_file(tmp_path, sid).write_text(json.dumps(st))
    mod.run_resolver(sid, st["generation"])
    assert not read_state(tmp_path, sid).get("window_dir")


def test_resolver_falls_back_to_title_when_process_gone(tmp_path):
    folder = tmp_path / "widget-lab"
    folder.mkdir()
    sid = "win-3"
    run(tmp_path, base("SessionStart", session_id=sid, cwd=str(folder)))
    mod = import_hook_module()
    _resolver_env(tmp_path, mod, None, title_root="widget-lab")
    st = read_state(tmp_path, sid)
    st["host_pid"] = 4343
    state_file(tmp_path, sid).write_text(json.dumps(st))
    mod.run_resolver(sid, st["generation"])
    assert read_state(tmp_path, sid)["window_dir"] == str(folder)


def test_resolver_rejects_same_basename_different_path(tmp_path):
    """Checkout .../wt/demo-web while ANOTHER 'demo-web' folder is open: the
    basename matches `code --status`, but the full path is not a folder the
    editor knows, so code <dir> would open a new window. Not used."""
    real = tmp_path / "projects" / "demo-web"
    real.mkdir(parents=True)
    wt = tmp_path / "wt" / "demo-web"
    wt.mkdir(parents=True)
    sid = "win-4"
    run(tmp_path, base("SessionStart", session_id=sid, cwd=str(wt)))
    mod = import_hook_module()
    _resolver_env(tmp_path, mod, str(wt), title_root=None, known={str(real)})
    st = read_state(tmp_path, sid)
    st["claude_pid"] = 4242
    state_file(tmp_path, sid).write_text(json.dumps(st))
    mod.run_resolver(sid, st["generation"])
    assert not read_state(tmp_path, sid).get("window_dir")


def test_resolver_accepts_full_path_match(tmp_path):
    real = tmp_path / "projects" / "demo-web"
    real.mkdir(parents=True)
    sid = "win-5"
    run(tmp_path, base("SessionStart", session_id=sid, cwd=str(real)))
    mod = import_hook_module()
    _resolver_env(tmp_path, mod, str(real), title_root=None, known={str(real)})
    st = read_state(tmp_path, sid)
    st["claude_pid"] = 4242
    state_file(tmp_path, sid).write_text(json.dumps(st))
    mod.run_resolver(sid, st["generation"])
    assert read_state(tmp_path, sid)["window_dir"] == str(real)


def test_proc_dir_is_open_window_and_known_paths(tmp_path):
    """Pure check + real workspaceStorage enumeration (including a resolved symlink)."""
    mod = import_hook_module()
    real = tmp_path / "projects" / "demo-web"
    real.mkdir(parents=True)
    store = tmp_path / "ws"
    (store / "a").mkdir(parents=True)
    (store / "a" / "workspace.json").write_text(json.dumps({"folder": "file://" + str(real)}))
    (store / "b").mkdir()
    (store / "b" / "workspace.json").write_text(json.dumps({"folder": "file://" + str(tmp_path / "gone")}))
    known = mod.known_folder_paths(store)
    assert str(real) in known and str(tmp_path / "gone") not in known
    names = {"demo-web"}
    assert mod.proc_dir_is_open_window(str(real), names, known)
    assert not mod.proc_dir_is_open_window(str(tmp_path / "wt" / "demo-web"), names, known)
    assert not mod.proc_dir_is_open_window(str(real), {"other"}, known)   # basename not open
    assert not mod.proc_dir_is_open_window("", names, known)
    # symlink with the same basename resolving to the known folder: accepted
    alias = tmp_path / "alias" / "demo-web"
    alias.parent.mkdir()
    alias.symlink_to(real)
    assert mod.proc_dir_is_open_window(str(alias), names, known)


# --- a new tab whose window is not resolvable yet ----------------------------

def test_resolver_retries_until_window_appears(tmp_path):
    """The window is not listed on the first attempt (freshly opened tab):
    the resolver retries in the same process and finds it."""
    folder = tmp_path / "demo-web"
    folder.mkdir()
    sid = "retry-1"
    run(tmp_path, base("SessionStart", session_id=sid, cwd=str(folder)))
    mod = import_hook_module()
    _resolver_env(tmp_path, mod, str(folder), title_root=None)
    answers = iter([None, None, str(folder)])
    mod.process_cwd = lambda pid: next(answers)
    sleeps = []
    mod.RESOLVE_BACKOFF_S = (3, 10, 30)
    mod._resolver_sleep = sleeps.append
    st = read_state(tmp_path, sid)
    st["claude_pid"], st["host_pid"] = 4242, None
    state_file(tmp_path, sid).write_text(json.dumps(st))
    mod.run_resolver(sid, st["generation"])
    st = read_state(tmp_path, sid)
    assert st["window_dir"] == str(folder)
    assert sleeps == [3, 10]


def test_resolver_retry_stops_when_identity_changes(tmp_path):
    """Another SessionStart happened during the wait: the old resolver does not write."""
    sid = "retry-2"
    run(tmp_path, base("SessionStart", session_id=sid, cwd="/tmp"))
    mod = import_hook_module()
    _resolver_env(tmp_path, mod, None, title_root=None)
    st = read_state(tmp_path, sid)
    old_gen = st["generation"]

    def new_life(_delay):
        cur = read_state(tmp_path, sid)
        cur["generation"] = "another-life"
        state_file(tmp_path, sid).write_text(json.dumps(cur))
    mod.RESOLVE_BACKOFF_S = (1,)
    mod._resolver_sleep = new_life
    mod.run_resolver(sid, old_gen)
    st = read_state(tmp_path, sid)
    assert st["generation"] == "another-life"
    assert st.get("resolve_at") is None


def test_prompt_retries_resolution_without_host_pid(tmp_path, monkeypatch):
    """Without host_pid (failed probe) but with claude_pid, the retry still
    runs; requiring host_pid would leave the session without a window forever."""
    mod = import_hook_module()
    monkeypatch.setattr(mod, "STATE_DIR", tmp_path)
    spawned = []
    monkeypatch.setattr(mod, "spawn_resolver", lambda sid, gen: spawned.append(sid))
    sid = "retry-3"
    (tmp_path / f"{sid}.json").write_text(json.dumps({
        "v": 1, "session_id": sid, "cwd": "/tmp", "status": "done",
        "entrypoint": "claude-vscode", "claude_pid": 17071, "host_pid": None,
        "generation": "g", "resolve_at": 1000.0, "started_at": 1000.0,
    }))
    assert mod._handle_event({"hook_event_name": "UserPromptSubmit", "session_id": sid,
                              "cwd": "/tmp", "prompt": "hello"}) == 0
    assert spawned == [sid]


# --- editor profiles -----------------------------------------------------------

def test_editor_profiles_only_vscode_enabled():
    """Only verified editor profiles ship enabled; the VS Code entrypoint is
    the one that triggers window resolution."""
    mod = import_hook_module()
    enabled = [k for k, p in mod.EDITOR_PROFILES.items() if p.get("enabled")]
    assert enabled == ["vscode"]
    assert mod.is_editor_entrypoint("claude-vscode")
    assert not mod.is_editor_entrypoint("cli")
    assert not mod.is_editor_entrypoint(None)
    assert mod.CODE_CLI == mod.EDITOR_PROFILES["vscode"]["cli"]


def test_hook_does_not_import_external_helpers():
    """The vendored hook is self-contained: no sibling-file loading."""
    src = HOOK.read_text()
    assert "importlib" not in src
    assert "desktop-notify" not in src
