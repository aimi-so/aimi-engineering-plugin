"""Structure-only tests for the Prototype-First Options rule.

Reads files as TEXT and asserts headings, citations and named tokens; never
English wording.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REFS = ROOT / "commands" / "references"
COMM = REFS / "user-communication.md"
CITERS = [
    REFS / "plan" / "phase-0-open-questions-gate.md",
    REFS / "plan" / "phase-1-8-open-questions-and-scope-gates.md",
    REFS / "plan" / "phase-2-5-spec-flow-gap-gate.md",
    REFS / "brainstorm" / "phase-2-questions.md",
]
HEADING = "## Prototype-First Options"


def section():
    text = COMM.read_text(encoding="utf-8")
    start = text.index("\n" + HEADING + "\n")
    nxt = text.find("\n## ", start + 1)
    return text[start:] if nxt == -1 else text[start:nxt]


def test_section_heading_exists_once():
    assert COMM.read_text(encoding="utf-8").count("\n" + HEADING + "\n") == 1


def test_section_names_supersede_record_and_fallback():
    body = section()
    assert "metadata.prototypeSuperseded" in body
    assert "follow-existing-pattern" in body
    assert "phase-4-metadata-context.md" in body


def test_section_lists_all_four_citers():
    head = COMM.read_text(encoding="utf-8").split("\n## ", 1)[0]
    for f in CITERS:
        assert f.name in head


def test_boundaries_names_the_section():
    text = COMM.read_text(encoding="utf-8")
    b = text.index("## Boundaries")
    assert HEADING in text[b : text.index("\n## ", b + 1)]


def test_cites_section_in_each_file():
    for f in CITERS:
        t = f.read_text(encoding="utf-8")
        assert "user-communication.md" in t, f.name
        assert "Prototype-First Options" in t, f.name


def test_cites_do_not_restate_the_rule():
    for f in CITERS:
        assert "metadata.prototypeSuperseded" not in f.read_text(encoding="utf-8"), f.name
