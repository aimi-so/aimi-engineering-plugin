from __future__ import annotations

import importlib.util
import io
import json
import re
import subprocess
import sys
import time
from pathlib import Path
from unittest.mock import patch

import pytest

_HOOKS_DIR = Path(__file__).parent.parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

_CLI = _HOOKS_DIR.parent / "scripts" / "aimi-cli.sh"


def _load_dispatcher():
    spec = importlib.util.spec_from_file_location(
        "pre_bash_dispatcher_raw_forge", _HOOKS_DIR / "pre-bash-dispatcher.py"
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


dispatcher = _load_dispatcher()


def _git(cwd: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True)


def _make_repo(root: Path, origin: str | None, aimi: bool = True) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    _git(root, "init", "-q", "-b", "feat/x")
    if origin is not None:
        _git(root, "remote", "add", "origin", origin)
    if aimi:
        (root / ".aimi").mkdir()
    return root


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    for name in ("AIMI_FORGE_GUARD", "AIMI_FORGE_TYPE", "AIMI_DEFAULT_BRANCH_GUARD"):
        monkeypatch.delenv(name, raising=False)


@pytest.fixture
def gh_repo(tmp_path):
    return _make_repo(tmp_path / "gh", "https://github.com/acme/app.git")


@pytest.fixture
def gl_repo(tmp_path):
    return _make_repo(tmp_path / "gl", "git@gitlab.com:acme/app.git")


def _run(command: str, cwd: Path) -> list[str]:
    event = {"tool_input": {"command": command, "cwd": str(cwd)}}
    out: list[str] = []
    with (
        patch("sys.stdin", io.StringIO(json.dumps(event))),
        patch("builtins.print", side_effect=out.append),
    ):
        try:
            dispatcher.main()
        except SystemExit as exc:
            assert exc.code in (0, None)
    return out


def _denied(command: str, cwd: Path) -> dict:
    out = _run(command, cwd)
    assert out, f"expected a deny for: {command!r}"
    data = json.loads(out[0])
    assert data["hookSpecificOutput"]["permissionDecision"] == "deny"
    return data


def _passes(command: str, cwd: Path) -> None:
    assert _run(command, cwd) == [], f"expected silence for: {command!r}"


def _reason(data: dict) -> str:
    return data["hookSpecificOutput"]["userMessage"]


# --- denials ---------------------------------------------------------------

GH_DENIED = [
    ("gh pr create --title T --base main --head feat/x --body B", "forge-pr-create"),
    ("gh pr create -t T -B main -H feat/x -b B", "forge-pr-create"),
    ("gh pr edit 5 --title T", "forge-pr-edit"),
    ("gh pr edit 5 --body=text", "forge-pr-edit"),
    ("gh pr merge 5 -s", "forge-pr-merge"),
    ("gh pr merge 5 --squash", "forge-pr-merge"),
    ("gh issue create --title T --body B", "forge-issue-create"),
    ("gh release create v1.0 --title T --target main --notes-file n.md", "forge-release-create"),
    ("gh release create v1.0 --generate-notes -d -p", "forge-release-create"),
]

GL_DENIED = [
    ("glab mr create --title T --description D --source-branch a --target-branch main --yes", "forge-pr-create"),
    ("glab mr update 5 --title T -y", "forge-pr-edit"),
    ("glab mr merge 5 --squash --yes", "forge-pr-merge"),
    ("glab issue create --title T --description D", "forge-issue-create"),
    ("glab release create v1 --name N --ref main --notes-file n.md", "forge-release-create"),
]


@pytest.mark.parametrize("command,verb", GH_DENIED)
def test_denies_gh_write(gh_repo, command, verb):
    reason = _reason(_denied(command, gh_repo))
    assert f"`{verb}`" in reason
    assert str(_CLI) in reason
    assert "AIMI_FORGE_GUARD=off" in reason
    assert "before the session" in reason
    assert "for the user to run" in reason


@pytest.mark.parametrize("command,verb", GL_DENIED)
def test_denies_glab_write(gl_repo, command, verb):
    assert f"`{verb}`" in _reason(_denied(command, gl_repo))


def test_denies_inline_bypass_prefix(gh_repo):
    _denied("AIMI_FORGE_GUARD=off gh pr merge 5 -s", gh_repo)


def test_denies_ssh_and_scp_origins(tmp_path):
    for i, url in enumerate(
        ["ssh://git@github.com/acme/app.git", "git@github.com:acme/app.git",
         "https://user@gist.github.com/x.git"]
    ):
        repo = _make_repo(tmp_path / f"r{i}", url)
        _denied("gh pr merge 5 -s", repo)


def test_denies_in_subdirectory_of_aimi_project(gh_repo):
    sub = gh_repo / "pkg" / "inner"
    sub.mkdir(parents=True)
    _denied("gh pr merge 5 -s", sub)


def test_denies_real_write_after_mention_and_after_commit(gh_repo):
    _denied('echo "gh pr merge 5 -s"; gh pr merge 5 -s', gh_repo)
    _denied('git commit -m "x" && gh pr merge 5 -s', gh_repo)
    _denied("true\n\ngh pr merge 5 -s", gh_repo)


def test_denies_with_redirect_and_fd_digit(gh_repo):
    _denied("gh pr merge 5 -s 2>&1 | tail -3", gh_repo)
    _denied("gh pr merge 5 -s > out.txt", gh_repo)


def test_denies_env_override_matching_tool(tmp_path, monkeypatch):
    repo = _make_repo(tmp_path / "o", "https://example.com/x.git")
    monkeypatch.setenv("AIMI_FORGE_TYPE", "github")
    _denied("gh pr merge 5 -s", repo)


# --- silent passes ---------------------------------------------------------

def test_passes_without_aimi_dir(tmp_path):
    repo = _make_repo(tmp_path / "n", "https://github.com/a/b.git", aimi=False)
    _passes("gh pr merge 5 -s", repo)


def test_passes_absent_or_other_origin(tmp_path):
    _passes("gh pr merge 5 -s", _make_repo(tmp_path / "a", None))
    _passes("gh pr merge 5 -s", _make_repo(tmp_path / "b", "https://example.com/a/b.git"))
    _passes("gh pr merge 5 -s", _make_repo(tmp_path / "c", "https://notgithub.com/a/b.git"))


def test_passes_tool_not_matching_forge(gh_repo, gl_repo):
    _passes("glab mr merge 5 --squash", gh_repo)
    _passes("gh pr merge 5 -s", gl_repo)


def test_passes_forge_type_override_other_value(gh_repo, monkeypatch):
    monkeypatch.setenv("AIMI_FORGE_TYPE", "gitea")
    _passes("gh pr merge 5 -s", gh_repo)
    monkeypatch.setenv("AIMI_FORGE_TYPE", "gitlab")
    _passes("gh pr merge 5 -s", gh_repo)


def test_passes_guard_off_in_environment(gh_repo, monkeypatch):
    monkeypatch.setenv("AIMI_FORGE_GUARD", "off")
    _passes("gh pr merge 5 -s", gh_repo)


def test_passes_when_git_fails_or_times_out(gh_repo):
    with patch.object(dispatcher.subprocess, "run", side_effect=subprocess.TimeoutExpired("git", 5)):
        _passes("gh pr merge 5 -s", gh_repo)
    with patch.object(dispatcher.subprocess, "run", side_effect=OSError("boom")):
        _passes("gh pr merge 5 -s", gh_repo)


def test_passes_on_internal_error(gh_repo):
    with patch.object(dispatcher, "_resolve_forge", side_effect=RuntimeError("x")):
        _passes("gh pr merge 5 -s", gh_repo)


# --- only what a verb can express -----------------------------------------

@pytest.mark.parametrize(
    "command",
    [
        "gh pr create --title T --base main --head h --draft",
        "gh pr create --fill",
        "gh pr merge 5 --squash --delete-branch",
        "gh pr merge 5 -s -d",
        "gh issue create --title T --body B --label bug",
        "gh release create v1 --notes 'text'",
        "gh release create v1 extra-asset.zip",
        "gh pr merge 5 -- -s",
        "gh pr merge 5 -s 'unterminated",
        "gh pr edit 5 -tTitle",
        "gh pr edit 5 6 --title T",
        "gh pr merge 5 --squash=1",
        "gh pr edit 5 --title",
        "glab mr create --draft --title T",
        "glab release create v1 --name N --milestone m",
    ],
)
def test_passes_what_a_verb_cannot_express(gh_repo, gl_repo, command):
    repo = gl_repo if command.startswith("glab") else gh_repo
    _passes(command, repo)


@pytest.mark.parametrize(
    "command",
    [
        "gh pr view 5", "gh pr list", "gh issue view 5", "gh release list",
        "gh issue edit 5 --title T", "gh api repos/a/b/pulls",
        "curl -X POST https://api.github.com/x",
        "gh pr checks 5", "gh pr close 5",
    ],
)
def test_passes_reads_and_unlisted(gh_repo, command):
    _passes(command, gh_repo)


def test_passes_glab_reads(gl_repo):
    _passes("glab mr view 5", gl_repo)
    _passes("glab issue view 5", gl_repo)


def test_flag_alias_and_equals_read_as_verb_flag(gh_repo):
    _denied("gh pr create --title=T --base=main --head=h", gh_repo)
    _denied("gh pr create -t T -B main -H h -b B", gh_repo)


# --- a mention is not a command -------------------------------------------

def test_passes_mentions(gh_repo):
    _passes('echo "gh pr merge 5 -s"', gh_repo)
    _passes("echo gh pr merge 5 -s", gh_repo)
    _passes('grep -r "gh pr merge 5 -s" docs', gh_repo)
    _passes('git commit -m "docs: run gh pr merge 5 -s later"', gh_repo)
    _passes('git commit -m "first line\ngh pr merge 5 --squash\nlast"', gh_repo)
    _passes("cat <<'EOF'\ngh pr merge 5 -s\nEOF", gh_repo)


def test_passes_aimi_cli_and_plugin_scripts(gh_repo):
    _passes("aimi-cli.sh forge-pr-merge --pr 5 --style squash", gh_repo)
    _passes(f"{_CLI} forge-pr-merge --pr 5 --style squash", gh_repo)
    _passes("bash plugins/aimi-engineering/scripts/test-aimi-cli.sh", gh_repo)


# --- prefilter and linear time --------------------------------------------

def test_prefilter_no_subprocess_for_unrelated_command(gh_repo):
    with patch.object(dispatcher.subprocess, "run", side_effect=AssertionError("spawned")):
        assert _run("ls -la && echo hi", gh_repo) == []


def test_gh_without_git_skips_git_regexes(gh_repo):
    class Boom:
        def search(self, *_a, **_k):
            raise AssertionError("git regex used")

    with (
        patch.object(dispatcher, "_GIT_COMMIT_RE", Boom()),
        patch.object(dispatcher, "_GIT_C_COMMIT_RE", Boom()),
        patch.object(dispatcher, "_GIT_WORKTREE_ADD_RE", Boom()),
        patch.object(dispatcher, "_GIT_C_WORKTREE_ADD_RE", Boom()),
    ):
        _denied("gh pr merge 5 -s", gh_repo)
        assert _run("gh pr view 5", gh_repo) == []


def test_git_branches_unchanged(gh_repo):
    _git(gh_repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "i")
    _git(gh_repo, "checkout", "-q", "-b", "main")
    out = _run("git commit -m x", gh_repo)
    assert out and "protected branch" in json.loads(out[0])["hookSpecificOutput"]["userMessage"]


@pytest.mark.parametrize(
    "command",
    [
        "\n" * 20000 + "gh pr view 5",
        "A=1 " * 5000 + "gh pr view 5",
        "sudo " * 5000 + "gh pr view 5",
        " " * 40000 + "gh pr create x",
    ],
)
def test_forge_regex_is_linear(command):
    start = time.monotonic()
    list(dispatcher._RAW_FORGE_RE.finditer(command))
    assert time.monotonic() - start < 1.0


# --- drift against the verbs ----------------------------------------------

_VERB_FUNCS = {
    ("gh", "pr", "create"): "cmd_forge_pr_create",
    ("gh", "pr", "edit"): "cmd_forge_pr_edit",
    ("gh", "pr", "merge"): "cmd_forge_pr_merge",
    ("gh", "issue", "create"): "cmd_forge_issue_create",
    ("gh", "release", "create"): "cmd_forge_release_create",
}


def _verb_flags(func: str) -> set[str]:
    text = _CLI.read_text()
    m = re.search(rf"^{func}\(\) \{{\n(.*?)^\}}\n", text, re.S | re.M)
    assert m, f"{func} not found in aimi-cli.sh"
    labels = re.findall(r"^\s*(--[a-z][a-z-]*)\)", m.group(1), re.M)
    return {label[2:] for label in labels} - {"project"}


def _roles(entry: dict) -> set[str]:
    roles = {role for role, _v in entry["flags"].values()}
    roles.update(entry["positionals"])
    roles.discard("-")
    return roles


@pytest.mark.parametrize("key,func", list(_VERB_FUNCS.items()))
def test_github_table_covers_every_verb_flag(key, func):
    verb_flags = _verb_flags(func)
    assert verb_flags, "no flags read from the verb"
    missing = verb_flags - _roles(dispatcher._RAW_FORGE_VERBS[key])
    assert not missing, f"{func} accepts {missing} that the GitHub table does not map"


@pytest.mark.parametrize("key,func", list(_VERB_FUNCS.items()))
def test_gitlab_table_maps_no_flag_the_verb_lacks(key, func):
    gl_key = ("glab", {"pr": "mr", "issue": "issue", "release": "release"}[key[1]],
              "update" if key[2] == "edit" else key[2])
    entry = dispatcher._RAW_FORGE_VERBS[gl_key]
    assert entry["verb"] == dispatcher._RAW_FORGE_VERBS[key]["verb"]
    extra = _roles(entry) - _verb_flags(func)
    assert not extra, f"GitLab table maps {extra} that {func} lacks"
