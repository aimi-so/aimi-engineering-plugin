"""Proof that the integrated wave check catches what a clean merge hides.

Two story branches are cut from one base commit and touch different files, so
they merge without a textual conflict. Story 1 raises a limit to 20; story 2
adds a check that the limit is below 15. Each passes its own verify on its own
branch, and the merged tree fails story 2's. `wave-verify-commands` lists the
union of the verify commands, and the tests run that union in the merged tree.

Everything runs inside pytest's tmp_path, with the environment scrubbed of the
variables that could point the CLI or git at the operator's own state. The CLI
is the `aimi-cli.sh` of the tree this file ships in, never the cli-path cache.
"""

import json
import os
import subprocess
from pathlib import Path

CLI = Path(__file__).resolve().parents[1] / "aimi-cli.sh"

VERIFY_1 = "sh check_limit.sh"
VERIFY_2 = "sh check_ceiling.sh"
STORIES = {"US-001": VERIFY_1, "US-002": VERIFY_2}
BRANCHES = {"US-001": "story-1", "US-002": "story-2"}

SCRUBBED = ("AIMI_ROOT", "AIMI_DEV_DIR", "AIMI_CLI_PINNED", "TASKS_FILE_PATH", "GIT_DIR", "GIT_WORK_TREE")


def make_env(tmp_path):
    env = {k: v for k, v in os.environ.items() if k not in SCRUBBED and not k.startswith("GIT_")}
    env.update(
        {
            "HOME": str(tmp_path / "home"),
            "XDG_CONFIG_HOME": str(tmp_path / "xdg"),
            "AIMI_CONFIG_DIR": str(tmp_path / "cfg"),
            "CLAUDE_CONFIG_DIR": str(tmp_path / "claude"),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_SYSTEM": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Fixture",
            "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Fixture",
            "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
        }
    )
    return env


def run(tmp_path, cwd, args, env, check=True):
    """Run a command with a cwd that must sit inside the test's own tmp_path."""
    cwd = Path(cwd).resolve()
    root = Path(tmp_path).resolve()
    assert cwd == root or root in cwd.parents, f"cwd {cwd} is outside {root}"
    res = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True)
    if check:
        assert res.returncode == 0, f"{args}: {res.stdout}{res.stderr}"
    return res


def git(tmp_path, repo, env, *args, check=True):
    return run(tmp_path, repo, ["git", "-c", "commit.gpgsign=false", *args], env, check=check)


def write(repo, name, text):
    (repo / name).write_text(text, encoding="utf-8")


def build_fixture(tmp_path):
    """A project with `.aimi/tasks/` and a repository, plus the two story branches."""
    env = make_env(tmp_path)
    repo = tmp_path / "proj"
    (repo / ".aimi" / "tasks").mkdir(parents=True)
    git(tmp_path, repo, env, "init", "-q", "-b", "main")
    write(repo, "limit.txt", "10\n")
    write(repo, ".gitignore", ".aimi/\n")
    git(tmp_path, repo, env, "add", "limit.txt", ".gitignore")
    git(tmp_path, repo, env, "commit", "-q", "-m", "base")

    git(tmp_path, repo, env, "checkout", "-q", "-b", BRANCHES["US-001"], "main")
    write(repo, "limit.txt", "20\n")
    write(repo, "check_limit.sh", '[ "$(cat limit.txt)" -eq 20 ]\n')
    git(tmp_path, repo, env, "add", "limit.txt", "check_limit.sh")
    git(tmp_path, repo, env, "commit", "-q", "-m", "story 1: raise the limit")

    git(tmp_path, repo, env, "checkout", "-q", "-b", BRANCHES["US-002"], "main")
    write(repo, "check_ceiling.sh", '[ "$(cat limit.txt)" -lt 15 ]\n')
    git(tmp_path, repo, env, "add", "check_ceiling.sh")
    git(tmp_path, repo, env, "commit", "-q", "-m", "story 2: add the ceiling check")

    git(tmp_path, repo, env, "checkout", "-q", "main")
    doc = {
        "schemaVersion": "3.3",
        "metadata": {"title": "t", "type": "feature", "branchName": "feat/t"},
        "userStories": [{"id": sid, "implementation": {"verify": cmd}} for sid, cmd in STORIES.items()],
    }
    tasks = repo / ".aimi" / "tasks" / "2026-01-01-t-tasks.json"
    tasks.write_text(json.dumps(doc), encoding="utf-8")
    return env, repo, tasks


def merge_wave(tmp_path, repo, env, ids):
    """A fresh integration branch off main with the given stories merged --no-ff."""
    git(tmp_path, repo, env, "checkout", "-q", "-B", "integration-" + "-".join(ids), "main")
    for sid in ids:
        res = git(tmp_path, repo, env, "merge", "--no-ff", "-q", "-m", f"merge {sid}", BRANCHES[sid], check=False)
        assert res.returncode == 0, f"merge of {sid} was not clean: {res.stdout}{res.stderr}"
        unmerged = git(tmp_path, repo, env, "diff", "--name-only", "--diff-filter=U", check=False).stdout.strip()
        assert unmerged == "", f"conflicted paths: {unmerged}"


def run_union(tmp_path, repo, env, tasks, ids):
    """Ask the verb for the union over ids, run each entry's command, return entries with exit codes."""
    res = run(tmp_path, repo, ["bash", str(CLI), "wave-verify-commands", *ids, "--tasks-file", str(tasks)], env)
    entries = json.loads(res.stdout)
    out = []
    for entry in entries:
        workdir = repo / entry["project"]
        ran = run(tmp_path, workdir, ["bash", "-c", entry["command"]], env, check=False)
        out.append({**entry, "exit": ran.returncode})
    return out


def test_clean_merge_of_two_stories_fails_only_the_union_command_of_the_second(tmp_path):
    env, repo, tasks = build_fixture(tmp_path)
    merge_wave(tmp_path, repo, env, ["US-001", "US-002"])
    assert (repo / "limit.txt").read_text(encoding="utf-8").strip() == "20"

    entries = run_union(tmp_path, repo, env, tasks, ["US-001", "US-002"])
    assert len(entries) == 2
    by_command = {e["command"]: e for e in entries}
    assert by_command[VERIFY_1]["exit"] == 0
    assert by_command[VERIFY_1]["stories"] == ["US-001"]
    assert by_command[VERIFY_2]["exit"] != 0
    assert by_command[VERIFY_2]["stories"] == ["US-002"]
    assert [e["command"] for e in entries if e["exit"] != 0] == [VERIFY_2]


def test_the_union_passes_with_either_story_merged_alone(tmp_path):
    env, repo, tasks = build_fixture(tmp_path)
    for sid in ("US-001", "US-002"):
        merge_wave(tmp_path, repo, env, [sid])
        entries = run_union(tmp_path, repo, env, tasks, [sid])
        assert len(entries) == 1
        assert entries[0]["stories"] == [sid]
        assert entries[0]["command"] == STORIES[sid]
        assert entries[0]["exit"] == 0, f"{sid} fails on its own"


def test_each_story_passes_its_own_verify_on_its_own_branch(tmp_path):
    env, repo, tasks = build_fixture(tmp_path)
    for sid, branch in BRANCHES.items():
        git(tmp_path, repo, env, "checkout", "-q", branch)
        ran = run(tmp_path, repo, ["bash", "-c", STORIES[sid]], env, check=False)
        assert ran.returncode == 0, f"{sid} fails before any merge: {ran.stdout}{ran.stderr}"
    git(tmp_path, repo, env, "checkout", "-q", "main")


def test_the_helpers_refuse_a_cwd_outside_the_temporary_directory(tmp_path):
    env = make_env(tmp_path)
    outside = tmp_path.parent
    try:
        run(tmp_path, outside, ["true"], env)
    except AssertionError as exc:
        assert "outside" in str(exc)
    else:
        raise AssertionError("a cwd outside tmp_path was accepted")
    for name in SCRUBBED:
        assert name not in env
    assert env["GIT_CONFIG_GLOBAL"] == os.devnull
