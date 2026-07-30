from __future__ import annotations

import functools
import json
import os
import re
import sys
from pathlib import Path
from typing import Callable


SCHEMA_VERSIONS: frozenset[str] = frozenset({"3.3"})  # acceptable tasks.json schema versions

# ---------------------------------------------------------------------------
# Secret-redaction helpers
# ---------------------------------------------------------------------------

_REDACT_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\bsk-[A-Za-z0-9\-_]{20,}\b"), "sk-token"),
    (re.compile(r"\bghp_[A-Za-z0-9]{36,}\b"), "github-pat"),
    (re.compile(r"\bgho_[A-Za-z0-9]{36,}\b"), "github-oauth"),
    (re.compile(r"\bxox[baprs]-[A-Za-z0-9\-]{10,}\b"), "slack-token"),
    (re.compile(r"\beyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\b"), "jwt"),
    (re.compile(r"\bAKIA[A-Z0-9]{16}\b"), "aws-access-key"),
    (re.compile(r"\baws_secret_access_key\s*[:=]\s*\S+", re.IGNORECASE), "aws-secret-key"),
    (re.compile(r"\b(password|passwd|api[_\-]?key|secret)\s*[:=]\s*\S+", re.IGNORECASE), "credential"),
]


def redact_secrets(text: str) -> str:
    """Replace common secret token patterns with [REDACTED:<token_type>] placeholders.

    Patterns covered: OpenAI/Anthropic sk- tokens, GitHub PATs/OAuth tokens,
    Slack tokens, JWTs, AWS access keys, AWS secret keys, and generic
    password/api_key/secret assignments.
    """
    for pattern, token_type in _REDACT_PATTERNS:
        text = pattern.sub(f"[REDACTED:{token_type}]", text)
    return text


def safe_hook(fn: Callable[[dict], None]) -> Callable[[], None]:
    """Decorator that wraps a handler(tool_input: dict) -> None.

    Reads safe_json_input(), calls fn, and catches every exception,
    exiting 0 silently.  Keeping Claude Code sessions stable is the
    explicit goal — never let a hook crash a session.
    """

    @functools.wraps(fn)
    def wrapper() -> None:
        try:
            tool_input = safe_json_input()
            fn(tool_input)
        except Exception:  # noqa: BLE001
            sys.exit(0)

    return wrapper


def safe_json_input() -> dict:
    """Read sys.stdin and parse as JSON.

    Returns the parsed dict on success, or {} on any parse error
    (including empty stdin).
    """
    try:
        raw = sys.stdin.read()
        return json.loads(raw)
    except Exception:  # noqa: BLE001
        return {}


def load_aimi_config(start: Path | None = None) -> dict:
    """Walk up from start (default: $CLAUDE_PLUGIN_ROOT or cwd) looking for .aimi/config.json.

    Returns parsed dict if found and valid JSON.
    Returns {} on any error (file missing, parse error, etc.).
    """
    if start is None:
        root = os.environ.get("CLAUDE_PLUGIN_ROOT")
        start = Path(root) if root else Path(os.getcwd())

    current = start
    while True:
        candidate = current / ".aimi" / "config.json"
        if candidate.exists():
            try:
                return json.loads(candidate.read_text(encoding="utf-8"))
            except Exception:  # noqa: BLE001
                return {}
        parent = current.parent
        if parent == current:
            return {}
        current = parent


def is_quiet_mode() -> bool:
    """Walk up from $CLAUDE_PLUGIN_ROOT (or cwd) looking for .aimi/config.json.

    Returns config.get("quietMode", False) when found and parseable,
    otherwise False.
    """
    return bool(load_aimi_config().get("quietMode", False))


# Path token shared by both extractors below: a double-quoted path, a
# single-quoted path, or a bare non-whitespace run. This mirrors the token the
# detection regexes in pre-bash-dispatcher.py use, so a command shape that is
# detected as a commit is also one whose target directory can be resolved. A
# bare `\S+` here would capture the opening quote (and stop at the first space
# inside it), yielding a path no git invocation can use — which resolves to an
# empty branch name and silently disables the protected-branch guard.
_PATH_TOKEN = r"(?:\"([^\"]+)\"|'([^']+)'|(\S+))"
_GIT_C_PATH_RE = re.compile(r"\bgit\s+-C\s+" + _PATH_TOKEN)
_CD_PREFIX_RE = re.compile(r"\s*cd\s+" + _PATH_TOKEN + r"\s*&&")


def _resolve_path_token(match: re.Match) -> str:
    """Return the absolute path from a _PATH_TOKEN match, quotes stripped."""
    path = match.group(1) or match.group(2) or match.group(3)
    return os.path.abspath(os.path.expanduser(path))


def effective_cwd(command: str, tool_input: dict) -> str:
    """Return the effective working directory for a shell command.

    Priority:
    1. Parse ``git -C <path>`` from command string.
    2. Parse a leading ``cd <path> &&`` from command string.
    3. Fall back to tool_input.get("cwd") if present.
    4. Fall back to os.getcwd().

    Returns an absolute path string with ~ expanded.
    """
    m = _GIT_C_PATH_RE.search(command)
    if m:
        return _resolve_path_token(m)

    m = _CD_PREFIX_RE.match(command)
    if m:
        return _resolve_path_token(m)

    cwd = tool_input.get("cwd")
    if cwd:
        return os.path.abspath(os.path.expanduser(cwd))
    return os.getcwd()


def resolve_session_id(tool_input: dict) -> str:
    """Resolve the current session identifier.

    Priority:
    1. tool_input.get("session_id")
    2. os.environ.get("CLAUDE_SESSION_ID")
    3. "default"
    """
    sid = tool_input.get("session_id")
    if sid:
        return str(sid)
    sid = os.environ.get("CLAUDE_SESSION_ID")
    if sid:
        return str(sid)
    return "default"


def find_aimi_dir(start: Path | None = None) -> Path | None:
    """Walk up from start (default: cwd) looking for a .aimi directory.

    Returns a Path pointing to the .aimi directory if found, or None.
    Stops at the filesystem root.
    """
    if start is None:
        start = Path(os.getcwd())

    current = start.resolve()
    while True:
        candidate = current / ".aimi"
        if candidate.is_dir():
            return candidate
        parent = current.parent
        if parent == current:
            return None
        current = parent


def extract_skill_name(tool_input: dict) -> str | None:
    """Extract the skill name from a Skill tool_input dict.

    Priority:
    1. tool_input["tool_input"]["skill"]  (Claude Code's actual shape)
    2. tool_input["skill"]               (flat fallback)
    3. None if neither is present
    """
    nested = tool_input.get("tool_input")
    if isinstance(nested, dict):
        name = nested.get("skill")
        if name:
            return str(name)
    name = tool_input.get("skill")
    if name:
        return str(name)
    return None


def deny(user_message: str, event_name: str = "PreToolUse") -> str:
    """Return the canonical JSON deny output for a PreToolUse (or other) hook event.

    Usage::

        print(deny("your message"))
        sys.exit(0)
    """
    return json.dumps(
        {
            "hookSpecificOutput": {
                "hookEventName": event_name,
                "permissionDecision": "deny",
                "userMessage": user_message,
            }
        }
    )
