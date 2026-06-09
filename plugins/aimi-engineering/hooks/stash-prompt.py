#!/usr/bin/env python3
from __future__ import annotations

import os
import sys
from pathlib import Path

_HOOKS_DIR = Path(__file__).parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

from hook_utils import safe_hook, safe_json_input, resolve_session_id  # noqa: E402


def _session_dir(session_id: str) -> Path:
    return Path.home() / ".aimi" / "session" / session_id


@safe_hook
def main(tool_input: dict) -> None:
    prompt = tool_input.get("prompt")
    if not prompt:
        sys.exit(0)

    sid = resolve_session_id(tool_input)
    sess_dir = _session_dir(sid)
    sess_dir.mkdir(parents=True, exist_ok=True)

    target = sess_dir / "last-prompt.txt"
    tmp = sess_dir / "last-prompt.txt.tmp"
    tmp.write_text(prompt, encoding="utf-8")
    os.replace(tmp, target)
    try:
        os.chmod(target, 0o600)
    except OSError:
        pass

    sys.exit(0)


if __name__ == "__main__":
    main()
