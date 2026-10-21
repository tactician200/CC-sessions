"""The event-parity checker passes on the shipped plugin and fails on drift."""

import json
import subprocess
import sys
from pathlib import Path

PLUGIN = Path(__file__).resolve().parent.parent
CHECKER = PLUGIN.parent / "tests" / "check_hook_events.py"
HOOKS_JSON = PLUGIN / "hooks" / "hooks.json"
HOOK = PLUGIN / "scripts" / "session-state.py"


def check(hooks_json: Path, hook: Path) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(CHECKER), str(hooks_json), str(hook)],
                          capture_output=True, text=True, timeout=15)


def test_shipped_plugin_matches():
    out = check(HOOKS_JSON, HOOK)
    assert out.returncode == 0, out.stdout
    assert out.stdout.strip() == "OK 9 == 9"


def test_missing_registration_fails(tmp_path):
    doc = json.loads(HOOKS_JSON.read_text())
    del doc["hooks"]["PostToolUseFailure"]
    p = tmp_path / "hooks.json"
    p.write_text(json.dumps(doc))
    out = check(p, HOOK)
    assert out.returncode == 1
    assert "dispatched but not registered: PostToolUseFailure" in out.stdout


def test_extra_registration_fails(tmp_path):
    doc = json.loads(HOOKS_JSON.read_text())
    doc["hooks"]["PreCompact"] = doc["hooks"]["Stop"]
    p = tmp_path / "hooks.json"
    p.write_text(json.dumps(doc))
    out = check(p, HOOK)
    assert out.returncode == 1
    assert "registered but not dispatched: PreCompact" in out.stdout
