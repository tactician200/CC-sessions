# claude-sessions-state

Claude Code plugin that feeds the [Claude Sessions menu bar app](../README.md).
On every hook event it writes a small JSON file per session to
`~/.claude/sessions-state/<session_id>.json` (atomic write, deleted on
`SessionEnd`) with the session status: `working`, `waiting` (question, plan
approval or permission prompt) or `done`, plus the last prompt, the last tool
activity and, for VS Code sessions, the editor window that owns the session.

## Events

`SessionStart`, `SessionEnd`, `UserPromptSubmit`, `Notification`, `Stop`,
`SubagentStop`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`.

## Install

```text
/plugin marketplace add tactician200/CC-sessions
/plugin install claude-sessions-state@cc-sessions
```

Hooks are global: every new Claude Code session starts reporting its state.

## Requirements

- macOS.
- Python 3.9 or newer. `scripts/run-hook.sh` looks for Homebrew, python.org,
  the Xcode Command Line Tools Python and `python3` on `PATH`, and caches the
  first one that works. If none is usable it writes
  `~/.claude/sessions-state/.hook-unavailable` (the app shows a notice) and
  exits silently; Claude Code is never affected.

Hook errors, if any, go to `~/.claude/sessions-state/.hook.log`.

## Privacy

Everything stays on your Mac. The state file holds metadata only: session id,
working directory, status, timestamps, tool names, a one-line summary of the
last tool call and the first 120 characters of the last prompt.

## Uninstall

```text
/plugin uninstall claude-sessions-state@cc-sessions
```

Leftover state files can be removed with `rm -rf ~/.claude/sessions-state`.

## Tests

```bash
python3 -m pytest -q plugin/tests
```
