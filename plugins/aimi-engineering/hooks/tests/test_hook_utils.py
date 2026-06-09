from __future__ import annotations

import io
import json
import sys
from pathlib import Path

import pytest

# Insert the hooks directory onto sys.path so we can import hook_utils and
# friction_store directly (the parent dir name contains a hyphen, which is
# not a valid Python package identifier).
_HOOKS_DIR = Path(__file__).parent.parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

import friction_store  # noqa: E402
import hook_utils  # noqa: E402


# ---------------------------------------------------------------------------
# hook_utils tests
# ---------------------------------------------------------------------------


def test_safe_hook_swallows_and_exits_zero():
    """A handler that raises an exception must be swallowed and exit 0."""

    @hook_utils.safe_hook
    def bad_handler(tool_input: dict) -> None:
        raise RuntimeError("boom")

    with pytest.raises(SystemExit) as exc_info:
        bad_handler()

    assert exc_info.value.code == 0


def test_safe_json_input_returns_dict_on_valid(monkeypatch):
    """Valid JSON on stdin is parsed and returned as a dict."""
    payload = {"tool": "Bash", "input": {"command": "ls"}}
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))

    result = hook_utils.safe_json_input()

    assert result == payload


def test_safe_json_input_returns_empty_on_invalid(monkeypatch):
    """Invalid / empty stdin returns an empty dict."""
    monkeypatch.setattr("sys.stdin", io.StringIO("not json!!!"))

    result = hook_utils.safe_json_input()

    assert result == {}


def test_is_quiet_mode_default_false(tmp_path, monkeypatch):
    """When no .aimi/config.json exists the function returns False."""
    monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(tmp_path))

    assert hook_utils.is_quiet_mode() is False


def test_is_quiet_mode_reads_flag(tmp_path, monkeypatch):
    """When .aimi/config.json has quietMode=true the function returns True."""
    config_dir = tmp_path / ".aimi"
    config_dir.mkdir()
    (config_dir / "config.json").write_text(json.dumps({"quietMode": True}))

    monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(tmp_path))

    assert hook_utils.is_quiet_mode() is True


# ---------------------------------------------------------------------------
# friction_store tests
# ---------------------------------------------------------------------------


def test_friction_store_round_trip(tmp_path, monkeypatch):
    """append_event, pending_count, and read_pending work together correctly."""
    # Redirect the store to a temp directory so tests don't pollute ~/.aimi.
    fake_home = tmp_path / "home"
    fake_home.mkdir()

    # Patch the module-level _STORE_DIR which was evaluated at import time.
    store_dir = fake_home / ".aimi" / "learnings"
    monkeypatch.setattr(friction_store, "_STORE_DIR", store_dir)

    events = [
        {"type": "tool_use", "tool": "Bash"},
        {"type": "tool_use", "tool": "Read"},
        {"type": "session_end", "duration": 42},
    ]

    for ev in events:
        friction_store.append_event(ev)

    assert friction_store.pending_count() == 3

    collected = list(friction_store.read_pending())
    assert collected == events
