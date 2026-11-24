"""Pins the Retry audit option of the Phase 3d.5 Unresolved Gate.

Reads the gate file straight from the tree and asserts the phrases that carry
each rule, so rewording the gate back to a single option set fails here.
"""

from pathlib import Path

GATE = (
    Path(__file__).resolve().parents[2]
    / "commands" / "references" / "plan" / "phase-3d5-audit-apply-gate.md"
)


def gate_text():
    return GATE.read_text(encoding="utf-8")


def flat(text):
    return " ".join(text.split())


def test_stub_gate_offers_four_options_retry_first_apply_absent():
    t = gate_text()
    block = t.split("Retry audit — re-run", 1)[1].split("```", 1)[0]
    labels = [ln.split(" — ")[0] for ln in ("Retry audit — re-run" + block).splitlines() if " — " in ln]
    assert labels == ["Retry audit", "Defer as open", "Edit outline", "Abort"]
    assert "Apply anyway is not offered, because" in flat(t)
    assert "names the attempt number" in flat(t)


def test_falls_back_to_normal_options_after_two_retries():
    t = flat(gate_text())
    assert "After the second retry" in t
    assert "Retry audit is no longer listed" in t
    assert "falls back to the two-question form" in t


def test_trigger_is_audit_failed_status_not_audit_sentinel():
    t = flat(gate_text())
    assert "Only the stub's `status` field, `audit-failed`" in t
    assert "The `_audit` sentinel alone never offers Retry audit" in t
    assert "malformed auditor entry" in t and "patch-cap notice" in t


def test_retry_reenters_at_consolidation_step_without_rewrite_or_reexpansion():
    t = flat(gate_text())
    assert "re-enter the audit at the `consolidation.md` step of `phase-3d5-audit-spawn.md`" in t
    assert "never rewritten" in t
    assert "no story is re-expanded" in t
    assert "The stub stays in place and valid while the retry runs" in t
    assert "on failure this section rewrites the stub" in t
    assert "missing or empty after the consolidation step" in t


def test_edit_outline_resets_attempts_and_rewrites_consolidation():
    t = flat(gate_text())
    assert "resets `auditRetries` to 0 and rewrites `consolidation.md` unconditionally (Retry audit does neither)" in t


def test_agent_mode_retries_once_before_auto_deferral():
    t = flat(gate_text())
    assert "retry the audit once automatically, with one log line per attempt" in t
    assert "a second failure falls through to the auto-deferral below unchanged" in t


def test_defer_paragraph_names_status_only():
    t = flat(gate_text())
    assert "only its `status` of `audit-failed` marks it, never the `_audit` sentinel" in t


def test_option_labels_follow_reader_language():
    assert "reader's language" in gate_text()


def _labels(block):
    return [ln.split(" — ")[0] for ln in block.splitlines() if " — " in ln]


def test_two_question_gate_first_question_has_four_options_in_order():
    t = gate_text()
    block = t.split("exactly these four options, in this order:**", 1)[1].split("```", 2)[1]
    assert _labels(block) == ["Resolve", "Defer as open", "Apply anyway", "Stop here"]


def test_two_question_gate_stop_here_opens_edit_outline_or_abort():
    t = flat(gate_text())
    assert "**Stop here** opens a second question with exactly two options" in t
    assert "`Edit outline" in t and "`Abort" in t
    assert "No question in this gate offers more than four options" in t


def test_two_question_gate_stub_set_has_no_resolve_and_label_is_gone():
    t = flat(gate_text())
    assert "Resolve is not offered" in t
    assert "Defer " + "with reason" not in t
