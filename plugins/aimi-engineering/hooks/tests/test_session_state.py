from __future__ import annotations

import io
import json
import os
import sys
import threading
from pathlib import Path

import pytest

# Insert the hooks directory onto sys.path so we can import modules directly.
_HOOKS_DIR = Path(__file__).parent.parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

import frame_helpers  # noqa: E402
import hook_utils  # noqa: E402


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _run_hook_module(module_name: str, stdin_payload: dict, monkeypatch, tmp_path) -> None:
    """Import and run a hook module's main() with a mocked stdin."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(stdin_payload)))

    # Force reimport so HOME changes take effect in module-level Path.home() calls
    import importlib
    mod = importlib.import_module(module_name)
    importlib.reload(mod)

    with pytest.raises(SystemExit) as exc_info:
        mod.main()
    assert exc_info.value.code == 0


def _session_dir(tmp_path: Path, sid: str = "default") -> Path:
    return tmp_path / ".aimi" / "session" / sid


# ---------------------------------------------------------------------------
# stash-prompt tests
# ---------------------------------------------------------------------------


def test_stash_prompt_atomic_write(monkeypatch, tmp_path):
    """stash-prompt.py writes the prompt to last-prompt.txt atomically."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)

    payload = {"prompt": "Hello, world!"}
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))

    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "stash_prompt_mod", _HOOKS_DIR / "stash-prompt.py"
    )
    mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    spec.loader.exec_module(mod)  # type: ignore[union-attr]

    with pytest.raises(SystemExit) as exc_info:
        mod.main()

    assert exc_info.value.code == 0
    result_file = _session_dir(tmp_path) / "last-prompt.txt"
    assert result_file.exists()
    assert result_file.read_text(encoding="utf-8") == "Hello, world!"


def test_stash_prompt_no_prompt_field(monkeypatch, tmp_path):
    """stash-prompt.py exits 0 without writing any file when 'prompt' is absent."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)

    payload = {"other_field": "value"}
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))

    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "stash_prompt_mod2", _HOOKS_DIR / "stash-prompt.py"
    )
    mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    spec.loader.exec_module(mod)  # type: ignore[union-attr]

    with pytest.raises(SystemExit) as exc_info:
        mod.main()

    assert exc_info.value.code == 0
    result_file = _session_dir(tmp_path) / "last-prompt.txt"
    assert not result_file.exists()


# ---------------------------------------------------------------------------
# push / pop LIFO tests
# ---------------------------------------------------------------------------

def _load_push_mod(monkeypatch, tmp_path):
    import importlib.util
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    spec = importlib.util.spec_from_file_location(
        "push_skill_frame_mod", _HOOKS_DIR / "push-skill-frame.py"
    )
    mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def _load_pop_mod(monkeypatch, tmp_path):
    import importlib.util
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    spec = importlib.util.spec_from_file_location(
        "pop_skill_frame_mod", _HOOKS_DIR / "pop-skill-frame.py"
    )
    mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def _push(mod, skill_name: str, monkeypatch):
    """Run push-skill-frame main() with given skill name."""
    payload = {"tool_input": {"skill": skill_name}}
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))
    with pytest.raises(SystemExit) as exc_info:
        mod.main()
    assert exc_info.value.code == 0


def _pop(mod, skill_name: str, monkeypatch):
    """Run pop-skill-frame main() with given skill name."""
    payload = {"tool_input": {"skill": skill_name}}
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))
    with pytest.raises(SystemExit) as exc_info:
        mod.main()
    assert exc_info.value.code == 0


def test_push_pop_lifo_order(monkeypatch, tmp_path):
    """Push A, push B, pop B → stack contains just A; current_frame returns A."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)

    push_mod = _load_push_mod(monkeypatch, tmp_path)
    pop_mod = _load_pop_mod(monkeypatch, tmp_path)

    _push(push_mod, "A", monkeypatch)
    _push(push_mod, "B", monkeypatch)
    _pop(pop_mod, "B", monkeypatch)

    # Patch frame_helpers to use our tmp_path HOME
    monkeypatch.setattr(frame_helpers, "_session_dir",
                        lambda sid: tmp_path / ".aimi" / "session" / sid)

    frame = frame_helpers.current_frame("default")
    assert frame is not None
    assert frame["name"] == "A"

    stack = frame_helpers.frame_stack("default")
    assert len(stack) == 1
    assert stack[0]["name"] == "A"


def test_pop_missing_name_no_op(monkeypatch, tmp_path):
    """pop-skill-frame.py exits 0 without error when skill name is missing."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)

    payload = {}  # no skill name anywhere
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))

    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "pop_skill_no_name", _HOOKS_DIR / "pop-skill-frame.py"
    )
    mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    spec.loader.exec_module(mod)  # type: ignore[union-attr]

    with pytest.raises(SystemExit) as exc_info:
        mod.main()
    assert exc_info.value.code == 0


def test_concurrent_appends_preserve_lines(monkeypatch, tmp_path):
    """50 concurrent append operations all preserve valid JSON lines in the file."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)

    sess_dir = tmp_path / ".aimi" / "session" / "default"
    sess_dir.mkdir(parents=True, exist_ok=True)
    stack_file = sess_dir / "skill-stack.jsonl"

    errors: list[Exception] = []

    def append_one(idx: int) -> None:
        try:
            entry = json.dumps({"name": f"skill-{idx}", "started_at": "2024-01-01T00:00:00+00:00"})
            with stack_file.open("a", encoding="utf-8") as fh:
                fh.write(entry + "\n")
        except Exception as exc:
            errors.append(exc)

    threads = [threading.Thread(target=append_one, args=(i,)) for i in range(50)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert not errors, f"Thread errors: {errors}"

    lines = [l.strip() for l in stack_file.read_text(encoding="utf-8").splitlines() if l.strip()]
    assert len(lines) == 50
    for line in lines:
        parsed = json.loads(line)
        assert "name" in parsed
        assert "started_at" in parsed


# ---------------------------------------------------------------------------
# frame_helpers tests
# ---------------------------------------------------------------------------


def test_frame_helpers_current_frame_when_empty(monkeypatch, tmp_path):
    """current_frame returns None when no stack file exists."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    monkeypatch.setattr(frame_helpers, "_session_dir",
                        lambda sid: tmp_path / ".aimi" / "session" / sid)

    result = frame_helpers.current_frame("default")
    assert result is None


def test_frame_helpers_session_id_fallback(monkeypatch, tmp_path):
    """When no env var and no arg, frame_stack uses 'default' as session id."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)
    monkeypatch.setattr(frame_helpers, "_session_dir",
                        lambda sid: tmp_path / ".aimi" / "session" / sid)

    # Create a file under "default" session dir
    sess_dir = tmp_path / ".aimi" / "session" / "default"
    sess_dir.mkdir(parents=True, exist_ok=True)
    stack_file = sess_dir / "skill-stack.jsonl"
    entry = json.dumps({"name": "my-skill", "started_at": "2024-01-01T00:00:00+00:00"})
    stack_file.write_text(entry + "\n", encoding="utf-8")

    # Call with no session_id arg and no CLAUDE_SESSION_ID env
    result = frame_helpers.frame_stack()
    assert len(result) == 1
    assert result[0]["name"] == "my-skill"


def test_session_id_from_tool_input(monkeypatch, tmp_path):
    """session_id from tool_input wins over CLAUDE_SESSION_ID env var."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("CLAUDE_SESSION_ID", "env-session")

    # Write to the "tool-session" dir
    tool_sess_dir = tmp_path / ".aimi" / "session" / "tool-session"
    tool_sess_dir.mkdir(parents=True, exist_ok=True)
    stack_file = tool_sess_dir / "skill-stack.jsonl"
    entry = json.dumps({"name": "tool-skill", "started_at": "2024-01-01T00:00:00+00:00"})
    stack_file.write_text(entry + "\n", encoding="utf-8")

    # Patch push module's _session_dir to use tmp_path HOME
    monkeypatch.setattr(frame_helpers, "_session_dir",
                        lambda sid: tmp_path / ".aimi" / "session" / sid)

    # Verify that passing "tool-session" explicitly wins
    result = frame_helpers.current_frame("tool-session")
    assert result is not None
    assert result["name"] == "tool-skill"

    # And that "env-session" (from env) returns None (no file there)
    result_env = frame_helpers.current_frame(None)
    # With CLAUDE_SESSION_ID="env-session" and no file there, should be None
    monkeypatch.setattr(frame_helpers, "_session_dir",
                        lambda sid: tmp_path / ".aimi" / "session" / sid)
    result_env = frame_helpers.current_frame()
    assert result_env is None
