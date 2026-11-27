"""Structural pin on the story expander's `implementation.symbols` declaration.

`agents/workflow/aimi-story-expander.md` tells every expander to declare, per file
of `implementation.files`, the symbols its story creates and edits. Three facts
about that text can rot without a test noticing:

* `## Declared symbols` sits between `## Single-story output shape` and
  `## Prototype citations`, the range `phase-3d-expander-prompt.md` tells every
  expander to follow, and states the whole-file-claim, no-pseudo-symbol,
  exact-name, rename and identity rules, and that the key is always written.
* The output-shape template shows `symbols` inside `implementation`, and the
  `## Field ownership and budget` row that owns where the story works names
  `implementation.symbols`.
* The worked example in the section is a json fence that
  `tasks.implementation_symbol_findings` accepts with no finding, and every key
  of it is an entry of the example's `files`.

Each check is a function over a corpus dict `{path relative to plugin root: text}`
and returns a list of problems, empty when fine, so
`test_checks_go_red_on_broken_copy` can hand the same functions a damaged copy.
A section is found by its heading, so the checks follow the text when lines move.
"""

import json
import os
import re
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import plan_text  # noqa: E402
import tasks as T  # noqa: E402

AGENT = "agents/workflow/aimi-story-expander.md"

SHAPE = "## Single-story output shape"
OWNERSHIP = "## Field ownership and budget"
SYMBOLS = "## Declared symbols"
CITATIONS = "## Prototype citations"


def load_corpus():
    root = plan_text.ROOT
    return {AGENT: (root / AGENT).read_text(encoding="utf-8")}


def section(text, heading):
    """The heading line and body of the `## ` section starting with `heading`, or None."""
    match = re.search(r"^%s[^\n]*\n" % re.escape(heading), text, re.MULTILINE)
    if match is None:
        return None
    nxt = re.search(r"^## ", text[match.end():], re.MULTILINE)
    end = match.end() + nxt.start() if nxt else len(text)
    return text[match.start():end]


def _heading_offset(text, heading):
    match = re.search(r"^%s" % re.escape(heading), text, re.MULTILINE)
    return None if match is None else match.start()


def check_rules_section(corpus):
    text = corpus.get(AGENT, "")
    body = section(text, SYMBOLS)
    if body is None:
        return ["%s lost its '%s' section" % (AGENT, SYMBOLS)]
    problems = []
    shape, symbols, citations = (_heading_offset(text, h) for h in (SHAPE, SYMBOLS, CITATIONS))
    if shape is None or citations is None or not (shape < symbols < citations):
        problems.append("'%s' is not between '%s' and '%s'" % (SYMBOLS, SHAPE, CITATIONS))
    for literal, what in (
        ("whole-file claim", "the whole-file-claim rule"),
        ("no key and no pseudo-symbol", "the no-pseudo-symbol rule"),
        ("CHANGELOG", "the CHANGELOG example of a nameless file"),
        ("`EXPECTED_ASSERTIONS`", "the shared-count example of a nameless file"),
        ("case-sensitive", "the exact-name rule"),
        ("scoped to their path", "the path-scoped name rule"),
        ("old name under `edits`", "the rename rule's old name"),
        ("new one under `creates`", "the rename rule's new name"),
        ("`_identity_reasons`", "the identity-rules citation"),
        ("no whitespace, no shell metacharacters", "the identity-rules summary"),
        ("`implementation_symbol_findings`", "the contract citation"),
        ("Always write the key", "the always-present key rule"),
        ("`{}`", "the empty-object form"),
    ):
        if literal not in body:
            problems.append("Declared symbols lost %s (%s)" % (what, literal))
    if "Markdown section" not in body or "config key" not in body:
        problems.append("Declared symbols does not list a Markdown section and a config key as nameless")
    if "every key is also an entry of `implementation.files`" not in body.replace("Every key", "every key"):
        problems.append("Declared symbols does not say every key is an entry of implementation.files")
    return problems


def check_template_shows_symbols(corpus):
    body = section(corpus.get(AGENT, ""), SHAPE)
    if body is None:
        return ["%s lost its '%s' section" % (AGENT, SHAPE)]
    match = re.search(r'"implementation":\s*\{(.*?)\n  \},', body, re.DOTALL)
    if match is None:
        return ["the output-shape template lost its implementation block"]
    if '"symbols"' not in match.group(1):
        return ["the output-shape template does not show symbols inside implementation"]
    return []


def check_ownership_row_names_symbols(corpus):
    body = section(corpus.get(AGENT, ""), OWNERSHIP)
    if body is None:
        return ["%s lost its '%s' section" % (AGENT, OWNERSHIP)]
    rows = [l for l in body.splitlines() if l.startswith("| `implementation.files`")]
    if not rows:
        return ["the ownership table lost its implementation.files row"]
    if "implementation.symbols" not in rows[0]:
        return ["the ownership row that owns where the story works does not name implementation.symbols"]
    return []


def _example(body):
    fence = re.search(r"```json\n(.*?)```", body, re.DOTALL)
    if fence is None:
        return None, "Declared symbols has no json example"
    try:
        return json.loads("{" + fence.group(1) + "}"), None
    except ValueError as exc:
        return None, "the Declared symbols example is not valid JSON members: %s" % exc


def check_example_is_accepted(corpus):
    body = section(corpus.get(AGENT, ""), SYMBOLS)
    if body is None:
        return ["%s lost its '%s' section" % (AGENT, SYMBOLS)]
    parsed, problem = _example(body)
    if problem:
        return [problem]
    if not isinstance(parsed.get("files"), list) or not isinstance(parsed.get("symbols"), dict):
        return ["the Declared symbols example must carry both files and symbols"]
    if not parsed["symbols"]:
        return ["the Declared symbols example declares no symbol"]
    if len(parsed["symbols"]) >= len(parsed["files"]):
        return ["the Declared symbols example leaves no file as a whole-file claim"]
    story = {"implementation": {"files": parsed["files"], "symbols": parsed["symbols"]}}
    return ["implementation_symbol_findings: %s" % f for f in T.implementation_symbol_findings(story)]


CHECKS = (
    check_rules_section,
    check_template_shows_symbols,
    check_ownership_row_names_symbols,
    check_example_is_accepted,
)


@pytest.mark.parametrize("check", CHECKS, ids=lambda c: c.__name__)
def test_check_is_clean_on_the_shipped_tree(check):
    assert check(load_corpus()) == []


def _damaged_by(mutate):
    corpus = load_corpus()
    corpus[AGENT] = mutate(corpus[AGENT])
    return corpus


def _replace(old, new):
    def mutate(text):
        assert old in text, "the damage no longer applies: %r" % old
        return text.replace(old, new, 1)

    return mutate


def _remove_section(text):
    body = section(text, SYMBOLS)
    assert body is not None
    return text.replace(body, "", 1)


def _move_section_after_citations(text):
    body = section(text, SYMBOLS)
    assert body is not None
    return text.replace(body, "", 1).rstrip("\n") + "\n\n" + body


def _drop_template_key(text):
    out = [l for l in text.split("\n") if not l.lstrip().startswith('"symbols": {"<path')]
    assert len(out) < len(text.split("\n"))
    return "\n".join(out)


@pytest.mark.parametrize(
    "check, mutate",
    [
        (check_rules_section, _remove_section),
        (check_rules_section, _move_section_after_citations),
        (check_rules_section, _replace("whole-file claim", "claim")),
        (check_rules_section, _replace("no key and no pseudo-symbol", "a key")),
        (check_rules_section, _replace("case-sensitive", "loose")),
        (check_rules_section, _replace("old name under `edits`", "old name")),
        (check_rules_section, _replace("no whitespace, no shell metacharacters", "any characters")),
        (check_rules_section, _replace("Always write the key", "Write the key when useful")),
        (check_template_shows_symbols, _drop_template_key),
        (check_ownership_row_names_symbols, _replace("`implementation.symbols` and `verify`", "and `verify`")),
        (check_example_is_accepted, _remove_section),
        (check_example_is_accepted, _replace('"creates": ["test_invoice_totals_round_up"]', '"creates": ["round up total"]')),
        (check_example_is_accepted, _replace('"src/billing/invoice.test.ts": {"creates"', '"src/billing/other.ts": {"creates"')),
    ],
    ids=[
        "section-removed",
        "section-moved-outside-the-followed-range",
        "whole-file-claim-rule-removed",
        "pseudo-symbol-rule-removed",
        "exact-name-rule-removed",
        "rename-rule-removed",
        "identity-rules-removed",
        "always-present-key-rule-removed",
        "template-key-removed",
        "ownership-row-not-naming-symbols",
        "example-section-removed",
        "example-name-with-whitespace",
        "example-key-not-in-files",
    ],
)
def test_checks_go_red_on_broken_copy(check, mutate):
    corpus = _damaged_by(mutate)
    assert check(corpus), "the check stayed green on damage it exists for"
