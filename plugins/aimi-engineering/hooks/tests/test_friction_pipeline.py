from __future__ import annotations

import io
import importlib
import importlib.util
import json
import os
import sys
import time
from pathlib import Path

import pytest

# Insert the hooks directory onto sys.path so we can import modules directly.
_HOOKS_DIR = Path(__file__).parent.parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

import scope_classifier  # noqa: E402
import friction_store  # noqa: E402
import frame_helpers  # noqa: E402
from frame_helpers import SkillFrame  # noqa: E402


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _session_dir(tmp_path: Path, sid: str = "default") -> Path:
    return tmp_path / ".aimi" / "session" / sid


def _write_frame(tmp_path: Path, sid: str = "default", name: str = "aimi:plan") -> Path:
    """Write a skill-stack.jsonl with one frame entry and return the dir."""
    sess_dir = _session_dir(tmp_path, sid)
    sess_dir.mkdir(parents=True, exist_ok=True)
    stack_file = sess_dir / "skill-stack.jsonl"
    entry = json.dumps({"name": name, "started_at": "2024-01-01T00:00:00+00:00"})
    stack_file.write_text(entry + "\n", encoding="utf-8")
    return sess_dir


def _write_last_prompt(tmp_path: Path, text: str, sid: str = "default", age_secs: float = 0) -> Path:
    """Write last-prompt.txt and optionally backdate its mtime."""
    sess_dir = _session_dir(tmp_path, sid)
    sess_dir.mkdir(parents=True, exist_ok=True)
    prompt_file = sess_dir / "last-prompt.txt"
    prompt_file.write_text(text, encoding="utf-8")
    if age_secs > 0:
        old_mtime = time.time() - age_secs
        os.utime(str(prompt_file), (old_mtime, old_mtime))
    return prompt_file


def _load_hook_module(filename: str, module_name: str):
    """Load a hook Python file by path."""
    spec = importlib.util.spec_from_file_location(module_name, _HOOKS_DIR / filename)
    mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def _run_capture_hook(monkeypatch, tmp_path: Path, payload: dict) -> None:
    """Run capture-correction.py main() with a mocked stdin."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))

    # Patch frame_helpers._session_dir to use tmp_path
    monkeypatch.setattr(frame_helpers, "_session_dir",
                        lambda sid: tmp_path / ".aimi" / "session" / sid)

    # Patch friction_store._STORE_DIR to use tmp_path
    monkeypatch.setattr(friction_store, "_STORE_DIR", tmp_path / ".aimi" / "learnings")

    mod = _load_hook_module("capture-correction.py", "capture_correction_mod")

    with pytest.raises(SystemExit) as exc_info:
        mod.main()
    assert exc_info.value.code == 0


def _run_gate_hook(monkeypatch, tmp_path: Path, payload: dict, cwd: str | None = None) -> str:
    """Run gate-friction-threshold.py main() and return captured stdout."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))

    # Patch friction_store._STORE_DIR to use tmp_path
    monkeypatch.setattr(friction_store, "_STORE_DIR", tmp_path / ".aimi" / "learnings")

    if cwd is not None:
        monkeypatch.chdir(cwd)

    mod = _load_hook_module("gate-friction-threshold.py", "gate_friction_threshold_mod")

    import io as _io
    captured = _io.StringIO()
    monkeypatch.setattr("sys.stdout", captured)

    with pytest.raises(SystemExit) as exc_info:
        mod.main()
    assert exc_info.value.code == 0

    return captured.getvalue()


def _write_friction_events(tmp_path: Path, count: int) -> None:
    """Write N fake friction events to the store."""
    store_dir = tmp_path / ".aimi" / "learnings"
    store_dir.mkdir(parents=True, exist_ok=True)
    from datetime import datetime, timezone
    date_str = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d")
    events_file = store_dir / f"{date_str}.jsonl"
    with events_file.open("a", encoding="utf-8") as fh:
        for i in range(count):
            event = {"ts": "2024-01-01T00:00:00+00:00", "session_id": "default",
                     "frame": "aimi:plan", "scope": "plugin",
                     "previous_prompt": f"prev {i}", "current_prompt": f"curr {i}"}
            fh.write(json.dumps(event) + "\n")


# ===========================================================================
# scope_classifier tests
# ===========================================================================

def test_classify_plugin_via_frame_name():
    """frame 'aimi:plan' → 'plugin'"""
    result = scope_classifier.classify_scope("do something", "aimi:plan")
    assert result == "plugin"


def test_classify_plugin_via_frame_name_aimi_engineering():
    """frame 'aimi-engineering:review' → 'plugin'"""
    result = scope_classifier.classify_scope("do something", "aimi-engineering:review")
    assert result == "plugin"


def test_classify_plugin_via_prompt_keywords():
    """Prompt containing 'hook' → 'plugin'"""
    result = scope_classifier.classify_scope("change the hook to use async", None)
    assert result == "plugin"


def test_classify_plugin_via_skill_keyword():
    """Prompt containing 'skill' → 'plugin'"""
    result = scope_classifier.classify_scope("update the skill definition", None)
    assert result == "plugin"


def test_classify_plugin_via_hooks_json_keyword():
    """Prompt containing 'hooks.json' → 'plugin'"""
    result = scope_classifier.classify_scope("modify the hooks.json file", None)
    assert result == "plugin"


def test_classify_project_via_walk_up_aimi(tmp_path, monkeypatch):
    """tmp_path with .aimi/, no plugin indicators → 'project'"""
    # Create a .aimi directory under tmp_path
    aimi_dir = tmp_path / ".aimi"
    aimi_dir.mkdir()

    # Change cwd to somewhere under tmp_path
    sub = tmp_path / "myproject" / "src"
    sub.mkdir(parents=True)
    monkeypatch.chdir(str(sub))
    monkeypatch.delenv("CLAUDE_PLUGIN_ROOT", raising=False)

    result = scope_classifier.classify_scope("fix the bug in login flow", None)
    assert result == "project"


def test_classify_inbox_default(tmp_path, monkeypatch):
    """No signals → 'inbox'"""
    # No .aimi dir, no frame, no plugin keywords, no CLAUDE_PLUGIN_ROOT
    clean_dir = tmp_path / "clean"
    clean_dir.mkdir()
    monkeypatch.chdir(str(clean_dir))
    monkeypatch.delenv("CLAUDE_PLUGIN_ROOT", raising=False)

    result = scope_classifier.classify_scope("fix the login page", None)
    assert result == "inbox"


# ===========================================================================
# capture-correction.py tests
# ===========================================================================

def test_capture_skips_when_no_correction_pattern(monkeypatch, tmp_path):
    """No correction pattern → no friction event written."""
    _write_frame(tmp_path)
    _write_last_prompt(tmp_path, "please refactor the service layer")

    payload = {"prompt": "continue with the refactoring"}
    _run_capture_hook(monkeypatch, tmp_path, payload)

    events = list(friction_store.read_pending())
    assert len(events) == 0


def test_capture_skips_when_no_active_frame(monkeypatch, tmp_path):
    """No active frame → no friction event written (even with correction pattern)."""
    # Do NOT write any frame stack file
    _write_last_prompt(tmp_path, "do something")

    payload = {"prompt": "wait, not actually what I meant"}
    _run_capture_hook(monkeypatch, tmp_path, payload)

    events = list(friction_store.read_pending())
    assert len(events) == 0


def test_capture_skips_when_previous_prompt_stale(monkeypatch, tmp_path):
    """Previous prompt older than 5 minutes → no event written."""
    _write_frame(tmp_path)
    # Write last-prompt.txt with mtime > 300 seconds ago
    _write_last_prompt(tmp_path, "old prompt text", age_secs=400)

    payload = {"prompt": "não, na verdade use httpx"}
    _run_capture_hook(monkeypatch, tmp_path, payload)

    events = list(friction_store.read_pending())
    assert len(events) == 0


def test_capture_writes_event_with_full_shape(monkeypatch, tmp_path):
    """Mock everything, run hook, assert friction_store.read_pending yields one event with correct keys."""
    _write_frame(tmp_path, name="aimi:plan")
    _write_last_prompt(tmp_path, "use requests library")

    # Patch friction_store._STORE_DIR before running
    monkeypatch.setattr(friction_store, "_STORE_DIR", tmp_path / ".aimi" / "learnings")
    monkeypatch.setattr(frame_helpers, "_session_dir",
                        lambda sid: tmp_path / ".aimi" / "session" / sid)

    payload = {"prompt": "wait, should be httpx instead"}
    _run_capture_hook(monkeypatch, tmp_path, payload)

    events = list(friction_store.read_pending())
    assert len(events) == 1
    event = events[0]
    assert "ts" in event
    assert "session_id" in event
    assert "frame" in event
    assert "scope" in event
    assert "previous_prompt" in event
    assert "current_prompt" in event
    assert event["frame"] == "aimi:plan"
    assert event["current_prompt"] == "wait, should be httpx instead"
    assert event["previous_prompt"] == "use requests library"


def test_capture_detects_pt_br_pattern(monkeypatch, tmp_path):
    """'não, na verdade use httpx' → event written"""
    _write_frame(tmp_path, name="aimi:plan")
    _write_last_prompt(tmp_path, "use requests para chamadas HTTP")

    monkeypatch.setattr(friction_store, "_STORE_DIR", tmp_path / ".aimi" / "learnings")
    monkeypatch.setattr(frame_helpers, "_session_dir",
                        lambda sid: tmp_path / ".aimi" / "session" / sid)

    payload = {"prompt": "não, na verdade use httpx"}
    _run_capture_hook(monkeypatch, tmp_path, payload)

    events = list(friction_store.read_pending())
    assert len(events) == 1
    assert events[0]["current_prompt"] == "não, na verdade use httpx"


def test_capture_detects_english_pattern(monkeypatch, tmp_path):
    """'not actually, use FastAPI' → event written"""
    _write_frame(tmp_path, name="aimi:plan")
    _write_last_prompt(tmp_path, "use Flask for the web server")

    monkeypatch.setattr(friction_store, "_STORE_DIR", tmp_path / ".aimi" / "learnings")
    monkeypatch.setattr(frame_helpers, "_session_dir",
                        lambda sid: tmp_path / ".aimi" / "session" / sid)

    payload = {"prompt": "not actually, use FastAPI"}
    _run_capture_hook(monkeypatch, tmp_path, payload)

    events = list(friction_store.read_pending())
    assert len(events) == 1
    assert events[0]["current_prompt"] == "not actually, use FastAPI"


def test_capture_skips_when_no_previous_prompt_file(monkeypatch, tmp_path):
    """No last-prompt.txt file → exit 0, no event written."""
    _write_frame(tmp_path, name="aimi:plan")
    # Do NOT write last-prompt.txt

    monkeypatch.setattr(friction_store, "_STORE_DIR", tmp_path / ".aimi" / "learnings")
    monkeypatch.setattr(frame_helpers, "_session_dir",
                        lambda sid: tmp_path / ".aimi" / "session" / sid)

    payload = {"prompt": "wait, should be httpx"}
    _run_capture_hook(monkeypatch, tmp_path, payload)

    events = list(friction_store.read_pending())
    assert len(events) == 0


def test_capture_does_not_match_weak_phrase(monkeypatch, tmp_path):
    """Weak signal phrases like 'espera, vou pensar nisso' do NOT trigger capture-correction."""
    _write_frame(tmp_path, name="aimi:plan")
    _write_last_prompt(tmp_path, "vou implementar o módulo de login")

    monkeypatch.setattr(friction_store, "_STORE_DIR", tmp_path / ".aimi" / "learnings")
    monkeypatch.setattr(frame_helpers, "_session_dir",
                        lambda sid: tmp_path / ".aimi" / "session" / sid)

    payload = {"prompt": "espera, vou pensar nisso"}
    _run_capture_hook(monkeypatch, tmp_path, payload)

    events = list(friction_store.read_pending())
    assert len(events) == 0


# ===========================================================================
# gate-friction-threshold.py tests
# ===========================================================================

def test_gate_emits_advisory_when_above_threshold(monkeypatch, tmp_path):
    """6 events, threshold=5 → JSON with additionalContext emitted to stdout."""
    _write_friction_events(tmp_path, 6)

    payload = {"skill_name": "aimi:plan"}
    output = _run_gate_hook(monkeypatch, tmp_path, payload, cwd=str(tmp_path))

    assert output.strip(), "Expected JSON output but got empty"
    data = json.loads(output.strip())
    assert "hookSpecificOutput" in data
    assert "additionalContext" in data["hookSpecificOutput"]
    advisory = data["hookSpecificOutput"]["additionalContext"]
    assert "[LEARNINGS CANDIDATE]" in advisory
    assert "6" in advisory
    assert "/aimi:learnings" in advisory


def test_gate_silent_when_below_threshold(monkeypatch, tmp_path):
    """4 events, threshold=5 → no output."""
    _write_friction_events(tmp_path, 4)

    payload = {"skill_name": "aimi:plan"}
    output = _run_gate_hook(monkeypatch, tmp_path, payload, cwd=str(tmp_path))

    assert output.strip() == ""


def test_gate_skips_for_learnings_skill(monkeypatch, tmp_path):
    """skill name aimi:learnings → no advisory even with 99 events."""
    _write_friction_events(tmp_path, 99)

    payload = {"tool_input": {"skill": "aimi:learnings"}}
    output = _run_gate_hook(monkeypatch, tmp_path, payload, cwd=str(tmp_path))

    assert output.strip() == ""


def test_gate_skips_for_aimi_engineering_learnings_skill(monkeypatch, tmp_path):
    """skill name aimi-engineering:learnings → no advisory even with 99 events."""
    _write_friction_events(tmp_path, 99)

    payload = {"tool_input": {"skill": "aimi-engineering:learnings"}}
    output = _run_gate_hook(monkeypatch, tmp_path, payload, cwd=str(tmp_path))

    assert output.strip() == ""


def test_gate_rate_limit_prevents_double_emit(monkeypatch, tmp_path):
    """Rate-limit file present → exit silently even with many events."""
    _write_friction_events(tmp_path, 99)

    # Pre-create the rate-limit file
    sess_dir = _session_dir(tmp_path, "default")
    sess_dir.mkdir(parents=True, exist_ok=True)
    nudge_flag = sess_dir / "learnings-nudge-emitted"
    nudge_flag.write_bytes(b"")

    payload = {"skill_name": "aimi:plan"}
    output = _run_gate_hook(monkeypatch, tmp_path, payload, cwd=str(tmp_path))

    assert output.strip() == ""


def test_gate_uses_unified_skill_name_extractor(monkeypatch, tmp_path):
    """tool_input.tool_input.skill='aimi:learnings' → recursion guard fires, no advisory."""
    _write_friction_events(tmp_path, 99)

    # Use Claude Code's actual nested shape: tool_input -> { tool_input: { skill: "..." } }
    payload = {"tool_input": {"skill": "aimi:learnings"}}
    output = _run_gate_hook(monkeypatch, tmp_path, payload, cwd=str(tmp_path))

    assert output.strip() == ""


def test_gate_custom_threshold_via_config(monkeypatch, tmp_path):
    """.aimi/config.json with learnings.frictionThreshold=3 → triggers at 3 events."""
    _write_friction_events(tmp_path, 3)

    # Write config with custom threshold
    aimi_dir = tmp_path / ".aimi"
    aimi_dir.mkdir(exist_ok=True)
    config = {"learnings": {"frictionThreshold": 3}}
    (aimi_dir / "config.json").write_text(json.dumps(config), encoding="utf-8")

    payload = {"skill_name": "aimi:plan"}
    output = _run_gate_hook(monkeypatch, tmp_path, payload, cwd=str(tmp_path))

    assert output.strip(), "Expected advisory at threshold=3 with 3 events"
    data = json.loads(output.strip())
    assert "[LEARNINGS CANDIDATE]" in data["hookSpecificOutput"]["additionalContext"]
    assert "3" in data["hookSpecificOutput"]["additionalContext"]
