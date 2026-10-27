"""op_roadmap_planned_phases: the claimable planned phases split-detect asks about."""

import json
import os
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
sys.path.insert(0, SCRIPTS)

import roadmap as R  # noqa: E402


def _roadmap(tmp_path, feature, phases):
    d = tmp_path / "tasks" / feature
    d.mkdir(parents=True)
    path = d / "roadmap.json"
    path.write_text(json.dumps({"phases": phases}), encoding="utf-8")
    return str(path)


def _run(paths):
    proc = subprocess.run(
        [sys.executable, os.path.join(SCRIPTS, "roadmap.py"), "planned-phases", *paths],
        capture_output=True, text=True,
    )
    return proc.returncode, (json.loads(proc.stdout) if proc.stdout.strip() else None), proc.stderr


def test_planned_unclaimed_phase_is_listed(tmp_path):
    p = _roadmap(tmp_path, "feat-a", [{"id": 1, "name": "One", "status": "planned"}])
    code, out, _ = _run([p])
    assert code == 0
    assert out == [{"feature": "feat-a", "id": 1, "name": "One"}]


def test_claimed_phase_is_not_listed(tmp_path):
    p = _roadmap(tmp_path, "f", [
        {"id": 1, "name": "One", "status": "planned", "claim": {"claimedPid": 1}}])
    assert _run([p])[1] == []


def test_dependency_blocked_phase_is_not_listed(tmp_path):
    p = _roadmap(tmp_path, "f", [
        {"id": 1, "name": "One", "status": "in_progress"},
        {"id": 2, "name": "Two", "status": "planned", "dependsOn": [1]}])
    assert _run([p])[1] == []


def test_completed_dependency_unblocks(tmp_path):
    p = _roadmap(tmp_path, "f", [
        {"id": 1, "name": "One", "status": "completed"},
        {"id": 2, "name": "Two", "status": "planned", "dependsOn": [1]}])
    assert [x["id"] for x in _run([p])[1]] == [2]


def test_non_planned_status_is_not_listed(tmp_path):
    p = _roadmap(tmp_path, "f", [{"id": 1, "name": "One", "status": "pending"}])
    assert _run([p])[1] == []


def test_corrupt_roadmap_is_skipped_with_one_stderr_line(tmp_path):
    good = _roadmap(tmp_path, "good", [{"id": 3, "name": "G", "status": "planned"}])
    bad_dir = tmp_path / "tasks" / "bad"
    bad_dir.mkdir()
    bad = bad_dir / "roadmap.json"
    bad.write_text("{not json", encoding="utf-8")
    code, out, err = _run([str(bad), good])
    assert code == 0
    assert [x["feature"] for x in out] == ["good"]
    assert len([l for l in err.splitlines() if l]) == 1


def test_registered_and_named_for_a_runnable_verb():
    assert R._OPS["planned-phases"] is R.op_roadmap_planned_phases
    assert R._VERB_FOR_OP["planned-phases"] == "split-detect"
