#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

_HOOKS_DIR = Path(__file__).parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

from hook_utils import safe_hook, resolve_session_id, extract_skill_name  # noqa: E402


def _session_dir(session_id: str) -> Path:
    return Path.home() / ".aimi" / "session" / session_id


@safe_hook
def main(tool_input: dict) -> None:
    skill_name = extract_skill_name(tool_input)
    if not skill_name:
        sys.exit(0)

    sid = resolve_session_id(tool_input)
    sess_dir = _session_dir(sid)
    sess_dir.mkdir(parents=True, exist_ok=True)

    stack_file = sess_dir / "skill-stack.jsonl"
    entry = json.dumps({"name": skill_name, "started_at": datetime.now(timezone.utc).isoformat()})
    with stack_file.open("a", encoding="utf-8") as fh:
        fh.write(entry + "\n")

    sys.exit(0)


if __name__ == "__main__":
    main()
