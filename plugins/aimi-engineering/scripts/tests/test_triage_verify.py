"""triage-verify: static verify-detector findings for a failed story.

Read-only, lock-free, one crossing. Which detectors run is decided by
tasks.SHIPPED_TRIAGE_DETECTORS alone.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pytest  # noqa: E402

import tasks as T  # noqa: E402

PIPEFAIL = "set -o pipefail; git diff | grep -q x"
RUNNER = "bash run-tests.sh | grep -q 'passed'"


def _file(tmp_path, verify, story_id="US-001"):
    story = {"id": story_id, "title": "t", "status": "failed"}
    if verify is not None:
        story["implementation"] = {"verify": verify}
    path = tmp_path / "tasks.json"
    path.write_text(json.dumps({"project": "x", "userStories": [story]}))
    return str(path)


def _run(path, capsys, story_id="US-001"):
    rc = T.op_triage_verify(
        ["triage-verify", "--tasks-file", path, "--story-id", story_id]
    )
    assert rc == 0
    return json.loads(capsys.readouterr().out)


def test_output_shape(tmp_path, capsys):
    out = _run(_file(tmp_path, PIPEFAIL), capsys)
    assert set(out) == {"id", "findings", "shipped"}
    assert out["id"] == "US-001"
    assert out["shipped"] == list(T.SHIPPED_TRIAGE_DETECTORS)
    assert out["findings"]
    assert {"detector", "segment", "message"} <= set(out["findings"][0])


def test_read_only(tmp_path, capsys):
    path = _file(tmp_path, PIPEFAIL)
    before = open(path, "rb").read()
    mtime = os.stat(path).st_mtime_ns
    _run(path, capsys)
    assert open(path, "rb").read() == before
    assert os.stat(path).st_mtime_ns == mtime
    assert not os.path.exists(path + ".lock")


def test_only_the_shipped_subset_runs(tmp_path, capsys, monkeypatch):
    path = _file(tmp_path, PIPEFAIL)
    monkeypatch.setattr(T, "SHIPPED_TRIAGE_DETECTORS", ("git-diff-unstaged",))
    out = _run(path, capsys)
    assert out["shipped"] == ["git-diff-unstaged"]
    assert all(f["detector"] == "git-diff-unstaged" for f in out["findings"])


def test_not_shipped_detectors_never_enabled():
    assert "runner-summary-colour" not in T.SHIPPED_TRIAGE_DETECTORS
    assert "negated-grep-no-twin" not in T.SHIPPED_TRIAGE_DETECTORS


def test_empty_constant(tmp_path, capsys, monkeypatch):
    path = _file(tmp_path, PIPEFAIL)
    monkeypatch.setattr(T, "SHIPPED_TRIAGE_DETECTORS", ())
    out = _run(path, capsys)
    assert out["findings"] == [] and out["shipped"] == []


def test_empty_constant_says_so_on_stderr(tmp_path, capsys, monkeypatch):
    path = _file(tmp_path, PIPEFAIL)
    monkeypatch.setattr(T, "SHIPPED_TRIAGE_DETECTORS", ())
    T.op_triage_verify(["triage-verify", "--tasks-file", path, "--story-id", "US-001"])
    assert "no shipped detector" in capsys.readouterr().err


@pytest.mark.parametrize("verify", [None, "", "   \n", "echo 'unterminated"])
def test_no_empty_or_unterminated_verify_answers_empty(tmp_path, capsys, verify):
    out = _run(_file(tmp_path, verify), capsys)
    assert out["findings"] == []


def test_quotes_are_sanitized_and_capped(tmp_path, capsys):
    verify = "set -o pipefail; git diff | grep -q " + "x" * 5000 + "\x1b[31m"
    out = _run(_file(tmp_path, verify), capsys)
    assert out["findings"]
    for finding in out["findings"]:
        assert "\x1b" not in finding["segment"]
        assert len(finding["segment"]) < 1000
