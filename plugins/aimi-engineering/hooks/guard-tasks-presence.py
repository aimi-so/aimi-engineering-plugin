#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

_HOOKS_DIR = Path(__file__).parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

from hook_utils import safe_hook, safe_json_input, find_aimi_dir, deny, SCHEMA_VERSIONS  # noqa: E402


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
    aimi_dir = find_aimi_dir(cwd)

    if aimi_dir is None:
        print(deny(
            "No .aimi/ directory found in walk-up from CWD. "
            "Run /aimi:plan first to create the task structure."
        ))
        sys.exit(0)

    tasks_dir = aimi_dir / "tasks"
    if not tasks_dir.is_dir():
        print(deny(
            "No tasks.json detected in .aimi/tasks/. "
            "Run /aimi:plan to generate one."
        ))
        sys.exit(0)

    tasks_files = sorted(
        tasks_dir.glob("*-tasks.json"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )

    if not tasks_files:
        print(deny(
            "No tasks.json detected in .aimi/tasks/. "
            "Run /aimi:plan to generate one."
        ))
        sys.exit(0)

    # Pick the most recent by mtime.
    latest = tasks_files[0]

    try:
        data = json.loads(latest.read_text())
    except Exception as exc:
        print(deny(f"Failed to parse tasks file {latest}: {exc}"))
        sys.exit(0)

    schema_version = data.get("schemaVersion")
    if schema_version not in SCHEMA_VERSIONS:
        print(deny(
            f"tasks file {latest} has schemaVersion {schema_version!r}, "
            f"expected one of {sorted(SCHEMA_VERSIONS)}."
        ))
        sys.exit(0)

    sys.exit(0)


if __name__ == "__main__":
    main()
