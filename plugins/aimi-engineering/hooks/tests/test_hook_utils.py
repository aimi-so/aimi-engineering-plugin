from __future__ import annotations

import io
import json
import sys
from pathlib import Path

import pytest

# Insert the hooks directory onto sys.path so we can import hook_utils
# directly (the parent dir name contains a hyphen, which is
# not a valid Python package identifier).
_HOOKS_DIR = Path(__file__).parent.parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

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
    data = {"guards": {"protectedBranches": ["release"]}}
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
    data = {"guards": {}}
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


@pytest.mark.parametrize(
    "command,expected",
    [
        ('git -C "/tmp/foo" commit -m x', "/tmp/foo"),
        ("git -C '/tmp/foo' commit -m x", "/tmp/foo"),
        ('git -C "/tmp/with space" commit -m x', "/tmp/with space"),
        ("git -C '/tmp/with space' commit -m x", "/tmp/with space"),
        ('git -C "/tmp/foo" worktree add /tmp/w', "/tmp/foo"),
        ('cd "/tmp/with space" && git commit -m x', "/tmp/with space"),
        ("cd '/tmp/with space' && git commit -m x", "/tmp/with space"),
    ],
)
def test_effective_cwd_resolves_quoted_paths(command, expected):
    """Quoted paths resolve to the real directory, quotes stripped.

    A bare `\\S+` capture keeps the opening quote and stops at the first space
    inside it. The resulting path is one no git invocation can use, so
    `git rev-parse` fails, the branch reads as empty, and the protected-branch
    guard allows a commit it was supposed to block. These shapes are all
    detected by pre-bash-dispatcher's regexes, so they must be resolvable here.
    """
    import os
    result = hook_utils.effective_cwd(command, {})
    assert result == os.path.abspath(os.path.expanduser(expected))


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
# A `cd` prefix is honoured whichever way the command chains
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "command",
    [
        "cd /tmp/bar && git commit -m 'x'",
        "cd /tmp/bar ; git commit -m 'x'",
        "cd /tmp/bar\ngit commit -m 'x'",
        "cd /tmp/bar\ngit add -A\ngit commit -m 'x'",
    ],
)
def test_effective_cwd_honours_cd_in_every_chaining_form(command):
    """`cd <path>` opens the same directory however the command chains.

    bash reads `&&`, `;` and a newline as three spellings of one sequence, so a
    command that starts `cd <path>` has said where it means to run in all three.
    Matching only `&&` sent the other two to the tool_input fallback below.
    """
    import os

    assert hook_utils.effective_cwd(command, {}) == os.path.abspath("/tmp/bar")


@pytest.mark.parametrize(
    "command",
    [
        "cd /tmp/protected && git commit -m 'x'",
        "cd /tmp/protected ; git commit -m 'x'",
        "cd /tmp/protected\ngit commit -m 'x'",
    ],
)
def test_effective_cwd_cd_target_outranks_the_session_cwd(command):
    """A declared `cd` target beats the session's own directory, in every form.

    This is the shape the protected-branch guard depends on. The two disagree
    exactly when it matters: the session sits in a feature worktree while the
    command cd's into a checkout on the default branch. Falling back to
    tool_input['cwd'] there reads the FEATURE branch, finds it allowed, and lets
    the commit land on the protected branch the guard exists to defend -- the
    same fail-open ending `test_effective_cwd_resolves_quoted_paths` describes
    for unstripped quotes, reached through the separator instead.
    """
    import os

    resolved = hook_utils.effective_cwd(command, {"cwd": "/tmp/feature-worktree"})
    assert resolved == os.path.abspath("/tmp/protected")


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


def test_deny_includes_top_level_system_message():
    """Carries the message in a top-level systemMessage, the field Claude Code reads."""
    msg = "You shall not pass."
    parsed = json.loads(hook_utils.deny(msg))
    assert parsed["systemMessage"] == msg


# ---------------------------------------------------------------------------
# SCHEMA_VERSIONS tests
# ---------------------------------------------------------------------------


def test_schema_versions_contains_3_3():
    """SCHEMA_VERSIONS must include '3.3'."""
    assert "3.3" in hook_utils.SCHEMA_VERSIONS


def test_schema_versions_rejects_unknown():
    """SCHEMA_VERSIONS must not include arbitrary version strings."""
    assert "1.0" not in hook_utils.SCHEMA_VERSIONS
    assert "99.0" not in hook_utils.SCHEMA_VERSIONS
