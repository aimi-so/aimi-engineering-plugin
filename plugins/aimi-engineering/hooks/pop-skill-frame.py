#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

_HOOKS_DIR = Path(__file__).parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

from hook_utils import safe_hook, safe_json_input, resolve_session_id, extract_skill_name  # noqa: E402


def _session_dir(session_id: str) -> Path:
    return Path.home() / ".aimi" / "session" / session_id


@safe_hook
def main(tool_input: dict) -> None:
    skill_name = extract_skill_name(tool_input)
    if not skill_name:
        sys.exit(0)

    sid = resolve_session_id(tool_input)
    sess_dir = _session_dir(sid)
    stack_file = sess_dir / "skill-stack.jsonl"

    frames: list[dict] = []
    if stack_file.exists():
        for line in stack_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                frames.append(json.loads(line))
            except json.JSONDecodeError:
                pass

    # LIFO pop: find the LAST occurrence of name == skill_name and remove it
    for i in range(len(frames) - 1, -1, -1):
        if frames[i].get("name") == skill_name:
            frames.pop(i)
            break

    # Atomically rewrite the file
    sess_dir.mkdir(parents=True, exist_ok=True)
    tmp = sess_dir / "skill-stack.jsonl.tmp"
    content = "".join(json.dumps(f) + "\n" for f in frames)
    tmp.write_text(content, encoding="utf-8")
    os.replace(tmp, stack_file)

    sys.exit(0)


if __name__ == "__main__":
    main()
