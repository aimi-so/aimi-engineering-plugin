"""Mechanically extracts every jq invocation that OPENS A FILE from the bash
blocks test-command-blocks.sh's extract_blocks() pulls out of commands/**/*.md,
executes each one against an adversarial tasks.json corpus in a shell that
reproduces the agent's own environment (no set -euo pipefail; AIMI_PLUGIN_DIR
and CLAUDECODE unset), and prints one JSON object to stdout.

This is EXTRACTION, not transcription: the caller (capture-command-block-jq.sh)
runs the shared extract_blocks() awk mechanism from lib/extract-command-blocks.sh
-- the exact same one test-command-blocks.sh uses, addressed by the exact same
heading rule -- and hands this module the resulting block files plus the
id/relpath/startline/heading index. Nothing here reads commands/*.md directly,
and nothing here was hand-copied from a planning note: a site is found because
a `jq` invocation in an extracted block has a trailing positional operand that
looks like a variable reference (the only shape every real site in this tree
uses), never because its file:line was listed anywhere.

Never touches the repository's own .aimi/tasks -- every fixture lives under a
throwaway root this process creates and removes; the subprocess env passed to
each probe carries only PATH and HOME (pointed at that throwaway root), so
AIMI_PLUGIN_DIR and CLAUDECODE are absent by construction, not by unset.

Usage:
    python3 capture_command_block_jq.py --blocks-dir DIR --index FILE \
        --commands-dir DIR [--sites-only] > out.json

--sites-only prints just {"sites": [...]} -- no fixture is built and no probe
is run -- for a caller that only needs the live count and file distribution.
"""

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile

# ---------------------------------------------------------------------------
# Step 1 -- read the index + block files extract_blocks() already produced
# ---------------------------------------------------------------------------


def read_index(index_path):
    rows = []
    with open(index_path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            block_id, relpath, startline, heading = line.split("\t", 3)
            rows.append(
                {"id": block_id, "relpath": relpath, "startline": int(startline), "heading": heading}
            )
    return rows


def read_block_lines(blocks_dir, block_id):
    path = os.path.join(blocks_dir, f"{block_id}.sh")
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]
    return lines


# ---------------------------------------------------------------------------
# Step 2 -- find every jq invocation with a trailing file operand
#
# A "site" is a `jq [flags] 'PROGRAM' [args]` call whose LAST positional token
# is a bare variable reference ($NAME or ${NAME}, possibly joined with other
# text). A call with no such trailing token reads stdin -- almost always
# `printf '%s' "$var" | jq ...` -- and is deliberately excluded: it never opens
# a file, so it is out of scope for this corpus by the AC's own definition.
# ---------------------------------------------------------------------------

JQ_WORD = re.compile(r"(?<![\w.\-])jq(?![\w\-])")
REDIR_TOKEN = re.compile(r"^[0-9]*>&?[0-9A-Za-z/._-]*$|^&[0-9]$")
VAR_RE = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?")


def _strip_comment(line):
    """Return line with a trailing shell comment removed, quote-aware -- so a
    `# ... jq ...` remark is never mistaken for an invocation start."""
    q = None
    i = 0
    while i < len(line):
        c = line[i]
        if q:
            if c == "\\":
                i += 2
                continue
            if c == q:
                q = None
            i += 1
            continue
        if c in "'\"":
            q = c
            i += 1
            continue
        if c == "#":
            return line[:i]
        i += 1
    return line


def _quote_balanced(text):
    count = 0
    i = 0
    while i < len(text):
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == "'":
            count += 1
        i += 1
    return count % 2 == 0


def _assemble_statements(lines):
    """Group block lines into logical jq-bearing statements: a line whose
    (comment-stripped) text starts a jq invocation, plus every following line
    needed to balance single quotes or satisfy a trailing backslash
    continuation. Returns [(start_idx, joined_text)] in line order."""
    out = []
    i = 0
    n = len(lines)
    while i < n:
        if JQ_WORD.search(_strip_comment(lines[i])):
            start = i
            buf = [lines[i]]
            j = i
            while True:
                joined = "\n".join(buf)
                cont = joined.rstrip().endswith("\\")
                if cont or not _quote_balanced(joined):
                    j += 1
                    if j >= n:
                        break
                    buf.append(lines[j])
                    continue
                break
            out.append((start, "\n".join(buf)))
            i = j + 1
        else:
            i += 1
    return out


def _paren_depth(text):
    depth = 0
    q = None
    i = 0
    while i < len(text):
        c = text[i]
        if q:
            if c == "\\":
                i += 2
                continue
            if c == q:
                q = None
            i += 1
            continue
        if c in "'\"":
            q = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        i += 1
    return depth


def _extract_jq_call(text, jq_pos):
    """From a `jq` keyword position inside `text`, return the substring
    covering just this invocation: from `jq` through its last token, stopping
    (outside quotes) at the point where paren depth would fall below the depth
    seen just before `jq`, or an unquoted statement terminator is hit at that
    same depth. This is what strips the surrounding `VAR=$(...)`, `if ... ;
    then` or `done < <(...)` wrapper without needing to recognize any of those
    forms by name -- the boundary is depth and quoting, not shape."""
    base_depth = _paren_depth(text[:jq_pos])
    depth = base_depth
    q = None
    i = jq_pos
    n = len(text)
    end = n
    while i < n:
        c = text[i]
        if q:
            if c == "\\":
                i += 2
                continue
            if c == q:
                q = None
            i += 1
            continue
        if c in "'\"":
            q = c
            i += 1
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            if depth <= base_depth:
                end = i
                break
            depth -= 1
        elif depth == base_depth:
            if c == ";":
                end = i
                break
            if c == "|" and text[i : i + 2] != "||":
                end = i
                break
            if text[i : i + 2] == "&&":
                end = i
                break
            if text[i : i + 4] == "then" and (i == 0 or text[i - 1].isspace()):
                end = i
                break
        i += 1
    return text[jq_pos:end].rstrip()


def _tail_after_program(tokens):
    """tokens is the shlex-split call, tokens[0] == 'jq'. Skip flags and
    --arg/--argjson/--slurpfile/--rawfile NAME VALUE pairs, then the program
    string; return (program_token, remaining_positional_tokens) with redirect
    tokens (2>/dev/null, >/dev/null, 2>&1, ...) dropped from the remainder."""
    i = 1
    n = len(tokens)
    program_idx = None
    while i < n:
        t = tokens[i]
        if t in ("--arg", "--argjson", "--slurpfile", "--rawfile"):
            i += 3
            continue
        if t.startswith("-"):
            i += 1
            continue
        program_idx = i
        break
    if program_idx is None:
        return None, []
    rest = [t for t in tokens[program_idx + 1 :] if not REDIR_TOKEN.match(t)]
    return tokens[program_idx], rest


def find_jq_sites(relpath, startline, heading, block_lines):
    """Yield one dict per file-opening jq invocation found in this block."""
    found = []
    for start_idx, statement in _assemble_statements(block_lines):
        for m in JQ_WORD.finditer(statement):
            jq_pos = m.start()
            call_text = _extract_jq_call(statement, jq_pos)
            if "'" not in call_text:
                continue  # every real jq PROGRAM in this tree is single-quoted
            try:
                # A backslash-newline is a shell line continuation -- it joins
                # two lines into one and is not itself a token. shlex (unlike
                # bash) has no such rule, so it is removed before tokenizing;
                # the ORIGINAL call_text (continuation intact) is still what
                # gets recorded as the verbatim expression below.
                tokens = shlex.split(call_text.replace("\\\n", " "), posix=True)
            except ValueError:
                continue
            if not tokens or tokens[0] != "jq":
                continue
            program, tail = _tail_after_program(tokens)
            if program is None or len(tail) != 1:
                continue
            operand = tail[0]
            if not operand.startswith("$"):
                continue  # the only file-operand shape this tree uses
            found.append(
                {
                    "file": relpath,
                    "line": startline + start_idx,
                    "heading": heading,
                    "expression": call_text,
                    "program": program,
                    "operand": operand,
                }
            )
    return found


# ---------------------------------------------------------------------------
# Step 3 -- classify each site into one of the seven question-groups
# ---------------------------------------------------------------------------


def classify(program):
    p = program
    if ".metadata.branchName" in p:
        return "branch-name", "which branch does this tasks file target"
    if ".metadata.execution" in p:
        return "execution-mode", "does this tasks file run inline or inside a container"
    if ".metadata.type" in p:
        return "metadata-type", "what commit-type prefix does this tasks file's feature carry"
    if ".metadata.splitGroup" in p:
        if ".total" in p:
            return "split-group", "how many members does this project-split group declare"
        if "siblings" in p:
            return "split-group", "which other files belong to this project-split group"
        if "type)" in p and "object" in p:
            return "split-group", "does this file carry a well-formed project-split marker"
        return "split-group", "which project does this split member's own marker name"
    if "strategy" in p and "visual" in p:
        return "verification-visual", "how many (or which) stories in this tasks file are visual-verification stories"
    if ".verification.url" in p:
        return "verification-visual", "what live URL does this story's verification block name"
    if "verification" in p and ("!= null" in p or "type !=" in p):
        return "verification-visual", "which stories carry a malformed (non-object) verification block"
    if "pending" in p and "completed" in p:
        return "pending-count", "how many stories in this tasks file are not yet completed"
    if ".project" in p:
        return "project-grouping", "which project does this story (or split member) belong to"
    return "other", "uncategorized jq read"


# ---------------------------------------------------------------------------
# Step 4 -- the adversarial corpus
#
# Every AC5 shape gets its own fixture rather than one fixture combining many
# of them, because the property under test is that each question-GROUP
# answers DIFFERENTLY *across* the corpus -- a single overstuffed fixture is
# one sample point and proves nothing about that.
# ---------------------------------------------------------------------------

_NO_KEY = object()


def _story(
    id_="US-001",
    title="Do the thing",
    status="completed",
    project=_NO_KEY,
    verification=_NO_KEY,
):
    s = {"id": id_, "title": title, "status": status, "dependsOn": []}
    if project is not _NO_KEY:
        s["project"] = project
    if verification is not _NO_KEY:
        s["verification"] = verification
    if status is _NO_KEY:
        del s["status"]
    return s


def _mk(metadata=_NO_KEY, stories=_NO_KEY):
    doc = {"schemaVersion": "3.3"}
    if metadata is not _NO_KEY:
        doc["metadata"] = metadata
    if stories is not _NO_KEY:
        doc["userStories"] = stories
    return json.dumps(doc, indent=2, sort_keys=True) + "\n"


def _base_metadata(**overrides):
    m = {"title": "ref: corpus fixture", "type": "ref", "branchName": "ref/corpus-fixture"}
    m.update(overrides)
    return m


_DEFAULT_STORIES = [
    _story("US-001", "First", "completed", project="apps/api"),
    _story("US-002", "Second", "pending", project="apps/web"),
]


def build_fixtures():
    return [
        ("no-metadata", _mk(stories=_DEFAULT_STORIES)),
        ("metadata-null", _mk(metadata=None, stories=_DEFAULT_STORIES)),
        (
            "branchname-missing",
            _mk(metadata={"title": "ref: x", "type": "ref"}, stories=_DEFAULT_STORIES),
        ),
        (
            "branchname-nonstring-array",
            _mk(metadata=_base_metadata(branchName=["a", "b", "c", "d"]), stories=_DEFAULT_STORIES),
        ),
        ("execution-absent", _mk(metadata=_base_metadata(), stories=_DEFAULT_STORIES)),
        ("execution-inline", _mk(metadata=_base_metadata(execution="inline"), stories=_DEFAULT_STORIES)),
        (
            "execution-container",
            _mk(metadata=_base_metadata(execution="container"), stories=_DEFAULT_STORIES),
        ),
        (
            "execution-unrecognized",
            _mk(metadata=_base_metadata(execution="bogus-mode"), stories=_DEFAULT_STORIES),
        ),
        ("userstories-absent", _mk(metadata=_base_metadata())),
        ("userstories-empty", _mk(metadata=_base_metadata(), stories=[])),
        (
            "stories-with-project",
            _mk(
                metadata=_base_metadata(),
                stories=[
                    _story("US-001", "A", "completed", project="apps/api"),
                    _story("US-002", "B", "pending", project="apps/web"),
                    _story("US-003", "C", "pending", project="."),
                ],
            ),
        ),
        (
            "stories-without-project",
            _mk(
                metadata=_base_metadata(),
                stories=[_story("US-001", "A", "completed"), _story("US-002", "B", "pending")],
            ),
        ),
        (
            "story-no-status",
            _mk(metadata=_base_metadata(), stories=[_story("US-001", "A", status=_NO_KEY)]),
        ),
        (
            "all-completed",
            _mk(
                metadata=_base_metadata(),
                stories=[_story("US-001", "A", "completed"), _story("US-002", "B", "completed")],
            ),
        ),
        (
            "splitgroup-present-siblings-populated",
            _mk(
                metadata=_base_metadata(
                    splitGroup={
                        "project": "apps/api",
                        "index": 1,
                        "total": 2,
                        "siblings": ["demo-feature-apps-web-tasks.json"],
                    }
                ),
                stories=_DEFAULT_STORIES,
            ),
        ),
        ("splitgroup-absent", _mk(metadata=_base_metadata(), stories=_DEFAULT_STORIES)),
        (
            "splitgroup-siblings-empty",
            _mk(
                metadata=_base_metadata(
                    splitGroup={"project": "apps/api", "index": 1, "total": 1, "siblings": []}
                ),
                stories=_DEFAULT_STORIES,
            ),
        ),
        (
            "verification-absent",
            _mk(metadata=_base_metadata(), stories=[_story("US-001", "A", "pending")]),
        ),
        (
            "verification-null",
            _mk(
                metadata=_base_metadata(),
                stories=[_story("US-001", "A", "pending", verification=None)],
            ),
        ),
        (
            "verification-string",
            _mk(
                metadata=_base_metadata(),
                stories=[_story("US-001", "A", "pending", verification="visual (manual)")],
            ),
        ),
        (
            "verification-object-no-url",
            _mk(
                metadata=_base_metadata(),
                stories=[
                    _story(
                        "US-001", "A", "pending", verification={"strategy": "visual", "status": "pending"}
                    )
                ],
            ),
        ),
        (
            "verification-object-with-url",
            _mk(
                metadata=_base_metadata(),
                stories=[
                    _story(
                        "US-001",
                        "A",
                        "pending",
                        verification={
                            "strategy": "visual",
                            "status": "pending",
                            "url": "http://localhost:4000/y",
                        },
                    )
                ],
            ),
        ),
        (
            "id-literal-placeholder-with-url",
            _mk(
                metadata=_base_metadata(),
                stories=[
                    _story(
                        "[full_story.id]",
                        "Placeholder id",
                        "pending",
                        verification={
                            "strategy": "visual",
                            "status": "pending",
                            "url": "http://localhost:5000/z",
                        },
                    )
                ],
            ),
        ),
        ("type-fix", _mk(metadata=_base_metadata(type="fix"), stories=_DEFAULT_STORIES)),
        (
            "type-absent",
            _mk(
                metadata={"title": "ref: x", "branchName": "ref/x"},
                stories=_DEFAULT_STORIES,
            ),
        ),
        ("malformed-document", '{"schemaVersion": "3.3", "metadata": {\n'),
    ]


# ---------------------------------------------------------------------------
# Step 5 -- bind each site's referenced variables to a fixture, and execute
# ---------------------------------------------------------------------------

DEFAULT_VAR_VALUES = {"GROUP_PROJECT": "."}


def build_env_for_site(call_text, operand, content, case_root):
    """Write `content` under case_root at the path the (unmodified) operand
    template resolves to once its variables are bound, and return the env-var
    bindings that make it resolve there. The one non-generic case is a nested
    command substitution around another jq read of a small JSON blob supplied
    by a plain variable (execute.md's SPLIT_EXECUTION_MODE derivation) --
    named here because it is the only site in this tree shaped that way."""
    env = {}
    if "$(" in operand:
        nested_vars = VAR_RE.findall(operand)
        if "SPLIT_PLAN" not in nested_vars:
            raise ValueError(f"unhandled nested-substitution operand: {operand!r}")
        target = os.path.join(case_root, "nested-target-tasks.json")
        with open(target, "w", encoding="utf-8") as fh:
            fh.write(content)
        env["SPLIT_PLAN"] = json.dumps({"file": target})
    else:
        var_names = VAR_RE.findall(operand)
        if not var_names:
            resolved = operand
        else:
            bindings = {v: DEFAULT_VAR_VALUES.get(v, f"seg-{v.lower()}") for v in var_names}
            resolved = VAR_RE.sub(lambda m: bindings[m.group(1)], operand)
            env.update(bindings)
        if not os.path.isabs(resolved):
            resolved = os.path.join(case_root, resolved)
        os.makedirs(os.path.dirname(resolved), exist_ok=True)
        with open(resolved, "w", encoding="utf-8") as fh:
            fh.write(content)

    # Any OTHER $VAR referenced elsewhere in the call (e.g. --arg p
    # "$GROUP_PROJECT") that the operand binding above didn't already cover.
    for v in VAR_RE.findall(call_text):
        if v not in env:
            env[v] = DEFAULT_VAR_VALUES.get(v, f"seg-{v.lower()}")
    return env


def run_case(call_text, env_vars, case_root):
    """Execute call_text as its own shell -- no set -euo pipefail, matching
    the environment these blocks actually run in, one block per shell -- and
    report exit status, raw stdout, stderr, and what a shell VARIABLE holding
    the command-substituted value would contain (bash's $(...) strips every
    trailing newline; interior newlines survive, which is how a non-string
    jq -r answer materializing as several lines is observed rather than
    guessed)."""
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": case_root}
    env.update(env_vars)
    proc = subprocess.run(
        ["bash", "-c", call_text],
        cwd=case_root,
        env=env,
        capture_output=True,
        text=True,
        timeout=10,
    )
    stdout = proc.stdout
    var_value = stdout.rstrip("\n")
    shell_lines = 0 if var_value == "" else var_value.count("\n") + 1
    return {
        "exit": proc.returncode,
        "stdout": stdout,
        "stderr": proc.stderr,
        "shellValue": var_value,
        "shellLines": shell_lines,
    }


def _normalize(text, master_root, real_root):
    text = text.replace(master_root, "/FIXTURE-ROOT")
    if real_root != master_root:
        text = text.replace(real_root, "/FIXTURE-ROOT")
    return text


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def extract_sites(blocks_dir, index_path):
    rows = read_index(index_path)
    sites = []
    for row in rows:
        block_lines = read_block_lines(blocks_dir, row["id"])
        sites.extend(find_jq_sites(row["relpath"], row["startline"], row["heading"], block_lines))
    sites.sort(key=lambda s: (s["file"], s["line"], s["expression"]))
    for i, s in enumerate(sites, 1):
        s["id"] = f"site-{i:03d}"
        group, question = classify(s["program"])
        s["group"] = group
        s["question"] = question
    return sites


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--blocks-dir", required=True)
    parser.add_argument("--index", required=True)
    parser.add_argument("--commands-dir", required=True)  # unused directly; documents provenance
    parser.add_argument("--sites-only", action="store_true")
    args = parser.parse_args()

    sites = extract_sites(args.blocks_dir, args.index)

    if args.sites_only:
        json.dump({"sites": sites}, sys.stdout, sort_keys=True, indent=2)
        sys.stdout.write("\n")
        return

    fixtures = build_fixtures()
    master_root = tempfile.mkdtemp(prefix="cbjq-")
    real_root = os.path.realpath(master_root)
    cases = []
    try:
        for s in sites:
            for label, content in fixtures:
                case_root = os.path.join(master_root, f"{s['id']}-{label}")
                os.makedirs(case_root, exist_ok=True)
                env_vars = build_env_for_site(s["expression"], s["operand"], content, case_root)
                result = run_case(s["expression"], env_vars, case_root)
                for k in ("stdout", "stderr", "shellValue"):
                    result[k] = _normalize(result[k], master_root, real_root)
                cases.append(
                    {
                        "site": s["id"],
                        "file": s["file"],
                        "line": s["line"],
                        "heading": s["heading"],
                        "group": s["group"],
                        "question": s["question"],
                        "expression": s["expression"],
                        "fixture": label,
                        "input": content,
                        **result,
                    }
                )
    finally:
        import shutil

        shutil.rmtree(master_root, ignore_errors=True)

    json.dump({"sites": sites, "cases": cases}, sys.stdout, sort_keys=True, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
