"""Structural tests for the cross-story auditor's seventh concern.

The agent file and plan.md Phase 3d.5 are read as text; nothing is executed.
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
AGENT_TEXT = (ROOT / "agents" / "workflow" / "aimi-cross-story-auditor.md").read_text(encoding="utf-8")
PLAN_TEXT = (ROOT / "commands" / "plan.md").read_text(encoding="utf-8")

HEADING = "### 7. Cross-project contract orphan"


def _concern_seven():
    start = AGENT_TEXT.index(HEADING)
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
    assert "seven concerns" in AGENT_TEXT
    assert "seven-concern" in AGENT_TEXT


def test_plan_phase_3d5_mentions_concern():
    body = _phase_3d5()
    assert re.search(r"cross-project contract orphan", body, re.I)
    assert "unresolved-only" in body
