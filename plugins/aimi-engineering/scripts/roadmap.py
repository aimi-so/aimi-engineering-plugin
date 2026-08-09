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
import time

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


def jq_numbers(value):
    """Collapse integral floats to ints, the way jq renders every number.

    jq puts every number through a double and prints the shortest form that
    round-trips, so 2.0 comes back out as 2 and 1e3 as 1000. Python keeps int
    and float apart and would write 2.0 and 1000.0. phases[].id genuinely
    accepts decimals (phase 2.1), so this is a real path, not a curiosity.

    ONE DELIBERATE DIVERGENCE: jq renders 10000000000000000001 as 1e+19,
    because the double cannot hold it. Python keeps it exact and this function
    does not undo that. Reproducing a precision loss would be indefensible, no
    test exercises it, and a phase id that large is not a thing.
    """
    if isinstance(value, bool):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    if isinstance(value, dict):
        return {k: jq_numbers(v) for k, v in value.items()}
    if isinstance(value, list):
        return [jq_numbers(v) for v in value]
    return value


def jq_sort_key(value):
    """jq's total order: null < false < true < numbers < strings < arrays < objects.

    sort_by(.id) has to survive a hand-seeded roadmap whose id is missing or is
    a string, because roadmap.json is a file people edit. Sorting would raise on
    a mixed list without this.
    """
    if value is None:
        return (0, 0)
    if value is False:
        return (1, 0)
    if value is True:
        return (2, 0)
    if isinstance(value, (int, float)):
        return (3, value)
    if isinstance(value, str):
        return (4, value)
    if isinstance(value, list):
        return (5, 0)
    return (6, 0)


# The note aimi-cli.sh prints under every identity refusal. Duplicated from
# _roadmap_identity_note in aimi-cli.sh for exactly as long as roadmap-amend-phase
# still prints it from bash; test_roadmap.py asserts the two are identical so the
# copy cannot drift while it exists.
IDENTITY_NOTE = (
    "Note: an entry is quoted after backtick normalization -- a `x` span becomes x "
    "-- so one submitted with backticks appears here without them. Nothing else "
    "about an identity is rewritten; locate it by its position in the list."
)


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
# roadmap-init — payload validation, sanitization, additive merge
# ---------------------------------------------------------------------------

DIR_REGEX = re.compile(r"^phase-[0-9]+(\.[0-9]+)?(-[a-z0-9][a-z0-9-]*)?$")
BRANCH_REGEX = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9/_-]*$")


def init_validation_errors(phases):
    """Structural validation of the payload. No I/O.

    Grouped by CHECK rather than by phase -- every duplicate id first, then
    every bad id, then every missing name, and so on -- because that is the
    order the jq built its array in and the order callers have been reading.

    ONE DEVIATION FROM THE JQ, DELIBERATE. The jq collected the "dependsOn must
    be an array" message and the per-entry "dependsOn entries must be numbers"
    messages in the same array, so it iterated dependsOn before it could print
    anything -- and iterating a string aborts jq. The result was that passing
    dependsOn: "1" exited 5 with `jq: error ... Cannot iterate over string`, and
    the message the code takes the trouble to write was unreachable. No test
    covers it. There is no faithful port of a crash, so this prints the message
    the code intends and exits 1 like every other validation failure.
    """
    errors = []

    ids = [p.get("id") for p in phases]
    seen, dups = {}, []
    for value in ids:
        key = json.dumps(value, sort_keys=True)
        seen[key] = seen.get(key, 0) + 1
    for value in sorted({json.dumps(v, sort_keys=True): v for v in ids}.values(), key=jq_sort_key):
        if seen[json.dumps(value, sort_keys=True)] > 1:
            dups.append(value)
    for value in dups:
        errors.append("duplicate phase id: " + _num(value))

    for phase in phases:
        if phase.get("id") is None or not isinstance(phase.get("id"), (int, float)) or isinstance(
            phase.get("id"), bool
        ):
            errors.append("phase " + _num(phase.get("id")) + ": id must be a number")
    for phase in phases:
        name = phase.get("name")
        if name is None or not isinstance(name, str) or len(name) == 0:
            errors.append("phase " + _num(phase.get("id")) + ": name is required")
    for phase in phases:
        goal = phase.get("goal")
        if goal is None or not isinstance(goal, str) or len(goal) == 0:
            errors.append("phase " + _num(phase.get("id")) + ": goal is required")
    for phase in phases:
        depends = phase.get("dependsOn")
        if depends is not None and not isinstance(depends, list):
            errors.append("phase " + _num(phase.get("id")) + ": dependsOn must be an array")
    for phase in phases:
        depends = phase.get("dependsOn")
        if not isinstance(depends, list):
            continue
        for entry in depends:
            if not isinstance(entry, (int, float)) or isinstance(entry, bool):
                errors.append(
                    "phase " + _num(phase.get("id")) + ": dependsOn entries must be numbers"
                )
    return errors


def init_sanitize(phases):
    """Sanitize free text, compute dir, and stash the marker forms for the judge.

    __mkCreates/__mkNeeds are scratch for the identity guard's mutation check and
    are never schema -- init_merge drops them before anything reaches disk.
    """
    out = []
    for phase in phases:
        p = dict(phase)
        p["name"] = rm_sanitize(p.get("name"), 200)
        p["goal"] = rm_sanitize(p.get("goal"), 2000)
        p["slug"] = rm_sanitize(p.get("slug") if p.get("slug") is not None else "", 100)
        p["notes"] = rm_sanitize(p["notes"], 5000) if p.get("notes") is not None else None
        p["successCriteria"] = [rm_sanitize(s, 2000) for s in (p.get("successCriteria") or [])]
        p["__mkCreates"] = [rm_markers_only(s, 500) for s in (p.get("creates") or [])]
        p["__mkNeeds"] = [rm_markers_only(s, 500) for s in (p.get("needs") or [])]
        p["creates"] = [rm_sanitize_contract(s, 500) for s in (p.get("creates") or [])]
        p["needs"] = [rm_sanitize_contract(s, 500) for s in (p.get("needs") or [])]
        p["areas"] = [rm_sanitize(s, 500) for s in (p.get("areas") or [])]
        p["dependsOn"] = p.get("dependsOn") or []
        p["branch"] = rm_sanitize(p["branch"], 200) if p.get("branch") is not None else None
        p["dir"] = "phase-" + _num(p.get("id")) + ("-" + p["slug"] if len(p["slug"]) > 0 else "")
        p["status"] = "pending"
        p["claim"] = None
        out.append(p)
    return out


def init_shape_errors(phases):
    """dir and branch pattern checks, in the order the two jq blocks ran."""
    dir_errors = [
        "phase " + _num(p.get("id")) + ': computed dir "' + p["dir"] + '" fails required pattern'
        for p in phases
        if not DIR_REGEX.search(p["dir"])
    ]
    branch_errors = [
        "phase " + _num(p.get("id")) + ': branch "' + p["branch"] + '" contains invalid characters'
        for p in phases
        if p.get("branch") is not None and not BRANCH_REGEX.search(p["branch"])
    ]
    return dir_errors, branch_errors


def dangling_errors(phases_to_check, allowed_ids):
    return [
        "phase "
        + _num(p.get("id"))
        + ": dependsOn references unknown phase id "
        + _num(dep)
        for p in phases_to_check
        for dep in (p.get("dependsOn") or [])
        if dep not in allowed_ids
    ]


def _without_markers(phases):
    return [{k: v for k, v in p.items() if k not in ("__mkCreates", "__mkNeeds")} for p in phases]


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


def _die_list(header, lines, note=False):
    sys.stderr.write(header + "\n")
    for line in lines:
        sys.stderr.write(line + "\n")
    if note:
        sys.stderr.write(IDENTITY_NOTE + "\n")
    sys.exit(1)


def op_init_validate(_argv):
    """Everything roadmap-init checks BEFORE it takes the lock.

    Split from init-write for one reason: today an invalid payload never
    reaches `mkdir -p`, so it never creates the feature directory. Doing
    validation inside the lock would create it as a side effect of a refusal.
    """
    raw = sys.stdin.read()
    try:
        payload = jq_numbers(json.loads(raw))
    except ValueError:
        die("Error: roadmap-init: phases payload must be a JSON array")
    if not isinstance(payload, list):
        die("Error: roadmap-init: phases payload must be a JSON array")

    errors = init_validation_errors(payload)
    if errors:
        _die_list("Error: roadmap-init: invalid phase payload:", errors)

    phases = init_sanitize(payload)
    dir_errors, branch_errors = init_shape_errors(phases)
    if dir_errors:
        _die_list("Error: roadmap-init: invalid phase directory slug(s):", dir_errors)
    if branch_errors:
        _die_list("Error: roadmap-init: invalid branch name(s):", branch_errors)

    json.dump(phases, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def op_init_write(argv):
    """The locked read-modify-write. stdin is init-validate's sanitized phases."""
    path = _flag(argv, "--roadmap")
    feature = _flag(argv, "--feature")
    brainstorm_path = _flag(argv, "--brainstorm-path") or ""
    sync_mode = "--sync" in argv
    if not path or not feature:
        die("Usage: roadmap.py init-write --roadmap <path> --feature <slug> [--sync]")

    new_phases = jq_numbers(json.load(sys.stdin))

    if os.path.exists(path):
        if not sync_mode:
            die("Error: roadmap-init: " + path + " already exists; pass --sync to merge additively")
        try:
            with open(path, "r", encoding="utf-8") as handle:
                existing = jq_numbers(json.load(handle))
        except (OSError, ValueError):
            die("Error: roadmap-init: existing roadmap.json is malformed: " + path)

        existing_phases = existing.get("phases") or []
        existing_ids = [p.get("id") for p in existing_phases]
        # Anti-clobber: a phase this roadmap already holds is never revisited.
        filtered_new = [p for p in new_phases if p.get("id") not in existing_ids]

        # Allowed ids are existing-file ids unioned with this payload's own, so a
        # --sync phase may depend on one an earlier call materialized AND on a
        # sibling introduced in the same call.
        allowed = existing_ids + [p.get("id") for p in new_phases]
        dangling = dangling_errors(filtered_new, allowed)
        if dangling:
            _die_list("Error: roadmap-init: dangling dependsOn reference(s):", dangling)

        # Judged over filtered_new ONLY -- the phases this call actually writes.
        # Over the whole payload, a legacy phase would make plan.md's full-array
        # submission fail forever, and both its call sites downgrade the failure
        # to a warning, so the new phase would vanish with nothing reported.
        identity = judge_phases(filtered_new)
        if identity:
            _die_list(
                "Error: roadmap-init: malformed creates/needs identity in new phase(s):",
                identity,
                note=True,
            )

        merged = existing_phases + _without_markers(filtered_new)
        merged.sort(key=lambda p: jq_sort_key(p.get("id")))
        # Only these four top-level keys survive a --sync, exactly as before.
        doc = {k: existing.get(k) for k in ("roadmapVersion", "feature", "createdAt", "brainstormPath")}
        doc["phases"] = merged
        added_count = len(filtered_new)
    else:
        allowed = [p.get("id") for p in new_phases]
        dangling = dangling_errors(new_phases, allowed)
        if dangling:
            _die_list("Error: roadmap-init: dangling dependsOn reference(s):", dangling)

        identity = judge_phases(new_phases)
        if identity:
            _die_list(
                "Error: roadmap-init: malformed creates/needs identity in new phase(s):",
                identity,
                note=True,
            )

        merged = _without_markers(new_phases)
        merged.sort(key=lambda p: jq_sort_key(p.get("id")))
        doc = {
            "roadmapVersion": "1.0",
            "feature": feature,
            "createdAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "brainstormPath": rm_sanitize(brainstorm_path, 500) if brainstorm_path else None,
            "phases": merged,
        }
        added_count = len(merged)

    write_doc_atomically(path, doc)
    json.dump(
        {"roadmap": path, "added": added_count, "phases": len(merged)}, sys.stdout, indent=2
    )
    sys.stdout.write("\n")
    return 0


_OPS = {
    "judge-phases": op_judge_phases,
    "normalize-contracts": op_normalize_contracts,
    "init-validate": op_init_validate,
    "init-write": op_init_write,
}


def main(argv):
    if len(argv) < 2 or argv[1] not in _OPS:
        die("Usage: roadmap.py <" + "|".join(sorted(_OPS)) + "> [flags]", 2)
    return _OPS[argv[1]](argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
