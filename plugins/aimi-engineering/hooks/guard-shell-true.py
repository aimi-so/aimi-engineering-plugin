#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from hook_utils import safe_hook, safe_json_input  # noqa: E402


def _effective_cwd(command: str, tool_input: dict) -> str:
    """Extract effective cwd from a git command string."""
    m = re.search(r"\bgit\s+-C\s+(\S+)", command)
    if m:
        return os.path.abspath(os.path.expanduser(m.group(1)))

    m = re.match(r"\s*cd\s+(\S+)\s*&&", command)
    if m:
        return os.path.abspath(os.path.expanduser(m.group(1)))

    cwd = tool_input.get("cwd")
    if cwd:
        return os.path.abspath(os.path.expanduser(cwd))
    return os.getcwd()


def _scan_for_shell_true(blob: str) -> list[int]:
    """Return 1-based line numbers where shell=True appears outside comments/docstrings."""
    hits: list[int] = []
    in_triple: str | None = None  # current open triple-quote style: '"""' or "'''"

    for lineno, line in enumerate(blob.splitlines(), start=1):
        stripped = line.strip()

        # Toggle triple-quote tracking (very simple heuristic)
        for marker in ('"""', "'''"):
            count = line.count(marker)
            if count > 0:
                if in_triple is None:
                    if count % 2 == 1:
                        in_triple = marker
                elif in_triple == marker:
                    if count % 2 == 1:
                        in_triple = None
                # If count is even, open/close balance on same line — state unchanged

        if in_triple is not None:
            # Inside a docstring — skip
            continue

        # Skip comment lines
        if stripped.startswith("#"):
            continue

        if re.search(r"\bshell\s*=\s*True\b", line):
            hits.append(lineno)

    return hits


@safe_hook
def main(tool_input: dict) -> None:
    command = tool_input.get("command", "")

    # Fast-path: must contain a git commit invocation.
    # Covers: "git commit ...", "git -C <p> commit ...", "cd <p> && git commit ..."
    if not (re.search(r"\bgit\s+commit\b", command) or re.search(r"\bgit\s+-C\s+\S+\s+commit\b", command)):
        sys.exit(0)

    # Bypass env
    if os.environ.get("AIMI_SHELL_TRUE_GUARD") == "off":
        sys.exit(0)

    cwd = _effective_cwd(command, tool_input)

    try:
        result = subprocess.run(
            ["git", "-C", cwd, "diff", "--cached", "--name-only", "--", "*.py"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        staged_files = [f for f in result.stdout.splitlines() if f.strip()]
    except Exception:  # noqa: BLE001
        sys.exit(0)

    if not staged_files:
        sys.exit(0)

    offenders: list[str] = []
    for path in staged_files:
        try:
            blob_result = subprocess.run(
                ["git", "-C", cwd, "show", f":{path}"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            blob = blob_result.stdout
        except Exception:  # noqa: BLE001
            continue

        for lineno in _scan_for_shell_true(blob):
            offenders.append(f"  {path}:{lineno}")

    if offenders:
        lines = "\n".join(offenders)
        msg = (
            "`shell=True` detected in staged files — refusing to commit:\n"
            f"{lines}\n"
            "Use shell=False with an argv list, or move the constant into a small helper that quotes inputs."
        )
        print(
            json.dumps(
                {
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "deny",
                        "userMessage": msg,
                    }
                }
            )
        )
    sys.exit(0)


if __name__ == "__main__":
    main()
