from __future__ import annotations

import importlib.util
import io
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

_HOOKS_DIR = Path(__file__).parent.parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

import telemetry_writer  # noqa: E402
import frame_helpers  # noqa: E402


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _load_hook(filename: str):
    """Load a hook module from a hyphenated filename using importlib.util."""
    mod_name = filename.replace("-", "_").replace(".py", "")
    spec = importlib.util.spec_from_file_location(mod_name, _HOOKS_DIR / filename)
    mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def _run_hook(mod, payload: dict, monkeypatch) -> None:
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))
    with pytest.raises(SystemExit) as exc_info:
        mod.main()
    assert exc_info.value.code == 0


def _telemetry_file(tmp_path: Path, category: str) -> Path:
    return tmp_path / ".aimi" / "telemetry" / f"{category}.jsonl"


# ---------------------------------------------------------------------------
# telemetry_writer unit tests
# ---------------------------------------------------------------------------

def test_writer_append_creates_dir_and_writes_line(monkeypatch, tmp_path):
    """append() creates parent dirs and writes a valid JSON line."""
    monkeypatch.setenv("HOME", str(tmp_path))
    # Patch the module-level _telemetry_dir to use tmp_path
    monkeypatch.setattr(telemetry_writer, "_telemetry_dir",
                        lambda: tmp_path / ".aimi" / "telemetry")

    telemetry_writer.append("test_cat", {"key": "value", "num": 42})

    target = tmp_path / ".aimi" / "telemetry" / "test_cat.jsonl"
    assert target.exists()
    lines = [l for l in target.read_text(encoding="utf-8").splitlines() if l.strip()]
    assert len(lines) == 1
    parsed = json.loads(lines[0])
    assert parsed["key"] == "value"
    assert parsed["num"] == 42


def test_writer_payload_round_trip(monkeypatch, tmp_path):
    """Write 3 events, read lines back — each is valid JSON matching what was written."""
    monkeypatch.setattr(telemetry_writer, "_telemetry_dir",
                        lambda: tmp_path / ".aimi" / "telemetry")

    events = [
        {"ts": "2025-01-01T00:00:00+00:00", "val": 1},
        {"ts": "2025-01-02T00:00:00+00:00", "val": 2},
        {"ts": "2025-01-03T00:00:00+00:00", "val": 3},
    ]
    for ev in events:
        telemetry_writer.append("round_trip", ev)

    target = tmp_path / ".aimi" / "telemetry" / "round_trip.jsonl"
    lines = [l for l in target.read_text(encoding="utf-8").splitlines() if l.strip()]
    assert len(lines) == 3
    for i, line in enumerate(lines):
        parsed = json.loads(line)
        assert parsed["val"] == events[i]["val"]
        assert parsed["ts"] == events[i]["ts"]


def test_writer_rotates_at_50mb(monkeypatch, tmp_path):
    """When file size exceeds threshold, file is rotated to .jsonl.1 and fresh .jsonl is created."""
    monkeypatch.setattr(telemetry_writer, "_telemetry_dir",
                        lambda: tmp_path / ".aimi" / "telemetry")
    monkeypatch.setattr(telemetry_writer, "_ROTATE_THRESHOLD_BYTES", 100)
    # Set _SAMPLE_EVERY=1 so rotation is checked on every write (preserves pre-US-004 semantics)
    monkeypatch.setattr(telemetry_writer, "_SAMPLE_EVERY", 1)

    tdir = tmp_path / ".aimi" / "telemetry"
    tdir.mkdir(parents=True, exist_ok=True)
    target = tdir / "rot_cat.jsonl"

    # Write enough bytes to exceed threshold
    target.write_text("x" * 101, encoding="utf-8")

    # Now append — should rotate (write #1, and 1 % 1 == 0 triggers the check)
    telemetry_writer.append("rot_cat", {"after": "rotation"})

    rotated = tdir / "rot_cat.jsonl.1"
    assert rotated.exists(), "Rotated file .jsonl.1 should exist"
    assert rotated.read_text(encoding="utf-8") == "x" * 101

    # Fresh .jsonl should contain only the new entry
    lines = [l for l in target.read_text(encoding="utf-8").splitlines() if l.strip()]
    assert len(lines) == 1
    parsed = json.loads(lines[0])
    assert parsed["after"] == "rotation"


def test_writer_samples_rotation_check(monkeypatch, tmp_path):
    """Rotation check only fires at multiples of _SAMPLE_EVERY.

    With _SAMPLE_EVERY=5: writes 1-4 are small and don't check size even if
    file is big; write 5 triggers the sample point and rotates.
    """
    monkeypatch.setattr(telemetry_writer, "_telemetry_dir",
                        lambda: tmp_path / ".aimi" / "telemetry")
    monkeypatch.setattr(telemetry_writer, "_ROTATE_THRESHOLD_BYTES", 10)
    monkeypatch.setattr(telemetry_writer, "_SAMPLE_EVERY", 5)

    tdir = tmp_path / ".aimi" / "telemetry"
    tdir.mkdir(parents=True, exist_ok=True)
    target = tdir / "sample_cat.jsonl"

    # Pre-fill with content exceeding threshold
    target.write_text("x" * 11, encoding="utf-8")

    # Writes 1-4: counter is 1,2,3,4 — none are multiples of 5 — no rotation
    for i in range(4):
        telemetry_writer.append("sample_cat", {"write": i})

    rotated = tdir / "sample_cat.jsonl.1"
    assert not rotated.exists(), (
        "Rotation should NOT have happened after writes 1-4 (not at sample boundary)"
    )

    # Write 5: counter becomes 5 → 5 % 5 == 0 → rotation fires
    telemetry_writer.append("sample_cat", {"write": 4})

    assert rotated.exists(), "Rotation SHOULD happen at write #5 (sample boundary)"

    # After rotation the fresh .jsonl should contain only the writes that came
    # after the rotation (just write #5, the one that triggered it).
    lines = [l for l in target.read_text(encoding="utf-8").splitlines() if l.strip()]
    assert len(lines) == 1
    parsed = json.loads(lines[0])
    assert parsed["write"] == 4


def test_writer_silent_on_io_error(monkeypatch, tmp_path):
    """append() returns None and does not raise when IO fails."""
    monkeypatch.setattr(telemetry_writer, "_telemetry_dir",
                        lambda: tmp_path / ".aimi" / "telemetry")

    original_open = open

    def bad_open(*args, **kwargs):
        raise OSError("simulated failure")

    monkeypatch.setattr("builtins.open", bad_open)

    # Should not raise
    result = telemetry_writer.append("fail_cat", {"data": 1})
    assert result is None


# ---------------------------------------------------------------------------
# is_telemetry_enabled tests (via hook short-circuit)
# ---------------------------------------------------------------------------

def _write_config(base: Path, enabled: bool) -> None:
    config_dir = base / ".aimi"
    config_dir.mkdir(parents=True, exist_ok=True)
    (config_dir / "config.json").write_text(
        json.dumps({"telemetry": {"enabled": enabled}}), encoding="utf-8"
    )


def test_telemetry_disabled_short_circuits_skill_log(monkeypatch, tmp_path):
    """When telemetry.enabled=false in config, skill log hook writes nothing."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(tmp_path))
    monkeypatch.setattr(telemetry_writer, "_telemetry_dir",
                        lambda: tmp_path / ".aimi" / "telemetry")

    _write_config(tmp_path, enabled=False)

    mod = _load_hook("log-skill-invocation.py")
    payload = {"tool_input": {"skill": "my-skill"}}
    _run_hook(mod, payload, monkeypatch)

    target = tmp_path / ".aimi" / "telemetry" / "skills.jsonl"
    assert not target.exists(), "No file should be written when telemetry is disabled"


def test_telemetry_disabled_short_circuits_read_log(monkeypatch, tmp_path):
    """When telemetry.enabled=false in config, read log hook writes nothing."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(tmp_path))
    monkeypatch.setattr(telemetry_writer, "_telemetry_dir",
                        lambda: tmp_path / ".aimi" / "telemetry")

    _write_config(tmp_path, enabled=False)

    mod = _load_hook("log-read-trace.py")
    payload = {"tool_input": {"file_path": "/some/file.py"}}
    _run_hook(mod, payload, monkeypatch)

    target = tmp_path / ".aimi" / "telemetry" / "reads.jsonl"
    assert not target.exists(), "No file should be written when telemetry is disabled"


# ---------------------------------------------------------------------------
# Payload shape tests
# ---------------------------------------------------------------------------

def test_skill_log_payload_shape(monkeypatch, tmp_path):
    """Skill log hook writes a JSONL line with all expected keys and correct types."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(tmp_path))
    monkeypatch.setattr(telemetry_writer, "_telemetry_dir",
                        lambda: tmp_path / ".aimi" / "telemetry")

    mod = _load_hook("log-skill-invocation.py")
    payload = {
        "tool_input": {"skill": "aimi-engineering:plan"},
        "tool_response": {"outcome": "success"},
        "session_id": "test-sess",
    }
    _run_hook(mod, payload, monkeypatch)

    target = tmp_path / ".aimi" / "telemetry" / "skills.jsonl"
    assert target.exists()
    lines = [l for l in target.read_text(encoding="utf-8").splitlines() if l.strip()]
    assert len(lines) == 1
    parsed = json.loads(lines[0])

    assert "ts" in parsed
    assert "session_id" in parsed
    assert parsed["session_id"] == "test-sess"
    assert "skill" in parsed
    assert parsed["skill"] == "aimi-engineering:plan"
    assert "outcome" in parsed
    assert parsed["outcome"] == "success"
    assert "duration_ms" in parsed
    # No frame pushed, so duration_ms should be None
    assert parsed["duration_ms"] is None

    # ts should be a valid ISO-8601 timestamp
    dt = datetime.fromisoformat(parsed["ts"])
    assert dt.tzinfo is not None


def test_read_log_payload_shape(monkeypatch, tmp_path):
    """Read log hook writes a JSONL line with all expected keys and correct types."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(tmp_path))
    monkeypatch.setattr(telemetry_writer, "_telemetry_dir",
                        lambda: tmp_path / ".aimi" / "telemetry")

    # Create a real file so getsize works
    test_file = tmp_path / "example.py"
    test_file.write_text("print('hello')", encoding="utf-8")

    mod = _load_hook("log-read-trace.py")
    payload = {
        "tool_input": {"file_path": str(test_file)},
        "session_id": "read-sess",
    }
    _run_hook(mod, payload, monkeypatch)

    target = tmp_path / ".aimi" / "telemetry" / "reads.jsonl"
    assert target.exists()
    lines = [l for l in target.read_text(encoding="utf-8").splitlines() if l.strip()]
    assert len(lines) == 1
    parsed = json.loads(lines[0])

    assert "ts" in parsed
    assert "session_id" in parsed
    assert parsed["session_id"] == "read-sess"
    assert "frame" in parsed
    assert parsed["frame"] is None  # no active frame
    assert "path" in parsed
    assert parsed["path"] == str(test_file)
    assert "size_bytes" in parsed
    assert isinstance(parsed["size_bytes"], int)
    assert parsed["size_bytes"] > 0


def test_read_log_handles_missing_size(monkeypatch, tmp_path):
    """When file_path doesn't exist, size_bytes defaults to 0."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(tmp_path))
    monkeypatch.setattr(telemetry_writer, "_telemetry_dir",
                        lambda: tmp_path / ".aimi" / "telemetry")

    mod = _load_hook("log-read-trace.py")
    payload = {
        "tool_input": {"file_path": "/nonexistent/path/file.py"},
        "session_id": "default",
    }
    _run_hook(mod, payload, monkeypatch)

    target = tmp_path / ".aimi" / "telemetry" / "reads.jsonl"
    assert target.exists()
    lines = [l for l in target.read_text(encoding="utf-8").splitlines() if l.strip()]
    assert len(lines) == 1
    parsed = json.loads(lines[0])
    assert parsed["size_bytes"] == 0


def test_skill_log_frame_attribution(monkeypatch, tmp_path):
    """When a frame is active, duration_ms is a non-null int."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(tmp_path))
    monkeypatch.setattr(telemetry_writer, "_telemetry_dir",
                        lambda: tmp_path / ".aimi" / "telemetry")

    # Manually push a frame into the session skill-stack
    sess_dir = tmp_path / ".aimi" / "session" / "default"
    sess_dir.mkdir(parents=True, exist_ok=True)
    stack_file = sess_dir / "skill-stack.jsonl"
    started = datetime.now(timezone.utc).isoformat()
    entry = json.dumps({"name": "my-skill", "started_at": started})
    stack_file.write_text(entry + "\n", encoding="utf-8")

    # Patch frame_helpers._session_dir so it resolves to our tmp_path
    monkeypatch.setattr(frame_helpers, "_session_dir",
                        lambda sid: tmp_path / ".aimi" / "session" / sid)

    mod = _load_hook("log-skill-invocation.py")
    payload = {
        "tool_input": {"skill": "my-skill"},
        "tool_response": {"outcome": "success"},
        "session_id": "default",
    }
    _run_hook(mod, payload, monkeypatch)

    target = tmp_path / ".aimi" / "telemetry" / "skills.jsonl"
    assert target.exists()
    lines = [l for l in target.read_text(encoding="utf-8").splitlines() if l.strip()]
    assert len(lines) == 1
    parsed = json.loads(lines[0])

    assert parsed["duration_ms"] is not None
    assert isinstance(parsed["duration_ms"], int)
    assert parsed["duration_ms"] >= 0
