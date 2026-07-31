from __future__ import annotations

import importlib.util
import io
import json
import re
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch, call

import pytest

_HOOKS_DIR = Path(__file__).parent.parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))


def _load_dispatcher():
    spec = importlib.util.spec_from_file_location(
        "pre_bash_dispatcher",
        _HOOKS_DIR / "pre-bash-dispatcher.py",
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


dispatcher = _load_dispatcher()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _run_dispatcher(
    command: str,
    extra_env: dict | None = None,
    cwd: str | None = None,
    branch: str = "feat/test",
):
    """Feed the full hook event JSON via stdin, run dispatcher.main(), capture output.

    *branch* is the branch every mocked ``git rev-parse --abbrev-ref HEAD`` call
    resolves to (default: an unprotected feature branch, preserving prior
    callers' behavior). Pass a protected branch name (e.g. "main") to exercise
    the deny path through the full main() entry point.
    """
    inner: dict = {"command": command}
    if cwd:
        inner["cwd"] = cwd
    # Full Claude Code hook event envelope: {"tool_input": {...}}
    event = {"tool_input": inner}
    stdin_data = json.dumps(event)

    captured = []
    env_patch = extra_env or {}

    with (
        patch("sys.stdin", io.StringIO(stdin_data)),
        patch.dict("os.environ", env_patch, clear=False),
        patch("builtins.print", side_effect=captured.append),
        patch("subprocess.run", return_value=_mock_proc(branch)),
    ):
        try:
            dispatcher.main()
        except SystemExit:
            pass

    return captured


def _mock_proc(branch: str = "feat/test"):
    p = MagicMock()
    p.stdout = branch + "\n"
    p.returncode = 0
    return p


# ---------------------------------------------------------------------------
# Routing tests
# ---------------------------------------------------------------------------

def test_dispatcher_routes_git_commit_to_default_branch_handler():
    """git commit on a protected branch → default-branch handler fires → deny."""
    inner = {"command": "git commit -m 'x'", "cwd": "/tmp"}
    event = {"tool_input": inner}
    stdin_data = json.dumps(event)

    mock_proc = _mock_proc("main")  # protected branch
    captured = []

    with (
        patch("sys.stdin", io.StringIO(stdin_data)),
        patch("subprocess.run", return_value=mock_proc),
        patch("builtins.print", side_effect=captured.append),
    ):
        try:
            dispatcher.main()
        except SystemExit:
            pass

    assert captured, "Expected deny from default-branch handler"
    data = json.loads(captured[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert "main" in data["hookSpecificOutput"]["userMessage"]


def test_dispatcher_routes_git_commit_to_shell_true_handler():
    """git commit with shell=True staged file → shell-true handler fires → deny."""
    inner = {"command": "git commit -m 'x'", "cwd": "/tmp"}
    event = {"tool_input": inner}
    stdin_data = json.dumps(event)

    blob = "subprocess.run('ls', shell=True)\n"

    def fake_run(args, **kwargs):
        mock = MagicMock()
        mock.returncode = 0
        if "rev-parse" in args:
            # default-branch check: feature branch → allow
            mock.stdout = "feat/test\n"
        elif "diff" in args and "--cached" in args:
            mock.stdout = "foo.py\n"
        elif "show" in args:
            mock.stdout = blob
        else:
            mock.stdout = ""
        return mock

    captured = []

    with (
        patch("sys.stdin", io.StringIO(stdin_data)),
        patch("subprocess.run", side_effect=fake_run),
        patch("builtins.print", side_effect=captured.append),
    ):
        try:
            dispatcher.main()
        except SystemExit:
            pass

    assert captured, "Expected deny from shell-true handler"
    data = json.loads(captured[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert "foo.py" in data["hookSpecificOutput"]["userMessage"]


def test_dispatcher_routes_git_worktree_add_to_budget_handler(tmp_path, monkeypatch):
    """git worktree add when budget exhausted → worktree-budget handler fires → deny."""
    # Set up .aimi/tasks
    tasks_dir = tmp_path / ".aimi" / "tasks"
    tasks_dir.mkdir(parents=True)
    data = {
        "schemaVersion": "3.3",
        "metadata": {"title": "T", "type": "feature", "branchName": "feat/x", "maxConcurrency": 2},
        "userStories": [],
    }
    (tasks_dir / "2026-06-09-test-tasks.json").write_text(json.dumps(data))

    monkeypatch.chdir(tmp_path)
    monkeypatch.delenv("AIMI_WORKTREE_BUDGET_GUARD", raising=False)

    # Simulate 2 active worktrees (= budget exhausted at max=2)
    def fake_run(args, **kwargs):
        if "worktree" in args and "list" in args:
            output = (
                f"worktree {tmp_path}\nHEAD aaaa\nbranch refs/heads/main\n\n"
                f"worktree {tmp_path}/wt1\nHEAD bbbb\nbranch refs/heads/feat/wt1\n\n"
                f"worktree {tmp_path}/wt2\nHEAD cccc\nbranch refs/heads/feat/wt2\n"
            )
            return MagicMock(returncode=0, stdout=output)
        return MagicMock(returncode=0, stdout="")

    inner = {"command": "git worktree add ../new-wt feat/y", "cwd": str(tmp_path)}
    event = {"tool_input": inner}
    stdin_data = json.dumps(event)

    captured = []

    with (
        patch("sys.stdin", io.StringIO(stdin_data)),
        patch("subprocess.run", side_effect=fake_run),
        patch("builtins.print", side_effect=captured.append),
    ):
        try:
            dispatcher.main()
        except SystemExit:
            pass

    assert captured, "Expected deny from worktree-budget handler"
    deny_data = json.loads(captured[0])
    assert deny_data["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert "2/2" in deny_data["hookSpecificOutput"]["userMessage"]


def test_dispatcher_silent_allow_on_unrelated_command():
    """ls -la → no handler fires → silent allow (no output, exit 0)."""
    inner = {"command": "ls -la"}
    event = {"tool_input": inner}
    stdin_data = json.dumps(event)

    captured = []

    with (
        patch("sys.stdin", io.StringIO(stdin_data)),
        patch("builtins.print", side_effect=captured.append),
    ):
        try:
            dispatcher.main()
        except SystemExit:
            pass

    assert not captured, "Expected no output for unrelated command"


def test_dispatcher_chains_handlers_in_order_for_commit():
    """For git commit: default-branch runs first, then shell-true.

    When default-branch allows (feature branch), shell-true still runs.
    When default-branch denies (protected branch), shell-true does NOT run
    because the process exits after the first deny.
    """
    call_order = []

    original_handle_default_branch = dispatcher.handle_default_branch
    original_handle_shell_true = dispatcher.handle_shell_true

    def tracking_default_branch(command, tool_input):
        call_order.append("default_branch")
        # Don't block — feature branch
        return original_handle_default_branch.__wrapped__(command, tool_input) if hasattr(original_handle_default_branch, "__wrapped__") else None

    def tracking_shell_true(command, tool_input):
        call_order.append("shell_true")
        return None  # allow

    inner = {"command": "git commit -m 'x'"}
    event = {"tool_input": inner}
    stdin_data = json.dumps(event)

    # Mock subprocess to return feature branch (no block)
    mock_proc = _mock_proc("feat/test")

    with (
        patch("sys.stdin", io.StringIO(stdin_data)),
        patch("subprocess.run", return_value=mock_proc),
        patch.object(dispatcher, "handle_default_branch", side_effect=tracking_default_branch),
        patch.object(dispatcher, "handle_shell_true", side_effect=tracking_shell_true),
        patch("builtins.print"),
    ):
        try:
            dispatcher.main()
        except SystemExit:
            pass

    assert call_order == ["default_branch", "shell_true"], (
        f"Expected default_branch → shell_true, got: {call_order}"
    )


# ---------------------------------------------------------------------------
# US-001: command-position anchoring (issue #82) — full main() path regressions
# ---------------------------------------------------------------------------

def test_main_denies_git_C_commit_on_protected_branch():
    """Confirms the L315 bug fix: `git -C <path> commit` must reach the handlers
    through the real main() entry point (previously only _GIT_COMMIT_RE was
    checked there, so this command was silently allowed straight through)."""
    out = _run_dispatcher("git -C /repo commit -m x", branch="main")
    assert out, "Expected deny from the full main() path"
    data = json.loads(out[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_main_denies_quoted_path_git_C_commit_on_protected_branch():
    out = _run_dispatcher('git -C "/path with spaces" commit -m x', branch="main")
    assert out, "Expected deny from the full main() path"
    data = json.loads(out[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_main_denies_newline_separated_multi_statement_commit_on_protected_branch():
    out = _run_dispatcher("cd /repo\ngit add -A\ngit commit -m x", branch="main")
    assert out, "Expected deny from the full main() path"
    data = json.loads(out[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_main_allows_grep_mention_silently_with_no_subprocess_calls():
    """A grep mention of the phrase must never invoke subprocess.run through main()."""
    inner = {"command": 'grep -rn "git commit" file.txt'}
    event = {"tool_input": inner}
    stdin_data = json.dumps(event)

    captured = []
    with (
        patch("sys.stdin", io.StringIO(stdin_data)),
        patch("builtins.print", side_effect=captured.append),
        patch("subprocess.run") as mock_run,
    ):
        try:
            dispatcher.main()
        except SystemExit:
            pass

    assert not captured, "Expected silent allow"
    mock_run.assert_not_called()


def test_main_allows_heredoc_body_mention_silently_with_no_subprocess_calls():
    """A heredoc body mentioning the phrase must never invoke subprocess.run through main()."""
    inner = {"command": "cat <<EOF\nremember to git commit\nEOF"}
    event = {"tool_input": inner}
    stdin_data = json.dumps(event)

    captured = []
    with (
        patch("sys.stdin", io.StringIO(stdin_data)),
        patch("builtins.print", side_effect=captured.append),
        patch("subprocess.run") as mock_run,
    ):
        try:
            dispatcher.main()
        except SystemExit:
            pass

    assert not captured, "Expected silent allow"
    mock_run.assert_not_called()


def test_main_denies_mixed_mention_and_real_commit_on_protected_branch():
    """A mention (grep) followed by a real invocation in the same command must
    still deny — the anchored regex finds the real invocation after `&&`."""
    out = _run_dispatcher('grep -r "git commit" . && git commit -m x', branch="main")
    assert out, "Expected deny from the full main() path"
    data = json.loads(out[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_neither_commit_regex_has_multiline_flag():
    assert not (dispatcher._GIT_COMMIT_RE.flags & re.MULTILINE)
    assert not (dispatcher._GIT_C_COMMIT_RE.flags & re.MULTILINE)


# ---------------------------------------------------------------------------
# US-002: command-position anchoring parity for worktree-add (issue #82) --
# full main() path routing regression
# ---------------------------------------------------------------------------

def test_dispatcher_routes_git_C_worktree_add_to_budget_handler(tmp_path, monkeypatch):
    """Confirms the L320 routing fix: `git -C <path> worktree add` must reach
    handle_worktree_budget through the real main() entry point (previously
    only _GIT_WORKTREE_ADD_RE was checked there, and it does not match the -C
    form, so this command was silently allowed straight through without ever
    counting active worktrees)."""
    tasks_dir = tmp_path / ".aimi" / "tasks"
    tasks_dir.mkdir(parents=True)
    data = {
        "schemaVersion": "3.3",
        "metadata": {"title": "T", "type": "feature", "branchName": "feat/x", "maxConcurrency": 2},
        "userStories": [],
    }
    (tasks_dir / "2026-06-09-test-tasks.json").write_text(json.dumps(data))

    monkeypatch.delenv("AIMI_WORKTREE_BUDGET_GUARD", raising=False)

    # Simulate 2 active worktrees (= budget exhausted at max=2)
    def fake_run(args, **kwargs):
        if "worktree" in args and "list" in args:
            output = (
                f"worktree {tmp_path}\nHEAD aaaa\nbranch refs/heads/main\n\n"
                f"worktree {tmp_path}/wt1\nHEAD bbbb\nbranch refs/heads/feat/wt1\n\n"
                f"worktree {tmp_path}/wt2\nHEAD cccc\nbranch refs/heads/feat/wt2\n"
            )
            return MagicMock(returncode=0, stdout=output)
        return MagicMock(returncode=0, stdout="")

    inner = {"command": f"git -C {tmp_path} worktree add ../new-wt feat/y"}
    event = {"tool_input": inner}
    stdin_data = json.dumps(event)

    captured = []

    with (
        patch("sys.stdin", io.StringIO(stdin_data)),
        patch("subprocess.run", side_effect=fake_run),
        patch("builtins.print", side_effect=captured.append),
    ):
        try:
            dispatcher.main()
        except SystemExit:
            pass

    assert captured, "Expected deny from worktree-budget handler via the git -C main() routing fix"
    deny_data = json.loads(captured[0])
    assert deny_data["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert "2/2" in deny_data["hookSpecificOutput"]["userMessage"]


def test_neither_worktree_add_regex_has_multiline_flag():
    assert not (dispatcher._GIT_WORKTREE_ADD_RE.flags & re.MULTILINE)
    assert not (dispatcher._GIT_C_WORKTREE_ADD_RE.flags & re.MULTILINE)


# ---------------------------------------------------------------------------
# Review follow-up: _CMD_START trailing-run correctness and cost
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    "whitespace",
    ["\r", "\v", "\f", "\r\n", " ", "\t", "  \t "],
    ids=["cr", "vtab", "formfeed", "crlf", "space", "tab", "mixed"],
)
def test_cmd_start_accepts_every_non_newline_whitespace(whitespace):
    """Whitespace between the anchor and `git` must not break detection.

    `_CMD_START`'s trailing run excludes `\\n` only, so that a long blank-line
    run cannot backtrack quadratically. Narrowing it further to `[ \\t]*` would
    silently stop detecting a command prefixed by a carriage return, vertical
    tab, or form feed -- a fail-open regression this pins.
    """
    assert dispatcher._GIT_COMMIT_RE.search(whitespace + "git commit -m x")
    assert dispatcher._GIT_WORKTREE_ADD_RE.search(whitespace + "git worktree add /tmp/w")


def test_cmd_start_scan_is_linear_in_blank_lines():
    """A long run of blank lines must not cost quadratic time to reject.

    A `\\n` is both an anchor and a `\\s` character, so a trailing `\\s*` lets
    every position in a whitespace run start a match and then backtrack over
    the rest -- seconds of CPU on a few thousand blank lines, enough to blow
    the hook timeout and stop the guard denying anything at all. Timing is
    coarse on purpose: the pre-fix cost at n=4000 was over a second, so a
    generous ceiling still fails loudly on a regression without being flaky.
    """
    import time

    payload = " \n" * 4000 + "echo done"
    start = time.perf_counter()
    for pattern in (
        dispatcher._GIT_COMMIT_RE,
        dispatcher._GIT_C_COMMIT_RE,
        dispatcher._GIT_WORKTREE_ADD_RE,
        dispatcher._GIT_C_WORKTREE_ADD_RE,
    ):
        assert pattern.search(payload) is None
    elapsed = time.perf_counter() - start
    assert elapsed < 0.5, f"anchored scan took {elapsed:.3f}s -- backtracking regression"


def test_main_prefilter_allows_command_without_the_git_literal():
    """The `"git" not in command` prefilter exits 0 without scanning."""
    out = _run_dispatcher("echo hello && npm run build", branch="main")
    assert out == [], f"Expected silent allow, got {out}"


def test_main_prefilter_does_not_swallow_a_real_commit():
    """The prefilter must never short-circuit a command it should deny."""
    out = _run_dispatcher("git commit -m x", branch="main")
    assert out, "Expected deny -- prefilter wrongly skipped a real invocation"
    assert json.loads(out[0])["hookSpecificOutput"]["permissionDecision"] == "deny"


# ---------------------------------------------------------------------------
# Statement-prefix detection: env assignments, wrappers, body keywords
#
# 1.119.1's anchoring rejected every token between the separator and `git`,
# which silently stopped guarding shapes the pre-anchoring regexes caught.
# ---------------------------------------------------------------------------

def _detects(command):
    """True when any of the four guard regexes matches the detection copy."""
    detect = dispatcher._strip_heredocs(command)
    return any(
        pattern.search(detect)
        for pattern in (
            dispatcher._GIT_COMMIT_RE,
            dispatcher._GIT_C_COMMIT_RE,
            dispatcher._GIT_WORKTREE_ADD_RE,
            dispatcher._GIT_C_WORKTREE_ADD_RE,
        )
    )


@pytest.mark.parametrize(
    "command",
    [
        "GIT_AUTHOR_DATE=2020-01-01 git commit -m x",
        'GIT_AUTHOR_DATE="2020-01-01 12:00:00" git commit -m x',
        "GIT_AUTHOR_DATE='2020-01-01 12:00:00' git commit -m x",
        "GIT_AUTHOR_DATE=2020-01-01 GIT_COMMITTER_DATE=2020-01-01 git commit -m x",
        "EMPTY= git commit -m x",
        'FOO=a"b" git commit -m x',
        'PATH="$HOME/bin:$PATH" git commit',
        "sudo git commit -m x",
        "env FOO=1 git commit",
        "time git commit",
        "nohup git commit",
        "for f in a b; do git commit -m $f; done",
        "if ok; then git commit; fi",
        "if x; then y; else git commit; fi",
        "{ git commit -m x; }",
        "! git commit",
        "while read l; do sudo GIT_AUTHOR_DATE=1 git commit; done",
        "cd /r && sudo git commit -m x",
        "x\n  GIT_AUTHOR_DATE=1 git commit",
        "sudo git -C /repo commit -m x",
        'FOO=1 git -C "/path with spaces" commit -m x',
        "sudo git worktree add /tmp/w",
        "FOO=1 git worktree add /tmp/w",
        "for f in a; do git worktree add /tmp/w; done",
        "if x; then git -C /r worktree add /tmp/w; fi",
    ],
)
def test_statement_prefix_shapes_are_detected(command):
    assert _detects(command), f"prefix shape must be detected: {command!r}"


@pytest.mark.parametrize(
    "command",
    [
        # Issue #82's own class -- these must never come back.
        'grep -rn "git commit" file.txt',
        "echo 'remember to git commit later'",
        'rg "git commit" -n',
        'echo "TODO: git commit"',
        'grep -rn "git worktree add" .',
        'echo "sudo git commit"',
        'echo "FOO=1 git commit"',
        'git log --grep "git commit"',
        "cat <<EOF\nremember to git commit\nEOF",
        # `{` and `!` survive ONLY because a prefix token requires trailing
        # whitespace: `{}`, `{a:`, `{print`, `!=` and `!!` all fail on that.
        r'find . -name "*.py" -exec grep -l "git commit" {} \;',
        "jq '{a: 1}' f.json; echo git commit",
        "awk '{print $1}' f; echo 'git commit'",
        "ls {src,test}; echo git commit",
        'test "$a" != "git commit"',
        "echo ${GIT_DIR} | wc -l; echo git commit",
        # A wrapper-looking word that is not a wrapper invocation.
        "timeout 5 echo git commit",
        "echo hi! git commit",
        'python3 -m pytest -k "git_commit"',
        "git status # git commit later",
        'docker run img sh -c "git commit"',
    ],
)
def test_mere_mentions_stay_undetected_with_statement_prefixes(command):
    assert not _detects(command), f"mention must stay silent: {command!r}"


def test_prefix_depth_ceiling_is_six():
    """Pins the documented {0,6} bound so a reader meets it as a decision.

    Six covers the deepest realistic prefix; a seventh token is dropped.
    """
    assert dispatcher._GIT_COMMIT_RE.search("A=1 " * 6 + "git commit")
    assert dispatcher._GIT_COMMIT_RE.search(
        "x; do sudo GIT_A=1 GIT_B=2 GIT_C=3 git commit"
    )
    assert dispatcher._GIT_COMMIT_RE.search("A=1 " * 7 + "git commit") is None


def test_prefix_run_does_not_backtrack_exponentially():
    """The assignment-value branches must stay disjoint by first character.

    A bare value branch that may begin with a quote makes `A="xy" ` parse two
    ways over the identical span, doubling live paths per token: 0.0004s at
    n=10, 0.023s at n=16, 0.38s at n=20, over 3s at n=24 before the fix.
    n=30 sits well past the {0,6} ceiling so this fails if EITHER defence --
    the disjoint branches or the bound -- is later removed.
    """
    import time

    payload = 'A="xy" ' * 30 + "gi"
    start = time.perf_counter()
    for pattern in (
        dispatcher._GIT_COMMIT_RE,
        dispatcher._GIT_C_COMMIT_RE,
        dispatcher._GIT_WORKTREE_ADD_RE,
        dispatcher._GIT_C_WORKTREE_ADD_RE,
    ):
        assert pattern.search(payload) is None
    elapsed = time.perf_counter() - start
    assert elapsed < 0.5, f"prefix scan took {elapsed:.3f}s -- backtracking regression"


def test_prefix_scan_is_linear_across_many_anchors():
    """A large command with a prefix run at every anchor must stay cheap.

    The short canary above cannot see a multiplicative term that only shows
    up once many anchor positions each pay the prefix cost.
    """
    import time

    payload = ("A=1 B=2 sudo do then gi;\n" * 1600) + "echo done"
    assert len(payload) > 35_000
    start = time.perf_counter()
    for pattern in (
        dispatcher._GIT_COMMIT_RE,
        dispatcher._GIT_C_COMMIT_RE,
        dispatcher._GIT_WORKTREE_ADD_RE,
        dispatcher._GIT_C_WORKTREE_ADD_RE,
    ):
        assert pattern.search(payload) is None
    elapsed = time.perf_counter() - start
    assert elapsed < 1.0, f"many-anchor scan took {elapsed:.3f}s -- cost regression"


def test_main_denies_env_prefixed_commit_on_protected_branch():
    """End-to-end through main(), not just the regex: the flagship shape."""
    out = _run_dispatcher("GIT_AUTHOR_DATE=2020-01-01 git commit -m x", branch="main")
    assert out, "Expected deny -- env-prefixed commit must reach the guard"
    data = json.loads(out[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_main_denies_sudo_prefixed_commit_on_protected_branch():
    out = _run_dispatcher("sudo git commit -m x", branch="main")
    assert out, "Expected deny -- sudo-prefixed commit must reach the guard"
    assert json.loads(out[0])["hookSpecificOutput"]["permissionDecision"] == "deny"
