from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

HOOKS_DIR = Path(__file__).parent.parent
sys.path.insert(0, str(HOOKS_DIR))


def _load_dispatcher():
    spec = importlib.util.spec_from_file_location(
        "pre_bash_dispatcher",
        HOOKS_DIR / "pre-bash-dispatcher.py",
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


dispatcher = _load_dispatcher()


def _run_handler(command: str, staged_files: list[str], blobs: dict[str, str], extra_env: dict | None = None):
    """
    staged_files: list of paths returned by git diff --cached
    blobs: mapping path -> content returned by git show :<path>
    """
    tool_input = {"command": command}
    captured = []

    def fake_run(args, **kwargs):
        mock = MagicMock()
        mock.returncode = 0
        # git diff --cached --name-only
        if "diff" in args and "--cached" in args:
            mock.stdout = "\n".join(staged_files) + ("\n" if staged_files else "")
        # git show :<path>
        elif "show" in args:
            path_arg = next((a for a in args if a.startswith(":")), None)
            if path_arg:
                path = path_arg[1:]
                mock.stdout = blobs.get(path, "")
        else:
            mock.stdout = ""
        return mock

    env_patch = extra_env or {}
    with (
        patch("subprocess.run", side_effect=fake_run),
        patch.dict("os.environ", env_patch, clear=False),
        patch("builtins.print", side_effect=captured.append),
    ):
        try:
            dispatcher.handle_shell_true(command, tool_input)
        except SystemExit:
            pass

    return captured


def test_blocks_when_staged_py_contains_shell_true():
    blob = "import subprocess\nsubprocess.run('ls', shell=True)\n"
    out = _run_handler("git commit -m x", ["foo.py"], {"foo.py": blob})
    assert out
    data = json.loads(out[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert "foo.py" in data["hookSpecificOutput"]["userMessage"]


def test_allows_when_inside_comment():
    blob = "# subprocess.run('ls', shell=True)\n"
    out = _run_handler("git commit -m x", ["foo.py"], {"foo.py": blob})
    assert not out, "Comment line should be skipped"


def test_allows_when_inside_docstring():
    blob = '"""\nsubprocess.run(cmd, shell=True)\n"""\n'
    out = _run_handler("git commit -m x", ["foo.py"], {"foo.py": blob})
    assert not out, "Docstring content should be skipped"


def test_allows_when_no_python_staged():
    out = _run_handler("git commit -m x", [], {})
    assert not out


def test_skips_non_commit_subcommands():
    for cmd in ["git status", "git log --oneline", "git diff HEAD"]:
        out = _run_handler(cmd, ["foo.py"], {"foo.py": "shell=True\n"})
        assert not out, f"Non-commit command '{cmd}' should be skipped"


def test_bypass_env_allows(monkeypatch):
    monkeypatch.setenv("AIMI_SHELL_TRUE_GUARD", "off")
    blob = "subprocess.run('ls', shell=True)\n"
    out = _run_handler("git commit -m x", ["foo.py"], {"foo.py": blob})
    assert not out, "Bypass env should allow"


def test_message_lists_each_offending_path_and_line():
    blob_a = "import subprocess\nsubprocess.run('a', shell=True)\nprint('ok')\nsubprocess.run('b', shell=True)\n"
    blob_b = "subprocess.call('ls', shell=True)\n"
    out = _run_handler(
        "git commit -m x",
        ["a.py", "b.py"],
        {"a.py": blob_a, "b.py": blob_b},
    )
    assert out
    data = json.loads(out[0])
    msg = data["hookSpecificOutput"]["userMessage"]
    # a.py has hits on lines 2 and 4
    assert "a.py:2" in msg
    assert "a.py:4" in msg
    # b.py has hit on line 1
    assert "b.py:1" in msg


# ---------------------------------------------------------------------------
# US-006: AST-based scan correctness
# ---------------------------------------------------------------------------

def test_ast_scan_ignores_string_literal_shell_true():
    """shell=True inside a string literal must NOT be flagged."""
    blob = 'example = "subprocess.run(cmd, shell=True)"\n'
    out = _run_handler("git commit -m x", ["foo.py"], {"foo.py": blob})
    assert not out, "String literal with shell=True should not be flagged"


def test_ast_scan_ignores_docstring_shell_true():
    """shell=True inside a module/function docstring must NOT be flagged."""
    blob = '"""Run with shell=True for convenience."""\nimport subprocess\n'
    out = _run_handler("git commit -m x", ["foo.py"], {"foo.py": blob})
    assert not out, "Docstring content should not be flagged"


def test_ast_scan_detects_shell_equals_true_with_spaces():
    """AST scan must catch shell = True (with surrounding spaces)."""
    blob = "import subprocess\nsubprocess.run(['ls'], shell = True)\n"
    out = _run_handler("git commit -m x", ["foo.py"], {"foo.py": blob})
    assert out, "shell = True with spaces should be detected"
    data = json.loads(out[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_ast_scan_skips_unparseable_python():
    """SyntaxError in a staged file must not block the commit (file is skipped)."""
    blob = "def broken(\n    # missing closing paren\n"
    out = _run_handler("git commit -m x", ["broken.py"], {"broken.py": blob})
    assert not out, "Unparseable Python should be skipped, not blocked"


# ---------------------------------------------------------------------------
# US-001: command-position anchoring (issue #82) — false-positive regressions
# ---------------------------------------------------------------------------

def test_grep_mention_of_git_commit_allows_silently():
    command = 'grep -rn "git commit" file.txt'
    with (
        patch("subprocess.run") as mock_run,
        patch("builtins.print") as mock_print,
    ):
        try:
            dispatcher.handle_shell_true(command, {"command": command})
        except SystemExit:
            pass
    mock_run.assert_not_called()
    mock_print.assert_not_called()


def test_echo_mention_of_git_commit_allows_silently():
    command = 'echo "remember to git commit later"'
    with (
        patch("subprocess.run") as mock_run,
        patch("builtins.print") as mock_print,
    ):
        try:
            dispatcher.handle_shell_true(command, {"command": command})
        except SystemExit:
            pass
    mock_run.assert_not_called()
    mock_print.assert_not_called()


def test_heredoc_body_mention_of_git_commit_allows_silently():
    command = "cat <<EOF\nremember to git commit\nEOF"
    with (
        patch("subprocess.run") as mock_run,
        patch("builtins.print") as mock_print,
    ):
        try:
            dispatcher.handle_shell_true(command, {"command": command})
        except SystemExit:
            pass
    mock_run.assert_not_called()
    mock_print.assert_not_called()


# ---------------------------------------------------------------------------
# US-001: command-position anchoring (issue #82) — true-positive regressions
# ---------------------------------------------------------------------------

def test_denies_cd_chained_commit_with_shell_true_staged():
    blob = "subprocess.run('ls', shell=True)\n"
    out = _run_handler("cd /repo && git commit -m x", ["foo.py"], {"foo.py": blob})
    assert out, "Expected deny output"
    data = json.loads(out[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_denies_semicolon_chained_commit_with_shell_true_staged():
    blob = "subprocess.run('ls', shell=True)\n"
    out = _run_handler("git status; git commit -m x", ["foo.py"], {"foo.py": blob})
    assert out, "Expected deny output"
    data = json.loads(out[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_denies_bare_git_C_commit_with_shell_true_staged():
    blob = "subprocess.run('ls', shell=True)\n"
    out = _run_handler("git -C /repo commit -m x", ["foo.py"], {"foo.py": blob})
    assert out, "Expected deny output"
    data = json.loads(out[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_denies_quoted_path_git_C_commit_with_shell_true_staged():
    blob = "subprocess.run('ls', shell=True)\n"
    out = _run_handler('git -C "/path with spaces" commit -m x', ["foo.py"], {"foo.py": blob})
    assert out, "Expected deny output"
    data = json.loads(out[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_denies_newline_separated_commit_with_shell_true_staged():
    blob = "subprocess.run('ls', shell=True)\n"
    out = _run_handler("cd /repo\ngit add -A\ngit commit -m x", ["foo.py"], {"foo.py": blob})
    assert out, "Expected deny output"
    data = json.loads(out[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_denies_leading_whitespace_commit_with_shell_true_staged():
    blob = "subprocess.run('ls', shell=True)\n"
    out = _run_handler("   git commit -m x", ["foo.py"], {"foo.py": blob})
    assert out, "Expected deny output"
    data = json.loads(out[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"
