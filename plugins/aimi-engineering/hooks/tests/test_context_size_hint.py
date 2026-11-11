"""context-size-hint.py: a UserPromptSubmit hint, never a block.

Run as a subprocess, the way Claude Code runs it, against throwaway
transcripts.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

HOOK = Path(__file__).resolve().parent.parent / "context-size-hint.py"
HOOKS_JSON = HOOK.parent / "hooks.json"


def _assistant(tokens: int, sidechain: bool = False) -> dict:
    return {
        "type": "assistant",
        "isSidechain": sidechain,
        "message": {"usage": {"input_tokens": 2, "cache_read_input_tokens": tokens - 102,
                              "cache_creation_input_tokens": 100, "output_tokens": 50}},
    }


def _transcript(tmp_path: Path, records: list[dict]) -> Path:
    path = tmp_path / "session.jsonl"
    path.write_text("\n".join(json.dumps(r) for r in records) + "\n", encoding="utf-8")
    return path


def _run(prompt: str, transcript: Path | None, **env: str) -> subprocess.CompletedProcess:
    base = {k: v for k, v in os.environ.items()
            if k not in ("AIMI_CONTEXT_GUARD", "AIMI_CONTEXT_HINT_TOKENS")}
    base["CLAUDECODE"] = "1"
    base.update(env)
    for key in [k for k, v in base.items() if v is None]:
        del base[key]
    payload = {"hook_event_name": "UserPromptSubmit", "prompt": prompt,
               "transcript_path": str(transcript) if transcript else ""}
    return subprocess.run([sys.executable, str(HOOK)], input=json.dumps(payload),
                          capture_output=True, text=True, env=base, timeout=30)


def _message(proc: subprocess.CompletedProcess) -> str | None:
    assert proc.returncode == 0
    if not proc.stdout.strip():
        return None
    return json.loads(proc.stdout)["systemMessage"]


@pytest.mark.parametrize("prompt", ["/aimi:execute", "/aimi-engineering:execute --phase 2",
                                    "/aimi-engineering:aimi:plan add login", "  /aimi:design:polish"])
def test_a_long_session_gets_the_hint_for_an_aimi_command(tmp_path, prompt):
    msg = _message(_run(prompt, _transcript(tmp_path, [_assistant(180_000)])))
    assert msg is not None
    assert "180k tokens" in msg and "/clear" in msg and "AIMI_CONTEXT_GUARD=off" in msg


def test_the_hint_names_the_command_typed(tmp_path):
    msg = _message(_run("/aimi:plan big feature", _transcript(tmp_path, [_assistant(150_000)])))
    assert "/aimi:plan keeps its state" in msg


def test_a_short_session_gets_nothing(tmp_path):
    assert _message(_run("/aimi:execute", _transcript(tmp_path, [_assistant(60_000)]))) is None


@pytest.mark.parametrize("prompt", ["fix the bug in /aimi:execute", "hello", "/review", "/aimi:status",
                                    "/aimi-engineering:setup-models"])
def test_other_prompts_and_quiet_commands_get_nothing(tmp_path, prompt):
    assert _message(_run(prompt, _transcript(tmp_path, [_assistant(300_000)]))) is None


def test_only_the_last_main_thread_turn_counts(tmp_path):
    records = [_assistant(300_000), _assistant(50_000), _assistant(400_000, sidechain=True),
               {"type": "user", "message": {"content": "x"}}]
    assert _message(_run("/aimi:execute", _transcript(tmp_path, records))) is None


def test_the_threshold_can_be_moved(tmp_path):
    transcript = _transcript(tmp_path, [_assistant(60_000)])
    assert _message(_run("/aimi:execute", transcript, AIMI_CONTEXT_HINT_TOKENS="50000")) is not None
    assert _message(_run("/aimi:execute", transcript, AIMI_CONTEXT_HINT_TOKENS="junk")) is None


def test_bypass_and_host_gate(tmp_path):
    transcript = _transcript(tmp_path, [_assistant(300_000)])
    assert _message(_run("/aimi:execute", transcript, AIMI_CONTEXT_GUARD="off")) is None
    assert _message(_run("/aimi:execute", transcript, CLAUDECODE=None)) is None


@pytest.mark.parametrize("content", ["", "not json\n{broken\n", json.dumps({"type": "assistant"}) + "\n"])
def test_unreadable_or_missing_transcripts_stay_silent(tmp_path, content):
    path = tmp_path / "t.jsonl"
    path.write_text(content, encoding="utf-8")
    assert _message(_run("/aimi:execute", path)) is None
    assert _message(_run("/aimi:execute", tmp_path / "absent.jsonl")) is None
    assert _message(_run("/aimi:execute", None)) is None


def test_garbage_stdin_exits_zero_silently():
    proc = subprocess.run([sys.executable, str(HOOK)], input="{not json", capture_output=True,
                          text=True, env={**os.environ, "CLAUDECODE": "1"}, timeout=30)
    assert proc.returncode == 0 and proc.stdout == ""


def test_the_hook_is_wired_on_user_prompt_submit():
    hooks = json.loads(HOOKS_JSON.read_text(encoding="utf-8"))["hooks"]
    commands = [h["command"] for entry in hooks.get("UserPromptSubmit", []) for h in entry["hooks"]]
    assert "${CLAUDE_PLUGIN_ROOT}/hooks/context-size-hint.py" in commands
    assert os.access(HOOK, os.X_OK)
