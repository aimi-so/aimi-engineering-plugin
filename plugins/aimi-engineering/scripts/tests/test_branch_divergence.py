"""branch-divergence: how a local branch stands against origin, read-only.

/aimi:plan records the working tree's HEAD as metadata.baseRef. This verb is
what lets it say, right after its own fetch, that the tree it is about to plan
against is behind origin. Every case builds a throwaway repository with a bare
origin beside it, and no case contacts a network.
"""

import json
import os
import subprocess

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
CLI = os.path.join(os.path.dirname(HERE), "aimi-cli.sh")


def _env(home):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_") and not k.startswith("AIMI_")}
    env.update(
        HOME=str(home), XDG_CONFIG_HOME=str(home / "xdg"),
        GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull,
        GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
        GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com",
    )
    return env


class Repo:
    def __init__(self, tmp_path):
        self.env = _env(tmp_path)
        self.origin = tmp_path / "origin.git"
        self.work = tmp_path / "work"
        self.other = tmp_path / "other"
        self.git(tmp_path, "init", "-q", "--bare", "-b", "main", str(self.origin))
        self.git(tmp_path, "clone", "-q", str(self.origin), str(self.work))
        self.git(self.work, "checkout", "-q", "-b", "main")
        (self.work / ".aimi").mkdir()
        self.commit(self.work, "base")
        self.git(self.work, "push", "-q", "-u", "origin", "main")
        self.git(tmp_path, "clone", "-q", str(self.origin), str(self.other))

    def git(self, cwd, *args):
        return subprocess.run(
            ["git", *args], cwd=str(cwd), env=self.env, capture_output=True, text=True, check=True
        ).stdout

    def commit(self, cwd, name):
        (cwd / (name + ".txt")).write_text(name, encoding="utf-8")
        self.git(cwd, "add", name + ".txt")
        self.git(cwd, "commit", "-q", "-m", name)

    def origin_moves(self, *names):
        """Someone else pushes to origin, and the working clone fetches it."""
        self.git(self.other, "pull", "-q", "--ff-only")
        for name in names:
            self.commit(self.other, name)
        self.git(self.other, "push", "-q")
        self.git(self.work, "fetch", "-q", "origin")

    def verb(self, *args):
        return subprocess.run(
            ["bash", CLI, "branch-divergence", *args],
            cwd=str(self.work), env=self.env, capture_output=True, text=True, timeout=60,
        )

    def answer(self, *args):
        proc = self.verb(*args)
        assert proc.returncode == 0, proc.stderr
        return json.loads(proc.stdout)


@pytest.fixture
def repo(tmp_path):
    return Repo(tmp_path)


def test_a_branch_level_with_origin_is_in_sync(repo):
    assert repo.answer() == {"branch": "main", "divergence": "in-sync", "ahead": 0, "behind": 0}


def test_a_branch_origin_moved_past_is_local_behind_with_the_count(repo):
    repo.origin_moves("one", "two", "three")
    assert repo.answer() == {"branch": "main", "divergence": "local-behind", "ahead": 0, "behind": 3}


def test_unpushed_commits_are_local_ahead(repo):
    repo.commit(repo.work, "mine")
    assert repo.answer() == {"branch": "main", "divergence": "local-ahead", "ahead": 1, "behind": 0}


def test_commits_on_both_sides_are_diverged_with_both_counts(repo):
    repo.origin_moves("theirs-1", "theirs-2")
    repo.commit(repo.work, "mine")
    assert repo.answer() == {"branch": "main", "divergence": "diverged", "ahead": 1, "behind": 2}


def test_it_reads_the_refs_the_last_fetch_left_and_never_fetches(repo):
    repo.git(repo.other, "pull", "-q", "--ff-only")
    repo.commit(repo.other, "unfetched")
    repo.git(repo.other, "push", "-q")
    assert repo.answer()["divergence"] == "in-sync"
    repo.git(repo.work, "fetch", "-q", "origin")
    assert repo.answer()["divergence"] == "local-behind"


def test_a_branch_origin_does_not_have_and_a_detached_head_answer_none(repo):
    repo.git(repo.work, "checkout", "-q", "-b", "feat/local-only")
    assert repo.answer() == {"branch": "feat/local-only", "divergence": "none", "ahead": 0, "behind": 0}
    repo.git(repo.work, "checkout", "-q", "--detach")
    assert repo.answer() == {"branch": "", "divergence": "none", "ahead": 0, "behind": 0}


def test_branch_names_another_branch_than_the_current_one(repo):
    repo.git(repo.work, "checkout", "-q", "-b", "feat/x")
    repo.origin_moves("one")
    assert repo.answer("--branch", "main") == {
        "branch": "main", "divergence": "local-behind", "ahead": 0, "behind": 1,
    }


def test_the_tree_and_the_refs_are_left_as_they_were(repo):
    repo.origin_moves("one")
    before = repo.git(repo.work, "for-each-ref") + repo.git(repo.work, "status", "--porcelain")
    repo.answer()
    assert repo.git(repo.work, "for-each-ref") + repo.git(repo.work, "status", "--porcelain") == before


@pytest.mark.parametrize("name", ['a"b', "a b", "a..b", "-x", "$(id)", ""])
def test_an_unsafe_branch_argument_is_refused(repo, name):
    proc = repo.verb("--branch", name)
    assert proc.returncode == 1
    assert "invalid branch name" in proc.stderr
    assert proc.stdout == ""


def test_an_unknown_argument_is_a_usage_error(repo):
    proc = repo.verb("--fetch")
    assert proc.returncode == 1
    assert "Usage: aimi-cli.sh branch-divergence" in proc.stderr
