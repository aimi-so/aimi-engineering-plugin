"""Pins the sanctioned pre-change baseline in the story-executor skill.

An executor that has already edited its worktree cannot measure the pre-run
or the verify-probe on the edited tree, and a copy outside the repository has
no `.aimi/` ancestor, so the CLI stops before it measures anything. The skill
names the one route that works: a detached worktree of HEAD inside the
repository, removed before anything is staged.
"""

import os
import subprocess
from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[2]
SKILL = PLUGIN / "skills" / "story-executor" / "SKILL.md"
RECIPE = 'git worktree add --detach "$PWD/.aimi-probe-base" HEAD'


def test_full_and_compact_templates_carry_the_recipe():
    text = SKILL.read_text(encoding="utf-8")
    full, compact = text.split("## Compact Template", 1)
    assert RECIPE in full
    assert RECIPE in compact
    assert 'git worktree remove --force "$PWD/.aimi-probe-base"' in full


def test_full_template_says_why_an_outside_copy_fails():
    flat = " ".join(SKILL.read_text(encoding="utf-8").split())
    assert "a copy under `/tmp` has no `.aimi/` ancestor" in flat
    assert "before you write a single file" in flat


def test_the_recipe_leaves_the_cli_able_to_find_aimi(tmp_path):
    root = tmp_path / "proj"
    (root / ".aimi" / "tasks").mkdir(parents=True)
    git = ["git", "-c", "user.email=t@example.invalid", "-c", "user.name=t"]
    subprocess.run(git + ["init", "-q"], cwd=root, check=True)
    (root / "a.txt").write_text("one\n")
    subprocess.run(git + ["add", "a.txt"], cwd=root, check=True)
    subprocess.run(git + ["commit", "-q", "-m", "init"], cwd=root, check=True)
    story = root / ".worktrees" / "story"
    subprocess.run(git + ["worktree", "add", "-q", "-b", "s", str(story)], cwd=root, check=True)
    (story / "a.txt").write_text("edited\n")
    subprocess.run(["bash", "-c", RECIPE], cwd=story, check=True)
    base = story / ".aimi-probe-base"
    assert (base / "a.txt").read_text() == "one\n"
    env = {**os.environ, "HOME": str(tmp_path)}
    res = subprocess.run(["bash", str(PLUGIN / "scripts" / "aimi-cli.sh"), "find-tasks-all"],
                         cwd=base, env=env, capture_output=True, text=True)
    assert ".aimi/ directory not found" not in res.stderr
    subprocess.run(["bash", "-c", 'git worktree remove --force "$PWD/.aimi-probe-base"'], cwd=story, check=True)
    assert not base.exists()
