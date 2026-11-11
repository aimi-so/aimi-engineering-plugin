#!/usr/bin/env python3
"""UserPromptSubmit: tell the person when an aimi command starts in a long session.

Every aimi command keeps its state on disk (`.aimi/`), so it loses nothing by
starting in a fresh session, while every turn it takes in a long one re-reads
the whole conversation so far. When the typed prompt is an aimi slash command
and the session's last measured context is above a threshold, this hook shows
the person one line suggesting `/clear` first. It never blocks and never adds
anything to Claude's context.

The context size is the last main-thread assistant turn's `usage` in the
transcript (input + cache read + cache creation tokens). The transcript is
written asynchronously and may lag by a turn, which is accurate enough for a
hint.

Claude Code only (`CLAUDECODE`). Bypass: `AIMI_CONTEXT_GUARD=off`. Threshold:
`AIMI_CONTEXT_HINT_TOKENS` (default 100000; a fresh session starts near 60000).
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

_HOOKS_DIR = Path(__file__).parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

from hook_utils import safe_hook  # noqa: E402


DEFAULT_THRESHOLD = 100_000
# How much of the transcript's end to scan for the last usage record.
TAIL_BYTES = 1_048_576

# /aimi:execute, /aimi-engineering:execute, /aimi-engineering:aimi:execute
_COMMAND = re.compile(r"^\s*/(?:aimi-engineering:(?:aimi:)?|aimi:)(?P<name>[a-z][a-z0-9:-]*)")
# Commands that are cheap or that only read state: no hint for them.
_QUIET = {"status", "setup-models"}


def command_name(prompt: str) -> str | None:
    match = _COMMAND.match(prompt or "")
    if not match:
        return None
    name = match.group("name")
    return None if name in _QUIET else name


def threshold() -> int:
    raw = os.environ.get("AIMI_CONTEXT_HINT_TOKENS", "")
    try:
        value = int(raw)
    except ValueError:
        return DEFAULT_THRESHOLD
    return value if value > 0 else DEFAULT_THRESHOLD


def last_context_tokens(transcript: Path) -> int | None:
    """Context size of the last main-thread assistant turn, or None."""
    with transcript.open("rb") as handle:
        handle.seek(0, os.SEEK_END)
        size = handle.tell()
        handle.seek(max(0, size - TAIL_BYTES))
        tail = handle.read().decode("utf-8", errors="replace")
    for line in reversed(tail.splitlines()):
        if '"usage"' not in line:
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if record.get("type") != "assistant" or record.get("isSidechain"):
            continue
        usage = (record.get("message") or {}).get("usage") or {}
        parts = [usage.get(k) for k in
                 ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")]
        if not any(isinstance(p, int) for p in parts):
            continue
        return sum(p for p in parts if isinstance(p, int))
    return None


@safe_hook
def main(payload: dict) -> None:
    if not os.environ.get("CLAUDECODE"):
        sys.exit(0)
    if os.environ.get("AIMI_CONTEXT_GUARD", "").lower() == "off":
        sys.exit(0)
    name = command_name(payload.get("prompt", ""))
    if name is None:
        sys.exit(0)
    transcript = payload.get("transcript_path") or ""
    if not transcript or not Path(transcript).is_file():
        sys.exit(0)
    tokens = last_context_tokens(Path(transcript))
    if tokens is None or tokens < threshold():
        sys.exit(0)
    message = (
        f"aimi: this session already holds about {tokens // 1000}k tokens of context. "
        f"/aimi:{name} keeps its state in .aimi/ and loses nothing in a fresh session, "
        "where each of its turns costs less: consider /clear and then running the command again. "
        "(AIMI_CONTEXT_GUARD=off silences this.)"
    )
    print(json.dumps({"systemMessage": message}))
    sys.exit(0)


if __name__ == "__main__":
    main()
