"""Structural pin on the `/aimi:plan` wiring: the audit stays mandatory and the router stays complete.

Two things used to be able to rot without any test noticing. The Phase 3d.5
audit could be reworded back into something optional, or the `story-merge`
call could grow a flag that lets a plan skip the audit gate. And `plan.md`,
now a router, could gain a `references/plan/*.md` phase file that nothing
tells the model to read, or lose the rule that a compacted conversation
re-reads the phase it was in.

Each check below is a function over a CORPUS dict, `{path relative to
commands/: text}`, and returns a list of problem strings; empty means the
corpus is fine. A check never reads the disk itself, which is what lets
`test_checks_go_red_on_broken_copy` hand the same functions a mutated copy and
prove each one fails on exactly the damage it exists for. The direct tests run
the checks over `plan_text.load_corpus()`, i.e. the shipped tree, or whatever
commands directory `AIMI_PLAN_WIRING_ROOT` names:

    AIMI_PLAN_WIRING_ROOT=/path/to/commands python3 -m pytest test_plan_wiring.py

Shape copied from hooks/tests/test_auto_approve_cli.py::
test_every_resolution_line_in_commands_is_approved: derive the checked set
from the tree and fail naming the offender.
"""

import re
import shutil

import pytest

import plan_text
from plan_text import (
    COMMANDS_DIR,
    REFERENCES_PREFIX,
    ROOT_ENV,
    ROUTER_KEY,
    commands_dir,
    fenced_blocks,
    heading_slices,
    load_corpus,
    scan_lines,
    section_lines,
)

# ---------------------------------------------------------------------------
# Constants the checks share
# ---------------------------------------------------------------------------

PHASE_3D5_TITLE = r"^Phase 3d\.5\b"
PHASE_3D5_FILE = re.compile(r"^references/plan/phase-3d5-[^/]*\.md$")
OPTIONAL_WORD = re.compile(r"\boptionally\b", re.IGNORECASE)
REQUIRED_3D5_LITERALS = ("apply-audit-patches", "--annotate-deferred")

# A story-merge flag that names the audit, or one of these, is a way past the gate.
GATE_ESCAPE_DENYLIST = {
    "--skip-audit",
    "--no-audit",
    "--audit-optional",
    "--no-gate",
    "--skip-gate",
    "--allow-unaudited",
}
STORY_MERGE_CALL = re.compile(
    r"(?:\$\{?AIMI_CLI\}?|aimi-cli(?:\.sh)?)[\"']?\s+story-merge(?![\w-])"
)
FLAG = re.compile(r"(?<![\w-])--[A-Za-z][\w-]*")

CONDITION_WORDS = re.compile(r"\b(when|if|applies|only|skip|unless)\b", re.IGNORECASE)
COMPACTION_SENTENCE_SPLIT = re.compile(r"(?<=[.!?])\s+")
REREAD = re.compile(r"\bre-?read\b", re.IGNORECASE)
COMPACTION = re.compile(r"\bcompaction\b", re.IGNORECASE)


def _reference_names(corpus):
    return sorted(k for k in corpus if k.startswith(REFERENCES_PREFIX))


# ---------------------------------------------------------------------------
# The five checks. Corpus in, list of problems out.
# ---------------------------------------------------------------------------


def phase_3d5_slice(corpus):
    """The Phase 3d.5 text: the router's section plus the whole of every phase-3d5-*.md.

    Located by heading, never by line number. Any other file carrying a
    `Phase 3d.5` heading contributes that heading's section (heading line
    included). The apply-gate file may not repeat the phase heading at all,
    which is why a `phase-3d5-*.md` is taken whole.
    """
    parts = []
    for name in sorted(corpus):
        text = corpus[name]
        if PHASE_3D5_FILE.match(name):
            parts.append(text)
        else:
            parts.extend(heading_slices(text, PHASE_3D5_TITLE))
    return "\n".join(parts)


def _phase_3d5_chunks(corpus):
    """[(file, chunk)] the Phase 3d.5 text is made of, as phase_3d5_slice() assembles it."""
    chunks = []
    for name in sorted(corpus):
        if PHASE_3D5_FILE.match(name):
            chunks.append((name, corpus[name]))
        else:
            chunks.extend((name, c) for c in heading_slices(corpus[name], PHASE_3D5_TITLE))
    return chunks


def check_phase_3d5_no_optional_wording(corpus):
    chunks = _phase_3d5_chunks(corpus)
    if not chunks:
        return ["no heading matching 'Phase 3d.5' and no phase-3d5-*.md, so the audit text was not found"]
    return [
        "%s: Phase 3d.5 text says 'optionally': %s" % (name, line.strip()[:120])
        for name, chunk in chunks
        for line in chunk.split("\n")
        if OPTIONAL_WORD.search(line)
    ]


def check_phase_3d5_names_apply_audit_patches_and_deferred_flag(corpus):
    text = phase_3d5_slice(corpus)
    if not text.strip():
        return ["Phase 3d.5 text not found: no heading and no phase-3d5-*.md in the corpus"]
    return [
        "Phase 3d.5 text never names %s" % literal
        for literal in REQUIRED_3D5_LITERALS
        if literal not in text
    ]


def _story_merge_flags(body):
    """Flags of every story-merge invocation in a block body (continuations followed)."""
    lines = body.split("\n")
    flags = []
    i = 0
    while i < len(lines):
        if lines[i].lstrip().startswith("#"):
            i += 1
            continue
        m = STORY_MERGE_CALL.search(lines[i])
        if not m:
            i += 1
            continue
        call = lines[i][m.start():]
        while call.rstrip().endswith("\\") and i + 1 < len(lines):
            i += 1
            call += "\n" + lines[i]
        flags.extend(FLAG.findall(call))
        i += 1
    return flags


def check_story_merge_call_carries_no_gate_escape(corpus):
    problems = []
    staged = 0
    for name in sorted(corpus):
        for _info, body in fenced_blocks(corpus[name]):
            flags = _story_merge_flags(body)
            if "--staging-dir" in flags:
                staged += 1
            for flag in flags:
                if "audit" in flag.lower() or flag in GATE_ESCAPE_DENYLIST:
                    problems.append("%s: story-merge call carries %s" % (name, flag))
    if staged == 0:
        problems.append("no fenced block invokes story-merge with --staging-dir, so the scan saw nothing")
    return problems


def check_every_plan_reference_has_condition_and_read_line(corpus):
    refs = _reference_names(corpus)
    if not refs:
        return ["no references/plan/*.md in the corpus"]
    if ROUTER_KEY not in corpus:
        return ["no plan.md in the corpus"]
    router = corpus[ROUTER_KEY]
    scanned = scan_lines(router)
    problems = []
    for ref in refs:
        base = ref[len(REFERENCES_PREFIX):]
        read_line = re.compile(r"Read .*references/plan/%s in full" % re.escape(base))
        hits = [i for i, (line, in_fence) in enumerate(scanned) if not in_fence and read_line.search(line)]
        if not hits:
            problems.append("%s: plan.md has no 'Read ... references/plan/%s in full' line" % (base, base))
            continue
        section = section_lines(router, hits[0])
        read_text = scanned[hits[0]][0]
        in_section = {
            line for line, in_fence in scan_lines("\n".join(section)) if not in_fence
        }
        others = [
            line for line in in_section
            if line.strip() and line != read_text and CONDITION_WORDS.search(line)
        ]
        if not others:
            problems.append("%s: its router entry has no separate line stating when the phase applies" % base)
    return problems


def check_plan_md_carries_reread_after_compaction_rule(corpus):
    if ROUTER_KEY not in corpus:
        return ["no plan.md in the corpus"]
    for line, in_fence in scan_lines(corpus[ROUTER_KEY]):
        if in_fence:
            continue
        for sentence in COMPACTION_SENTENCE_SPLIT.split(line):
            if REREAD.search(sentence) and COMPACTION.search(sentence):
                return []
    return ["plan.md has no single sentence naming both the re-read and the compaction"]


CHECKS = {
    "optional": check_phase_3d5_no_optional_wording,
    "names": check_phase_3d5_names_apply_audit_patches_and_deferred_flag,
    "story_merge": check_story_merge_call_carries_no_gate_escape,
    "router": check_every_plan_reference_has_condition_and_read_line,
    "compaction": check_plan_md_carries_reread_after_compaction_rule,
}


# ---------------------------------------------------------------------------
# The shipped tree (or AIMI_PLAN_WIRING_ROOT)
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def corpus():
    return load_corpus()


def _assert_clean(problems):
    assert not problems, "\n".join(problems)


def test_phase_3d5_has_no_optional_wording(corpus):
    _assert_clean(check_phase_3d5_no_optional_wording(corpus))


def test_phase_3d5_names_apply_audit_patches_and_deferred_flag(corpus):
    _assert_clean(check_phase_3d5_names_apply_audit_patches_and_deferred_flag(corpus))


def test_story_merge_call_carries_no_gate_escape(corpus):
    _assert_clean(check_story_merge_call_carries_no_gate_escape(corpus))


def test_every_plan_reference_has_condition_and_read_line(corpus):
    _assert_clean(check_every_plan_reference_has_condition_and_read_line(corpus))


def test_plan_md_carries_reread_after_compaction_rule(corpus):
    _assert_clean(check_plan_md_carries_reread_after_compaction_rule(corpus))


# ---------------------------------------------------------------------------
# The checks must be able to fail: five damaged copies, one targeted check each
# ---------------------------------------------------------------------------

DELETED_READ_BASENAME = "phase-2-5-spec-flow-gap-gate.md"
COMPACTION_SENTENCE = (
    "**When the conversation resumes after a context compaction, re-read the current "
    "phase's file before continuing.**"
)


def _rewrite(path, fn):
    text = path.read_text(encoding="utf-8")
    new = fn(text)
    assert new != text, "mutation changed nothing in %s" % path
    path.write_text(new, encoding="utf-8")


def _mutate_optional(root):
    for path in [root / "plan.md", *(root / "references" / "plan").glob("*.md")]:
        text = path.read_text(encoding="utf-8")
        new = re.sub(r"(?m)^(#+ Phase 3d\.5.*)$", r"\1 optionally", text)
        if new != text:
            path.write_text(new, encoding="utf-8")


def _mutate_skip_audit(root):
    _rewrite(
        root / "references" / "plan" / "phase-3e-story-merge.md",
        lambda t: t.replace('  --staging-dir "$RUN_DIR" \\\n', '  --staging-dir "$RUN_DIR" \\\n  --skip-audit \\\n', 1),
    )


def _mutate_delete_read_line(root):
    pattern = re.compile(r"(?m)^.*references/plan/%s in full.*\n" % re.escape(DELETED_READ_BASENAME))
    _rewrite(root / "plan.md", lambda t: pattern.sub("", t, count=1))


def _mutate_orphan_reference(root):
    (root / "references" / "plan" / "zz-orphan-phase.md").write_text(
        "# Plan: orphan\n\nNothing in plan.md points here.\n", encoding="utf-8"
    )


def _mutate_delete_compaction(root):
    _rewrite(root / "plan.md", lambda t: t.replace(COMPACTION_SENTENCE, "", 1))


MUTATIONS = {
    "optionally-in-3d5-heading": (_mutate_optional, "optional"),
    "skip-audit-flag-on-story-merge": (_mutate_skip_audit, "story_merge"),
    "read-line-deleted": (_mutate_delete_read_line, "router"),
    "orphan-reference-file": (_mutate_orphan_reference, "router"),
    "compaction-sentence-deleted": (_mutate_delete_compaction, "compaction"),
}


def _copy_of_shipped_commands(tmp_path):
    """A copy of the plugin's own commands/ (never AIMI_PLAN_WIRING_ROOT) holding just the plan files."""
    dest = tmp_path / "commands"
    (dest / "references").mkdir(parents=True)
    shutil.copy2(COMMANDS_DIR / ROUTER_KEY, dest / ROUTER_KEY)
    shutil.copytree(COMMANDS_DIR / "references" / "plan", dest / "references" / "plan")
    return dest


def test_shipped_tree_is_clean_for_every_check(tmp_path):
    """The baseline the mutation test leans on: an unmutated copy of the shipped tree has no problems."""
    corpus = load_corpus(_copy_of_shipped_commands(tmp_path))
    assert {name: check(corpus) for name, check in CHECKS.items()} == {name: [] for name in CHECKS}


@pytest.mark.parametrize("mutation", sorted(MUTATIONS))
def test_checks_go_red_on_broken_copy(mutation, tmp_path):
    mutate, targeted = MUTATIONS[mutation]
    root = _copy_of_shipped_commands(tmp_path)
    mutate(root)
    results = {name: check(load_corpus(root)) for name, check in CHECKS.items()}
    assert results[targeted], "%s did not turn the %s check red" % (mutation, targeted)
    others = {name: problems for name, problems in results.items() if name != targeted and problems}
    assert not others, "%s also turned other checks red: %s" % (mutation, others)


def test_load_corpus_on_copy_equals_the_real_corpus(tmp_path):
    copy = _copy_of_shipped_commands(tmp_path)
    real = load_corpus(COMMANDS_DIR)
    assert load_corpus(copy) == real
    assert ROUTER_KEY in real and _reference_names(real)


def test_commands_dir_honours_the_override(monkeypatch, tmp_path):
    monkeypatch.delenv(ROOT_ENV, raising=False)
    assert commands_dir() == COMMANDS_DIR
    monkeypatch.setenv(ROOT_ENV, str(tmp_path))
    assert commands_dir() == tmp_path
    assert plan_text.load_corpus() == {}


# ---------------------------------------------------------------------------
# The structure readers the checks lean on
# ---------------------------------------------------------------------------


def test_a_hash_inside_a_fence_is_not_a_heading():
    text = "## Phase 3d.5: Real\nbody\n```bash\n## Phase 3d.5: Fake\n```\nmore\n## Next\n"
    slices = heading_slices(text, PHASE_3D5_TITLE)
    assert len(slices) == 1
    assert slices[0].startswith("## Phase 3d.5: Real") and "more" in slices[0] and "Next" not in slices[0]


def test_a_slice_keeps_its_subsections_and_stops_at_the_next_peer():
    text = "## A\n### sub\ntext\n## B\nother\n"
    assert heading_slices(text, r"^A$") == ["## A\n### sub\ntext"]
    assert section_lines(text, 2) == ["### sub", "text"]
    assert fenced_blocks("x\n```bash\nls\n```\n") == [("bash", "ls")]
