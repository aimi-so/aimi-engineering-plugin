#!/usr/bin/env python3
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from hook_utils import safe_hook, safe_json_input, effective_cwd, load_aimi_config, deny  # noqa: E402


def _load_protected_branches(cwd: str) -> set[str]:
    protected = {"main", "master", "develop"}
    config = load_aimi_config(start=Path(cwd))
    extra = config.get("guards", {}).get("protectedBranches", [])
    protected.update(extra)
    return protected


@safe_hook
def main(tool_input: dict) -> None:
    command = tool_input.get("command", "")

    # Fast-path: must contain a git commit invocation.
    # Covers: "git commit ...", "git -C <p> commit ...", "cd <p> && git commit ..."
    if not (re.search(r"\bgit\s+commit\b", command) or re.search(r"\bgit\s+-C\s+\S+\s+commit\b", command)):
        sys.exit(0)

    # Bypass env
    if os.environ.get("AIMI_DEFAULT_BRANCH_GUARD") == "off":
        sys.exit(0)

    cwd = effective_cwd(command, tool_input)
    protected = _load_protected_branches(cwd)

    try:
        result = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        branch = result.stdout.strip()
    except Exception:  # noqa: BLE001
        sys.exit(0)

    if branch in protected:
        msg = (
            f"Commits on the protected branch `{branch}` are blocked.\n"
            "Use a feature worktree:\n"
            "  git worktree add /tmp/<feature> -b feat/<feature>\n"
            "Then commit from that worktree. The default branch stays clean for merges."
        )
        print(deny(msg))
    sys.exit(0)


if __name__ == "__main__":
    main()
