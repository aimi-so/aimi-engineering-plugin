from __future__ import annotations

import functools
import json
import os
import re
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


def load_aimi_config(start: Path | None = None) -> dict:
    """Walk up from start (default: $CLAUDE_PLUGIN_ROOT or cwd) looking for .aimi/config.json.

    Returns parsed dict if found and valid JSON.
    Returns {} on any error (file missing, parse error, etc.).
    """
    if start is None:
        root = os.environ.get("CLAUDE_PLUGIN_ROOT")
        start = Path(root) if root else Path(os.getcwd())

    current = start
    while True:
        candidate = current / ".aimi" / "config.json"
        if candidate.exists():
            try:
                return json.loads(candidate.read_text(encoding="utf-8"))
            except Exception:  # noqa: BLE001
                return {}
        parent = current.parent
        if parent == current:
            return {}
        current = parent


def is_quiet_mode() -> bool:
    """Walk up from $CLAUDE_PLUGIN_ROOT (or cwd) looking for .aimi/config.json.

    Returns config.get("quietMode", False) when found and parseable,
    otherwise False.
    """
    return bool(load_aimi_config().get("quietMode", False))


def effective_cwd(command: str, tool_input: dict) -> str:
    """Return the effective working directory for a shell command.

    Priority:
    1. Parse ``git -C <path>`` from command string.
    2. Parse a leading ``cd <path> &&`` from command string.
    3. Fall back to tool_input.get("cwd") if present.
    4. Fall back to os.getcwd().

    Returns an absolute path string with ~ expanded.
    """
    m = re.search(r"\bgit\s+-C\s+(\S+)", command)
    if m:
        return os.path.abspath(os.path.expanduser(m.group(1)))

    m = re.match(r"\s*cd\s+(\S+)\s*&&", command)
    if m:
        return os.path.abspath(os.path.expanduser(m.group(1)))

    cwd = tool_input.get("cwd")
    if cwd:
        return os.path.abspath(os.path.expanduser(cwd))
    return os.getcwd()


def resolve_session_id(tool_input: dict) -> str:
    """Resolve the current session identifier.

    Priority:
    1. tool_input.get("session_id")
    2. os.environ.get("CLAUDE_SESSION_ID")
    3. "default"
    """
    sid = tool_input.get("session_id")
    if sid:
        return str(sid)
    sid = os.environ.get("CLAUDE_SESSION_ID")
    if sid:
        return str(sid)
    return "default"


def find_aimi_dir(start: Path | None = None) -> Path | None:
    """Walk up from start (default: cwd) looking for a .aimi directory.

    Returns a Path pointing to the .aimi directory if found, or None.
    Stops at the filesystem root.
    """
    if start is None:
        start = Path(os.getcwd())

    current = start.resolve()
    while True:
        candidate = current / ".aimi"
        if candidate.is_dir():
            return candidate
        parent = current.parent
        if parent == current:
            return None
        current = parent


def deny(user_message: str, event_name: str = "PreToolUse") -> str:
    """Return the canonical JSON deny output for a PreToolUse (or other) hook event.

    Usage::

        print(deny("your message"))
        sys.exit(0)
    """
    return json.dumps(
        {
            "hookSpecificOutput": {
                "hookEventName": event_name,
                "permissionDecision": "deny",
                "userMessage": user_message,
            }
        }
    )
