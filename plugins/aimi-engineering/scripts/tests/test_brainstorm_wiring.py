"""Structural pin on the `/aimi:brainstorm` wiring: the router and its files stay in step.

`commands/brainstorm.md` is a router. Each entry is a heading, an `Applies when:`
line (with the default for the skipped case beside it), an optional `Covers:`
line and one `Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/<file>.md
in full` line. The body of a step or phase lives in that file. What can rot
without any run noticing: a file nothing reads (an orphan), a Read line naming
a file that is gone, an entry that lost its condition, a file read by two
entries, the two sentences the router exists to carry (the re-read after
compaction and the STOP on a failed Read), a file that lost its header, the
order that puts interactivity, models and bundle detection before the first
research Task spawn, and the two `$ARGUMENTS` fences that must stay in the
command body.

Each check is a function over a CORPUS dict, `{path relative to commands/:
text}`, and returns a list of problem strings; empty means the corpus is fine.
A check never reads the disk itself (the arguments check only inspects text),
which is what lets `test_checks_go_red_on_broken_copy` hand the same functions
a damaged copy and prove each one fails on exactly the damage it exists for.
The direct tests run the checks over `brainstorm_text.load_brainstorm_corpus()`,
i.e. the shipped tree, or whatever commands directory
`AIMI_BRAINSTORM_WIRING_ROOT` names:

    AIMI_BRAINSTORM_WIRING_ROOT=/path/to/commands python3 -m pytest test_brainstorm_wiring.py

Later stories that move more of brainstorm.md into references/brainstorm/
extend this module rather than adding another. Byte budgets belong to
`test-command-size.sh` and are not checked here.
"""

import re
import shutil

import pytest

import brainstorm_text
from brainstorm_text import (
    COMMANDS_DIR,
    REFERENCES_PREFIX,
    ROOT_ENV,
    ROUTER_KEY,
    brainstorm_text as assemble,
    commands_dir,
    load_brainstorm_corpus,
    scan_lines,
)
from test_arguments_stay_in_command_bodies import ARGUMENTS_READ, shell_fence_lines

HEADING = re.compile(r"^(#{1,6})[ \t]+(\S.*?)[ \t]*$")
READ_LINE = re.compile(
    r"Read \$\{CLAUDE_PLUGIN_ROOT\}/commands/references/brainstorm/([A-Za-z0-9._-]+\.md) in full"
)
APPLIES_WHEN = "Applies when:"
SENTENCE_SPLIT = re.compile(r"(?<=[.!?])[*_`\"')\]]*\s+")
REREAD = re.compile(r"\bre-?read\b", re.IGNORECASE)
COMPACTION = re.compile(r"\bcompaction\b", re.IGNORECASE)

HEADER_H1 = "# Brainstorm: "
HEADER_LOADED = "> Loaded by `commands/brainstorm.md` when its `Applies when:` condition holds."
HEADER_ARTIFACT = (
    "> Artifacts written under `.aimi/` follow the Artifact Language Rule in "
    "`${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`."
)

STEP_07_FILES = (
    "step-0-7-ambiguous-bundle-resolution.md",
    "step-0-7-design-handoff-offer.md",
    "step-0-7-bundle-prototype-gate.md",
)
PHASE_FILES = ("phase-0-assess-clarity.md", "phase-1-research.md")
# Phase 1.7 to Phase 3.9, in router order: (file, router heading, what its Applies when line must hold).
# None means the line must open with `every run`; a string must appear in the line.
LATE_PHASE_ENTRIES = (
    ("phase-1-7-ui-detection.md", "Phase 1.7: UI Feature Detection", None),
    ("phase-1-8-foundation-detection.md", "Phase 1.8: Greenfield Foundation Detection", None),
    ("phase-2-questions.md", "Phase 2: Batched Questions", None),
    ("phase-2-visual-variant-rendering.md", "Phase 2 Visual Variant Rendering", ("Aesthetic Direction", "Differentiation", "visualOverridePending = true", "skip the file")),
    ("phase-2-present-questions.md", "Phase 2 Present Questions", None),
    ("phase-3-resolve-approach.md", "Phase 3: Resolve Approach (Fallback)", None),
    ("phase-3-5-roadmap-gate.md", "Phase 3.5: Roadmap Definition Gate", None),
    ("phase-3-6-prototype-offer.md", "Phase 3.6: Prototype Offer Gate", None),
    ("phase-3-7-fire-check.md", "Phase 3.7: Foundation Synthesis", None),
    ("phase-3-7-foundation-synthesis.md", "Phase 3.7 Foundation Synthesis Steps", ("phase37Verdict", "`fired`", "skip the file")),
    ("phase-3-8-classification-summary.md", "Phase 3.8: Classification Summary Line", None),
    ("phase-3-9-business-contract.md", "Phase 3.9: Business Contract Authoring", None),
)
LATE_PHASE_FILES = tuple(f for f, _h, _c in LATE_PHASE_ENTRIES)
# Phase 4, Phase 5 and the closing entry, in router order, after the Phase 3.9 entry.
TAIL_ENTRIES = (
    ("phase-4-capture.md", "Phase 4: Capture the Design"),
    ("phase-4-pre-save.md", "Phase 4 Pre-Save Rules and Gates"),
    ("phase-5-handoff.md", "Phase 5: Handoff"),
    ("closing-error-handling-and-guidelines.md", "Closing: Error Handling and Guidelines"),
)
TAIL_FILES = tuple(f for f, _h in TAIL_ENTRIES)
# Sections of brainstorm.md that may hold inline text; every other section is a router entry.
INLINE_SECTION_PREFIXES = (
    "Aimi Brainstorm", "Phase Files", "Feature Description", "Step 0:", "Step 0.5:",
    "Step 0.6:", "Step 0.7: Detect", "Step 0.8:", "Environment Variables", "Override Keywords",
)
# Headings that moved out of brainstorm.md: none may remain there, each is in exactly one reference file.
MOVED_HEADINGS = (
    "### Question Generation Rules",
    "#### Approach Questions",
    "#### Visual Variant Rendering (Aesthetic Direction and Differentiation only)",
    "### Present Questions",
    "### Adaptive Rounds",
    "### Quality Gate: Topic Coverage",
    "### Step 1: Scope-Context Trigger Check",
    "### Step 2: Propose the Phase Cut",
    "### Cross-Reference: Prototype Persistence",
    "### Step 2: Reuse Check",
    "### Step 5: Validation Gate",
    "### Step 2: Derive Repository Facts",
    "### Derive Filename",
    "### Pre-Save Blocking Gate \u2014 Open Questions",
)
# Router-level phase headings: each stays in the router once and is repeated in its file.
PHASE_ORDER_BEFORE_PHASE_4 = (
    "## Phase 1.7:", "## Phase 1.8:", "## Phase 2:", "## Phase 3:", "## Phase 3.5:",
    "## Phase 3.6:", "## Phase 3.7:", "## Phase 3.8:", "## Phase 3.9:",
)
FIRST_RESEARCH_TASK = 'Task subagent_type="aimi-engineering:research:aimi-codebase-researcher"'
# Two fences that must stay in the command body, each told apart by a marker it carries.
ARGUMENT_FENCES = (
    ("Step 0.5", "detect-interactivity"),
    ("Step 0.7", 'BUNDLE_ARG=""'),
    ("Step 0.8", "inspect-prototype-kit"),
)


# ---------------------------------------------------------------------------
# Readers
# ---------------------------------------------------------------------------


def read_lines(router):
    """[(line index, basename)] for every anchored Read line outside a fence."""
    found = []
    for i, (line, in_fence) in enumerate(scan_lines(router)):
        if in_fence:
            continue
        for base in READ_LINE.findall(line):
            found.append((i, base))
    return found


def router_entries(router):
    """[{heading, lines: [(index, line)], reads: [(index, basename)]}], one per heading above a Read line."""
    blocks = []
    for i, (line, in_fence) in enumerate(scan_lines(router)):
        if in_fence:
            continue
        m = HEADING.match(line)
        if m:
            blocks.append({"heading": m.group(2), "lines": [], "reads": []})
            continue
        if not blocks:
            continue
        blocks[-1]["lines"].append((i, line))
        for base in READ_LINE.findall(line):
            blocks[-1]["reads"].append((i, base))
    return [b for b in blocks if b["reads"]]


def paragraphs(text):
    """[(first index, last index, [lines])] for each run of non-blank lines outside a fence."""
    out = []
    current = []
    start = 0
    for i, (line, in_fence) in enumerate(scan_lines(text)):
        if in_fence or not line.strip():
            if current:
                out.append((start, i - 1, current))
                current = []
            continue
        if not current:
            start = i
        current.append(line)
    if current:
        out.append((start, start + len(current) - 1, current))
    return out


def split_sentences(joined):
    return [s for s in SENTENCE_SPLIT.split(joined.strip()) if s]


def sentences(text):
    out = []
    for _a, _b, lines in paragraphs(text):
        out.extend(split_sentences(" ".join(l.strip() for l in lines)))
    return out


def drop_sentences(text, predicate):
    lines = text.split("\n")
    for first, last, para in reversed(paragraphs(text)):
        kept = split_sentences(" ".join(l.strip() for l in para))
        remaining = [s for s in kept if not predicate(s)]
        if len(remaining) != len(kept):
            lines[first:last + 1] = [" ".join(remaining)] if remaining else []
    return "\n".join(lines)


def is_compaction_sentence(sentence):
    return bool(REREAD.search(sentence) and COMPACTION.search(sentence))


def is_failed_read_sentence(sentence):
    return bool(
        re.search(r"\bRead\b", sentence)
        and re.search(r"\bfail", sentence, re.IGNORECASE)
        and "STOP" in sentence
        and re.search(r"\bpath\b", sentence)
        and re.search(r"\bfalse\b", sentence)
    )


# ---------------------------------------------------------------------------
# The checks. Corpus in, list of problems out.
# ---------------------------------------------------------------------------

NO_ROUTER = ["no brainstorm.md in the corpus"]


def _reference_names(corpus):
    return sorted(k for k in corpus if k.startswith(REFERENCES_PREFIX))


def check_every_reference_file_has_a_router_read_line(corpus):
    if ROUTER_KEY not in corpus:
        return NO_ROUTER
    refs = _reference_names(corpus)
    if not refs:
        return ["no references/brainstorm/*.md in the corpus"]
    read = {base for _i, base in read_lines(corpus[ROUTER_KEY])}
    return [
        "%s: brainstorm.md has no 'Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/%s in full' line"
        % (ref[len(REFERENCES_PREFIX):], ref[len(REFERENCES_PREFIX):])
        for ref in refs
        if ref[len(REFERENCES_PREFIX):] not in read
    ]


def check_every_router_read_target_exists(corpus):
    if ROUTER_KEY not in corpus:
        return NO_ROUTER
    reads = read_lines(corpus[ROUTER_KEY])
    if not reads:
        return ["brainstorm.md has no anchored Read line, so the scan saw nothing"]
    return [
        "%s: brainstorm.md line %d reads a file that does not exist" % (base, i + 1)
        for i, base in reads
        if REFERENCES_PREFIX + base not in corpus
    ]


def check_every_entry_has_an_applies_when_line(corpus):
    if ROUTER_KEY not in corpus:
        return NO_ROUTER
    entries = router_entries(corpus[ROUTER_KEY])
    if not entries:
        return ["brainstorm.md has no router entry (no heading above an anchored Read line)"]
    problems = []
    for entry in entries:
        read_idx = {i for i, _ in entry["reads"]}
        if not any(l.startswith(APPLIES_WHEN) and i not in read_idx for i, l in entry["lines"]):
            problems.append("%s: its router entry has no line beginning '%s'" % (entry["heading"], APPLIES_WHEN))
    return problems


def check_no_file_is_read_by_two_entries(corpus):
    if ROUTER_KEY not in corpus:
        return NO_ROUTER
    readers = {}
    for n, entry in enumerate(router_entries(corpus[ROUTER_KEY])):
        for _i, base in entry["reads"]:
            readers.setdefault(base, {})[n] = entry["heading"]
    return [
        "%s: read by %d entries (%s)" % (base, len(who), "; ".join(who[n] for n in sorted(who)))
        for base, who in sorted(readers.items())
        if len(who) > 1
    ]


def check_router_carries_the_compaction_sentence(corpus):
    if ROUTER_KEY not in corpus:
        return NO_ROUTER
    if any(is_compaction_sentence(s) for s in sentences(corpus[ROUTER_KEY])):
        return []
    return ["brainstorm.md has no single sentence naming both the re-read and the compaction"]


def check_router_carries_the_failed_read_sentence(corpus):
    if ROUTER_KEY not in corpus:
        return NO_ROUTER
    if any(is_failed_read_sentence(s) for s in sentences(corpus[ROUTER_KEY])):
        return []
    return ["brainstorm.md has no sentence saying a failed Read means STOP and report the path, never condition false"]


def check_every_reference_file_keeps_its_header(corpus):
    refs = _reference_names(corpus)
    if not refs:
        return ["no references/brainstorm/*.md in the corpus"]
    problems = []
    for key in refs:
        lines = corpus[key].split("\n")
        name = key[len(REFERENCES_PREFIX):]
        if not (lines[0].startswith(HEADER_H1) and len(lines[0]) > len(HEADER_H1)):
            problems.append("%s: line 1 is not '%s<the step or phase name>'" % (name, HEADER_H1))
        if len(lines) < 3 or lines[1] != "":
            problems.append("%s: line 2 is not blank" % name)
        if len(lines) < 3 or lines[2] != HEADER_LOADED:
            problems.append("%s: line 3 is not the Loaded by line" % name)
        if len(lines) > 4 and lines[3] == ">":
            if lines[4] != HEADER_ARTIFACT:
                problems.append("%s: lines 4-5 are not the Artifact Language Rule pair" % name)
        elif len(lines) > 3 and lines[3] != "":
            problems.append("%s: line 4 is neither blank nor the start of the Artifact Language pair" % name)
    return problems


def _first(text, needle, start=0):
    i = text.find(needle, start)
    return i


def check_detection_precedes_the_first_research_task(corpus):
    """In the assembled text, Steps 0.5, 0.6 and 0.7 detection precede the first research Task, and the Step 0.7 entries sit above Phase 0 and 1."""
    if ROUTER_KEY not in corpus:
        return NO_ROUTER
    text = assemble(corpus)
    task = _first(text, FIRST_RESEARCH_TASK)
    problems = []
    if task < 0:
        problems.append("no codebase-researcher Task spawn in the assembled text")
        task = len(text)
    for label, needle in (
        ("Step 0.5 detect-interactivity call", "$AIMI_CLI detect-interactivity"),
        ("Step 0.6 Resolve Agent Models line", "**Resolve Agent Models**"),
        ("Step 0.7 detect-design-bundle call", "$AIMI_CLI detect-design-bundle"),
        ("Step 0.8 inspect-prototype-kit call", "$AIMI_CLI inspect-prototype-kit"),
    ):
        at = _first(text, needle)
        if at < 0:
            problems.append("%s is missing from the assembled text" % label)
        elif at > task:
            problems.append("%s follows the first research Task spawn" % label)
    entries = router_entries(corpus[ROUTER_KEY])
    order = {}
    for n, entry in enumerate(entries):
        for _i, base in entry["reads"]:
            order.setdefault(base, n)
    # A file no entry reads is the file_to_router check's finding, not this one's.
    seven = [order[b] for b in STEP_07_FILES if b in order]
    phases = [order[b] for b in PHASE_FILES if b in order]
    if seven and phases and max(seven) > min(phases):
        problems.append("a Step 0.7 entry sits below the Phase 0 / Phase 1 entries")
    return problems


def check_late_phases_are_router_entries_in_order(corpus):
    """The twelve Phase 1.7 to 3.9 files exist, each has one Read line, in phase order after Phase 1 and before Phase 4, with the stated Applies when line."""
    if ROUTER_KEY not in corpus:
        return NO_ROUTER
    router = corpus[ROUTER_KEY]
    problems = []
    reads = read_lines(router)
    for f in LATE_PHASE_FILES:
        if REFERENCES_PREFIX + f not in corpus:
            problems.append("%s: the file does not exist" % f)
        n = sum(1 for _i, b in reads if b == f)
        if n != 1:
            problems.append("%s: %d router Read lines, expected exactly 1" % (f, n))
    order = [b for _i, b in reads]
    if all(f in order for f in LATE_PHASE_FILES):
        positions = [order.index(f) for f in LATE_PHASE_FILES]
        if positions != sorted(positions):
            problems.append("the Phase 1.7 to 3.9 entries are not in phase order")
        if min(positions) < order.index(PHASE_FILES[1]):
            problems.append("a Phase 1.7 to 3.9 entry sits above the Phase 1 entry")
    by_read = {entry["reads"][0][1]: entry for entry in router_entries(router)}
    for f, heading, cond in LATE_PHASE_ENTRIES:
        entry = by_read.get(f)
        if entry is None:
            continue
        if entry["heading"] != heading:
            problems.append("%s: its entry heading is %r, expected %r" % (f, entry["heading"], heading))
        read_idx = {i for i, _ in entry["reads"]}
        applies = [l for i, l in entry["lines"] if l.startswith(APPLIES_WHEN) and i not in read_idx]
        if not applies:
            continue
        line = applies[0]
        if cond is None:
            if not line[len(APPLIES_WHEN):].strip().startswith("every run"):
                problems.append("%s: its Applies when line does not open with 'every run'" % f)
        else:
            missing = [c for c in cond if c not in line]
            if missing:
                problems.append("%s: its Applies when line lacks %s" % (f, ", ".join(missing)))
    return problems


def check_moved_headings_left_the_router(corpus):
    """No moved heading is in brainstorm.md; each is in exactly one reference file; the assembled text orders Phase 1.7 to 3.9 before Phase 4."""
    if ROUTER_KEY not in corpus:
        return NO_ROUTER
    router_lines = [l for l, in_fence in scan_lines(corpus[ROUTER_KEY]) if not in_fence]
    problems = []
    for h in MOVED_HEADINGS:
        if h in router_lines:
            problems.append("%r is still in brainstorm.md" % h)
        holders = [
            k[len(REFERENCES_PREFIX):] for k in _reference_names(corpus)
            if h in [l for l, in_fence in scan_lines(corpus[k]) if not in_fence]
        ]
        if len(holders) != 1:
            problems.append("%r is in %d reference files, expected exactly 1" % (h, len(holders)))
    text = assemble(corpus)
    phase4 = _first(text, "\n## Phase 4: Capture the Design")
    if phase4 < 0:
        problems.append("no Phase 4 heading in the assembled text")
        phase4 = len(text)
    for prefix in PHASE_ORDER_BEFORE_PHASE_4:
        at = _first(text, "\n" + prefix)
        if at < 0:
            problems.append("no %r heading in the assembled text" % prefix)
        elif at > phase4:
            problems.append("%r follows Phase 4 in the assembled text" % prefix)
    return problems


def check_late_phases_are_router_entries_in_order_tail(corpus):
    """Phase 4, Phase 5 and the closing entry: one Read line each, in order, after the Phase 3.9 entry."""
    if ROUTER_KEY not in corpus:
        return NO_ROUTER
    router = corpus[ROUTER_KEY]
    order = [b for _i, b in read_lines(router)]
    problems = []
    for f in TAIL_FILES:
        if REFERENCES_PREFIX + f not in corpus:
            problems.append("%s: the file does not exist" % f)
        if order.count(f) != 1:
            problems.append("%s: %d router Read lines, expected exactly 1" % (f, order.count(f)))
    if all(f in order for f in TAIL_FILES + LATE_PHASE_FILES[-1:]):
        at = [order.index(f) for f in LATE_PHASE_FILES[-1:] + TAIL_FILES]
        if at != sorted(at):
            problems.append("the Phase 4, Phase 5 and closing entries are not in order after Phase 3.9")
    by_read = {entry["reads"][0][1]: entry for entry in router_entries(router)}
    for f, heading in TAIL_ENTRIES:
        entry = by_read.get(f)
        if entry is not None and entry["heading"] != heading:
            problems.append("%s: its entry heading is %r, expected %r" % (f, entry["heading"], heading))
    return problems


def check_brainstorm_md_is_router_only(corpus):
    """Outside the allowed sections, an entry holds a heading and only Applies when, Covers and Read lines, and no fence (counts of each belong to the other checks)."""
    if ROUTER_KEY not in corpus:
        return NO_ROUTER
    problems = []
    heading = None
    scanned = scan_lines(corpus[ROUTER_KEY])
    for n, (line, in_fence) in enumerate(scanned):
        m = None if in_fence else HEADING.match(line)
        if m:
            heading = m.group(2)
            continue
        if heading is None or heading.startswith(INLINE_SECTION_PREFIXES):
            continue
        if in_fence or line.lstrip().startswith("```"):
            problems.append("%s: line %d holds a fenced block" % (heading, n + 1))
        elif not line.strip():
            continue
        elif not (READ_LINE.search(line) or line.startswith(("Applies when:", "Covers:"))):
            problems.append("%s: line %d holds prose beyond Applies when, Covers and the Read line" % (heading, n + 1))
    return problems


def check_the_two_arguments_fences_stay_in_the_command_body(corpus):
    if ROUTER_KEY not in corpus:
        return NO_ROUTER
    problems = []
    router_lines = [line for _n, line in shell_fence_lines(corpus[ROUTER_KEY])]
    reading = [l for l in router_lines if ARGUMENTS_READ.search(l)]
    if not reading:
        problems.append("brainstorm.md has no bash fence reading $ARGUMENTS")
    # Each fence is told apart by a marker it carries; it must read $ARGUMENTS too.
    text = corpus[ROUTER_KEY]
    for label, verb in ARGUMENT_FENCES:
        blocks = _fences_with(text, verb)
        if not blocks:
            problems.append("%s: no fence in brainstorm.md carries %s" % (label, verb))
        elif not any(ARGUMENTS_READ.search(b) for b in blocks):
            problems.append("%s: the fence carrying %s no longer reads $ARGUMENTS in brainstorm.md" % (label, verb))
    for key in _reference_names(corpus):
        for number, line in shell_fence_lines(corpus[key]):
            if ARGUMENTS_READ.search(line):
                problems.append("%s:%d: a bash fence reads $ARGUMENTS under references/" % (key, number))
    return problems


def _fences_with(text, verb):
    """Bodies of the top-level shell fences of `text` that mention `verb`."""
    blocks = []
    current = []
    in_shell = False
    for line, state in brainstorm_text._scan(text):
        if state == "open":
            in_shell = line.lstrip(" \t").lstrip("`").strip().split()[:1] in (["bash"], ["sh"], ["zsh"])
            current = []
        elif state == "body":
            current.append(line)
        elif state == "close":
            if in_shell:
                blocks.append("\n".join(current))
            in_shell = False
    return [b for b in blocks if verb in b]


CHECKS = {
    "file_to_router": check_every_reference_file_has_a_router_read_line,
    "router_to_file": check_every_router_read_target_exists,
    "applies_when": check_every_entry_has_an_applies_when_line,
    "shared_file": check_no_file_is_read_by_two_entries,
    "compaction": check_router_carries_the_compaction_sentence,
    "failed_read": check_router_carries_the_failed_read_sentence,
    "header": check_every_reference_file_keeps_its_header,
    "ordering": check_detection_precedes_the_first_research_task,
    "late_entries": check_late_phases_are_router_entries_in_order,
    "moved_headings": check_moved_headings_left_the_router,
    "tail_entries": check_late_phases_are_router_entries_in_order_tail,
    "router_only": check_brainstorm_md_is_router_only,
    "arguments": check_the_two_arguments_fences_stay_in_the_command_body,
}


# ---------------------------------------------------------------------------
# The shipped tree (or AIMI_BRAINSTORM_WIRING_ROOT)
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def corpus():
    return load_brainstorm_corpus()


def _assert_clean(problems):
    assert not problems, "\n".join(problems)


@pytest.mark.parametrize("name", sorted(CHECKS))
def test_shipped_tree_passes_every_check(name, corpus):
    _assert_clean(CHECKS[name](corpus))


def test_shipped_router_reaches_its_files_through_one_entry_each(corpus):
    reads = [b for _i, b in read_lines(corpus[ROUTER_KEY])]
    assert reads == list(STEP_07_FILES + PHASE_FILES + LATE_PHASE_FILES + TAIL_FILES)


def test_shipped_router_holds_no_task_spawn_and_the_files_hold_five(corpus):
    spawn = re.compile(r"Task subagent_type=")
    assert len(spawn.findall(corpus[ROUTER_KEY])) == 0
    assert sum(len(spawn.findall(corpus[k])) for k in _reference_names(corpus)) == 5


# ---------------------------------------------------------------------------
# The checks must be able to fail: damaged copies, one targeted check each
# ---------------------------------------------------------------------------


def _router_path(root):
    return root / ROUTER_KEY


def _rewrite(path, fn):
    text = path.read_text(encoding="utf-8")
    new = fn(text)
    assert new != text, "mutation changed nothing in %s" % path
    path.write_text(new, encoding="utf-8")


def _edit_router_lines(root, fn):
    path = _router_path(root)
    text = path.read_text(encoding="utf-8")
    lines = text.split("\n")
    fn(lines, router_entries(text))
    new = "\n".join(lines)
    assert new != text, "mutation changed nothing in the router"
    path.write_text(new, encoding="utf-8")


def _ref(root, name):
    return root / "references" / "brainstorm" / name


def _mutate_orphan_file(root):
    (root / "references" / "brainstorm" / "zz-orphan.md").write_text(
        HEADER_H1 + "orphan\n\n" + HEADER_LOADED + "\n\nNothing in brainstorm.md points here.\n",
        encoding="utf-8",
    )


def _mutate_read_line_deleted(root):
    def edit(lines, entries):
        entry = next(e for e in entries if e["reads"][0][1] == PHASE_FILES[0])
        del lines[entry["reads"][0][0]]

    _edit_router_lines(root, edit)


def _mutate_read_of_missing_file(root):
    def edit(lines, entries):
        last = entries[0]["reads"][-1][0]
        lines.insert(
            last + 1,
            "Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/zz-missing.md in full.",
        )

    _edit_router_lines(root, edit)


def _mutate_applies_when_renamed(root):
    def edit(lines, entries):
        read_idx = {i for i, _ in entries[0]["reads"]}
        i = next(i for i, l in entries[0]["lines"] if l.startswith(APPLIES_WHEN) and i not in read_idx)
        del lines[i]

    _edit_router_lines(root, edit)


def _mutate_visual_variant_condition_dropped(root):
    def edit(lines, entries):
        entry = next(e for e in entries if e["reads"][0][1] == "phase-2-visual-variant-rendering.md")
        read_idx = {i for i, _ in entry["reads"]}
        i = next(i for i, l in entry["lines"] if l.startswith(APPLIES_WHEN) and i not in read_idx)
        lines[i] = "Applies when: every run."

    _edit_router_lines(root, edit)


def _mutate_late_entries_swapped(root):
    def edit(lines, entries):
        a = next(e for e in entries if e["reads"][0][1] == "phase-3-5-roadmap-gate.md")
        b = next(e for e in entries if e["reads"][0][1] == "phase-3-6-prototype-offer.md")
        ia, ib = a["reads"][0][0], b["reads"][0][0]
        lines[ia], lines[ib] = lines[ib], lines[ia]

    _edit_router_lines(root, edit)


def _mutate_moved_heading_restored_in_router(root):
    def edit(lines, entries):
        entry = next(e for e in entries if e["reads"][0][1] == "phase-2-questions.md")
        lines.insert(entry["reads"][0][0] + 1, "### Question Generation Rules")

    _edit_router_lines(root, edit)


def _mutate_second_entry_reads_a_shared_file(root):
    def edit(lines, entries):
        shared = entries[0]["reads"][0][1]
        last = entries[-1]["reads"][-1][0]
        lines.insert(
            last + 1,
            "Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/%s in full." % shared,
        )

    _edit_router_lines(root, edit)


def _mutate_prose_added_to_an_entry(root):
    def edit(lines, entries):
        entry = next(e for e in entries if e["reads"][0][1] == "phase-5-handoff.md")
        lines.insert(entry["reads"][0][0] + 1, "Display the brainstorm summary and next steps.")

    _edit_router_lines(root, edit)


def _mutate_tail_entries_swapped(root):
    def edit(lines, entries):
        a = next(e for e in entries if e["reads"][0][1] == "phase-5-handoff.md")
        b = next(e for e in entries if e["reads"][0][1] == "closing-error-handling-and-guidelines.md")
        ia, ib = a["reads"][0][0], b["reads"][0][0]
        lines[ia], lines[ib] = lines[ib], lines[ia]

    _edit_router_lines(root, edit)


def _mutate_compaction_dropped(root):
    _rewrite(_router_path(root), lambda t: drop_sentences(t, is_compaction_sentence))


def _mutate_failed_read_dropped(root):
    _rewrite(_router_path(root), lambda t: drop_sentences(t, is_failed_read_sentence))


def _mutate_h1_prefix_changed(root):
    _rewrite(_ref(root, PHASE_FILES[1]), lambda t: t.replace(HEADER_H1, "# Brainstorming: ", 1))


def _mutate_loaded_by_line_changed(root):
    _rewrite(_ref(root, STEP_07_FILES[0]), lambda t: t.replace("Loaded by `commands/brainstorm.md`", "Loaded by `commands/plan.md`", 1))


def _mutate_research_task_moved_above_detection(root):
    def edit(lines, _entries):
        at = next(i for i, l in enumerate(lines) if l.startswith("## Step 0.5"))
        lines.insert(at, FIRST_RESEARCH_TASK + " prompt=\"early\"")

    _edit_router_lines(root, edit)


def _mutate_step_07_entries_moved_below_phases(root):
    def edit(lines, entries):
        first = next(i for i, l in enumerate(lines) if l.startswith("### Step 0.7 Ambiguous Bundle Resolution"))
        last = next(i for i, l in enumerate(lines) if l.startswith("## Environment Variables"))
        block = lines[first:last]
        del lines[first:last]
        at = next(i for i, l in enumerate(lines) if l.startswith("## Phase 1.7"))
        lines[at:at] = block

    _edit_router_lines(root, edit)


def _mutate_arguments_fence_appended_to_a_reference(root):
    _rewrite(_ref(root, PHASE_FILES[0]), lambda t: t + "\n```bash\nFLAGS=\"$ARGUMENTS\"\n```\n")


def _mutate_step_05_fence_stops_reading_arguments(root):
    _rewrite(_router_path(root), lambda t: t.replace('case " $ARGUMENTS " in', 'case " $FEATURE " in', 1).replace('echo "$ARGUMENTS" | sed \'s/\\(^', 'echo "$FEATURE" | sed \'s/\\(^', 1))


MUTATIONS = {
    "orphan-reference-file": (_mutate_orphan_file, "file_to_router"),
    "read-line-deleted": (_mutate_read_line_deleted, "file_to_router"),
    "read-line-to-missing-file-added": (_mutate_read_of_missing_file, "router_to_file"),
    "first-applies-when-renamed": (_mutate_applies_when_renamed, "applies_when"),
    "visual-variant-condition-dropped": (_mutate_visual_variant_condition_dropped, "late_entries"),
    "late-entries-swapped": (_mutate_late_entries_swapped, "late_entries"),
    "moved-heading-restored-in-router": (_mutate_moved_heading_restored_in_router, "moved_headings"),
    "second-entry-reads-a-shared-file": (_mutate_second_entry_reads_a_shared_file, "shared_file"),
    "prose-added-to-an-entry": (_mutate_prose_added_to_an_entry, "router_only"),
    "tail-entries-swapped": (_mutate_tail_entries_swapped, "tail_entries"),
    "compaction-sentence-dropped": (_mutate_compaction_dropped, "compaction"),
    "failed-read-sentence-dropped": (_mutate_failed_read_dropped, "failed_read"),
    "h1-prefix-changed": (_mutate_h1_prefix_changed, "header"),
    "loaded-by-line-changed": (_mutate_loaded_by_line_changed, "header"),
    "research-task-above-detection": (_mutate_research_task_moved_above_detection, "ordering"),
    "step-07-entries-below-phase-entries": (_mutate_step_07_entries_moved_below_phases, "ordering"),
    "arguments-fence-appended-to-a-reference": (_mutate_arguments_fence_appended_to_a_reference, "arguments"),
    "step-05-fence-stops-reading-arguments": (_mutate_step_05_fence_stops_reading_arguments, "arguments"),
}


def _copy_of_shipped_commands(tmp_path):
    """A copy of the plugin's own commands/ (never AIMI_BRAINSTORM_WIRING_ROOT) holding the router and its files."""
    dest = tmp_path / "commands"
    (dest / "references").mkdir(parents=True)
    shutil.copy2(COMMANDS_DIR / ROUTER_KEY, dest / ROUTER_KEY)
    shutil.copytree(COMMANDS_DIR / "references" / "brainstorm", dest / "references" / "brainstorm")
    return dest


def test_shipped_tree_is_clean_for_every_check_on_a_copy(tmp_path):
    corpus = load_brainstorm_corpus(_copy_of_shipped_commands(tmp_path))
    assert {name: check(corpus) for name, check in CHECKS.items()} == {name: [] for name in CHECKS}


@pytest.mark.parametrize("mutation", sorted(MUTATIONS))
def test_checks_go_red_on_broken_copy(mutation, tmp_path):
    mutate, targeted = MUTATIONS[mutation]
    root = _copy_of_shipped_commands(tmp_path)
    mutate(root)
    broken = load_brainstorm_corpus(root)
    results = {name: check(broken) for name, check in CHECKS.items()}
    assert results[targeted], "%s did not turn the %s check red" % (mutation, targeted)
    others = {name: problems for name, problems in results.items() if name != targeted and problems}
    assert not others, "%s also turned other checks red: %s" % (mutation, others)


def test_every_check_is_targeted_by_a_mutation():
    assert {targeted for _m, targeted in MUTATIONS.values()} == set(CHECKS)


def test_load_corpus_on_copy_equals_the_real_corpus(tmp_path):
    copy = _copy_of_shipped_commands(tmp_path)
    real = load_brainstorm_corpus(COMMANDS_DIR)
    assert load_brainstorm_corpus(copy) == real
    assert ROUTER_KEY in real and _reference_names(real)


def test_commands_dir_honours_the_override(monkeypatch, tmp_path):
    monkeypatch.delenv(ROOT_ENV, raising=False)
    assert commands_dir() == COMMANDS_DIR
    monkeypatch.setenv(ROOT_ENV, str(tmp_path))
    assert commands_dir() == tmp_path
    assert load_brainstorm_corpus() == {}


def test_override_root_redirects_the_corpus_the_direct_tests_read(monkeypatch, tmp_path):
    root = _copy_of_shipped_commands(tmp_path)
    _mutate_orphan_file(root)
    monkeypatch.setenv(ROOT_ENV, str(root))
    assert check_every_reference_file_has_a_router_read_line(load_brainstorm_corpus())


# ---------------------------------------------------------------------------
# The readers the checks lean on
# ---------------------------------------------------------------------------

READ = "Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/%s in full."


def test_a_read_line_inside_a_fence_is_not_a_read_line():
    text = "## A\nApplies when: x\n" + READ % "a.md" + "\n```\n" + READ % "b.md" + "\n```\n"
    assert read_lines(text) == [(2, "a.md")]


def test_an_entry_is_the_heading_above_a_read_line_up_to_the_next_heading():
    text = "## No read\ntext\n## A\nApplies when: x\n" + READ % "a.md" + "\n### B\nApplies when: y\n" + READ % "c.md" + "\n"
    assert [e["heading"] for e in router_entries(text)] == ["A", "B"]


def test_a_sentence_wrapped_across_lines_is_one_sentence():
    text = "Intro line.\n\nWhen a context\ncompaction happens, re-read\nthe router first. Next one."
    assert [s for s in sentences(text) if is_compaction_sentence(s)] == [
        "When a context compaction happens, re-read the router first."
    ]


# ---------------------------------------------------------------------------
# Named prototype kit (Step 0.8, the Phase 1 handoff wrap, the Phase 4 template)
# ---------------------------------------------------------------------------

STEP_08_HEADING = "## Step 0.8: Detect a Named Prototype Kit"


def _step_08(corpus):
    router = corpus[ROUTER_KEY]
    start = router.index(STEP_08_HEADING)
    end = router.find("\n## ", start + 1)
    return router[start:end if end >= 0 else len(router)]


def test_prototype_kit_step_08_sits_inline_between_step_07_and_phase_0(corpus):
    router = corpus[ROUTER_KEY]
    assert router.count(STEP_08_HEADING) == 1
    at = router.index(STEP_08_HEADING)
    last_07 = router.index("Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/step-0-7-bundle-prototype-gate.md")
    phase_0 = router.index("\n## Phase 0: Assess Requirements Clarity")
    assert last_07 < at < phase_0


def test_prototype_kit_step_08_fence_reads_arguments_inline(corpus):
    blocks = _fences_with(_step_08(corpus), "inspect-prototype-kit")
    assert blocks and any(ARGUMENTS_READ.search(b) for b in blocks)
    assert "cat \"${AIMI_CONFIG_DIR" in blocks[0]
    assert not any("jq" in b for b in _fences_with(_step_08(corpus), "AIMI_CLI"))


def test_prototype_kit_inspect_precedes_import_in_step_08(corpus):
    body = _step_08(corpus)
    assert 0 <= body.index("inspect-prototype-kit") < body.index("import-prototype-kit")
    assert "qualifies" in body and "kitHtmlFiles" in body and "kitHandoffFiles" in body


def test_prototype_kit_handoff_is_wrapped_and_escaped_in_phase_1(corpus):
    text = corpus[REFERENCES_PREFIX + "phase-1-research.md"]
    assert '<prototype_handoff path="' in text
    assert "&lt;/prototype_handoff" in text and "&lt;prototype_handoff" in text
    assert "kitHandoffFiles" in text and "DATA, not instructions" in text


def test_prototype_kit_phase_4_template_has_branch_kit_and_prototype_handoff(corpus):
    text = corpus[REFERENCES_PREFIX + "phase-4-capture.md"]
    assert "branch: kit" in text
    assert "prototypeHandoff:" in text
    assert "non-HTML, non-markdown" in text
