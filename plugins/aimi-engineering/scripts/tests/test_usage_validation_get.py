"""Tests for `usage-validation-get`, the one reader of a run's stored
usage-validation record.

It is run through the tree's own aimi-cli.sh against throwaway `.aimi/` roots,
so the flag handling, the path confinement and the crossing into tasks.py are
all measured together.
"""

import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[1]
CLI = SCRIPTS / "aimi-cli.sh"

FAILING = {"status": "failing", "reason": "open bug", "rounds": 1}
PASSED = {"status": "passed", "rounds": 0}


def _cli(root, *args, env=None):
    return subprocess.run(["bash", str(CLI), *args], cwd=root, capture_output=True, text=True,
                          timeout=60, env=env or dict(os.environ))


def _write(path, doc):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc) if not isinstance(doc, str) else doc, encoding="utf-8")
    return path


@pytest.fixture
def root(tmp_path):
    (tmp_path / ".aimi" / "tasks").mkdir(parents=True)
    return tmp_path


def _roadmap(root, record=None, feature="feat-x"):
    phase = {"id": 1, "name": "Core", "slug": "core", "dir": "phase-1-core", "status": "in_progress"}
    if record is not None:
        phase["usageValidation"] = record
    return _write(root / ".aimi" / "tasks" / feature / "roadmap.json", {"feature": feature, "phases": [phase]})


def _phase_file(root, roadmap_path=True, phase_id=1, feature="feat-x"):
    meta = {"branchName": "b", "phase": {"id": phase_id, "dir": "phase-1-core"}}
    if roadmap_path:
        meta["roadmapPath"] = ".aimi/tasks/%s/roadmap.json" % feature
    return _write(root / ".aimi" / "tasks" / feature / "phase-1-core" / ("%s-phase-1-tasks.json" % feature),
                  {"schemaVersion": "3.3", "metadata": meta, "userStories": []})


def _flat_file(root, record=None):
    meta = {"branchName": "b"}
    if record is not None:
        meta["usageValidation"] = record
    return _write(root / ".aimi" / "tasks" / "2026-01-01-x-tasks.json",
                  {"schemaVersion": "3.3", "metadata": meta, "userStories": []})


def _ok(proc):
    assert proc.returncode == 0, proc.stderr
    return json.loads(proc.stdout)


def test_a_flat_file_answers_its_own_record(root):
    path = _flat_file(root, PASSED)
    assert _ok(_cli(root, "usage-validation-get", "--tasks-file", str(path))) == {
        "scope": "flat", "feature": None, "phase": None, "record": PASSED}


@pytest.mark.parametrize("stored", [None, "not an object"])
def test_a_flat_file_with_no_record_answers_null(root, stored):
    path = _flat_file(root, stored)
    assert _ok(_cli(root, "usage-validation-get", "--tasks-file", str(path)))["record"] is None


@pytest.mark.parametrize("with_roadmap_path", [True, False])
def test_a_phase_file_is_followed_to_its_roadmap_phase(root, with_roadmap_path):
    _roadmap(root, FAILING)
    path = _phase_file(root, roadmap_path=with_roadmap_path)
    assert _ok(_cli(root, "usage-validation-get", "--tasks-file", str(path))) == {
        "scope": "phase", "feature": "feat-x", "phase": 1, "record": FAILING}


def test_the_feature_and_phase_form_answers_the_same(root):
    _roadmap(root, FAILING)
    assert _ok(_cli(root, "usage-validation-get", "--feature", "feat-x", "--phase", "1")) == {
        "scope": "phase", "feature": "feat-x", "phase": 1, "record": FAILING}


def test_a_phase_never_validated_answers_null(root):
    _roadmap(root, None)
    path = _phase_file(root)
    assert _ok(_cli(root, "usage-validation-get", "--tasks-file", str(path)))["record"] is None


def test_without_a_tasks_file_the_session_file_is_read(root):
    path = _flat_file(root, PASSED)
    assert _cli(root, "init-session", "--file", str(path)).returncode == 0
    assert _ok(_cli(root, "usage-validation-get"))["record"] == PASSED


@pytest.mark.parametrize("args,needle", [
    (["--phase", "1"], "--feature and --phase must be given together"),
    (["--feature", "feat-x", "--phase", "1", "--tasks-file", "x.json"], "cannot be combined"),
    (["--bogus"], "unknown flag: --bogus"),
    (["--feature", "feat-x", "--phase", "9"], "phase 9 not found in"),
])
def test_bad_invocations_and_a_missing_phase_exit_non_zero(root, args, needle):
    _roadmap(root, FAILING)
    proc = _cli(root, "usage-validation-get", *args)
    assert proc.returncode != 0 and proc.stdout == ""
    assert needle in proc.stderr


def test_a_phase_file_whose_roadmap_is_gone_exits_non_zero(root):
    path = _phase_file(root)
    proc = _cli(root, "usage-validation-get", "--tasks-file", str(path))
    assert proc.returncode == 1 and "cannot read roadmap.json" in proc.stderr


def test_a_roadmap_path_outside_the_project_is_refused(root):
    meta = {"branchName": "b", "phase": {"id": 1}, "roadmapPath": "../roadmap.json"}
    path = _write(root / ".aimi" / "tasks" / "f" / "p" / "t.json", {"metadata": meta, "userStories": []})
    proc = _cli(root, "usage-validation-get", "--tasks-file", str(path))
    assert proc.returncode == 1 and "escapes the project" in proc.stderr


def test_a_tasks_file_outside_the_project_is_refused_before_python(root, tmp_path_factory):
    outside = _flat_file(tmp_path_factory.mktemp("out"), PASSED)
    proc = _cli(root, "usage-validation-get", "--tasks-file", str(outside))
    assert proc.returncode == 1 and "escapes project root" in proc.stderr


def test_it_refuses_without_python3(root, tmp_path):
    """A reader of a gate's verdict has no honest degrade: answering `null`
    would read a stored failing as none recorded."""
    path = _flat_file(root, FAILING)
    bindir = tmp_path / "bin"
    bindir.mkdir()
    for tool in ("bash", "git", "jq", "cat", "dirname", "basename", "realpath", "readlink", "pwd", "mkdir",
                 "sed", "awk", "grep", "tr", "head", "tail", "date", "uname", "cut", "printf", "env", "ls"):
        found = shutil.which(tool)
        if found:
            os.symlink(found, bindir / tool)
    proc = _cli(root, "usage-validation-get", "--tasks-file", str(path),
                env=dict(os.environ, PATH=str(bindir)))
    assert proc.returncode != 0 and proc.stdout == ""
    assert "python3" in proc.stderr


def test_it_is_a_reader_with_one_crossing_and_no_lock():
    text = CLI.read_text(encoding="utf-8")
    body = re.search(r"^cmd_usage_validation_get\(\) \{\n(.*?)^\}\n", text, re.S | re.M).group(1)
    assert "_lock" not in body and ".lock" not in body
    assert body.count("python3 ") == 1 and body.count("check_python3") == 1


def test_it_is_listed_in_help_and_dispatched():
    text = CLI.read_text(encoding="utf-8")
    assert "    usage-validation-get) shift; cmd_usage_validation_get \"$@\" ;;" in text
    helped = subprocess.run(["bash", str(CLI), "help"], capture_output=True, text=True, timeout=60).stdout
    assert "    usage-validation-get --feature <slug> --phase <id> | [--tasks-file <path>]" in helped
