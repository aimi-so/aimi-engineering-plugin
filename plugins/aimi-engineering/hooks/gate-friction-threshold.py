#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

_HOOKS_DIR = Path(__file__).parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

from hook_utils import safe_hook, safe_json_input  # noqa: E402
import friction_store  # noqa: E402

_SKIP_SKILLS = {"aimi:learnings", "aimi-engineering:learnings"}
_DEFAULT_THRESHOLD = 5


def _resolve_session_id() -> str:
    sid = os.environ.get("CLAUDE_SESSION_ID")
    if sid:
        return str(sid)
    return "default"


def _session_dir(session_id: str) -> Path:
    return Path.home() / ".aimi" / "session" / session_id


def _read_threshold() -> int:
    """Walk up from cwd to find .aimi/config.json and read learnings.frictionThreshold."""
    current = Path(os.getcwd()).resolve()
    while True:
        candidate = current / ".aimi" / "config.json"
        if candidate.exists():
            try:
                config = json.loads(candidate.read_text(encoding="utf-8"))
                learnings = config.get("learnings", {})
                threshold = learnings.get("frictionThreshold", _DEFAULT_THRESHOLD)
                return int(threshold)
            except Exception:  # noqa: BLE001
                return _DEFAULT_THRESHOLD
        parent = current.parent
        if parent == current:
            break
        current = parent
    return _DEFAULT_THRESHOLD


@safe_hook
def main(tool_input: dict) -> None:
    # Extract skill name from tool input
    skill_name: str = tool_input.get("skill_name", "") or tool_input.get("name", "") or ""
    # Also check nested structures Claude Code may use
    if not skill_name:
        skill_name = tool_input.get("toolName", "") or ""

    # Skip silently when skill is a learnings skill (avoid recursion)
    if skill_name in _SKIP_SKILLS:
        sys.exit(0)

    # Rate limit: check if nudge already emitted this session
    sid = _resolve_session_id()
    sess_dir = _session_dir(sid)
    nudge_flag = sess_dir / "learnings-nudge-emitted"
    if nudge_flag.exists():
        sys.exit(0)

    # Read threshold from config
    threshold = _read_threshold()

    # Count pending friction events
    count = friction_store.pending_count()

    if count >= threshold:
        # Touch rate-limit file
        sess_dir.mkdir(parents=True, exist_ok=True)
        nudge_flag.write_bytes(b"")

        # Emit advisory via additionalContext
        advisory = f"[LEARNINGS CANDIDATE] {count} pending friction events. Run /aimi:learnings to triage."
        output = {
            "hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": advisory,
            }
        }
        print(json.dumps(output))

    sys.exit(0)


if __name__ == "__main__":
    main()
