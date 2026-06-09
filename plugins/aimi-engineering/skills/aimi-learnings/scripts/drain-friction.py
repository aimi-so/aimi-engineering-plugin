#!/usr/bin/env python3
"""drain-friction.py — data layer for the aimi-learnings skill.

Subcommands
-----------
--list   (default)
    Output JSON to stdout describing pending friction events grouped by scope.

--mark
    Read JSON from stdin with {"promoted": [<event_id>, ...], "discarded": [<event_id>, ...]}.
    Move matched events to companion files with a "decision" field.
    Print counts as JSON: {"promoted": N, "discarded": N, "skipped": N}.
    Atomic: live file is rewritten via tmp+os.replace.
    Idempotent: event_ids already in a companion file are no-ops (counted as skipped).

--summary
    Output JSON with counts of pending, promoted, and discarded events.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Import friction_store from the hooks/ directory
# ---------------------------------------------------------------------------
# Path layout: skills/aimi-learnings/scripts/drain-friction.py
#   parent        = scripts/
#   parent.parent = aimi-learnings/
#   parent×3      = skills/
#   parent×4      = plugins/aimi-engineering/   ← plugin root
_PLUGIN_DIR = Path(__file__).resolve().parent.parent.parent.parent
_HOOKS_DIR = _PLUGIN_DIR / "hooks"
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

try:
    import friction_store
except ImportError:
    friction_store = None  # type: ignore[assignment]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_SCOPES = ("project", "plugin", "inbox")
_SAMPLES_CAP = 3


def _empty_groups() -> dict[str, Any]:
    return {s: {"count": 0, "samples": []} for s in _SCOPES}


def _live_files() -> list[Path]:
    """Return all date-suffixed JSONL files from the store directory."""
    if friction_store is None:
        return []
    try:
        return friction_store.all_date_files()
    except Exception:
        return []


def _companion_path(live_path: Path, decision: str = "promoted") -> Path:
    return live_path.with_name(live_path.stem + f".{decision}.jsonl")


def _read_companion_events(companion: Path) -> list[dict]:
    """Read all events from a companion .jsonl file."""
    if not companion.exists():
        return []
    events: list[dict] = []
    try:
        with companion.open("r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    try:
                        events.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue
    except OSError:
        pass
    return events


# ---------------------------------------------------------------------------
# Subcommand: --list
# ---------------------------------------------------------------------------

def cmd_list() -> None:
    """Group pending events by scope and output JSON."""
    if friction_store is None:
        print(json.dumps({"groups": _empty_groups(), "total_pending": 0}, indent=2))
        return

    groups: dict[str, Any] = _empty_groups()
    try:
        for event_id, event in friction_store.iter_events():
            scope = event.get("scope", "inbox")
            if scope not in _SCOPES:
                scope = "inbox"
            groups[scope]["count"] += 1
            if len(groups[scope]["samples"]) < _SAMPLES_CAP:
                sample = dict(event)
                sample["event_id"] = event_id
                groups[scope]["samples"].append(sample)
    except Exception:
        pass

    total_pending = sum(g["count"] for g in groups.values())
    print(json.dumps({"groups": groups, "total_pending": total_pending}, indent=2))


# ---------------------------------------------------------------------------
# Subcommand: --mark
# ---------------------------------------------------------------------------

def cmd_mark() -> None:
    """Read mark decisions from stdin and update live + companion files.

    Input JSON (from stdin):
      {"promoted": ["<event_id>", ...], "discarded": ["<event_id>", ...]}

    Output JSON (to stdout):
      {"promoted": N, "discarded": N, "skipped": N}
    """
    try:
        payload = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, OSError):
        payload = {}

    promoted_ids: set[str] = set(payload.get("promoted", []))
    discarded_ids: set[str] = set(payload.get("discarded", []))

    if friction_store is None:
        print(json.dumps({"promoted": 0, "discarded": 0, "skipped": 0}))
        return

    counts = friction_store.mark_events(promoted_ids, discarded_ids)
    print(json.dumps(counts))


# ---------------------------------------------------------------------------
# Subcommand: --summary
# ---------------------------------------------------------------------------

def cmd_summary() -> None:
    """Output counts of pending, promoted, and discarded events."""
    pending = 0
    promoted = 0
    discarded = 0

    live_files = _live_files()
    for path in live_files:
        try:
            with path.open("r", encoding="utf-8") as fh:
                for line in fh:
                    if line.strip():
                        try:
                            json.loads(line.strip())
                            pending += 1
                        except json.JSONDecodeError:
                            pass
        except OSError:
            pass

        for decision in ("promoted", "discarded"):
            companion = _companion_path(path, decision)
            for entry in _read_companion_events(companion):
                if entry.get("decision") == "promoted":
                    promoted += 1
                elif entry.get("decision") == "discarded":
                    discarded += 1

    print(json.dumps({"pending": pending, "promoted": promoted, "discarded": discarded}))


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Drain and triage the aimi friction queue.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    group = parser.add_mutually_exclusive_group()
    group.add_argument(
        "--list",
        action="store_true",
        default=False,
        help="List pending events grouped by scope (default behaviour).",
    )
    group.add_argument(
        "--mark",
        action="store_true",
        default=False,
        help="Read mark decisions (event_ids) from stdin and update friction files.",
    )
    group.add_argument(
        "--summary",
        action="store_true",
        default=False,
        help="Output pending/promoted/discarded counts.",
    )
    args = parser.parse_args()

    try:
        if args.mark:
            cmd_mark()
        elif args.summary:
            cmd_summary()
        else:
            # Default: --list
            cmd_list()
    except Exception:
        # Silent on unexpected errors — return safe empty output
        if args.mark:
            print(json.dumps({"promoted": 0, "discarded": 0, "skipped": 0}))
        elif args.summary:
            print(json.dumps({"pending": 0, "promoted": 0, "discarded": 0}))
        else:
            print(json.dumps({"groups": _empty_groups(), "total_pending": 0}))


if __name__ == "__main__":
    main()
