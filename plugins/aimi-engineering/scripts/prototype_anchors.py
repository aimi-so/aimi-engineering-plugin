#!/usr/bin/env python3
"""Anchors of a prototype HTML file that has no data-view sections.

Behind `index-prototype-anchors` and the kind-tagged anchors of
`extract-prototype-sections` (aimi-cli.sh owns the flags, the path confinement
and check_python3; every HTML rule is here).

    prototype_anchors.py index   <file>
    prototype_anchors.py extract <file> <kind> <name>

`index` prints one `<kind>:<name>` line per anchor, in document order:

    view     <section data-view="NAME">
    id       an id on section, main, article or div
    tab      role=tabpanel, named by the text of the element its aria-labelledby
             names, else of the role=tab element whose aria-controls names it,
             else its aria-label
    heading  h1-h3, named by its text

`extract` prints one slice of the file, cut from the raw text by the offsets the
parser reports and never re-serialised, so it is the bytes on disk:

    id, tab   the element, from its opening tag through its matching closing tag
              (to end of file when it is never closed)
    heading   from the heading's opening tag up to the next h1-h6 of the same or
              a higher level, or end of file -- start tags only, so unbalanced
              markup does not change the answer

Exit status of `extract`: 0 matched, 1 no anchor of that kind and name, 2 a file
it could not read.
"""

import re
import sys
from html.parser import HTMLParser

VOID = frozenset(
    "area base br col embed hr img input link meta param source track wbr".split()
)
ID_TAGS = frozenset(("section", "main", "article", "div"))
HEADING_TAGS = {"h1": 1, "h2": 2, "h3": 3, "h4": 4, "h5": 5, "h6": 6}
INDEXED_HEADINGS = frozenset(("h1", "h2", "h3"))
# A heading left unclosed ends where one of these starts.
BLOCK_TAGS = frozenset(
    (
        "p div section article main nav header footer aside form ul ol dl li table "
        "pre blockquote figure fieldset details hr"
    ).split()
)
UNSAFE = ("$", "`", '"', "\\")


def collapse(text):
    return re.sub(r"\s+", " ", text).strip()


class Element:
    __slots__ = ("tag", "attrs", "start", "end", "open_end", "parts")

    def __init__(self, tag, attrs, start):
        self.tag = tag
        self.attrs = attrs
        self.start = start
        self.end = None
        self.open_end = start
        self.parts = []

    @property
    def text(self):
        return collapse("".join(self.parts))

    def roles(self):
        return (self.attrs.get("role") or "").lower().split()


class Scanner(HTMLParser):
    """One pass over the raw text: every element with its start and end offsets,
    and every start tag of a heading."""

    def __init__(self, raw):
        super().__init__(convert_charrefs=True)
        self.raw = raw
        self.line_starts = [0]
        for m in re.finditer("\n", raw):
            self.line_starts.append(m.end())
        self.elements = []
        self.stack = []

    def _offset(self):
        line, col = self.getpos()
        return self.line_starts[line - 1] + col

    def _close_from(self, index, end):
        # Everything above `index` is closed implicitly where this end tag starts.
        for el in reversed(self.stack[index + 1:]):
            el.end = end[0]
        self.stack[index].end = end[1]
        del self.stack[index:]

    def _implicit_heading_close(self, tag, offset):
        if tag in BLOCK_TAGS or tag in HEADING_TAGS:
            for i in range(len(self.stack) - 1, -1, -1):
                if self.stack[i].tag in HEADING_TAGS:
                    for el in self.stack[i:]:
                        el.end = offset
                    del self.stack[i:]
                    break

    def _open(self, tag, attrs):
        start = self._offset()
        self._implicit_heading_close(tag, start)
        attr = {}
        for name, value in attrs:
            attr.setdefault(name.lower(), value if value is not None else "")
        el = Element(tag, attr, start)
        text = self.get_starttag_text() or ""
        el.open_end = start + len(text)
        self.elements.append(el)
        if tag not in VOID:
            self.stack.append(el)
        return el

    def handle_starttag(self, tag, attrs):
        self._open(tag, attrs)

    def handle_startendtag(self, tag, attrs):
        el = self._open(tag, attrs)
        if tag not in VOID and self.stack and self.stack[-1] is el:
            self.stack.pop()
            el.end = el.open_end

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        for i in range(len(self.stack) - 1, -1, -1):
            if self.stack[i].tag == tag:
                start = self._offset()
                gt = self.raw.find(">", start)
                stop = len(self.raw) if gt < 0 else gt + 1
                self._close_from(i, (start, stop))
                return

    def handle_data(self, data):
        for el in self.stack:
            el.parts.append(data)


def scan(path):
    with open(path, "rb") as fh:
        raw = fh.read().decode("utf-8", errors="surrogateescape")
    scanner = Scanner(raw)
    scanner.feed(raw)
    scanner.close()
    for el in scanner.elements:
        if el.end is None:
            el.end = len(raw)
    return raw, scanner.elements


def _label_text(by_id, ids):
    parts = []
    for ident in (ids or "").split():
        target = by_id.get(ident)
        if target is not None and target.text:
            parts.append(target.text)
    return collapse(" ".join(parts))


def anchors(elements):
    """Every anchor as (kind, name, element), in document order.

    The second pass: a tab panel is named by an element that can follow it, so
    the lookup tables are built from the whole file before any name is chosen."""
    by_id = {}
    tab_for_panel = {}
    for el in elements:
        ident = collapse(el.attrs.get("id") or "")
        if ident and ident not in by_id:
            by_id[ident] = el
        if "tab" in el.roles():
            for target in (el.attrs.get("aria-controls") or "").split():
                tab_for_panel.setdefault(target, el)

    found = []
    for el in elements:
        if el.tag == "section" and "data-view" in el.attrs:
            name = collapse(el.attrs["data-view"])
            if name:
                found.append(("view", name, el))
        if el.tag in ID_TAGS:
            name = collapse(el.attrs.get("id") or "")
            if name:
                found.append(("id", name, el))
        if "tabpanel" in el.roles():
            name = _label_text(by_id, el.attrs.get("aria-labelledby"))
            if not name:
                tab = tab_for_panel.get(collapse(el.attrs.get("id") or ""))
                name = tab.text if tab is not None else ""
            if not name:
                name = collapse(el.attrs.get("aria-label") or "")
            if name:
                found.append(("tab", name, el))
        if el.tag in INDEXED_HEADINGS:
            name = el.text
            if name:
                found.append(("heading", name, el))
    return found


def _is_unsafe(name):
    return any(ch in name for ch in UNSAFE)


def index(path):
    _, elements = scan(path)
    safe = []
    for kind, name, el in anchors(elements):
        if _is_unsafe(name):
            sys.stderr.write(
                "Warning: anchor skipped (unsafe character): %s:%s\n" % (kind, name)
            )
            continue
        safe.append((kind, name, el))

    out = []
    seen = set()
    for kind, name, el in safe:
        if kind == "id" and _encloses_every_other(el, safe):
            continue
        key = (kind, name)
        if key in seen:
            continue
        seen.add(key)
        out.append("%s:%s" % (kind, name))
    if out:
        sys.stdout.write("\n".join(out) + "\n")
    return 0


def _encloses_every_other(container, safe):
    """True when an id container holds every anchor that is not its own.

    An anchor of the same element is not another anchor, and a container that
    has nothing else to enclose stays listed."""
    others = [el for _, _, el in safe if el is not container]
    if not others:
        return False
    return all(container.start < el.start and el.start < container.end for el in others)


def _emit(raw, start, stop):
    sys.stdout.flush()
    sys.stdout.buffer.write(raw[start:stop].encode("utf-8", errors="surrogateescape"))
    sys.stdout.buffer.flush()


def extract(path, kind, name):
    raw, elements = scan(path)
    candidates = [(n, el) for k, n, el in anchors(elements) if k == kind]
    chosen = next((el for n, el in candidates if n == name), None)
    if chosen is None:
        folded = name.casefold()
        chosen = next((el for n, el in candidates if n.casefold() == folded), None)
    if chosen is None:
        return 1
    if kind == "heading":
        level = HEADING_TAGS[chosen.tag]
        stop = len(raw)
        for el in elements:
            if el.start > chosen.start and HEADING_TAGS.get(el.tag, 99) <= level:
                stop = el.start
                break
        _emit(raw, chosen.start, stop)
    else:
        _emit(raw, chosen.start, chosen.end)
    return 0


def main(argv):
    try:
        if len(argv) == 3 and argv[1] == "index":
            return index(argv[2])
        if len(argv) == 5 and argv[1] == "extract":
            if argv[3] not in ("id", "tab", "heading"):
                sys.stderr.write("prototype_anchors: unknown kind: %s\n" % argv[3])
                return 2
            return extract(argv[2], argv[3], argv[4])
    except OSError as exc:
        sys.stderr.write("prototype_anchors: %s\n" % exc)
        return 2
    sys.stderr.write(
        "usage: prototype_anchors.py index <file> | extract <file> <kind> <name>\n"
    )
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
