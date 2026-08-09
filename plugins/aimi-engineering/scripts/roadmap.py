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
import subprocess
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
# roadmap-amend-phase
# ---------------------------------------------------------------------------
#
# The amendable set is exactly six keys, and the discriminator is "contract
# field with no other writer". branch IS amendable for precisely that reason --
# roadmap-init sets it at creation and --sync never revisits it, which is why a
# decimal phase's null branch could not be filled in. status and claim are NOT,
# on the opposite ground: roadmap-set-status owns status and roadmap-claim owns
# claim, and a second writer would duplicate those guarantees rather than reuse
# them.
AMENDABLE_KEYS = ["goal", "successCriteria", "creates", "needs", "areas", "branch"]

_PHASE_IDENTITY_KEYS = ["id", "dir", "slug", "name", "dependsOn"]


def _v1_string_entries(entries):
    """Reproduces `select(type == "string")` from the 1.0 schema.

    DELETED IN THE SCHEMA COMMIT -- on one line, because that is the grep.

    Today it discards nothing: in 1.0 every creates/needs entry IS a string. It
    only becomes a hazard when an entry becomes {identity, description}, at
    which point this filter would silently drop every entry instead of failing
    -- disabling the orphan check, the dropped/added diff, retarget resolution,
    the duplicate check and the downstream rewrite, without one line of error.
    That was measured, not theorised.

    It exists as a named helper rather than thirteen filters buried in
    pipelines so that removing it is `grep _v1_string_entries` rather than
    archaeology. When it goes, `entry["identity"]` raises on a malformed entry,
    which is the entire reason this file is in Python.
    """
    return [e for e in entries if isinstance(e, str)]


def _identities(phase, key):
    return [cv_identity(e) for e in _v1_string_entries(phase.get(key) or [])]


def amend_key_errors(payload):
    """Six-key allowlist, with the two owned keys redirected to their owner."""
    errors = []
    for key in payload.keys():  # insertion order, like jq's keys_unsorted
        if key in AMENDABLE_KEYS:
            continue
        if key == "status":
            why = " -- phase status is owned by roadmap-set-status"
        elif key == "claim":
            why = " -- phase claims are owned by roadmap-claim / roadmap-release-claim"
        elif key in _PHASE_IDENTITY_KEYS:
            why = " -- it is phase identity, written once by roadmap-init"
        else:
            why = " -- amendable fields are: " + ", ".join(AMENDABLE_KEYS)
        errors.append('  "' + key + '" is not amendable' + why)
    return errors


def amend_type_errors(payload):
    errors = []
    if "goal" in payload and (not isinstance(payload["goal"], str) or len(payload["goal"]) == 0):
        errors.append("  goal must be a non-empty string")
    if "branch" in payload and payload["branch"] is not None and not isinstance(
        payload["branch"], str
    ):
        errors.append("  branch must be a string or null")
    for key in ("successCriteria", "creates", "needs", "areas"):
        if key not in payload:
            continue
        if not isinstance(payload[key], list):
            errors.append("  " + key + " must be an array of strings")
        elif any(not isinstance(e, str) for e in payload[key]):
            errors.append("  " + key + " entries must all be strings")
    return errors


def amend_sanitize(payload):
    """The same sanitizer and the same caps roadmap-init applies to a fresh phase."""
    p = dict(payload)
    if "goal" in p:
        p["goal"] = rm_sanitize(p["goal"], 2000)
    if "successCriteria" in p:
        p["successCriteria"] = [rm_sanitize(s, 2000) for s in p["successCriteria"]]
    if "creates" in p:
        p["__mkCreates"] = [rm_markers_only(s, 500) for s in p["creates"]]
    if "needs" in p:
        p["__mkNeeds"] = [rm_markers_only(s, 500) for s in p["needs"]]
    if "creates" in p:
        p["creates"] = [rm_sanitize_contract(s, 500) for s in p["creates"]]
    if "needs" in p:
        p["needs"] = [rm_sanitize_contract(s, 500) for s in p["needs"]]
    if "areas" in p:
        p["areas"] = [rm_sanitize(s, 500) for s in p["areas"]]
    if "branch" in p:
        p["branch"] = None if p["branch"] is None else rm_sanitize(p["branch"], 200)
    return p


def amend_orphan_rows(stored, amended, doc, authorized):
    """Downstream needs entries that cite a creates identity this drop removes.

    Comparison is exact equality throughout, never substring containment: this
    repository's own roadmap has phases citing "account override applied inside
    the forge command surface" verbatim, and a substring rule would let a
    partial-word rewrite corrupt both.
    """
    new = set(_identities(amended, "creates"))
    orphaned = {
        i for i in _identities(stored, "creates") if i not in new and i not in set(authorized)
    }
    rows = {
        (p.get("id"), ident)
        for p in doc.get("phases") or []
        if p.get("id") != amended.get("id")
        for ident in _identities(p, "needs")
        if ident in orphaned
    }
    return sorted(rows, key=lambda t: (jq_sort_key(t[0]), t[1]))


# ---------------------------------------------------------------------------
# verify-creates — prove a phase's creates[] exist in code, not in prose
# ---------------------------------------------------------------------------
#
# Every pattern uses the LONG ":(exclude)" form. The short "!" form is not
# interchangeable -- git reads the character after the colon as pathspec magic,
# so ':!__tests__/*' aborts the whole invocation with
#   fatal: Unimplemented pathspec magic '_' in ':!__tests__/*'
# and exit 128, which would turn every artifact of every phase into "missing".
#
# Default pathspec matching is fnmatch without FNM_PATHNAME -- "*" crosses "/"
# -- so "*.md" excludes .md files at any depth, while "docs/*" is anchored at
# the search root and needs the "*/docs/*" companion for nested copies.
#
# .aimi/* is excluded for a specific reason: roadmap.json holds the creates[]
# strings themselves, so without it every identity would find itself in the very
# file that declared it.
VERIFY_CREATES_EXCLUDES = [
    ":(exclude)*.md",
    ":(exclude)*.mdx",
    ":(exclude)*.rst",
    ":(exclude)*.adoc",
    ":(exclude)*.txt",
    ":(exclude)docs/*",
    ":(exclude)doc/*",
    ":(exclude)documentation/*",
    ":(exclude)*/docs/*",
    ":(exclude)*/doc/*",
    ":(exclude)*/documentation/*",
    ":(exclude)README*",
    ":(exclude)CHANGELOG*",
    ":(exclude)CONTRIBUTING*",
    ":(exclude).aimi/*",
    ":(exclude)*_test.*",
    ":(exclude)*.test.*",
    ":(exclude)*_spec.*",
    ":(exclude)*.spec.*",
    ":(exclude)test/*",
    ":(exclude)tests/*",
    ":(exclude)spec/*",
    ":(exclude)__tests__/*",
    ":(exclude)*/test/*",
    ":(exclude)*/tests/*",
    ":(exclude)*/spec/*",
    ":(exclude)*/__tests__/*",
]

# The tracked-files caveat, stated in every "missing" verdict so the caller
# reports the limit instead of silently owning it.
VERIFY_CREATES_TRACKED_NOTE = (
    "Note: git ls-files and git grep see tracked (committed) files only, so "
    "uncommitted work reads as missing."
)

_HTTP_METHODS = ("GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS")

_MARKER_LINE = re.compile(
    r"^[ \t]*(//+|#+|--+|\*+|/\*+|<!--)[ \t]*(TODO|FIXME|XXX|HACK)([^A-Za-z0-9_]|$)"
)


def _git(directory, *args):
    """Run git and return (stdout, returncode).

    Argument-list form, never a shell string. The pathspecs below carry ":", "*"
    and "(" -- characters a shell would be free to reinterpret -- and the
    pathspec defect this verb was fixed for came from exactly that. There is no
    quoting layer here to get wrong.
    """
    proc = subprocess.run(
        ["git", "-C", directory] + list(args),
        capture_output=True,
        text=True,
    )
    return proc.stdout, proc.returncode


def is_doc_identity(identity):
    """True when the identity names documentation ITSELF.

    For those, a hit under docs/ IS the artifact rather than a mention of it, so
    the exclusion list is bypassed for that one entry.
    """
    return (
        identity.startswith("docs/")
        or identity.startswith("doc/")
        or "/docs/" in identity
        or "/doc/" in identity
        or identity.endswith((".md", ".rst", ".adoc", ".txt"))
    )


def is_marker_line(content):
    """True when a matched line is nothing but a TODO/FIXME/XXX/HACK marker in a
    comment -- a note that the work is still owed, which must never count as the
    work being done."""
    return _MARKER_LINE.search(content) is not None


def _verdict(identity, status, method, evidence, git_status):
    return {
        "identity": identity,
        "status": status,
        "method": method or None,
        "evidence": evidence,
        "gitStatus": git_status,
    }


def verify_creates_one(directory, identity):
    """Verify ONE creates identity against <directory>'s tracked files.

    Always returns a verdict: "missing" or "error" is data, not failure.
    gitStatus is the HIGHEST exit status any git invocation returned for this
    entry -- 0 or 1 in normal operation, above 1 only on tool failure, and that
    is the line between "the phase did not build it" and "we could not look".
    """
    git_max = 0
    if not identity:
        return _verdict(
            identity,
            "missing",
            "",
            "Malformed creates entry: empty artifact identity (expected "
            '"<artifact-name> (<description>)"). ' + VERIFY_CREATES_TRACKED_NOTE,
            0,
        )

    # --- Step 1: tracked path ------------------------------------------------
    # Matches a FILE and a DIRECTORY alike. An absolute or traversing identity is
    # never handed to git as a pathspec (same escape-prevention posture
    # validate_path_in_project enforces); it falls through to the content search
    # instead, which cannot leave the repo.
    #
    # ":(glob)" is not decoration -- without a magic prefix git parses the
    # identity AS pathspec, and this is the gate that proves a phase built what
    # it declared. Measured: `ls-files -- '*'`, `-- ':'` and `-- ':!nope'` each
    # returned every tracked file, so a phase could close on an artifact that
    # does not exist. Not ":(literal)", which would also kill
    # "db/migrations/*.sql", a declared-legal identity kind. The residue -- a
    # bare "*" over-matching the text search -- is closed at WRITE time instead,
    # by requiring an identity to carry an alphanumeric character.
    path_safe = not (
        identity.startswith("/")
        or identity.startswith("../")
        or "/../" in identity
        or identity.endswith("/..")
    )
    if path_safe:
        ls_out, rc = _git(directory, "ls-files", "--", ":(glob)" + identity)
        git_max = max(git_max, rc)
        if rc > 1:
            return _verdict(
                identity,
                "error",
                "",
                "git ls-files exited " + str(rc) + " under " + directory
                + " — tool failure, not an absent artifact.",
                git_max,
            )
        if ls_out:
            first_path = ls_out.split("\n", 1)[0]
            return _verdict(identity, "verified", "path", "tracked path: " + first_path, git_max)

    # --- Step 2: endpoint path extraction -----------------------------------
    # Load-bearing, not a nicety. In a repository that genuinely serves the
    # route, the literal "POST /api/notifications" lives in docs and nowhere
    # else -- real code writes router.post('/api/notifications', ...). Excluding
    # documentation without this step turns every endpoint-kind phase into
    # verification_failed.
    #
    # Only a leading HTTP method token followed by a space and a "/" is
    # stripped. "DELETE user_sessions" is a table-shaped identity, not an
    # endpoint, and searching it for "user_sessions" alone would weaken the
    # check. Two spaces is not this shape either -- that is why the writer
    # refuses "POST  /api/x".
    search = identity
    for method in _HTTP_METHODS:
        if identity.startswith(method + " /"):
            search = identity[len(method) + 1 :]
            break
    searched_note = ' (searched "' + search + '")' if search != identity else ""

    # --- Step 3: text search over tracked source ----------------------------
    if is_doc_identity(identity):
        grep_out, rc = _git(directory, "grep", "-n", "-I", "-F", "-e", search)
    else:
        grep_out, rc = _git(
            directory, "grep", "-n", "-I", "-F", "-e", search, "--", *VERIFY_CREATES_EXCLUDES
        )
    git_max = max(git_max, rc)
    if rc > 1:
        return _verdict(
            identity,
            "error",
            "",
            "git grep exited " + str(rc) + " under " + directory
            + " — tool failure, not an absent artifact.",
            git_max,
        )

    # --- Step 4: drop marker-only comment lines -----------------------------
    kept = ""
    first_marker = ""
    for line in grep_out.split("\n"):
        if not line:
            continue
        hit_file, _, rest = line.partition(":")
        hit_num, _, hit_content = rest.partition(":")
        if is_marker_line(hit_content):
            if not first_marker:
                first_marker = hit_file + ":" + hit_num
            continue
        kept = hit_file + ":" + hit_num
        break

    if kept:
        return _verdict(
            identity, "verified", "text", "tracked source: " + kept + searched_note, git_max
        )

    # --- Missing: name what was found and rejected, not just "not found" ----
    rejected = ""
    if first_marker:
        rejected = (
            " Found and rejected at " + first_marker
            + ": TODO/FIXME marker comment, not an implementation."
        )
    else:
        all_out, rc = _git(directory, "grep", "-n", "-I", "-F", "-e", search)
        git_max = max(git_max, rc)
        if rc > 1:
            return _verdict(
                identity,
                "error",
                "",
                "git grep exited " + str(rc) + " under " + directory
                + " — tool failure, not an absent artifact.",
                git_max,
            )
        if all_out:
            aline = all_out.split("\n", 1)[0]
            afile, _, arest = aline.partition(":")
            anum, _, acontent = arest.partition(":")
            if is_marker_line(acontent):
                rejected = (
                    " Found and rejected at " + afile + ":" + anum
                    + ": TODO/FIXME marker comment, not an implementation."
                )
            else:
                rejected = (
                    " Found and rejected at " + afile + ":" + anum
                    + ": documentation or test path, excluded from the source search."
                )

    return _verdict(
        identity,
        "missing",
        "",
        'No tracked artifact for "' + identity + '" under ' + directory + searched_note
        + "." + rejected + " " + VERIFY_CREATES_TRACKED_NOTE,
        git_max,
    )


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


def handoff_lists_artifact(path, identity):
    """Fixed-string search inside handoff.md's "## Artifacts Created" section.

    Ported from _cv_handoff_lists_artifact's awk, which aimi-cli.sh still uses
    from validate-contracts; that copy goes when the readers move. The section
    ends at the next heading of any level, and the heading line itself is not
    part of the section in either implementation.
    """
    try:
        with open(path, "r", encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return False
    inside = False
    for line in lines:
        if re.match(r"^#+[ \t]+Artifacts Created", line):
            inside = True
            continue
        if re.match(r"^#+[ \t]", line):
            inside = False
        if inside and identity in line:
            return True
    return False


def op_amend_validate(argv):
    """Everything roadmap-amend-phase checks BEFORE it takes the lock."""
    raw = sys.stdin.read()
    payload = None
    try:
        parsed = json.loads(raw)
        if isinstance(parsed, dict):
            payload = jq_numbers(parsed)
    except ValueError:
        payload = None
    if payload is None:
        flat = raw.replace("\n", "")[:200]
        die("Error: roadmap-amend-phase: amendment payload must be a JSON object, got: " + flat)

    # Scalar flags fold into the same object so there is exactly one validation,
    # sanitization and merge path -- no second code path to keep in step.
    if "--goal" in argv:
        payload["goal"] = _flag(argv, "--goal")
    if "--branch" in argv:
        payload["branch"] = _flag(argv, "--branch")

    key_errors = amend_key_errors(payload)
    if key_errors:
        _die_list(
            "Error: roadmap-amend-phase: unamendable key(s) in the amendment payload:", key_errors
        )

    if not payload:
        die(
            "Error: roadmap-amend-phase: the amendment carries no field to change "
            "-- pass at least one of " + ", ".join(AMENDABLE_KEYS)
        )

    type_errors = amend_type_errors(payload)
    if type_errors:
        _die_list("Error: roadmap-amend-phase: invalid amendment value(s):", type_errors)

    sanitized = amend_sanitize(payload)
    branch = sanitized.get("branch")
    if "branch" in sanitized and branch is not None and not BRANCH_REGEX.search(branch):
        die('Error: roadmap-amend-phase: branch "' + branch + '" contains invalid characters')

    json.dump(sanitized, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def op_amend_write(argv):
    """The locked read-modify-write. Every refusal happens before the file is
    touched, so a refused amendment leaves roadmap.json byte-for-byte alone."""
    path = _flag(argv, "--roadmap")
    feature = _flag(argv, "--feature")
    phase_raw = _flag(argv, "--phase")
    retargets_raw = _flag(argv, "--retargets") or "[]"
    if not path or not feature or phase_raw is None:
        die("Usage: roadmap.py amend-write --roadmap <path> --feature <slug> --phase <id>")
    phase_id = jq_numbers(json.loads(phase_raw))
    pairs = json.loads(retargets_raw)

    patch = jq_numbers(json.load(sys.stdin))
    doc = read_doc(path, "roadmap-amend-phase")

    stored = next((p for p in (doc.get("phases") or []) if p.get("id") == phase_id), None)
    if stored is None:
        die(
            "Error: roadmap-amend-phase: phase "
            + _num(phase_id)
            + " not found in "
            + path
        )

    # Shallow merge: every key the stored phase already had keeps its position
    # and value -- id, dir, slug, name, dependsOn, status and claim included --
    # and only the keys the payload carries are replaced, each wholesale.
    amended = dict(stored)
    for key, value in patch.items():
        if key in ("__mkCreates", "__mkNeeds"):
            continue
        amended[key] = value

    # Judge ONLY the lists this call actually writes. Handing over the merged
    # phase would re-judge a list the amendment never touched, turning every
    # tightening of the identity rule into a retroactive refusal -- a phase whose
    # stored creates holds a legacy whitespace identity could no longer have its
    # needs amended, and repairing exactly those phases is what this verb is for.
    check = {"id": amended.get("id")}
    if "creates" in patch:
        check["creates"] = amended.get("creates") or []
        check["__mkCreates"] = patch.get("__mkCreates") or []
    if "needs" in patch:
        check["needs"] = amended.get("needs") or []
        check["__mkNeeds"] = patch.get("__mkNeeds") or []
    if "areas" in patch:
        check["areas"] = amended.get("areas") or []
    identity_errors = judge_phases([check])
    if identity_errors:
        _die_list(
            "Error: roadmap-amend-phase: malformed creates/needs identity in the amended phase:",
            identity_errors,
            note=True,
        )

    new_idents = _identities(amended, "creates")
    old_idents = _identities(stored, "creates")
    dropped = sorted({i for i in old_idents if i not in set(new_idents)})
    added = sorted({i for i in new_idents if i not in set(old_idents)})

    # A pair that authorizes nothing is a caller mistake, not a no-op: the
    # rename they meant to make did not happen the way they thought.
    pair_errors = []
    for pair in pairs:
        if pair["old"] not in dropped:
            pair_errors.append(
                '  "' + pair["old"] + "=" + pair["new"] + '": this amendment does not drop '
                'the creates identity "' + pair["old"] + '"'
            )
        elif pair["new"] not in new_idents:
            pair_errors.append(
                '  "' + pair["old"] + "=" + pair["new"] + '": the amended phase declares no '
                'creates entry whose identity is "' + pair["new"] + '"'
            )
    if pair_errors:
        _die_list("Error: roadmap-amend-phase: unusable --retarget-needs pair(s):", pair_errors)

    authorized = sorted({p["old"] for p in pairs})

    orphans = amend_orphan_rows(stored, amended, doc, authorized)
    if orphans:
        sys.stderr.write(
            "Error: roadmap-amend-phase: this amendment drops creates identities other "
            "phases still cite in needs:\n"
        )
        for phase, ident in orphans:
            sys.stderr.write("  phase " + _num(phase) + ' needs "' + ident + '"\n')
        sys.stderr.write("Re-run with the pairing that authorizes the rewrite:\n")
        # The set difference proves an identity was dropped but never which new
        # identity replaced it, so the pairing is the caller's to state. With
        # exactly one added identity the suggestion is complete; otherwise the
        # new side stays a placeholder rather than a guess.
        target = added[0] if len(added) == 1 else "<new identity>"
        unique_new = set(new_idents)
        for ident in sorted({i for i in old_idents if i not in unique_new and i not in set(authorized)}):
            sys.stderr.write(
                "  aimi-cli.sh roadmap-amend-phase --feature "
                + feature
                + " --phase "
                + phase_raw
                + ' ... --retarget-needs "'
                + ident
                + "="
                + target
                + '"\n'
            )
        sys.exit(1)

    # Hard block because validate-contracts hard-fails on a duplicate outside
    # --agent-mode, and that halts /aimi:plan: writing the amendment would
    # produce a roadmap its own consumer rejects. Scope is the identities THIS
    # amendment introduces -- a collision that predates it is not this verb's to
    # adjudicate, and blocking on one would wall off the very repair it exists for.
    dup_rows = sorted(
        {
            (p.get("id"), ident)
            for p in doc.get("phases") or []
            if p.get("id") != phase_id
            for ident in _identities(p, "creates")
            if ident in set(added)
        },
        key=lambda t: (jq_sort_key(t[0]), t[1]),
    )
    if dup_rows:
        sys.stderr.write(
            "Error: roadmap-amend-phase: phase "
            + _num(phase_id)
            + " would declare a creates identity another phase already declares:\n"
        )
        for phase, ident in dup_rows:
            sys.stderr.write("  phase " + _num(phase) + ' already declares "' + ident + '"\n')
        sys.stderr.write(
            "  Convert the collision into a creates/needs contract between the two phases, "
            "or promote the artifact to a shared foundation phase.\n"
        )
        sys.exit(1)

    # old identity -> the amended phase's new creates entry VERBATIM (identity
    # plus its parenthetical), so provider and consumer stay byte-identical.
    retarget_map = {}
    for pair in pairs:
        match = next(
            (e for e in _v1_string_entries(amended.get("creates") or []) if cv_identity(e) == pair["new"]),
            None,
        )
        retarget_map[pair["old"]] = match

    retargeted = [
        {"phase": p.get("id"), "from": entry, "to": retarget_map[cv_identity(entry)]}
        for p in doc.get("phases") or []
        if p.get("id") != phase_id
        for entry in _v1_string_entries(p.get("needs") or [])
        if cv_identity(entry) in retarget_map
    ]

    # One write: the phase swap and every authorized downstream needs rewrite.
    for index, phase in enumerate(doc.get("phases") or []):
        if phase.get("id") == phase_id:
            doc["phases"][index] = amended
        elif retarget_map and isinstance(phase.get("needs"), list):
            phase["needs"] = [
                retarget_map.get(cv_identity(e), e) if isinstance(e, str) else e
                for e in phase["needs"]
            ]
    write_doc_atomically(path, doc)

    # Advisory only, exit status stays 0: correcting an already-completed phase's
    # prose creates is precisely the repair this verb exists for, so no status
    # value gates the amend in either direction.
    if amended.get("status") == "completed" and added:
        handoff = os.path.join(os.path.dirname(path), amended.get("dir") or "", "handoff.md")
        if os.path.isfile(handoff):
            for ident in added:
                if not handoff_lists_artifact(handoff, ident):
                    sys.stderr.write(
                        "Advisory: roadmap-amend-phase: phase "
                        + _num(phase_id)
                        + " is completed and its handoff.md does not list \""
                        + ident
                        + '" under Artifacts Created -- update the handoff so the phase\'s '
                        "prose matches its contract.\n"
                    )

    json.dump(
        {
            "roadmap": path,
            "phase": phase_id,
            # Intersected with the allowlist rather than filtered by name. This
            # field can only ever name an amendable key -- amend_key_errors
            # refused everything else at the door -- so the intersection is the
            # true statement and it maintains itself: a future scratch key stays
            # out without anyone remembering it exists. Before this, __mkCreates
            # and __mkNeeds rode along, and neither of the two assertions on this
            # field noticed, because neither amended creates or needs.
            "amended": sorted(k for k in patch if k in AMENDABLE_KEYS),
            "retargeted": retargeted,
        },
        sys.stdout,
        indent=2,
    )
    sys.stdout.write("\n")
    return 0


def op_verify_creates(argv):
    """One process for the whole phase. The bash it replaces spent two git and
    two jq per identity -- one jq only to build the verdict, another only to
    append it to the array."""
    path = _flag(argv, "--roadmap")
    directory = _flag(argv, "--dir")
    phase_raw = _flag(argv, "--phase")
    if not path or not directory or phase_raw is None:
        die("Usage: roadmap.py verify-creates --roadmap <path> --phase <id> --dir <path>")
    phase_id = jq_numbers(json.loads(phase_raw))

    doc = read_doc(path, "verify-creates")
    phase = next((p for p in (doc.get("phases") or []) if p.get("id") == phase_id), None)
    if phase is None:
        die("Error: verify-creates: phase " + _num(phase_id) + " not found in " + path)

    # Identities come from the one existing definition, never a second copy.
    verdicts = [
        verify_creates_one(directory, cv_identity(entry))
        for entry in _v1_string_entries(phase.get("creates") or [])
    ]
    json.dump(verdicts, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


_OPS = {
    "judge-phases": op_judge_phases,
    "verify-creates": op_verify_creates,
    "normalize-contracts": op_normalize_contracts,
    "init-validate": op_init_validate,
    "init-write": op_init_write,
    "amend-validate": op_amend_validate,
    "amend-write": op_amend_write,
}


def main(argv):
    if len(argv) < 2 or argv[1] not in _OPS:
        die("Usage: roadmap.py <" + "|".join(sorted(_OPS)) + "> [flags]", 2)
    return _OPS[argv[1]](argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
