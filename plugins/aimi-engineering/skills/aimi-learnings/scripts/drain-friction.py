#!/usr/bin/env python3
"""drain-friction.py — data layer for the aimi-learnings skill.

Subcommands
-----------
--list   (default)
    Output JSON to stdout describing pending friction events grouped by scope.
    Flags accepted alongside --list:
      --scope project|plugin|inbox   Filter output to one scope only.
      --since YYYY-MM-DD or ISO ts   Exclude events older than this timestamp.
      --samples N                    Override the default sample cap (default 3).
      --limit N                      Max total events to return across all groups.

--mark
    Read JSON from stdin with {"promoted": [<event_id>, ...], "discarded": [<event_id>, ...]}.
    Move matched events to companion files with a "decision" field.
    Print counts as JSON: {"promoted": N, "discarded": N, "skipped": N}.
    Atomic: live file is rewritten via tmp+os.replace.
    Idempotent: event_ids already in a companion file are no-ops (counted as skipped).

--summary
    Output JSON with counts of pending, promoted, and discarded events.

--classify
    Read {"prompt": "...", "frame": "..."} JSON from stdin, classify the scope,
    and print {"scope": "..."} on stdout. No friction store interaction.
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
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

try:
    import scope_classifier
except ImportError:
    scope_classifier = None  # type: ignore[assignment]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_SCOPES = ("project", "plugin", "inbox")
_SAMPLES_CAP = 3


def _empty_groups(scope_filter: str | None = None) -> dict[str, Any]:
    scopes = (scope_filter,) if scope_filter else _SCOPES
    return {s: {"count": 0, "samples": []} for s in scopes}


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


def _parse_since(since_str: str) -> datetime | None:
    """Parse a --since value into a timezone-aware datetime. Returns None on failure."""
    for fmt in ("%Y-%m-%d", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M:%S%z",
                "%Y-%m-%dT%H:%M:%S.%f%z", "%Y-%m-%dT%H:%M:%S.%f"):
        try:
            dt = datetime.strptime(since_str, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt
        except ValueError:
            continue
    return None


def _event_ts(event: dict) -> datetime | None:
    """Return a timezone-aware datetime from event['ts'], or None."""
    ts_str = event.get("ts", "")
    if not ts_str:
        return None
    try:
        dt = datetime.fromisoformat(ts_str)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except (ValueError, TypeError):
        return None


# ---------------------------------------------------------------------------
# Subcommand: --list
# ---------------------------------------------------------------------------

def cmd_list(
    scope_filter: str | None = None,
    since: str | None = None,
    samples_cap: int = _SAMPLES_CAP,
    limit: int | None = None,
) -> None:
    """Group pending events by scope and output JSON."""
    if friction_store is None:
        print(json.dumps({"groups": _empty_groups(scope_filter), "total_pending": 0}, indent=2))
        return

    since_dt: datetime | None = None
    if since:
        since_dt = _parse_since(since)

    groups: dict[str, Any] = _empty_groups(scope_filter)
    total_seen = 0

    try:
        for event_id, event in friction_store.iter_events():
            # --since filter
            if since_dt is not None:
                event_time = _event_ts(event)
                if event_time is not None and event_time < since_dt:
                    continue

            scope = event.get("scope", "inbox")
            if scope not in _SCOPES:
                scope = "inbox"

            # --scope filter
            if scope_filter is not None and scope != scope_filter:
                continue

            # --limit filter (total events cap)
            if limit is not None and total_seen >= limit:
                break

            groups[scope]["count"] += 1
            total_seen += 1
            if len(groups[scope]["samples"]) < samples_cap:
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
# Subcommand: --classify
# ---------------------------------------------------------------------------

def cmd_classify() -> None:
    """Read {"prompt": "...", "frame": "..."} from stdin and print {"scope": "..."}.

    Uses scope_classifier.classify_scope. No friction store interaction.
    """
    try:
        payload = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, OSError):
        payload = {}

    prompt_text = payload.get("prompt", "")
    frame_name = payload.get("frame") or None

    if scope_classifier is None:
        print(json.dumps({"scope": "inbox"}))
        return

    try:
        scope = scope_classifier.classify_scope(str(prompt_text), frame_name)
    except Exception:
        scope = "inbox"

    print(json.dumps({"scope": scope}))


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
    group.add_argument(
        "--classify",
        action="store_true",
        default=False,
        help="Read {prompt, frame} from stdin and output {scope}. No store interaction.",
    )

    # --list filters
    parser.add_argument(
        "--scope",
        choices=list(_SCOPES),
        default=None,
        help="Filter list output to one scope only (project, plugin, or inbox).",
    )
    parser.add_argument(
        "--since",
        default=None,
        metavar="YYYY-MM-DD",
        help="Filter list output to events newer than this date/timestamp.",
    )
    parser.add_argument(
        "--samples",
        type=int,
        default=_SAMPLES_CAP,
        metavar="N",
        help=f"Override default sample cap per group (default {_SAMPLES_CAP}).",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        metavar="N",
        help="Max total events to return across all groups.",
    )

    args = parser.parse_args()

    try:
        if args.mark:
            cmd_mark()
        elif args.summary:
            cmd_summary()
        elif args.classify:
            cmd_classify()
        else:
            # Default: --list (also handles --list flag explicitly)
            cmd_list(
                scope_filter=args.scope,
                since=args.since,
                samples_cap=args.samples,
                limit=args.limit,
            )
    except Exception:
        # Silent on unexpected errors — return safe empty output
        if args.mark:
            print(json.dumps({"promoted": 0, "discarded": 0, "skipped": 0}))
        elif args.summary:
            print(json.dumps({"pending": 0, "promoted": 0, "discarded": 0}))
        elif args.classify:
            print(json.dumps({"scope": "inbox"}))
        else:
            print(json.dumps({"groups": _empty_groups(args.scope), "total_pending": 0}))


if __name__ == "__main__":
    main()
