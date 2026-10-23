"""One reader for the text of `/aimi:plan`, wherever it lives.

`commands/plan.md` is a router: each phase keeps its heading and an
`Applies when:` line, and the phase body sits in
`commands/references/plan/<file>.md`, read only when that phase runs. A test
that wants "the plan's text" therefore has two places to look, and a test that
reads only `plan.md` finds a router and none of the content it asserts on.
This module is the single answer, so a test never hard-codes which file a
section happens to be in today.

Three readers, each returning what its name says:

    plan_files()        every plan file as a Path, references first, router last
    plan_text()         their text joined into one string, each file after a marker
    plan_router_text()  plan.md alone, the always-loaded part

ORDER IS THE CONTRACT. References come first, in sorted name order, and
`plan.md` last. A test that slices by heading (`text.index("## Phase 3d.5: ...")`
up to the next marker heading) must find the moved section, whose body follows
its heading, before it can find the router heading of the same name, which has
no body worth slicing. Putting the router first would invert that silently.
Every moved file starts with its own heading, so within one file the heading
order is the document order; across files the order is the sorted file name,
which is stable but is not document order, so a slice must not run across a
file marker.
"""

import os
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COMMANDS_DIR = ROOT / "commands"
PLAN = COMMANDS_DIR / "plan.md"
PLAN_REFERENCES_DIR = COMMANDS_DIR / "references" / "plan"

# One line before each file's text. Anchored on its own line and carrying the
# path relative to `commands/`, so a failing assertion can name the file, and
# no phase text ever contains it.
FILE_MARKER = "<!-- plan-file: %s -->"


def plan_files():
    """Every plan file, references in sorted order first, `plan.md` last."""
    return sorted(PLAN_REFERENCES_DIR.glob("*.md")) + [PLAN]


def plan_router_text():
    """`plan.md` alone: the router a `/aimi:plan` run always loads."""
    return PLAN.read_text(encoding="utf-8")


def plan_text():
    """The router plus every phase file, as one string with a marker per file."""
    parts = []
    for path in plan_files():
        marker = FILE_MARKER % path.relative_to(COMMANDS_DIR).as_posix()
        parts.append(marker + "\n" + path.read_text(encoding="utf-8"))
    return "\n".join(parts)


# ---------------------------------------------------------------------------
# Structure readers for tests that pin the plan's wiring rather than its prose.
# None of these change the three readers above; they work on a corpus dict
# ({path relative to commands/: text}) so a check can be run against a copy.
# ---------------------------------------------------------------------------

ROOT_ENV = "AIMI_PLAN_WIRING_ROOT"
ROUTER_KEY = "plan.md"
REFERENCES_PREFIX = "references/plan/"

_FENCE_OPEN = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
_HEADING = re.compile(r"^(#{1,6})[ \t]+(\S.*?)[ \t]*$")


def commands_dir():
    """The commands directory under test: `AIMI_PLAN_WIRING_ROOT`, else the plugin's own.

    Pointing the variable at a copy lets the same module be run, from outside
    the tree, against a deliberately broken `commands/`.
    """
    override = os.environ.get(ROOT_ENV)
    return Path(override) if override else COMMANDS_DIR


def load_corpus(commands=None):
    """`plan.md` plus every `references/plan/*.md` as {relative path: text}.

    Keys are posix paths relative to the commands directory, references in
    sorted order. A missing `plan.md` or an absent references directory simply
    yields fewer keys; the checks, not this reader, decide that is a problem.
    """
    base = Path(commands) if commands is not None else commands_dir()
    corpus = {}
    router = base / ROUTER_KEY
    if router.is_file():
        corpus[ROUTER_KEY] = router.read_text(encoding="utf-8")
    refs = base / "references" / "plan"
    if refs.is_dir():
        for path in sorted(refs.glob("*.md")):
            corpus[REFERENCES_PREFIX + path.name] = path.read_text(encoding="utf-8")
    return corpus


def _scan(text):
    """[(line, state)] with state one of text, open, body, close."""
    out = []
    opener = None
    for line in text.split("\n"):
        if opener is None:
            m = _FENCE_OPEN.match(line)
            if m:
                opener = m.group(1)
                out.append((line, "open"))
            else:
                out.append((line, "text"))
            continue
        stripped = line.strip()
        if stripped and set(stripped) == {opener[0]} and len(stripped) >= len(opener):
            opener = None
            out.append((line, "close"))
        else:
            out.append((line, "body"))
    return out


def scan_lines(text):
    """[(line, in_fence)] for every line; the fence marker lines count as in a fence."""
    return [(line, state != "text") for line, state in _scan(text)]


def headings(text):
    """[(line_index, level, title)] for every heading outside a fence."""
    found = []
    for i, (line, in_fence) in enumerate(scan_lines(text)):
        if in_fence:
            continue
        m = _HEADING.match(line)
        if m:
            found.append((i, len(m.group(1)), m.group(2)))
    return found


def heading_slices(text, title_pattern):
    """Slices (heading line included) of every non-fenced heading whose title matches.

    A slice ends at the next heading of the same or a higher level, so its own
    subsections stay inside it; a `#` inside a fence is not a heading.
    """
    lines = text.split("\n")
    marks = headings(text)
    slices = []
    for n, (idx, level, title) in enumerate(marks):
        if not re.search(title_pattern, title):
            continue
        end = len(lines)
        for later_idx, later_level, _ in marks[n + 1:]:
            if later_level <= level:
                end = later_idx
                break
        slices.append("\n".join(lines[idx:end]))
    return slices


def section_lines(text, line_index):
    """The lines of the innermost heading section holding `line_index`.

    Runs from the nearest heading above (included) to the next heading of ANY
    level, fences respected. Text before the first heading is its own section.
    """
    lines = text.split("\n")
    marks = [m[0] for m in headings(text)]
    start = 0
    end = len(lines)
    for idx in marks:
        if idx <= line_index:
            start = idx
        else:
            end = idx
            break
    return lines[start:end]


def fenced_blocks(text):
    """[(info string, body)] for every fenced block, in document order."""
    blocks = []
    info = ""
    body = []
    for line, state in _scan(text):
        if state == "open":
            info = _FENCE_OPEN.match(line).group(2).strip()
            body = []
        elif state == "body":
            body.append(line)
        elif state == "close":
            blocks.append((info, "\n".join(body)))
    return blocks
