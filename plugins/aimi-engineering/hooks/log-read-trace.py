#!/usr/bin/env python3
from __future__ import annotations

import os
import sys
from datetime import datetime, timezone
from pathlib import Path

_HOOKS_DIR = Path(__file__).parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

from hook_utils import safe_hook, safe_json_input  # noqa: E402
import frame_helpers  # noqa: E402
import telemetry_writer  # noqa: E402


def _resolve_session_id(tool_input: dict) -> str:
    sid = tool_input.get("session_id")
    if sid:
        return str(sid)
    sid = os.environ.get("CLAUDE_SESSION_ID")
    if sid:
        return str(sid)
    return "default"


@safe_hook
def main(tool_input: dict) -> None:
    if not telemetry_writer.is_telemetry_enabled():
        sys.exit(0)

    # Extract file_path from nested tool_input.tool_input.file_path
    file_path: str | None = None
    nested = tool_input.get("tool_input")
    if isinstance(nested, dict):
        file_path = nested.get("file_path") or None
    if not file_path:
        sys.exit(0)

    # Get file size, default 0 on error
    size_bytes = 0
    try:
        size_bytes = os.path.getsize(file_path)
    except Exception:  # noqa: BLE001
        size_bytes = 0

    session_id = _resolve_session_id(tool_input)
    frame = frame_helpers.current_frame(session_id)
    frame_name: str | None = frame.get("name") if frame else None

    payload = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "session_id": session_id,
        "frame": frame_name,
        "path": file_path,
        "size_bytes": size_bytes,
    }

    telemetry_writer.append("reads", payload)
    sys.exit(0)


if __name__ == "__main__":
    main()
