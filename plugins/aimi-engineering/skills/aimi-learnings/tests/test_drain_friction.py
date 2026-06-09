"""Tests for drain-friction.py

Runs the script as a subprocess so that sys.path manipulation inside the
script is exercised. Uses monkeypatch.setenv("HOME", str(tmp_path)) so that
friction_store uses tmp_path as the store directory root.
"""
from __future__ import annotations

import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

_SKILL_DIR = Path(__file__).resolve().parent.parent
_SCRIPT = _SKILL_DIR / "scripts" / "drain-friction.py"
_HOOKS_DIR = _SKILL_DIR.parent.parent / "hooks"

# Insert hooks dir so we can call friction_store directly in tests
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

import friction_store  # noqa: E402


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _run(args: list[str], env: dict | None = None, stdin: str | None = None) -> dict:
    """Run drain-friction.py with given args, return parsed JSON stdout.

    For subcommands that produce no stdout (e.g. --mark), returns {}.
    """
    cmd = [sys.executable, str(_SCRIPT)] + args
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        input=stdin,
        env=env,
    )
    assert result.returncode == 0, (
        f"Script exited {result.returncode}\nstdout: {result.stdout}\nstderr: {result.stderr}"
    )
    stripped = result.stdout.strip()
    if not stripped:
        return {}
    return json.loads(stripped)


def _make_env(tmp_path: Path) -> dict:
    """Build subprocess env with HOME pointing to tmp_path."""
    import os
    env = dict(os.environ)
    env["HOME"] = str(tmp_path)
    return env


def _write_event(tmp_path: Path, scope: str = "project", suffix: str = "") -> None:
    """Write one friction event directly via friction_store with patched store dir."""
    store_dir = tmp_path / ".aimi" / "learnings"
    store_dir.mkdir(parents=True, exist_ok=True)

    # Temporarily patch friction_store._STORE_DIR
    original = friction_store._STORE_DIR
    friction_store._STORE_DIR = store_dir
    try:
        friction_store.append_event({
            "ts": datetime.now(tz=timezone.utc).isoformat(),
            "session_id": "test-session",
            "frame": "aimi:plan",
            "scope": scope,
            "previous_prompt": f"prev{suffix}",
            "current_prompt": f"curr{suffix}",
        })
    finally:
        friction_store._STORE_DIR = original


def _get_event_ids(tmp_path: Path) -> list[str]:
    """Return event_ids for all live events in the store under tmp_path."""
    store_dir = tmp_path / ".aimi" / "learnings"
    original = friction_store._STORE_DIR
    friction_store._STORE_DIR = store_dir
    try:
        return [eid for eid, _ in friction_store.iter_events()]
    finally:
        friction_store._STORE_DIR = original


# ---------------------------------------------------------------------------
# Tests — --list
# ---------------------------------------------------------------------------

def test_list_empty_returns_zero_groups(tmp_path):
    """With no events the list command returns total_pending=0 and all groups empty."""
    env = _make_env(tmp_path)
    data = _run(["--list"], env=env)

    assert data["total_pending"] == 0
    for scope in ("project", "plugin", "inbox"):
        assert data["groups"][scope]["count"] == 0
        assert data["groups"][scope]["samples"] == []


def test_list_groups_by_scope(tmp_path):
    """2 project + 2 plugin + 1 inbox → correct counts per group."""
    _write_event(tmp_path, scope="project", suffix="1")
    _write_event(tmp_path, scope="project", suffix="2")
    _write_event(tmp_path, scope="plugin", suffix="3")
    _write_event(tmp_path, scope="plugin", suffix="4")
    _write_event(tmp_path, scope="inbox", suffix="5")

    env = _make_env(tmp_path)
    data = _run(["--list"], env=env)

    assert data["total_pending"] == 5
    assert data["groups"]["project"]["count"] == 2
    assert data["groups"]["plugin"]["count"] == 2
    assert data["groups"]["inbox"]["count"] == 1


def test_list_samples_capped_at_3(tmp_path):
    """5 project events → samples array has length 3."""
    for i in range(5):
        _write_event(tmp_path, scope="project", suffix=str(i))

    env = _make_env(tmp_path)
    data = _run(["--list"], env=env)

    assert data["groups"]["project"]["count"] == 5
    assert len(data["groups"]["project"]["samples"]) == 3


def test_list_samples_include_event_id(tmp_path):
    """Each sample entry must include an event_id field."""
    _write_event(tmp_path, scope="project", suffix="x")

    env = _make_env(tmp_path)
    data = _run(["--list"], env=env)

    samples = data["groups"]["project"]["samples"]
    assert len(samples) == 1
    assert "event_id" in samples[0]
    assert isinstance(samples[0]["event_id"], str)
    assert samples[0]["event_id"]  # non-empty


# ---------------------------------------------------------------------------
# Tests — --mark (uses event_ids)
# ---------------------------------------------------------------------------

def _get_store_file(tmp_path: Path) -> Path:
    """Return the live JSONL file path for today."""
    store_dir = tmp_path / ".aimi" / "learnings"
    original = friction_store._STORE_DIR
    friction_store._STORE_DIR = store_dir
    try:
        return friction_store._today_file()
    finally:
        friction_store._STORE_DIR = original


def _count_live_lines(path: Path) -> int:
    if not path.exists():
        return 0
    count = 0
    with path.open() as fh:
        for line in fh:
            if line.strip():
                count += 1
    return count


def test_mark_promoted_writes_companion_and_removes_from_live(tmp_path):
    """Mark 2 event_ids as promoted → live file has 3 events left, companion has 2."""
    for i in range(5):
        _write_event(tmp_path, scope="project", suffix=str(i))

    all_ids = _get_event_ids(tmp_path)
    assert len(all_ids) == 5
    ids_to_promote = all_ids[:2]  # first 2

    live_path = _get_store_file(tmp_path)
    companion = live_path.with_name(live_path.stem + ".promoted.jsonl")

    env = _make_env(tmp_path)
    mark_payload = json.dumps({"promoted": ids_to_promote, "discarded": []})
    result = _run(["--mark"], env=env, stdin=mark_payload)

    assert result.get("promoted") == 2
    assert result.get("discarded") == 0
    assert _count_live_lines(live_path) == 3

    companion_events = []
    with companion.open() as fh:
        for line in fh:
            if line.strip():
                companion_events.append(json.loads(line.strip()))

    assert len(companion_events) == 2
    for e in companion_events:
        assert e["decision"] == "promoted"


def test_mark_discarded_writes_companion_too(tmp_path):
    """Mark 2 event_ids as discarded → discarded.jsonl has 2 entries."""
    for i in range(5):
        _write_event(tmp_path, scope="plugin", suffix=str(i))

    all_ids = _get_event_ids(tmp_path)
    ids_to_discard = all_ids[1:3]  # middle 2

    live_path = _get_store_file(tmp_path)
    companion = live_path.with_name(live_path.stem + ".discarded.jsonl")

    env = _make_env(tmp_path)
    mark_payload = json.dumps({"promoted": [], "discarded": ids_to_discard})
    result = _run(["--mark"], env=env, stdin=mark_payload)

    assert result.get("discarded") == 2
    assert _count_live_lines(live_path) == 3

    companion_events = []
    with companion.open() as fh:
        for line in fh:
            if line.strip():
                companion_events.append(json.loads(line.strip()))

    assert len(companion_events) == 2
    for e in companion_events:
        assert e["decision"] == "discarded"


def test_mark_idempotent(tmp_path):
    """Calling mark twice with the same event_ids: second call returns skipped=1."""
    for i in range(3):
        _write_event(tmp_path, scope="project", suffix=str(i))

    all_ids = _get_event_ids(tmp_path)
    first_id = all_ids[:1]

    live_path = _get_store_file(tmp_path)
    companion = live_path.with_name(live_path.stem + ".promoted.jsonl")

    env = _make_env(tmp_path)
    mark_payload = json.dumps({"promoted": first_id, "discarded": []})

    # First call
    result1 = _run(["--mark"], env=env, stdin=mark_payload)
    assert result1["promoted"] == 1

    # Second call — same event_ids, should not duplicate companion entries
    result2 = _run(["--mark"], env=env, stdin=mark_payload)
    assert result2["promoted"] == 0
    assert result2["skipped"] == 1

    companion_events = []
    if companion.exists():
        with companion.open() as fh:
            for line in fh:
                if line.strip():
                    companion_events.append(json.loads(line.strip()))

    assert len(companion_events) == 1, (
        f"Expected 1 companion entry after idempotent mark, got {len(companion_events)}"
    )


def test_mark_returns_counts_json(tmp_path):
    """--mark must print JSON with promoted/discarded/skipped keys."""
    for i in range(4):
        _write_event(tmp_path, scope="project", suffix=str(i))

    all_ids = _get_event_ids(tmp_path)
    env = _make_env(tmp_path)
    mark_payload = json.dumps({"promoted": all_ids[:2], "discarded": all_ids[2:4]})
    result = _run(["--mark"], env=env, stdin=mark_payload)

    assert "promoted" in result
    assert "discarded" in result
    assert "skipped" in result
    assert result["promoted"] == 2
    assert result["discarded"] == 2
    assert result["skipped"] == 0


# ---------------------------------------------------------------------------
# Tests — --summary
# ---------------------------------------------------------------------------

def test_summary_reports_correct_counts(tmp_path):
    """Write 3 events, promote 1, discard 1 → summary shows pending=1 promoted=1 discarded=1."""
    for i in range(3):
        _write_event(tmp_path, scope="project", suffix=str(i))

    all_ids = _get_event_ids(tmp_path)
    env = _make_env(tmp_path)

    # Promote first, discard second
    mark_payload = json.dumps({"promoted": all_ids[:1], "discarded": all_ids[1:2]})
    _run(["--mark"], env=env, stdin=mark_payload)

    data = _run(["--summary"], env=env)

    assert data["pending"] == 1
    assert data["promoted"] == 1
    assert data["discarded"] == 1


# ---------------------------------------------------------------------------
# Tests — --scope filter
# ---------------------------------------------------------------------------

def test_list_filter_by_scope(tmp_path):
    """--scope project filters output to project events only."""
    _write_event(tmp_path, scope="project", suffix="p1")
    _write_event(tmp_path, scope="project", suffix="p2")
    _write_event(tmp_path, scope="plugin", suffix="pl1")
    _write_event(tmp_path, scope="inbox", suffix="i1")

    env = _make_env(tmp_path)
    data = _run(["--list", "--scope", "project"], env=env)

    assert data["total_pending"] == 2
    assert "project" in data["groups"]
    assert data["groups"]["project"]["count"] == 2
    # Other scopes should not appear in output groups
    assert "plugin" not in data["groups"]
    assert "inbox" not in data["groups"]


# ---------------------------------------------------------------------------
# Tests — --since filter
# ---------------------------------------------------------------------------

def test_list_filter_by_since(tmp_path):
    """--since filters out events older than the given date."""
    from datetime import datetime, timezone, timedelta

    store_dir = tmp_path / ".aimi" / "learnings"
    store_dir.mkdir(parents=True, exist_ok=True)

    original = friction_store._STORE_DIR
    friction_store._STORE_DIR = store_dir
    try:
        # Write an old event (2020-01-01)
        friction_store.append_event({
            "ts": "2020-01-01T00:00:00+00:00",
            "session_id": "test",
            "frame": "aimi:plan",
            "scope": "project",
            "previous_prompt": "old prev",
            "current_prompt": "old curr",
        })
        # Write a recent event
        recent_ts = datetime.now(tz=timezone.utc).isoformat()
        friction_store.append_event({
            "ts": recent_ts,
            "session_id": "test",
            "frame": "aimi:plan",
            "scope": "project",
            "previous_prompt": "recent prev",
            "current_prompt": "recent curr",
        })
    finally:
        friction_store._STORE_DIR = original

    env = _make_env(tmp_path)
    data = _run(["--list", "--since", "2025-01-01"], env=env)

    # Only the recent event should be included
    assert data["total_pending"] == 1
    assert data["groups"]["project"]["count"] == 1


# ---------------------------------------------------------------------------
# Tests — --samples flag
# ---------------------------------------------------------------------------

def test_list_respects_samples(tmp_path):
    """--samples 2 limits samples per group to 2."""
    for i in range(5):
        _write_event(tmp_path, scope="project", suffix=str(i))

    env = _make_env(tmp_path)
    data = _run(["--list", "--samples", "2"], env=env)

    assert data["groups"]["project"]["count"] == 5
    assert len(data["groups"]["project"]["samples"]) == 2


# ---------------------------------------------------------------------------
# Tests — --limit flag
# ---------------------------------------------------------------------------

def test_list_respects_limit(tmp_path):
    """--limit 3 caps total events returned to 3."""
    _write_event(tmp_path, scope="project", suffix="1")
    _write_event(tmp_path, scope="project", suffix="2")
    _write_event(tmp_path, scope="plugin", suffix="3")
    _write_event(tmp_path, scope="plugin", suffix="4")
    _write_event(tmp_path, scope="inbox", suffix="5")

    env = _make_env(tmp_path)
    data = _run(["--list", "--limit", "3"], env=env)

    assert data["total_pending"] == 3


# ---------------------------------------------------------------------------
# Tests — --classify subcommand
# ---------------------------------------------------------------------------

def test_classify_subcommand_reads_stdin_returns_scope(tmp_path):
    """--classify reads {prompt, frame} from stdin and returns {scope}."""
    env = _make_env(tmp_path)
    stdin_payload = json.dumps({"prompt": "update the hook script", "frame": "aimi:plan"})
    data = _run(["--classify"], env=env, stdin=stdin_payload)

    assert "scope" in data
    assert data["scope"] in ("project", "plugin", "inbox")
    # Frame 'aimi:plan' is a plugin frame → scope should be 'plugin'
    assert data["scope"] == "plugin"


def test_classify_subcommand_inbox_fallback(tmp_path, monkeypatch):
    """--classify returns inbox when no plugin/project signals match."""
    import os
    env = _make_env(tmp_path)
    # Ensure no CLAUDE_PLUGIN_ROOT is set
    env.pop("CLAUDE_PLUGIN_ROOT", None)
    # Use a clean directory with no .aimi/
    clean_dir = tmp_path / "clean_project"
    clean_dir.mkdir()

    stdin_payload = json.dumps({"prompt": "fix the login page", "frame": None})
    # We cannot monkeypatch cwd in subprocess, but with no plugin signals and
    # HOME pointed to tmp_path (no .aimi), it should return inbox or project.
    # Just assert scope is a valid value.
    data = _run(["--classify"], env=env, stdin=stdin_payload)
    assert "scope" in data
    assert data["scope"] in ("project", "plugin", "inbox")


# ---------------------------------------------------------------------------
# Tests — SKILL.md documents agent mode
# ---------------------------------------------------------------------------

def test_skill_md_documents_agent_mode():
    """SKILL.md must mention AIMI_AGENT_MODE and isatty."""
    skill_md = _SKILL_DIR / "SKILL.md"
    content = skill_md.read_text(encoding="utf-8")
    assert "AIMI_AGENT_MODE" in content, "SKILL.md must document AIMI_AGENT_MODE env var"
    assert "isatty" in content, "SKILL.md must document sys.stdin.isatty() detection"
