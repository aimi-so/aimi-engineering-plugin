#!/usr/bin/env python3
from __future__ import annotations

import ast
import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from hook_utils import safe_hook, safe_json_input, effective_cwd, load_aimi_config, deny  # noqa: E402

# ---------------------------------------------------------------------------
# Module-level pre-compiled regexes — compiled once on import
# ---------------------------------------------------------------------------

_GIT_COMMIT_RE = re.compile(r"\bgit\s+commit\b")
_GIT_WORKTREE_ADD_RE = re.compile(r"\bgit\s+worktree\s+add\b")

# Used by handle_default_branch for git -C variant
_GIT_C_COMMIT_RE = re.compile(r"\bgit\s+-C\s+\S+\s+commit\b")


# ---------------------------------------------------------------------------
# Handler: default-branch guard
# ---------------------------------------------------------------------------

def _load_protected_branches(cwd: str) -> set[str]:
    protected = {"main", "master", "develop"}
    config = load_aimi_config(start=Path(cwd))
    extra = config.get("guards", {}).get("protectedBranches", [])
    protected.update(extra)
    return protected


def handle_default_branch(command: str, tool_input: dict) -> None:
    """Block git commits on protected branches.

    Mirrors guard-default-branch.py logic.  Calls deny() + prints + exits on
    block; returns normally to allow the next handler to run.
    """
    # Fast-path: must contain a git commit invocation
    if not (_GIT_COMMIT_RE.search(command) or _GIT_C_COMMIT_RE.search(command)):
        return

    # Bypass env
    if os.environ.get("AIMI_DEFAULT_BRANCH_GUARD") == "off":
        return

    cwd = effective_cwd(command, tool_input)
    protected = _load_protected_branches(cwd)

    try:
        result = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        branch = result.stdout.strip()
    except Exception:  # noqa: BLE001
        return

    if branch in protected:
        msg = (
            f"Commits on the protected branch `{branch}` are blocked.\n"
            "Use a feature worktree:\n"
            "  git worktree add /tmp/<feature> -b feat/<feature>\n"
            "Then commit from that worktree. The default branch stays clean for merges."
        )
        print(deny(msg))
        sys.exit(0)


# ---------------------------------------------------------------------------
# Handler: shell=True guard
# ---------------------------------------------------------------------------

def _scan_for_shell_true(blob: str) -> list[int]:
    """Return 1-based line numbers where shell=True is passed as a keyword argument.

    Uses ast.parse to walk Call nodes so that occurrences inside string
    literals, comments, and docstrings are never flagged.  On SyntaxError the
    file is skipped (returns []) to avoid blocking legitimate WIP.
    """
    try:
        tree = ast.parse(blob)
    except SyntaxError:
        return []

    hits: list[int] = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        for kw in node.keywords:
            if (
                kw.arg == "shell"
                and isinstance(kw.value, ast.Constant)
                and kw.value.value is True
            ):
                hits.append(kw.value.lineno)
    hits.sort()
    return hits


def handle_shell_true(command: str, tool_input: dict) -> None:
    """Block git commits that stage Python files containing shell=True.

    Mirrors guard-shell-true.py logic.  Calls deny() + prints + exits on
    block; returns normally to continue.
    """
    # Fast-path: must contain a git commit invocation
    if not (_GIT_COMMIT_RE.search(command) or _GIT_C_COMMIT_RE.search(command)):
        return

    # Bypass env
    if os.environ.get("AIMI_SHELL_TRUE_GUARD") == "off":
        return

    cwd = effective_cwd(command, tool_input)

    try:
        result = subprocess.run(
            ["git", "-C", cwd, "diff", "--cached", "--name-only", "--", "*.py"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        staged_files = [f for f in result.stdout.splitlines() if f.strip()]
    except Exception:  # noqa: BLE001
        return

    if not staged_files:
        return

    offenders: list[str] = []
    for path in staged_files:
        try:
            blob_result = subprocess.run(
                ["git", "-C", cwd, "show", f":{path}"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            blob = blob_result.stdout
        except Exception:  # noqa: BLE001
            continue

        for lineno in _scan_for_shell_true(blob):
            offenders.append(f"  {path}:{lineno}")

    if offenders:
        lines = "\n".join(offenders)
        msg = (
            "`shell=True` detected in staged files — refusing to commit:\n"
            f"{lines}\n"
            "Use shell=False with an argv list, or move the constant into a small helper that quotes inputs."
        )
        print(deny(msg))
        sys.exit(0)


# ---------------------------------------------------------------------------
# Handler: worktree budget guard
# ---------------------------------------------------------------------------

def _allow() -> None:
    sys.exit(0)


def _find_tasks_json(start: str):
    """Walk up from *start* looking for .aimi/tasks/*.json.

    Returns (root_path, tasks_json_path) where root_path is the directory
    containing .aimi/, or (None, None) if not found.
    """
    current = Path(start).resolve()
    while True:
        aimi_dir = current / ".aimi" / "tasks"
        if aimi_dir.is_dir():
            candidates = list(aimi_dir.glob("*-tasks.json"))
            if candidates:
                # Pick most recently modified
                latest = max(candidates, key=lambda p: p.stat().st_mtime)
                return current, latest
        parent = current.parent
        if parent == current:
            break
        current = parent
    return None, None


def _count_active_worktrees(cwd: str) -> int:
    """Run ``git worktree list --porcelain`` and count active worktrees.

    Returns the count minus 1 (to exclude the main checkout).
    Returns 0 on any error.
    """
    try:
        result = subprocess.run(
            ["git", "-C", cwd, "worktree", "list", "--porcelain"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode != 0:
            return 0
        count = sum(
            1 for line in result.stdout.splitlines() if line.startswith("worktree ")
        )
        return max(0, count - 1)  # subtract main checkout
    except Exception:  # noqa: BLE001
        return 0


def handle_worktree_budget(command: str, tool_input: dict) -> None:
    """Block git worktree add when the concurrency budget is exhausted.

    Mirrors guard-worktree-budget.py logic.  Calls deny() + prints + exits on
    block; calls _allow() (sys.exit(0)) to allow.
    """
    # Fast-path: only intercept `git worktree add` commands.
    if not _GIT_WORKTREE_ADD_RE.search(command):
        _allow()

    # Bypass env var.
    if os.environ.get("AIMI_WORKTREE_BUDGET_GUARD", "").lower() == "off":
        _allow()

    cwd = effective_cwd(command, tool_input)

    root, tasks_path = _find_tasks_json(cwd)
    if root is None:
        # Not inside an aimi-managed project — silent allow.
        _allow()

    # Read maxConcurrency from metadata.
    max_concurrency = 5
    try:
        tasks_data = json.loads(tasks_path.read_text())
        raw = tasks_data.get("metadata", {}).get("maxConcurrency")
        if isinstance(raw, int):
            max_concurrency = raw
    except Exception:  # noqa: BLE001
        pass

    active_count = _count_active_worktrees(cwd)

    if active_count >= max_concurrency:
        rel_path = tasks_path.relative_to(root)
        print(deny(
            f"Worktree budget exhausted: {active_count}/{max_concurrency} active.\n"
            f"Wait for an in-flight story to complete, or raise metadata.maxConcurrency\n"
            f"in {rel_path}. Set AIMI_WORKTREE_BUDGET_GUARD=off to bypass."
        ))
        sys.exit(0)

    _allow()


# ---------------------------------------------------------------------------
# Main dispatcher
# ---------------------------------------------------------------------------

@safe_hook
def main(tool_input: dict) -> None:
    command = tool_input.get("tool_input", {}).get("command", "")

    if _GIT_COMMIT_RE.search(command):
        handle_default_branch(command, tool_input.get("tool_input", {}))
        handle_shell_true(command, tool_input.get("tool_input", {}))
        sys.exit(0)

    if _GIT_WORKTREE_ADD_RE.search(command):
        handle_worktree_budget(command, tool_input.get("tool_input", {}))
        sys.exit(0)

    # Unrelated command — silent allow
    sys.exit(0)


if __name__ == "__main__":
    main()
