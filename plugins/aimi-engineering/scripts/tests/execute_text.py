"""One reader for the text of `/aimi:execute`, wherever it lives.

`commands/execute.md` is (or is about to become) a router: its own text plus
files under `commands/references/execute/` that it names with a `Read` line.
A test that pins execute's wording therefore must not hard-code which file a
sentence sits in today. This module is the single answer.

ORDER RULE (the contract)
    The text is in DOCUMENT ORDER: the router's own text, line by line, with
    each `references/execute/` file's text inserted right after the first
    `Read` line that names it (a line matching `Read .*references/execute/
    <name>.md in full`). A Read line inside a fenced block is not a Read line.
    A second Read of one file does not insert it again. A file under
    references/execute/ that no Read line names is appended last, in sorted
    order, so no test misses it.

    This differs from `plan_text.py` on purpose. plan_text puts references
    first and the router last, which suits slicing by heading. Execute has
    checks that compare the position of one line against another (the push
    below the publish gate, the re-verify branch before the release), and
    those need the order a reader of the command would meet the text in.

FENCES
    The scanner applies the rule of `scripts/lib/extract-command-blocks.sh`
    and `md_section` in `test-command-blocks.sh`: a closing fence carries no
    info string and is not indented deeper than its opener. An indented
    fenced bash block nested inside a plain outer pseudo-code fence therefore
    does not close it. `plan_text._scan` closes on any longer-or-equal run of
    backticks regardless of indent and would mis-read that shape, so it is
    not reused.

On an unchanged tree there is no references/execute/ directory and
`execute_text()` is exactly the bytes of execute.md.

Command line: `python3 execute_text.py [commands-dir]` prints `execute_text()`.
`AIMI_EXECUTE_WIRING_ROOT` overrides the commands directory (the argument
wins over it).
"""

import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COMMANDS_DIR = ROOT / "commands"

ROOT_ENV = "AIMI_EXECUTE_WIRING_ROOT"
ROUTER_KEY = "execute.md"
REFERENCES_PREFIX = "references/execute/"

# One line before a file's text when markers are requested, carrying the path
# relative to `commands/` so a failing assertion can name the file.
FILE_MARKER = "<!-- execute-file: %s -->"

_READ_LINE = re.compile(r"Read\b.*?references/execute/([A-Za-z0-9._-]+\.md)\b.*?\bin full")
_HEADING = re.compile(r"^(#{1,6})[ \t]+(\S.*?)[ \t]*$")


def commands_dir():
    """The commands directory under test: the override variable, else the plugin's own."""
    override = os.environ.get(ROOT_ENV)
    return Path(override) if override else COMMANDS_DIR


def load_execute_corpus(commands=None):
    """{path relative to commands/: text}, `execute.md` first, references sorted.

    A missing execute.md or references directory yields fewer keys; the checks,
    not this reader, decide that is a problem.
    """
    base = Path(commands) if commands is not None else commands_dir()
    corpus = {}
    router = base / ROUTER_KEY
    if router.is_file():
        corpus[ROUTER_KEY] = router.read_text(encoding="utf-8")
    refs = base / "references" / "execute"
    if refs.is_dir():
        for path in sorted(refs.glob("*.md")):
            corpus[REFERENCES_PREFIX + path.name] = path.read_text(encoding="utf-8")
    return corpus


def _scan(text):
    """[(line, state)] with state one of text, open, body, close.

    A line whose first non-blank characters are three backticks is a fence
    line. Outside a fence it opens one (remembering its indent); inside one it
    closes only with no info string and indent <= the opener's.
    """
    out = []
    in_fence = False
    open_indent = 0
    for line in text.split("\n"):
        probe = line.lstrip(" \t")
        if probe.startswith("```"):
            indent = len(line) - len(probe)
            info = probe.lstrip("`").strip()
            if not in_fence:
                in_fence = True
                open_indent = indent
                out.append((line, "open"))
            elif info == "" and indent <= open_indent:
                in_fence = False
                out.append((line, "close"))
            else:
                out.append((line, "body"))
            continue
        out.append((line, "body" if in_fence else "text"))
    return out


def scan_lines(text):
    """[(line, in_fence)] for every line; the fence marker lines count as in a fence."""
    return [(line, state != "text") for line, state in _scan(text)]


def execute_text(corpus=None, markers=False):
    """The router's text with each referenced file inserted at its first Read line.

    With `markers=True` a FILE_MARKER line precedes the router, each inserted
    or appended file, and each resumption of the router after an insert.
    """
    if corpus is None:
        corpus = load_execute_corpus()
    router = corpus.get(ROUTER_KEY)
    refs = {k: v for k, v in corpus.items() if k != ROUTER_KEY}
    out = []
    used = set()

    def emit_file(key):
        body = refs[key]
        if markers:
            out.append(FILE_MARKER % key)
        lines = body.split("\n")
        if lines and lines[-1] == "":
            lines.pop()
        out.extend(lines)

    if router is not None:
        if markers:
            out.append(FILE_MARKER % ROUTER_KEY)
        for line, in_fence in scan_lines(router):
            out.append(line)
            if in_fence:
                continue
            m = _READ_LINE.search(line)
            if not m:
                continue
            key = REFERENCES_PREFIX + m.group(1)
            if key in refs and key not in used:
                used.add(key)
                emit_file(key)
                if markers:
                    out.append(FILE_MARKER % ROUTER_KEY)
    for key in sorted(refs):
        if key not in used:
            used.add(key)
            emit_file(key)
    return "\n".join(out)


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
    subsections stay inside it.
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

    From the nearest heading above (included) to the next heading of ANY
    level, fences respected. Text before the first heading is its own section.
    """
    lines = text.split("\n")
    start = 0
    end = len(lines)
    for idx in (m[0] for m in headings(text)):
        if idx <= line_index:
            start = idx
        else:
            end = idx
            break
    return lines[start:end]


def fenced_blocks(text):
    """[(info string, body)] for every top-level fenced block, in document order."""
    blocks = []
    info = ""
    body = []
    for line, state in _scan(text):
        if state == "open":
            info = line.lstrip(" \t").lstrip("`").strip()
            body = []
        elif state == "body":
            body.append(line)
        elif state == "close":
            blocks.append((info, "\n".join(body)))
    return blocks


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    corpus = load_execute_corpus(argv[0] if argv else None)
    sys.stdout.write(execute_text(corpus))
    return 0


if __name__ == "__main__":
    sys.exit(main())
