from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

HOOKS_DIR = Path(__file__).parent.parent
sys.path.insert(0, str(HOOKS_DIR))


def _load_dispatcher():
    """Import pre-bash-dispatcher as a module (hyphen in name)."""
    spec = importlib.util.spec_from_file_location(
        "pre_bash_dispatcher",
        HOOKS_DIR / "pre-bash-dispatcher.py",
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


dispatcher = _load_dispatcher()


def _run_handler(command: str, branch: str, extra_env: dict | None = None, cwd: str | None = None):
    """Helper: call handle_default_branch directly, mock subprocess, capture stdout."""
    tool_input: dict = {"command": command}
    if cwd:
        tool_input["cwd"] = cwd

    mock_proc = MagicMock()
    mock_proc.stdout = branch + "\n"
    mock_proc.returncode = 0

    env_patch = extra_env or {}

    captured = []

    def fake_print(s):
        captured.append(s)

    with (
        patch("subprocess.run", return_value=mock_proc),
        patch.dict("os.environ", env_patch, clear=False),
        patch("builtins.print", side_effect=fake_print),
    ):
        try:
            dispatcher.handle_default_branch(command, tool_input)
        except SystemExit:
            pass

    return captured


def test_blocks_commit_on_main():
    out = _run_handler("git commit -m 'msg'", "main")
    assert out, "Expected deny output"
    data = json.loads(out[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert "main" in data["hookSpecificOutput"]["userMessage"]


def test_blocks_commit_on_master():
    out = _run_handler("git commit -m 'msg'", "master")
    assert out
    data = json.loads(out[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert "master" in data["hookSpecificOutput"]["userMessage"]


def test_blocks_commit_on_develop():
    out = _run_handler("git commit -m 'msg'", "develop")
    assert out
    data = json.loads(out[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_deny_message_names_resolved_directory():
    """Issue #86: the denial must name the directory the branch was resolved from.

    Without this, an agent that lost a `cd` sees only the branch name and
    concludes the platform is blocking it, rather than that it committed from
    the wrong directory.
    """
    out = _run_handler("git commit -m 'msg'", "main", cwd="/repo/some-other-dir")
    assert out, "Expected deny output"
    data = json.loads(out[0])
    msg = data["hookSpecificOutput"]["userMessage"]
    assert "/repo/some-other-dir" in msg, f"Expected resolved directory in denial, got: {msg!r}"
    assert "feature worktree" in msg, "Worktree advice must still be present"


def test_allows_commit_on_feature_branch():
    out = _run_handler("git commit -m 'msg'", "feat/my-feature")
    assert not out, "Expected no output (allow)"


def test_parses_git_C_path():
    """command 'git -C /tmp/foo commit -m x' → cwd /tmp/foo"""
    cwd_used = []

    mock_proc = MagicMock()
    mock_proc.stdout = "feat/test\n"

    def fake_run(args, **kwargs):
        if "-C" in args:
            idx = args.index("-C")
            cwd_used.append(args[idx + 1])
        return mock_proc

    command = "git -C /tmp/foo commit -m x"
    tool_input = {"command": command}
    with (
        patch("subprocess.run", side_effect=fake_run),
        patch("builtins.print"),
    ):
        try:
            dispatcher.handle_default_branch(command, tool_input)
        except SystemExit:
            pass

    assert cwd_used and cwd_used[0] == "/tmp/foo"


def test_parses_cd_prefix():
    """command 'cd /tmp/foo && git commit -m x' → cwd /tmp/foo"""
    cwd_used = []

    mock_proc = MagicMock()
    mock_proc.stdout = "feat/test\n"

    def fake_run(args, **kwargs):
        if "-C" in args:
            idx = args.index("-C")
            cwd_used.append(args[idx + 1])
        return mock_proc

    command = "cd /tmp/foo && git commit -m x"
    tool_input = {"command": command}
    with (
        patch("subprocess.run", side_effect=fake_run),
        patch("builtins.print"),
    ):
        try:
            dispatcher.handle_default_branch(command, tool_input)
        except SystemExit:
            pass

    assert cwd_used and cwd_used[0] == "/tmp/foo"


def test_bypass_env_allows(monkeypatch):
    monkeypatch.setenv("AIMI_DEFAULT_BRANCH_GUARD", "off")
    out = _run_handler("git commit -m 'msg'", "main")
    assert not out, "Bypass env should allow"



# ---------------------------------------------------------------------------
# US-001: command-position anchoring (issue #82) — false-positive regressions
# ---------------------------------------------------------------------------

def test_grep_mention_of_git_commit_allows_silently():
    """A grep invocation that mentions the phrase must never be treated as a commit."""
    with (
        patch("subprocess.run") as mock_run,
        patch("builtins.print") as mock_print,
    ):
        try:
            dispatcher.handle_default_branch('grep -rn "git commit" file.txt', {"command": 'grep -rn "git commit" file.txt'})
        except SystemExit:
            pass
    mock_run.assert_not_called()
    mock_print.assert_not_called()


def test_echo_mention_of_git_commit_allows_silently():
    """An echo invocation that mentions the phrase must never be treated as a commit."""
    command = 'echo "remember to git commit later"'
    with (
        patch("subprocess.run") as mock_run,
        patch("builtins.print") as mock_print,
    ):
        try:
            dispatcher.handle_default_branch(command, {"command": command})
        except SystemExit:
            pass
    mock_run.assert_not_called()
    mock_print.assert_not_called()


def test_heredoc_body_mention_of_git_commit_allows_silently():
    """A heredoc body that mentions the phrase must never be treated as a commit."""
    command = "cat <<EOF\nremember to git commit\nEOF"
    with (
        patch("subprocess.run") as mock_run,
        patch("builtins.print") as mock_print,
    ):
        try:
            dispatcher.handle_default_branch(command, {"command": command})
        except SystemExit:
            pass
    mock_run.assert_not_called()
    mock_print.assert_not_called()


# ---------------------------------------------------------------------------
# US-001: command-position anchoring (issue #82) — true-positive regressions
# ---------------------------------------------------------------------------

def test_denies_cd_chained_commit_on_protected_branch():
    out = _run_handler("cd /repo && git commit -m x", "main")
    assert out, "Expected deny output"
    data = json.loads(out[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_denies_semicolon_chained_commit_on_protected_branch():
    out = _run_handler("git status; git commit -m x", "main")
    assert out, "Expected deny output"
    data = json.loads(out[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_denies_bare_git_C_commit_on_protected_branch():
    out = _run_handler("git -C /repo commit -m x", "main")
    assert out, "Expected deny output"
    data = json.loads(out[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_denies_quoted_path_git_C_commit_on_protected_branch():
    out = _run_handler('git -C "/path with spaces" commit -m x', "main")
    assert out, "Expected deny output"
    data = json.loads(out[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_denies_newline_separated_commit_on_protected_branch():
    out = _run_handler("cd /repo\ngit add -A\ngit commit -m x", "main")
    assert out, "Expected deny output"
    data = json.loads(out[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_denies_leading_whitespace_commit_on_protected_branch():
    out = _run_handler("   git commit -m x", "main")
    assert out, "Expected deny output"
    data = json.loads(out[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_custom_protected_branches_via_config(tmp_path):
    """tmp_path .aimi/config.json with extra branches in guards.protectedBranches"""
    aimi_dir = tmp_path / ".aimi"
    aimi_dir.mkdir()
    config = {"guards": {"protectedBranches": ["release", "staging"]}}
    (aimi_dir / "config.json").write_text(json.dumps(config))

    mock_proc = MagicMock()
    mock_proc.stdout = "release\n"
    captured = []

    command = "git commit -m x"
    tool_input = {"command": command, "cwd": str(tmp_path)}
    with (
        patch("subprocess.run", return_value=mock_proc),
        patch("builtins.print", side_effect=captured.append),
    ):
        try:
            dispatcher.handle_default_branch(command, tool_input)
        except SystemExit:
            pass

    assert captured
    data = json.loads(captured[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert "release" in data["hookSpecificOutput"]["userMessage"]


# ---------------------------------------------------------------------------
# Statement-prefix detection reaches the deny path (issue #82 follow-up)
# ---------------------------------------------------------------------------

def test_denies_env_prefixed_commit_on_protected_branch():
    """`GIT_AUTHOR_DATE=... git commit` is a real invocation, not a mention.

    1.119.1's anchoring rejected any token between the separator and `git`,
    so this shape -- the canonical way to backdate a commit -- stopped being
    guarded entirely, silently.
    """
    captured = _run_handler("GIT_AUTHOR_DATE=2020-01-01 git commit -m x", "main")
    assert captured, "Expected deny for an env-prefixed commit on a protected branch"
    data = json.loads(captured[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_denies_sudo_prefixed_commit_on_protected_branch():
    captured = _run_handler("sudo git commit -m x", "main")
    assert captured, "Expected deny for a sudo-prefixed commit on a protected branch"
    assert json.loads(captured[0])["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_denies_loop_body_commit_on_protected_branch():
    captured = _run_handler("for f in a b; do git commit -m $f; done", "main")
    assert captured, "Expected deny for a commit inside a loop body"
    assert json.loads(captured[0])["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_env_prefixed_mention_still_allows_on_protected_branch():
    """The prefix must not drag mentions back in -- issue #82 stays closed."""
    captured = _run_handler('echo "FOO=1 git commit"', "main")
    assert captured == [], f"Expected silent allow for a mention, got {captured}"
