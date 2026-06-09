from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

_STORE_DIR = Path.home() / ".aimi" / "learnings"
_DATE_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}\.jsonl$")


def _today_file() -> Path:
    """Return the path for today's JSONL file (UTC date)."""
    date_str = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d")
    return _STORE_DIR / f"{date_str}.jsonl"


def _all_date_files() -> list[Path]:
    """Return all date-suffixed JSONL files sorted lexicographically."""
    if not _STORE_DIR.exists():
        return []
    return sorted(
        p for p in _STORE_DIR.iterdir() if _DATE_PATTERN.match(p.name)
    )


def append_event(event: dict) -> None:
    """Append one JSON line to today's JSONL file (UTC).

    Creates parent directories if missing.
    """
    target = _today_file()
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(event) + "\n")


def read_pending() -> Iterator[dict]:
    """Yield all events across all date-suffixed JSONL files in chronological order.

    Files are sorted lexicographically by name (ISO-8601 date prefix ensures
    chronological order).  Lines within each file are yielded in file order.
    """
    for path in _all_date_files():
        with path.open("r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    try:
                        yield json.loads(line)
                    except json.JSONDecodeError:
                        continue


def pending_count() -> int:
    """Return the total number of event lines across all date-suffixed JSONL files."""
    total = 0
    for path in _all_date_files():
        with path.open("r", encoding="utf-8") as fh:
            for line in fh:
                if line.strip():
                    total += 1
    return total
