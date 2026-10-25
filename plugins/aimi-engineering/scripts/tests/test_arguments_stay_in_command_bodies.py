"""Pin: a bash block that reads `$ARGUMENTS` lives in a command body, never in a reference file.

The host substitutes `$ARGUMENTS` in a command's own body and nowhere else. A
reference file is read at run time by a model that copies its bash fences
into a shell, so a `$ARGUMENTS` in one of them reaches the shell as an
unset variable and the flags the user typed are silently lost. `/aimi:plan`'s
`--phase` and `--non-interactive` parsing sat in
`references/plan/step-0-environment-setup.md` for exactly that reason; this
module is the check that refuses any later regression, under
`commands/references/` at any depth (so `references/plan/` and a future
`references/execute/` are both covered, and a missing subdirectory is not an
error).

What counts as a bash fence is what `scripts/lib/extract-command-blocks.sh`
counts: a top-level fence (backticks or tildes, any leading whitespace) whose
info string names a shell, closed by a fence of the same character, at least
as long, carrying no info string and indented no deeper than the opener. A
fence nested inside another fence is content of the outer one and is not
scanned as a fence of its own. Prose mentions of `$ARGUMENTS` are out of
scope: text a model reads executes nothing.

The match is word-bounded, so `$ARGUMENTS_STRIPPED` alone is not a read.

Every check is a function over a commands directory returning problem
strings (empty means fine), so one function serves the shipped tree, the
`AIMI_ARGUMENTS_GUARD_ROOT` override (a commands directory, in the manner of
`AIMI_PLAN_WIRING_ROOT`) and tmp_path fixtures:

    AIMI_ARGUMENTS_GUARD_ROOT=/path/to/commands python3 -m pytest test_arguments_stay_in_command_bodies.py
"""

import os
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COMMANDS_DIR = ROOT / "commands"
ROOT_ENV = "AIMI_ARGUMENTS_GUARD_ROOT"

SHELLS = {"bash", "sh", "zsh", "shell", "dash", "ksh"}
FENCE_OPEN = re.compile(r"^([ \t]*)(`{3,}|~{3,})(.*)$")
ARGUMENTS_READ = re.compile(r"\$(?:ARGUMENTS\b|\{ARGUMENTS\b)")


def commands_dir():
    """The commands directory under test: the override when set, else the plugin's own."""
    override = os.environ.get(ROOT_ENV)
    return Path(override) if override else COMMANDS_DIR


def shell_fence_lines(text):
    """[(line number, line)] for every line inside a top-level shell fence.

    Opener: three or more backticks or tildes, any indent, an info string whose
    first word names a shell. Closer: the same character, at least as many,
    no info string, indent no deeper than the opener's. Anything between an
    opener and its closer, including a fence-looking line, is content.
    """
    found = []
    opener = None  # (char, length, indent, is_shell)
    for number, line in enumerate(text.split("\n"), start=1):
        m = FENCE_OPEN.match(line)
        if opener is None:
            if m:
                info = m.group(3).strip().split()
                is_shell = bool(info) and info[0].lower() in SHELLS
                if m.group(2)[0] == "`" and "`" in m.group(3):
                    # A backtick fence cannot carry a backtick in its info string:
                    # this is inline code at the start of a line, not an opener.
                    continue
                opener = (m.group(2)[0], len(m.group(2)), len(m.group(1).expandtabs(4)), is_shell)
            continue
        char, length, indent, is_shell = opener
        if (
            m
            and m.group(2)[0] == char
            and len(m.group(2)) >= length
            and not m.group(3).strip()
            and len(m.group(1).expandtabs(4)) <= indent
        ):
            opener = None
            continue
        if is_shell:
            found.append((number, line))
    return found


def arguments_reads(commands):
    """["references/x/y.md:LINE: text"] for each `$ARGUMENTS` read in a shell fence under references/."""
    base = Path(commands)
    refs = base / "references"
    problems = []
    if not refs.is_dir():
        return problems
    for path in sorted(refs.rglob("*.md")):
        text = path.read_text(encoding="utf-8")
        for number, line in shell_fence_lines(text):
            if ARGUMENTS_READ.search(line):
                rel = path.relative_to(base).as_posix()
                problems.append("%s:%d: %s" % (rel, number, line.strip()[:120]))
    return problems


def _write(base, rel, text):
    path = Path(base) / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


# ---------------------------------------------------------------------------
# The shipped tree (or the override root)
# ---------------------------------------------------------------------------


def test_shipped_references_carry_no_arguments_read():
    problems = arguments_reads(commands_dir())
    assert not problems, (
        "a bash fence under commands/references/ reads $ARGUMENTS, which the host "
        "substitutes only in a command body; move the block into the command file:\n"
        + "\n".join(problems)
    )


def test_plan_md_holds_the_arguments_read_and_stripped_producer_and_reader():
    text = (COMMANDS_DIR / "plan.md").read_text(encoding="utf-8")
    reads = [line for _, line in shell_fence_lines(text) if ARGUMENTS_READ.search(line)]
    assert reads, "plan.md has no bash block reading $ARGUMENTS"
    lines = [line for _, line in shell_fence_lines(text)]
    assert any(re.search(r"ARGUMENTS_STRIPPED=", line) for line in lines), "no producer"
    assert any(re.search(r"case \" \$ARGUMENTS_STRIPPED \"", line) for line in lines), "no reader"


# ---------------------------------------------------------------------------
# Fixtures: red
# ---------------------------------------------------------------------------


def _red(tmp_path, fence_text, rel="references/execute/leak.md"):
    _write(tmp_path, rel, "# Leak\n\n" + fence_text)
    problems = arguments_reads(tmp_path)
    assert problems and problems[0].startswith(rel + ":"), problems
    return problems


def test_plain_read_is_red(tmp_path):
    _red(tmp_path, "```bash\necho \"$ARGUMENTS\"\n```\n")


def test_braced_read_is_red(tmp_path):
    _red(tmp_path, "```bash\necho \"${ARGUMENTS}\"\n```\n")


def test_tilde_fence_is_red(tmp_path):
    _red(tmp_path, "~~~bash\necho \"$ARGUMENTS\"\n~~~\n")


def test_indented_fence_is_red(tmp_path):
    _red(tmp_path, "  ```bash\n  echo \"$ARGUMENTS\"\n  ```\n")


def test_other_shell_names_are_red(tmp_path):
    _red(tmp_path, "```sh\necho $ARGUMENTS\n```\n")


def test_nested_directory_is_covered(tmp_path):
    _red(tmp_path, "```bash\necho $ARGUMENTS\n```\n", rel="references/a/b/c/deep.md")


def test_mutated_copy_of_real_references_goes_red(tmp_path):
    copy = tmp_path / "commands"
    shutil.copytree(COMMANDS_DIR / "references", copy / "references")
    assert arguments_reads(copy) == []
    step0 = copy / "references" / "plan" / "step-0-environment-setup.md"
    step0.write_text(
        step0.read_text(encoding="utf-8") + "\n```bash\nFLAGS=\"$ARGUMENTS\"\n```\n",
        encoding="utf-8",
    )
    problems = arguments_reads(copy)
    assert len(problems) == 1
    assert problems[0].startswith("references/plan/step-0-environment-setup.md:")


# ---------------------------------------------------------------------------
# Fixtures: green
# ---------------------------------------------------------------------------


def test_prose_only_mention_is_green(tmp_path):
    _write(tmp_path, "references/execute/prose.md", "Scan `$ARGUMENTS` for a flag.\n\nThe text $ARGUMENTS is read as prose.\n")
    assert arguments_reads(tmp_path) == []


def test_stripped_only_block_is_green(tmp_path):
    _write(
        tmp_path,
        "references/execute/stripped.md",
        "```bash\ncase \" $ARGUMENTS_STRIPPED \" in\n  *\" --x \"*) echo \"${ARGUMENTS_STRIPPED}\";;\nesac\n```\n",
    )
    assert arguments_reads(tmp_path) == []


def test_read_nested_inside_outer_fence_is_green(tmp_path):
    _write(
        tmp_path,
        "references/execute/nested.md",
        "````markdown\n```bash\necho \"$ARGUMENTS\"\n```\n````\n",
    )
    assert arguments_reads(tmp_path) == []


def test_read_in_non_shell_fence_is_green(tmp_path):
    _write(tmp_path, "references/execute/py.md", "```python\nprint('$ARGUMENTS')\n```\n")
    assert arguments_reads(tmp_path) == []


def test_missing_execute_directory_is_not_an_error(tmp_path):
    _write(tmp_path, "references/plan/ok.md", "```bash\ntrue\n```\n")
    assert arguments_reads(tmp_path) == []
    assert arguments_reads(tmp_path / "does-not-exist") == []
