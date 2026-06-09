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
import scope_classifier  # noqa: E402


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
# load_aimi_config tests
# ---------------------------------------------------------------------------


def test_load_aimi_config_returns_empty_when_missing(tmp_path, monkeypatch):
    """Returns {} when no .aimi/config.json exists."""
    monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(tmp_path))
    assert hook_utils.load_aimi_config() == {}


def test_load_aimi_config_returns_parsed_dict(tmp_path, monkeypatch):
    """Returns the parsed dict when config is valid JSON."""
    config_dir = tmp_path / ".aimi"
    config_dir.mkdir()
    data = {"quietMode": True, "telemetry": {"enabled": False}}
    (config_dir / "config.json").write_text(json.dumps(data))
    monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(tmp_path))
    assert hook_utils.load_aimi_config() == data


def test_load_aimi_config_returns_empty_on_bad_json(tmp_path, monkeypatch):
    """Returns {} when config.json contains invalid JSON."""
    config_dir = tmp_path / ".aimi"
    config_dir.mkdir()
    (config_dir / "config.json").write_text("not valid json {{")
    monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(tmp_path))
    assert hook_utils.load_aimi_config() == {}


def test_load_aimi_config_walks_up(tmp_path, monkeypatch):
    """Finds config.json by walking up from a nested directory."""
    config_dir = tmp_path / ".aimi"
    config_dir.mkdir()
    data = {"quietMode": True}
    (config_dir / "config.json").write_text(json.dumps(data))
    # start from a nested dir that doesn't have its own .aimi
    nested = tmp_path / "sub" / "deep"
    nested.mkdir(parents=True)
    result = hook_utils.load_aimi_config(start=nested)
    assert result == data


# ---------------------------------------------------------------------------
# effective_cwd tests
# ---------------------------------------------------------------------------


def test_effective_cwd_git_dash_c():
    """Parses `git -C <path>` from command string."""
    import os
    result = hook_utils.effective_cwd("git -C /tmp/foo commit -m 'msg'", {})
    assert result == os.path.abspath(os.path.expanduser("/tmp/foo"))


def test_effective_cwd_cd_prefix():
    """Parses `cd <path> &&` from command string."""
    import os
    result = hook_utils.effective_cwd("cd /tmp/bar && git commit -m 'x'", {})
    assert result == os.path.abspath(os.path.expanduser("/tmp/bar"))


def test_effective_cwd_tool_input_cwd():
    """Falls back to tool_input['cwd'] when no pattern matches."""
    import os
    result = hook_utils.effective_cwd("git commit -m 'x'", {"cwd": "/tmp/baz"})
    assert result == os.path.abspath(os.path.expanduser("/tmp/baz"))


def test_effective_cwd_fallback_getcwd(monkeypatch):
    """Falls back to os.getcwd() when nothing else matches."""
    import os
    monkeypatch.chdir("/tmp")
    result = hook_utils.effective_cwd("echo hello", {})
    assert result == os.getcwd()


# ---------------------------------------------------------------------------
# resolve_session_id tests
# ---------------------------------------------------------------------------


def test_resolve_session_id_from_tool_input():
    """Returns session_id from tool_input when present."""
    result = hook_utils.resolve_session_id({"session_id": "abc123"})
    assert result == "abc123"


def test_resolve_session_id_from_env(monkeypatch):
    """Returns CLAUDE_SESSION_ID from environment when tool_input lacks it."""
    monkeypatch.setenv("CLAUDE_SESSION_ID", "env-session")
    result = hook_utils.resolve_session_id({})
    assert result == "env-session"


def test_resolve_session_id_default(monkeypatch):
    """Returns 'default' when neither tool_input nor env has the value."""
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    result = hook_utils.resolve_session_id({})
    assert result == "default"


def test_resolve_session_id_tool_input_takes_precedence(monkeypatch):
    """tool_input.session_id wins over CLAUDE_SESSION_ID."""
    monkeypatch.setenv("CLAUDE_SESSION_ID", "env-session")
    result = hook_utils.resolve_session_id({"session_id": "tool-session"})
    assert result == "tool-session"


# ---------------------------------------------------------------------------
# find_aimi_dir tests
# ---------------------------------------------------------------------------


def test_find_aimi_dir_returns_none_when_missing(tmp_path):
    """Returns None when no .aimi directory exists."""
    result = hook_utils.find_aimi_dir(tmp_path)
    assert result is None


def test_find_aimi_dir_finds_at_start(tmp_path):
    """Returns the .aimi directory when it exists at the start path."""
    aimi = tmp_path / ".aimi"
    aimi.mkdir()
    result = hook_utils.find_aimi_dir(tmp_path)
    assert result == aimi


def test_find_aimi_dir_walks_up(tmp_path):
    """Finds .aimi directory by walking up from a nested path."""
    aimi = tmp_path / ".aimi"
    aimi.mkdir()
    nested = tmp_path / "sub" / "deep"
    nested.mkdir(parents=True)
    result = hook_utils.find_aimi_dir(nested)
    assert result == aimi


# ---------------------------------------------------------------------------
# deny tests
# ---------------------------------------------------------------------------


def test_deny_returns_canonical_json():
    """Returns well-formed hookSpecificOutput deny JSON."""
    msg = "You shall not pass."
    result = hook_utils.deny(msg)
    parsed = json.loads(result)
    assert parsed["hookSpecificOutput"]["hookEventName"] == "PreToolUse"
    assert parsed["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert parsed["hookSpecificOutput"]["userMessage"] == msg


def test_deny_custom_event_name():
    """Accepts a custom event_name."""
    result = hook_utils.deny("msg", event_name="PostToolUse")
    parsed = json.loads(result)
    assert parsed["hookSpecificOutput"]["hookEventName"] == "PostToolUse"


# ---------------------------------------------------------------------------
# friction_store tests
# ---------------------------------------------------------------------------


def test_scope_return_type_annotation():
    """classify_scope return annotation is Literal['project', 'plugin', 'inbox']."""
    import typing
    from typing import Literal, get_args, get_type_hints
    # Use get_type_hints to resolve string annotations (from __future__ import annotations)
    hints = get_type_hints(scope_classifier.classify_scope)
    ann = hints.get("return")
    assert ann is not None, "classify_scope must have a return annotation"
    # The annotation should be Literal["project", "plugin", "inbox"]
    assert hasattr(ann, "__args__"), "return annotation must be a Literal type"
    assert set(get_args(ann)) == {"project", "plugin", "inbox"}


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
