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
