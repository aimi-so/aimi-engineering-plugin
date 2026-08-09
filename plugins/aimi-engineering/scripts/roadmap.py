#!/usr/bin/env python3
"""Roadmap document logic for aimi-cli.sh.

WHY THIS FILE EXISTS, AND WHAT IT IS ALLOWED TO DO
==================================================

aimi-cli.sh keeps the shell-shaped work: argument parsing, `flock`, path
confinement, resolving where the plugin lives. This file owns the part that
reads and rewrites roadmap.json. The split is deliberate and the boundary is
one call per verb -- bash acquires the lock, calls here once, and prints
whatever comes back.

The reason for the split is a measured difference in how the two languages
FAIL. A creates/needs entry is about to stop being the string
"identity (description)" and become {identity, description}, and the question
every reader asks is "what is the identity of this entry". In jq:

    [{identity:"x"}] | [ .[] | select(type == "string") | _cv_identity ]
    => []            exit 0, no diagnostic, guard silently disabled

in Python:

    entry["identity"]  on a str
    => TypeError: string indices must be integers

Both are wrong code. Only one of them says so. Three of the five defects found
while building this contract were of the silent kind -- jq's `.` rebinding
inside a pipe, that type filter, and a backtick inside a double-quoted `echo`
forking a command substitution -- and all three are unrepresentable here.

Two things this file must NOT become:

  * A second opinion. Where a rule already exists in aimi-cli.sh it is ported
    verbatim, message strings included, and the old one is deleted in the same
    commit. Two implementations of "what is a legal identity" is the exact
    disease this whole branch exists to cure.
  * A place that touches the filesystem outside the lock bash holds. Read,
    transform, write to a temp file beside the target, rename. Never open a
    roadmap this process was not handed.

The bash suite (3944 assertions, 119 of them black-box calls to these verbs)
is the fidelity net: a faithful port does not move a single one of them.
"""

import json
import os
import re
import sys
import tempfile

# ---------------------------------------------------------------------------
# The sanitizer, ported from _ROADMAP_SANITIZE_JQ
# ---------------------------------------------------------------------------
#
# Rule order is load-bearing and is preserved exactly. Fenced blocks go first
# so their contents cannot be reinterpreted by a later rule; the backtick span
# unwraps to its inner text rather than being deleted, because deleting it
# destroyed the very token a later phase greps for.
#
# jq's regex engine is Oniguruma and Python's is `re`. Every pattern below was
# compared against the jq original over the corpus in tests/test_roadmap.py --
# `^` and `$` anchor to the whole string in both (no MULTILINE), `.` stops at a
# newline in both, and both count length in codepoints, so the truncation slices
# identically.


def rm_sanitize(value, maxlen):
    """Full prose sanitizer: formatting normalization AND content deletion."""
    if value is None:
        return None
    s = value
    s = re.sub(r"```[\s\S]*?```", "", s)
    s = re.sub(r"`([^`\n]*)`", r"\1", s)
    s = s.replace("`", "")
    s = re.sub(r"\r\n|\r|\n", " ", s)
    s = s.replace("$(", "")
    s = re.sub(r"<[^>]*>", "", s)
    s = re.sub(r"ignore previous( instructions)?", "", s, flags=re.I)
    s = re.sub(r"you are now", "", s, flags=re.I)
    s = re.sub(r"((?:^|\s)[^a-zA-Z0-9]*)system\s*:", r"\1", s, flags=re.I)
    return s[:maxlen] if len(s) > maxlen else s


def rm_markers_only(value, maxlen):
    """The INTENDED-mutation prefix of rm_sanitize: formatting only.

    Every rule rm_sanitize applies beyond this point DELETES CONTENT -- an
    HTML/XML-looking tag such as "<T>", a "$(" opener, an instruction-override
    phrase. That is right for prose and wrong for a name: it rewrote
    "parseList<T>" into "parseList" and then verify-creates went looking for a
    token the phase never produces.

    Keep in step with rm_sanitize: a new FORMATTING rule belongs in both, a new
    CONTENT rule in rm_sanitize alone.
    """
    if value is None:
        return None
    s = value
    s = re.sub(r"```[\s\S]*?```", "", s)
    s = re.sub(r"`([^`\n]*)`", r"\1", s)
    s = s.replace("`", "")
    s = re.sub(r"\r\n|\r|\n", " ", s)
    return s[:maxlen] if len(s) > maxlen else s


def rm_sanitize_contract(value, maxlen):
    """The two rulers applied to mutation: identity formatting-only, description full."""
    if value is None:
        return None
    marked = rm_markers_only(value, maxlen)
    i = marked.find("(")
    if i < 0:
        ident, desc = marked, ""
    else:
        ident, desc = marked[:i], rm_sanitize(marked[i:], maxlen)
    s = ident + desc
    return s[:maxlen] if len(s) > maxlen else s


# ---------------------------------------------------------------------------
# The contract vocabulary, ported from _CONTRACT_JQ_DEFS
# ---------------------------------------------------------------------------

_SHELL_CLASS = re.compile(r"[$`;|&]")

_INJECTION = re.compile(
    r"ignore previous"
    r"|(^|\s)[^a-zA-Z0-9]*system\s*:"
    r"|(^|\s)[^a-zA-Z0-9]*#{1,6}\s*INSTRUCTIONS\b"
    r"|INSTRUCTIONS\s*:"
    r"|```"
    r"|\$\(",
    re.I,
)


def cv_identity(entry):
    """The token verify-creates greps for: everything before the first "(", trimmed.

    THIS FUNCTION HAS A DEADLINE. It exists so that normalize-contracts computes
    each migrated identity with the same rule every pre-migration reader used,
    making the migration byte-identical by construction rather than by testing.
    It retires when the migration retires.
    """
    s = re.sub(r"\(.*", "", entry, count=1)
    return re.sub(r"^[ \t]+|[ \t]+$", "", s)


def cv_injection(s):
    return _INJECTION.search(s) is not None


def cv_shell_char(s):
    m = _SHELL_CLASS.search(s)
    return m.group(0) if m else None


def cv_suspicious(entry):
    return cv_injection(entry) or (
        _SHELL_CLASS.search(entry) is not None
        and _SHELL_CLASS.search(cv_identity(entry)) is not None
    )


# ---------------------------------------------------------------------------
# judge-phases — ported from _roadmap_identity_errors
# ---------------------------------------------------------------------------

_METHOD_PREFIX = re.compile(r"^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS) /")
_DOTDOT_SEGMENT = re.compile(r"(^|/)\.\.($|/)")
_ALNUM = re.compile(r"[a-zA-Z0-9]")
_SEPARATORS_AND_GLOBS = re.compile(r"[*?\[\]/ ]")

_MK_KEY = {"creates": "__mkCreates", "needs": "__mkNeeds"}


def _reject_unfindable_identity(ident):
    """True when verify-creates could never match this token against source.

    The method alternation and the single-space-then-slash shape are
    byte-for-byte the ones verify-creates step 2 strips, so the token judged at
    write time is exactly the token searched at close time. "POST  /api/x" with
    two spaces does not match that shape there and must not match it here.
    CR and LF are in the class as insurance: roadmap-init's sanitizer already
    folds newlines to spaces, but the amend path reaches this helper too and may
    sanitize differently.
    """
    if _METHOD_PREFIX.search(ident):
        ident = re.sub(r"^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS) ", "", ident, count=1)
    return re.search(r"[ \t\r\n]", ident) is not None


def _identity_reasons(entry, ident, marker_form):
    reasons = []
    if len(ident) == 0:
        reasons.append("empty once the description is stripped")
    if _DOTDOT_SEGMENT.search(ident):
        reasons.append('contains a ".." path segment')
    if ident.startswith("/"):
        reasons.append('begins with "/"')
    if _reject_unfindable_identity(ident):
        reasons.append(
            "contains whitespace, so no source token could match it -- name the "
            'symbol, path, table or "METHOD /path" endpoint the phase will '
            "actually produce"
        )
    shell_char = cv_shell_char(ident)
    if shell_char is not None:
        reasons.append(
            'contains the shell metacharacter "'
            + shell_char
            + '", which validate-contracts refuses in an identity -- move that '
            "text into the parenthesised description, or, for an endpoint, "
            "declare the route without its query string"
        )
    if cv_injection(entry):
        reasons.append(
            "matches an instruction-injection pattern validate-contracts "
            "refuses (ignore previous / system: / INSTRUCTIONS: / code fence / "
            '"$(") -- reword it; the description reaches a sub-agent prompt, so '
            "this half is judged on the whole entry, not just the identity"
        )
    if marker_form is not None and cv_identity(marker_form) != ident:
        reasons.append(
            "would be stored under a DIFFERENT identity than the one written: \""
            + cv_identity(marker_form)
            + '" becomes "'
            + ident
            + '". A sanitizer rule that deletes content (an HTML/XML-looking tag '
            'such as "<T>", a "$(" opener, or an instruction-override phrase) '
            "rewrote it, and verify-creates would then grep for a name this "
            "phase never produces -- rename the artifact so it survives verbatim"
        )
    if len(ident) > 0 and not _ALNUM.search(_SEPARATORS_AND_GLOBS.sub("", ident)):
        reasons.append(
            "names nothing in particular -- it is only separators and glob "
            "metacharacters, so verify-creates would match whatever the "
            "repository happens to contain and report the phase verified without "
            "it having built anything. Name the symbol, path, table or "
            '"METHOD /path" endpoint the phase actually produces; a glob is fine '
            'as PART of a path ("db/migrations/*.sql") but not as the whole '
            "identity"
        )
    return reasons


def judge_phases(phases):
    """Return one diagnostic line per indefensible creates/needs/areas entry."""
    out = []
    for phase in phases:
        for list_name in ("creates", "needs"):
            for pos0, raw in enumerate(phase.get(list_name) or []):
                entry = raw if isinstance(raw, str) else ""
                marker_list = phase.get(_MK_KEY[list_name]) or []
                marker_form = marker_list[pos0] if pos0 < len(marker_list) else None
                ident = cv_identity(entry)
                reasons = _identity_reasons(entry, ident, marker_form)
                if not reasons:
                    continue
                shown = (
                    " (content withheld -- it matches an injection pattern)"
                    if cv_injection(entry)
                    else ' "' + entry + '"'
                )
                out.append(
                    "phase "
                    + _num(phase.get("id"))
                    + ": "
                    + list_name
                    + " entry #"
                    + str(pos0 + 1)
                    + shown
                    + " is not a usable artifact identity: "
                    + "; and it ".join(reasons)
                )
    # areas[] is a glob list, not an identity list, so none of the rules above
    # applies -- but it IS joined onto a filesystem path downstream and is
    # exempted from /aimi:plan's pathHints filter on the grounds that
    # "roadmap-init already sanitized it". It never checked traversal. Only the
    # two path shapes are judged.
    for phase in phases:
        for pos0, raw in enumerate(phase.get("areas") or []):
            area = raw if isinstance(raw, str) else ""
            reasons = []
            if _DOTDOT_SEGMENT.search(area):
                reasons.append('contains a ".." path segment')
            if area.startswith("/"):
                reasons.append("is an absolute path")
            if not reasons:
                continue
            out.append(
                "phase "
                + _num(phase.get("id"))
                + ": areas entry #"
                + str(pos0 + 1)
                + ' "'
                + area
                + '" is not a usable scope hint: it '
                + "; and it ".join(reasons)
                + " -- areas are repo-relative globs and are appended to research "
                "path hints as-is"
            )
    return out


def _num(value):
    """Render a JSON number the way jq's tostring does: 2 not 2.0."""
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return str(value)


# ---------------------------------------------------------------------------
# normalize-contracts — the 1.0 -> 2.0 migration
# ---------------------------------------------------------------------------

CONTRACT_VERSION = "2.0"


def nc_description(entry):
    """The exact inverse of cv_identity's cut: from the first "(" on, unwrapped.

    One-way by construction: an entry whose text after the first "(" does not
    end in ")" yields the same pair as one that does, so a single unbalanced
    trailing paren is dropped. Nothing re-glues these, and the half that IS
    compared byte-for-byte downstream -- the identity -- never sees it.
    """
    rest = re.sub(r"^[^(]*", "", entry, count=1)
    if not rest:
        return ""
    rest = re.sub(r"^\(", "", rest, count=1)
    return re.sub(r"\)$", "", rest, count=1)


def nc_entry(entry):
    if isinstance(entry, str):
        return {"identity": cv_identity(entry), "description": nc_description(entry)}
    return entry


def normalize_contracts(doc):
    """Migrate creates/needs to {identity, description}. Idempotent.

    Already-object entries are left untouched, which is what makes a second run
    a no-op. It does NOT judge: a prose or whitespace-bearing identity the
    current writer would refuse migrates unchanged, and the reader reports it
    afterwards by name. Repairing on the way past would silently change what a
    phase promises.
    """
    converted = 0
    for phase in doc.get("phases") or []:
        for list_name in ("creates", "needs"):
            if list_name not in phase:
                continue
            entries = phase[list_name] or []
            converted += sum(1 for e in entries if isinstance(e, str))
            phase[list_name] = [nc_entry(e) for e in entries]
    doc["roadmapVersion"] = CONTRACT_VERSION
    return converted


# ---------------------------------------------------------------------------
# I/O — the only filesystem this file is allowed to touch
# ---------------------------------------------------------------------------


def die(message, code=1):
    sys.stderr.write(message + "\n")
    sys.exit(code)


def read_doc(path, verb):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        # Re-read under the lock can find a file that turned malformed between
        # bash's own check and lock acquisition. Same message bash printed.
        die("Error: " + verb + ": malformed roadmap.json: " + path)


def write_doc_atomically(path, doc):
    """tmp beside the target, then rename. Same discipline every roadmap writer uses."""
    directory = os.path.dirname(path) or "."
    handle = tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=directory, prefix=os.path.basename(path) + ".", delete=False
    )
    try:
        json.dump(doc, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
        handle.close()
        os.replace(handle.name, path)
    except BaseException:
        handle.close()
        try:
            os.unlink(handle.name)
        except OSError:
            pass
        raise


# ---------------------------------------------------------------------------
# Operations, one per aimi-cli.sh call site
# ---------------------------------------------------------------------------


def op_judge_phases(_argv):
    """stdin: a phases array. stdout: one diagnostic line per bad entry."""
    try:
        phases = json.load(sys.stdin)
    except ValueError:
        die("Error: judge-phases: input is not valid JSON")
    for line in judge_phases(phases):
        sys.stdout.write(line + "\n")
    return 0


def op_normalize_contracts(argv):
    path = _flag(argv, "--roadmap")
    if not path:
        die("Usage: roadmap.py normalize-contracts --roadmap <path>")
    doc = read_doc(path, "normalize-contracts")
    converted = normalize_contracts(doc)
    write_doc_atomically(path, doc)
    json.dump(
        {"roadmap": path, "converted": converted, "roadmapVersion": CONTRACT_VERSION},
        sys.stdout,
        indent=2,
    )
    sys.stdout.write("\n")
    return 0


def _flag(argv, name):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return None


_OPS = {
    "judge-phases": op_judge_phases,
    "normalize-contracts": op_normalize_contracts,
}


def main(argv):
    if len(argv) < 2 or argv[1] not in _OPS:
        die("Usage: roadmap.py <" + "|".join(sorted(_OPS)) + "> [flags]", 2)
    return _OPS[argv[1]](argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
