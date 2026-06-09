from __future__ import annotations

import importlib.util
import io
import json
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

_HOOKS_DIR = Path(__file__).parent.parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

import friction_store  # noqa: E402


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _load_hook():
    """Load inspect-session.py as a module."""
    mod_name = "inspect_session"
    spec = importlib.util.spec_from_file_location(
        mod_name, _HOOKS_DIR / "inspect-session.py"
    )
    mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def _run_hook(monkeypatch, tmp_path: Path, payload: dict | None = None) -> str:
    """Run the hook with mocked stdin and return captured stdout."""
    if payload is None:
        payload = {}
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))
    monkeypatch.setattr(friction_store, "_STORE_DIR", tmp_path / ".aimi" / "learnings")

    mod = _load_hook()

    captured = io.StringIO()
    monkeypatch.setattr("sys.stdout", captured)

    with pytest.raises(SystemExit) as exc_info:
        mod.main()
    assert exc_info.value.code == 0

    return captured.getvalue()


def _write_friction_events(
    tmp_path: Path,
    count: int,
    scope: str = "plugin",
    scopes: list[str] | None = None,
) -> None:
    """Write friction events to the store."""
    store_dir = tmp_path / ".aimi" / "learnings"
    store_dir.mkdir(parents=True, exist_ok=True)
    date_str = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d")
    events_file = store_dir / f"{date_str}.jsonl"
    with events_file.open("a", encoding="utf-8") as fh:
        for i in range(count):
            s = scopes[i] if scopes else scope
            event = {
                "ts": datetime.now(tz=timezone.utc).isoformat(),
                "session_id": "default",
                "frame": "aimi:plan",
                "scope": s,
                "previous_prompt": f"prev {i}",
                "current_prompt": f"curr {i}",
            }
            fh.write(json.dumps(event) + "\n")


def _write_telemetry(
    tmp_path: Path,
    category: str,
    entries: list[dict],
) -> None:
    """Write telemetry entries to ~/.aimi/telemetry/<category>.jsonl."""
    tdir = tmp_path / ".aimi" / "telemetry"
    tdir.mkdir(parents=True, exist_ok=True)
    target = tdir / f"{category}.jsonl"
    with target.open("a", encoding="utf-8") as fh:
        for entry in entries:
            fh.write(json.dumps(entry) + "\n")


def _now_iso() -> str:
    return datetime.now(tz=timezone.utc).isoformat()


def _old_iso(hours: int = 25) -> str:
    """Return an ISO timestamp older than `hours` hours ago."""
    return (datetime.now(tz=timezone.utc) - timedelta(hours=hours)).isoformat()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_silent_when_all_zero(monkeypatch, tmp_path):
    """No friction, no telemetry → no stdout output."""
    output = _run_hook(monkeypatch, tmp_path)
    assert output.strip() == ""


def test_banner_with_friction_only(monkeypatch, tmp_path):
    """3 friction events → banner shows pending friction line."""
    _write_friction_events(tmp_path, 3, scope="project")

    output = _run_hook(monkeypatch, tmp_path)
    assert output.strip() != ""

    data = json.loads(output.strip())
    banner = data["hookSpecificOutput"]["additionalContext"]
    assert "[aimi session]" in banner
    assert "pending friction: 3" in banner
    assert "Run /aimi:learnings to triage." in banner


def test_banner_scope_breakdown_counts_correct(monkeypatch, tmp_path):
    """2 project, 1 plugin, 1 inbox → 'project: 2 / plugin: 1 / inbox: 1'."""
    _write_friction_events(
        tmp_path,
        4,
        scopes=["project", "project", "plugin", "inbox"],
    )

    output = _run_hook(monkeypatch, tmp_path)
    data = json.loads(output.strip())
    banner = data["hookSpecificOutput"]["additionalContext"]

    assert "project: 2" in banner
    assert "plugin: 1" in banner
    assert "inbox: 1" in banner


def test_banner_includes_top_5_skills(monkeypatch, tmp_path):
    """7 distinct skills → banner shows only top 5."""
    # Write 7 distinct skills with decreasing counts
    skills_entries = []
    for i in range(7):
        skill_name = f"skill-{i:02d}"
        count = 10 - i  # skill-00 has 10 hits, skill-06 has 4 hits
        for _ in range(count):
            skills_entries.append({"ts": _now_iso(), "skill": skill_name})

    _write_telemetry(tmp_path, "skills", skills_entries)
    # Need at least 1 friction event so we don't hit the empty-state exit
    _write_friction_events(tmp_path, 1)

    output = _run_hook(monkeypatch, tmp_path)
    data = json.loads(output.strip())
    banner = data["hookSpecificOutput"]["additionalContext"]

    # Count how many skill× entries appear
    skill_markers = [part for part in banner.split(",") if "×" in part]
    # skills last 24h line may have 5 comma-separated entries
    skills_line = [line for line in banner.splitlines() if "skills last 24h" in line]
    assert len(skills_line) == 1
    top_skills_str = skills_line[0].split("skills last 24h:")[1].strip()
    top_skills = [s.strip() for s in top_skills_str.split(",")]
    assert len(top_skills) == 5


def test_banner_skills_ordered_by_count_desc(monkeypatch, tmp_path):
    """Skills are sorted by count descending."""
    skills_entries = []
    # skill-A: 3, skill-B: 7, skill-C: 1
    for name, count in [("skill-A", 3), ("skill-B", 7), ("skill-C", 1)]:
        for _ in range(count):
            skills_entries.append({"ts": _now_iso(), "skill": name})

    _write_telemetry(tmp_path, "skills", skills_entries)
    _write_friction_events(tmp_path, 1)

    output = _run_hook(monkeypatch, tmp_path)
    data = json.loads(output.strip())
    banner = data["hookSpecificOutput"]["additionalContext"]

    skills_line = [line for line in banner.splitlines() if "skills last 24h" in line][0]
    # skill-B×7 should appear before skill-A×3 which should appear before skill-C×1
    pos_b = skills_line.find("skill-B")
    pos_a = skills_line.find("skill-A")
    pos_c = skills_line.find("skill-C")
    assert pos_b < pos_a < pos_c


def test_banner_reads_count_correct(monkeypatch, tmp_path):
    """12 read events in last 24h → banner shows 'reads last 24h: 12'."""
    read_entries = [{"ts": _now_iso(), "path": f"/file{i}.py"} for i in range(12)]
    _write_telemetry(tmp_path, "reads", read_entries)
    _write_friction_events(tmp_path, 1)

    output = _run_hook(monkeypatch, tmp_path)
    data = json.loads(output.strip())
    banner = data["hookSpecificOutput"]["additionalContext"]

    assert "reads last 24h: 12" in banner


def test_banner_skips_telemetry_outside_24h(monkeypatch, tmp_path):
    """Old telemetry entries (>24h) are excluded from counts."""
    # Write 5 old entries and 2 recent entries
    old_ts = _old_iso(hours=30)
    recent_ts = _now_iso()

    read_entries = [{"ts": old_ts, "path": "/old.py"} for _ in range(5)]
    read_entries += [{"ts": recent_ts, "path": "/new.py"} for _ in range(2)]
    _write_telemetry(tmp_path, "reads", read_entries)
    _write_friction_events(tmp_path, 1)

    output = _run_hook(monkeypatch, tmp_path)
    data = json.loads(output.strip())
    banner = data["hookSpecificOutput"]["additionalContext"]

    assert "reads last 24h: 2" in banner


def test_banner_respects_quiet_mode(monkeypatch, tmp_path):
    """is_quiet_mode() True → no output."""
    _write_friction_events(tmp_path, 3)

    import hook_utils
    monkeypatch.setattr(hook_utils, "is_quiet_mode", lambda: True)

    # Reload module so it picks up the monkeypatched is_quiet_mode
    mod = _load_hook()
    monkeypatch.setattr(mod, "is_quiet_mode", lambda: True)

    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    monkeypatch.setattr("sys.stdin", io.StringIO("{}"))
    monkeypatch.setattr(friction_store, "_STORE_DIR", tmp_path / ".aimi" / "learnings")

    captured = io.StringIO()
    monkeypatch.setattr("sys.stdout", captured)

    with pytest.raises(SystemExit) as exc_info:
        mod.main()
    assert exc_info.value.code == 0
    assert captured.getvalue().strip() == ""


def test_banner_respects_banner_disabled(monkeypatch, tmp_path, capsys):
    """.aimi/config.json banner.enabled false → no output."""
    _write_friction_events(tmp_path, 3)

    # Write config with banner.enabled = false
    aimi_dir = tmp_path / ".aimi"
    aimi_dir.mkdir(parents=True, exist_ok=True)
    (aimi_dir / "config.json").write_text(
        json.dumps({"banner": {"enabled": False}}), encoding="utf-8"
    )

    # Change cwd so the config is found by walk-up
    monkeypatch.chdir(str(tmp_path))

    output = _run_hook(monkeypatch, tmp_path)
    assert output.strip() == ""


def test_banner_time_budget_skips_telemetry_section(monkeypatch, tmp_path):
    """When time budget is exceeded before reading reads.jsonl, telemetry section is skipped."""
    # Write friction and telemetry data
    _write_friction_events(tmp_path, 2, scope="project")
    read_entries = [{"ts": _now_iso(), "path": f"/file{i}.py"} for i in range(5)]
    _write_telemetry(tmp_path, "reads", read_entries)
    skill_entries = [{"ts": _now_iso(), "skill": "my-skill"} for _ in range(3)]
    _write_telemetry(tmp_path, "skills", skill_entries)

    # Monkeypatch time.monotonic to simulate budget exceeded
    # We want: first call returns 0.0, subsequent calls return a value > 0.5
    import time as _time_module

    call_count = [0]
    original_monotonic = _time_module.monotonic

    def fake_monotonic():
        call_count[0] += 1
        if call_count[0] == 1:
            return 0.0  # t_start
        # All subsequent calls return past budget
        return 0.6  # exceeds 0.5s budget

    mod = _load_hook()
    monkeypatch.setattr(mod, "time", type("FakeTime", (), {"monotonic": staticmethod(fake_monotonic)})())

    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    monkeypatch.setattr("sys.stdin", io.StringIO("{}"))
    monkeypatch.setattr(friction_store, "_STORE_DIR", tmp_path / ".aimi" / "learnings")

    captured = io.StringIO()
    monkeypatch.setattr("sys.stdout", captured)

    with pytest.raises(SystemExit) as exc_info:
        mod.main()
    assert exc_info.value.code == 0

    output = captured.getvalue().strip()
    assert output != "", "Expected banner output with friction"

    data = json.loads(output)
    banner = data["hookSpecificOutput"]["additionalContext"]

    # Banner should show friction but NOT skills or reads telemetry
    assert "pending friction" in banner
    assert "skills last 24h" not in banner
    assert "reads last 24h" not in banner
