"""Pins the Working Tree Guard of /aimi:plan Phase 3d and runs its block.

The guard is a bash block an orchestrator runs around every batch of story
expanders: `snapshot` before, `check` after. These tests extract that block
from the phase file and run it, under bash and zsh, against throwaway
repositories, so the block that ships is the block that is measured.
"""

import shutil
import subprocess
from pathlib import Path

import pytest

PLUGIN = Path(__file__).resolve().parents[2]
PLAN_DIR = PLUGIN / "commands" / "references" / "plan"
GUARD = PLAN_DIR / "phase-3d-tree-guard.md"
SHELLS = [s for s in ("bash", "zsh") if shutil.which(s)]


def flat(text):
    return " ".join(text.split())


def guard_block():
    text = GUARD.read_text(encoding="utf-8")
    return text.split("```bash\n", 1)[1].split("\n```", 1)[0]


def run_guard(shell, root, run_dir, mode):
    script = guard_block().replace('TREE_GUARD_MODE="[snapshot or check]"', f'TREE_GUARD_MODE="{mode}"')
    env = {"PATH": "/usr/bin:/bin", "HOME": str(root), "RUN_DIR": str(run_dir)}
    return subprocess.run([shell, "-c", script], cwd=root, env=env, capture_output=True, text=True)


def git(repo, *args):
    subprocess.run(
        ["git", "-c", "user.email=t@example.invalid", "-c", "user.name=t", *args],
        cwd=repo, check=True, capture_output=True,
    )


def make_repo(path):
    path.mkdir(parents=True, exist_ok=True)
    git(path, "init", "-q")
    (path / "a.txt").write_text("one\n")
    git(path, "add", "a.txt")
    git(path, "commit", "-q", "-m", "init")
    return path


@pytest.fixture
def layout(tmp_path):
    root = make_repo(tmp_path / "proj")
    run_dir = root / ".aimi" / ".tasks-staging" / "run"
    run_dir.mkdir(parents=True)
    return root, run_dir


# --- wiring -----------------------------------------------------------------

def test_router_reads_the_guard_file():
    plan = (PLUGIN / "commands" / "plan.md").read_text(encoding="utf-8")
    assert "### Working Tree Guard" in plan
    assert "commands/references/plan/phase-3d-tree-guard.md" in plan


def test_every_spawn_site_names_the_guard():
    assert "Working Tree Guard" in (PLAN_DIR / "phase-3d-prep-blocks.md").read_text(encoding="utf-8")
    assert "Working Tree Guard" in (PLAN_DIR / "phase-3d-validate-retry.md").read_text(encoding="utf-8")
    assert "Working Tree Guard" in (PLAN_DIR / "phase-3c-outline-gate.md").read_text(encoding="utf-8")


def test_failed_check_stops_the_plan_without_reverting():
    t = flat(GUARD.read_text(encoding="utf-8"))
    assert "A failed check stops the plan, in every mode." in t
    assert "Nothing is reverted automatically" in t


def test_expander_is_told_not_to_change_the_repository():
    t = flat((PLUGIN / "agents" / "workflow" / "aimi-story-expander.md").read_text(encoding="utf-8"))
    assert "You do NOT change the repository to check a story" in t
    assert "`stash`, `checkout`, `restore`, `reset`, `add`, `commit`, `apply`" in t


# --- behaviour --------------------------------------------------------------

@pytest.mark.parametrize("shell", SHELLS)
def test_unchanged_tree_passes(shell, layout):
    root, run_dir = layout
    assert run_guard(shell, root, run_dir, "snapshot").returncode == 0
    res = run_guard(shell, root, run_dir, "check")
    assert res.returncode == 0, res.stderr
    assert "unchanged" in res.stdout


@pytest.mark.parametrize("shell", SHELLS)
def test_edited_tracked_file_fails(shell, layout):
    root, run_dir = layout
    run_guard(shell, root, run_dir, "snapshot")
    (root / "a.txt").write_text("two\n")
    res = run_guard(shell, root, run_dir, "check")
    assert res.returncode == 1
    assert "a.txt" in res.stderr


@pytest.mark.parametrize("shell", SHELLS)
def test_new_untracked_file_fails(shell, layout):
    root, run_dir = layout
    run_guard(shell, root, run_dir, "snapshot")
    (root / "b.txt").write_text("x\n")
    assert run_guard(shell, root, run_dir, "check").returncode == 1


@pytest.mark.parametrize("shell", SHELLS)
def test_stash_push_that_restores_the_tree_still_fails(shell, layout):
    root, run_dir = layout
    (root / "a.txt").write_text("users work\n")
    run_guard(shell, root, run_dir, "snapshot")
    git(root, "stash", "push", "-q")
    git(root, "stash", "pop", "-q")
    git(root, "stash", "push", "-q")
    res = run_guard(shell, root, run_dir, "check")
    assert res.returncode == 1
    assert "stash" in res.stderr


@pytest.mark.parametrize("shell", SHELLS)
def test_writes_under_aimi_are_ignored(shell, layout):
    root, run_dir = layout
    run_guard(shell, root, run_dir, "snapshot")
    (run_dir / "01-story.json").write_text("{}\n")
    res = run_guard(shell, root, run_dir, "check")
    assert res.returncode == 0, res.stderr


@pytest.mark.parametrize("shell", SHELLS)
def test_multi_repo_layout_checks_each_child_repository(shell, tmp_path):
    root = tmp_path / "parent"
    (root / ".aimi").mkdir(parents=True)
    child = make_repo(root / "svc")
    run_dir = root / ".aimi" / "run"
    run_dir.mkdir()
    run_guard(shell, root, run_dir, "snapshot")
    (child / "a.txt").write_text("changed\n")
    res = run_guard(shell, root, run_dir, "check")
    assert res.returncode == 1
    assert "svc" in res.stderr


@pytest.mark.parametrize("shell", SHELLS)
def test_check_without_snapshot_fails(shell, layout):
    root, run_dir = layout
    res = run_guard(shell, root, run_dir, "check")
    assert res.returncode == 1
    assert "no snapshot" in res.stderr


@pytest.mark.parametrize("shell", SHELLS)
def test_unknown_mode_fails(shell, layout):
    root, run_dir = layout
    assert run_guard(shell, root, run_dir, "[snapshot or check]").returncode == 1
