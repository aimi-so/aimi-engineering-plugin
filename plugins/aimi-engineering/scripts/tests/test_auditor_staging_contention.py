"""Pins the contending-staged-pairs wiring between Phase 3d.5 and the auditor.

Both files are read as text: the spawn file runs `staging-contention` once over
RUN_DIR and hands the answer to the auditor, and the agent file patches only the
pairs that answer lists instead of re-deriving the shared-path rule.
"""
import re
from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[2]
SPAWN = PLUGIN / "commands/references/plan/phase-3d5-audit-spawn.md"
AGENT = PLUGIN / "agents/review/aimi-cross-story-auditor.md"
HEADING = "Contending staged pairs"
OLD_SENTENCE = "land in the same wave, and `validate-wave-contention` later refuses that wave"


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


def _inputs(text: str) -> str:
    return text.split("## Inputs you will receive")[1].split("\n## ")[0]


def test_spawn_section_sits_before_task_spawn():
    t = _spawn()
    assert t.index("### Contending Staged Pairs") < t.index("### Auditor Task Spawn")


def test_spawn_runs_the_verb_exactly_once_over_run_dir():
    sec = _section(_spawn(), "Contending Staged Pairs")
    assert sec.count("staging-contention --staging-dir") == 1
    assert '--staging-dir "$RUN_DIR"' in sec
    assert "exactly once" in sec
    assert "verbatim" in sec


def test_spawn_resolution_line_matches_apply_gate():
    gate = (PLUGIN / "commands/references/plan/phase-3d5-audit-apply-gate.md").read_text()
    line = next(l for l in gate.splitlines() if l.startswith("AIMI_CLI=$(cat"))
    assert line in _section(_spawn(), "Contending Staged Pairs")


def test_spawn_renders_none_and_unavailable_and_continues():
    sec = _section(_spawn(), "Contending Staged Pairs")
    assert '`"pairs":[]` renders as `none`' in sec
    assert "surface its stderr" in sec
    assert "render the section as `unavailable`" in sec
    assert "continue the audit" in sec
    assert "never read as no contention" in sec


def test_spawn_template_carries_heading_with_both_renderings():
    t = _spawn()
    tmpl = t[t.index("**Task spawn template:**"):]
    assert HEADING in tmpl
    block = tmpl.split(HEADING)[1].split("Failed expansion idx")[0]
    assert "'none'" in block and "'unavailable'" in block


def test_agent_names_pairs_as_numbered_data_input_never_opened():
    inputs = _inputs(_agent())
    line = next(l for l in inputs.splitlines() if HEADING in l)
    assert re.match(r"\d+\. ", line)
    assert "never open as a file" in line
    assert "staging-contention" in line
    assert "`unavailable`" in line and "`none`" in line


def test_agent_concern3_patches_only_listed_pairs():
    c3 = _concern3(_agent())
    assert "For each listed pair" in c3
    assert "higher outline index" in c3
    assert "Patch only listed pairs" in c3
    assert "disjoint symbols" in c3
    assert "you derive no contention yourself" in c3


def test_agent_concern3_cycle_and_same_wave_go_to_unresolved():
    c3 = _concern3(_agent())
    assert "`dependsOn` cycle" in c3
    assert "legitimately need to run in the same wave" in c3
    assert "`unresolved[]` entry naming both stories and the path" in c3


def test_agent_unavailable_is_one_unresolved_never_an_empty_result():
    c3 = _concern3(_agent())
    assert "On `unavailable`" in c3
    assert "the wave serialization was not checked" in c3
    assert "never an empty result" in c3


def test_negative_twin_old_shared_path_derivation_is_gone():
    t = _agent()
    assert OLD_SENTENCE not in t
    c3 = _concern3(t)
    assert "list one literal path" not in c3
    assert "are not ordered by `dependsOn`" not in c3
    assert "Stories of different projects never collide" not in c3


def test_unchanged_paragraphs_and_concern_headings():
    c3 = _concern3(_agent())
    assert "cross-story wiring step" in c3
    assert "no story may claim a finalize-owned path because of it" in c3
    assert "applies to the listed pairs only" in c3.lower()
    heads = re.findall(r"^### (\d+)\. ", _agent(), re.M)
    assert heads == [str(n) for n in range(1, 10)]
    assert "nine-concern audit" in _agent()
    assert "Declared bookkeeping paths" in _spawn()


def test_dependson_add_stays_the_only_serialization_patch():
    t = _agent()
    assert "implementation.symbols" not in t
    c3 = _concern3(t)
    assert "`dependsOn` `add` patch" in c3
