"""Pins how the story-executor brief treats `story.implementation.symbols`.

A story that declares the symbols it creates and edits in a shared file is told
that the declaration is its scope there, that touching an undeclared symbol is
allowed but must be reported, and that nothing is refused at execute time. The
report rides the existing `knownGaps` key of the result contract as one
`undeclared-symbol: <path> <symbol>` entry, so the orchestrator's knownGaps
extraction writes it to `.aimi/known-gaps` unchanged.

These tests read the brief's Step 2 section and its Result Contract section
only, so a sentence elsewhere in the file cannot satisfy or break them.
"""

import json
import re
from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[2]
SKILL = PLUGIN / "skills" / "story-executor" / "SKILL.md"


def _section(heading: str) -> str:
    text = SKILL.read_text(encoding="utf-8")
    start = text.index(heading)
    nxt = re.search(r"^## ", text[start + len(heading):], re.MULTILINE)
    end = start + len(heading) + nxt.start() if nxt else len(text)
    return text[start:end]


def _flat(section: str) -> str:
    return " ".join(section.split())


def _step_2() -> str:
    return _flat(_section("## Step 2 — Implement"))


def _result_contract_raw() -> str:
    return _section("## Result Contract (REQUIRED)")


def _result_contract() -> str:
    return _flat(_result_contract_raw())


def test_symbols_field_is_named_as_a_path_to_creates_and_edits():
    step = _step_2()
    assert "`story.implementation.symbols`" in step
    assert "maps a path to `{creates: [...], edits: [...]}`" in step


def test_symbols_declaration_is_the_scope_in_each_keyed_file():
    step = _step_2()
    assert (
        "For each path that is a key of it, those names are your scope in that file."
    ) in step


def test_symbols_unkeyed_path_and_absent_or_empty_map_are_whole_file_claims():
    step = _step_2()
    assert (
        "A path in `story.implementation.files` with no key, or a story whose map is "
        "absent or `{}`, is a whole-file claim with no symbol scope."
    ) in step


def test_symbols_touching_an_undeclared_symbol_is_allowed_but_reported():
    step = _step_2()
    assert (
        "Touching an undeclared symbol is allowed when an acceptance criterion needs "
        "it, but report it"
    ) in step


def test_symbols_nothing_is_refused_and_the_wave_check_is_the_safety_net():
    step = _step_2()
    assert "Nothing is refused at execute time for it" in step
    assert "the integrated wave check after the merge remains the safety net" in step


def test_symbols_label_is_defined_in_the_result_contract():
    contract = _result_contract()
    assert "`undeclared-symbol: <path> <symbol>`" in contract
    assert "as one entry of the exact form" in contract
    assert "one per path and symbol" in contract
    assert "`knownGaps`" in contract


def test_symbols_nothing_is_reported_inside_the_declaration_or_without_one():
    contract = _result_contract()
    assert (
        "Report none when you stayed inside the declaration or the story declared "
        "no symbols."
    ) in contract


def test_symbols_label_is_not_satisfied_by_text_outside_the_two_sections():
    # The label must live in the Result Contract, not merely somewhere in the file.
    assert "undeclared-symbol" not in _step_2()
    assert "undeclared-symbol" in _result_contract()


def _template_keys() -> list[str]:
    raw = _result_contract_raw()
    fence = re.search(r"```\n(<result_json>\n\{.*?\n\}\n</result_json>)\n```", raw, re.DOTALL)
    assert fence, "result_json template fence not found"
    body = fence.group(1)
    body = body.split("<result_json>\n", 1)[1].rsplit("\n</result_json>", 1)[0]
    # strip the template's // comments so it parses as the keys it declares
    body = re.sub(r"\s//.*$", "", body, flags=re.MULTILINE)
    # placeholders such as <int> are not JSON; keys are all that matter here
    return re.findall(r'^\s{2}"(\w+)":', body, re.MULTILINE)


def test_symbols_result_template_gains_no_new_top_level_key():
    assert _template_keys() == [
        "status",
        "commit",
        "tests",
        "typecheck",
        "verify",
        "knownGaps",
        "deviations",
        "failureCause",
    ]


def test_symbols_success_example_still_parses_with_known_keys_only():
    raw = _result_contract_raw()
    example = re.search(r'^\{"status":"ok".*\}$', raw, re.MULTILINE)
    assert example
    assert set(json.loads(example.group(0))) <= set(_template_keys())
