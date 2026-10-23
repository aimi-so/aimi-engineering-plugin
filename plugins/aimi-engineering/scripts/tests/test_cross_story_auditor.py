"""Structural tests for the cross-story auditor's seventh and eighth concerns.

The agent file and plan.md Phase 3d.5 are read as text; nothing is executed.
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
AGENT_TEXT = (ROOT / "agents" / "workflow" / "aimi-cross-story-auditor.md").read_text(encoding="utf-8")
PLAN_TEXT = (ROOT / "commands" / "plan.md").read_text(encoding="utf-8")

HEADING = "### 7. Cross-project contract orphan"
HEADING_8 = "### 8. Intra-story contradiction"


def _concern_seven():
    # Bounded at the next concern heading, so concern 8 is never swallowed.
    start = AGENT_TEXT.index(HEADING)
    end = AGENT_TEXT.index("\n### ", start)
    return AGENT_TEXT[start:end]


def _concern_eight():
    start = AGENT_TEXT.index(HEADING_8)
    end = AGENT_TEXT.index("\n## ", start)
    return AGENT_TEXT[start:end]


def _phase_3d5():
    start = PLAN_TEXT.index("## Phase 3d.5: Cross-Story DAG Audit")
    end = PLAN_TEXT.index("\n### Skip Condition", start)
    return PLAN_TEXT[start:end]


def test_agent_declares_seventh_concern_under_audit_scope():
    audit = AGENT_TEXT.index("## Audit scope")
    assert HEADING in AGENT_TEXT
    assert AGENT_TEXT.index(HEADING) > AGENT_TEXT.index("### 6. Deferral surfacing") > audit


def test_concern_is_unresolved_only():
    body = _concern_seven()
    assert "unresolved-only" in body
    assert "never emits a patch" in body
    assert "unresolved[]" in body


def test_single_project_plan_is_a_no_op():
    body = _concern_seven()
    assert "single-project plan" in body
    assert "emits nothing" in body
    assert "2+ distinct" in body


def test_concern_count_wording_updated():
    assert "six concerns" not in AGENT_TEXT
    assert "six-concern" not in AGENT_TEXT
    assert "seven concerns" not in AGENT_TEXT
    assert "seven-concern" not in AGENT_TEXT
    assert "eight concerns" in AGENT_TEXT
    assert "eight-concern" in AGENT_TEXT


def test_plan_phase_3d5_mentions_concern():
    body = _phase_3d5()
    assert re.search(r"cross-project contract orphan", body, re.I)
    assert "unresolved-only" in body


def test_concern_seven_is_intact_and_bounded():
    body = _concern_seven()
    assert HEADING_8 not in body
    assert "cross-project contract orphan" in body
    assert "never emits a patch" in body
    assert "2+ distinct" in body


def test_concern_eight_follows_concern_seven_under_audit_scope():
    audit = AGENT_TEXT.index("## Audit scope")
    assert audit < AGENT_TEXT.index(HEADING) < AGENT_TEXT.index(HEADING_8)
    assert AGENT_TEXT.index(HEADING_8) < AGENT_TEXT.index("## What you do NOT do")


def test_exactly_eight_concern_headings():
    assert len(re.findall(r"^### [0-9]\. ", AGENT_TEXT, re.M)) == 8


def test_concern_eight_compares_the_three_fields():
    body = _concern_eight()
    for field in ("`notes`", "`acceptanceCriteria`", "`implementation.approach`"):
        assert field in body
    assert "pairwise" in body


def test_concern_eight_stale_note_is_unresolved_only():
    body = _concern_eight()
    assert "`notes` accepts only `add`" in body
    assert "unresolved[]" in body
    assert "intra-story contradiction:" in body
    assert "naming the story and the two fields" in body


def test_concern_eight_replace_needs_matchvalue_for_criteria_and_complete_approach():
    body = _concern_eight()
    assert "op: replace" in body
    assert "`matchValue` quoting it exactly" in body
    assert "complete corrected string" in body
    assert "most recent decision" in body


def test_concern_eight_ignores_recorded_history_markers():
    body = _concern_eight()
    assert "`[audit-deferred:`" in body
    assert "`[superseded`" in body
    assert "never flag" in body


def test_auditor_file_stays_within_the_size_ceiling():
    assert len(AGENT_TEXT.encode("utf-8")) <= 16384
