from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

HOOKS_DIR = Path(__file__).parent.parent
sys.path.insert(0, str(HOOKS_DIR))


def _load_guard():
    spec = importlib.util.spec_from_file_location(
        "guard_shell_true",
        HOOKS_DIR / "guard-shell-true.py",
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


guard = _load_guard()


def _run_main(command: str, staged_files: list[str], blobs: dict[str, str], extra_env: dict | None = None):
    """
    staged_files: list of paths returned by git diff --cached
    blobs: mapping path -> content returned by git show :<path>
    """
    tool_input = json.dumps({"command": command})
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
        patch("sys.stdin", __import__("io").StringIO(tool_input)),
        patch("subprocess.run", side_effect=fake_run),
        patch.dict("os.environ", env_patch, clear=False),
        patch("builtins.print", side_effect=captured.append),
    ):
        try:
            guard.main()
        except SystemExit:
            pass

    return captured


def test_blocks_when_staged_py_contains_shell_true():
    blob = "import subprocess\nsubprocess.run('ls', shell=True)\n"
    out = _run_main("git commit -m x", ["foo.py"], {"foo.py": blob})
    assert out
    data = json.loads(out[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert "foo.py" in data["hookSpecificOutput"]["userMessage"]


def test_allows_when_inside_comment():
    blob = "# subprocess.run('ls', shell=True)\n"
    out = _run_main("git commit -m x", ["foo.py"], {"foo.py": blob})
    assert not out, "Comment line should be skipped"


def test_allows_when_inside_docstring():
    blob = '"""\nsubprocess.run(cmd, shell=True)\n"""\n'
    out = _run_main("git commit -m x", ["foo.py"], {"foo.py": blob})
    assert not out, "Docstring content should be skipped"


def test_allows_when_no_python_staged():
    out = _run_main("git commit -m x", [], {})
    assert not out


def test_skips_non_commit_subcommands():
    for cmd in ["git status", "git log --oneline", "git diff HEAD"]:
        out = _run_main(cmd, ["foo.py"], {"foo.py": "shell=True\n"})
        assert not out, f"Non-commit command '{cmd}' should be skipped"


def test_bypass_env_allows(monkeypatch):
    monkeypatch.setenv("AIMI_SHELL_TRUE_GUARD", "off")
    blob = "subprocess.run('ls', shell=True)\n"
    out = _run_main("git commit -m x", ["foo.py"], {"foo.py": blob})
    assert not out, "Bypass env should allow"


def test_message_lists_each_offending_path_and_line():
    blob_a = "import subprocess\nsubprocess.run('a', shell=True)\nprint('ok')\nsubprocess.run('b', shell=True)\n"
    blob_b = "subprocess.call('ls', shell=True)\n"
    out = _run_main(
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
