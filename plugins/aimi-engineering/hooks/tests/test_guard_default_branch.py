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
