#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from pathlib import Path

_HOOKS_DIR = Path(__file__).parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

from hook_utils import safe_hook, load_aimi_config, resolve_session_id, extract_skill_name  # noqa: E402
import friction_store  # noqa: E402
import frame_helpers  # noqa: E402

_SKIP_SKILLS = {"aimi:learnings", "aimi-engineering:learnings"}
_EXECUTOR_FRAME_PREFIXES = ("aimi:execute", "aimi-engineering:execute", "general-purpose")
_DEFAULT_THRESHOLD = 5


def _session_dir(session_id: str) -> Path:
    return Path.home() / ".aimi" / "session" / session_id


def _read_threshold() -> int:
    """Read learnings.frictionThreshold from .aimi/config.json (walk-up)."""
    config = load_aimi_config()
    learnings = config.get("learnings", {})
    threshold = learnings.get("frictionThreshold", _DEFAULT_THRESHOLD)
    try:
        return int(threshold)
    except (OSError, json.JSONDecodeError, ValueError):
        return _DEFAULT_THRESHOLD


def _nudge_enabled() -> bool:
    """Read learnings.nudge.enabled from .aimi/config.json (default True)."""
    config = load_aimi_config()
    learnings = config.get("learnings", {})
    nudge = learnings.get("nudge", {})
    if isinstance(nudge, dict):
        return bool(nudge.get("enabled", True))
    return True


@safe_hook
def main(tool_input: dict) -> None:
    # Check if nudge is enabled via config
    if not _nudge_enabled():
        sys.exit(0)

    # Extract skill name using the unified helper
    skill_name: str = extract_skill_name(tool_input) or ""

    # Skip silently when skill is a learnings skill (avoid recursion)
    if skill_name in _SKIP_SKILLS:
        sys.exit(0)

    # Skip silently when an executor frame is active
    sid = resolve_session_id(tool_input)
    current = frame_helpers.current_frame(sid)
    if current is not None:
        for prefix in _EXECUTOR_FRAME_PREFIXES:
            if current.name.startswith(prefix):
                sys.exit(0)

    # Rate limit: check if nudge already emitted this session
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
