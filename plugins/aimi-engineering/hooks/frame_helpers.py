from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from pathlib import Path

_HOOKS_DIR = Path(__file__).parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

from hook_utils import resolve_session_id as _resolve_session_id_from_tool_input  # noqa: E402


@dataclass(frozen=True)
class SkillFrame:
    name: str
    started_at: str


def _resolve_session_id(session_id: str | None) -> str:
    # frame_helpers accepts session_id as a positional/keyword str arg (not tool_input dict)
    # We map it to resolve_session_id by constructing a minimal tool_input when not None.
    if session_id is not None:
        return str(session_id)
    return _resolve_session_id_from_tool_input({})


def _session_dir(session_id: str) -> Path:
    return Path.home() / ".aimi" / "session" / session_id


def _load_stack(session_id: str) -> list[SkillFrame]:
    stack_file = _session_dir(session_id) / "skill-stack.jsonl"
    frames: list[SkillFrame] = []
    try:
        for line in stack_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                raw = json.loads(line)
                frames.append(SkillFrame(
                    name=raw.get("name", ""),
                    started_at=raw.get("started_at", ""),
                ))
            except json.JSONDecodeError:
                pass
    except OSError:
        pass
    return frames


def current_frame(session_id: str | None = None) -> SkillFrame | None:
    """Return the top of the skill frame stack (most recently pushed), or None if empty."""
    try:
        sid = _resolve_session_id(session_id)
        frames = _load_stack(sid)
        if not frames:
            return None
        return frames[-1]
    except Exception:  # noqa: BLE001
        return None


def frame_stack(session_id: str | None = None) -> list[SkillFrame]:
    """Return the full skill frame stack in chronological order (oldest first)."""
    try:
        sid = _resolve_session_id(session_id)
        return _load_stack(sid)
    except Exception:  # noqa: BLE001
        return []
