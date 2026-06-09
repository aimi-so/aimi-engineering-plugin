#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
import time
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

_HOOKS_DIR = Path(__file__).parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

from hook_utils import safe_hook, safe_json_input, is_quiet_mode  # noqa: E402
import friction_store  # noqa: E402

_BUDGET_SECS = 0.5  # 500 ms hard budget


def _read_banner_enabled() -> bool:
    """Walk up from cwd looking for .aimi/config.json -> banner.enabled (default True)."""
    import os

    start = Path(os.getcwd())
    current = start
    while True:
        candidate = current / ".aimi" / "config.json"
        if candidate.exists():
            try:
                config = json.loads(candidate.read_text(encoding="utf-8"))
                return bool(config.get("banner", {}).get("enabled", True))
            except Exception:  # noqa: BLE001
                return True
        parent = current.parent
        if parent == current:
            return True
        current = parent


def _read_telemetry_file(path: Path, cutoff: datetime) -> list[dict]:
    """Read a JSONL telemetry file and return entries with ts >= cutoff."""
    results = []
    if not path.exists():
        return results
    try:
        with path.open("r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                    ts_raw = entry.get("ts")
                    if ts_raw:
                        ts = datetime.fromisoformat(ts_raw)
                        # Ensure both are offset-aware for comparison
                        if ts.tzinfo is None:
                            ts = ts.replace(tzinfo=timezone.utc)
                        if ts >= cutoff:
                            results.append(entry)
                except Exception:  # noqa: BLE001
                    continue
    except Exception:  # noqa: BLE001
        pass
    return results


@safe_hook
def main(tool_input: dict) -> None:
    t_start = time.monotonic()

    if is_quiet_mode():
        sys.exit(0)

    if not _read_banner_enabled():
        sys.exit(0)

    # --- Friction ---
    total_friction = 0
    scope_counts: dict[str, int] = {"project": 0, "plugin": 0, "inbox": 0}
    for event in friction_store.read_pending():
        total_friction += 1
        scope = event.get("scope", "inbox")
        if scope in scope_counts:
            scope_counts[scope] += 1
        else:
            scope_counts["inbox"] += 1

    # --- Telemetry (only if budget allows) ---
    now_utc = datetime.now(tz=timezone.utc)
    cutoff = now_utc - timedelta(hours=24)

    skills_counter: Counter[str] = Counter()
    reads_24h = 0
    telemetry_skipped = False

    telemetry_base = Path.home() / ".aimi" / "telemetry"
    skills_path = telemetry_base / "skills.jsonl"
    reads_path = telemetry_base / "reads.jsonl"

    # Read skills if budget allows
    elapsed = time.monotonic() - t_start
    if elapsed < _BUDGET_SECS:
        skill_entries = _read_telemetry_file(skills_path, cutoff)
        for entry in skill_entries:
            skill_name = entry.get("skill")
            if skill_name:
                skills_counter[skill_name] += 1

    # Read reads.jsonl only if budget still allows
    elapsed = time.monotonic() - t_start
    if elapsed < _BUDGET_SECS:
        read_entries = _read_telemetry_file(reads_path, cutoff)
        reads_24h = len(read_entries)
    else:
        telemetry_skipped = True

    # Empty state: nothing to show
    if total_friction == 0 and not skills_counter and reads_24h == 0:
        sys.exit(0)

    # Build banner lines
    lines = ["[aimi session]"]

    if total_friction > 0:
        p = scope_counts.get("project", 0)
        l_val = scope_counts.get("plugin", 0)
        i = scope_counts.get("inbox", 0)
        lines.append(
            f"  pending friction: {total_friction}  "
            f"(project: {p} / plugin: {l_val} / inbox: {i})"
        )

    if not telemetry_skipped:
        if skills_counter:
            top5 = skills_counter.most_common(5)
            skills_str = ", ".join(f"{name}×{count}" for name, count in top5)
            lines.append(f"  skills last 24h: {skills_str}")

        if reads_24h > 0:
            lines.append(f"  reads last 24h: {reads_24h}")

    lines.append("Run /aimi:learnings to triage.")

    banner_text = "\n".join(lines)

    output = {
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": banner_text,
        }
    }
    print(json.dumps(output))
    sys.exit(0)


if __name__ == "__main__":
    main()
