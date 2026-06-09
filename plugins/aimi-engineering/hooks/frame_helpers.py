from __future__ import annotations

import json
import os
from pathlib import Path


def _resolve_session_id(session_id: str | None) -> str:
    if session_id is not None:
        return str(session_id)
    sid = os.environ.get("CLAUDE_SESSION_ID")
    if sid:
        return str(sid)
    return "default"


def _session_dir(session_id: str) -> Path:
    return Path.home() / ".aimi" / "session" / session_id


def _load_stack(session_id: str) -> list[dict]:
    stack_file = _session_dir(session_id) / "skill-stack.jsonl"
    frames: list[dict] = []
    try:
        for line in stack_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                frames.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    except OSError:
        pass
    return frames


def current_frame(session_id: str | None = None) -> dict | None:
    """Return the top of the skill frame stack (most recently pushed), or None if empty."""
    try:
        sid = _resolve_session_id(session_id)
        frames = _load_stack(sid)
        if not frames:
            return None
        return frames[-1]
    except Exception:  # noqa: BLE001
        return None


def frame_stack(session_id: str | None = None) -> list[dict]:
    """Return the full skill frame stack in chronological order (oldest first)."""
    try:
        sid = _resolve_session_id(session_id)
        return _load_stack(sid)
    except Exception:  # noqa: BLE001
        return []
