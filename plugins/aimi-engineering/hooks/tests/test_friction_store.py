"""Tests for friction_store public API (US-002).

Covers:
- append_event assigns event_id
- all_date_files returns sorted list
- iter_events yields all events in order
- mark_events atomic under concurrent append
- mark_events idempotent
- tmp+os.replace rewrite pattern (no leftover tmp file)
"""
from __future__ import annotations

import json
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

import pytest

import sys
_HOOKS_DIR = Path(__file__).resolve().parent.parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

import friction_store


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _patch_store(monkeypatch, tmp_path: Path) -> Path:
    store_dir = tmp_path / ".aimi" / "learnings"
    store_dir.mkdir(parents=True, exist_ok=True)
    monkeypatch.setattr(friction_store, "_STORE_DIR", store_dir)
    return store_dir


def _make_event(scope: str = "project", suffix: str = "") -> dict:
    return {
        "ts": datetime.now(tz=timezone.utc).isoformat(),
        "session_id": "test-session",
        "frame": "aimi:plan",
        "scope": scope,
        "previous_prompt": f"prev{suffix}",
        "current_prompt": f"curr{suffix}",
    }


# ---------------------------------------------------------------------------
# append_event assigns event_id
# ---------------------------------------------------------------------------

def test_append_event_assigns_event_id(monkeypatch, tmp_path):
    """append_event should add event_id to every stored event."""
    _patch_store(monkeypatch, tmp_path)

    event = _make_event()
    assert "event_id" not in event  # precondition

    friction_store.append_event(event)

    events = list(friction_store.read_pending())
    assert len(events) == 1
    stored = events[0]
    assert "event_id" in stored
    assert len(stored["event_id"]) == 16  # sha256[:16]


def test_append_event_preserves_existing_event_id(monkeypatch, tmp_path):
    """If event already has event_id, append_event must not overwrite it."""
    _patch_store(monkeypatch, tmp_path)

    event = _make_event()
    event["event_id"] = "my-stable-id-1234"
    friction_store.append_event(event)

    events = list(friction_store.read_pending())
    assert events[0]["event_id"] == "my-stable-id-1234"


def test_append_event_stable_id_same_input(monkeypatch, tmp_path):
    """Two events with identical content should produce the same event_id."""
    _patch_store(monkeypatch, tmp_path)

    base = {"ts": "2026-01-01T00:00:00+00:00", "session_id": "s1",
            "scope": "project", "frame": "aimi:plan",
            "previous_prompt": "p", "current_prompt": "c"}

    friction_store.append_event(dict(base))
    events = list(friction_store.read_pending())
    id1 = events[0]["event_id"]

    # Clear store and append again
    for p in friction_store.all_date_files():
        p.unlink()

    friction_store.append_event(dict(base))
    events2 = list(friction_store.read_pending())
    id2 = events2[0]["event_id"]

    assert id1 == id2


# ---------------------------------------------------------------------------
# all_date_files returns sorted list
# ---------------------------------------------------------------------------

def test_all_date_files_sorted(monkeypatch, tmp_path):
    """all_date_files() returns files sorted lexicographically by name."""
    _patch_store(monkeypatch, tmp_path)
    store_dir = friction_store._STORE_DIR

    # Create files out of order
    for name in ("2026-03-01.jsonl", "2026-01-01.jsonl", "2026-02-01.jsonl"):
        (store_dir / name).write_text("{}\n", encoding="utf-8")

    files = friction_store.all_date_files()
    names = [f.name for f in files]
    assert names == sorted(names)


def test_all_date_files_excludes_companions(monkeypatch, tmp_path):
    """Companion .promoted.jsonl and .discarded.jsonl files must NOT appear."""
    _patch_store(monkeypatch, tmp_path)
    store_dir = friction_store._STORE_DIR

    (store_dir / "2026-01-01.jsonl").write_text("{}\n", encoding="utf-8")
    (store_dir / "2026-01-01.promoted.jsonl").write_text("{}\n", encoding="utf-8")
    (store_dir / "2026-01-01.discarded.jsonl").write_text("{}\n", encoding="utf-8")

    files = friction_store.all_date_files()
    assert len(files) == 1
    assert files[0].name == "2026-01-01.jsonl"


def test_all_date_files_backward_compat_alias(monkeypatch, tmp_path):
    """_all_date_files is the same object as all_date_files."""
    assert friction_store._all_date_files is friction_store.all_date_files


# ---------------------------------------------------------------------------
# iter_events yields all events in order
# ---------------------------------------------------------------------------

def test_iter_events_yields_all_in_order(monkeypatch, tmp_path):
    """iter_events should yield (event_id, event) pairs for all appended events in order."""
    _patch_store(monkeypatch, tmp_path)

    for i in range(5):
        friction_store.append_event(_make_event(suffix=str(i)))

    pairs = list(friction_store.iter_events())
    assert len(pairs) == 5

    for i, (eid, event) in enumerate(pairs):
        assert isinstance(eid, str) and eid
        assert event.get("current_prompt") == f"curr{i}"


def test_iter_events_event_id_matches_stored(monkeypatch, tmp_path):
    """event_id in iter_events must match the event_id field stored in the event."""
    _patch_store(monkeypatch, tmp_path)

    friction_store.append_event(_make_event())

    eid, event = next(friction_store.iter_events())
    assert eid == event["event_id"]


# ---------------------------------------------------------------------------
# mark_events atomic under concurrent append
# ---------------------------------------------------------------------------

def test_mark_events_concurrent_append_no_loss(monkeypatch, tmp_path):
    """No events silently lost when a writer thread appends during mark.

    Strategy: write 10 initial events, start a writer thread doing 40 more
    appends, run mark_events on the initial 10 IDs, then verify that
    live + companion files = 50 total.
    """
    _patch_store(monkeypatch, tmp_path)

    initial_events = []
    for i in range(10):
        ev = _make_event(suffix=f"init{i}")
        friction_store.append_event(ev)

    # Collect event_ids of the initial 10
    initial_ids = {eid for eid, _ in friction_store.iter_events()}
    assert len(initial_ids) == 10

    stop_flag = threading.Event()
    errors: list[Exception] = []

    def writer():
        for i in range(40):
            try:
                friction_store.append_event(_make_event(suffix=f"concurrent{i}"))
            except Exception as exc:
                errors.append(exc)

    t = threading.Thread(target=writer, daemon=True)
    t.start()

    # Mark all initial events as promoted
    counts = friction_store.mark_events(initial_ids, set())

    t.join(timeout=5)
    assert not errors, f"Writer thread errors: {errors}"

    # Count live events
    live_count = 0
    for path in friction_store.all_date_files():
        with path.open("r", encoding="utf-8") as fh:
            for line in fh:
                if line.strip():
                    try:
                        json.loads(line.strip())
                        live_count += 1
                    except json.JSONDecodeError:
                        pass

    # Count companion events
    companion_count = 0
    store_dir = friction_store._STORE_DIR
    for companion in store_dir.glob("*.promoted.jsonl"):
        with companion.open("r", encoding="utf-8") as fh:
            for line in fh:
                if line.strip():
                    try:
                        json.loads(line.strip())
                        companion_count += 1
                    except json.JSONDecodeError:
                        pass

    total = live_count + companion_count
    assert total == 50, (
        f"Expected 50 total events (10 promoted + 40 concurrent), got {total} "
        f"(live={live_count}, companion={companion_count})"
    )


# ---------------------------------------------------------------------------
# mark_events idempotent
# ---------------------------------------------------------------------------

def test_mark_events_idempotent(monkeypatch, tmp_path):
    """Calling mark_events twice with the same ids returns skipped=original_count on second call."""
    _patch_store(monkeypatch, tmp_path)

    for i in range(3):
        friction_store.append_event(_make_event(suffix=str(i)))

    ids = {eid for eid, _ in friction_store.iter_events()}
    assert len(ids) == 3

    # First call
    counts1 = friction_store.mark_events(ids, set())
    assert counts1["promoted"] == 3
    assert counts1["skipped"] == 0

    # Second call — same ids
    counts2 = friction_store.mark_events(ids, set())
    assert counts2["promoted"] == 0
    assert counts2["skipped"] == 3


def test_mark_events_discarded_idempotent(monkeypatch, tmp_path):
    """mark_events idempotent for discarded_ids too."""
    _patch_store(monkeypatch, tmp_path)

    for i in range(2):
        friction_store.append_event(_make_event(suffix=str(i)))

    ids = {eid for eid, _ in friction_store.iter_events()}

    counts1 = friction_store.mark_events(set(), ids)
    assert counts1["discarded"] == 2

    counts2 = friction_store.mark_events(set(), ids)
    assert counts2["discarded"] == 0
    assert counts2["skipped"] == 2


# ---------------------------------------------------------------------------
# tmp+os.replace rewrite pattern (no leftover tmp file)
# ---------------------------------------------------------------------------

def test_mark_events_no_leftover_tmp_file(monkeypatch, tmp_path):
    """After a successful mark, no .tmp file should remain in the store directory."""
    _patch_store(monkeypatch, tmp_path)
    store_dir = friction_store._STORE_DIR

    for i in range(3):
        friction_store.append_event(_make_event(suffix=str(i)))

    ids = {eid for eid, _ in friction_store.iter_events()}
    friction_store.mark_events(ids, set())

    tmp_files = list(store_dir.glob("*.tmp"))
    assert tmp_files == [], f"Leftover tmp files after mark: {tmp_files}"


# ---------------------------------------------------------------------------
# US-006: redaction and file mode
# ---------------------------------------------------------------------------

def test_append_redacts_prompt_field(monkeypatch, tmp_path):
    """append_event must redact secrets in previous_prompt and current_prompt."""
    _patch_store(monkeypatch, tmp_path)

    secret_key = "sk-" + "x" * 25
    event = {
        "ts": "2026-01-01T00:00:00+00:00",
        "session_id": "s1",
        "frame": "aimi:plan",
        "scope": "project",
        "previous_prompt": f"Here is my key: {secret_key}",
        "current_prompt": f"Use {secret_key} for auth",
    }
    friction_store.append_event(event)

    stored = list(friction_store.read_pending())
    assert len(stored) == 1
    rec = stored[0]
    assert secret_key not in rec.get("previous_prompt", "")
    assert secret_key not in rec.get("current_prompt", "")
    assert "[REDACTED:sk-token]" in rec.get("previous_prompt", "")
    assert "[REDACTED:sk-token]" in rec.get("current_prompt", "")


def test_jsonl_file_mode_is_0600(monkeypatch, tmp_path):
    """A newly created JSONL file must have mode 0600."""
    _patch_store(monkeypatch, tmp_path)

    friction_store.append_event(_make_event())

    files = friction_store.all_date_files()
    assert len(files) == 1
    mode = oct(files[0].stat().st_mode & 0o777)
    assert mode == oct(0o600), f"Expected 0600, got {mode}"
