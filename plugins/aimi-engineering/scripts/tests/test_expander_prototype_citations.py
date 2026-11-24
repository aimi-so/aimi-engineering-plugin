"""Structural pin on the story expander's prototype-citation and screen-url rules.

Two rules live in `agents/workflow/aimi-story-expander.md` and can rot without a
test noticing:

* `## Prototype citations` is gated on `prototypePaths` being non-empty and on
  nothing else: the duty to cite covers every criterion that restates prototype
  content, whatever the verification strategy. It keeps the view, heading and
  whole-file line-range forms with the line-range provenance rule and the
  `prototypeAnchor` rule, and takes the kind-tagged index entries spelled as
  `extract-prototype-sections` anchors are (`§id:`, `§tab:`, `§heading:`).
* A story that changes a screen sets `verification.url` (a `/`-prefixed path or
  a loopback url) whatever its strategy except `api`: stated under the
  `## Verification strategy` table, and not contradicted by the url placeholder
  of `## Single-story output shape`.

Each check is a function over a corpus dict `{path relative to plugin root:
text}` and returns a list of problems, empty when fine, so
`test_checks_go_red_on_broken_copy` can hand the same functions a damaged copy.
A section is found by its heading, so the checks follow the text when lines move.
"""

import re

import pytest

import plan_text

AGENT = "agents/workflow/aimi-story-expander.md"

CITATIONS = "## Prototype citations"
STRATEGY = "## Verification strategy"
SHAPE = "## Single-story output shape"

KIND_TAGS = ("§id:", "§tab:", "§heading:")


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


def check_citations_heading_is_not_gated_on_strategy(corpus):
    text = corpus.get(AGENT, "")
    body = section(text, CITATIONS)
    if body is None:
        return ["%s lost its '%s' section" % (AGENT, CITATIONS)]
    heading, _, rest = body.partition("\n")
    problems = []
    if "prototypePaths" not in heading:
        problems.append("the Prototype citations heading no longer requires prototypePaths")
    if "strategy" in heading or "visual" in heading:
        problems.append("the Prototype citations heading is gated on the verification strategy")
    if "whatever" not in rest or "verification strategy" not in rest:
        problems.append("Prototype citations does not state the duty holds whatever the verification strategy")
    if "restates prototype content" not in rest:
        problems.append("Prototype citations does not cover every criterion that restates prototype content")
    return problems


def check_citation_forms_are_kept(corpus):
    body = section(corpus.get(AGENT, ""), CITATIONS)
    if body is None:
        return ["%s lost its '%s' section" % (AGENT, CITATIONS)]
    problems = []
    for literal, what in (
        ("(prototype: <relative-path> §<view-name>)", "the view citation"),
        ("(prototype: <relative-path> §<heading-text>)", "the heading citation"),
        ("(prototype: <relative-path>:L<start>-L<end>)", "the whole-file line-range citation"),
        ("admissible ONLY when the numbers were counted over the whole file on disk", "the line-range provenance rule"),
        ("never over lines counted inside a `<prototype_html>` block", "the line-range provenance rule's exclusion"),
        ("set `implementation.prototypeAnchor` to that path", "the prototypeAnchor rule"),
        ("leave `prototypeAnchor` unset", "the prototypeAnchor rule's otherwise branch"),
    ):
        if literal not in body:
            problems.append("Prototype citations lost %s (%s)" % (what, literal))
    return problems


def check_kind_tagged_forms_are_named(corpus):
    body = section(corpus.get(AGENT, ""), CITATIONS)
    if body is None:
        return ["%s lost its '%s' section" % (AGENT, CITATIONS)]
    return [
        "Prototype citations does not name the kind-tagged form %s" % tag
        for tag in KIND_TAGS
        if tag not in body
    ]


def check_screen_url_rule(corpus):
    text = corpus.get(AGENT, "")
    problems = []
    body = section(text, STRATEGY)
    if body is None:
        return ["%s lost its '%s' section" % (AGENT, STRATEGY)]
    last_row = body.rfind("\n|")
    below = body[body.find("\n", last_row + 1):] if last_row != -1 else ""
    if "changes a screen" not in below or "`verification.url`" not in below:
        problems.append("Verification strategy does not state the screen-url rule below its table")
    for literal in ("`/`-prefixed path", "never `//`", "loopback", "except `api`"):
        if literal not in below:
            problems.append("the screen-url rule lost '%s'" % literal)
    if "whatever its strategy" not in below:
        problems.append("the screen-url rule is limited to one strategy")
    return problems


def check_url_placeholder_is_not_limited(corpus):
    body = section(corpus.get(AGENT, ""), SHAPE)
    if body is None:
        return ["%s lost its '%s' section" % (AGENT, SHAPE)]
    line = next((l for l in body.splitlines() if l.strip().startswith('"url"')), None)
    if line is None:
        return ["Single-story output shape lost its url placeholder"]
    problems = []
    if "visual/api" in line or "only for visual" in line:
        problems.append("the url placeholder is limited to visual and api again")
    if "changes a screen" not in line:
        problems.append("the url placeholder does not say a screen-changing story sets url")
    return problems


CHECKS = (
    check_citations_heading_is_not_gated_on_strategy,
    check_citation_forms_are_kept,
    check_kind_tagged_forms_are_named,
    check_screen_url_rule,
    check_url_placeholder_is_not_limited,
)


@pytest.mark.parametrize("check", CHECKS, ids=lambda c: c.__name__)
def test_check_is_clean_on_the_shipped_tree(check):
    assert check(load_corpus()) == []


def _damaged(old, new):
    corpus = load_corpus()
    assert old in corpus[AGENT], "the damage no longer applies: %r" % old
    corpus[AGENT] = corpus[AGENT].replace(old, new, 1)
    return corpus


def _damaged_by(mutate):
    corpus = load_corpus()
    corpus[AGENT] = mutate(corpus[AGENT])
    return corpus


def _drop_line_containing(needle):
    def mutate(text):
        lines = text.split("\n")
        kept = [l for l in lines if needle not in l]
        assert len(kept) < len(lines), "no line contains %r" % needle
        return "\n".join(kept)

    return mutate


def _regate_heading(text):
    old = "## Prototype citations (when prototypePaths non-empty)"
    assert old in text
    return text.replace(old, '## Prototype citations (when prototypePaths non-empty and verification.strategy == "visual")', 1)


def _strip_screen_url_rule(text):
    return _drop_line_containing("A story that changes a screen sets `verification.url`")(text)


def _limit_url_placeholder(text):
    old = "set on any story that changes a screen unless its strategy is api"
    assert old in text
    return text.replace(old, "only for visual/api", 1)


@pytest.mark.parametrize(
    "check, mutate",
    [
        (check_citations_heading_is_not_gated_on_strategy, _regate_heading),
        (check_citations_heading_is_not_gated_on_strategy, lambda t: t.replace("whatever the story's verification strategy", "for visual stories", 1)),
        (check_citation_forms_are_kept, _drop_line_containing("Line-range fallback")),
        (check_citation_forms_are_kept, lambda t: t.replace("admissible ONLY when the numbers were counted over the whole file on disk", "admissible", 1)),
        (check_citation_forms_are_kept, lambda t: t.replace("set `implementation.prototypeAnchor` to that path", "set nothing", 1)),
        (check_kind_tagged_forms_are_named, _drop_line_containing("Kind-tagged index entry")),
        (check_kind_tagged_forms_are_named, lambda t: t.replace("§id:", "§x:")),
        (check_kind_tagged_forms_are_named, lambda t: t.replace("§tab:", "§x:")),
        (check_kind_tagged_forms_are_named, lambda t: t.replace("§heading:", "§x:")),
        (check_screen_url_rule, _strip_screen_url_rule),
        (check_url_placeholder_is_not_limited, _limit_url_placeholder),
    ],
    ids=[
        "visual-gate-restored-on-heading",
        "duty-limited-to-visual-stories",
        "line-range-form-removed",
        "line-range-provenance-rule-removed",
        "prototypeanchor-rule-removed",
        "kind-tagged-form-removed",
        "id-tag-removed",
        "tab-tag-removed",
        "heading-tag-removed",
        "screen-url-rule-removed",
        "url-placeholder-limited-to-visual-api",
    ],
)
def test_checks_go_red_on_broken_copy(check, mutate):
    corpus = _damaged_by(mutate)
    assert check(corpus), "the check stayed green on damage it exists for"
