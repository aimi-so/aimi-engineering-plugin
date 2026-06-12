from __future__ import annotations

import importlib.util
import io
import json
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch, call

import pytest

_HOOKS_DIR = Path(__file__).parent.parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))


def _load_dispatcher():
    spec = importlib.util.spec_from_file_location(
        "pre_bash_dispatcher",
        _HOOKS_DIR / "pre-bash-dispatcher.py",
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


dispatcher = _load_dispatcher()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _run_dispatcher(command: str, extra_env: dict | None = None, cwd: str | None = None):
    """Feed the full hook event JSON via stdin, run dispatcher.main(), capture output."""
    inner: dict = {"command": command}
    if cwd:
        inner["cwd"] = cwd
    # Full Claude Code hook event envelope: {"tool_input": {...}}
    event = {"tool_input": inner}
    stdin_data = json.dumps(event)

    captured = []
    env_patch = extra_env or {}

    with (
        patch("sys.stdin", io.StringIO(stdin_data)),
        patch.dict("os.environ", env_patch, clear=False),
        patch("builtins.print", side_effect=captured.append),
        patch("subprocess.run", return_value=_mock_proc("feat/test")),
    ):
        try:
            dispatcher.main()
        except SystemExit:
            pass

    return captured


def _mock_proc(branch: str = "feat/test"):
    p = MagicMock()
    p.stdout = branch + "\n"
    p.returncode = 0
    return p


# ---------------------------------------------------------------------------
# Routing tests
# ---------------------------------------------------------------------------

def test_dispatcher_routes_git_commit_to_default_branch_handler():
    """git commit on a protected branch → default-branch handler fires → deny."""
    inner = {"command": "git commit -m 'x'", "cwd": "/tmp"}
    event = {"tool_input": inner}
    stdin_data = json.dumps(event)

    mock_proc = _mock_proc("main")  # protected branch
    captured = []

    with (
        patch("sys.stdin", io.StringIO(stdin_data)),
        patch("subprocess.run", return_value=mock_proc),
        patch("builtins.print", side_effect=captured.append),
    ):
        try:
            dispatcher.main()
        except SystemExit:
            pass

    assert captured, "Expected deny from default-branch handler"
    data = json.loads(captured[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert "main" in data["hookSpecificOutput"]["userMessage"]


def test_dispatcher_routes_git_commit_to_shell_true_handler():
    """git commit with shell=True staged file → shell-true handler fires → deny."""
    inner = {"command": "git commit -m 'x'", "cwd": "/tmp"}
    event = {"tool_input": inner}
    stdin_data = json.dumps(event)

    blob = "subprocess.run('ls', shell=True)\n"

    def fake_run(args, **kwargs):
        mock = MagicMock()
        mock.returncode = 0
        if "rev-parse" in args:
            # default-branch check: feature branch → allow
            mock.stdout = "feat/test\n"
        elif "diff" in args and "--cached" in args:
            mock.stdout = "foo.py\n"
        elif "show" in args:
            mock.stdout = blob
        else:
            mock.stdout = ""
        return mock

    captured = []

    with (
        patch("sys.stdin", io.StringIO(stdin_data)),
        patch("subprocess.run", side_effect=fake_run),
        patch("builtins.print", side_effect=captured.append),
    ):
        try:
            dispatcher.main()
        except SystemExit:
            pass

    assert captured, "Expected deny from shell-true handler"
    data = json.loads(captured[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert "foo.py" in data["hookSpecificOutput"]["userMessage"]


def test_dispatcher_routes_git_worktree_add_to_budget_handler(tmp_path, monkeypatch):
    """git worktree add when budget exhausted → worktree-budget handler fires → deny."""
    # Set up .aimi/tasks
    tasks_dir = tmp_path / ".aimi" / "tasks"
    tasks_dir.mkdir(parents=True)
    data = {
        "schemaVersion": "3.3",
        "metadata": {"title": "T", "type": "feature", "branchName": "feat/x", "maxConcurrency": 2},
        "userStories": [],
    }
    (tasks_dir / "2026-06-09-test-tasks.json").write_text(json.dumps(data))

    monkeypatch.chdir(tmp_path)
    monkeypatch.delenv("AIMI_WORKTREE_BUDGET_GUARD", raising=False)

    # Simulate 2 active worktrees (= budget exhausted at max=2)
    def fake_run(args, **kwargs):
        if "worktree" in args and "list" in args:
            output = (
                f"worktree {tmp_path}\nHEAD aaaa\nbranch refs/heads/main\n\n"
                f"worktree {tmp_path}/wt1\nHEAD bbbb\nbranch refs/heads/feat/wt1\n\n"
                f"worktree {tmp_path}/wt2\nHEAD cccc\nbranch refs/heads/feat/wt2\n"
            )
            return MagicMock(returncode=0, stdout=output)
        return MagicMock(returncode=0, stdout="")

    inner = {"command": "git worktree add ../new-wt feat/y", "cwd": str(tmp_path)}
    event = {"tool_input": inner}
    stdin_data = json.dumps(event)

    captured = []

    with (
        patch("sys.stdin", io.StringIO(stdin_data)),
        patch("subprocess.run", side_effect=fake_run),
        patch("builtins.print", side_effect=captured.append),
    ):
        try:
            dispatcher.main()
        except SystemExit:
            pass

    assert captured, "Expected deny from worktree-budget handler"
    deny_data = json.loads(captured[0])
    assert deny_data["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert "2/2" in deny_data["hookSpecificOutput"]["userMessage"]


def test_dispatcher_silent_allow_on_unrelated_command():
    """ls -la → no handler fires → silent allow (no output, exit 0)."""
    inner = {"command": "ls -la"}
    event = {"tool_input": inner}
    stdin_data = json.dumps(event)

    captured = []

    with (
        patch("sys.stdin", io.StringIO(stdin_data)),
        patch("builtins.print", side_effect=captured.append),
    ):
        try:
            dispatcher.main()
        except SystemExit:
            pass

    assert not captured, "Expected no output for unrelated command"


def test_dispatcher_chains_handlers_in_order_for_commit():
    """For git commit: default-branch runs first, then shell-true.

    When default-branch allows (feature branch), shell-true still runs.
    When default-branch denies (protected branch), shell-true does NOT run
    because the process exits after the first deny.
    """
    call_order = []

    original_handle_default_branch = dispatcher.handle_default_branch
    original_handle_shell_true = dispatcher.handle_shell_true

    def tracking_default_branch(command, tool_input):
        call_order.append("default_branch")
        # Don't block — feature branch
        return original_handle_default_branch.__wrapped__(command, tool_input) if hasattr(original_handle_default_branch, "__wrapped__") else None

    def tracking_shell_true(command, tool_input):
        call_order.append("shell_true")
        return None  # allow

    inner = {"command": "git commit -m 'x'"}
    event = {"tool_input": inner}
    stdin_data = json.dumps(event)

    # Mock subprocess to return feature branch (no block)
    mock_proc = _mock_proc("feat/test")

    with (
        patch("sys.stdin", io.StringIO(stdin_data)),
        patch("subprocess.run", return_value=mock_proc),
        patch.object(dispatcher, "handle_default_branch", side_effect=tracking_default_branch),
        patch.object(dispatcher, "handle_shell_true", side_effect=tracking_shell_true),
        patch("builtins.print"),
    ):
        try:
            dispatcher.main()
        except SystemExit:
            pass

    assert call_order == ["default_branch", "shell_true"], (
        f"Expected default_branch → shell_true, got: {call_order}"
    )
