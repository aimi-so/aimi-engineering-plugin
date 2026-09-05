#!/usr/bin/env python3
from __future__ import annotations

import os
import sys
from pathlib import Path

_HOOKS_DIR = Path(__file__).parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

from hook_utils import safe_hook, find_aimi_dir, deny  # noqa: E402

# The jq -> Python golden corpus, matched by the last three path COMPONENTS
# rather than an absolute path: the corpus lives outside any .aimi/, and an
# absolute path would pin the guard to one tree and miss every worktree copy.
# Comparing parts (not str.endswith) keeps "myscripts/tests/..." from matching.
_GOLDEN_CORPUS_PARTS = ("scripts", "tests", "golden_from_jq.json")


def _deny_path(path: str, reason: str, exit_code: int = 0) -> None:
    msg = (
        f"Direct edits to runtime state are blocked:\n"
        f"  {path}\n"
        f"This file is owned by the aimi runtime. {reason}.\n"
        f"Set AIMI_RUNTIME_STATE_GUARD=off to bypass intentionally."
    )
    # A PreToolUse block is read two ways: the structured `permissionDecision:
    # deny` on stdout with exit 0, or a non-zero exit whose reason is read off
    # stderr.  Callers here use the first; one that asks for a non-zero status
    # gets both, so the reason survives either reading instead of arriving as a
    # bare refusal.  The default keeps every existing caller byte-identical.
    print(deny(msg))
    if exit_code != 0:
        sys.stderr.write(msg + "\n")
    sys.exit(exit_code)


def _is_within(target: Path, container: Path) -> bool:
    try:
        target.relative_to(container)
        return True
    except ValueError:
        return False


def _is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        # Process exists but we don't have permission to signal it.
        return True


@safe_hook
def main(tool_input: dict) -> None:
    # Bypass env check.
    if os.environ.get("AIMI_RUNTIME_STATE_GUARD", "").lower() == "off":
        sys.exit(0)

    # Extract file path from the Claude Code shape: tool_input.tool_input.file_path
    inner = tool_input.get("tool_input", {})
    file_path_raw = inner.get("file_path", "")
    if not file_path_raw:
        sys.exit(0)

    target = Path(file_path_raw).resolve()

    home = Path("~").expanduser().resolve(strict=False)
    learnings_dir = (home / ".aimi" / "learnings").resolve(strict=False)
    telemetry_dir = (home / ".aimi" / "telemetry").resolve(strict=False)

    # Always-blocked: ~/.aimi/learnings/ (recursive)
    try:
        target.relative_to(learnings_dir)
        _deny_path(str(target), "Friction log is append-only")
    except ValueError:
        pass

    # Always-blocked: ~/.aimi/telemetry/ (recursive)
    try:
        target.relative_to(telemetry_dir)
        _deny_path(str(target), "Telemetry log is append-only")
    except ValueError:
        pass

    # Always-blocked: the jq -> Python golden corpus.  It sits with the two
    # $HOME checks above rather than in the .aimi/ section below because it
    # blocks unconditionally: the corpus is a repository file, so it must be
    # refused before the .aimi/ walk-up that the rest of main() depends on.
    if target.parts[-3:] == _GOLDEN_CORPUS_PARTS:
        _deny_path(
            str(target),
            "This corpus was captured from the jq implementations before they "
            "were deleted, so it is the evidence that the port changed nothing "
            "-- regenerating it from today's Python would turn it into a "
            "snapshot of whatever the code already does. Move it the way it has "
            "always been moved: rewrite the generator or re-run the capture, in "
            "the same commit as the rule change and with the reason in the "
            "commit message, never by editing this file by hand",
            exit_code=2,
        )

    # Find .aimi/ directory by walking up from cwd.
    cwd = Path(os.getcwd()).resolve()
    aimi_dir = find_aimi_dir(cwd)

    if aimi_dir is not None:
        state_dir = (aimi_dir / "state").resolve()
        reviews_dir = (aimi_dir / "reviews").resolve()
        tasks_dir = (aimi_dir / "tasks").resolve()
        lock_file = aimi_dir / ".execute.lock"

        # Always-blocked: any path inside .aimi/state/ (recursive)
        try:
            target.relative_to(state_dir)
            _deny_path(str(target), "State files reflect live runtime")
        except ValueError:
            pass

        # Always-blocked: any path inside .aimi/reviews/ (recursive)
        #
        # Non-zero on purpose, matching the golden corpus above rather than the
        # four denies that exit 0.  Both are real PreToolUse deny protocols and
        # _deny_path prints the same permissionDecision JSON either way, so the
        # stdout signal here is byte-identical to the others; the exit status is
        # added on top.  It is added because a caller that reads the status
        # rather than the JSON -- `guard ... && echo allowed`, which is exactly
        # how this block's own regression check reads it -- would take a 0 for
        # permission to write, and this file has one writer: `aimi-cli
        # write-review`.
        try:
            target.relative_to(reviews_dir)
            _deny_path(
                str(target),
                "Phase reviews are written by aimi-cli so they outlive the "
                "session that produced them. Pipe the markdown instead: "
                "aimi-cli write-review --feature <slug> --phase <N>",
                exit_code=2,
            )
        except ValueError:
            pass

        # Everything below only applies to paths inside .aimi/tasks/. First
        # match wins (_deny_path exits), so ordering mirrors the prior
        # separate try/except blocks: roadmap.json, then phase handoff.md,
        # then a live-locked tasks.json.
        if _is_within(target, tasks_dir):
            # Always-blocked: .aimi/tasks/<feature>/roadmap.json
            if target.name == "roadmap.json":
                _deny_path(
                    str(target),
                    "Roadmap state is owned by aimi-cli roadmap verbs. "
                    "To correct an existing phase's goal, successCriteria, "
                    "creates, needs, areas or branch, use: aimi-cli "
                    "roadmap-amend-phase --feature <slug> --phase <id>",
                    # provenance: staging pipeline outline step 02
                )

            # Always-blocked: .aimi/tasks/<feature>/phase-N/handoff.md
            if target.name == "handoff.md" and target.parent.name.startswith("phase-"):
                _deny_path(
                    str(target),
                    "Phase handoff is generated by aimi-cli at phase completion",
                    # provenance: staging pipeline outline step 11
                )

            # Conditionally-blocked: .aimi/tasks/*-tasks.json when lock is alive
            if target.name.endswith("-tasks.json") and lock_file.exists():
                try:
                    pid_text = lock_file.read_text().strip()
                    pid = int(pid_text)
                    if _is_alive(pid):
                        _deny_path(str(target), "Execute lock is active")
                    # else: pid dead, allow
                except (ValueError, OSError):
                    pass  # unreadable / bad pid → allow

    sys.exit(0)


if __name__ == "__main__":
    main()
