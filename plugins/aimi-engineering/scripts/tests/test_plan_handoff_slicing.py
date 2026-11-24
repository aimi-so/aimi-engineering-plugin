"""Structural pin on the per-entry slicing of a kit handoff document in `/aimi:plan` Phase 3d.

Phase 0 wraps the whole handoff documents for Phase 1. Pass 2 hands each story
expander only the heading sections its outline entry draws on
(`prototypeHandoffSectionBlock`), plus every handoff path for on-demand reading.
What can rot without a test noticing: the new reference losing one of its four
steps, its CLI resolution lines drifting from the ones the auto-approve hook
matches, the router losing the entry or moving it, the expander template going
back to the whole block, the context-files table forgetting the new inline
block, and the new variable leaking into a file that should not name it.

Each check is a function over a corpus dict `{path relative to the plugin root:
text}` and returns a list of problems, empty when fine, so
`test_checks_go_red_on_broken_copy` can hand the same functions a damaged copy.
"""

import re
import shutil
import subprocess

import pytest

import plan_text

PLAN_DIR = "commands/references/plan/"
HANDOFF = PLAN_DIR + "phase-3d-handoff-blocks.md"
PREP = PLAN_DIR + "phase-3d-prep-blocks.md"
TEMPLATE = PLAN_DIR + "phase-3d-expander-prompt.md"
CONTEXT = PLAN_DIR + "phase-3d-context-files.md"
PHASE_0 = PLAN_DIR + "phase-0-brainstorm-reuse.md"
PHASE_1 = PLAN_DIR + "phase-1-local-research.md"
ROUTER = "commands/plan.md"
BASELINE = "scripts/command-size-baseline.txt"

VARIABLE = "prototypeHandoffSectionBlock"
# The commit this story forked from: the tree the Phase 0 sentence is compared with.
FORK_POINT = "cd0e9de"
PHASE_0_SENTENCE = "No metadata field records them, so `tasks.py` and `archive-task` never see these paths."
DEFAULT_CEILING = 16384
RESOLUTION_LINES = 2


def load_corpus():
    root = plan_text.ROOT
    corpus = {}
    for path in plan_text.plan_files():
        corpus[path.relative_to(root).as_posix()] = path.read_text(encoding="utf-8")
    corpus[BASELINE] = (root / BASELINE).read_text(encoding="utf-8")
    return corpus


def _resolution_lines(text):
    lines = [ln for ln in text.split("\n") if ln.startswith("AIMI_CLI=$(cat ") or ln.startswith(': "${AIMI_CLI:?')]
    return lines[:RESOLUTION_LINES]


def check_reference_states_the_four_steps(corpus):
    text = corpus.get(HANDOFF)
    if text is None:
        return ["%s is missing" % HANDOFF]
    problems = []
    for literal in (
        "**Step 1",
        "**Step 2",
        "**Step 3",
        "**Step 4",
        "setext",
        "level 1",
        "front matter",
        "fenced code block",
        "Sanitize every selected anchor",
        "replace newlines/CRs with spaces",
        "remove every `$`",
        "remove backtick characters",
        "remove `\"` and `\\` characters",
        "truncate to 200 characters",
        "--anchors",
        "--all-headings",
        "newline-joined",
        "`&lt;/prototype_handoff`",
        "`&lt;prototype_handoff`",
        '<prototype_handoff path="',
        "20 KB",
        "…[truncated; original is intact on disk]",
        "Slice from the files, never from the Phase 0 blocks",
        "prototypeHandoffPaths",
        VARIABLE,
    ):
        if literal not in text:
            problems.append("%s never says %s" % (HANDOFF, literal))
    if "extract-sections" not in text:
        problems.append("%s never names extract-sections" % HANDOFF)
    if not re.search(r"extract-sections \"<file path>\" --anchors \"[^\"]+\" --all-headings", text):
        problems.append("%s lost the extract-sections --all-headings call" % HANDOFF)
    if "user-communication.md" not in text:
        problems.append("%s lost the Artifact Language anchor" % HANDOFF)
    return problems


def check_resolution_lines_match_the_research_block(corpus):
    handoff = _resolution_lines(corpus.get(HANDOFF, ""))
    prep = _resolution_lines(corpus.get(PREP, ""))
    if len(handoff) != RESOLUTION_LINES:
        return ["%s does not carry the two AIMI_CLI resolution lines" % HANDOFF]
    if handoff != prep:
        return ["%s: the AIMI_CLI resolution lines differ from %s" % (HANDOFF, PREP)]
    return []


def check_headingless_and_empty_cases(corpus):
    text = corpus.get(HANDOFF, "")
    problems = []
    if "no heading of any kind" not in text:
        problems.append("%s lost the headingless-file case" % HANDOFF)
    if "goes **whole**" not in text or "50 KB aggregate cap" not in text:
        problems.append("%s: a headingless file no longer goes whole within the 50 KB aggregate cap" % HANDOFF)
    if "gives that entry no slice of it" not in text:
        problems.append("%s lost the no-match-gives-no-slice case" % HANDOFF)
    if "every expander also receives every path of `prototypeHandoffPaths`" not in text:
        problems.append("%s lost the rule that every entry still receives the paths" % HANDOFF)
    return problems


def check_router_entry(corpus):
    router = corpus.get(ROUTER, "")
    protos = router.find("phase-3d-prototype-blocks.md")
    handoff = router.find("phase-3d-handoff-blocks.md")
    ctx = router.find("phase-3d-context-files.md")
    if handoff < 0:
        return ["plan.md has no entry for phase-3d-handoff-blocks.md"]
    if not (0 <= protos < handoff < ctx):
        return ["plan.md: the handoff entry is not between the prototype-blocks and context-files entries"]
    section = router[router.rfind("### ", 0, handoff):handoff]
    problems = []
    if "Applies when:" not in section or "prototypeHandoffPaths" not in section or "non-empty" not in section:
        problems.append("plan.md: the handoff entry has no Applies when: line gated on prototypeHandoffPaths being non-empty")
    if "phase-3d-handoff-blocks.md in full" not in router:
        problems.append("plan.md: the handoff entry has no 'Read ... in full' line")
    return problems


def check_template_renders_the_section_block(corpus):
    text = corpus.get(TEMPLATE, "")
    problems = []
    if "[%s]" % VARIABLE not in text:
        problems.append("%s no longer renders [%s]" % (TEMPLATE, VARIABLE))
    if "[prototypeHandoffBlocks]" in text:
        problems.append("%s still renders the whole [prototypeHandoffBlocks]" % TEMPLATE)
    if "Prototype handoff paths available for on-demand reading" not in text:
        problems.append("%s lost the handoff path list" % TEMPLATE)
    line = text[text.find("Prototype handoff paths available"):]
    line = line[: line.find("[prototypeHandoffPaths")]
    if "section excerpt is insufficient" not in line:
        problems.append("%s: the on-demand line no longer says to Read the full file when the section excerpt is insufficient" % TEMPLATE)
    return problems


def check_context_files_keeps_it_inline(corpus):
    text = corpus.get(CONTEXT, "")
    problems = []
    if "`%s`" % VARIABLE not in text:
        problems.append("%s does not name %s among the inline blocks" % (CONTEXT, VARIABLE))
    if "prototypeHandoffBlocks" in text:
        problems.append("%s still names the whole prototypeHandoffBlocks" % CONTEXT)
    inline = text[text.find("These stay inline"):]
    inline = inline[: inline.find("\n")]
    if "path list" not in inline:
        problems.append("%s: the inline sentence lost the handoff path list" % CONTEXT)
    return problems


def check_phase_1_still_reads_the_whole_block(corpus):
    text = corpus.get(PHASE_1, "")
    if "[prototypeHandoffBlocks]" not in text:
        return ["%s no longer hands Phase 1 researchers the whole [prototypeHandoffBlocks]" % PHASE_1]
    return []


def check_phase_0_points_at_pass_2(corpus):
    text = corpus.get(PHASE_0, "")
    if "phase-3d-handoff-blocks.md" not in text:
        return ["%s has no pointer to phase-3d-handoff-blocks.md" % PHASE_0]
    return []


def check_variable_is_named_only_where_it_is_built_or_read(corpus):
    allowed = {HANDOFF, TEMPLATE, CONTEXT}
    problems = []
    for name, text in sorted(corpus.items()):
        if name == BASELINE:
            continue
        named = VARIABLE in text
        if named and name not in allowed:
            problems.append("%s names %s, which only the handoff, template and context-files files need" % (name, VARIABLE))
        if not named and name in allowed:
            problems.append("%s does not name %s" % (name, VARIABLE))
    return problems


def _budget_of(baseline, relpath):
    for line in baseline.split("\n"):
        fields = line.split("\t")
        if len(fields) >= 2 and fields[0] == relpath:
            return int(fields[1].strip())
    return None


def check_files_stay_inside_their_budgets(corpus):
    problems = []
    baseline = corpus.get(BASELINE, "")
    router_size = len(corpus.get(ROUTER, "").encode("utf-8"))
    budget = _budget_of(baseline, "plan.md")
    if budget is None:
        problems.append("%s has no budget line for plan.md" % BASELINE)
    elif router_size > budget:
        problems.append("plan.md is %d bytes, over its %d budget" % (router_size, budget))
    for name in (HANDOFF, TEMPLATE, CONTEXT, PHASE_0):
        size = len(corpus.get(name, "").encode("utf-8"))
        if size > DEFAULT_CEILING and _budget_of(baseline, name[len("commands/"):]) is None:
            problems.append("%s is %d bytes, over the shared ceiling with no budget line" % (name, size))
    return problems


CHECKS = (
    check_reference_states_the_four_steps,
    check_resolution_lines_match_the_research_block,
    check_headingless_and_empty_cases,
    check_router_entry,
    check_template_renders_the_section_block,
    check_context_files_keeps_it_inline,
    check_phase_1_still_reads_the_whole_block,
    check_phase_0_points_at_pass_2,
    check_variable_is_named_only_where_it_is_built_or_read,
    check_files_stay_inside_their_budgets,
)


@pytest.mark.parametrize("check", CHECKS, ids=lambda c: c.__name__)
def test_check_is_clean_on_the_shipped_tree(check):
    assert check(load_corpus()) == []


def _damaged(mutate):
    corpus = load_corpus()
    mutate(corpus)
    return corpus


def _replace(name, old, new):
    def mutate(corpus):
        assert old in corpus[name], "%s does not contain %r" % (name, old)
        corpus[name] = corpus[name].replace(old, new)

    return mutate


@pytest.mark.parametrize(
    "check, mutate",
    [
        (check_reference_states_the_four_steps, _replace(HANDOFF, "--all-headings", "--x")),
        (check_reference_states_the_four_steps, _replace(HANDOFF, "setext", "other")),
        (check_reference_states_the_four_steps, _replace(HANDOFF, "front matter", "preamble")),
        (check_reference_states_the_four_steps, _replace(HANDOFF, "`&lt;/prototype_handoff`", "`x`")),
        (check_reference_states_the_four_steps, _replace(HANDOFF, "20 KB", "30 KB")),
        (check_reference_states_the_four_steps, _replace(HANDOFF, "remove every `$`", "keep every `$`")),
        (check_reference_states_the_four_steps, _replace(HANDOFF, "never from the Phase 0 blocks", "from the Phase 0 blocks")),
        (check_resolution_lines_match_the_research_block, _replace(HANDOFF, ': "${AIMI_CLI:?AIMI_CLI is empty', ': "${AIMI_CLI:?AIMI_CLI is unset')),
        (check_headingless_and_empty_cases, _replace(HANDOFF, "no heading of any kind", "no heading")),
        (check_headingless_and_empty_cases, _replace(HANDOFF, "gives that entry no slice of it", "is an error")),
        (check_headingless_and_empty_cases, _replace(HANDOFF, "every expander also receives every path of `prototypeHandoffPaths`", "an expander may receive a path")),
        (check_router_entry, _replace(ROUTER, "phase-3d-handoff-blocks.md", "phase-3d-other.md")),
        (check_router_entry, _replace(ROUTER, "Applies when: `prototypeHandoffPaths` is non-empty", "Applies when: every run")),
        (check_router_entry, _replace(ROUTER, "phase-3d-handoff-blocks.md in full", "phase-3d-handoff-blocks.md")),
        (check_template_renders_the_section_block, _replace(TEMPLATE, "[%s]" % VARIABLE, "[prototypeHandoffBlocks]")),
        (check_template_renders_the_section_block, _replace(TEMPLATE, "section excerpt is insufficient", "block is truncated")),
        (check_context_files_keeps_it_inline, _replace(CONTEXT, "`%s`" % VARIABLE, "`prototypeHandoffBlocks`")),
        (check_phase_1_still_reads_the_whole_block, _replace(PHASE_1, "[prototypeHandoffBlocks]", "[x]")),
        (check_phase_0_points_at_pass_2, _replace(PHASE_0, "phase-3d-handoff-blocks.md", "x.md")),
        (check_variable_is_named_only_where_it_is_built_or_read, lambda c: c.__setitem__(PHASE_1, c[PHASE_1] + "\n" + VARIABLE)),
        (check_variable_is_named_only_where_it_is_built_or_read, _replace(CONTEXT, VARIABLE, "x")),
        (check_files_stay_inside_their_budgets, lambda c: c.__setitem__(ROUTER, c[ROUTER] + "x" * 30000)),
        (check_files_stay_inside_their_budgets, lambda c: c.__setitem__(HANDOFF, c[HANDOFF] + "x" * 17000)),
    ],
)
def test_checks_go_red_on_broken_copy(check, mutate):
    assert check(_damaged(mutate)), "the check stayed green on damage it exists for"


# ---------------------------------------------------------------------------
# The Phase 0 sentence about handoff paths stays as this story found it.
# ---------------------------------------------------------------------------


def phase_0_sentence_problems(fork_text, current_text):
    """Compare the Phase 0 file with this story's fork point, never with a fixed count.

    The sentence must be present byte for byte. The one allowed departure is a
    later story that records the paths in metadata and so replaces the sentence:
    then the file must say where the paths are recorded.
    """
    if PHASE_0_SENTENCE not in fork_text:
        return ["the fork point's Phase 0 file does not carry the sentence; FORK_POINT is wrong"]
    if PHASE_0_SENTENCE in current_text:
        return []
    if "metadata.prototypeHandoffPaths" in current_text:
        return []
    return ["%s lost the sentence about handoff paths that the fork point carries" % PHASE_0]


def _fork_point_phase_0():
    if shutil.which("git") is None:
        return None
    result = subprocess.run(
        ["git", "show", "%s:plugins/aimi-engineering/%s" % (FORK_POINT, PHASE_0)],
        cwd=str(plan_text.ROOT),
        capture_output=True,
        text=True,
    )
    return result.stdout if result.returncode == 0 else None


def test_phase_0_sentence_is_untouched_against_the_fork_point():
    fork_text = _fork_point_phase_0()
    if fork_text is None:
        pytest.skip("the fork point %s is not reachable from this checkout" % FORK_POINT)
    assert phase_0_sentence_problems(fork_text, load_corpus()[PHASE_0]) == []


def test_phase_0_sentence_check_goes_red_on_a_rewritten_sentence():
    fork_text = "x\n" + PHASE_0_SENTENCE + "\n"
    assert phase_0_sentence_problems(fork_text, "x\nNo metadata field records them.\n")
    assert phase_0_sentence_problems(fork_text, "x\n" + PHASE_0_SENTENCE + " Pass 2 slices them.\n") == []
    assert phase_0_sentence_problems(fork_text, "x\nmetadata.prototypeHandoffPaths records them.\n") == []
