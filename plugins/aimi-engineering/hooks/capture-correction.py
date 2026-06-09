#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

_HOOKS_DIR = Path(__file__).parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

from hook_utils import safe_hook, safe_json_input, resolve_session_id  # noqa: E402
import friction_store  # noqa: E402
import frame_helpers  # noqa: E402
import scope_classifier  # noqa: E402

# Heuristic correction patterns (case-insensitive)
_CORRECTION_PATTERNS: list[re.Pattern[str]] = [
    re.compile(r"\bn[aã]o,?\s+na\s+verdade\b", re.IGNORECASE),
    re.compile(r"\bisso\s+est[aá]\s+errado\b", re.IGNORECASE),
    re.compile(r"\bespera,?\b", re.IGNORECASE),
    re.compile(r"\bna\s+realidade\b", re.IGNORECASE),
    re.compile(r"\bn[aã]o\s+era\s+isso\b", re.IGNORECASE),
    re.compile(r"\bdeveria\s+ser\b", re.IGNORECASE),
    re.compile(r"\brefaz\b", re.IGNORECASE),
    re.compile(r"\buse?\s+\w+\s+em\s+vez\s+de\b", re.IGNORECASE),
    re.compile(r"\bnot,?\s+actually\b", re.IGNORECASE),
    re.compile(r"\bwait,?\b", re.IGNORECASE),
    re.compile(r"\bshould\s+be\b", re.IGNORECASE),
]

_STALE_THRESHOLD_SECS = 300  # 5 minutes


def _session_dir(session_id: str) -> Path:
    return Path.home() / ".aimi" / "session" / session_id


@safe_hook
def main(tool_input: dict) -> None:
    current_prompt: str = tool_input.get("prompt", "")
    if not current_prompt:
        sys.exit(0)

    # Check correction patterns — require at least one match
    matched = any(p.search(current_prompt) for p in _CORRECTION_PATTERNS)
    if not matched:
        sys.exit(0)

    # Load previous prompt from session file
    sid = resolve_session_id(tool_input)
    sess_dir = _session_dir(sid)
    last_prompt_file = sess_dir / "last-prompt.txt"

    previous_prompt = ""
    if last_prompt_file.exists():
        # Timeliness check: only proceed if file was updated within last 5 minutes
        try:
            file_mtime = last_prompt_file.stat().st_mtime
            age_secs = time.time() - file_mtime
            if age_secs > _STALE_THRESHOLD_SECS:
                sys.exit(0)
            previous_prompt = last_prompt_file.read_text(encoding="utf-8")
        except OSError:
            sys.exit(0)
    else:
        # No previous prompt file — nothing to capture
        sys.exit(0)

    # Require active frame
    frame = frame_helpers.current_frame(session_id=sid)
    if frame is None:
        sys.exit(0)

    # Classify scope
    scope = scope_classifier.classify_scope(current_prompt, frame.get("name"))

    # Build event
    event = {
        "ts": datetime.now(tz=timezone.utc).isoformat(),
        "session_id": sid,
        "frame": frame.get("name"),
        "scope": scope,
        "previous_prompt": previous_prompt,
        "current_prompt": current_prompt,
    }

    friction_store.append_event(event)
    sys.exit(0)


if __name__ == "__main__":
    main()
