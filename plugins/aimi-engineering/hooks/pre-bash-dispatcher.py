#!/usr/bin/env python3
from __future__ import annotations

import ast
import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from hook_utils import safe_hook, effective_cwd, load_aimi_config, deny  # noqa: E402

# ---------------------------------------------------------------------------
# Module-level pre-compiled regexes — compiled once on import
# ---------------------------------------------------------------------------

# Command-position anchor: a `git commit` (or `git -C ... commit`) token, or a
# `git worktree add` (or `git -C ... worktree add`) token, must appear at the
# start of a shell "statement" — string start, or immediately after `;`,
# `&&`, `||`, `|`, or a newline — rather than matching anywhere in the
# command text (e.g. inside a grep/echo argument or a heredoc body).
# Each lookbehind branch below is fixed-width, so it is valid under Python's
# re module. No re.MULTILINE flag: the newline case is handled as a literal
# lookbehind alternative, not via `^`/`$` line semantics.
#
# Residual risk (accepted, documented here rather than fixed). This list is
# meant to be exhaustive — a reader should be able to trust that a shape not
# named here is detected. Undetected:
#   * nested inside `bash -c '...'`, a subshell `(git commit)`, or command
#     substitution `$(git commit)`;
#   * chained with a single `&` (background) rather than `&&`;
#   * inside an `if`/`then`, `else`, `case`, loop (`do ... done`) or brace-
#     group body;
#   * preceded on the same statement by an environment assignment or wrapper
#     prefix — `GIT_AUTHOR_DATE=... git commit`, `env`, `sudo`, `time`,
#     `nohup`. `\s*` after the anchor consumes whitespace only, so anything
#     between the separator and `git` breaks the match;
#   * option forms other than `-C`: `git -c key=value commit`,
#     `git --git-dir=... commit`.
# The old unanchored regexes caught these shapes only "by accident" — while
# also false-positiving on mere mentions of the phrase. Closing the quote-
# wrapped cases would require quote/paren-aware shell parsing, which is out of
# scope here.
# The trailing run must exclude `\n` specifically. A newline is both an anchor
# (its own lookbehind branch) and a `\s` character, so `\s*` would let every
# position inside a whitespace run start a match and then backtrack across the
# rest of it — quadratic on a long run of blank lines (seconds of CPU on a few
# thousand, enough to exhaust the hook timeout and stop denying anything).
# `[^\S\n]*` is "whitespace except newline", which keeps `\r`, `\v` and `\f`
# matching exactly as `\s*` did; `[ \t]*` would silently stop detecting a
# command prefixed by a carriage return.
_CMD_START = r"(?:(?<=^)|(?<=;)|(?<=&&)|(?<=\|\|)|(?<=\|)|(?<=\n))[^\S\n]*"

_GIT_COMMIT_RE = re.compile(_CMD_START + r"\bgit\s+commit\b")
_GIT_WORKTREE_ADD_RE = re.compile(_CMD_START + r"git\s+worktree\s+add\b")

# Used by handle_default_branch for git -C variant. Path token accepts a
# double-quoted path, a single-quoted path, or a bare non-whitespace token so
# `git -C "/path with spaces" commit` is detected too.
_GIT_C_COMMIT_RE = re.compile(
    _CMD_START + r"\bgit\s+-C\s+(?:\"[^\"]+\"|'[^']+'|\S+)\s+commit\b"
)

# Used by handle_worktree_budget for git -C variant. Same quoted-or-bare path
# token as _GIT_C_COMMIT_RE, so `git -C "/path with spaces" worktree add` is
# detected too.
_GIT_C_WORKTREE_ADD_RE = re.compile(
    _CMD_START + r"\bgit\s+-C\s+(?:\"[^\"]+\"|'[^']+'|\S+)\s+worktree\s+add\b"
)

# Heredoc opener: `<<` or `<<-` followed (after optional whitespace) by a
# bare, single-quoted, or double-quoted tag. The negative lookbehind/lookahead
# pair excludes `<<<` (here-string redirection) from ever being treated as an
# opener.
_HEREDOC_OPEN_RE = re.compile(
    r"(?<!<)<<(?!<)(-)?\s*(?:'([A-Za-z0-9_]+)'|\"([A-Za-z0-9_]+)\"|([A-Za-z0-9_]+))"
)


def _strip_heredocs(command: str) -> str:
    """Return a detection-only copy of *command* with heredoc bodies removed.

    Recognizes <<TAG, <<'TAG', <<"TAG", and <<-TAG opener forms. Never
    misidentifies a `<<<` here-string redirection as a heredoc opener (see
    _HEREDOC_OPEN_RE). A heredoc-lookalike line inside a real heredoc body is
    never re-scanned for its own opener — the body-skipping loop only checks
    each line against the *current* heredoc's closing tag — so it cannot
    cause a subsequent real statement after the true terminator to be
    swallowed.

    Fails closed on any internal error (including an unterminated heredoc):
    returns the original, unmodified command string rather than raising or
    emitting a partially-stripped result, so a malformed heredoc can never
    hide a real commit from the caller's detection regexes.
    """
    try:
        lines = command.split("\n")
        out: list[str] = []
        i = 0
        n = len(lines)
        while i < n:
            line = lines[i]
            m = _HEREDOC_OPEN_RE.search(line)
            if not m:
                out.append(line)
                i += 1
                continue

            dash = m.group(1) is not None
            tag = m.group(2) or m.group(3) or m.group(4)

            out.append(line)  # keep the opener line itself
            i += 1

            terminated = False
            while i < n:
                body_line = lines[i]
                i += 1
                candidate = body_line.strip() if dash else body_line
                if candidate == tag:
                    terminated = True
                    break
                # body line: intentionally dropped, never re-scanned for its
                # own heredoc-opener lookalikes

            if not terminated:
                # Unterminated heredoc — fail closed on the whole command.
                return command

        return "\n".join(out)
    except Exception:  # noqa: BLE001
        return command


# ---------------------------------------------------------------------------
# Handler: default-branch guard
# ---------------------------------------------------------------------------

def _load_protected_branches(cwd: str) -> set[str]:
    protected = {"main", "master", "develop"}
    config = load_aimi_config(start=Path(cwd))
    extra = config.get("guards", {}).get("protectedBranches", [])
    protected.update(extra)
    return protected


def handle_default_branch(command: str, tool_input: dict) -> None:
    """Block git commits on protected branches.

    Mirrors guard-default-branch.py logic.  Calls deny() + prints + exits on
    block; returns normally to allow the next handler to run.
    """
    # Fast-path: must contain a git commit invocation (heredoc bodies are
    # stripped from the detection copy; the raw `command` below is untouched)
    detect = _strip_heredocs(command)
    if not (_GIT_COMMIT_RE.search(detect) or _GIT_C_COMMIT_RE.search(detect)):
        return

    # Bypass env
    if os.environ.get("AIMI_DEFAULT_BRANCH_GUARD") == "off":
        return

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
        return

    if branch in protected:
        msg = (
            f"Commits on the protected branch `{branch}` are blocked.\n"
            "Use a feature worktree:\n"
            "  git worktree add /tmp/<feature> -b feat/<feature>\n"
            "Then commit from that worktree. The default branch stays clean for merges."
        )
        print(deny(msg))
        sys.exit(0)


# ---------------------------------------------------------------------------
# Handler: shell=True guard
# ---------------------------------------------------------------------------

def _scan_for_shell_true(blob: str) -> list[int]:
    """Return 1-based line numbers where shell=True is passed as a keyword argument.

    Uses ast.parse to walk Call nodes so that occurrences inside string
    literals, comments, and docstrings are never flagged.  On SyntaxError the
    file is skipped (returns []) to avoid blocking legitimate WIP.
    """
    try:
        tree = ast.parse(blob)
    except SyntaxError:
        return []

    hits: list[int] = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        for kw in node.keywords:
            if (
                kw.arg == "shell"
                and isinstance(kw.value, ast.Constant)
                and kw.value.value is True
            ):
                hits.append(kw.value.lineno)
    hits.sort()
    return hits


def handle_shell_true(command: str, tool_input: dict) -> None:
    """Block git commits that stage Python files containing shell=True.

    Mirrors guard-shell-true.py logic.  Calls deny() + prints + exits on
    block; returns normally to continue.
    """
    # Fast-path: must contain a git commit invocation (heredoc bodies are
    # stripped from the detection copy; the raw `command` below is untouched)
    detect = _strip_heredocs(command)
    if not (_GIT_COMMIT_RE.search(detect) or _GIT_C_COMMIT_RE.search(detect)):
        return

    # Bypass env
    if os.environ.get("AIMI_SHELL_TRUE_GUARD") == "off":
        return

    cwd = effective_cwd(command, tool_input)

    try:
        result = subprocess.run(
            ["git", "-C", cwd, "diff", "--cached", "--name-only", "--", "*.py"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        staged_files = [f for f in result.stdout.splitlines() if f.strip()]
    except Exception:  # noqa: BLE001
        return

    if not staged_files:
        return

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
        print(deny(msg))
        sys.exit(0)


# ---------------------------------------------------------------------------
# Handler: worktree budget guard
# ---------------------------------------------------------------------------

def _allow() -> None:
    sys.exit(0)


def _current_branch(cwd: str) -> str | None:
    """Resolve the git branch checked out at *cwd*, or None on any failure."""
    try:
        result = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode != 0:
            return None
        branch = result.stdout.strip()
        return branch or None
    except Exception:  # noqa: BLE001
        return None


def _select_governing_tasks_file(candidates: list[Path], branch: str | None) -> Path:
    """Pick the tasks file that governs maxConcurrency for this session.

    Prefers the single candidate whose metadata.branchName matches *branch*
    (deterministic under parallel phase sessions, keyed off the same
    branch-per-phase convention already used by the roadmap claim schema);
    falls back to the most recently modified candidate when there is no
    unique branch match, preserving the prior flat/legacy newest-mtime
    behavior for flat and non-phase projects.
    """
    matches: list[Path] = []
    if branch:
        for candidate in candidates:
            try:
                data = json.loads(candidate.read_text())
                meta = data.get("metadata") if isinstance(data, dict) else None
                if isinstance(meta, dict) and meta.get("branchName") == branch:
                    matches.append(candidate)
            except Exception:  # noqa: BLE001
                continue
        if len(matches) == 1:
            return matches[0]
    return max(matches or candidates, key=lambda p: p.stat().st_mtime)


def _find_tasks_json(start: str) -> tuple[Path | None, Path | None]:
    """Walk up from *start* looking for .aimi/tasks/*-tasks.json (flat) or
    .aimi/tasks/<feature>/phase-<N>-<slug>/*-tasks.json (nested phase folders).

    Returns (root_path, tasks_json_path) where root_path is the directory
    containing .aimi/, or (None, None) if not found.
    """
    current = Path(start).resolve()
    while True:
        aimi_dir = current / ".aimi" / "tasks"
        if aimi_dir.is_dir():
            candidates = list(aimi_dir.glob("*-tasks.json"))
            candidates += list(aimi_dir.glob("*/*/*-tasks.json"))
            if candidates:
                branch = _current_branch(start)
                latest = _select_governing_tasks_file(candidates, branch)
                return current, latest
        parent = current.parent
        if parent == current:
            break
        current = parent
    return None, None


def _count_active_worktrees(cwd: str) -> int:
    """Run ``git worktree list --porcelain`` and count active worktrees.

    Returns the count minus 1 (to exclude the main checkout).
    Returns 0 on any error.
    """
    try:
        result = subprocess.run(
            ["git", "-C", cwd, "worktree", "list", "--porcelain"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode != 0:
            return 0
        count = sum(
            1 for line in result.stdout.splitlines() if line.startswith("worktree ")
        )
        return max(0, count - 1)  # subtract main checkout
    except Exception:  # noqa: BLE001
        return 0


def handle_worktree_budget(command: str, tool_input: dict) -> None:
    """Block git worktree add when the concurrency budget is exhausted.

    Mirrors guard-worktree-budget.py logic.  Calls deny() + prints + exits on
    block; calls _allow() (sys.exit(0)) to allow.
    """
    # Fast-path: only intercept `git worktree add` commands (heredoc bodies
    # are stripped from the detection copy; the raw `command` below, passed
    # to effective_cwd and the rest of this function, is untouched).
    detect = _strip_heredocs(command)
    if not (_GIT_WORKTREE_ADD_RE.search(detect) or _GIT_C_WORKTREE_ADD_RE.search(detect)):
        _allow()

    # Bypass env var.
    if os.environ.get("AIMI_WORKTREE_BUDGET_GUARD", "").lower() == "off":
        _allow()

    cwd = effective_cwd(command, tool_input)

    root, tasks_path = _find_tasks_json(cwd)
    if root is None:
        # Not inside an aimi-managed project — silent allow.
        _allow()

    # Read maxConcurrency from metadata.
    max_concurrency = 20
    try:
        tasks_data = json.loads(tasks_path.read_text())
        raw = tasks_data.get("metadata", {}).get("maxConcurrency")
        if isinstance(raw, int):
            max_concurrency = raw
    except Exception:  # noqa: BLE001
        pass

    active_count = _count_active_worktrees(cwd)

    if active_count >= max_concurrency:
        rel_path = tasks_path.relative_to(root)
        print(deny(
            f"Worktree budget exhausted: {active_count}/{max_concurrency} active.\n"
            f"Wait for an in-flight story to complete, or raise metadata.maxConcurrency\n"
            f"in {rel_path}. Set AIMI_WORKTREE_BUDGET_GUARD=off to bypass."
        ))
        sys.exit(0)

    _allow()


# ---------------------------------------------------------------------------
# Main dispatcher
# ---------------------------------------------------------------------------

@safe_hook
def main(tool_input: dict) -> None:
    command = tool_input.get("tool_input", {}).get("command", "")

    # Literal prefilter. Every detection regex below requires the literal
    # "git", and _strip_heredocs only ever removes whole lines, so a command
    # without it cannot match and needs no further work. Anchoring the regexes
    # cost them their leading literal, which is what CPython's re uses to skip
    # ahead; without this the 6-branch alternation is evaluated at every offset
    # of every command the hook ever sees.
    if "git" not in command:
        sys.exit(0)

    # Heredoc bodies are stripped from the detection copy only; the raw
    # `command` passed to the handlers below (and on to effective_cwd/
    # subprocess.run) is untouched.
    detect = _strip_heredocs(command)
    if _GIT_COMMIT_RE.search(detect) or _GIT_C_COMMIT_RE.search(detect):
        handle_default_branch(command, tool_input.get("tool_input", {}))
        handle_shell_true(command, tool_input.get("tool_input", {}))
        sys.exit(0)

    if _GIT_WORKTREE_ADD_RE.search(detect) or _GIT_C_WORKTREE_ADD_RE.search(detect):
        handle_worktree_budget(command, tool_input.get("tool_input", {}))
        sys.exit(0)

    # Unrelated command — silent allow
    sys.exit(0)


if __name__ == "__main__":
    main()
