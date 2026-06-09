#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

# Insert the hooks directory onto sys.path so we can import hook_utils when
# this script is run directly (shebang path) or via python3 invocation.
_HOOKS_DIR = Path(__file__).parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

from hook_utils import safe_hook, safe_json_input  # noqa: E402


def _deny(message: str) -> None:
    """Write a Claude Code hook deny response to stdout and exit 2."""
    print(json.dumps({"decision": "block", "reason": message}))
    sys.exit(2)


def _allow() -> None:
    sys.exit(0)


def _detect_cwd(tool_input: dict) -> str:
    """Detect the effective working directory from the Bash tool input.

    Priority:
    1. Parse ``git -C <path>`` from the command string.
    2. Parse a leading ``cd <path> &&`` from the command string.
    3. Fall back to tool_input["cwd"] if present.
    4. Fall back to os.getcwd().
    """
    command = tool_input.get("command", "")

    # git -C <path>
    m = re.search(r"git\s+-C\s+(\S+)", command)
    if m:
        return m.group(1)

    # cd <path> &&
    m = re.match(r"^\s*cd\s+(\S+)\s*&&", command)
    if m:
        return m.group(1)

    # tool_input cwd
    if tool_input.get("cwd"):
        return tool_input["cwd"]

    return os.getcwd()


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


@safe_hook
def main(tool_input: dict) -> None:
    command = tool_input.get("command", "")

    # Fast-path: only intercept `git worktree add` commands.
    if not re.search(r"git\s+worktree\s+add", command):
        _allow()

    # Bypass env var.
    if os.environ.get("AIMI_WORKTREE_BUDGET_GUARD", "").lower() == "off":
        _allow()

    effective_cwd = _detect_cwd(tool_input)

    root, tasks_path = _find_tasks_json(effective_cwd)
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

    active_count = _count_active_worktrees(effective_cwd)

    if active_count >= max_concurrency:
        rel_path = tasks_path.relative_to(root)
        _deny(
            f"Worktree budget exhausted: {active_count}/{max_concurrency} active.\n"
            f"Wait for an in-flight story to complete, or raise metadata.maxConcurrency\n"
            f"in {rel_path}. Set AIMI_WORKTREE_BUDGET_GUARD=off to bypass."
        )

    _allow()


if __name__ == "__main__":
    main()
