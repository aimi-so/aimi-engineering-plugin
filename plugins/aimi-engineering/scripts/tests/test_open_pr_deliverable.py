"""Runs /aimi:open-pr's Step 2a and Step 4a blocks against a throwaway repository.

The blocks are extracted from commands/open-pr.md and run under bash and zsh with
the plugin's own aimi-cli.sh, so the text that ships is the text measured. The
pin is the phase PR: once a split plan's per-repository branches are gone, the
PR keeps its feature title, and a plan split across repositories renders no
Closes line.
"""

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

PLUGIN = Path(__file__).resolve().parents[2]
CLI = PLUGIN / "scripts" / "aimi-cli.sh"
OPEN_PR = PLUGIN / "commands" / "open-pr.md"
SHELLS = [s for s in ("bash", "zsh") if shutil.which(s)]
PHASE_BRANCH = "feat/feat-x-phase-1-core"


def blocks(start, end):
    text = OPEN_PR.read_text(encoding="utf-8")
    section = text.split(start, 1)[1].split(end, 1)[0]
    return [part.split("\n```", 1)[0] for part in section.split("```bash\n")[1:]]


def git(repo, *args):
    subprocess.run(
        ["git", "-c", "user.email=t@example.invalid", "-c", "user.name=t", *args],
        cwd=repo, check=True, capture_output=True,
    )


def story(sid):
    return {"id": sid, "title": "s", "status": "pending", "priority": 1, "dependsOn": [],
            "acceptanceCriteria": ["x"], "passes": False}


def write_plan(root, name, branch, title, issues, split=None, phase=True, mtime=None):
    meta = {"branchName": branch, "title": title, "type": "feat", "issues": issues,
            "roadmapPath": ".aimi/tasks/feat-x/roadmap.json"}
    if phase:
        meta["phase"] = {"id": 1, "dir": "phase-1-core"}
    if split:
        meta["splitGroup"] = split
    folder = root / ".aimi/tasks/feat-x/phase-1-core"
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / name
    path.write_text(json.dumps({"schemaVersion": "3.3", "metadata": meta, "userStories": [story("US-001")]}))
    if mtime:
        os.utime(path, (mtime, mtime))
    return path


@pytest.fixture
def repo(tmp_path):
    root = tmp_path / "proj"
    root.mkdir()
    git(root, "init", "-q", "-b", "main")
    (root / "a.txt").write_text("a\n")
    git(root, "add", "a.txt")
    git(root, "commit", "-q", "-m", "init")
    git(root, "branch", PHASE_BRANCH)
    roadmap = root / ".aimi/tasks/feat-x"
    roadmap.mkdir(parents=True)
    (roadmap / "roadmap.json").write_text(json.dumps(
        {"phases": [{"id": 1, "slug": "core", "dir": "phase-1-core", "status": "in_progress"}]}))
    cfg = tmp_path / "cfg"
    cfg.mkdir()
    (cfg / "cli-path").write_text(str(CLI) + "\n")
    return root


def env_for(root):
    cfg = root.parent / "cfg"
    return {"PATH": os.environ["PATH"], "HOME": str(root.parent), "AIMI_CONFIG_DIR": str(cfg),
            "CLAUDE_CONFIG_DIR": str(cfg), "XDG_CONFIG_HOME": str(cfg)}


def run(shell, root, script):
    return subprocess.run([shell, "-c", script], cwd=root, env=env_for(root), capture_output=True, text=True)


def step_2a(shell, root):
    parts = blocks("### 2a.", "### 2b.")
    script = "\n".join([parts[0], parts[2]]) + '\necho "CURRENT=$CURRENT_BRANCH"\n'
    return run(shell, root, script)


def step_4a(shell, root, current):
    block = blocks("### 4a.", "### 4b.")[0]
    script = (f'CURRENT_BRANCH="{current}"\nBASE_BRANCH=main\n'
              'AIMI_CLI=$(cat "$AIMI_CONFIG_DIR/cli-path")\n' + block +
              '\necho "TITLE=$PR_TITLE"\necho "ISSUES=$METADATA_ISSUES"\necho "COUNT=$BRANCH_PLAN_COUNT"\n')
    return run(shell, root, script)


def field(result, key):
    for line in result.stdout.splitlines():
        if line.startswith(key + "="):
            return line[len(key) + 1:]
    raise AssertionError(result.stdout + result.stderr)


def split_pair(root, mtime=None):
    for project, name in (("api", "feat-x-phase-1-api-tasks.json"), ("web", "feat-x-phase-1-web-tasks.json")):
        write_plan(root, name, f"feat/feat-x-phase-1-core-{project}", "Feature X", [7],
                   split={"project": project, "index": 1, "total": 2, "siblings": []}, mtime=mtime)


@pytest.mark.parametrize("shell", SHELLS)
def test_a_deleted_split_branch_still_adopts_the_live_phase_branch(repo, shell):
    split_pair(repo)
    result = step_2a(shell, repo)
    assert result.returncode == 0, result.stderr
    assert field(result, "CURRENT") == PHASE_BRANCH
    assert "no longer exists" not in result.stderr and "never executed" not in result.stderr


@pytest.mark.parametrize("shell", SHELLS)
def test_a_cross_repository_plan_keeps_its_title_and_renders_no_closes_line(repo, shell):
    split_pair(repo)
    result = step_4a(shell, repo, PHASE_BRANCH)
    assert result.returncode == 0, result.stderr
    assert field(result, "TITLE") == "Feature X"
    assert field(result, "ISSUES") == ""
    assert field(result, "COUNT") == "1"
    assert "split across 2 repositories" in result.stderr


@pytest.mark.parametrize("shell", SHELLS)
def test_a_side_axis_pair_keeps_its_closes_lines(repo, shell):
    for side in ("frontend", "backend"):
        write_plan(repo, f"feat-x-phase-1-{side}-tasks.json", f"feat/feat-x-phase-1-core-{side}",
                   "Feature X", [7])
    result = step_4a(shell, repo, PHASE_BRANCH)
    assert field(result, "TITLE") == "Feature X"
    assert field(result, "ISSUES") == "7"
    assert field(result, "COUNT") == "1"


@pytest.mark.parametrize("shell", SHELLS)
def test_a_one_repository_plan_keeps_its_closes_lines(repo, shell):
    write_plan(repo, "feat-x-phase-1-tasks.json", PHASE_BRANCH, "Feature X", [7], phase=True)
    result = step_4a(shell, repo, PHASE_BRANCH)
    assert field(result, "TITLE") == "Feature X"
    assert field(result, "ISSUES") == "7"


@pytest.mark.parametrize("shell", SHELLS)
def test_the_scan_supplies_the_plan_when_the_active_file_is_another_plans(repo, shell):
    split_pair(repo, mtime=1_000_000)
    other = write_plan(repo, "other-tasks.json", "feat/other", "Other plan", [9], phase=False, mtime=2_000_000)
    assert other.stat().st_mtime > (repo / ".aimi/tasks/feat-x/phase-1-core/feat-x-phase-1-api-tasks.json").stat().st_mtime
    result = step_4a(shell, repo, PHASE_BRANCH)
    assert field(result, "TITLE") == "Feature X"
    assert field(result, "COUNT") == "1"


@pytest.mark.parametrize("shell", SHELLS)
def test_two_plans_with_different_titles_on_one_branch_count_twice(repo, shell):
    split_pair(repo)
    write_plan(repo, "second-tasks.json", PHASE_BRANCH, "Second plan", [], phase=False)
    assert field(step_4a(shell, repo, PHASE_BRANCH), "COUNT") == "2"


@pytest.mark.parametrize("shell", SHELLS)
def test_a_candidate_branch_that_does_not_exist_still_goes_through_run_verdict(repo, shell):
    git(repo, "branch", "-D", PHASE_BRANCH)
    split_pair(repo)
    result = step_2a(shell, repo)
    assert result.returncode == 1
    assert "never executed" in result.stderr
