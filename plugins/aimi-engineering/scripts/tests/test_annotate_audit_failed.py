"""Tests for the audit-failed stub fan-out of `apply-audit-patches --annotate-deferred`.

The Failure Fallback stub (`status == "audit-failed"`) means no story was audited,
so a deferral annotates every staged story; any other `_audit` entry is recorded
only. The helpers are re-declared because test_audit_patches.py is not a library.
"""

import io
import json
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import audit_patches as AP  # noqa: E402

MARKER = "[audit-deferred: unresolved — review before execution]"
RESOLVED = "[audit-deferred: resolved at plan review]"
LABEL = "Reason recorded for the deferred findings of this batch:"
MSG = "cross-story audit did not run"


def story(title="Story", **extra):
    doc = {
        "title": title,
        "description": "As a developer, I want " + title + " so that it works.",
        "acceptanceCriteria": ["Typecheck passes"],
        "status": "pending",
        "dependsOn": [],
        "notes": "",
        "verification": {"strategy": "test", "status": "pending"},
    }
    doc.update(extra)
    return doc


def put(path, doc):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(doc, indent=2))


def get(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def make_stg(tmp_path, count):
    d = tmp_path / "stg"
    d.mkdir()
    for n in range(1, count + 1):
        put(d / ("%02d-s.json" % n), story("S%d" % n))
    return d


def result(stg, unresolved, **extra):
    doc = {"patches": [], "unresolved": unresolved}
    doc.update(extra)
    put(stg / "audit-result.json", doc)


def run(stg, *extra):
    out, err = io.StringIO(), io.StringIO()
    old = sys.stdout, sys.stderr
    sys.stdout, sys.stderr = out, err
    try:
        code = AP.main(["audit_patches.py", "--staging-dir", str(stg), "--annotate-deferred", *extra])
    finally:
        sys.stdout, sys.stderr = old
    text = out.getvalue()
    return code, (json.loads(text) if text.strip() else None)


STUB = [{"storyIdx": "_audit", "message": "audit failed - no patches applied"}]


@pytest.mark.parametrize("count", [2, 3])
def test_stub_annotates_every_staged_story(tmp_path, count):
    stg = make_stg(tmp_path, count)
    result(stg, STUB, status="audit-failed")
    code, report = run(stg, "--reason", "reviewed")
    assert code == 0
    assert report["annotated"] == ["%02d" % n for n in range(1, count + 1)]
    for n in range(1, count + 1):
        notes = get(stg / ("%02d-s.json" % n))["notes"]
        assert notes.startswith(RESOLVED + " ")
        assert MSG in notes
        assert LABEL + " reviewed" in notes
    assert len(report["oqDecisions"]) == 1
    assert report["oqDecisions"][0]["anchor"] == "auditUnresolved:_audit"


def test_stub_agent_deferral_has_no_reason_text(tmp_path):
    stg = make_stg(tmp_path, 2)
    result(stg, STUB, status="audit-failed")
    code, report = run(stg, "--reason", "auto", "--agent-deferral")
    assert code == 0 and report["annotated"] == ["01", "02"]
    for n in ("01", "02"):
        notes = get(stg / ("%s-s.json" % n))["notes"]
        assert notes.startswith(MARKER + " ")
        assert MSG in notes
        assert LABEL not in notes and "auto" not in notes


def test_stub_without_reason_uses_unresolved_marker(tmp_path):
    stg = make_stg(tmp_path, 2)
    result(stg, STUB, status="audit-failed")
    code, report = run(stg)
    assert code == 0 and report["annotated"] == ["01", "02"]
    assert get(stg / "01-s.json")["notes"].startswith(MARKER)


def test_non_stub_audit_entry_is_recorded_only(tmp_path):
    stg = make_stg(tmp_path, 2)
    result(stg, [{"storyIdx": "_audit", "message": "patch cap reached"}])
    code, report = run(stg, "--reason", "x")
    assert code == 0 and report["annotated"] == []
    assert len(report["oqDecisions"]) == 1
    assert get(stg / "01-s.json") == story("S1")


def test_other_status_is_not_a_stub(tmp_path):
    stg = make_stg(tmp_path, 2)
    result(stg, STUB, status="ok")
    code, report = run(stg, "--reason", "x")
    assert report["annotated"] == []


def test_existing_notes_are_kept_and_paragraph_appended(tmp_path):
    stg = make_stg(tmp_path, 2)
    put(stg / "02-s.json", story("S2", notes="existing"))
    result(stg, STUB, status="audit-failed")
    run(stg, "--agent-deferral")
    notes = get(stg / "02-s.json")["notes"]
    assert notes.startswith("existing\n\n---\n\n" + MARKER)
    assert MSG in notes


def test_second_call_appends_a_second_paragraph(tmp_path):
    stg = make_stg(tmp_path, 2)
    result(stg, STUB, status="audit-failed")
    run(stg, "--agent-deferral")
    run(stg, "--agent-deferral")
    assert get(stg / "01-s.json")["notes"].count(MSG) == 2
