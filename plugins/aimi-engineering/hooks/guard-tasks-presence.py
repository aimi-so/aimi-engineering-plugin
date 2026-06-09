#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

_HOOKS_DIR = Path(__file__).parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

from hook_utils import safe_hook, safe_json_input  # noqa: E402


def _deny(message: str) -> None:
    output = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "userMessage": message,
        }
    }
    print(json.dumps(output))
    sys.exit(0)


def _find_aimi_dir(start: Path) -> Path | None:
    """Walk up from start to find the first directory containing .aimi/."""
    current = start.resolve()
    while True:
        candidate = current / ".aimi"
        if candidate.is_dir():
            return candidate
        parent = current.parent
        if parent == current:
            return None
        current = parent


_EXECUTE_SKILLS = {"aimi:execute", "aimi-engineering:execute"}


@safe_hook
def main(tool_input: dict) -> None:
    # Extract skill name from tool input.
    inner = tool_input.get("tool_input", {})
    skill_name = inner.get("name", "") or inner.get("skill", "")
    if not skill_name:
        # Try top-level
        skill_name = tool_input.get("name", "") or tool_input.get("skill", "")

    # Only act when skill is aimi:execute or aimi-engineering:execute.
    if skill_name not in _EXECUTE_SKILLS:
        sys.exit(0)

    cwd = Path(os.getcwd()).resolve()
    aimi_dir = _find_aimi_dir(cwd)

    if aimi_dir is None:
        _deny(
            "No .aimi/ directory found in walk-up from CWD. "
            "Run /aimi:plan first to create the task structure."
        )

    tasks_dir = aimi_dir / "tasks"
    if not tasks_dir.is_dir():
        _deny(
            "No tasks.json detected in .aimi/tasks/. "
            "Run /aimi:plan to generate one."
        )

    tasks_files = sorted(
        tasks_dir.glob("*-tasks.json"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )

    if not tasks_files:
        _deny(
            "No tasks.json detected in .aimi/tasks/. "
            "Run /aimi:plan to generate one."
        )

    # Pick the most recent by mtime.
    latest = tasks_files[0]

    try:
        data = json.loads(latest.read_text())
    except Exception as exc:
        _deny(f"Failed to parse tasks file {latest}: {exc}")

    schema_version = data.get("schemaVersion")
    if schema_version != "3.3":
        _deny(
            f"tasks file {latest} has schemaVersion {schema_version!r}, "
            f"expected '3.3'."
        )

    sys.exit(0)


if __name__ == "__main__":
    main()
