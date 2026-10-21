"""Tests for plugin/scripts/run-hook.sh, the interpreter-picking launcher.

Every run uses a temporary CLAUDE_SESSIONS_STATE_DIR and an explicit
CS_PY_CANDIDATES list, so nothing touches the real ~/.claude.
"""

import json
import os
import stat
import subprocess
import sys
from pathlib import Path

import pytest

PLUGIN = Path(__file__).resolve().parent.parent
LAUNCHER = PLUGIN / "scripts" / "run-hook.sh"
REAL_PY = sys.executable

PAYLOAD = json.dumps({
    "hook_event_name": "PreToolUse",
    "session_id": "launcher-1",
    "cwd": "/Users/alex/dev/demo-web",
    "tool_name": "Read",
    "tool_input": {"file_path": "/Users/alex/dev/demo-web/index.ts"},
    "tool_use_id": "toolu_demo_01",
}) + "\n"


def make_exe(path: Path, body: str) -> str:
    path.write_text(body)
    path.chmod(0o755)
    return str(path)


def fake_exit69(tmp_path: Path) -> str:
    """Stand-in for the system python3 stub when the Xcode license is not accepted."""
    return make_exe(tmp_path / "fake-python-exit69", "#!/bin/sh\nexit 69\n")


def wrapper(tmp_path: Path, name="py-wrapper", run_exit=None) -> str:
    """A working interpreter that records every call. Probes (`-c ...`) are
    logged as "probe"; real runs are logged as "run" and their stdin is
    appended to <name>.stdin before being forwarded to the real Python
    (or, with run_exit, swallowed and answered with that exit code)."""
    log = tmp_path / f"{name}.calls"
    cap = tmp_path / f"{name}.stdin"
    if run_exit is None:
        tail = f'tee -a "{cap}" | "{REAL_PY}" "$@"\n'
    else:
        tail = f'cat >> "{cap}"\nexit {run_exit}\n'
    body = (
        "#!/bin/sh\n"
        f'if [ "$1" = "-c" ]; then echo probe >> "{log}"; exec "{REAL_PY}" "$@"; fi\n'
        f'echo run >> "{log}"\n' + tail
    )
    return make_exe(tmp_path / name, body)


def calls(tmp_path: Path, name="py-wrapper") -> list:
    p = tmp_path / f"{name}.calls"
    return p.read_text().split() if p.exists() else []


def captured(tmp_path: Path, name="py-wrapper") -> str:
    p = tmp_path / f"{name}.stdin"
    return p.read_text() if p.exists() else ""


@pytest.fixture
def state_dir(tmp_path):
    d = tmp_path / "state"
    d.mkdir()
    return d


def launch(tmp_path, state_dir, candidates, stdin=PAYLOAD, via_bash=True):
    home = tmp_path / "home"
    home.mkdir(exist_ok=True)
    env = {
        "PATH": "/usr/bin:/bin",
        "HOME": str(home),
        "CLAUDE_SESSIONS_STATE_DIR": str(state_dir),
        "CS_PY_CANDIDATES": candidates,
    }
    argv = ["/bin/bash", str(LAUNCHER)] if via_bash else [str(LAUNCHER)]
    return subprocess.run(argv, input=stdin, capture_output=True, text=True, timeout=30, env=env)


def assert_silent_ok(out):
    assert out.returncode == 0
    assert out.stdout == ""
    assert out.stderr == ""


def test_launcher_is_executable():
    assert os.stat(LAUNCHER).st_mode & stat.S_IXUSR


@pytest.mark.parametrize("via_bash", [True, False])
def test_no_interpreter_writes_marker_and_stays_silent(tmp_path, state_dir, via_bash):
    out = launch(tmp_path, state_dir, "/nonexistent", via_bash=via_bash)
    assert_silent_ok(out)
    assert (state_dir / ".hook-unavailable").exists()
    assert not list(state_dir.glob("*.json"))


def test_no_interpreter_with_empty_stdin(tmp_path, state_dir):
    out = launch(tmp_path, state_dir, "/nonexistent", stdin="")
    assert_silent_ok(out)
    assert (state_dir / ".hook-unavailable").exists()


def test_broken_interpreter_exit69_is_discarded(tmp_path, state_dir):
    out = launch(tmp_path, state_dir, fake_exit69(tmp_path))
    assert_silent_ok(out)
    assert (state_dir / ".hook-unavailable").exists()
    assert not (state_dir / ".python").exists()
    assert not list(state_dir.glob("*.json"))


def test_valid_interpreter_runs_hook_once_and_clears_marker(tmp_path, state_dir):
    (state_dir / ".hook-unavailable").write_text("")
    py = wrapper(tmp_path)
    out = launch(tmp_path, state_dir, py)
    assert_silent_ok(out)
    assert not (state_dir / ".hook-unavailable").exists()
    assert (state_dir / ".python").read_text().strip() == py
    assert calls(tmp_path).count("run") == 1
    assert captured(tmp_path) == PAYLOAD  # stdin delivered exactly once, byte for byte
    st = json.loads((state_dir / "launcher-1.json").read_text())
    assert st["status"] == "working"
    assert st["last_activity"] == "Read: index.ts"


def test_skips_bad_candidates_before_valid_one(tmp_path, state_dir):
    py = wrapper(tmp_path)
    out = launch(tmp_path, state_dir, f"/nonexistent {fake_exit69(tmp_path)} {py}")
    assert_silent_ok(out)
    assert calls(tmp_path).count("run") == 1
    assert captured(tmp_path) == PAYLOAD
    assert (state_dir / "launcher-1.json").exists()
    assert not (state_dir / ".hook-unavailable").exists()


def test_broken_cached_interpreter_is_reprobed(tmp_path, state_dir):
    (state_dir / ".python").write_text(fake_exit69(tmp_path) + "\n")
    py = wrapper(tmp_path)
    out = launch(tmp_path, state_dir, py)
    assert_silent_ok(out)
    assert (state_dir / ".python").read_text().strip() == py
    assert calls(tmp_path).count("run") == 1
    assert (state_dir / "launcher-1.json").exists()


def test_cached_interpreter_is_preferred(tmp_path, state_dir):
    cached = wrapper(tmp_path, "cached-py")
    other = wrapper(tmp_path, "other-py")
    (state_dir / ".python").write_text(cached + "\n")
    out = launch(tmp_path, state_dir, other)
    assert_silent_ok(out)
    assert calls(tmp_path, "cached-py").count("run") == 1
    assert calls(tmp_path, "other-py") == []


def test_stub_exit69_on_real_run_resends_to_next_candidate(tmp_path, state_dir):
    """Passes the probe but the real run exits 69 (the stub refused to start,
    so the hook never ran): the event goes to the next interpreter, once."""
    stub = wrapper(tmp_path, "stub-py", run_exit=69)
    py = wrapper(tmp_path)
    out = launch(tmp_path, state_dir, f"{stub} {py}")
    assert_silent_ok(out)
    assert calls(tmp_path).count("run") == 1
    assert captured(tmp_path) == PAYLOAD
    assert (state_dir / ".python").read_text().strip() == py


def test_never_resends_after_hook_ran(tmp_path, state_dir):
    """Any other failure after the hook started is final: the event is not
    sent to a second interpreter (it could be applied twice)."""
    failing = wrapper(tmp_path, "failing-py", run_exit=1)
    py = wrapper(tmp_path)
    out = launch(tmp_path, state_dir, f"{failing} {py}")
    assert_silent_ok(out)
    assert calls(tmp_path, "failing-py").count("run") == 1
    assert captured(tmp_path, "failing-py") == PAYLOAD
    assert calls(tmp_path) == []
    assert not (state_dir / ".hook-unavailable").exists()


def test_hook_stderr_goes_to_log_not_terminal(tmp_path, state_dir):
    noisy = make_exe(
        tmp_path / "noisy-py",
        "#!/bin/sh\n"
        f'if [ "$1" = "-c" ]; then exec "{REAL_PY}" "$@"; fi\n'
        "cat >/dev/null\necho 'traceback here' >&2\necho 'stdout noise'\nexit 1\n",
    )
    out = launch(tmp_path, state_dir, noisy)
    assert_silent_ok(out)
    assert "traceback here" in (state_dir / ".hook.log").read_text()


def test_oversized_log_is_reset(tmp_path, state_dir):
    log = state_dir / ".hook.log"
    log.write_text("x" * (300 * 1024))
    out = launch(tmp_path, state_dir, wrapper(tmp_path))
    assert_silent_ok(out)
    assert log.stat().st_size < 256 * 1024


def test_creates_missing_state_dir(tmp_path):
    state_dir = tmp_path / "does" / "not" / "exist"
    out = launch(tmp_path, state_dir, "/nonexistent")
    assert_silent_ok(out)
    assert (state_dir / ".hook-unavailable").exists()
