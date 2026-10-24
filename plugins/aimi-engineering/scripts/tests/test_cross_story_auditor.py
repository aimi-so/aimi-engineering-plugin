"""Structural tests for the cross-story auditor: its op table, and concerns seven to nine.

The agent file and the plan Phase 3d.5 are read as text; nothing is executed,
except that the op table is compared with `audit_patches.OPS_FOR_FIELD`, the
rule the table describes.
"""

import os
import re
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import audit_patches  # noqa: E402
from plan_text import plan_text  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
AGENT_TEXT = (ROOT / "agents" / "review" / "aimi-cross-story-auditor.md").read_text(encoding="utf-8")
# plan.md is a router; Phase 3d.5 lives in commands/references/plan/. plan_text()
# puts the references first, so the heading below resolves to the moved section.
PLAN_TEXT = plan_text()

HEADING = "### 7. Cross-project contract orphan"
HEADING_8 = "### 8. Intra-story contradiction"
HEADING_9 = "### 9. Outline contract conformance"
AGENT_REL = "agents/review/aimi-cross-story-auditor.md"
BASELINE = ROOT / "scripts" / "command-size-baseline.txt"
SPAWN_TEXT = (ROOT / "commands" / "references" / "plan" / "phase-3d5-audit-spawn.md").read_text(encoding="utf-8")
GATE_TEXT = (ROOT / "commands" / "references" / "plan" / "phase-3d5-audit-apply-gate.md").read_text(encoding="utf-8")


def _concern_seven():
    # Bounded at the next concern heading, so concern 8 is never swallowed.
    start = AGENT_TEXT.index(HEADING)
    end = AGENT_TEXT.index("\n### ", start)
    return AGENT_TEXT[start:end]


def _concern_eight():
    # Bounded at the next concern heading, so concern 9 is never swallowed.
    start = AGENT_TEXT.index(HEADING_8)
    end = AGENT_TEXT.index("\n### ", start)
    return AGENT_TEXT[start:end]


def _concern_nine():
    start = AGENT_TEXT.index(HEADING_9)
    end = AGENT_TEXT.index("\n## ", start)
    return AGENT_TEXT[start:end]


def _op_table(text=AGENT_TEXT):
    """{field: set of ops} read from the op table rows of `text`."""
    start = text.index("### Op table")
    end = text.index("\n### ", start + 1)
    rows = {}
    for line in text[start:end].splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 2 or not (cells[0].startswith("`") and cells[1].startswith("`")):
            continue
        field = cells[0].strip("`")
        assert field not in rows, "duplicate op table row for " + field
        rows[field] = {op.strip() for op in cells[1].strip("`").split(",")}
    return rows


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
    assert not re.search(r"\b(six|seven|eight)[- ]concerns?\b", AGENT_TEXT)
    assert "nine concerns" in AGENT_TEXT
    assert "nine-concern" in AGENT_TEXT


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


def test_exactly_nine_concern_headings():
    assert len(re.findall(r"^### [0-9]\. ", AGENT_TEXT, re.M)) == 9


def test_concern_eight_compares_the_three_fields():
    body = _concern_eight()
    for field in ("`notes`", "`acceptanceCriteria`", "`implementation.approach`"):
        assert field in body
    assert "pairwise" in body


def test_concern_eight_stale_note_is_a_notes_replace_with_unresolved_fallback():
    body = _concern_eight()
    assert "`notes` `replace` patch" in body
    assert "quotes the stale paragraph exactly" in body
    assert "`\\n\\n---\\n\\n`" in body
    assert "Only when the paragraph cannot be isolated" in body
    assert "intra-story contradiction:" in body
    assert "naming the story and the two fields" in body
    assert "accepts only" not in body


def test_concern_eight_covers_intra_story_duplication():
    body = _concern_eight()
    assert "intra-story duplication" in body
    assert "between `acceptanceCriteria` and `tasks`" in body
    assert "restating `implementation.approach`" in body
    assert "`tasks` `remove` patch" in body
    assert "`acceptanceCriteria` `replace` patch" in body
    assert "Leave the fact in one field" in body
    assert "unresolved[]" in body
    assert "intra-story duplication:" in body


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


def test_concern_nine_follows_concern_eight_and_is_bounded():
    audit = AGENT_TEXT.index("## Audit scope")
    assert audit < AGENT_TEXT.index(HEADING_8) < AGENT_TEXT.index(HEADING_9)
    assert AGENT_TEXT.index(HEADING_9) < AGENT_TEXT.index("## What you do NOT do")
    assert HEADING_9 not in _concern_eight()


def test_concern_nine_checks_each_story_against_its_outline_contract():
    body = _concern_nine()
    assert "`dependsOn` `add` patch" in body
    assert "outline:NN" in body
    assert "never mentions" in body
    assert "no outline entry produces it" in body
    assert "`ext:`" in body
    assert body.count("unresolved[]") >= 2


def test_concern_nine_emits_nothing_without_a_contract():
    body = _concern_nine()
    assert "emits nothing for this concern" in body
    assert "`produces:`" in body and "`consumes:`" in body


def test_op_table_matches_ops_for_field():
    table = _op_table()
    assert set(table) == set(audit_patches.OPS_FOR_FIELD)
    for field, ops in audit_patches.OPS_FOR_FIELD.items():
        assert table[field] == set(ops), field


def test_op_table_parity_check_goes_red_on_a_damaged_table():
    damaged = AGENT_TEXT.replace("| `tasks` | `add, replace, remove` |", "| `tasks` | `add, replace` |", 1)
    assert damaged != AGENT_TEXT
    assert _op_table(damaged)["tasks"] != set(audit_patches.OPS_FOR_FIELD["tasks"])
    dropped_row = "\n".join(ln for ln in AGENT_TEXT.splitlines() if not ln.startswith("| `gate.prompt` |"))
    assert set(_op_table(dropped_row)) != set(audit_patches.OPS_FOR_FIELD)


def test_matching_rules_are_stated():
    assert "equal one whole" in AGENT_TEXT
    assert "occurs exactly once" in AGENT_TEXT
    assert "every `guardRails` entry containing it" in AGENT_TEXT
    assert "`guardRails-out-of-sync`" in AGENT_TEXT
    assert "`verify-composition`" in AGENT_TEXT
    assert "stored verbatim, never rewritten" in AGENT_TEXT
    assert "reported by trigger name, never by value" in AGENT_TEXT


def test_no_stale_vocabulary_wording():
    assert "accepts only `add`" not in AGENT_TEXT
    assert "dropped silently" not in AGENT_TEXT
    assert "six" not in AGENT_TEXT
    assert "listed in the orchestrator's apply report" in AGENT_TEXT
    assert "adds no `unresolved[]` entry" in AGENT_TEXT


def test_spawn_renders_the_outline_contract_and_names_nine_concerns():
    assert "produces: <names, comma-joined>" in SPAWN_TEXT
    assert "consumes: <names, comma-joined>" in SPAWN_TEXT
    assert "verbatim from outline.json" in SPAWN_TEXT
    assert "renders its own line only" in SPAWN_TEXT
    assert "nine audit concerns" in SPAWN_TEXT
    assert not re.search(r"\b(six|seven|eight) audit concerns\b", SPAWN_TEXT)


def test_apply_gate_describes_the_vocabulary_and_the_dropped_report():
    assert "storyIdx, field, op, reason" in GATE_TEXT
    assert "trigger" in GATE_TEXT
    assert "not counted as unresolved" in GATE_TEXT
    assert "`remove`" in GATE_TEXT
    assert "guardRails-out-of-sync" in GATE_TEXT
    assert "verify-composition" in GATE_TEXT
    assert "{applied, dropped, unresolved, auditedIdx}" in GATE_TEXT


def _recorded_budget():
    for line in BASELINE.read_text(encoding="utf-8").splitlines():
        if line.startswith("#"):
            continue
        fields = line.split("\t")
        if fields[0] == AGENT_REL:
            return int(fields[1])
    raise AssertionError(AGENT_REL + " has no line in command-size-baseline.txt")


def test_auditor_baseline_has_exactly_one_line():
    lines = [ln for ln in BASELINE.read_text(encoding="utf-8").splitlines() if ln.split("\t")[0] == AGENT_REL]
    assert len(lines) == 1


def test_auditor_file_stays_within_its_recorded_budget():
    # The ratchet in test-command-size.sh fails both ways; this pin reads the
    # same line rather than a literal, so the two cannot disagree.
    assert len(AGENT_TEXT.encode("utf-8")) == _recorded_budget()
