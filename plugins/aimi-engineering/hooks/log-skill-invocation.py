#!/usr/bin/env python3
from __future__ import annotations

import sys
from datetime import datetime, timezone
from pathlib import Path

_HOOKS_DIR = Path(__file__).parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

from hook_utils import safe_hook, safe_json_input, resolve_session_id, extract_skill_name  # noqa: E402
import frame_helpers  # noqa: E402
import telemetry_writer  # noqa: E402


@safe_hook
def main(tool_input: dict) -> None:
    if not telemetry_writer.is_telemetry_enabled():
        sys.exit(0)

    skill_name = extract_skill_name(tool_input)
    if not skill_name:
        sys.exit(0)

    session_id = resolve_session_id(tool_input)
    frame = frame_helpers.current_frame(session_id)

    # Compute duration_ms from frame started_at if available
    duration_ms: int | None = None
    if frame and frame.get("started_at"):
        try:
            started_at = datetime.fromisoformat(frame["started_at"])
            now = datetime.now(timezone.utc)
            duration_ms = int((now - started_at).total_seconds() * 1000)
        except Exception:  # noqa: BLE001
            duration_ms = None

    # Extract outcome from tool_response
    outcome = "unknown"
    tool_response = tool_input.get("tool_response")
    if isinstance(tool_response, dict):
        outcome = tool_response.get("outcome", "unknown")

    payload = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "session_id": session_id,
        "skill": skill_name,
        "outcome": outcome,
        "duration_ms": duration_ms,
    }

    telemetry_writer.append("skills", payload)
    sys.exit(0)


if __name__ == "__main__":
    main()
