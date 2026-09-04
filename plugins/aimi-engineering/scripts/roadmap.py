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
FAIL. A creates/needs entry stopped being the string "identity (description)"
and became {identity, description}, and the question every reader asks is "what
is the identity of this entry". In jq:

    [{identity:"x"}] | [ .[] | select(type == "string") | _cv_identity ]
    => []            exit 0, no diagnostic, guard silently disabled

here:

    contract_entries(phase, "creates")  on a stored string
    => MalformedEntry: phase 2: creates entry #1 must be an object ...

Both inputs are wrong. Only one of the two reactions says so. Three of the five
defects found while building this contract were of the silent kind -- jq's `.`
rebinding inside a pipe, that type filter, and a backtick inside a
double-quoted `echo` forking a command substitution -- and all three are
unrepresentable here.

Two things this file must NOT become:

  * A second opinion. Where a rule already exists in aimi-cli.sh it is ported
    verbatim, message strings included, and the old one is deleted in the same
    commit. Two implementations of "what is a legal identity" is the exact
    disease this whole branch exists to cure.
  * A place that touches the filesystem outside the lock bash holds. Read,
    transform, write to a temp file beside the target, rename. Never open a
    roadmap this process was not handed.

The bash suite is the fidelity net: EXPECTED_ASSERTIONS in test-aimi-cli.sh
pins its total, over a hundred of those assertions drive these verbs as black
boxes through the CLI, and a faithful port does not move a single one of them.
"""

import json
import os
import re
import subprocess
import sys
import tempfile
import time

# The prose sanitizer is not this file's to own: story_merge.py needs the same
# rule for the story titles it puts into a dropped-dependency warning, and a
# story title is not a roadmap concern. It lives in sanitize.py, which holds that
# one rule and nothing else, and both files import it from there.
from sanitize import rm_sanitize

# THE TWO RULERS, NOW THAT THE TWO HALVES ARE TWO FIELDS.
#
# The description gets rm_sanitize above. The identity gets NOTHING: it is
# stored exactly as it was submitted, and a name this file will not accept is
# REFUSED rather than repaired. There used to be a third sanitizer here
# (rm_sanitize_contract) whose whole job was to find the "(" and apply two
# different rules either side of it, plus a formatting-only variant
# (rm_markers_only) so the identity half could be normalized without being
# rewritten. Both existed only because the two halves shared one string. They
# are gone with it -- and so is the class of defect where a rule meant for
# prose reached a name, because there is no longer any code path that can
# reach one.
#
# What "never modified" costs and why it is still right: an identity now keeps
# its backticks, its newlines and its length instead of having them normalized
# away. Each of those is refused by name in _identity_reasons below -- a
# backtick is in the shell class, a newline is whitespace, and an over-long
# identity has its own reason -- so nothing gets through unjudged. The author
# sees the refusal at write time, which is the one moment they can still fix
# it, rather than discovering one phase later that verify-creates is grepping
# for a token nobody ever wrote.


# ---------------------------------------------------------------------------
# The contract vocabulary, ported from _CONTRACT_JQ_DEFS
# ---------------------------------------------------------------------------
#
# One definition, read by the write-time guard and by every reader, so the
# writer and the reader cannot drift apart on what an identity is or which
# characters an identity may not hold.
#
# cv_suspicious is deliberately two halves with two different scopes. The full
# argument for why -- and why the description keeps the injection guard -- lives
# in commands/references/scope-contexts.md, "Two rulers". In short:
#   * cv_injection judges BOTH fields, description included, because a
#     description reaches a story-expander sub-agent prompt via /aimi:plan's
#     phaseHandoffBlocks (grep that symbol; do not cite line numbers here, they
#     drift).
#   * The shell class judges only the IDENTITY -- the token verify-creates greps
#     and every contract match keys on. Judging the description too refused
#     "cmd_clean" described as "does x; then y", an identity that is itself
#     clean.
#
# The two fields are read separately rather than rejoined into one string. A
# join would have to invent a separator, and a pattern straddling it would match
# text no field actually holds.
#
# Both instruction markers anchor on POSITION -- start-of-string or whitespace,
# then any run of punctuation -- because that is what a marker looks like and
# what an ordinary name never does. This comment records only why the shape is
# what it is, because both directions have already been wrong.
#
#   Too wide: unanchored, "INSTRUCTIONS" matched the ordinary English word, so
#   "docs/instructions.md (setup instructions)" was written by roadmap-init and
#   then refused by validate-contracts. The same unanchored "system:" matched
#   inside "design-system:tokens".
#
#   Too narrow: keying on the neighbouring character ([^a-zA-Z0-9_-]) and
#   requiring a colon after INSTRUCTIONS closed those two and admitted
#   "--system: do this" and "### INSTRUCTIONS do X" -- a hyphen is an identifier
#   character, and a heading needs no colon.
#
# The heading form requires the "#" deliberately: without it an artifact
# legitimately named INSTRUCTIONS.md would be refused. Keep this in step with
# rm_sanitize's own "system:" strip, which uses the same anchor. Both tables in
# test-aimi-cli-part3-roadmap-forge.sh guard this pair -- widening fails the
# ordinary rows, narrowing fails the injection rows.
#
# judge_phases rejects both halves at write time, so the reader-side check is
# defence in depth and should not be the place authors meet the rule.

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
    """The reader-side judgement, over an entry already proven to be 2.0."""
    identity, description = entry["identity"], entry.get("description") or ""
    return (
        cv_injection(identity)
        or cv_injection(description)
        or _SHELL_CLASS.search(identity) is not None
    )


# ---------------------------------------------------------------------------
# The 2.0 entry: two fields, and no way to read one without proving both
# ---------------------------------------------------------------------------
#
# WHAT THIS REPLACES, AND WHY IT IS NOT THE SAME THING WITH A NEW NAME. Until
# the schema split, thirteen call sites read their lists through a
# `select(type == "string")` filter that reproduced 1.0 exactly. In 1.0 it
# discarded nothing, because every entry WAS a string. The moment an entry
# became an object it would have discarded every one of them -- disabling the
# orphan check, the dropped/added diff, retarget resolution, the duplicate check
# and the downstream rewrite, without printing one line. That was measured, not
# theorised, and removing it is the reason this branch exists.
#
# So the replacement is not another filter. contract_entries RAISES, and it
# raises with the phase, the list and the position already in the message,
# because the caller that can act on the diagnostic is a human reading stderr,
# not this function. A skip and a raise are the same amount of code; only one of
# them tells anybody.
#
# The gate in aimi-cli.sh (_roadmap_require_contracts) means a pre-2.0 document
# never reaches here at all -- it is refused by version, before a single entry is
# read. What DOES reach here is the shape this file can neither prevent nor
# repair: a document stamped 2.0 whose entries are not, i.e. one that was
# hand-edited, or written by something that stamped the version without doing
# the work. MIGRATION_HINT names both possibilities rather than assuming.

CONTRACT_ENTRY_KEYS = ("identity", "description")

# The identity is never truncated -- see the two-rulers note above -- so the cap
# is a refusal instead, and it is the same 500 the description carries.
CONTRACT_MAXLEN = 500

MIGRATION_HINT = (
    "An entry is {identity, description}. If this roadmap predates that shape, "
    "its roadmapVersion is wrong for what it holds -- migrate it with "
    "normalize-contracts; otherwise repair the entry with roadmap-amend-phase."
)


class MalformedEntry(Exception):
    """A creates/needs entry that is not a 2.0 {identity, description} object.

    Raised, never caught inside a rule. main() turns it into one stderr line and
    a non-zero exit, so a malformed entry stops the verb instead of quietly
    shrinking what it looked at.
    """


def _json_type(value):
    """jq's `type`, so a diagnostic names the shape the author actually wrote."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "a boolean"
    if isinstance(value, str):
        return "a string"
    if isinstance(value, (int, float)):
        return "a number"
    if isinstance(value, list):
        return "an array"
    return "an object"


def entry_shape_reasons(entry):
    """Why this value is not a 2.0 contract entry. Empty when it is one.

    Every unknown key is named individually rather than counted, because the one
    the author meant to write is the one the message has to show them.
    """
    if not isinstance(entry, dict):
        return ["must be an object {identity, description}, got " + _json_type(entry)]
    reasons = []
    for key in entry:  # insertion order, so the message follows the payload
        if key not in CONTRACT_ENTRY_KEYS:
            reasons.append(
                'carries the unknown key "' + key + '" -- an entry has exactly '
                "identity and description"
            )
    if "identity" not in entry:
        reasons.append("has no identity")
    elif not isinstance(entry["identity"], str):
        reasons.append("identity must be a string, got " + _json_type(entry["identity"]))
    if "description" in entry and not isinstance(entry["description"], str):
        reasons.append(
            "description must be a string, got " + _json_type(entry["description"])
            + " -- an absent description is \"\", never null"
        )
    return reasons


def contract_entries(phase, key):
    """A stored phase's creates or needs, each proven to be a 2.0 entry.

    THE ONE WAY A READER TOUCHES A CONTRACT LIST. Returns the list unchanged so
    positions and order survive; raises MalformedEntry, naming where, the moment
    one entry is not the shape the document claims to hold.
    """
    entries = phase.get(key) or []
    for index, entry in enumerate(entries, 1):
        reasons = entry_shape_reasons(entry)
        if reasons:
            raise MalformedEntry(
                "phase " + _num(phase.get("id")) + ": " + key + " entry #" + str(index)
                + " " + "; and it ".join(reasons) + ". " + MIGRATION_HINT
            )
    return entries


def contract_entry(identity, description=""):
    """The stored form. description is "" when absent, never null: a
    string-or-null disjunction costs every reader a branch for a distinction
    nothing consumes."""
    return {"identity": identity, "description": description}


# ---------------------------------------------------------------------------
# judge-phases — ported from _roadmap_identity_errors
# ---------------------------------------------------------------------------

_METHOD_PREFIX = re.compile(r"^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS) /")
_DOTDOT_SEGMENT = re.compile(r"(^|/)\.\.($|/)")
_ALNUM = re.compile(r"[a-zA-Z0-9]")
_SEPARATORS_AND_GLOBS = re.compile(r"[*?\[\]/ ]")


def _reject_unfindable_identity(ident):
    """True when verify-creates could never match this token against source.

    The method alternation and the single-space-then-slash shape are
    byte-for-byte the ones verify-creates step 2 strips, so the token judged at
    write time is exactly the token searched at close time. "POST  /api/x" with
    two spaces does not match that shape there and must not match it here.
    CR and LF are in the class and are now load-bearing rather than insurance:
    nothing folds a newline in an identity any more, so this is what refuses one.
    """
    if _METHOD_PREFIX.search(ident):
        ident = re.sub(r"^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS) ", "", ident, count=1)
    return re.search(r"[ \t\r\n]", ident) is not None


def _identity_reasons(ident, description):
    """Every reason this identity cannot name an artifact, in a fixed order.

    The identity carries all of them but one: the injection alternation also
    reads the description, because a description is threaded verbatim into a
    story-expander sub-agent prompt and is therefore prompt input, not
    human-only prose.
    """
    reasons = []
    if len(ident) == 0:
        reasons.append("empty -- the identity field is where the artifact is named")
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
            "text into the description field, or, for an endpoint, declare the "
            "route without its query string"
        )
    if cv_injection(ident) or cv_injection(description):
        reasons.append(
            "matches an instruction-injection pattern validate-contracts "
            "refuses (ignore previous / system: / INSTRUCTIONS: / code fence / "
            '"$(") -- reword it; the description reaches a sub-agent prompt, so '
            "both fields are judged, not just the identity"
        )
    if len(ident) > CONTRACT_MAXLEN:
        reasons.append(
            "is longer than "
            + str(CONTRACT_MAXLEN)
            + " characters -- an identity is never truncated to fit, because a "
            "truncated name is one verify-creates would grep for and never find; "
            "shorten it or move the prose into the description field"
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


_GLOB_METACHAR = re.compile(r"[*?\[\]]")


def _project_root_from_roadmap(roadmap_path):
    """The AIMI_ROOT a roadmap.json sits under, or None when it sits nowhere.

    Anchored on the path the writers already hold -- roadmap.json lives at
    <AIMI_ROOT>/.aimi/tasks/<feature>/roadmap.json -- rather than on a fresh
    resolution of its own: the root is the parent of the nearest ancestor
    directory named ".aimi".

    Two properties this needs and a fixed count of ".." would not have. The walk
    is purely LEXICAL, because a fresh roadmap-init runs before its own feature
    directory exists and no component of this path can be required to be on
    disk. And a path that is not under a ".aimi" at all answers None instead of
    a directory some fixed number of levels up, so a caller passing a path of a
    different shape gets no root and therefore no advisory, never an advisory
    measured against the wrong tree.
    """
    parent = os.path.dirname(os.path.abspath(roadmap_path))
    while parent and parent != os.path.dirname(parent):
        if os.path.basename(parent) == ".aimi":
            return os.path.dirname(parent)
        parent = os.path.dirname(parent)
    return None


def _missing_parent_dir_warnings(phases, roadmap_path):
    """One advisory line per creates[] identity whose parent directory is absent.

    verify-creates closes a phase on a textual match against the tokens git
    tracks, so an identity naming a path nobody ever wrote can still come back
    verified off a like-named token somewhere else. This is the cheap early
    signal for that, and it is ONLY a signal: a phase whose whole job is to
    create a directory tree legitimately declares a parent that does not exist
    yet, so nothing here dies and nothing here is added to judge_phases' fatal
    list.

    Judged only for the identities that are actually path-shaped, because a
    warning that fires on top of correct usage is one nobody reads by its third
    appearance:
      - a bare verb name -- list-known-gaps, verify-probe, measure-command-file,
        which is the form phase 1 of this very roadmap declared -- carries no
        "/" and names no directory, so it is never judged here;
      - "METHOD /path" is a route, not a file, and its slash belongs to the
        route;
      - a parent carrying a glob metacharacter (src/*/models/x.py) names no one
        literal directory, so there is nothing whose existence could be tested.

    Entries _identity_reasons already refuses are skipped: they are dying
    anyway, and a second line about them is noise on top of a refusal.
    """
    root = _project_root_from_roadmap(roadmap_path)
    if root is None:
        return []
    out = []
    for phase in phases:
        for pos0, entry in enumerate(contract_entries(phase, "creates")):
            ident = entry["identity"]
            if _identity_reasons(ident, entry.get("description") or ""):
                continue
            if _METHOD_PREFIX.search(ident) or "/" not in ident:
                continue
            parent = os.path.dirname(ident)
            if not parent or _GLOB_METACHAR.search(parent):
                continue
            resolved = os.path.normpath(os.path.join(root, parent))
            # ".." is already fatal above, so this can only fire on a shape that
            # normalizes out of the tree some other way. Skipping rather than
            # warning keeps this channel from reporting on a path it did not
            # actually test.
            if resolved != root and not resolved.startswith(root + os.sep):
                continue
            if os.path.isdir(resolved):
                continue
            out.append(
                "phase "
                + _num(phase.get("id"))
                + ": creates entry #"
                + str(pos0 + 1)
                + ' "'
                + ident
                + '" names a path whose parent directory "'
                + parent
                + '" does not exist under '
                + root
                + " -- fine when this phase is the one that creates it, but "
                "verify-creates closes a phase on a textual match, so an "
                "identity nobody ever writes can still come back verified"
            )
    return out


def judge_phases(phases, roadmap_path=None):
    """Return one diagnostic line per indefensible creates/needs/areas entry.

    Reads its lists through contract_entries, so a payload whose shape never
    reached the entry validator raises here rather than being judged as though
    its identity were empty.

    The returned lines are the FATAL half and are unchanged by roadmap_path.
    When one is given -- the two writers know their own roadmap path; the
    stdin-only judge-phases verb does not -- a second, advisory channel also
    runs, writing to stderr through warn_list and adding nothing to the returned
    list. No caller's refusal set moves because of it.
    """
    out = []
    for phase in phases:
        for list_name in ("creates", "needs"):
            for pos0, entry in enumerate(contract_entries(phase, list_name)):
                ident = entry["identity"]
                description = entry.get("description") or ""
                reasons = _identity_reasons(ident, description)
                if not reasons:
                    continue
                shown = (
                    " (content withheld -- it matches an injection pattern)"
                    if cv_injection(ident) or cv_injection(description)
                    else ' "' + ident + '"'
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

    if roadmap_path:
        advisories = _missing_parent_dir_warnings(phases, roadmap_path)
        if advisories:
            warn_list(
                "Warning: creates entry naming a path whose parent directory "
                "does not exist:",
                advisories,
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
#
# It used to explain a rewrite: an identity was quoted back after backtick
# normalization, so one submitted with backticks appeared without them, and
# without the note the author could not find the entry they had written. There
# is no rewrite left to explain -- an identity is stored and quoted exactly as
# submitted -- so the note now states that, which is the thing an author needs
# to know before they go looking for the sanitizer that "must have" changed it.
IDENTITY_NOTE = (
    "Note: an identity is quoted back exactly as submitted -- nothing normalizes, "
    "trims or truncates one. A backticked name such as `x` is refused rather than "
    "unwrapped to x, so what appears above is the string that was in the payload; "
    "locate the entry by its position in the list."
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
        return contract_entry(cv_identity(entry), nc_description(entry))
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
# The terminal story statuses: the one rule that answers "has this story
# finished?", and therefore "does this phase still have work?".
#
# One name, three readers, because a Python constant cannot reach all three:
#   - ground_truth, below in this file
#   - tasks.py's _dep_status_done, which imports this
#   - aimi-cli.sh's split-detect, which is jq and cannot import anything
#
# The jq copy carries a comment pointing here. Three literal copies is what the
# tree had before, and they DID drift: split-detect tested only "completed"
# while the other two had already been taught that "skipped" is terminal too,
# which is how issue #112 stayed open for split phases after being closed for
# every other kind. A name does not prevent the jq copy drifting again, but it
# gives the drift somewhere to be measured against.
#
# It lives here rather than in tasks.py, where a story rule semantically
# belongs, only because tasks.py already imports FROM this module -- putting it
# there would close an import cycle. Move it if that edge ever reverses; do not
# move it without checking.
TERMINAL_STORY_STATUSES = ("completed", "skipped")

# Matched with .fullmatch(), never .search(). Python's `$` also matches just
# BEFORE a trailing newline, so `re.search` accepted "main\n" -- a value no git
# refname can hold, but this pattern also guards integrationBranch, which
# arrives straight from a CLI flag with no rm_sanitize newline-stripping in
# front of it. fullmatch anchors both ends and closes it for every caller at
# once. The pattern itself is unchanged so the accepted set is otherwise
# byte-identical.
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


def init_entry_shape_errors(phases):
    """One line per creates/needs value that is not a 2.0 entry.

    Runs BEFORE init_sanitize, because sanitizing an entry means reaching into
    its two fields, and a payload whose entries are still 1.0 strings must be
    told so by name rather than raising out of a sanitizer.
    """
    errors = []
    for phase in phases:
        for list_name in ("creates", "needs"):
            entries = phase.get(list_name)
            if entries is None:
                continue
            if not isinstance(entries, list):
                errors.append(
                    "phase " + _num(phase.get("id")) + ": " + list_name
                    + " must be an array of {identity, description} entries"
                )
                continue
            for index, entry in enumerate(entries, 1):
                for reason in entry_shape_reasons(entry):
                    errors.append(
                        "phase " + _num(phase.get("id")) + ": " + list_name
                        + " entry #" + str(index) + " " + reason
                    )
    return errors


def sanitize_contract_entry(entry):
    """The two rulers, applied to one entry: identity untouched, description
    through the full prose sanitizer and its cap."""
    return contract_entry(
        entry["identity"], rm_sanitize(entry.get("description") or "", CONTRACT_MAXLEN)
    )


def init_sanitize(phases):
    """Sanitize free text and compute dir. Contract identities are not free text
    and are the one thing here that passes through untouched."""
    out = []
    for phase in phases:
        p = dict(phase)
        p["name"] = rm_sanitize(p.get("name"), 200)
        p["goal"] = rm_sanitize(p.get("goal"), 2000)
        p["slug"] = rm_sanitize(p.get("slug") if p.get("slug") is not None else "", 100)
        p["notes"] = rm_sanitize(p["notes"], 5000) if p.get("notes") is not None else None
        p["successCriteria"] = [rm_sanitize(s, 2000) for s in (p.get("successCriteria") or [])]
        p["creates"] = [sanitize_contract_entry(e) for e in (p.get("creates") or [])]
        p["needs"] = [sanitize_contract_entry(e) for e in (p.get("needs") or [])]
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
        if p.get("branch") is not None and not BRANCH_REGEX.fullmatch(p["branch"])
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


def _identities(phase, key):
    return [entry["identity"] for entry in contract_entries(phase, key)]


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
    for key in ("successCriteria", "areas"):
        if key not in payload:
            continue
        if not isinstance(payload[key], list):
            errors.append("  " + key + " must be an array of strings")
        elif any(not isinstance(e, str) for e in payload[key]):
            errors.append("  " + key + " entries must all be strings")
    # creates/needs carry entries, not strings, and this is the boundary that
    # keeps a 1.0 string out of a 2.0 document. Without it an amendment could
    # write one string into a stored list of objects and leave a roadmap whose
    # own readers refuse it -- measured: the mixed document dropped an identity a
    # later phase still cited, exited 0, and only surfaced at validate-contracts.
    for key in ("creates", "needs"):
        if key not in payload:
            continue
        if not isinstance(payload[key], list):
            errors.append(
                "  " + key + " must be an array of {identity, description} entries"
            )
            continue
        for index, entry in enumerate(payload[key], 1):
            for reason in entry_shape_reasons(entry):
                errors.append("  " + key + " entry #" + str(index) + " " + reason)
    return errors


def amend_sanitize(payload):
    """The same sanitizer and the same caps roadmap-init applies to a fresh phase."""
    p = dict(payload)
    if "goal" in p:
        p["goal"] = rm_sanitize(p["goal"], 2000)
    if "successCriteria" in p:
        p["successCriteria"] = [rm_sanitize(s, 2000) for s in p["successCriteria"]]
    if "creates" in p:
        p["creates"] = [sanitize_contract_entry(e) for e in p["creates"]]
    if "needs" in p:
        p["needs"] = [sanitize_contract_entry(e) for e in p["needs"]]
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

# What survives the bypass when the identity names documentation ITSELF.
#
# Bypassing the whole list above was too much. Those four meta-documents exist
# to CITE other files by name -- a README's file map, a CHANGELOG's entry, the
# two agent-instruction files -- so they match nearly any identity and prove
# nothing about the named artifact existing. Measured at phase 2's close: with
# the list fully off, an identity whose ONLY hit is its own CHANGELOG line
# closes the phase on the announcement of the work rather than the work.
#
# The rest of the list stays off, which is what the bypass exists to give: for a
# doc identity, a hit under docs/ IS the artifact.
#
# Each pattern twice, for the reason the comment above already gives about
# "docs/*": default pathspec matching is anchored at the search root, so a lone
# "CLAUDE.md" would miss plugins/aimi-engineering/CLAUDE.md. README* and
# CHANGELOG* carry the same anchor and get the same companion.
DOC_IDENTITY_EXCLUDES = [
    ":(exclude)README*",
    ":(exclude)*/README*",
    ":(exclude)CHANGELOG*",
    ":(exclude)*/CHANGELOG*",
    ":(exclude)CLAUDE.md",
    ":(exclude)*/CLAUDE.md",
    ":(exclude)AGENTS.md",
    ":(exclude)*/AGENTS.md",
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
    the exclusion list narrows to DOC_IDENTITY_EXCLUDES for that one entry --
    it is no longer turned off whole, because four meta-documents cite every
    other file by name and would match anything.

    Narrowing the exclusions is only half of it. A text hit does not CLOSE a doc
    identity either: it reports "unconfirmed", because finding the string
    "docs/api.md" somewhere in the tree says a file mentions that page, not that
    the page exists. Step 1 answers that, and step 1 is the only step that
    returns "verified" for one of these.
    """
    return (
        identity.startswith("docs/")
        or identity.startswith("doc/")
        or "/docs/" in identity
        or "/doc/" in identity
        or identity.endswith((".md", ".rst", ".adoc", ".txt"))
    )


def is_bare_name_identity(search):
    """True when the searched token is a bare NAME rather than a path.

    No "/" and no ".", so "baseRef" and "list-known-gaps" are bare while
    "plugins/aimi-engineering/scripts/roadmap.py", "docs/api.md" and an
    endpoint's already-stripped "/api/notifications" are not. This is the one
    shape that can only ever resolve through the text search, which is why it is
    the one whose evidence gets a second look below.
    """
    return bool(search) and "/" not in search and "." not in search


def _norm_repo_path(path):
    """A git-grep path and an implementation.files entry, made comparable.

    Both are repo-relative already; only a "./" prefix and a trailing "/" differ
    in practice. Normalizing here keeps the comparison EXACT -- substring
    containment is the defect this whole story exists to remove, and it would be
    absurd to reintroduce it in the check that catches it.
    """
    path = path.strip()
    if path.startswith("./"):
        path = path[2:]
    return path.rstrip("/")


def _unowned_bare_name_warning(identity, search, kept, hit_files, phase_files):
    """The advisory line for a bare name verified against nobody's file, or "".

    Never a refusal: the same warn_list channel judge_phases got, for the same
    reason -- the verdict this questions is usually right. It is the exact shape
    that approved "baseRef" against a forge adapter's `--arg baseRefName`, in a
    file no story of that phase declared touching, so the evidence is worth
    naming even though a bare name legitimately resolves in code no story listed.

    Silent when the phase declared no files at all. With nothing to compare
    against, "outside the declared set" is not a fact anyone measured.
    """
    if not phase_files or not is_bare_name_identity(search):
        return ""
    if any(_norm_repo_path(hit) in phase_files for hit in hit_files):
        return ""
    return (
        'identity "' + identity + '" verified by text, but all '
        + str(len(hit_files)) + " matching line(s) fall outside the files this "
        "phase's stories declared -- first at " + kept + ". A bare name matches "
        "any identifier that contains it as a whole word."
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


def verify_creates_one(directory, identity, phase_files=None, warnings=None):
    """Verify ONE creates identity against <directory>'s tracked files.

    Always returns a verdict: "missing", "unconfirmed" or "error" is data, not
    failure. "unconfirmed" is reached only by a doc identity that resolved
    through the text search -- see is_doc_identity for why a mention is not a
    page.

    gitStatus is the HIGHEST exit status any git invocation returned for this
    entry -- 0 or 1 in normal operation, above 1 only on tool failure, and that
    is the line between "the phase did not build it" and "we could not look".

    `phase_files` (a set of normalized implementation.files[] paths) and
    `warnings` (a list this appends to) drive the bare-name advisory, and both
    default to off: a caller that passes neither gets exactly the verdicts it
    got before, on stdout, with nothing on stderr.
    """
    git_max = 0
    if not identity:
        return _verdict(
            identity,
            "missing",
            "",
            "Malformed creates entry: empty artifact identity (an entry is "
            '{identity, description}, and the identity names the artifact). '
            + VERIFY_CREATES_TRACKED_NOTE,
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
    #
    # "-w" is load-bearing, not tidiness. Without it a match INSIDE a longer
    # identifier counts: measured at phase 2's close, the identity "baseRef"
    # matched 37 lines, every one of them the substring inside the forge
    # adapter's "--arg baseRefName" -- a GitHub pull-request field with no
    # relation to the metadata.baseRef the phase had promised. With "-w" it
    # matches zero. The three bare verb names phase 1 declared
    # (list-known-gaps, verify-probe, measure-command-file) keep matching, and
    # so does every identity kind scope-contexts.md documents: "parseList<T>",
    # "queue:emails" and a stripped "/api/notifications" all begin and end at a
    # non-word character, which is exactly what -w tests.
    #
    # One residue closes as a side effect, recorded here so nobody reads it as
    # an accident: an identity of a bare ":" used to verify by text, because
    # `grep -F ':'` finds a colon in any source file. Under -w it matches
    # nothing. The write-time alphanumeric rule still owns that case; this is a
    # second net under it, not a replacement.
    #
    # One branch, two pathspec sets -- the two used to be an if/else in which one
    # arm passed no "--" at all, and that arm is what turned the whole exclusion
    # list off for a doc identity.
    excludes = DOC_IDENTITY_EXCLUDES if is_doc_identity(identity) else VERIFY_CREATES_EXCLUDES
    grep_out, rc = _git(
        directory, "grep", "-n", "-I", "-F", "-w", "-e", search, "--", *excludes
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
    #
    # This no longer stops at the first surviving line. The advisory below asks
    # whether EVERY match falls outside the declared files, and a loop that
    # stopped at the first one could not answer that. `first_marker` is unmoved
    # by the change: it is read only on the path where `kept` stayed empty, and
    # on that path there was never a line to break at.
    kept = ""
    first_marker = ""
    hit_files = []
    for line in grep_out.split("\n"):
        if not line:
            continue
        hit_file, _, rest = line.partition(":")
        hit_num, _, hit_content = rest.partition(":")
        if is_marker_line(hit_content):
            if not first_marker:
                first_marker = hit_file + ":" + hit_num
            continue
        if not kept:
            kept = hit_file + ":" + hit_num
        hit_files.append(hit_file)

    if kept:
        # A doc identity gets no "verified" from here. Its search deliberately
        # runs OVER documentation, so a hit says some file writes the page's
        # name -- which is what a table of contents does. Only the tracked path
        # of step 1 proves the page itself, and step 1 is untouched: a real
        # documentation phase whose file is committed still verifies there.
        if is_doc_identity(identity):
            return _verdict(
                identity,
                "unconfirmed",
                "text",
                "mentioned in tracked source: " + kept + searched_note
                + " — a documentation identity is confirmed by its own tracked "
                "path, not by a mention of its name. " + VERIFY_CREATES_TRACKED_NOTE,
                git_max,
            )
        if warnings is not None:
            advisory = _unowned_bare_name_warning(
                identity, search, kept, hit_files, phase_files
            )
            if advisory:
                warnings.append(advisory)
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
        all_out, rc = _git(directory, "grep", "-n", "-I", "-F", "-w", "-e", search)
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
# validate-contracts — do this phase's needs resolve against what came before
# ---------------------------------------------------------------------------


def reachable_ids(doc, start):
    """Phase ids reachable from `start` through dependsOn, transitively, excluding
    `start` itself.

    Transitive and not just direct: a phase may legitimately need what its
    grandparent built. A provider OUTSIDE this closure is "no-provider" even
    though it exists in the roadmap -- declaring a need on a phase you do not
    depend on is a scheduling error, not a resolved contract.
    """
    deps = {_num(p.get("id")): (p.get("dependsOn") or []) for p in doc.get("phases") or []}
    cur = [start]
    while True:
        nxt = sorted(set(cur) | {d for c in cur for d in deps.get(_num(c), [])}, key=jq_sort_key)
        if nxt == cur:
            break
        cur = nxt
    return [i for i in cur if i != start]


def creates_in_scope(doc, ids):
    """(phase id, identity, status, dir) for every creates entry of every phase in
    `ids`, phase-id ascending.

    The order is the contract: the first row whose identity matches wins, so
    provider selection is deterministic rather than incidental.
    """
    rows = []
    in_scope = [p for p in (doc.get("phases") or []) if p.get("id") in ids]
    for phase in sorted(in_scope, key=lambda p: jq_sort_key(p.get("id"))):
        for entry in contract_entries(phase, "creates"):
            rows.append(
                (phase.get("id"), entry["identity"], phase.get("status"), phase.get("dir") or "")
            )
    return rows


def contract_sanitize_hits(doc):
    """One line per offending ENTRY, naming the entry and why.

    Same shape as the write-time judge, deliberately: the two are the same rule,
    and a reader who has seen one should recognise the other. Sorted and
    deduplicated, which is what jq's `unique` did here -- so the order is
    lexical, not phase order.
    """
    hits = set()
    for phase in doc.get("phases") or []:
        for field in ("creates", "needs"):
            for index, entry in enumerate(contract_entries(phase, field)):
                if not cv_suspicious(entry):
                    continue
                char = cv_shell_char(entry["identity"])
                if char is not None:
                    reason = (
                        'its identity carries the shell metacharacter "' + char
                        + '", which verify-creates cannot grep for'
                    )
                else:
                    reason = (
                        "it matches an instruction-injection pattern (ignore previous / "
                        'system: / INSTRUCTIONS: / code fence / "$(")'
                    )
                hits.add(
                    "phase " + _num(phase.get("id")) + " field '" + field + "' entry #"
                    + str(index + 1) + ": " + reason
                )
    return sorted(hits)


def duplicate_creates(doc):
    """Identities declared by more than one phase, whatever their status."""
    seen = {}
    for phase in doc.get("phases") or []:
        for entry in contract_entries(phase, "creates"):
            seen.setdefault(entry["identity"], []).append(phase.get("id"))
    return [
        {"identity": ident, "phases": sorted(set(phases), key=jq_sort_key)}
        for ident, phases in sorted(seen.items())
        if len(phases) > 1
    ]


def op_validate_contracts(argv):
    path = _flag(argv, "--roadmap")
    phase_raw = _flag(argv, "--phase")
    agent_mode = "--agent-mode" in argv
    if not path:
        die("Usage: roadmap.py validate-contracts --roadmap <path> [--phase <id>] [--agent-mode]")
    doc = read_doc(path, "validate-contracts")
    feature_dir = os.path.dirname(path)

    scoped = phase_raw is not None and phase_raw != ""
    phase_id = jq_numbers(json.loads(phase_raw)) if scoped else None
    if scoped and not any(p.get("id") == phase_id for p in doc.get("phases") or []):
        die("Error: validate-contracts: phase " + _num(phase_id) + " not found in " + path)

    # --- Sanitization pass: always blocks; never demoted by --agent-mode -----
    # (a duplicate-creates finding is the only check --agent-mode demotes)
    hits = contract_sanitize_hits(doc)
    if hits:
        for line in hits:
            sys.stderr.write("Error: validate-contracts: " + line + "\n")
        sys.stderr.write(
            "Error: validate-contracts: roadmap-init and roadmap-amend-phase refuse these "
            "at write time, so a roadmap this CLI wrote should not reach here. Repair with: "
            "roadmap-amend-phase --feature <slug> --phase <id>\n"
        )
        sys.exit(1)

    # --- Duplicate-creates collision check (across all phases, any status) ---
    dups = duplicate_creates(doc)
    if dups:
        lines = [
            "  phase " + " and phase ".join(_num(p) for p in d["phases"])
            + ': both declare "' + d["identity"] + '" -- convert the collision into a'
            " creates/needs contract between the two phases or promote the"
            " artifact to a shared foundation phase"
            for d in dups
        ]
        if agent_mode:
            sys.stderr.write(
                "Warning: validate-contracts: duplicate creates (--agent-mode: proceeding):\n"
            )
            sys.stderr.write("\n".join(lines) + "\n")
        else:
            sys.stderr.write("Error: validate-contracts: duplicate creates:\n")
            sys.stderr.write("\n".join(lines) + "\n")
            sys.exit(1)

    # --- Needs resolution: scope is --phase (if given) or every phase --------
    scope = [phase_id] if scoped else [p.get("id") for p in doc.get("phases") or []]
    missing = []
    providers = {}
    for sid in scope:
        rows = creates_in_scope(doc, reachable_ids(doc, sid))
        phase = next((p for p in doc.get("phases") or [] if p.get("id") == sid), {})
        for entry in contract_entries(phase, "needs"):
            need = entry["identity"]
            provider = next((r for r in rows if r[1] == need), None)
            if provider is None:
                missing.append({"phase": sid, "need": need, "reason": "no-provider"})
                continue
            prov_id, _, prov_status, prov_dir = provider
            if not scoped:
                # Unscoped run: identity resolution within the dependsOn closure
                # is sufficient. The completed+handoff delivery gate only applies
                # when --phase pins the check to one phase's execution readiness.
                providers[need] = prov_id
                continue
            delivered = prov_status == "completed" and handoff_lists_artifact(
                os.path.join(feature_dir, prov_dir, "handoff.md"), need
            )
            if delivered:
                providers[need] = prov_id
            else:
                missing.append({"phase": sid, "need": need, "reason": "not-delivered"})

    report = {"valid": not missing, "missing": missing, "providers": providers}
    if dups and agent_mode:
        report["duplicateWarnings"] = dups
    json.dump(report, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    sys.exit(0 if not missing else 1)


# ---------------------------------------------------------------------------
# roadmap-sweep — advisory contract/status consistency across a whole roadmap
# ---------------------------------------------------------------------------
#
# Advisory only: it reports and never refuses, so the caller reads the report
# rather than the exit status. Suspicious creates/needs are dropped before the
# orphan/deferred analysis so a flagged entry can never leak into another output
# field -- and THE DROP IS REPORTED, not silent. A dropped creates is invisible
# to the analysis that follows, so a downstream phase whose needs cited it reads
# as unmet with no trace of why: exactly the phase-late, cause-far-away failure
# this contract exists to remove. Each warning carries droppedCount and the
# offending positions, so a reader can tell "nothing declared it" apart from "it
# was declared and then discarded here".
#
# Schema note: the phase status enum is pending/planned/in_progress/completed/
# verification_failed -- there is no "deferred" status. deferredNeeds substitutes
# the existing "provider resolved but status != completed" signal for it.

SWEEP_DROP_MESSAGE = (
    "contains suspicious content -- dropped from this sweep, so anything "
    "downstream that cited it now reads as unmet"
)


def sweep_warnings(phases):
    """One warning per (phase, field) holding at least one suspicious entry.

    Sorted by phase then field, which is the whole observable effect jq's
    `unique_by([.phase,.field])` had here: the pairs are unique by construction,
    so nothing was ever deduplicated -- only the sort it performs on the way.
    """
    rows = []
    for phase in phases:
        for field in ("creates", "needs"):
            # Positions count against the list AS STORED, which is what a reader
            # comparing this warning to roadmap.json has in front of them.
            dropped = [
                position
                for position, entry in enumerate(contract_entries(phase, field), 1)
                if cv_suspicious(entry)
            ]
            if not dropped:
                continue
            rows.append(
                {
                    "phase": phase.get("id"),
                    "field": field,
                    "message": SWEEP_DROP_MESSAGE,
                    "droppedCount": len(dropped),
                    "droppedIndexes": dropped,
                }
            )
    return sorted(rows, key=lambda row: (jq_sort_key(row["phase"]), row["field"]))


def sweep_clean_phases(phases):
    """Every phase with its suspicious creates/needs removed."""
    cleaned = []
    for phase in phases:
        copy = dict(phase)
        for field in ("creates", "needs"):
            copy[field] = [
                entry for entry in contract_entries(phase, field) if not cv_suspicious(entry)
            ]
        cleaned.append(copy)
    return cleaned


def sweep(doc):
    """{orphanCreates, deferredNeeds, warnings} for the whole roadmap."""
    stored = doc.get("phases") or []
    phases = sweep_clean_phases(stored)

    needed = {entry["identity"] for p in phases for entry in p["needs"]}
    orphans = [
        {"phase": p.get("id"), "creates": identity}
        for p in phases
        for identity in [entry["identity"] for entry in p["creates"]]
        if identity not in needed
    ]

    providers = [
        {"identity": entry["identity"], "phase": p.get("id"), "status": p.get("status")}
        for p in phases
        for entry in p["creates"]
    ]
    deferred = []
    for phase in phases:
        for entry in phase["needs"]:
            identity = entry["identity"]
            # Lowest phase id wins, so which provider a need is attributed to is
            # deterministic rather than incidental -- the same rule
            # creates_in_scope applies for validate-contracts.
            matches = sorted(
                (row for row in providers if row["identity"] == identity),
                key=lambda row: jq_sort_key(row["phase"]),
            )
            if not matches or matches[0]["status"] == "completed":
                continue
            deferred.append(
                {"phase": phase.get("id"), "need": identity, "deferred": matches[0]["phase"]}
            )

    return {
        "orphanCreates": orphans,
        "deferredNeeds": deferred,
        "warnings": sweep_warnings(stored),
    }


# ---------------------------------------------------------------------------
# roadmap-write-handoff — render handoff.md from a structured payload
# ---------------------------------------------------------------------------
#
# Five headings, always all five, always in this order: that order is what
# roadmap-set-status's completed-requires-handoff precondition and
# handoff_lists_artifact's "Artifacts Created" lookup both depend on.

HANDOFF_FIELDS = ("decisions", "artifacts", "deviations", "deferred", "contracts")

HANDOFF_SECTIONS = (
    ("Decisions Made", "decisions"),
    ("Artifacts Created", "artifacts"),
    ("Deviations", "deviations"),
    ("Deferred Items", "deferred"),
    ("Contracts Delivered", "contracts"),
)

# The two lists that report DELIVERY, and so must keep their identities whole.
HANDOFF_DELIVERY_FIELDS = ("artifacts", "contracts")


def handoff_field(payload, name):
    """`(.[$k] // [])`: absent, null and false all mean "no entries"."""
    value = payload.get(name)
    return [] if value is None or value is False else value


def handoff_field_error(payload):
    """The first field that is not an array of strings, in the checked order."""
    for name in HANDOFF_FIELDS:
        value = handoff_field(payload, name)
        if not isinstance(value, list) or not all(isinstance(e, str) for e in value):
            return name
    return None


def handoff_clean(lines):
    """Ordinary prose: the full sanitizer, capped at 2000."""
    return [rm_sanitize(line, 2000) for line in lines]


def handoff_clean_delivery(lines, identities):
    """The prose sanitizer, except a declared identity at the head of the line
    survives byte-for-byte.

    WHY THIS EXISTS. "## Artifacts Created" is exactly what
    handoff_lists_artifact greps to resolve a later phase's needs, and this verb
    was running the full prose sanitizer over the artifacts it renders. Measured:
    creates ["parseList<T> (a generic helper)"] is stored verbatim in
    roadmap.json and landed in handoff.md as "parseList", so validate-contracts
    reported {"need":"parseList<T>","reason":"not-delivered"} forever. The tag
    rule is right for prose and wrong for a token that is grepped literally --
    the same two-rulers split roadmap-init already makes, one boundary later.

    Longest match wins, so a phase declaring both "alpha" and "alphabet" keeps
    the longer one whole. A line matching no declared identity is ordinary prose
    and gets the full treatment.
    """
    rendered = []
    for line in lines:
        matches = sorted((i for i in identities if line.startswith(i)), key=len)
        if not matches:
            out = rm_sanitize(line, 2000)
        else:
            head = matches[-1]
            out = head + rm_sanitize(line[len(head):], 2000)
        rendered.append(out[:2000] if len(out) > 2000 else out)
    return rendered


def handoff_section(title, items):
    head = "## " + title + "\n\n"
    if not items:
        return head + "_None._\n"
    return head + "\n".join("- " + item for item in items) + "\n"


def handoff_body(payload, identities):
    rendered = {
        name: (
            handoff_clean_delivery(handoff_field(payload, name), identities)
            if name in HANDOFF_DELIVERY_FIELDS
            else handoff_clean(handoff_field(payload, name))
        )
        for name in HANDOFF_FIELDS
    }
    return "\n".join(handoff_section(title, rendered[name]) for title, name in HANDOFF_SECTIONS)


def handoff_lost_identities(payload, identities, body):
    """Declared identities a payload line claimed to deliver that the rendered
    body no longer holds, under the same fixed-string match
    handoff_lists_artifact uses to resolve a downstream needs.

    With the renderer above this is always empty, and that is the point: it is
    not a check on today's code, it is a guard against a future sanitizer edit
    silently reopening the defect handoff_clean_delivery closes. It only judges
    identities some line actually claimed, so a phase reporting fewer artifacts
    than it declared -- a legitimate partial delivery -- is untouched.
    """
    lines = handoff_field(payload, "artifacts") + handoff_field(payload, "contracts")
    return [
        identity
        for identity in identities
        if any(line.startswith(identity) for line in lines) and identity not in body
    ]


# ---------------------------------------------------------------------------
# phase-overlap — which files two expanded phases both plan to touch
# ---------------------------------------------------------------------------
#
# Stage 2 of the sibling-phase overlap guard: execute.md calls this only after
# its own stage-1 roadmap.json `areas` comparison finds a non-empty coarse
# intersection. It reports the overlap and nothing else -- no splitting
# suggestion, the caller decides what to do with it.


def _jq_raw(value):
    """`tostring`: a string prints as itself, anything else as its JSON form.

    THE SEPARATORS ARE NOT COSMETIC. jq's tostring is COMPACT -- `[1,2]`, not
    `[1, 2]` -- and Python's default json.dumps puts a space after every comma
    and colon. Nothing had ever handed this an array or an object until
    list_archivable_roadmap_cases recorded a phase whose id was one, and the
    recording (`phase(s) [1,2]`) is what named the difference. Both other
    callers that can reach a composite value put the result in a message.
    """
    if isinstance(value, str):
        return value
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return _num(value)
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def phase_dirs(doc, phase_id):
    """`(.phases[] | select(.id == $pid) | .dir) // empty`, joined the way a
    command substitution joins jq's output lines.

    Two phases sharing an id is not a shape roadmap-init can write, but
    roadmap.json is a file people edit, and the answer for one has to stay what
    it always was: the single dir, unwrapped.
    """
    return "\n".join(
        _jq_raw(phase.get("dir"))
        for phase in doc.get("phases") or []
        if phase.get("id") == phase_id and phase.get("dir") is not None
        and phase.get("dir") is not False
    )


def _jq_key(value):
    """A hashable stand-in for jq's value equality, for set membership."""
    return json.dumps(value, sort_keys=True, ensure_ascii=False)


def jq_unique(values):
    """jq's `unique`: deduplicate by value, then sort by jq's total order."""
    seen = {}
    for value in values:
        seen[_jq_key(value)] = value
    return sorted(seen.values(), key=jq_sort_key)


def overlap_files(doc):
    """Every userStories[].implementation.files[] entry, undeduplicated.

    Tolerant at each hop the way jq's `?` was: a story with no implementation, an
    implementation with no files and a document with no userStories at all are
    all simply empty, because a phase may legitimately have planned none.
    """
    stories = doc.get("userStories") if isinstance(doc, dict) else None
    if isinstance(stories, dict):
        stories = list(stories.values())
    if not isinstance(stories, list):
        return []
    files = []
    for story in stories:
        implementation = story.get("implementation") if isinstance(story, dict) else None
        entries = implementation.get("files") if isinstance(implementation, dict) else None
        if isinstance(entries, dict):
            entries = list(entries.values())
        if isinstance(entries, list):
            files.extend(entries)
    return files


# ---------------------------------------------------------------------------
# Phase lifecycle — ground truth, has-work, and candidate selection
# ---------------------------------------------------------------------------
#
# One phase's status per roadmap.json is a claim about a session; what a phase
# still has to DO is a fact on disk, in its own tasks file. These pieces turn
# that fact into the ordering both selectors -- roadmap-get --next-eligible and
# roadmap-claim's auto branch -- read.

CLAIMABLE_STATUSES = ["pending", "planned", "in_progress", "verification_failed"]

# roadmap-get reports the two statuses a phase can be in before anyone has
# started it. roadmap-claim's set is wider on purpose (see op_claim).
GET_ELIGIBLE_STATUSES = ["pending", "planned"]

# Every status a phase may carry, in lifecycle order. It exists so --statuses
# can REFUSE a name rather than silently returning zero eligible phases: a
# caller who types "Pending" gets a message naming what they typed and what is
# accepted, instead of an empty answer indistinguishable from "nothing is
# ready". Kept in one place so the vocabulary cannot drift away from
# STATUS_TRANSITIONS, which is the graph over these same five names.
PHASE_STATUSES = ["pending", "planned", "in_progress", "completed", "verification_failed"]


def _tsv(value):
    """One `@tsv` field as bash's `read -r` received it.

    null is the empty field, which is why a phase with no `dir` builds a path
    with an empty component (`.../f//handoff.md`) rather than being skipped, and
    why a phase whose status is null reconciles `from: ""`. The escapes are jq's
    own: without them a tab would end the field and a newline the whole record.
    """
    if value is None:
        return ""
    return (
        _jq_raw(value)
        .replace("\\", "\\\\")
        .replace("\t", "\\t")
        .replace("\n", "\\n")
        .replace("\r", "\\r")
    )


def _story_statuses(doc):
    """`[.userStories[].status]`, or None where the jq aborted mid-expression.

    None is not "no stories" -- it is "the expression raised". A tasks file that
    parses but whose userStories is absent or holds a scalar made jq exit 5 with
    a raw engine error, and the bash captured its empty stdout and carried on.
    That empty string is load-bearing: reconcile compares it against the stored
    status, finds them different, and writes `status: ""` into roadmap.json.
    Ported as it stands rather than repaired -- see ground_truth.
    """
    if not isinstance(doc, dict):
        return None
    stories = doc.get("userStories")
    if isinstance(stories, dict):
        stories = list(stories.values())
    if not isinstance(stories, list):
        return None
    statuses = []
    for story in stories:
        if story is None:
            statuses.append(None)
        elif isinstance(story, dict):
            statuses.append(story.get("status"))
        else:
            return None
    return statuses


def ground_truth(doc):
    """Classify a phase from its own tasks file's story statuses.

    The one rule reconcile and the has-work map both read, so they cannot drift
    into two different answers about the same file.

    The empty-string return is the jq-era behaviour described in
    _story_statuses, kept because it is observable: reconcile turns it into a
    correction to "" rather than declining to correct. It is a defect, and
    fixing it is a behaviour change that does not belong in a port.

    failed is checked before either terminal-set branch below, and that order
    is load-bearing rather than cosmetic: a phase carrying even one failed
    story is never "completed" and never "planned", no matter what its other
    stories say. In practice the two conditions never actually compete --
    "every story is completed-or-skipped" and "any story is failed" cannot
    both be true of the same list -- but a reader should not have to prove
    that to trust the precedence, so failed is asked first and answered first.

    completed-or-skipped (issue #112): a story's status stops changing once it
    is "completed" OR "skipped" -- nothing in this codebase ever un-skips one --
    so a phase where every story has reached one of those two is exactly as
    finished, from ground_truth's point of view, as a phase where every story
    is "completed" outright. This is not a new rule invented for this phase
    boundary: tasks.py's own _dep_status_done already treats "completed" and
    "skipped" as the same "done" for a story's own dependents, and count-pending
    treats them the same for a whole tasks file. ground_truth answers "is there
    work left for execute to do here", not "did this phase deliver value" -- a
    deliberately skipped story already made that call, at cascade-skip time,
    and this function does not re-litigate it. That includes the all-skipped
    case: a phase whose every story was skipped delivered nothing, and still
    reads "completed", because every story in it has still reached a status
    nothing will ever move again. Judging "delivered nothing" is a different
    question than the one this function exists to answer, and answering it
    here would make ground_truth read intent instead of state.

    all-pending (issue #102): a phase whose stories are every one still
    "pending" has not been started -- no story has moved, so the phase itself
    has not moved, and "in_progress" was never true of it. This can correct an
    "in_progress" phase back to "planned" on reconcile, when a claim crashed
    before any story began: that direction is accepted rather than guarded
    against, because concurrency here is guarded by the claim field, not the
    status field. A live claim already excludes a phase from
    roadmap-claim's candidates regardless of status, and a dead one is cleared
    by roadmap-claim's own PID-liveness check before status is ever consulted
    -- so demoting the status changes what a human reading roadmap.json sees,
    not what a concurrent claim can do. reconcile also clears a claim only for
    a "completed" correction (see op_reconcile), so this demotion leaves
    whatever claim exists in place, and self-reclaim treats "planned" and
    "in_progress" identically.

    That reasoning covers roadmap-claim and stops there, which is exactly how
    far it goes: the session that owns the claim IS affected, because
    STATUS_TRANSITIONS has no planned -> completed edge, so a demoted phase
    strands its owner at Mark Phase Completed after every story has already
    run. This function cannot see that -- it is a pure function of the tasks
    file and never reads the stored status -- so the refusal lives in
    op_reconcile, which does. See the in_progress branch there.
    """
    statuses = _story_statuses(doc)
    if statuses is None:
        return ""
    if not statuses:
        return "unknown"
    if any(status == "failed" for status in statuses):
        return "verification_failed"
    if all(status in TERMINAL_STORY_STATUSES for status in statuses):
        return "completed"
    if all(status == "pending" for status in statuses):
        return "planned"
    return "in_progress"


def _read_tasks(path):
    """A phase's tasks file, or None when nothing is known about it.

    None covers every case bash's `[ -f ] && jq -e .` rejected, including the
    two `jq -e` treats as false rather than as a parse failure: a file holding
    literally `null` or `false`.
    """
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as handle:
            doc = json.load(handle)
    except (OSError, ValueError):
        return None
    if doc is None or doc is False:
        return None
    return doc


def has_work_map(roadmap_path, doc, feature):
    """{"<phase id>": <has work>} for every phase in a roadmap.

    A phase has NO work only when its own tasks file exists, parses, holds at
    least one story, and every story is "completed" or "skipped" -- i.e.
    exactly when ground_truth says "completed". That now includes a phase
    every one of whose stories was skipped: it reads has-work false and is
    demoted the same way a fully-completed phase already was by
    roadmap-claim's auto ranking (candidates, via _rank) -- a consequence
    issue #102's own not-affected analysis of this function does not cover,
    because it predates the skipped branch landing in the same ground_truth
    this map reads. Every other case is has-work:
      - no tasks file: a pending phase /aimi:plan has not expanded yet. Demoting
        a phase for being unplanned would rank the whole front of the roadmap
        last, which is the opposite of the intent.
      - unparseable: nothing is known, so nothing is demoted.
      - zero userStories ("unknown"): same reasoning reconcile already applies --
        it declines to correct a status from an empty story list.

    A `phases` that is not a list of dicts contributes nothing rather than
    raising. roadmap.json is a file people hand-edit and every other malformed
    shape in this module is already answered with an empty result; a scalar
    `phases` used to reach `.get` on an int here and print an AttributeError
    traceback, which told the agent reading the stream nothing it could act on.
    An empty map is also the SAFE answer: _rank leaves a phase the map does not
    mention undemoted, so a roadmap nobody can read reorders nothing.
    """
    feature_dir = os.path.dirname(roadmap_path)
    phases = doc.get("phases") if isinstance(doc, dict) else None
    work = {}
    for phase in phases if isinstance(phases, list) else []:
        if not isinstance(phase, dict):
            continue
        key = _jq_raw(phase.get("id"))
        path = (
            feature_dir + "/" + _tsv(phase.get("dir")) + "/"
            + feature + "-phase-" + key + "-tasks.json"
        )
        tasks = _read_tasks(path)
        truth = "unknown" if tasks is None else ground_truth(tasks)
        work[key] = truth != "completed"
    return work


def _status_by_id(phases):
    """{"<id>": status}. A later phase with a repeated id wins, as jq's reduce did."""
    return {_jq_raw(phase.get("id")): phase.get("status") for phase in phases}


def _depends_on(phase):
    """`.dependsOn // []` -- the alternative fires on false as well as null."""
    value = phase.get("dependsOn")
    if isinstance(value, dict):
        return list(value.values())
    return value if isinstance(value, list) else []


def _unmet(phase, status_by_id):
    """The dependency ids that have not reached completed, in declared order."""
    return [
        dep for dep in _depends_on(phase)
        if status_by_id.get(_jq_raw(dep)) != "completed"
    ]


def _rank(phase, work):
    """0 for a phase that still has work, 1 for one that does not.

    ORDER, not the set, was the defect (issue #90). A phase stuck in
    in_progress or verification_failed is by construction older, and therefore
    lower-id, than whatever came after it, so ordering by id alone made it win
    every auto-claim indefinitely ahead of the phase genuinely ready to run.
    Ranking DEMOTES, it never excludes: the moment a zero-work phase is the only
    eligible candidate it is claimed, which is what keeps crash recovery and the
    verification retry reachable.

    A phase the map does not mention ranks 0. That is deliberate and is what the
    jq's `has($k)` test meant: an unknown phase is not demoted.
    """
    key = _jq_raw(phase.get("id"))
    if key in work:
        return 0 if work[key] else 1
    return 0


def rank_first_key(phase, work):
    """Remaining work first, numeric id second -- the claim order (issue #90)."""
    return (_rank(phase, work), jq_sort_key(phase.get("id")))


def id_only_key(phase, _work):
    """Numeric id alone, consulting no work map.

    The answer a caller gets from this key depends on roadmap.json and nothing
    else, which is the point: /aimi:plan reports which phases it may expand
    while an /aimi:execute run is rewriting tasks files underneath it, and a
    ranking that reads those files would move its answer between two reads of
    the same roadmap.
    """
    return jq_sort_key(phase.get("id"))


def candidates(phases, allowed, work, sort_key=rank_first_key):
    """The claimable phases, in the order the caller asked for.

    The caller supplies the array it wants judged, and that is deliberate: it is
    the axis on which the two selectors differ. roadmap-claim passes phases
    whose dead-PID claims it has already cleared, inside its own lock;
    roadmap-get --next-eligible passes them untouched, because it holds no lock
    and clearing stale claims is a decision that belongs where the lock is. So a
    phase held by a dead session stays claimable by one and invisible to the
    other -- unifying the ordering was never meant to change that, and a
    read-only verb has no business inferring liveness.

    ORDER is the second such axis, and it defaults to the one the two selectors
    already used, so neither of them moves a byte. roadmap-eligible passes
    id_only_key with an empty work map: it answers "which phases MAY be
    expanded", a question with no notion of how much is left to do, and buying
    a ranking it does not use would cost it one tasks-file read per phase and
    the determinism that comes with reading none.
    """
    status_by_id = _status_by_id(phases)
    eligible = [
        phase for phase in phases
        if phase.get("status") in allowed
        and phase.get("claim") is None
        and not _unmet(phase, status_by_id)
    ]
    return sorted(eligible, key=lambda p: sort_key(p, work))


def is_pid_alive(pid_text):
    """Signal-zero liveness probe, the same reading guard-runtime-state.py uses.

    "No such process" is not alive; "exists, but this user may not signal it" is
    alive -- ProcessLookupError False, PermissionError True. The text arrives as
    `tostring` produced it, so a null claimedPid is the literal "null" and fails
    the numeric test before any signal is sent, which is what makes a
    hand-edited claim releasable rather than fatal.
    """
    if not re.fullmatch(r"[0-9]+", pid_text):
        return False
    pid = int(pid_text)
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except (OverflowError, OSError):
        return False
    return True


def rm_sanitize_lines(value, maxlen):
    """`jq -Rr _rm_sanitize` over raw input, whose framing is per LINE.

    jq -R hands the filter one string per input line and the command
    substitution that captured its output joined those lines back with newlines,
    so a session id carrying a newline keeps it -- even though removing newlines
    is one of the things the sanitizer exists to do. Ported as it stood: this is
    what is stored in claimedBy today, and a port is not where a rule changes.
    """
    lines = value.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return "\n".join(rm_sanitize(line, maxlen) for line in lines)


# The status graph. verification_failed is reachable from any non-terminal state
# (execute sets it when creates-verification fails) and is therefore not listed.
#   pending -> planned            plan expands the phase
#   pending -> in_progress        execute claims a phase whose planned transition
#                                 was lost (plan aborted after writing tasks.json
#                                 but before setting planned) -- allowing it makes
#                                 execute self-healing instead of silently
#                                 diverging from roadmap.json
#   planned -> in_progress        normal start
#   in_progress -> in_progress    idempotent resume of a crashed session
#   verification_failed -> in_progress   re-verify retry
#   in_progress|verification_failed -> completed
STATUS_TRANSITIONS = frozenset(
    [
        "pending:planned",
        "pending:in_progress",
        "planned:in_progress",
        "in_progress:in_progress",
        "verification_failed:in_progress",
        "in_progress:completed",
        "verification_failed:completed",
    ]
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


def warn_list(header, lines):
    """The non-fatal half of _die_list, and the same pair story_merge.py has.

    Mirrored rather than reinvented: story_merge.py's warn_list writes the
    header and the lines, and its die_list calls it and adds the exit, so the
    two channels there cannot drift in how a diagnostic is rendered. _die_list
    below is now that same shape. Until this existed, every verdict this file
    could reach was fatal -- 13 _die_list call sites and nothing else -- so a
    check that must not stop a write had nowhere to go.
    """
    sys.stderr.write(header + "\n")
    for line in lines:
        sys.stderr.write(line + "\n")


def _die_list(header, lines, note=False):
    warn_list(header, lines)
    if note:
        sys.stderr.write(IDENTITY_NOTE + "\n")
    sys.exit(1)


def op_init_validate(argv):
    """Everything roadmap-init checks BEFORE it takes the lock.

    Split from init-write for one reason: today an invalid payload never
    reaches `mkdir -p`, so it never creates the feature directory. Doing
    validation inside the lock would create it as a side effect of a refusal.

    --integration-branch is judged here for exactly that reason. It shipped
    validated in init-write instead, which put the refusal after the mkdir and
    inside the lock -- so `roadmap-init --integration-branch 'bad branch!'`
    exited 1 having created the feature directory and a stale .lock, which is
    the side effect this split exists to prevent. init-write still re-checks
    it: two layers on purpose, the same shape validate_story_exists uses.
    """
    integration_branch = _flag(argv, "--integration-branch") or ""
    if integration_branch and not BRANCH_REGEX.fullmatch(integration_branch):
        die(
            'Error: roadmap-init: integrationBranch "'
            + integration_branch
            + '" contains invalid characters'
        )

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

    # Before init_sanitize, which reaches into an entry's two fields and would
    # otherwise raise out of a sanitizer on a payload still written in 1.0.
    shape_errors = init_entry_shape_errors(payload)
    if shape_errors:
        _die_list("Error: roadmap-init: malformed creates/needs entry:", shape_errors)

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
    integration_branch = _flag(argv, "--integration-branch") or ""
    sync_mode = "--sync" in argv
    if not path or not feature:
        die("Usage: roadmap.py init-write --roadmap <path> --feature <slug> [--sync]")

    # Refused here, before the phases payload is even read, rather than stored:
    # the field is a branch name, so it is judged against the exact pattern a
    # phase's own `branch` field already enforces (BRANCH_REGEX above) instead
    # of a second one. An empty value is legal -- it means "not declared" -- so
    # only a non-empty, non-matching value dies.
    if integration_branch and not BRANCH_REGEX.fullmatch(integration_branch):
        die(
            'Error: roadmap-init: integrationBranch "'
            + integration_branch
            + '" contains invalid characters'
        )

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
        identity = judge_phases(filtered_new, path)
        if identity:
            _die_list(
                "Error: roadmap-init: malformed creates/needs identity in new phase(s):",
                identity,
                note=True,
            )

        merged = existing_phases + filtered_new
        merged.sort(key=lambda p: jq_sort_key(p.get("id")))
        # --sync preserves every top-level key it did not come to change, and
        # replaces only `phases`. It used to rebuild from a whitelist instead,
        # and that whitelist erased integrationBranch on its first use -- a
        # field DOCUMENTED as addable to an existing roadmap.json by hand, i.e.
        # arriving by a route a list of permitted names is structurally unable
        # to know about. Widening the list to six would fix that one key and
        # leave the shape that produced it.
        #
        # Inverted rather than widened, for three reasons:
        #   - The list performed no admission function. The untrusted input is
        #     the phases payload on stdin, already through init-validate;
        #     `existing` is a document this CLI wrote and guard-runtime-state
        #     protects from Write/Edit. It was filtering this script's own
        #     output.
        #   - It was the ONLY writer doing so. op_amend_write, op_set_status,
        #     op_claim, op_release_claim, op_reconcile and op_normalize_contracts
        #     all mutate `doc` in place and have always preserved unknown keys.
        #     Six writers obeyed one rule and this one held an exception.
        #   - The failure directions are not symmetric. A too-narrow allowlist
        #     erases user data silently; a too-narrow denylist carries a stale
        #     key forward, which is visible and repairable. Take the visible one.
        #
        # Accepted knowingly: a --sync over a document carrying a junk top-level
        # key now preserves the junk. It can only have arrived by a hand-edit --
        # the same route integrationBranch is designed to arrive by -- so
        # preserving it is the same promise, not a new hazard.
        #
        # This call's own --integration-branch flag is still NOT consulted here:
        # only materialization (the create branch below) writes a fresh value.
        # --sync preserves; it never overwrites a value someone declared by hand.
        doc = {k: v for k, v in existing.items() if k != "phases"}
        doc["phases"] = merged
        added_count = len(filtered_new)
    else:
        allowed = [p.get("id") for p in new_phases]
        dangling = dangling_errors(new_phases, allowed)
        if dangling:
            _die_list("Error: roadmap-init: dangling dependsOn reference(s):", dangling)

        identity = judge_phases(new_phases, path)
        if identity:
            _die_list(
                "Error: roadmap-init: malformed creates/needs identity in new phase(s):",
                identity,
                note=True,
            )

        merged = list(new_phases)
        merged.sort(key=lambda p: jq_sort_key(p.get("id")))
        doc = {
            # A roadmap this verb writes today holds 2.0 entries, so it says so.
            # Stamping 1.0 here would make the contract gate refuse a document
            # this CLI had just produced.
            "roadmapVersion": CONTRACT_VERSION,
            "feature": feature,
            "createdAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "brainstormPath": rm_sanitize(brainstorm_path, 500) if brainstorm_path else None,
            # Already validated above, against the same BRANCH_REGEX a phase's
            # own `branch` field uses -- no further sanitization needed.
            "integrationBranch": integration_branch or None,
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
    if "branch" in sanitized and branch is not None and not BRANCH_REGEX.fullmatch(branch):
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
        amended[key] = value

    # Judge ONLY the lists this call actually writes. Handing over the merged
    # phase would re-judge a list the amendment never touched, turning every
    # tightening of the identity rule into a retroactive refusal -- a phase whose
    # stored creates holds a legacy whitespace identity could no longer have its
    # needs amended, and repairing exactly those phases is what this verb is for.
    check = {"id": amended.get("id")}
    if "creates" in patch:
        check["creates"] = amended.get("creates") or []
    if "needs" in patch:
        check["needs"] = amended.get("needs") or []
    if "areas" in patch:
        check["areas"] = amended.get("areas") or []
    identity_errors = judge_phases([check], path)
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

    # old identity -> the amended phase's new creates entry VERBATIM (both
    # fields), so provider and consumer stay byte-identical.
    retarget_map = {}
    for pair in pairs:
        match = next(
            (e for e in contract_entries(amended, "creates") if e["identity"] == pair["new"]),
            None,
        )
        retarget_map[pair["old"]] = match

    retargeted = [
        {"phase": p.get("id"), "from": entry, "to": retarget_map[entry["identity"]]}
        for p in doc.get("phases") or []
        if p.get("id") != phase_id
        for entry in contract_entries(p, "needs")
        if entry["identity"] in retarget_map
    ]

    # One write: the phase swap and every authorized downstream needs rewrite.
    for index, phase in enumerate(doc.get("phases") or []):
        if phase.get("id") == phase_id:
            doc["phases"][index] = amended
        elif retarget_map and isinstance(phase.get("needs"), list):
            # Guarded on the key EXISTING, not on its contents: a phase with no
            # needs at all must not acquire an empty one as a side effect of
            # somebody else's rename.
            phase["needs"] = [
                retarget_map.get(e["identity"], e) for e in contract_entries(phase, "needs")
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
            # out without anyone remembering it exists. There were two such keys
            # here until the schema split (the marker forms the identity guard's
            # mutation check consumed), and neither of the two assertions on this
            # field noticed them, because neither amended creates or needs.
            "amended": sorted(k for k in patch if k in AMENDABLE_KEYS),
            "retargeted": retargeted,
        },
        sys.stdout,
        indent=2,
    )
    sys.stdout.write("\n")
    return 0


def _phase_declared_files(roadmap_path, doc, phase):
    """The implementation.files[] this phase's own stories declared, normalized.

    Built from the ONE path every other reader in this file builds --
    <feature_dir>/<dir>/<feature>-phase-<id>-tasks.json, the same derivation
    has_work_map uses -- and empty whenever there is nothing to read.

    Empty is the SAFE answer and the reason this returns a set rather than
    raising: it turns the bare-name advisory OFF. A phase /aimi:plan has not
    expanded yet, a split phase whose stories live in sibling files this name
    does not reach, an unreadable document -- in all three nobody has measured
    what the phase declared, and an advisory that fires against an unknown is an
    advisory people learn to skip.
    """
    feature = doc.get("feature") if isinstance(doc, dict) else None
    if not isinstance(feature, str) or not feature:
        return set()
    tasks_path = (
        os.path.dirname(roadmap_path) + "/" + _tsv(phase.get("dir")) + "/"
        + feature + "-phase-" + _jq_raw(phase.get("id")) + "-tasks.json"
    )
    tasks = _read_tasks(tasks_path)
    if tasks is None:
        return set()
    return {
        _norm_repo_path(entry)
        for entry in overlap_files(tasks)
        if isinstance(entry, str) and entry.strip()
    }


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

    # The identity is read from its own field: there is no split left to
    # re-derive here, which is what this schema change was for.
    #
    # stderr carries the advisory, stdout the verdicts, and the two never mix:
    # every caller of this verb parses stdout as JSON, so an advisory written
    # there would break the parse it is trying to inform.
    phase_files = _phase_declared_files(path, doc, phase)
    warnings = []
    verdicts = [
        verify_creates_one(directory, entry["identity"], phase_files, warnings)
        for entry in contract_entries(phase, "creates")
    ]
    if warnings:
        warn_list(
            "Warning: creates identity verified by text against a file no story "
            "of this phase declared:",
            warnings,
        )
    json.dump(verdicts, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def op_sweep(argv):
    """Advisory only: this op has no failure verdict, only a report."""
    path = _flag(argv, "--roadmap")
    if not path:
        die("Usage: roadmap.py sweep --roadmap <path>")
    doc = jq_numbers(read_doc(path, "roadmap-sweep"))
    json.dump(sweep(doc), sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def op_write_handoff(argv):
    """Validate the payload, render the body, refuse if the render lost an
    identity. stdout is the body; bash confines the path and writes it under the
    lock, because a handoff path is built from a `dir` roadmap.json holds and
    path confinement is bash's rule, not this file's."""
    path = _flag(argv, "--roadmap")
    phase_raw = _flag(argv, "--phase")
    if not path or phase_raw is None:
        die("Usage: roadmap.py write-handoff --roadmap <path> --phase <id>")
    phase_id = jq_numbers(json.loads(phase_raw))

    raw = sys.stdin.read()
    # An empty payload is zero jq inputs, hence zero outputs and an empty body:
    # the verb wrote a one-newline handoff.md and exited 0. Preserved rather than
    # turned into a refusal because roadmap-set-status's completed precondition
    # only checks that the file EXISTS, so refusing here would change which
    # phases can complete.
    if raw.strip() == "":
        return 0

    try:
        payload = json.loads(raw)
    except ValueError:
        payload = None
    if not isinstance(payload, dict):
        die("Error: roadmap-write-handoff: payload must be a JSON object")

    bad_field = handoff_field_error(payload)
    if bad_field is not None:
        die(
            "Error: roadmap-write-handoff: field '"
            + bad_field
            + "' must be an array of strings"
        )

    # The identities this phase declared, straight from the field that holds
    # them -- there is no split rule here to drift from anyone else's.
    doc = read_doc(path, "roadmap-write-handoff")
    identities = [
        entry["identity"]
        for phase in doc.get("phases") or []
        if phase.get("id") == phase_id
        for entry in contract_entries(phase, "creates")
    ]

    body = handoff_body(payload, identities)
    lost = handoff_lost_identities(payload, identities, body)
    if lost:
        sys.stderr.write(
            "Error: roadmap-write-handoff: the rendered handoff lost a declared "
            "identity it was asked to report:\n"
        )
        for identity in lost:
            sys.stderr.write("  " + identity + "\n")
        sys.stderr.write(
            "Error: roadmap-write-handoff: '## Artifacts Created' is what "
            "validate-contracts greps to resolve a downstream needs, so writing "
            "this would leave that contract permanently unmet. Nothing was "
            "written.\n"
        )
        sys.exit(1)

    # No trailing newline of our own: the body already ends with one, and bash
    # captures this in a command substitution that strips them either way.
    sys.stdout.write(body)
    return 0


def op_phase_overlap(argv):
    """The phase ids arrive as the strings the caller typed, because every
    message quotes them back verbatim ("phase 2.1 not found") and the tasks
    filename is built from them."""
    path = _flag(argv, "--roadmap")
    feature = _flag(argv, "--feature")
    raw = {"a": _flag(argv, "--phase-a"), "b": _flag(argv, "--phase-b")}
    if not path or not feature or raw["a"] is None or raw["b"] is None:
        die(
            "Usage: roadmap.py phase-overlap --roadmap <path> --feature <slug> "
            "--phase-a <id> --phase-b <id>"
        )
    doc = jq_numbers(read_doc(path, "phase-overlap"))
    feature_dir = os.path.dirname(path)

    dirs = {side: phase_dirs(doc, jq_numbers(json.loads(raw[side]))) for side in ("a", "b")}
    for side in ("a", "b"):
        if not dirs[side]:
            die("Error: phase-overlap: phase " + raw[side] + " not found in " + path)

    # Mirrors execute.md Step 1.7's PHASE_TASKS_PATH convention:
    # <feature_dir>/<phase_dir>/<feature>-phase-<id>-tasks.json
    tasks = {
        side: feature_dir + "/" + dirs[side] + "/" + feature + "-phase-" + raw[side] + "-tasks.json"
        for side in ("a", "b")
    }
    for side in ("a", "b"):
        if not os.path.isfile(tasks[side]):
            die(
                "Error: phase-overlap: phase " + raw[side] + " has no tasks file yet ("
                + tasks[side] + ") -- run /aimi:plan --phase " + raw[side]
                + " to materialize it first"
            )
    docs = {}
    for side in ("a", "b"):
        try:
            with open(tasks[side], "r", encoding="utf-8") as handle:
                docs[side] = jq_numbers(json.load(handle))
        except (OSError, ValueError):
            die("Error: phase-overlap: malformed tasks file: " + tasks[side])

    # Both sides are already deduplicated and sorted, so the intersection is too.
    files_a = jq_unique(overlap_files(docs["a"]))
    keys_b = {_jq_key(value) for value in jq_unique(overlap_files(docs["b"]))}
    overlapping = [value for value in files_a if _jq_key(value) in keys_b]

    json.dump({"overlapping_files": overlapping}, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def _emit(value):
    """One JSON value on stdout, rendered the way jq's default output did."""
    json.dump(value, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")


def _joined(values):
    """jq's `join(", ")` over ids, each through `tostring`."""
    return ", ".join(_jq_raw(value) for value in values)


def op_roadmap_get(argv):
    """Read-only, so this is the one lifecycle verb bash calls outside a lock.

    --phase wins over --next-eligible, and with neither the whole file is copied
    byte for byte -- it is the document the caller asked for, not a
    re-serialization of it.
    """
    path = _flag(argv, "--roadmap")
    feature = _flag(argv, "--feature")
    phase_raw = _flag(argv, "--phase")
    if not path or not feature:
        die("Usage: roadmap.py roadmap-get --roadmap <path> --feature <slug> "
            "[--phase <id>] [--next-eligible]")

    if phase_raw:
        doc = read_doc(path, "roadmap-get")
        phase_id = jq_numbers(json.loads(phase_raw))
        matches = [p for p in (doc.get("phases") or []) if p.get("id") == phase_id]
        if not matches:
            die("Error: roadmap-get: phase " + phase_raw + " not found in " + path)
        for phase in matches:
            _emit(phase)
        return 0

    if "--next-eligible" in argv:
        doc = read_doc(path, "roadmap-get")
        # Reading one tasks file per phase is cost for a verb that once touched
        # only roadmap.json, and it is unsynchronized -- a tasks file rewritten
        # mid-read yields "has work", the safe answer, since only an
        # all-completed file demotes anything.
        eligible = candidates(
            doc.get("phases") or [],
            GET_ELIGIBLE_STATUSES,
            has_work_map(path, doc, feature),
        )
        if not eligible:
            die("Error: roadmap-get: no eligible phase found")
        _emit(eligible[0])
        return 0

    with open(path, "rb") as handle:
        sys.stdout.buffer.write(handle.read())
    return 0


def parse_statuses(raw):
    """`--statuses a,b,c`, refused rather than silently narrowed.

    An unknown name is the failure mode worth spending a message on: filtering
    on it returns zero eligible phases, which is a legitimate answer the caller
    cannot tell apart from a typo. So the offending value AND the accepted
    vocabulary both go in the message, and the verb stops.
    """
    names = [name.strip() for name in raw.split(",")]
    unknown = [name for name in names if name not in PHASE_STATUSES]
    if unknown:
        die(
            "Error: roadmap-eligible: --statuses: unknown status "
            + ", ".join('"' + name + '"' for name in unknown)
            + " (accepted: "
            + ", ".join(PHASE_STATUSES)
            + ")"
        )
    return names


def op_roadmap_eligible(argv):
    """Every phase's eligibility verdict, and for the rest, what is holding it.

    THREE THINGS THIS VERB DELIBERATELY DOES NOT DO.

    It does not die when nothing is eligible. "No phase is ready" is a normal
    answer here, unlike in roadmap-get --next-eligible, where the caller wanted
    one phase and got none. This one's caller captures stdout in a command
    substitution and has to be able to tell an empty eligible list from a CLI
    that broke, so an empty list exits 0 and says so in the payload.

    It writes no prose. Not one field carries a sentence, because the plugin's
    user-facing wording follows whatever language the person is writing in
    (commands/references/user-communication.md) and a sentence composed here
    cannot be re-worded by the command that prints it. A blocked phase is
    `eligible: false` plus its own unmet ids and its own claim object; the
    caller composes the sentence.

    It reads no tasks file. See id_only_key: this answer must not move while a
    concurrent /aimi:execute rewrites the very files a work-ranking would read.

    The payload covers EVERY phase, not just the eligible ones, so one call
    serves both a list rendering and a by-id lookup.
    """
    path = _flag(argv, "--roadmap")
    statuses_raw = _flag(argv, "--statuses")
    if not path:
        die("Usage: roadmap.py roadmap-eligible --roadmap <path> [--statuses <a,b>]")
    allowed = GET_ELIGIBLE_STATUSES if statuses_raw is None else parse_statuses(statuses_raw)

    doc = read_doc(path, "roadmap-eligible")
    stored = doc.get("phases") if isinstance(doc, dict) else None
    # Same tolerance has_work_map applies: a hand-edited roadmap whose phases is
    # a scalar, a string, or a list with a stray entry in it answers "no phases"
    # rather than raising at the caller.
    phases = [p for p in stored if isinstance(p, dict)] if isinstance(stored, list) else []

    status_by_id = _status_by_id(phases)
    ordered = candidates(phases, allowed, {}, id_only_key)
    chosen = {id(phase) for phase in ordered}

    records = [
        {
            "id": phase.get("id"),
            "name": phase.get("name"),
            "status": phase.get("status"),
            "claim": phase.get("claim"),
            "eligible": id(phase) in chosen,
            "unmet": [
                {"id": dep, "status": status_by_id.get(_jq_raw(dep))}
                for dep in _unmet(phase, status_by_id)
            ],
        }
        for phase in phases
    ]

    _emit(
        {
            "phases": records,
            "eligible": [phase.get("id") for phase in ordered],
            "eligibleCount": len(ordered),
        }
    )
    return 0


def _index(value, key, path):
    """jq's `.<key>`: legal on an object and on null, an error on anything else."""
    if value is None:
        return None
    if isinstance(value, dict):
        return value.get(key)
    die(
        "Error: list-archivable: " + path + ': cannot index ' + _json_type(value)
        + ' with "' + key + '"'
    )


def op_list_archivable_phases(argv):
    """Every phase's terminal/stuck verdict, for list-archivable's roadmap half.

    WHY THIS IS NOT roadmap-eligible. That verb carries the same status column
    and the question was real. Two things settle it. Consuming its payload from
    bash would still leave bash counting `.status != "completed"` over the
    OUTPUT -- the same rule, still in jq, still in aimi-cli.sh, merely moved.
    And it reaches its document through read_doc, which die()s on malformed
    JSON, where list-archivable's `jq -e .` probe failed silently and the
    feature was INCLUDED. Routing through it would turn a silent include into a
    hard abort. So: a new op, in roadmap-eligible's GENERAL form -- a verdict
    for every phase plus the derived aggregates -- rather than a boolean shaped
    for one caller.

    THE DOCUMENT'S USABILITY IS PART OF THE ANSWER, NOT AN ABORT. `usable`
    reproduces `jq -e . <file>`: false for a parse error and for a document
    whose value is null or false, because -e exits 1 on those and bash then
    skipped the whole `if`. An EMPTY (or whitespace-only) file is a third state
    and not a fourth line in the payload: jq -e exits 0 over zero documents, and
    the counting jq then printed nothing, which is what made bash's
    `[ -z "$non_terminal_phases" ] && continue` arm fire. That state is
    `usable: true` with `nonTerminalCount: null`.

    WHAT STILL TAKES THE VERB DOWN, because it did before. `.phases[]` over a
    null, a string or a number, and `.status` on a phase that is not an object,
    are jq ERRORS, and under `set -euo pipefail` the assignment that ran them
    ended the whole command at jq's own exit 5 with its message swallowed. That
    is preserved as a refusal -- the verb stops, stdout stays empty -- with one
    stderr line naming the verb, the file and the shape instead of nothing at
    all. Only the engine's number moves.

    THE STREAM SHAPE OF stdout, and why the payload is compact and last:

        1  usable            true | false
        2  nonTerminalCount  empty for no document, else decimal digits
        3..N-1  stuckIds     raw, possibly empty, possibly MULTI-LINE
        N  payload           the whole verdict, compact, exactly one line

    bash splits this with parameter expansion and no jq, the way cmd_init_session
    already splits its own first line off. stuckIds is `tostring` output, and a
    string id carrying a newline prints one -- so it goes last of the raw fields
    and the payload is compact, which is what keeps a hostile id from shifting
    the fields above it.
    """
    path = _flag(argv, "--roadmap")
    if not path:
        die("Usage: roadmap.py list-archivable-phases --roadmap <path>")

    try:
        with open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        text = None

    records = []
    count = None
    stuck_ids = ""
    if text is None:
        usable = False
    elif text.strip() == "":
        # jq -e over zero documents exits 0, and the counting jq printed
        # nothing: usable, with no count for bash to test.
        usable = True
    else:
        try:
            doc = json.loads(text)
        except ValueError:
            # A parse error AND a multi-document stream both land here. jq read
            # the second document happily; what the two share is that bash
            # never got a single usable count out of them, and both ended with
            # the feature included.
            doc = None
            usable = False
        else:
            usable = doc is not None and doc is not False

        if usable:
            stored = _index(doc, "phases", path)
            if isinstance(stored, list):
                entries = stored
            elif isinstance(stored, dict):
                entries = list(stored.values())  # `.[]` over an object yields its values
            else:
                die(
                    "Error: list-archivable: " + path + ": cannot iterate over "
                    + _json_type(stored) + " (.phases)"
                )
            for entry in entries:
                status = _index(entry, "status", path)
                records.append(
                    {
                        "id": _index(entry, "id", path),
                        "status": status,
                        "terminal": status == "completed",
                        "stuck": status == "verification_failed",
                    }
                )
            count = sum(1 for row in records if not row["terminal"])
            stuck_ids = _joined([row["id"] for row in records if row["stuck"]])

    payload = {
        "usable": usable,
        "phases": records,
        "nonTerminalCount": count,
        "stuckIds": stuck_ids,
    }
    sys.stdout.write("true\n" if usable else "false\n")
    sys.stdout.write(("" if count is None else str(count)) + "\n")
    sys.stdout.write(stuck_ids + "\n")
    sys.stdout.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
    return 0


def op_set_status(argv):
    """The locked read-modify-write. Bash holds the lock and has already refused
    every argument it can judge on its own, so what is left here needs the
    document: which statuses the phase currently has, whether the transition is
    in the graph, and whether handoff.md exists."""
    path = _flag(argv, "--roadmap")
    phase_raw = _flag(argv, "--phase")
    new_status = _flag(argv, "--status")
    force = "--force" in argv
    if not path or phase_raw is None or new_status is None:
        die("Usage: roadmap.py set-status --roadmap <path> --phase <id> --status <s> [--force]")
    phase_id = jq_numbers(json.loads(phase_raw))

    doc = read_doc(path, "roadmap-set-status")
    phases = doc.get("phases") or []

    # `(.phases[] | select(.id == $pid) | .status) // empty`, joined the way a
    # command substitution joins jq's output lines. The alternative drops a null
    # or false status per match, so a phase carrying one reads as not found --
    # and two phases sharing an id produce a two-line "status" that matches no
    # transition, which is the shape the graph check below then refuses.
    current = "\n".join(
        _jq_raw(phase.get("status"))
        for phase in phases
        if phase.get("id") == phase_id
        and phase.get("status") is not None
        and phase.get("status") is not False
    )
    if current == "":
        die("Error: roadmap-set-status: phase " + phase_raw + " not found in " + path)

    allowed = new_status == "verification_failed" or (
        current + ":" + new_status
    ) in STATUS_TRANSITIONS
    if not allowed and not force:
        die(
            "Error: roadmap-set-status: transition "
            + current
            + " -> "
            + new_status
            + " is not allowed without --force"
        )

    # Hard rule, not a --force-able ordering convention: a phase can never reach
    # "completed" without handoff.md already on disk at its phase dir. handoff.md
    # is written only via roadmap-write-handoff, the guard-protected path
    # guard-runtime-state.py points callers at. This check runs even when --force
    # is set -- --force overrides transition ORDER, never this physical artifact
    # precondition.
    if new_status == "completed":
        handoff = (
            os.path.dirname(path) + "/" + phase_dirs(doc, phase_id) + "/handoff.md"
        )
        if not os.path.isfile(handoff):
            die(
                "Error: roadmap-set-status: phase "
                + phase_raw
                + " cannot transition to completed -- no handoff.md found at "
                + handoff
                + ". Write it first with roadmap-write-handoff."
            )

    # Completing a phase also releases its claim in the same atomic write -- no
    # window where status reads completed while the phase still shows claimed.
    for phase in phases:
        if phase.get("id") == phase_id:
            phase["status"] = new_status
            if new_status == "completed":
                phase["claim"] = None

    write_doc_atomically(path, doc)
    _emit({"phase": phase_id, "from": current, "to": new_status})
    return 0


def op_claim(argv):
    """The locked check-and-set: release what is stale, then choose.

    Bash still owns the lock and the session-pid pattern; everything below needs
    the document. Exit statuses are part of the contract -- 4 for "there is
    nothing to claim", 3 for "there is, and you cannot have it" -- because
    execute.md branches on them.
    """
    path = _flag(argv, "--roadmap")
    feature = _flag(argv, "--feature")
    session_raw = _flag(argv, "--session-id")
    pid_raw = _flag(argv, "--session-pid")
    phase_raw = _flag(argv, "--phase")
    if not path or not feature or session_raw is None or pid_raw is None:
        die("Usage: roadmap.py claim --roadmap <path> --feature <slug> "
            "--session-id <id> --session-pid <pid> [--phase <id>]")

    doc = read_doc(path, "roadmap-claim")
    phases = doc.get("phases") or []
    session_id = rm_sanitize_lines(session_raw, 200)
    session_pid = jq_numbers(json.loads(pid_raw))
    override = jq_numbers(json.loads(phase_raw)) if phase_raw else None

    # sessionId travels alongside pid so the caller's release report can be built
    # without a second read: staleReleased is what execute.md prints as "released
    # stale claim on phase <id> (session <sid> pid <pid> not alive)".
    claimed = [
        {
            "id": phase.get("id"),
            "pid": (phase.get("claim") or {}).get("claimedPid"),
            "sessionId": (phase.get("claim") or {}).get("claimedBy"),
        }
        for phase in phases
        if phase.get("claim") is not None
    ]
    stale = [row for row in claimed if not is_pid_alive(_jq_raw(row["pid"]))]
    stale_ids = [row["id"] for row in stale]

    # Clearing in place is the same array the write below persists, which is why
    # a stale claim on a phase nobody claims this run is still released.
    for phase in phases:
        if phase.get("id") in stale_ids:
            phase["claim"] = None

    status_by_id = _status_by_id(phases)
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    def succeed(phase, refresh):
        """Write, then print the claim envelope.

        The envelope is the phase object itself plus staleReleased, and that is
        a contract: execute.md Step 1.7 reads .id/.dir/.slug/.branch/.status off
        it and Step 3 branches on .status. Projecting it down to a summary would
        silently disable the re-verify branch, which is why the suite pins all
        six fields on the auto path.

        `refresh` is false for a self-reclaim: the phase comes back with the
        claim it already carried, not a rewritten one.
        """
        if refresh:
            phase["claim"] = {
                "claimedBy": session_id,
                "claimedAt": now,
                "claimedPid": session_pid,
            }
        write_doc_atomically(path, doc)
        report = dict(phase)
        report["staleReleased"] = stale
        _emit(report)
        return 0

    # Self-reclaim: this exact session already owns an unreleased claim on a
    # still-active phase (matching the requested --phase when given). Return it
    # again instead of erroring or re-running eligibility -- this is what makes
    # re-running /aimi:execute on an already-claimed phase idempotent.
    mine = [
        phase for phase in phases
        if phase.get("claim") is not None
        and (phase["claim"] or {}).get("claimedBy") == session_id
        and phase.get("status") in ("pending", "planned", "in_progress")
        and (override is None or phase.get("id") == override)
    ]
    if mine:
        return succeed(sorted(mine, key=lambda p: jq_sort_key(p.get("id")))[0], False)

    if override is not None:
        targets = [phase for phase in phases if phase.get("id") == override]
        if not targets:
            die("Error: roadmap-claim: phase " + phase_raw + " not found in " + path, 4)
        target = targets[0]
        detail = None
        if target.get("status") not in CLAIMABLE_STATUSES:
            detail = "phase status is " + (target.get("status") or "")
        elif target.get("claim") is not None:
            detail = "claimed by a live session"
        elif _unmet(target, status_by_id):
            detail = "depends on incomplete phase(s): " + _joined(
                _unmet(target, status_by_id)
            )
        if detail is not None:
            die(
                "Error: roadmap-claim: phase " + phase_raw + " is not claimable: " + detail,
                3,
            )
        return succeed(target, True)

    # Resumable = not yet terminal AND carrying no live claim. Stale claims were
    # already cleared above, so an unclaimed in_progress phase is leftover from a
    # crashed session and verification_failed is awaiting a re-verify run -- both
    # must be re-claimable or crash recovery and verification retry are dead
    # ends, which is exactly what execute.md tells the user to recover by
    # re-running.
    # Has-work pre-pass inside the same lock, so the ordering reads a tasks-file
    # snapshot no concurrent claim can move under it. It stays a SIDE MAP and is
    # never merged onto the phase objects: `phases` is the very array written
    # back below, so a synthetic key added here would be persisted forever and
    # would then flow into validate-contracts, roadmap-sweep and reconcile.
    eligible = candidates(phases, CLAIMABLE_STATUSES, has_work_map(path, doc, feature))
    if eligible:
        return succeed(eligible[0], True)

    remaining = [p for p in phases if p.get("status") in CLAIMABLE_STATUSES]
    if not remaining:
        die(
            "Error: roadmap-claim: no phase remains in pending, planned, "
            "in_progress or verification_failed status",
            4,
        )
    sys.stderr.write(
        "Error: roadmap-claim: all remaining pending/planned phases are blocked:\n"
    )
    for phase in remaining:
        if phase.get("claim") is not None:
            reason = "claimed by session " + ((phase["claim"] or {}).get("claimedBy") or "")
        else:
            reason = "depends on incomplete phase(s): " + _joined(
                _unmet(phase, status_by_id)
            )
        sys.stderr.write("  phase " + _jq_raw(phase.get("id")) + ": " + reason + "\n")
    sys.exit(3)


def op_release_claim(argv):
    """The manual escape hatch, in addition to automatic stale-claim recovery.

    It is the one lifecycle verb that never checked the document parses before
    taking the lock, so a malformed roadmap arrives here and reports the phase as
    not found. Preserved rather than newly diagnosed: the message is what its
    callers have always seen.
    """
    path = _flag(argv, "--roadmap")
    phase_raw = _flag(argv, "--phase")
    if not path or phase_raw is None:
        die("Usage: roadmap.py release-claim --roadmap <path> --phase <id>")
    phase_id = jq_numbers(json.loads(phase_raw))

    try:
        with open(path, "r", encoding="utf-8") as handle:
            doc = json.load(handle)
    except (OSError, ValueError):
        doc = None

    phases = doc.get("phases") or [] if isinstance(doc, dict) else []
    matches = [p for p in phases if isinstance(p, dict) and p.get("id") == phase_id]
    if not matches:
        die("Error: roadmap-release-claim: phase " + phase_raw + " not found in " + path)

    for phase in matches:
        phase["claim"] = None
    write_doc_atomically(path, doc)
    _emit({"released": phase_id})
    return 0


def op_reconcile(argv):
    """Every phase's status against its own tasks file's ground truth.

    A correction to "completed" is applied only when handoff.md already exists;
    otherwise it is reported as blocked rather than applied. Reconcile must not
    be a second write path with weaker invariants than roadmap-set-status -- an
    otherwise-valid completed correction stays visible as a divergence instead of
    being silently healed wrong.
    """
    path = _flag(argv, "--roadmap")
    feature = _flag(argv, "--feature")
    if not path or not feature:
        die("Usage: roadmap.py reconcile --roadmap <path> --feature <slug>")

    doc = read_doc(path, "roadmap-reconcile")
    feature_dir = os.path.dirname(path)
    corrections = []
    blocked = []

    for phase in doc.get("phases") or []:
        key = _jq_raw(phase.get("id"))
        directory = _tsv(phase.get("dir"))
        status = _tsv(phase.get("status"))
        # Phase tasks files follow <feature>-phase-<id>-tasks.json, the same
        # convention phase-overlap, execute.md Step 1.7, plan.md Phase 3e and
        # status.md use. Reading a bare tasks.json here made every lookup miss,
        # so reconcile silently reported zero corrections.
        tasks = _read_tasks(
            feature_dir + "/" + directory + "/" + feature + "-phase-" + key + "-tasks.json"
        )
        if tasks is None:
            continue
        truth = ground_truth(tasks)
        if truth == "unknown" or truth == status:
            continue
        row = {"id": jq_numbers(phase.get("id")), "from": status, "to": truth}
        if truth == "planned" and status == "in_progress":
            # A phase a session has already transitioned to in_progress must not be
            # demoted, even though its stories genuinely are all still pending. That
            # is the normal shape of a phase mid-claim: execute.md writes in_progress
            # before any story moves, so the window spans split detection, dependency
            # validation, orphan reset and wave planning -- agent turns, not
            # milliseconds -- and execute.md runs reconcile across the WHOLE roadmap
            # on every claim, so a sibling session is what lands here.
            #
            # The demotion is unrecoverable rather than merely untidy: planned ->
            # completed is not in STATUS_TRANSITIONS, so the owning session would run
            # every story and then hard-fail at Mark Phase Completed, which is one
            # call with no fallback. Reported instead of applied, so the divergence
            # stays visible -- execute.md already prints blocked[] advisorily.
            #
            # Deliberately narrower than "never demote": pending -> planned, issue
            # #102's own target, is a phase nobody has claimed and still self-heals.
            row["reason"] = (
                "phase is in_progress -- demoting to planned would strand its "
                "completion transition, which STATUS_TRANSITIONS does not allow "
                "from planned"
            )
            blocked.append(row)
        elif truth == "completed" and not os.path.isfile(
            feature_dir + "/" + directory + "/handoff.md"
        ):
            row["reason"] = "no handoff.md -- write it with roadmap-write-handoff, then re-run"
            blocked.append(row)
        else:
            corrections.append(row)

    if corrections:
        # Reaching "completed" also releases the claim in the same atomic write,
        # mirroring roadmap-set-status -- otherwise a reconciled phase reads as
        # done while still showing claimed by a dead session.
        for phase in doc.get("phases") or []:
            row = next(
                (c for c in corrections if c["id"] == jq_numbers(phase.get("id"))), None
            )
            if row is None:
                continue
            phase["status"] = row["to"]
            if row["to"] == "completed":
                phase["claim"] = None
        write_doc_atomically(path, doc)

    _emit({"corrections": corrections, "blocked": blocked})
    return 0


_OPS = {
    "judge-phases": op_judge_phases,
    "roadmap-get": op_roadmap_get,
    "roadmap-eligible": op_roadmap_eligible,
    "list-archivable-phases": op_list_archivable_phases,
    "set-status": op_set_status,
    "claim": op_claim,
    "release-claim": op_release_claim,
    "reconcile": op_reconcile,
    "verify-creates": op_verify_creates,
    "validate-contracts": op_validate_contracts,
    "normalize-contracts": op_normalize_contracts,
    "init-validate": op_init_validate,
    "init-write": op_init_write,
    "amend-validate": op_amend_validate,
    "amend-write": op_amend_write,
    "sweep": op_sweep,
    "write-handoff": op_write_handoff,
    "phase-overlap": op_phase_overlap,
}

# The aimi-cli.sh verb each op serves, for the ops whose names differ. Every
# other op is named after its verb already. This exists only so a diagnostic
# names a command the reader can actually run: "Error: sweep:" points at nothing
# a caller has ever typed, and the agent reading that stream needs the verb.
_VERB_FOR_OP = {
    # The one entry whose verb is outside the roadmap-* family: list-archivable
    # is a tasks.json verb that reads one roadmap.json per feature folder.
    "list-archivable-phases": "list-archivable",
    "sweep": "roadmap-sweep",
    "set-status": "roadmap-set-status",
    "claim": "roadmap-claim",
    "release-claim": "roadmap-release-claim",
    "reconcile": "roadmap-reconcile",
    "write-handoff": "roadmap-write-handoff",
    "init-validate": "roadmap-init",
    "init-write": "roadmap-init",
    "amend-validate": "roadmap-amend-phase",
    "amend-write": "roadmap-amend-phase",
}


def main(argv):
    if len(argv) < 2 or argv[1] not in _OPS:
        die("Usage: roadmap.py <" + "|".join(sorted(_OPS)) + "> [flags]", 2)
    try:
        return _OPS[argv[1]](argv[2:])
    except MalformedEntry as malformed:
        # The ONE exception this file catches, and it is caught here rather than
        # at any rule so that no rule can be tempted to carry on without it. One
        # stderr line and a non-zero exit: the verb stops, and it says which
        # entry stopped it. A traceback would say the same thing to a developer
        # and nothing at all to the agent reading this stream.
        die("Error: " + _VERB_FOR_OP.get(argv[1], argv[1]) + ": " + str(malformed))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
