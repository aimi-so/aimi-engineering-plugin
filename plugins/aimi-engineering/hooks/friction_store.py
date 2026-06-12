from __future__ import annotations

import hashlib
import json
import os
import re
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

import sys as _sys
_HOOKS_DIR = Path(__file__).parent
if str(_HOOKS_DIR) not in _sys.path:
    _sys.path.insert(0, str(_HOOKS_DIR))
from hook_utils import redact_secrets  # noqa: E402

_STORE_DIR = Path.home() / ".aimi" / "learnings"
_DATE_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}\.jsonl$")


def _redact_event(event: dict) -> dict:
    """Return a shallow copy of *event* with secrets redacted from string values."""
    result = {}
    for key, value in event.items():
        if isinstance(value, str):
            result[key] = redact_secrets(value)
        else:
            result[key] = value
    return result


def _today_file() -> Path:
    """Return the path for today's JSONL file (UTC date)."""
    date_str = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d")
    return _STORE_DIR / f"{date_str}.jsonl"


def all_date_files() -> list[Path]:
    """Return all date-suffixed JSONL files sorted lexicographically."""
    if not _STORE_DIR.exists():
        return []
    return sorted(
        p for p in _STORE_DIR.iterdir() if _DATE_PATTERN.match(p.name)
    )


# Backward-compat alias
_all_date_files = all_date_files


def append_event(event: dict) -> None:
    """Append one JSON line to today's JSONL file (UTC).

    Creates parent directories if missing.  If the event does not already
    carry an ``event_id`` field one is generated as the first 16 hex chars of
    sha256(ts|session_id|sorted-json-payload).  String fields in the event are
    passed through :func:`redact_secrets` before writing.
    """
    if "event_id" not in event:
        ts = event.get("ts", "")
        session_id = event.get("session_id", "")
        raw = f"{ts}|{session_id}|{json.dumps(event, sort_keys=True)}"
        event_id = hashlib.sha256(raw.encode()).hexdigest()[:16]
        event = dict(event)
        event["event_id"] = event_id

    event = _redact_event(event)

    target = _today_file()
    target.parent.mkdir(parents=True, exist_ok=True)
    is_new = not target.exists()
    with target.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(event) + "\n")
    if is_new:
        try:
            os.chmod(target, 0o600)
        except OSError:
            pass


def read_pending() -> Iterator[dict]:
    """Yield all events across all date-suffixed JSONL files in chronological order.

    Files are sorted lexicographically by name (ISO-8601 date prefix ensures
    chronological order).  Lines within each file are yielded in file order.
    """
    for path in all_date_files():
        with path.open("r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    try:
                        yield json.loads(line)
                    except json.JSONDecodeError:
                        continue


def iter_events() -> Iterator[tuple[str, dict]]:
    """Yield (event_id, event_dict) pairs across all date files in order.

    Events that lack an ``event_id`` field are assigned a synthetic id derived
    from their position and raw content so that the iterator always yields a
    non-empty string id.
    """
    pos = 0
    for path in all_date_files():
        with path.open("r", encoding="utf-8") as fh:
            for line in fh:
                stripped = line.strip()
                if not stripped:
                    continue
                try:
                    event = json.loads(stripped)
                except json.JSONDecodeError:
                    pos += 1
                    continue
                event_id = event.get("event_id") or hashlib.sha256(
                    f"{pos}|{stripped}".encode()
                ).hexdigest()[:16]
                yield event_id, event
                pos += 1


def pending_count() -> int:
    """Return the total number of event lines across all date-suffixed JSONL files."""
    total = 0
    for path in all_date_files():
        with path.open("r", encoding="utf-8") as fh:
            for line in fh:
                if line.strip():
                    total += 1
    return total


def mark_events(
    promoted_ids: set[str],
    discarded_ids: set[str],
) -> dict:
    """Move events identified by event_id into companion files atomically.

    For each affected date file the rewrite is done via a tmp file +
    ``os.replace`` so that the replace is atomic.  Concurrent appenders write
    to the file via POSIX O_APPEND; to avoid losing those writes, after the
    os.replace we re-read the original file descriptor (still open) for any
    lines that appeared after our snapshot and append them to the new file.

    Companion files:
    - Promoted events go to ``<date>.promoted.jsonl``
    - Discarded events go to ``<date>.discarded.jsonl``

    Each companion entry gains a ``decision`` field (``"promoted"`` or
    ``"discarded"``).

    Idempotent: an event whose ``event_id`` already appears in a companion
    file is counted as skipped (even if it is no longer in the live file).

    Returns ``{"promoted": N, "discarded": N, "skipped": N}``.
    """
    all_marked = promoted_ids | discarded_ids
    if not all_marked:
        return {"promoted": 0, "discarded": 0, "skipped": 0}

    # Collect event_ids already present in companion files (idempotency).
    already_done: set[str] = set()
    for path in all_date_files():
        for companion_suffix in (".promoted.jsonl", ".discarded.jsonl"):
            companion = path.with_name(path.stem + companion_suffix)
            if companion.exists():
                try:
                    with companion.open("r", encoding="utf-8") as fh:
                        for line in fh:
                            stripped = line.strip()
                            if stripped:
                                try:
                                    entry = json.loads(stripped)
                                    eid = entry.get("event_id")
                                    if eid:
                                        already_done.add(eid)
                                except json.JSONDecodeError:
                                    pass
                except OSError:
                    pass

    counts = {"promoted": 0, "discarded": 0, "skipped": 0}

    # Count already-done ids that were requested (idempotent re-mark)
    for eid in all_marked:
        if eid in already_done:
            counts["skipped"] += 1

    # Determine which ids still need processing
    effective_promoted = promoted_ids - already_done
    effective_discarded = discarded_ids - already_done
    effective_marked = effective_promoted | effective_discarded

    if not effective_marked:
        return counts

    for path in all_date_files():
        # Open the live file and take a snapshot of its current content.
        # Keep the file descriptor open so we can detect concurrent appends.
        try:
            fh = path.open("r", encoding="utf-8")
        except OSError:
            continue

        try:
            snapshot_lines = fh.readlines()
            snapshot_pos = fh.tell()
        except OSError:
            fh.close()
            continue

        promoted_entries: list[dict] = []
        discarded_entries: list[dict] = []
        surviving_lines: list[str] = []

        for line in snapshot_lines:
            stripped = line.strip()
            if not stripped:
                surviving_lines.append(line)
                continue
            try:
                event = json.loads(stripped)
            except json.JSONDecodeError:
                surviving_lines.append(line)
                continue

            eid = event.get("event_id", "")
            if eid in effective_promoted:
                entry = dict(event)
                entry["decision"] = "promoted"
                promoted_entries.append(entry)
                counts["promoted"] += 1
            elif eid in effective_discarded:
                entry = dict(event)
                entry["decision"] = "discarded"
                discarded_entries.append(entry)
                counts["discarded"] += 1
            else:
                surviving_lines.append(line)

        # If nothing changed in this file, skip rewriting.
        if not promoted_entries and not discarded_entries:
            fh.close()
            continue

        # Atomic rewrite of live file: surviving lines only (no tail yet).
        dir_ = path.parent
        tmp_path_str: str | None = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="utf-8",
                dir=dir_,
                delete=False,
                suffix=".tmp",
            ) as tmp_fh:
                tmp_path_str = tmp_fh.name
                tmp_fh.writelines(surviving_lines)
            os.replace(tmp_path_str, path)
            tmp_path_str = None  # replaced successfully
        except OSError:
            fh.close()
            if tmp_path_str is not None:
                try:
                    os.unlink(tmp_path_str)
                except Exception:
                    pass
            # Skip companion writes for this file if rewrite failed.
            continue

        # After os.replace, drain any lines that arrived on the OLD inode
        # (concurrent appenders that opened the file before the replace and
        # wrote between our snapshot and now).  Since fh still points at the
        # old inode, readlines() returns only the bytes after our snapshot.
        try:
            tail_lines = fh.readlines()
        except OSError:
            tail_lines = []
        fh.close()

        # Re-append tail lines (concurrent writes) to the new live file.
        if tail_lines:
            try:
                with path.open("a", encoding="utf-8") as live_fh:
                    live_fh.writelines(tail_lines)
            except OSError:
                pass

        # Append to promoted companion.
        if promoted_entries:
            companion = path.with_name(path.stem + ".promoted.jsonl")
            try:
                companion.parent.mkdir(parents=True, exist_ok=True)
                companion_is_new = not companion.exists()
                with companion.open("a", encoding="utf-8") as cfh:
                    for entry in promoted_entries:
                        cfh.write(json.dumps(entry) + "\n")
                if companion_is_new:
                    try:
                        os.chmod(companion, 0o600)
                    except OSError:
                        pass
            except OSError:
                pass

        # Append to discarded companion.
        if discarded_entries:
            companion = path.with_name(path.stem + ".discarded.jsonl")
            try:
                companion.parent.mkdir(parents=True, exist_ok=True)
                companion_is_new = not companion.exists()
                with companion.open("a", encoding="utf-8") as cfh:
                    for entry in discarded_entries:
                        cfh.write(json.dumps(entry) + "\n")
                if companion_is_new:
                    try:
                        os.chmod(companion, 0o600)
                    except OSError:
                        pass
            except OSError:
                pass

    return counts
