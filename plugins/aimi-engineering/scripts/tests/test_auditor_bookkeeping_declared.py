"""Pins the declared-bookkeeping-paths wiring between Phase 3d.5 and the auditor.

Both files are read as text: the spawn file hands the auditor each project's
declared paths, and the agent file exempts them from concern 3's dependsOn rule.
"""
import re
from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[2]
SPAWN = PLUGIN / "commands/references/plan/phase-3d5-audit-spawn.md"
AGENT = PLUGIN / "agents/review/aimi-cross-story-auditor.md"
HEADING = "Declared bookkeeping paths"


def _spawn() -> str:
    return SPAWN.read_text(encoding="utf-8")


def _agent() -> str:
    return AGENT.read_text(encoding="utf-8")


def _section(text: str, title: str) -> str:
    m = re.search(rf"^### {re.escape(title)}\n(.*?)(?=^### |\Z)", text, re.S | re.M)
    assert m, f"section {title!r} missing"
    return m.group(1)


def _concern3(text: str) -> str:
    return _section(text, "3. Missing integration tasks")


def test_spawn_section_precedes_task_spawn():
    t = _spawn()
    a = t.index("### Declared Bookkeeping Paths")
    b = t.index("### Auditor Task Spawn")
    assert a < b


def test_spawn_calls_verb_once_per_key_with_dot_default():
    sec = _section(_spawn(), "Declared Bookkeeping Paths")
    assert sec.count("bookkeeping-declared --project") == 1
    assert 'KEY=' in sec and "once per distinct `project`" in sec
    assert "`.`" in sec


def test_spawn_resolution_line_matches_apply_gate():
    gate = (PLUGIN / "commands/references/plan/phase-3d5-audit-apply-gate.md").read_text()
    line = next(l for l in gate.splitlines() if l.startswith("AIMI_CLI=$(cat"))
    assert line in _spawn()


def test_spawn_template_carries_heading_and_none():
    t = _spawn()
    tmpl = t[t.index("**Task spawn template:**"):]
    assert HEADING in tmpl
    assert "'none'" in tmpl.split(HEADING)[1]


def test_refusal_does_not_stop_audit_and_renders_none():
    sec = _section(_spawn(), "Declared Bookkeeping Paths")
    assert "surface its stderr" in sec
    assert "render that key as `none`" in sec
    assert "continue the audit" in sec
    assert "never exempts" in sec


def test_agent_names_input_as_data_never_opened():
    t = _agent()
    inputs = _section(t, "Inputs you will receive") if "### Inputs you will receive" in t \
        else t.split("## Inputs you will receive")[1].split("\n## ")[0]
    assert HEADING in inputs
    assert "never open as a file" in inputs


def test_agent_exempts_by_exact_match_on_own_key():
    c3 = _concern3(_agent())
    assert "exact string" in c3
    assert "own `project` key" in c3
    assert "no `dependsOn` patch and no `unresolved[]` entry" in c3


def test_agent_negative_twins_stay_patches():
    c3 = _concern3(_agent())
    # undeclared overlap still patched, reason names undeclared only
    assert "also shares an undeclared literal still gets the patch" in c3
    assert "names the undeclared paths only" in c3
    # another key's declaration, `none`, and a missing line exempt nothing
    assert "declared under another key exempts nothing" in c3
    assert "`none` or a key with no line exempts nothing" in c3


def test_exemption_scope_is_narrow():
    c3 = _concern3(_agent())
    assert "wiring-task check above is unchanged" in c3
    assert "finalize-owned path" in c3


def test_nine_concern_headings_unchanged():
    heads = re.findall(r"^### (\d+)\. ", _agent(), re.M)
    assert heads == [str(n) for n in range(1, 10)]
    assert "nine-concern audit" in _agent()
