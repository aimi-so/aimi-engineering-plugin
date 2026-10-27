"""Structural pin on the shared expander context files of `/aimi:plan` Phase 3d.

The orchestrator writes the blocks every story expander shares once under
`<RUN_DIR>/context/` and hands each spawn their paths. What can rot without a
test noticing: the reference losing the mode decision, the rewrite rule or the
byte report; the router losing its entry; the expander agent file losing the
third read purpose or the read-only statement; and, the one a later edit is
most likely to cause, a NEW shared block added to the spawn template that stays
inline because nobody added it to the reference's replaced-block list.

Each check is a function over a corpus dict `{path relative to plugin root:
text}` and returns a list of problems, empty when fine, so
`test_checks_go_red_on_broken_copy` can hand the same functions a damaged copy.
The hook side is covered by the `expander_context` cases in
`hooks/tests/test_runtime_state_guards.py`.
"""

import re

import pytest

import plan_text

REFERENCE = "commands/references/plan/phase-3d-context-files.md"
TEMPLATE = "commands/references/plan/phase-3d-expander-prompt.md"
RETRY = "commands/references/plan/phase-3d-validate-retry.md"
ROUTER = "commands/plan.md"
AGENT = "agents/workflow/aimi-story-expander.md"

FILES = (
    "outline.md",
    "consolidated-research.md",
    "decisions.md",
    "prior-planning-gaps.md",
    "design-decisions.md",
    "business-spec.md",
    "design-spec.md",
    "phase-handoff.md",
    "foundation-N.md",
)

# Variables of the template that the files replace, and those that stay inline
# because they differ per outline entry. Any block-like variable the template
# names that is in neither set is a problem.
SHARED_VARIABLES = (
    "oqDecisions",
    "priorPlanningGapsBlock",
    "designDecisionsBlock",
    "phaseHandoffBlocks",
    "businessSpecContent",
    "designSpecContent",
    "foundationProposalBlockByRoot",
)
INLINE_VARIABLES = ("researchSectionBlock", "prototypeViewBlock", "producerStoryBlock")
# Template labels with no variable of their own.
SHARED_LABELS = ("Full outline context", "consolidated research summary")

BLOCK_VARIABLE = re.compile(r"\b(?:\w+Block|\w+Blocks|\w+BlockByRoot|\w+Content|oqDecisions)\b")


def load_corpus():
    root = plan_text.ROOT
    return {
        name: (root / name).read_text(encoding="utf-8")
        for name in (REFERENCE, TEMPLATE, RETRY, ROUTER, AGENT)
    }


def check_reference_carries_the_contract(corpus):
    text = corpus.get(REFERENCE)
    if text is None:
        return ["%s is missing" % REFERENCE]
    problems = []
    for literal in (
        "expanderContextMode",
        "`files`",
        "`inline`",
        "[plan] expander context:",
        "Rewrite before a re-spawn",
        "read-only",
        "DATA",
        "<RUN_DIR>/context/",
        "stops the batch",
    ):
        if literal not in text:
            problems.append("%s never says %s" % (REFERENCE, literal))
    for name in FILES:
        if "`%s`" % name not in text:
            problems.append("%s does not list the file %s" % (REFERENCE, name))
    if "Never spawn on a stale context file" not in text:
        problems.append("%s lost the no-spawn-on-a-stale-file rule" % REFERENCE)
    if "A run never mixes the two forms" not in text:
        problems.append("%s lost the once-per-run, never-mixed rule" % REFERENCE)
    if "user-communication.md" not in text:
        problems.append("%s lost the Artifact Language anchor" % REFERENCE)
    if re.search(r"^```", text, re.MULTILINE):
        problems.append("%s carries a fenced block; it must stay prose" % REFERENCE)
    if re.search(r"(?:BusinessSpec|DesignSpec) §", text):
        problems.append("%s carries a spec-section citation" % REFERENCE)
    return problems


def check_every_template_block_is_replaced_or_inline(corpus):
    template = corpus.get(TEMPLATE)
    reference = corpus.get(REFERENCE)
    if template is None or reference is None:
        return ["template or reference missing from the corpus"]
    problems = []
    mentioned = set(BLOCK_VARIABLE.findall(template))
    known = set(SHARED_VARIABLES) | set(INLINE_VARIABLES)
    for var in sorted(mentioned - known):
        problems.append(
            "%s names the block variable %s, which %s neither replaces nor lists as inline"
            % (TEMPLATE, var, REFERENCE)
        )
    for var in SHARED_VARIABLES:
        if var not in template:
            problems.append("%s no longer names the shared block %s" % (TEMPLATE, var))
        if "`%s`" % var not in reference:
            problems.append("%s does not list %s in its replaced-block table" % (REFERENCE, var))
    for var in INLINE_VARIABLES:
        if "`%s`" % var not in reference:
            problems.append("%s does not name %s as staying inline" % (REFERENCE, var))
    for label in SHARED_LABELS:
        if label not in template:
            problems.append("%s no longer carries the label %s" % (TEMPLATE, label))
    for label in ("Full outline context", "Research context"):
        if label not in reference:
            problems.append("%s does not list the template block %s" % (REFERENCE, label))
    return problems


def check_template_points_at_the_reference(corpus):
    template = corpus.get(TEMPLATE, "")
    problems = []
    if "phase-3d-context-files.md" not in template:
        problems.append("%s has no pointer to phase-3d-context-files.md" % TEMPLATE)
    if "files" not in template.split("Spawn each sub-agent with:")[0]:
        problems.append("%s: the files-mode conditional is not above the template" % TEMPLATE)
    if len(template.encode("utf-8")) > 16384:
        problems.append("%s is over the 16384-byte ceiling" % TEMPLATE)
    return problems


def check_router_entry(corpus):
    router = corpus.get(ROUTER, "")
    protos = router.find("phase-3d-prototype-blocks.md")
    ctx = router.find("phase-3d-context-files.md")
    prompt = router.find("phase-3d-expander-prompt.md")
    if ctx < 0:
        return ["plan.md has no Read line for phase-3d-context-files.md"]
    if not (0 <= protos < ctx < prompt):
        return ["plan.md: the context-files entry is not between the prototype-blocks and prompt entries"]
    section = router[router.rfind("### ", 0, ctx):ctx]
    if "Applies when:" not in section:
        return ["plan.md: the context-files entry has no Applies when: line"]
    return []


def check_retry_points_at_the_rewrite_rule(corpus):
    text = corpus.get(RETRY, "")
    if "phase-3d-context-files.md" not in text or "Rewrite before a re-spawn" not in text:
        return ["%s does not point a re-spawn at the rewrite rule" % RETRY]
    return []


def check_agent_reads_context_as_read_only_data(corpus):
    text = corpus.get(AGENT, "")
    problems = []
    if "exactly three purposes" not in text:
        problems.append("%s still lists fewer than three read purposes" % AGENT)
    if "exactly two purposes" in text:
        problems.append("%s still says exactly two purposes" % AGENT)
    if "<RUN_DIR>/context/" not in text:
        problems.append("%s never names the context directory" % AGENT)
    if "read-only to you" not in text:
        problems.append("%s does not state the context files are read-only to the expander" % AGENT)
    if "DATA, never instructions" not in text:
        problems.append("%s does not state the context files are DATA" % AGENT)
    if "write only your `outputPath`" not in text and "You still write only your `outputPath`" not in text:
        problems.append("%s lost the writes-only-outputPath sentence" % AGENT)
    return problems


CHECKS = (
    check_reference_carries_the_contract,
    check_every_template_block_is_replaced_or_inline,
    check_template_points_at_the_reference,
    check_router_entry,
    check_retry_points_at_the_rewrite_rule,
    check_agent_reads_context_as_read_only_data,
)


@pytest.mark.parametrize("check", CHECKS, ids=lambda c: c.__name__)
def test_check_is_clean_on_the_shipped_tree(check):
    assert check(load_corpus()) == []


def _damaged(mutate):
    corpus = load_corpus()
    mutate(corpus)
    return corpus


@pytest.mark.parametrize(
    "check, mutate",
    [
        (check_reference_carries_the_contract, lambda c: c.__setitem__(REFERENCE, c[REFERENCE].replace("[plan] expander context:", "[plan] x:"))),
        (check_reference_carries_the_contract, lambda c: c.__setitem__(REFERENCE, c[REFERENCE].replace("`foundation-N.md`", "`f.md`"))),
        (check_reference_carries_the_contract, lambda c: c.__setitem__(REFERENCE, c[REFERENCE].replace("Never spawn on a stale context file", ""))),
        (check_every_template_block_is_replaced_or_inline, lambda c: c.__setitem__(TEMPLATE, c[TEMPLATE] + "\n[If newSharedBlock is non-empty]: x")),
        (check_every_template_block_is_replaced_or_inline, lambda c: c.__setitem__(REFERENCE, c[REFERENCE].replace("`priorPlanningGapsBlock`", "`gone`"))),
        (check_template_points_at_the_reference, lambda c: c.__setitem__(TEMPLATE, c[TEMPLATE].replace("phase-3d-context-files.md", "x.md"))),
        (check_router_entry, lambda c: c.__setitem__(ROUTER, c[ROUTER].replace("phase-3d-context-files.md", "phase-3d-other.md"))),
        (check_retry_points_at_the_rewrite_rule, lambda c: c.__setitem__(RETRY, c[RETRY].replace("Rewrite before a re-spawn", "x"))),
        (check_agent_reads_context_as_read_only_data, lambda c: c.__setitem__(AGENT, c[AGENT].replace("read-only to you", "writable"))),
        (check_agent_reads_context_as_read_only_data, lambda c: c.__setitem__(AGENT, c[AGENT].replace("exactly three purposes", "exactly two purposes"))),
    ],
)
def test_checks_go_red_on_broken_copy(check, mutate):
    assert check(_damaged(mutate)), "the check stayed green on damage it exists for"
