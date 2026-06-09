#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

_HOOKS_DIR = Path(__file__).parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

from hook_utils import safe_hook, safe_json_input, find_aimi_dir, deny  # noqa: E402


def _deny_path(path: str, reason: str) -> None:
    msg = (
        f"Direct edits to runtime state are blocked:\n"
        f"  {path}\n"
        f"This file is owned by the aimi runtime. {reason}.\n"
        f"Set AIMI_RUNTIME_STATE_GUARD=off to bypass intentionally."
    )
    print(deny(msg))
    sys.exit(0)


def _load_extra_paths(aimi_dir: Path) -> list[Path]:
    """Load guards.runtimeStatePaths from .aimi/config.json if present."""
    config_file = aimi_dir / "config.json"
    if not config_file.exists():
        return []
    try:
        config = json.loads(config_file.read_text())
        raw_paths = config.get("guards", {}).get("runtimeStatePaths", [])
        result = []
        for p in raw_paths:
            expanded = Path(os.path.expanduser(p)).resolve()
            result.append(expanded)
        return result
    except Exception:
        return []


def _is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        # Process exists but we don't have permission to signal it.
        return True


@safe_hook
def main(tool_input: dict) -> None:
    # Bypass env check.
    if os.environ.get("AIMI_RUNTIME_STATE_GUARD", "").lower() == "off":
        sys.exit(0)

    # Extract file path from the Claude Code shape: tool_input.tool_input.file_path
    inner = tool_input.get("tool_input", {})
    file_path_raw = inner.get("file_path", "")
    if not file_path_raw:
        sys.exit(0)

    target = Path(file_path_raw).resolve()

    home = Path(os.path.expanduser("~")).resolve()
    learnings_dir = (home / ".aimi" / "learnings").resolve()
    telemetry_dir = (home / ".aimi" / "telemetry").resolve()

    # Always-blocked: ~/.aimi/learnings/ (recursive)
    try:
        target.relative_to(learnings_dir)
        _deny_path(str(target), "Friction log is append-only")
    except ValueError:
        pass

    # Always-blocked: ~/.aimi/telemetry/ (recursive)
    try:
        target.relative_to(telemetry_dir)
        _deny_path(str(target), "Telemetry log is append-only")
    except ValueError:
        pass

    # Find .aimi/ directory by walking up from cwd.
    cwd = Path(os.getcwd()).resolve()
    aimi_dir = find_aimi_dir(cwd)

    if aimi_dir is not None:
        state_dir = (aimi_dir / "state").resolve()
        tasks_dir = (aimi_dir / "tasks").resolve()
        lock_file = aimi_dir / ".execute.lock"

        # Always-blocked: any path inside .aimi/state/ (recursive)
        try:
            target.relative_to(state_dir)
            _deny_path(str(target), "State files reflect live runtime")
        except ValueError:
            pass

        # Conditionally-blocked: .aimi/tasks/*-tasks.json when lock is alive
        try:
            target.relative_to(tasks_dir)
            # It's inside tasks/; check if it's a tasks.json file
            if target.name.endswith("-tasks.json"):
                if lock_file.exists():
                    try:
                        pid_text = lock_file.read_text().strip()
                        pid = int(pid_text)
                        if _is_alive(pid):
                            _deny_path(str(target), "Execute lock is active")
                        # else: pid dead, allow
                    except (ValueError, OSError):
                        pass  # unreadable / bad pid → allow
                # else: no lock file → allow
        except ValueError:
            pass

        # Check extra paths from config
        extra_paths = _load_extra_paths(aimi_dir)
        for extra in extra_paths:
            try:
                target.relative_to(extra)
                _deny_path(str(target), "State files reflect live runtime")
            except ValueError:
                pass

    sys.exit(0)


if __name__ == "__main__":
    main()
