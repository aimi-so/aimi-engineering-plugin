"""Structural pin on the `/aimi:execute` wiring: the router and its step files stay in step.

`commands/execute.md` is a router. Each entry is a heading, an `Applies when:`
line, an optional `Covers:` line and one or more `Read ${CLAUDE_PLUGIN_ROOT}/
commands/references/execute/<file>.md in full` lines. The body of a step lives
in that file. Four things can rot without any run noticing: a step file that
nothing reads (an orphan), a Read line naming a file that is gone, an entry
that lost its condition, and the two sentences the router exists to carry (the
re-read after compaction, and the STOP on a failed Read). The Spawned Tasks
table adds a fifth: a router entry that appears in neither cell of a kind's
row is silently neither evaluated nor skipped by a spawned split task.

Each check below is a function over a CORPUS dict, `{path relative to
commands/: text}`, and returns a list of problem strings; empty means the
corpus is fine. A check never reads the disk itself (the `$ARGUMENTS` check
writes the corpus to a throwaway directory to hand it to the guard of
`test_arguments_stay_in_command_bodies.py`, which takes a directory), which is
what lets `test_checks_go_red_on_broken_copy` hand the same functions a damaged
copy and prove each one fails on exactly the damage it exists for. The direct
tests run the checks over `execute_text.load_execute_corpus()`, i.e. the
shipped tree, or whatever commands directory `AIMI_EXECUTE_WIRING_ROOT` names:

    AIMI_EXECUTE_WIRING_ROOT=/path/to/commands python3 -m pytest test_execute_wiring.py

All text is read through `execute_text`; this module has its own fence-aware
paragraph reader only on top of `execute_text.scan_lines`. Byte budgets belong
to `test-command-size.sh` and are not checked here.
"""

import re
import shutil
import tempfile
from pathlib import Path

import pytest

import execute_text
from execute_text import (
    COMMANDS_DIR,
    REFERENCES_PREFIX,
    ROOT_ENV,
    ROUTER_KEY,
    commands_dir,
    heading_slices,
    load_execute_corpus,
    scan_lines,
)
from test_arguments_stay_in_command_bodies import arguments_reads

# ---------------------------------------------------------------------------
# Constants the checks share
# ---------------------------------------------------------------------------

HEADING = re.compile(r"^(#{1,6})[ \t]+(\S.*?)[ \t]*$")
READ_LINE = re.compile(
    r"Read \$\{CLAUDE_PLUGIN_ROOT\}/commands/references/execute/([A-Za-z0-9._-]+\.md) in full"
)
APPLIES_WHEN = "Applies when:"
SENTENCE_SPLIT = re.compile(r"(?<=[.!?])[*_`\"')\]]*\s+")
REREAD = re.compile(r"\bre-?read\b", re.IGNORECASE)
COMPACTION = re.compile(r"\bcompaction\b", re.IGNORECASE)
SPAWNED_KINDS = ("flat-split-child", "phase-split-sub-orchestrator")
SPAWNED_TITLE = r"^Spawned Tasks$"


# ---------------------------------------------------------------------------
# Readers on top of execute_text.scan_lines
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
    """[{heading, lines: [(index, line)], reads: [(index, basename)]}], one per heading above a Read line.

    An entry is the heading above an anchored Read line plus the non-fence
    lines up to the next heading. Headings come from the router; nothing is
    hard-coded.
    """
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
    """Every sentence of every paragraph outside a fence; a wrapped sentence is one."""
    out = []
    for _a, _b, lines in paragraphs(text):
        out.extend(split_sentences(" ".join(l.strip() for l in lines)))
    return out


def drop_sentences(text, predicate):
    """`text` with every sentence satisfying `predicate` removed from its paragraph."""
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


def split_items(cell):
    """The `;`-separated items of a table cell, splitting only outside parentheses."""
    items = []
    depth = 0
    buf = []
    for ch in cell:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth = max(0, depth - 1)
        if ch == ";" and depth == 0:
            items.append("".join(buf).strip())
            buf = []
        else:
            buf.append(ch)
    items.append("".join(buf).strip())
    return [i for i in items if i]


def match_heading(item, headings):
    """The longest heading an item names: the heading itself, or the heading plus a parenthesised note."""
    best = None
    for h in headings:
        if item == h or item.startswith(h + " ("):
            if best is None or len(h) > len(best):
                best = h
    return best


def spawned_rows(router):
    """{kind: (line index, [cells])} for the table rows of the Spawned Tasks section."""
    lines = router.split("\n")
    rows = {}
    for section in heading_slices(router, SPAWNED_TITLE):
        for line in section.split("\n"):
            if not line.lstrip().startswith("|"):
                continue
            for kind in SPAWNED_KINDS:
                if "SPAWNED_SPLIT_TASK=" + kind in line:
                    cells = [c.strip() for c in line.strip().strip("|").split("|")]
                    rows[kind] = (lines.index(line), cells)
    return rows


# ---------------------------------------------------------------------------
# The eight checks. Corpus in, list of problems out.
# ---------------------------------------------------------------------------

NO_ROUTER = ["no execute.md in the corpus"]


def _reference_names(corpus):
    return sorted(k for k in corpus if k.startswith(REFERENCES_PREFIX))


def check_every_reference_file_has_a_router_read_line(corpus):
    if ROUTER_KEY not in corpus:
        return NO_ROUTER
    refs = _reference_names(corpus)
    if not refs:
        return ["no references/execute/*.md in the corpus"]
    read = {base for _i, base in read_lines(corpus[ROUTER_KEY])}
    return [
        "%s: execute.md has no 'Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/%s in full' line"
        % (ref[len(REFERENCES_PREFIX):], ref[len(REFERENCES_PREFIX):])
        for ref in refs
        if ref[len(REFERENCES_PREFIX):] not in read
    ]


def check_every_router_read_target_exists(corpus):
    if ROUTER_KEY not in corpus:
        return NO_ROUTER
    reads = read_lines(corpus[ROUTER_KEY])
    if not reads:
        return ["execute.md has no anchored Read line, so the scan saw nothing"]
    return [
        "%s: execute.md line %d reads a file that does not exist" % (base, i + 1)
        for i, base in reads
        if REFERENCES_PREFIX + base not in corpus
    ]


def check_every_entry_has_an_applies_when_line(corpus):
    if ROUTER_KEY not in corpus:
        return NO_ROUTER
    entries = router_entries(corpus[ROUTER_KEY])
    if not entries:
        return ["execute.md has no router entry (no heading above an anchored Read line)"]
    problems = []
    for entry in entries:
        read_idx = {i for i, _ in entry["reads"]}
        if not any(l.startswith(APPLIES_WHEN) and i not in read_idx for i, l in entry["lines"]):
            problems.append("%s: its router entry has no line beginning '%s'" % (entry["heading"], APPLIES_WHEN))
    return problems


def check_no_file_is_read_by_two_entries(corpus):
    if ROUTER_KEY not in corpus:
        return NO_ROUTER
    entries = router_entries(corpus[ROUTER_KEY])
    readers = {}
    for n, entry in enumerate(entries):
        for _i, base in entry["reads"]:
            readers.setdefault(base, {})[n] = entry["heading"]
    problems = [
        "%s: read by %d entries (%s)" % (base, len(who), "; ".join(who[n] for n in sorted(who)))
        for base, who in sorted(readers.items())
        if len(who) > 1
    ]
    if not any(len({b for _i, b in e["reads"]}) > 1 for e in entries):
        problems.append("no entry reads two files, so the paired-entry case is not represented")
    return problems


def check_router_carries_the_compaction_sentence(corpus):
    if ROUTER_KEY not in corpus:
        return NO_ROUTER
    if any(is_compaction_sentence(s) for s in sentences(corpus[ROUTER_KEY])):
        return []
    return ["execute.md has no single sentence naming both the re-read and the compaction"]


def check_router_carries_the_failed_read_sentence(corpus):
    if ROUTER_KEY not in corpus:
        return NO_ROUTER
    if any(is_failed_read_sentence(s) for s in sentences(corpus[ROUTER_KEY])):
        return []
    return ["execute.md has no sentence saying a failed Read means STOP and report the path, never condition false"]


def check_spawned_tasks_table_covers_every_entry(corpus):
    if ROUTER_KEY not in corpus:
        return NO_ROUTER
    router = corpus[ROUTER_KEY]
    headings = [e["heading"] for e in router_entries(router)]
    rows = spawned_rows(router)
    problems = []
    for kind in SPAWNED_KINDS:
        if kind not in rows:
            problems.append("Spawned Tasks has no table row carrying SPAWNED_SPLIT_TASK=%s" % kind)
            continue
        cells = rows[kind][1]
        if len(cells) < 4:
            problems.append("%s: row has %d cells, expected Kind, Marker, Evaluates, Skips" % (kind, len(cells)))
            continue
        counts = {h: 0 for h in headings}
        for cell_name, cell in (("Evaluates", cells[2]), ("Skips", cells[3])):
            for item in split_items(cell):
                hit = match_heading(item, headings)
                if hit is None:
                    problems.append("%s: %s item '%s' names no router entry" % (kind, cell_name, item[:80]))
                else:
                    counts[hit] += 1
        for heading, n in counts.items():
            if n != 1:
                problems.append(
                    "%s: entry '%s' appears %d times across Evaluates and Skips, expected exactly one"
                    % (kind, heading, n)
                )
    return problems


def check_no_arguments_read_in_execute_references(corpus):
    refs = _reference_names(corpus)
    if not refs:
        return ["no references/execute/*.md in the corpus"]
    with tempfile.TemporaryDirectory() as tmp:
        for name, text in corpus.items():
            path = Path(tmp) / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        found = arguments_reads(tmp)
    return [p for p in found if p.startswith(REFERENCES_PREFIX)]


CHECKS = {
    "file_to_router": check_every_reference_file_has_a_router_read_line,
    "router_to_file": check_every_router_read_target_exists,
    "applies_when": check_every_entry_has_an_applies_when_line,
    "shared_file": check_no_file_is_read_by_two_entries,
    "compaction": check_router_carries_the_compaction_sentence,
    "failed_read": check_router_carries_the_failed_read_sentence,
    "spawned_tasks": check_spawned_tasks_table_covers_every_entry,
    "arguments": check_no_arguments_read_in_execute_references,
}


# ---------------------------------------------------------------------------
# The shipped tree (or AIMI_EXECUTE_WIRING_ROOT)
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def corpus():
    return load_execute_corpus()


def _assert_clean(problems):
    assert not problems, "\n".join(problems)


def test_shipped_every_reference_file_has_a_router_read_line(corpus):
    _assert_clean(check_every_reference_file_has_a_router_read_line(corpus))


def test_shipped_every_router_read_target_exists(corpus):
    _assert_clean(check_every_router_read_target_exists(corpus))


def test_shipped_every_entry_has_an_applies_when_line(corpus):
    _assert_clean(check_every_entry_has_an_applies_when_line(corpus))


def test_shipped_no_file_is_read_by_two_entries(corpus):
    _assert_clean(check_no_file_is_read_by_two_entries(corpus))


def test_shipped_router_carries_the_compaction_sentence(corpus):
    _assert_clean(check_router_carries_the_compaction_sentence(corpus))


def test_shipped_router_carries_the_failed_read_sentence(corpus):
    _assert_clean(check_router_carries_the_failed_read_sentence(corpus))


def test_shipped_spawned_tasks_table_covers_every_entry(corpus):
    _assert_clean(check_spawned_tasks_table_covers_every_entry(corpus))


def test_shipped_no_arguments_read_in_execute_references(corpus):
    _assert_clean(check_no_arguments_read_in_execute_references(corpus))


# ---------------------------------------------------------------------------
# The checks must be able to fail: ten damaged copies, one targeted check each
# ---------------------------------------------------------------------------


def _router_path(root):
    return root / ROUTER_KEY


def _edit_router_lines(root, fn):
    path = _router_path(root)
    text = path.read_text(encoding="utf-8")
    lines = text.split("\n")
    fn(lines, router_entries(text))
    new = "\n".join(lines)
    assert new != text, "mutation changed nothing in the router"
    path.write_text(new, encoding="utf-8")


def _rewrite(path, fn):
    text = path.read_text(encoding="utf-8")
    new = fn(text)
    assert new != text, "mutation changed nothing in %s" % path
    path.write_text(new, encoding="utf-8")


def _mutate_orphan_file(root):
    (root / "references" / "execute" / "zz-orphan.md").write_text(
        "# Execute: orphan\n\nNothing in execute.md points here.\n", encoding="utf-8"
    )


def _mutate_paired_read_deleted(root):
    def edit(lines, entries):
        paired = next(e for e in entries if len({b for _i, b in e["reads"]}) > 1)
        del lines[paired["reads"][0][0]]

    _edit_router_lines(root, edit)


def _mutate_read_of_missing_file(root):
    def edit(lines, entries):
        last = entries[0]["reads"][-1][0]
        lines.insert(
            last + 1,
            "Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/zz-missing-step.md in full.",
        )

    _edit_router_lines(root, edit)


def _mutate_applies_when_renamed(root):
    def edit(lines, entries):
        read_idx = {i for i, _ in entries[0]["reads"]}
        i = next(i for i, l in entries[0]["lines"] if l.startswith(APPLIES_WHEN) and i not in read_idx)
        lines[i] = "Use when:" + lines[i][len(APPLIES_WHEN):]

    _edit_router_lines(root, edit)


def _mutate_second_entry_reads_a_shared_file(root):
    def edit(lines, entries):
        shared = entries[0]["reads"][0][1]
        last = entries[-1]["reads"][-1][0]
        lines.insert(
            last + 1,
            "Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/%s in full." % shared,
        )

    _edit_router_lines(root, edit)


def _mutate_compaction_dropped(root):
    _rewrite(_router_path(root), lambda t: drop_sentences(t, is_compaction_sentence))


def _mutate_failed_read_dropped(root):
    _rewrite(_router_path(root), lambda t: drop_sentences(t, is_failed_read_sentence))


def _rewrite_row(root, kind, fn):
    def edit(lines, _entries):
        idx, cells = spawned_rows("\n".join(lines))[kind]
        fn(cells)
        lines[idx] = "| " + " | ".join(cells) + " |"

    _edit_router_lines(root, edit)


def _mutate_heading_removed_from_skips(root):
    def fn(cells):
        items = split_items(cells[3])
        cells[3] = "; ".join(items[:-1])

    _rewrite_row(root, SPAWNED_KINDS[0], fn)


def _mutate_heading_in_both_cells(root):
    def fn(cells):
        cells[2] = cells[2] + "; " + split_items(cells[3])[0]

    _rewrite_row(root, SPAWNED_KINDS[0], fn)


def _mutate_arguments_fence_appended(root):
    target = sorted((root / "references" / "execute").glob("*.md"))[0]
    _rewrite(target, lambda t: t + "\n```bash\nFLAGS=\"$ARGUMENTS\"\n```\n")


MUTATIONS = {
    "orphan-reference-file": (_mutate_orphan_file, "file_to_router"),
    "paired-entry-read-line-deleted": (_mutate_paired_read_deleted, "file_to_router"),
    "read-line-to-missing-file-added": (_mutate_read_of_missing_file, "router_to_file"),
    "first-applies-when-renamed": (_mutate_applies_when_renamed, "applies_when"),
    "second-entry-reads-a-shared-file": (_mutate_second_entry_reads_a_shared_file, "shared_file"),
    "compaction-sentence-dropped": (_mutate_compaction_dropped, "compaction"),
    "failed-read-sentence-dropped": (_mutate_failed_read_dropped, "failed_read"),
    "heading-removed-from-a-skips-cell": (_mutate_heading_removed_from_skips, "spawned_tasks"),
    "heading-in-both-cells-of-a-row": (_mutate_heading_in_both_cells, "spawned_tasks"),
    "arguments-bash-fence-appended": (_mutate_arguments_fence_appended, "arguments"),
}


def _copy_of_shipped_commands(tmp_path):
    """A copy of the plugin's own commands/ (never AIMI_EXECUTE_WIRING_ROOT) holding the router and its step files."""
    dest = tmp_path / "commands"
    (dest / "references").mkdir(parents=True)
    shutil.copy2(COMMANDS_DIR / ROUTER_KEY, dest / ROUTER_KEY)
    shutil.copytree(COMMANDS_DIR / "references" / "execute", dest / "references" / "execute")
    return dest


def test_shipped_tree_is_clean_for_every_check(tmp_path):
    """The baseline the mutation test leans on: an unmutated copy of the shipped tree has no problems."""
    corpus = load_execute_corpus(_copy_of_shipped_commands(tmp_path))
    assert {name: check(corpus) for name, check in CHECKS.items()} == {name: [] for name in CHECKS}


@pytest.mark.parametrize("mutation", sorted(MUTATIONS))
def test_checks_go_red_on_broken_copy(mutation, tmp_path):
    mutate, targeted = MUTATIONS[mutation]
    root = _copy_of_shipped_commands(tmp_path)
    mutate(root)
    broken = load_execute_corpus(root)
    results = {name: check(broken) for name, check in CHECKS.items()}
    assert results[targeted], "%s did not turn the %s check red" % (mutation, targeted)
    others = {name: problems for name, problems in results.items() if name != targeted and problems}
    assert not others, "%s also turned other checks red: %s" % (mutation, others)


def test_every_check_is_targeted_by_a_mutation():
    assert {targeted for _m, targeted in MUTATIONS.values()} == set(CHECKS)


def test_load_corpus_on_copy_equals_the_real_corpus(tmp_path):
    copy = _copy_of_shipped_commands(tmp_path)
    real = load_execute_corpus(COMMANDS_DIR)
    assert load_execute_corpus(copy) == real
    assert ROUTER_KEY in real and _reference_names(real)


def test_commands_dir_honours_the_override(monkeypatch, tmp_path):
    monkeypatch.delenv(ROOT_ENV, raising=False)
    assert commands_dir() == COMMANDS_DIR
    monkeypatch.setenv(ROOT_ENV, str(tmp_path))
    assert commands_dir() == tmp_path
    assert execute_text.load_execute_corpus() == {}
    assert load_execute_corpus() == {}


def test_override_root_redirects_the_corpus_the_direct_tests_read(monkeypatch, tmp_path):
    root = _copy_of_shipped_commands(tmp_path)
    _mutate_orphan_file(root)
    monkeypatch.setenv(ROOT_ENV, str(root))
    assert check_every_reference_file_has_a_router_read_line(load_execute_corpus())


# ---------------------------------------------------------------------------
# The readers the checks lean on
# ---------------------------------------------------------------------------

READ = "Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/%s in full."


def test_a_read_line_inside_a_fence_is_not_a_read_line():
    text = "## A\nApplies when: x\n" + READ % "a.md" + "\n```\n" + READ % "b.md" + "\n```\n"
    assert read_lines(text) == [(2, "a.md")]


def test_an_entry_is_the_heading_above_a_read_line_up_to_the_next_heading():
    text = (
        "## No read\ntext\n## A\nApplies when: x\n" + READ % "a.md" + "\n" + READ % "b.md"
        + "\n### B\nApplies when: y\n" + READ % "c.md" + "\n"
    )
    entries = router_entries(text)
    assert [e["heading"] for e in entries] == ["A", "B"]
    assert [b for _i, b in entries[0]["reads"]] == ["a.md", "b.md"]


def test_a_sentence_wrapped_across_lines_is_one_sentence():
    text = "Intro line.\n\nWhen a context\ncompaction happens, re-read\nthe router first. Next one."
    assert [s for s in sentences(text) if is_compaction_sentence(s)] == [
        "When a context compaction happens, re-read the router first."
    ]


def test_sentences_ignore_fenced_text():
    text = "```\nre-read after compaction.\n```\n"
    assert sentences(text) == []


def test_items_split_only_outside_parentheses():
    assert split_items("A (x; y); B; C") == ["A (x; y)", "B", "C"]
    assert match_heading("Step 1 (note)", ["Step 1", "Step"]) == "Step 1"
    assert match_heading("Step 10", ["Step 1"]) is None
