"""Tests for scripts/deps_recipe.py, the module behind `aimi-cli.sh deps-recipe-record`.

The document rules are driven through `main`; the lock race and the round trip
with the dependency detector go through the CLI as a subprocess. Every fixture
is a tempfile root outside the repository.
"""

import json
import os
import shlex
import subprocess
import sys
import tempfile

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
sys.path.insert(0, SCRIPTS)

import deps_recipe as D  # noqa: E402

CLI = os.path.join(SCRIPTS, "aimi-cli.sh")
WORKTREE_MANAGER = os.path.join(
    os.path.dirname(SCRIPTS), "skills", "git-worktree", "scripts", "worktree-manager.sh"
)


@pytest.fixture
def root():
    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, ".aimi"))
        yield tmp


def cfg_path(root):
    return os.path.join(root, ".aimi", "config.json")


def record(root, project, command):
    return D.main(["deps_recipe.py", "record", "--config", cfg_path(root),
                   "--project", project, "--command", command])


def load(root):
    with open(cfg_path(root)) as fh:
        return json.load(fh)


def test_records_and_trims(root, capsys):
    assert record(root, ".", "  make setup  ") == 0
    report = json.loads(capsys.readouterr().out)
    assert report["status"] == "recorded" and report["command"] == "make setup"
    assert load(root) == {"dependencies": {"install": {".": "make setup"}}}


def test_same_command_is_unchanged_and_untouched(root, capsys):
    record(root, ".", "make setup")
    capsys.readouterr()
    before = os.stat(cfg_path(root)).st_mtime_ns
    assert record(root, ".", "make setup") == 0
    assert json.loads(capsys.readouterr().out)["status"] == "unchanged"
    assert os.stat(cfg_path(root)).st_mtime_ns == before


def test_other_keys_and_order_survive(root):
    with open(cfg_path(root), "w") as fh:
        json.dump({"z": 1, "dependencies": {"install": {"b": "y"}, "k": 2}, "a": 3}, fh)
    assert record(root, "api", "just deps") == 0
    doc = load(root)
    assert list(doc) == ["z", "dependencies", "a"]
    assert doc["dependencies"]["install"] == {"b": "y", "api": "just deps"}
    assert doc["dependencies"]["k"] == 2


def test_no_temp_file_left_behind(root):
    record(root, ".", "make")
    assert sorted(os.listdir(os.path.join(root, ".aimi"))) == ["config.json"]


@pytest.mark.parametrize("command", [
    "", "   ", "a;b", "a|b", "a&b", "a$b", "a<b", "a>b", "a`b`", "a\nb", "a\tb", "x" * 513,
])
def test_unsafe_command_refused_and_config_absent(root, command, capsys):
    assert record(root, ".", command) == 1
    assert "Error: deps-recipe-record:" in capsys.readouterr().err
    assert not os.path.exists(cfg_path(root))


@pytest.mark.parametrize("key", ["", "  ", "/abs", "../x", "a/../b", "a\\b", "a\x01b"])
def test_bad_key_refused(root, key, capsys):
    assert record(root, key, "make") == 1
    assert not os.path.exists(cfg_path(root))


@pytest.mark.parametrize("text", [
    "not json", "[1]", '{"dependencies": 3}', '{"dependencies": {"install": []}}',
])
def test_bad_config_refused_byte_identical(root, text):
    with open(cfg_path(root), "w") as fh:
        fh.write(text)
    assert record(root, ".", "make") == 1
    with open(cfg_path(root)) as fh:
        assert fh.read() == text


def test_tracked_config_refused(root, capsys):
    subprocess.run(["git", "init", "-q", root], check=True)
    with open(cfg_path(root), "w") as fh:
        fh.write("{}\n")
    subprocess.run(["git", "-C", root, "add", "-f", ".aimi/config.json"], check=True)
    assert record(root, ".", "make") == 1
    assert "tracked by git" in capsys.readouterr().err
    assert load(root) == {}


def test_untracked_config_in_git_repo_is_trusted(root):
    subprocess.run(["git", "init", "-q", root], check=True)
    assert record(root, ".", "make") == 0


def test_lock_race_all_keys_survive(root):
    keys = ["k%d" % i for i in range(8)]
    procs = []
    for k in keys:
        procs.append(subprocess.Popen(
            [CLI, "deps-recipe-record", "--project", k, "--command", "run " + k],
            cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    assert [p.wait() for p in procs] == [0] * len(keys)
    assert load(root)["dependencies"]["install"] == {k: "run " + k for k in keys}
    assert [n for n in os.listdir(os.path.join(root, ".aimi")) if n.endswith(".tmp")] == []


@pytest.mark.parametrize("key", [".", "services/api"])
def test_detector_round_trip(root, key):
    r = subprocess.run([CLI, "deps-recipe-record", "--project", key, "--command", "make setup"],
                       cwd=root, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    proj = os.path.join(root, "proj")
    os.makedirs(proj)
    script = "source %s; cd %s; _detect_dependency_installer %s %s" % (
        shlex.quote(WORKTREE_MANAGER), shlex.quote(root), shlex.quote(proj), shlex.quote(key))
    d = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    out = json.loads(d.stdout.strip().splitlines()[-1])
    assert out["status"] == "ready" and out["source"] == "config" and out["command"] == "make setup"


def test_usage_exit_two():
    assert D.main(["deps_recipe.py"]) == 2
