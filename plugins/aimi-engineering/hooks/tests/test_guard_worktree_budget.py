from __future__ import annotations

import io
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

# Insert the hooks directory onto sys.path so we can import the module under
# test without needing a proper Python package structure.
_HOOKS_DIR = Path(__file__).parent.parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

import importlib.util as _ilu

_spec = _ilu.spec_from_file_location(
    "pre_bash_dispatcher", _HOOKS_DIR / "pre-bash-dispatcher.py"
)
dispatcher = _ilu.module_from_spec(_spec)  # type: ignore[arg-type]
_spec.loader.exec_module(dispatcher)  # type: ignore[union-attr]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_MAIN_SHA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
_WT1_SHA = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
_WT2_SHA = "cccccccccccccccccccccccccccccccccccccccccc"
_WT3_SHA = "dddddddddddddddddddddddddddddddddddddddddd"


def _porcelain(*worktree_paths: str) -> str:
    """Build a git worktree list --porcelain output string.

    The first path is always the "main" checkout; the rest are extra
    worktrees.  Each entry gets a deterministic synthetic SHA.
    """
    shas = [_MAIN_SHA, _WT1_SHA, _WT2_SHA, _WT3_SHA]
    blocks = []
    for i, path in enumerate(worktree_paths):
        sha = shas[i % len(shas)]
        branch = "main" if i == 0 else f"feat/wt{i}"
        block = f"worktree {path}\nHEAD {sha}\nbranch refs/heads/{branch}\n"
        blocks.append(block)
    return "\n".join(blocks)


def _make_tasks_json(tmp_path: Path, max_concurrency=None) -> Path:
    """Write a minimal tasks.json under tmp_path/.aimi/tasks/ and return its path."""
    tasks_dir = tmp_path / ".aimi" / "tasks"
    tasks_dir.mkdir(parents=True, exist_ok=True)
    metadata: dict = {"title": "Test", "type": "feature", "branchName": "feat/test"}
    if max_concurrency is not None:
        metadata["maxConcurrency"] = max_concurrency
    data = {"schemaVersion": "3.3", "metadata": metadata, "userStories": []}
    tasks_file = tasks_dir / "2026-06-09-test-tasks.json"
    tasks_file.write_text(json.dumps(data))
    return tasks_file


def _fake_run_factory(active_worktree_count: int, cwd: str = "/repo"):
    """Return a fake subprocess.run that simulates git worktree list output.

    *active_worktree_count* is the number of NON-main worktrees.  The fake
    always prepends the main checkout so total entries = active + 1.
    """

    def fake_run(cmd, **kwargs):
        # Build path list: main + N extra worktrees.
        paths = [cwd] + [f"{cwd}/wt{i}" for i in range(1, active_worktree_count + 1)]
        output = _porcelain(*paths)
        return subprocess.CompletedProcess(cmd, 0, stdout=output, stderr="")

    return fake_run


def _tool_input_for(command: str, cwd: str = "") -> dict:
    payload: dict = {"command": command}
    if cwd:
        payload["cwd"] = cwd
    return payload


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_allows_when_under_budget(tmp_path, monkeypatch):
    """active=2, max=5 → allow (exit 0)."""
    _make_tasks_json(tmp_path)
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(
        subprocess, "run", _fake_run_factory(2, str(tmp_path))
    )
    monkeypatch.delenv("AIMI_WORKTREE_BUDGET_GUARD", raising=False)

    with pytest.raises(SystemExit) as exc_info:
        dispatcher.handle_worktree_budget("git worktree add ../wt-new feat/x", _tool_input_for("git worktree add ../wt-new feat/x"))

    assert exc_info.value.code == 0


def test_denies_when_at_budget(tmp_path, monkeypatch):
    """active=4, max=4 → deny (exit 0), message includes '4/4'."""
    _make_tasks_json(tmp_path, max_concurrency=4)
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(
        subprocess, "run", _fake_run_factory(4, str(tmp_path))
    )
    monkeypatch.delenv("AIMI_WORKTREE_BUDGET_GUARD", raising=False)

    captured = []

    def fake_print(msg):
        captured.append(msg)

    monkeypatch.setattr("builtins.print", fake_print)

    with pytest.raises(SystemExit) as exc_info:
        dispatcher.handle_worktree_budget("git worktree add ../wt-new feat/x", _tool_input_for("git worktree add ../wt-new feat/x"))

    assert exc_info.value.code == 0
    assert captured, "Expected deny message to be printed"
    deny_data = json.loads(captured[0])
    assert "4/4" in deny_data["hookSpecificOutput"]["userMessage"]


def test_denies_when_over_budget(tmp_path, monkeypatch):
    """active=6, max=5 → deny (exit 0)."""
    _make_tasks_json(tmp_path, max_concurrency=5)
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(
        subprocess, "run", _fake_run_factory(6, str(tmp_path))
    )
    monkeypatch.delenv("AIMI_WORKTREE_BUDGET_GUARD", raising=False)

    with pytest.raises(SystemExit) as exc_info:
        dispatcher.handle_worktree_budget("git worktree add ../wt-new feat/x", _tool_input_for("git worktree add ../wt-new feat/x"))

    assert exc_info.value.code == 0


def test_passes_through_non_worktree_commands(tmp_path, monkeypatch):
    """Non-git commands → allow (exit 0)."""
    monkeypatch.chdir(tmp_path)
    monkeypatch.delenv("AIMI_WORKTREE_BUDGET_GUARD", raising=False)

    for cmd in ("git status", "git log --oneline", "ls -la", "npm install"):
        with pytest.raises(SystemExit) as exc_info:
            dispatcher.handle_worktree_budget(cmd, _tool_input_for(cmd))
        assert exc_info.value.code == 0, f"Expected allow for: {cmd!r}"


def test_passes_through_non_add_worktree_subcommands(tmp_path, monkeypatch):
    """git worktree list / remove → allow (exit 0)."""
    monkeypatch.chdir(tmp_path)
    monkeypatch.delenv("AIMI_WORKTREE_BUDGET_GUARD", raising=False)

    for cmd in ("git worktree list", "git worktree remove ../old-wt"):
        with pytest.raises(SystemExit) as exc_info:
            dispatcher.handle_worktree_budget(cmd, _tool_input_for(cmd))
        assert exc_info.value.code == 0, f"Expected allow for: {cmd!r}"


def test_allows_outside_aimi_project(tmp_path, monkeypatch):
    """No .aimi/ in walk-up → allow silently (exit 0)."""
    monkeypatch.chdir(tmp_path)
    monkeypatch.delenv("AIMI_WORKTREE_BUDGET_GUARD", raising=False)
    # Do NOT create .aimi/ directory.

    with pytest.raises(SystemExit) as exc_info:
        dispatcher.handle_worktree_budget("git worktree add ../wt-new feat/x", _tool_input_for("git worktree add ../wt-new feat/x"))

    assert exc_info.value.code == 0


def test_bypass_env_allows(tmp_path, monkeypatch):
    """AIMI_WORKTREE_BUDGET_GUARD=off → always allow."""
    _make_tasks_json(tmp_path, max_concurrency=1)
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(
        subprocess, "run", _fake_run_factory(10, str(tmp_path))
    )
    monkeypatch.setenv("AIMI_WORKTREE_BUDGET_GUARD", "off")

    with pytest.raises(SystemExit) as exc_info:
        dispatcher.handle_worktree_budget("git worktree add ../wt-new feat/x", _tool_input_for("git worktree add ../wt-new feat/x"))

    assert exc_info.value.code == 0


def test_parses_git_C_path_cwd(tmp_path, monkeypatch):
    """Effective cwd is parsed from ``git -C <path>`` in the command."""
    project_dir = tmp_path / "project"
    project_dir.mkdir()
    _make_tasks_json(project_dir)
    monkeypatch.chdir(tmp_path)  # NOT the project dir
    monkeypatch.setattr(
        subprocess,
        "run",
        _fake_run_factory(0, str(project_dir)),
    )
    monkeypatch.delenv("AIMI_WORKTREE_BUDGET_GUARD", raising=False)

    # Command uses git -C <project_dir> worktree add
    cmd = f"git -C {project_dir} worktree add ../wt-new feat/x"

    with pytest.raises(SystemExit) as exc_info:
        dispatcher.handle_worktree_budget(cmd, _tool_input_for(cmd))

    # 0 active worktrees → under budget → allow
    assert exc_info.value.code == 0


def test_parses_cd_prefix_cwd(tmp_path, monkeypatch):
    """Effective cwd is parsed from leading ``cd <path> &&`` in the command."""
    project_dir = tmp_path / "project"
    project_dir.mkdir()
    _make_tasks_json(project_dir)
    monkeypatch.chdir(tmp_path)  # NOT the project dir
    monkeypatch.setattr(
        subprocess,
        "run",
        _fake_run_factory(0, str(project_dir)),
    )
    monkeypatch.delenv("AIMI_WORKTREE_BUDGET_GUARD", raising=False)

    cmd = f"cd {project_dir} && git worktree add ../wt-new feat/x"

    with pytest.raises(SystemExit) as exc_info:
        dispatcher.handle_worktree_budget(cmd, _tool_input_for(cmd))

    assert exc_info.value.code == 0


def test_reads_max_concurrency_from_metadata(tmp_path, monkeypatch):
    """tasks.json with metadata.maxConcurrency=3, active=3 → deny (exit 0)."""
    _make_tasks_json(tmp_path, max_concurrency=3)
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(
        subprocess, "run", _fake_run_factory(3, str(tmp_path))
    )
    monkeypatch.delenv("AIMI_WORKTREE_BUDGET_GUARD", raising=False)

    captured = []
    monkeypatch.setattr("builtins.print", lambda msg: captured.append(msg))

    with pytest.raises(SystemExit) as exc_info:
        dispatcher.handle_worktree_budget("git worktree add ../wt-new feat/x", _tool_input_for("git worktree add ../wt-new feat/x"))

    assert exc_info.value.code == 0
    deny_data = json.loads(captured[0])
    assert "3/3" in deny_data["hookSpecificOutput"]["userMessage"]


def test_default_max_when_missing(tmp_path, monkeypatch):
    """No metadata.maxConcurrency → default 20; active=4 → allow."""
    _make_tasks_json(tmp_path)  # no maxConcurrency → defaults to 20
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(
        subprocess, "run", _fake_run_factory(4, str(tmp_path))
    )
    monkeypatch.delenv("AIMI_WORKTREE_BUDGET_GUARD", raising=False)

    with pytest.raises(SystemExit) as exc_info:
        dispatcher.handle_worktree_budget("git worktree add ../wt-new feat/x", _tool_input_for("git worktree add ../wt-new feat/x"))

    assert exc_info.value.code == 0


def test_message_lists_tasks_file_path(tmp_path, monkeypatch):
    """Deny message includes tasks file path relative to project root."""
    _make_tasks_json(tmp_path, max_concurrency=2)
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(
        subprocess, "run", _fake_run_factory(2, str(tmp_path))
    )
    monkeypatch.delenv("AIMI_WORKTREE_BUDGET_GUARD", raising=False)

    captured = []
    monkeypatch.setattr("builtins.print", lambda msg: captured.append(msg))

    with pytest.raises(SystemExit) as exc_info:
        dispatcher.handle_worktree_budget("git worktree add ../wt-new feat/x", _tool_input_for("git worktree add ../wt-new feat/x"))

    assert exc_info.value.code == 0
    deny_data = json.loads(captured[0])
    # Should contain the relative path .aimi/tasks/2026-06-09-test-tasks.json
    assert ".aimi/tasks/2026-06-09-test-tasks.json" in deny_data["hookSpecificOutput"]["userMessage"]


# ---------------------------------------------------------------------------
# Phase-aware governing-file resolution tests (US-004)
# ---------------------------------------------------------------------------

def _make_nested_tasks_json(
    tmp_path: Path,
    feature: str,
    phase_dir: str,
    filename: str,
    branch_name: str,
    max_concurrency=None,
) -> Path:
    """Write a minimal nested phase tasks.json under
    tmp_path/.aimi/tasks/<feature>/<phase_dir>/<filename> and return its path."""
    tasks_dir = tmp_path / ".aimi" / "tasks" / feature / phase_dir
    tasks_dir.mkdir(parents=True, exist_ok=True)
    metadata: dict = {"title": "Test", "type": "feature", "branchName": branch_name}
    if max_concurrency is not None:
        metadata["maxConcurrency"] = max_concurrency
    data = {"schemaVersion": "3.3", "metadata": metadata, "userStories": []}
    tasks_file = tasks_dir / filename
    tasks_file.write_text(json.dumps(data))
    return tasks_file


def _fake_run_with_branch(branch: str, active_worktree_count: int = 0, cwd: str = "/repo"):
    """Return a fake subprocess.run that answers both ``git rev-parse`` (the
    checked-out branch) and ``git worktree list --porcelain`` (active
    worktree count) based on the command being run, so branch-aware file
    selection can be tested independent of worktree budget counting."""

    def fake_run(cmd, **kwargs):
        if "rev-parse" in cmd:
            return subprocess.CompletedProcess(cmd, 0, stdout=f"{branch}\n", stderr="")
        paths = [cwd] + [f"{cwd}/wt{i}" for i in range(1, active_worktree_count + 1)]
        output = _porcelain(*paths)
        return subprocess.CompletedProcess(cmd, 0, stdout=output, stderr="")

    return fake_run


def test_branch_match_wins_over_newer_mtime(tmp_path, monkeypatch):
    """Two nested phase tasks files: an older one whose metadata.branchName
    matches the checked-out branch, and a newer one that doesn't. The
    branch-matching file must govern maxConcurrency, not the newer-mtime one
    -- deterministic phase selection under parallel sessions instead of a
    race on whichever file was touched most recently."""
    _make_nested_tasks_json(
        tmp_path, "myfeat", "phase-1-alpha", "myfeat-phase-1-tasks.json",
        branch_name="feat/myfeat-phase-1", max_concurrency=2,
    )
    newer = _make_nested_tasks_json(
        tmp_path, "myfeat", "phase-2-beta", "myfeat-phase-2-tasks.json",
        branch_name="feat/myfeat-phase-2", max_concurrency=10,
    )
    # Force the second file to have a strictly newer mtime than the first.
    older_mtime = (tmp_path / ".aimi/tasks/myfeat/phase-1-alpha/myfeat-phase-1-tasks.json").stat().st_mtime
    os.utime(newer, (older_mtime + 10, older_mtime + 10))

    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(
        subprocess, "run",
        _fake_run_with_branch("feat/myfeat-phase-1", active_worktree_count=2, cwd=str(tmp_path)),
    )
    monkeypatch.delenv("AIMI_WORKTREE_BUDGET_GUARD", raising=False)

    captured = []
    monkeypatch.setattr("builtins.print", lambda msg: captured.append(msg))

    with pytest.raises(SystemExit) as exc_info:
        dispatcher.handle_worktree_budget(
            "git worktree add ../wt-new feat/x", _tool_input_for("git worktree add ../wt-new feat/x")
        )

    assert exc_info.value.code == 0
    # active=2 >= the branch-matching (older) file's maxConcurrency=2 -> deny.
    # If the newer non-matching file (maxConcurrency=10) had governed instead,
    # active=2 would be under budget and no deny message would be printed.
    assert captured, "Expected deny message from the branch-matching file's budget"
    deny_data = json.loads(captured[0])
    assert "2/2" in deny_data["hookSpecificOutput"]["userMessage"]


def test_no_branch_match_falls_back_to_newest_mtime(tmp_path, monkeypatch):
    """When the checked-out branch matches none of the discovered candidates
    (e.g. running from the main checkout with no phase context), fall back
    to today's newest-modified-file selection across all flat and nested
    candidates, preserving existing flat/legacy behavior."""
    _make_nested_tasks_json(
        tmp_path, "myfeat", "phase-1-alpha", "myfeat-phase-1-tasks.json",
        branch_name="feat/myfeat-phase-1", max_concurrency=10,
    )
    newest = _make_nested_tasks_json(
        tmp_path, "myfeat", "phase-2-beta", "myfeat-phase-2-tasks.json",
        branch_name="feat/myfeat-phase-2", max_concurrency=2,
    )
    older_mtime = (tmp_path / ".aimi/tasks/myfeat/phase-1-alpha/myfeat-phase-1-tasks.json").stat().st_mtime
    os.utime(newest, (older_mtime + 10, older_mtime + 10))

    monkeypatch.chdir(tmp_path)
    # "main" matches neither candidate's branchName.
    monkeypatch.setattr(
        subprocess, "run",
        _fake_run_with_branch("main", active_worktree_count=2, cwd=str(tmp_path)),
    )
    monkeypatch.delenv("AIMI_WORKTREE_BUDGET_GUARD", raising=False)

    captured = []
    monkeypatch.setattr("builtins.print", lambda msg: captured.append(msg))

    with pytest.raises(SystemExit) as exc_info:
        dispatcher.handle_worktree_budget(
            "git worktree add ../wt-new feat/x", _tool_input_for("git worktree add ../wt-new feat/x")
        )

    assert exc_info.value.code == 0
    # active=2 >= the newest file's maxConcurrency=2 -> deny. If the older
    # file (maxConcurrency=10) had governed, active=2 would be under budget.
    assert captured, "Expected deny message from the newest-mtime file's budget"
    deny_data = json.loads(captured[0])
    assert "2/2" in deny_data["hookSpecificOutput"]["userMessage"]


def test_malformed_sibling_metadata_null_does_not_disable_guard(tmp_path, monkeypatch):
    """A sibling *-tasks.json shaped like ``{"metadata": null}`` must not raise
    and must not silently disable enforcement.

    Regression for: the branch-match comparison in
    ``_select_governing_tasks_file`` used to sit outside the ``try`` that
    wraps ``json.loads``, so a successfully-parsed-but-malformed sibling threw
    an uncaught AttributeError from ``.get("metadata", {}).get("branchName")``
    (``.get`` on an explicit ``None`` returns ``None``, not ``{}``). That
    propagated through ``_find_tasks_json`` -> ``handle_worktree_budget`` and,
    in production, would be swallowed by ``@safe_hook`` -> exit 0 = silent
    allow, disabling worktree-budget enforcement entirely. This test calls
    ``handle_worktree_budget`` directly (bypassing ``@safe_hook``), so any
    unhandled exception fails the test instead of being masked as an allow.
    """
    _make_nested_tasks_json(
        tmp_path, "myfeat", "phase-1-alpha", "myfeat-phase-1-tasks.json",
        branch_name="feat/myfeat-phase-1", max_concurrency=2,
    )
    malformed_dir = tmp_path / ".aimi" / "tasks" / "myfeat" / "phase-2-beta"
    malformed_dir.mkdir(parents=True, exist_ok=True)
    (malformed_dir / "myfeat-phase-2-tasks.json").write_text(json.dumps({"metadata": None}))

    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(
        subprocess, "run",
        _fake_run_with_branch("feat/myfeat-phase-1", active_worktree_count=2, cwd=str(tmp_path)),
    )
    monkeypatch.delenv("AIMI_WORKTREE_BUDGET_GUARD", raising=False)

    captured = []
    monkeypatch.setattr("builtins.print", lambda msg: captured.append(msg))

    with pytest.raises(SystemExit) as exc_info:
        dispatcher.handle_worktree_budget(
            "git worktree add ../wt-new feat/x", _tool_input_for("git worktree add ../wt-new feat/x")
        )

    assert exc_info.value.code == 0
    assert captured, "Expected deny message -- guard must still enforce budget despite malformed sibling"
    deny_data = json.loads(captured[0])
    assert "2/2" in deny_data["hookSpecificOutput"]["userMessage"]


def test_malformed_sibling_top_level_list_does_not_disable_guard(tmp_path, monkeypatch):
    """A sibling *-tasks.json whose top-level JSON value is a list (not an
    object) must not raise and must not silently disable enforcement.

    Same regression as test_malformed_sibling_metadata_null_does_not_disable_guard,
    but for the shape where ``data.get(...)`` itself raises AttributeError
    because ``data`` is a ``list``, not a ``dict``.
    """
    _make_nested_tasks_json(
        tmp_path, "myfeat", "phase-1-alpha", "myfeat-phase-1-tasks.json",
        branch_name="feat/myfeat-phase-1", max_concurrency=2,
    )
    malformed_dir = tmp_path / ".aimi" / "tasks" / "myfeat" / "phase-2-beta"
    malformed_dir.mkdir(parents=True, exist_ok=True)
    (malformed_dir / "myfeat-phase-2-tasks.json").write_text(json.dumps([1, 2, 3]))

    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(
        subprocess, "run",
        _fake_run_with_branch("feat/myfeat-phase-1", active_worktree_count=2, cwd=str(tmp_path)),
    )
    monkeypatch.delenv("AIMI_WORKTREE_BUDGET_GUARD", raising=False)

    captured = []
    monkeypatch.setattr("builtins.print", lambda msg: captured.append(msg))

    with pytest.raises(SystemExit) as exc_info:
        dispatcher.handle_worktree_budget(
            "git worktree add ../wt-new feat/x", _tool_input_for("git worktree add ../wt-new feat/x")
        )

    assert exc_info.value.code == 0
    assert captured, "Expected deny message -- guard must still enforce budget despite malformed sibling"
    deny_data = json.loads(captured[0])
    assert "2/2" in deny_data["hookSpecificOutput"]["userMessage"]
