#!/usr/bin/env python3
"""drain-friction.py — data layer for the aimi-learnings skill.

Subcommands
-----------
--list   (default)
    Output JSON to stdout describing pending friction events grouped by scope.

--mark
    Read JSON from stdin with {"promoted": [...], "discarded": [...]} index lists.
    Write a companion <friction_file>.promoted.jsonl with a "decision" field.
    Remove marked entries from the live friction file.

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


def _load_all_events() -> list[tuple[int, dict]]:
    """Return (original_index, event) pairs across all pending JSONL files."""
    if friction_store is None:
        return []
    try:
        return list(enumerate(friction_store.read_pending()))
    except Exception:
        return []


def _live_files() -> list[Path]:
    """Return all date-suffixed JSONL files from the store directory."""
    if friction_store is None:
        return []
    try:
        # Access private helper — same package, documented internal API
        return friction_store._all_date_files()
    except Exception:
        return []


def _companion_path(live_path: Path) -> Path:
    return live_path.with_suffix(".promoted.jsonl")


def _read_companion_events(companion: Path) -> list[dict]:
    """Read all events from a companion .promoted.jsonl file."""
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
    indexed = _load_all_events()

    groups: dict[str, Any] = _empty_groups()
    for idx, event in indexed:
        scope = event.get("scope", "inbox")
        if scope not in _SCOPES:
            scope = "inbox"
        groups[scope]["count"] += 1
        if len(groups[scope]["samples"]) < _SAMPLES_CAP:
            sample = dict(event)
            sample["_index"] = idx
            groups[scope]["samples"].append(sample)

    total_pending = sum(g["count"] for g in groups.values())

    print(json.dumps({"groups": groups, "total_pending": total_pending}, indent=2))


# ---------------------------------------------------------------------------
# Subcommand: --mark
# ---------------------------------------------------------------------------

def _load_claimed_global_indices(live_files: list[Path]) -> set[int]:
    """Return the set of global indices already recorded in companion files.

    Each companion entry stores a ``_global_index`` field written at mark time.
    This allows subsequent mark calls to skip indices that were already claimed,
    even after the live file has been rewritten (which would otherwise shift
    remaining events to lower indices).
    """
    claimed: set[int] = set()
    for path in live_files:
        companion = _companion_path(path)
        for entry in _read_companion_events(companion):
            gi = entry.get("_global_index")
            if isinstance(gi, int):
                claimed.add(gi)
    return claimed


def cmd_mark() -> None:
    """Read mark decisions from stdin and update live + companion files.

    Input JSON (from stdin):
      {"promoted": [<indices>], "discarded": [<indices>]}

    Behaviour:
    - Appends marked entries (with "decision" and "_global_index" fields) to
      the companion file.
    - Removes marked entries from the live friction file.
    - Idempotent: a global index already present in any companion file is skipped.
    """
    try:
        payload = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, OSError):
        payload = {}

    promoted_indices: set[int] = set(payload.get("promoted", []))
    discarded_indices: set[int] = set(payload.get("discarded", []))
    all_marked = promoted_indices | discarded_indices

    if not all_marked:
        return

    live_files = _live_files()
    if not live_files:
        return

    # Load already-claimed global indices to ensure idempotency across calls.
    claimed_global = _load_claimed_global_indices(live_files)

    # Re-read raw lines per file to do precise removal.
    per_file_lines: dict[Path, list[str]] = {}
    for path in live_files:
        try:
            with path.open("r", encoding="utf-8") as fh:
                per_file_lines[path] = fh.readlines()
        except OSError:
            per_file_lines[path] = []

    # Map global index → (path, line_index_in_file) for ALL current live events.
    # Note: global indices here are relative to the CURRENT live file state, not
    # the original state before any marks. Combined with claimed_global tracking
    # (which stores the ORIGINAL global index at first-mark time), repeated calls
    # with the same payload will find those indices in claimed_global and skip.
    global_idx = 0
    index_map: dict[int, tuple[Path, int]] = {}
    for path in live_files:
        for line_idx, line in enumerate(per_file_lines[path]):
            stripped = line.strip()
            if stripped:
                try:
                    json.loads(stripped)
                    index_map[global_idx] = (path, line_idx)
                    global_idx += 1
                except json.JSONDecodeError:
                    pass

    # Determine which requested indices are unclaimed.
    effective_marked = all_marked - claimed_global

    if not effective_marked:
        return

    lines_to_remove: dict[Path, set[int]] = {p: set() for p in live_files}

    for path in live_files:
        companion = _companion_path(path)
        append_entries: list[dict] = []

        for g_idx, (file_path, line_idx) in index_map.items():
            if file_path != path:
                continue
            if g_idx not in effective_marked:
                continue

            raw_line = per_file_lines[path][line_idx].strip()
            try:
                event = json.loads(raw_line)
            except json.JSONDecodeError:
                continue

            decision = "promoted" if g_idx in promoted_indices else "discarded"
            entry = dict(event)
            entry["decision"] = decision
            entry["_global_index"] = g_idx  # stable idempotency key for future calls
            append_entries.append(entry)
            lines_to_remove[path].add(line_idx)

        if append_entries:
            try:
                companion.parent.mkdir(parents=True, exist_ok=True)
                with companion.open("a", encoding="utf-8") as fh:
                    for entry in append_entries:
                        fh.write(json.dumps(entry) + "\n")
            except OSError:
                pass

    # Rewrite live files with marked lines removed.
    for path in live_files:
        remove_set = lines_to_remove[path]
        if not remove_set:
            continue
        remaining = [
            line for idx, line in enumerate(per_file_lines[path])
            if idx not in remove_set
        ]
        try:
            with path.open("w", encoding="utf-8") as fh:
                fh.writelines(remaining)
        except OSError:
            pass


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

        companion = _companion_path(path)
        for entry in _read_companion_events(companion):
            decision = entry.get("decision", "")
            if decision == "promoted":
                promoted += 1
            elif decision == "discarded":
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
        help="Read mark decisions from stdin and update friction files.",
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
            pass
        elif args.summary:
            print(json.dumps({"pending": 0, "promoted": 0, "discarded": 0}))
        else:
            print(json.dumps({"groups": _empty_groups(), "total_pending": 0}))


if __name__ == "__main__":
    main()
