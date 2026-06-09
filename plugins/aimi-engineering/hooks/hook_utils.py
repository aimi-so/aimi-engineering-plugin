from __future__ import annotations

import functools
import json
import os
import sys
from pathlib import Path
from typing import Callable


def safe_hook(fn: Callable[[dict], None]) -> Callable[[], None]:
    """Decorator that wraps a handler(tool_input: dict) -> None.

    Reads safe_json_input(), calls fn, and catches every exception,
    exiting 0 silently.  Keeping Claude Code sessions stable is the
    explicit goal — never let a hook crash a session.
    """

    @functools.wraps(fn)
    def wrapper() -> None:
        try:
            tool_input = safe_json_input()
            fn(tool_input)
        except Exception:  # noqa: BLE001
            sys.exit(0)

    return wrapper


def safe_json_input() -> dict:
    """Read sys.stdin and parse as JSON.

    Returns the parsed dict on success, or {} on any parse error
    (including empty stdin).
    """
    try:
        raw = sys.stdin.read()
        return json.loads(raw)
    except Exception:  # noqa: BLE001
        return {}


def is_quiet_mode() -> bool:
    """Walk up from $CLAUDE_PLUGIN_ROOT (or cwd) looking for .aimi/config.json.

    Returns config.get("quietMode", False) when found and parseable,
    otherwise False.
    """
    root = os.environ.get("CLAUDE_PLUGIN_ROOT")
    start = Path(root) if root else Path(os.getcwd())

    current = start
    while True:
        candidate = current / ".aimi" / "config.json"
        if candidate.exists():
            try:
                config = json.loads(candidate.read_text())
                return bool(config.get("quietMode", False))
            except Exception:  # noqa: BLE001
                return False
        parent = current.parent
        if parent == current:
            # Reached filesystem root without finding the file.
            return False
        current = parent
