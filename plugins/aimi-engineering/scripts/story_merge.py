#!/usr/bin/env python3
"""story-merge's document logic, ported from aimi-cli.sh.

WHY THIS FILE EXISTS
====================

Same split roadmap.py already draws, for the same reason. aimi-cli.sh keeps the
shell-shaped work -- flag parsing, path confinement, the `--phase-aware`
basename precondition -- and calls here once. This file owns everything from
"read the staging directory" to "the files are on disk", including the locking,
because the PROJECT axis derives its own output paths and bash cannot hold a
lock on a name it has not computed yet.

The reason it moved is narrower than roadmap.py's and worth saying plainly: the
prose sanitizer existed TWICE, once as `_ROADMAP_SANITIZE_JQ` in aimi-cli.sh and
once as Python, and the four call sites keeping the jq copy alive were all in
this family. Porting it retired the jq copy. Both this file and roadmap.py now
import the one rule from sanitize.py.

WHAT IS PRESERVED, AND HOW IT WAS CHECKED
-----------------------------------------

Every rule here was captured from the jq it replaces, case by case, over an
adversarial corpus (legacy mode, both split axes, --foundation, --phase-aware,
--agent-mode) BEFORE the jq was deleted. That recording is
tests/golden_from_jq.json's `story_merge_cases`, and its comment names every
field that differs and why. The differences are all of one kind: jq aborting
mid-expression, where the message was the engine's and the diagnostic the code
was written to print was unreachable.

Two jq behaviours that look like bugs and are reproduced ON PURPOSE, because a
port is not where a defect is fixed:

  * A `dependsOn` naming a story that does not exist is reported as a circular
    dependency, not as a dangling reference. Kahn's algorithm cannot tell the
    two apart, and the bash never tried to.
  * The SIDE axis classifies every story by its own file/title heuristic even
    when every story shares one `.project`. That is what the old monorepo-guard
    fallback did.

The jq's own key ORDER is preserved too, and that is not cosmetic: jq's `+`
appends keys the left side did not have and leaves the rest where they were,
which is exactly what a Python dict does. A story therefore reaches disk with
its authored keys first and `id`, `dependsOn`, `wave`, `status` in the positions
jq put them.
"""

import fcntl
import json
import locale
import math
import os
import random
import re
import shutil
import statistics
import sys
import time

from audit_patches import NOTES_SEPARATOR, AuditRefusal, staged_idx_map
from sanitize import rm_sanitize

# The two caps the jq applied, at the two places it applied them. A title
# reaching a warning is sub-agent-authored; a .project reaching a refusal has
# already failed validation and is therefore unbounded.
TITLE_MAXLEN = 200
PROJECT_MAXLEN = 120

SCHEMA_FILE_PATTERNS = (
    r"schemas/.*\.(ts|js|py|rb)$",
    r"types/.*\.(ts|js)$",
    r"zod/.*\.(ts|js)$",
    r"\.schema\.ts$",
    r"\.types\.ts$",
)
MOCK_AC_PATTERN = r"[Mm]ock.*updated|mock.*sync|[Uu]pdate.*mock|[Mm]ock.*data|[Vv]erify.*mock"
FE_FILE_PATTERNS = (
    r"\.(tsx|jsx)$",
    r"components?/",
    r"pages?/",
    r"frontend/",
    r"ui/",
    r"client/",
)
FE_TEXT_PATTERN = r"\b(UI|Frontend|Component|Page|View|React|Tailwind)\b"

PROJECT_GRAMMAR = r"^[a-zA-Z0-9_][a-zA-Z0-9_./@-]*$"

# `find ... | sort` sorts in the caller's collation, not in byte order, so the
# port asks libc the same question the pipeline did rather than quietly becoming
# byte-ordered on a host whose locale says otherwise.
try:  # pragma: no cover - depends on the host's locale configuration
    locale.setlocale(locale.LC_COLLATE, "")
except locale.Error:
    pass


# ---------------------------------------------------------------------------
# jq's small semantics, reproduced by name so a call site reads like the filter
# ---------------------------------------------------------------------------


def _collate(value):
    try:
        return locale.strxfrm(value)
    except (ValueError, UnicodeError):  # pragma: no cover - pathological names
        return value


def _tostring(value):
    """jq's `tostring`: a string passes through, everything else is compact JSON."""
    if isinstance(value, str):
        return value
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _cat(value):
    """jq's `"a" + null == "a"`: null is the identity for string concatenation."""
    return "" if value is None else value


def _join(sep, items):
    """jq's `join`: null renders as empty, everything else through tostring."""
    return sep.join("" if v is None else _tostring(v) for v in items)


def _pad(number, width):
    """jq's zero-pad, which stops padding once the number is already that wide."""
    return "%0*d" % (width, number)


def _basename(path):
    stripped = path.rstrip("/")
    if stripped == "":
        return "/"
    return stripped.rsplit("/", 1)[-1]


def _dirname(path):
    stripped = path.rstrip("/")
    if "/" not in stripped:
        return "."
    head = stripped.rsplit("/", 1)[0]
    return head if head else "/"


def _strip_extension(base):
    """`${base%.${base##*.}}` -- drop the last dot-suffix, or nothing if there is none."""
    if "." not in base:
        return base
    return base[: -(len(base.rsplit(".", 1)[1]) + 1)]


def _falsy(value):
    """jq's `//` guard: null and false only. 0 and "" are values."""
    return value is None or value is False


def _list(value):
    """`.x // []` where the key may be absent, null, or false."""
    return [] if _falsy(value) else value


def _implementation_files(story):
    implementation = story.get("implementation")
    if _falsy(implementation):
        return []
    return _list(implementation.get("files"))


def _implementation_approach(story):
    implementation = story.get("implementation")
    if _falsy(implementation):
        return None
    return implementation.get("approach")


def _implementation_verify(story):
    implementation = story.get("implementation")
    if _falsy(implementation):
        return None
    return implementation.get("verify")


def die(message, code=1):
    sys.stderr.write(message + "\n")
    sys.exit(code)


def warn_list(header, lines):
    sys.stderr.write(header + "\n")
    for line in lines:
        sys.stderr.write(line + "\n")


def die_list(header, lines, code=1):
    warn_list(header, lines)
    sys.exit(code)


# ---------------------------------------------------------------------------
# Reading the staging directory
# ---------------------------------------------------------------------------
#
# Non-story sidecars written by plan.md Phase 3b have a different shape and would
# be mis-merged as bogus stories, so they are skipped by name. A sidecar is one of
# the three exact names in _SIDECARS, or any file whose basename ENDS IN
# "-outline.json" -- the open arm that keeps future <topic>-outline.json metadata
# files out of the merge.
#
# The suffix is the contract, and it replaced a bare `"outline" in base` substring
# test that was too wide by exactly the names a story author would choose. A story
# file legitimately called 05-n-foundation-outline-entries.json was silently
# dropped by it: six files loaded instead of seven, and because outline:NN is a
# POSITION in the merged array rather than a filename prefix, every later position
# shifted by one and two stories ended up depending on themselves. What the run
# actually printed was "circular dependency detected among stories: US-005,
# US-006" -- a message naming no missing file, no skipped filename and no filter.
# So the word "outline" may appear anywhere in a story's name; only a file whose
# name ENDS that way is claiming to BE an outline.

_SIDECARS = ("outline.json", "metadata.json", "audit-result.json")


def is_sidecar(base):
    if base in _SIDECARS:
        return True
    return base.endswith("-outline.json")


def staging_files(staging_dir):
    paths = []
    for name in os.listdir(staging_dir):
        if not name.endswith(".json"):
            continue
        path = os.path.join(staging_dir, name)
        # `find -type f` without -L: a symlink is type l, never type f.
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        paths.append(path)
    paths.sort(key=_collate)

    kept = []
    for path in paths:
        base = _basename(path)
        if not is_sidecar(base):
            kept.append(path)
            continue
        # Say so when the skipped file carries a story INDEX. read_staging reads
        # that index with this same expression, and it is what makes a skip
        # expensive: only a numbered file occupies a position, so only a numbered
        # file can shift every outline:NN after it and manufacture the cycle that
        # gets reported instead of the skip. The three exact _SIDECARS names and a
        # plain <topic>-outline.json carry no index, hold no position, and are
        # written beside the stories on every ordinary run -- announcing those
        # would be noise on every merge, and would report nothing that can go
        # wrong. So an ordinary merge stays silent on stderr, and the one shape
        # that can silently renumber the array never does.
        if re.match(r"[0-9]", base):
            sys.stderr.write(
                "Note: story-merge: skipped "
                + base
                + ": it carries a story index but its name ends in"
                ' "-outline.json", so it is read as an outline sidecar and'
                " contributes no story. Rename it if it is a story.\n"
            )
    return kept


# ---------------------------------------------------------------------------
# The cross-story audit gate
# ---------------------------------------------------------------------------
#
# A staging directory holding two or more stories is merged only after the
# cross-story audit (/aimi:plan Phase 3d.5) has run, and the proof that it ran
# is audit-result.json carrying `auditedIdx`: the staged idx set the
# apply-audit-patches verb stamped on it. Requiring the proof turns a skipped
# audit from something nobody can see into a refusal. The gate has no flag, no
# environment variable and no --agent-mode exemption: an escape hatch is a
# default-off gate by another name.
#
# The staged set comes from audit_patches.staged_idx_map, the same function the
# verb audited against, so the two cannot disagree on which files are stories.

# Step 5 of /aimi:plan matches on the phrase inside this line, so it is a
# constant rather than a literal at the call site.
AUDIT_FAILED_NOTICE = (
    "Warning: story-merge: the cross-story audit failed for this staging"
    " directory; plan shipped unaudited"
)

_NN_STORY = re.compile(r"[0-9]{2}-.*\.json", re.S)
_AUDIT_STEP = (
    "Run the cross-story audit (/aimi:plan Phase 3d.5, aimi-cli apply-audit-patches"
    " --staging-dir <dir>) and retry."
)
_IDX_LIST_CAP = 50


def _gate_refusal(staging_dir, reason):
    die(
        "Error: story-merge: staging directory "
        + staging_dir
        + " was not cross-story audited ("
        + reason
        + "). "
        + _AUDIT_STEP.replace("<dir>", staging_dir)
    )


def _idx_text(values):
    """An idx list as a refusal prints it: two-digit tokens only, capped.

    The list in audit-result.json was written by a model. Anything that is not
    a two-digit string is shown as '?' and nothing else of the file is echoed.
    """
    shown = [
        v if isinstance(v, str) and re.fullmatch(r"[0-9]{2}", v) else "?"
        for v in values[:_IDX_LIST_CAP]
    ]
    text = "[" + ",".join(shown) + (",..." if len(values) > _IDX_LIST_CAP else "") + "]"
    return text


def require_audit(staging_dir, paths):
    """Refuse a multi-story staging directory that carries no matching audit result.

    Returns the audit result's `status` (None unless it is a string) so the
    caller can announce an audit-failed run once the merge is certain to go on.
    Fewer than two staged files is not gated.
    """
    if len(paths) < 2:
        return None

    extras = [_basename(p) for p in paths if not _NN_STORY.fullmatch(_basename(p))]
    if extras:
        _gate_refusal(
            staging_dir,
            "staged file(s) not named NN-<slug>.json, which the audit never reads: "
            + ", ".join(extras),
        )

    sidecar = os.path.join(staging_dir, "audit-result.json")
    try:
        with open(sidecar, "r", encoding="utf-8") as handle:
            result = json.load(handle)
    except FileNotFoundError:
        _gate_refusal(staging_dir, "audit-result.json is missing")
    except (OSError, ValueError, RecursionError):
        _gate_refusal(staging_dir, "audit-result.json is unreadable or not valid JSON")
    if (
        not isinstance(result, dict)
        or not isinstance(result.get("patches"), list)
        or not isinstance(result.get("unresolved"), list)
        or not isinstance(result.get("auditedIdx"), list)
        or not all(isinstance(v, str) for v in result["auditedIdx"])
    ):
        _gate_refusal(
            staging_dir,
            "audit-result.json has the wrong shape: it needs an object with"
            " patches[], unresolved[] and auditedIdx[] of strings",
        )

    try:
        staged = sorted(staged_idx_map(staging_dir))
    except AuditRefusal as refusal:
        # Two staged files sharing one index cannot be merged at all, and
        # read_staging names the pair right after this gate; a symlink leaving
        # the staging directory is the other cause, and that one stops here.
        indices = [_basename(p)[:2] for p in paths]
        if len(set(indices)) != len(indices):
            return result.get("status") if isinstance(result.get("status"), str) else None
        _gate_refusal(staging_dir, str(refusal))

    audited = sorted(set(result["auditedIdx"]))
    if audited != staged:
        _gate_refusal(
            staging_dir,
            "audited indices "
            + _idx_text(audited)
            + " differ from staged indices "
            + _idx_text(staged),
        )
    status = result.get("status")
    return status if isinstance(status, str) else None


def read_changed_fields(staging_dir):
    """The audit's changed-field record: {staged idx: [field names]}, or {}.

    apply-audit-patches writes `changedFields` into audit-result.json, one entry
    per staged idx that received an applied patch. This is the ONE tolerant
    reader of it: a missing file, a document that does not parse, a missing key
    or a value of the wrong shape all answer {} and say nothing, because the
    only consumer is an advisory smell and a smell must never block a merge.
    require_audit has already refused a malformed result for a multi-story
    directory, so for those this only ever sees a well-formed object.
    """
    try:
        with open(os.path.join(staging_dir, "audit-result.json"), "r", encoding="utf-8") as handle:
            result = json.load(handle)
    except (OSError, ValueError, RecursionError):
        return {}
    changed = result.get("changedFields") if isinstance(result, dict) else None
    if not isinstance(changed, dict):
        return {}
    record = {}
    for idx, fields in changed.items():
        if isinstance(idx, str) and isinstance(fields, list):
            names = [f for f in fields if isinstance(f, str)]
            if names:
                record[idx] = names
    return record


def read_staging(paths):
    """Validate every file, then load every story. Both passes, in that order.

    The order is the contract: a malformed file or a duplicate index is reported
    before anything is loaded, so a refusal never depends on how far the loader
    got.
    """
    seen_indices = {}
    for path in paths:
        base = _basename(path)
        try:
            with open(path, "r", encoding="utf-8") as handle:
                value = json.load(handle)
        except (OSError, ValueError):
            die("Error: story-merge: malformed JSON in file: " + base)
        # `jq -e .` reports a document whose only value is null or false as a
        # failure, so those two count as malformed here as well.
        if _falsy(value):
            die("Error: story-merge: malformed JSON in file: " + base)
        index = re.match(r"[0-9]*", base).group(0)
        if index:
            if index in seen_indices:
                die(
                    "Error: story-merge: duplicate index '"
                    + index
                    + "' in files: "
                    + seen_indices[index]
                    + " and "
                    + base
                )
            seen_indices[index] = base

    merged = []
    for path in paths:
        with open(path, "r", encoding="utf-8") as handle:
            value = json.load(handle)
        entries = value if isinstance(value, list) else [value]
        # The staged filename idx, taken with the same match the duplicate-index
        # check uses: "" for an unnumbered file. outline:NN names THIS, never a
        # position in the merged array, because a skipped expansion leaves a gap
        # in the filenames that a position would silently close.
        staged_idx = re.match(r"[0-9]*", _basename(path)).group(0)
        for entry in entries:
            if not isinstance(entry, dict):
                die(
                    "Error: story-merge: staging file must hold a story object or an "
                    "array of story objects: " + _basename(path)
                )
            entry["_stagedIdx"] = staged_idx
            # Written and removed again rather than never written: an authored
            # _srcIdx was overwritten and deleted by the jq, so a staging file
            # carrying one must not smuggle it into the output either.
            entry["_srcIdx"] = len(merged)
            merged.append(entry)
    return merged


# ---------------------------------------------------------------------------
# Ids, the outline:NN remap, and the dependency graph
# ---------------------------------------------------------------------------


def assign_ids(stories):
    for position, story in enumerate(stories):
        story["id"] = "US-" + _pad(position + 1, 3)


# One pattern for what an outline reference looks like inside story text: the
# literal "outline:" and exactly two digits that are not followed by a third.
# outline:041 and outline:7 are not tokens, so a longer number or a bare digit is
# never half-rewritten, and US-NNN text can never match. Compiled once here so the
# pre-split pass below and the post-split pass in _remap_block cannot disagree.
OUTLINE_TOKEN = re.compile(r"outline:([0-9]{2})(?![0-9])")


def outline_map(stories):
    """{staged filename idx: story id}, the first story staged under each idx.

    outline:NN is the zero-padded idx in the staged FILENAME (NN-slug.json), not a
    position in the merged array: after a skipped expansion the two disagree, and
    resolving by position repoints every later reference at the wrong story. An
    unnumbered file has no idx and is never a target. A story dict carrying no
    _stagedIdx key at all (a list built by hand, as a unit test does) falls back
    to its 1-based list position; read_staging always sets the key, so a real run
    never takes that branch.
    """
    mapping = {}
    for position, story in enumerate(stories):
        idx = story.get("_stagedIdx")
        if idx is None:
            idx = _pad(position + 1, 2)
        if idx == "":
            continue
        mapping.setdefault(idx, story["id"])
    return mapping


def remap_outline_tokens(stories, mapping=None):
    if mapping is None:
        mapping = outline_map(stories)
    for story in stories:
        remapped = []
        for dep in _list(story.get("dependsOn")):
            if isinstance(dep, str) and dep.startswith("outline:"):
                token = dep[len("outline:") :]
                remapped.append(mapping.get(token) or "UNRESOLVED_OUTLINE:" + token)
            else:
                remapped.append(dep)
        story["dependsOn"] = remapped


def _rewrite_story_text(story, sub):
    """Apply `sub(text, path, shell)` to every text field a story reference can sit in.

    The one walk both text passes share -- the outline:NN pass before the split and
    the US-NNN pass after it -- so they cannot disagree on which fields they own.
    Covers implementation.approach, implementation.verify,
    implementation.guardRails[], tasks[], notes, acceptanceCriteria[], gate.prompt
    and gate.options[], in that order. `path` is the field path ("tasks[1]"), and
    `shell` is true for verify and guardRails only: those two are shell text, and a
    pass that adds anything but a bare id to them can break the script.

    A field is assigned only when its text changed, so no key is created and no
    order moves.
    """

    def field(container, key, path, shell=False):
        value = container.get(key)
        if isinstance(value, str):
            rewritten = sub(value, path, shell)
            if rewritten != value:
                container[key] = rewritten

    def entries(container, key, path, shell=False):
        values = container.get(key)
        if not isinstance(values, list):
            return
        for index, value in enumerate(values):
            if isinstance(value, str):
                rewritten = sub(value, path + "[" + str(index) + "]", shell)
                if rewritten != value:
                    values[index] = rewritten

    implementation = story.get("implementation")
    if isinstance(implementation, dict):
        field(implementation, "approach", "implementation.approach")
        field(implementation, "verify", "implementation.verify", True)
        entries(implementation, "guardRails", "implementation.guardRails", True)
    entries(story, "tasks", "tasks")
    field(story, "notes", "notes")
    entries(story, "acceptanceCriteria", "acceptanceCriteria")
    gate = story.get("gate")
    if isinstance(gate, dict):
        field(gate, "prompt", "gate.prompt")
        entries(gate, "options", "gate.options")


def remap_story_text_tokens(stories, mapping):
    """Resolve every OUTLINE_TOKEN in a story's text fields by staged filename idx.

    The fields are those `_rewrite_story_text` walks. verify and guardRails go
    through the SAME helper as the rest, so a guardRails entry that equalled a
    verify segment before the merge still does after it. A field is assigned only
    when its text changed, so no key is created and no order moves, and a second
    application changes nothing (a story id contains no "outline:").

    Returns one "US-NNN <field path>: outline:NN" line per token whose idx has no
    staged file; such a token is left in place here and the caller refuses the
    merge, so it is never dropped and never resolved by position.
    """
    unmapped = []

    for story in stories:
        story_id = story["id"]

        def sub(text, path, shell, story_id=story_id):
            def replace(match):
                target = mapping.get(match.group(1))
                if target is None:
                    unmapped.append(story_id + " " + path + ": " + match.group(0))
                    return match.group(0)
                return target

            return OUTLINE_TOKEN.sub(replace, text)

        _rewrite_story_text(story, sub)
    return unmapped


def unresolved_outline_refs(stories):
    lines = []
    for story in stories:
        for dep in _list(story.get("dependsOn")):
            if isinstance(dep, str) and dep.startswith("UNRESOLVED_OUTLINE:"):
                lines.append(story["id"] + ": " + dep)
    return lines


def _group_label(key):
    """A normalized project group as a message names it.

    group_key() answers None for the untagged group, which has no path to
    print; every message that names a group goes through here so the two
    spellings cannot drift.
    """
    return '"' + key + '"' if key else "(untagged)"


def _die_each(lines):
    """One complete message per violator, then exit 1.

    Batched the way resolve_axis batches, with one deliberate difference: there
    is NO header line. A single violator must print exactly the one line the
    pre-batch implementation printed -- golden's fundacao-inexistente and
    fundacao-dependson-nao-vazio are the frozen recording of that wording -- and
    a header would prepend a second line to it.
    """
    for line in lines:
        sys.stderr.write(line + "\n")
    sys.exit(1)


def inject_foundation(stories, foundation_values, mapping=None):
    """--foundation NN | <project>:NN, repeatable: one foundation PER project group.

    Each accepted foundation gains an edge from every OTHER story sharing its
    own group_key(.project) -- never from a story in a different normalized
    project group. A group no value names is left alone: a normal, silent
    outcome, not a partial failure, whether it simply has no foundation story or
    its own Foundation Gate resolved Skip.

    The qualifier is a CHECKSUM, never a second source of truth. Routing is
    always computed from the resolved story's own .project via group_key; the
    stated project is only ever compared against that, and a mismatch refuses
    the merge. That comparison is the one thing in the pipeline that catches
    plan.md's own per-project bookkeeping disagreeing with what a staging file
    actually says.

    A bare value is accepted whenever it is the SOLE occurrence, whatever
    project it resolves to -- golden's proj-fundacao-edge is a lone bare index
    resolving to a tagged, non-root project, so a bare-means-root rule would be
    wrong. Two or more values require every one of them to be qualified: with
    two bare values there is no way to say which project each is for.

    The SIDE axis and legacy mode need no special case here and have none:
    group_key(None) is one value for every untagged story, so "inject only
    within your own group" reduces to "inject into every other story" whenever
    every story shares one group -- resolve_axis's own SIDE-axis boundary.

    Cycle-safe by construction -- every accepted foundation's own dependsOn is
    asserted empty first and injection only ever points toward one -- but the
    Kahn check below still runs unmodified.

    Returns every accepted foundation id, across every group, deduplicated and
    in first-occurrence order. write_project_split needs the WHOLE set, not one
    group's: a single id cannot express "this dropped edge targets some group's
    foundation" once there can be many.
    """
    values = list(foundation_values)

    # Gate 0 -- arity, before any index is resolved. Counted over the RAW
    # occurrences, so two identical bare values are refused too: the question
    # ("which project is the bare one for?") is asked of the flag surface, not
    # of what the values happen to point at.
    if len(values) > 1:
        bare = [v for v in values if ":" not in v]
        if bare:
            _die_each(
                [
                    "Error: story-merge: --foundation "
                    + v
                    + " must be qualified as <project>:NN when more than one"
                    " --foundation is given"
                    for v in bare
                ]
            )

    # An exact repeat is idempotent rather than a collision. First occurrence
    # wins the ordering.
    parsed = []
    for raw in list(dict.fromkeys(values)):
        head, sep, tail = raw.rpartition(":")
        # A .project cannot contain ':' under PROJECT_GRAMMAR, so the LAST colon
        # is unambiguously the separator.
        parsed.append((raw, tail if sep else raw, head if sep else None))

    if mapping is None:
        mapping = outline_map(stories)

    # Gate 1 -- indices resolving to nothing. Byte-identical to the pre-batch
    # single message when exactly one value is at fault.
    missing = [
        "Error: story-merge: --foundation " + idx + " not present among staging files"
        for _, idx, _ in parsed
        if not mapping.get(idx)
    ]
    if missing:
        _die_each(missing)

    owned = {}
    for story in stories:
        owned.setdefault(story.get("id"), story)
    resolved = [(raw, mapping[idx], stated) for raw, idx, stated in parsed]

    def _actual(story_id):
        return group_key(owned.get(story_id, {}).get("project"))

    # Gate 2 -- the checksum, QUALIFIED values only. A bare value carries no
    # stated project and is exempt by definition, which is exactly what keeps a
    # lone bare index valid for any project, non-root included.
    mismatched = [
        "Error: story-merge: --foundation "
        + raw
        + ": story "
        + story_id
        + " belongs to project "
        + _group_label(_actual(story_id))
        + ", not "
        + _group_label(group_key(stated))
        for raw, story_id, stated in resolved
        if stated is not None and group_key(stated) != _actual(story_id)
    ]
    if mismatched:
        _die_each(mismatched)

    # Gate 3 -- a foundation carrying dependencies of its own. Byte-identical to
    # the pre-batch single message when exactly one value is at fault. A value
    # naming an id no story owns is not a violation here, exactly as before.
    nonempty = [
        "Error: story-merge: foundation story " + story_id + " has non-empty dependsOn"
        for _, story_id, _ in resolved
        if story_id in owned and _list(owned[story_id].get("dependsOn")) != []
    ]
    if nonempty:
        _die_each(nonempty)

    # Gate 4 -- two foundations landing in one group. Necessarily both
    # qualified, since Gate 0 already refused a bare value alongside another.
    # New behaviour, so it carries no byte-identity constraint and uses the
    # ordinary header-plus-lines shape.
    groups = {}
    for _, story_id, _ in resolved:
        ids = groups.setdefault(_actual(story_id), [])
        if story_id not in ids:
            ids.append(story_id)
    collisions = [
        "  " + _join(" and ", ids) + " both resolve to project " + _group_label(key)
        for key, ids in groups.items()
        if len(ids) > 1
    ]
    if collisions:
        die_list(
            "Error: story-merge: --foundation names more than one foundation story in"
            " the same project group; no files were written:",
            collisions,
        )

    # Injection, once every gate has passed. A group with no accepted foundation
    # is skipped silently.
    foundation_of = {key: ids[0] for key, ids in groups.items()}
    for story in stories:
        foundation_id = foundation_of.get(group_key(story.get("project")))
        if foundation_id is None or story.get("id") == foundation_id:
            continue
        deps = _list(story.get("dependsOn"))
        story["dependsOn"] = deps if foundation_id in deps else deps + [foundation_id]

    return list(dict.fromkeys(story_id for _, story_id, _ in resolved))


def cycle_stories(stories):
    """Kahn's algorithm, one pass per story, exactly as the jq ran it.

    A dependsOn naming no story keeps that story's in-degree above zero forever,
    so it is reported here as part of a cycle. That is what the jq did.
    """
    in_degree = {}
    adjacency = {}
    for story in stories:
        in_degree[story["id"]] = len(_list(story.get("dependsOn")))
    for story in stories:
        for dep in _list(story.get("dependsOn")):
            adjacency.setdefault(dep, []).append(story["id"])

    queue = [s["id"] for s in stories if in_degree.get(s["id"], 0) == 0]
    degree = dict(in_degree)
    visited = []
    for _ in range(len(stories)):
        if not queue:
            break
        node = queue[0]
        neighbors = adjacency.get(node, [])
        for neighbor in neighbors:
            degree[neighbor] = degree.get(neighbor, 1) - 1
        queue = queue[1:] + [n for n in neighbors if degree.get(n, 0) == 0]
        visited.append(node)

    if len(visited) == len(stories):
        return []
    return [s["id"] for s in stories if s["id"] not in visited]


def compute_waves(stories):
    """Roots are wave 1; everyone else is max(dependency waves) + 1.

    Each pass reads the waves as they stood when the pass began, never the
    partially updated ones -- the jq built a new array from `$current` every
    iteration and this reproduces that.
    """
    for story in stories:
        story["wave"] = 1 if _list(story.get("dependsOn")) == [] else 0
    for _ in range(len(stories)):
        current = [(s["id"], s["wave"]) for s in stories]
        updated = []
        for story in stories:
            if story["wave"] > 0:
                updated.append(story["wave"])
                continue
            dep_waves = []
            for dep in _list(story.get("dependsOn")):
                dep_waves += [wave for (sid, wave) in current if sid == dep]
            if not dep_waves:
                dep_waves = [0]
            if all(wave > 0 for wave in dep_waves):
                updated.append(max(dep_waves) + 1)
            else:
                updated.append(story["wave"])
        for story, wave in zip(stories, updated):
            story["wave"] = wave


# ---------------------------------------------------------------------------
# Rule 22: mock-sync AC routing
# ---------------------------------------------------------------------------


def _story_text(story):
    return _join(" ", [story.get("title"), _cat(story.get("description"))] + _list(story.get("acceptanceCriteria")))


def _scan_lines(text, pattern):
    """`jq -rR '[scan(...)]'`, whose framing is per LINE, over a captured string."""
    if text == "":
        return []
    found = []
    for line in text.split("\n"):
        found += re.findall(pattern, line)
    return found


def schema_story_ids(stories):
    ids = []
    for story in stories:
        files = _implementation_files(story)
        if any(
            isinstance(f, str) and any(re.search(p, f) for p in SCHEMA_FILE_PATTERNS)
            for f in files
        ):
            ids.append(story["id"])
    return ids


def _mock_acs(story):
    return [ac for ac in _list(story.get("acceptanceCriteria")) if re.search(MOCK_AC_PATTERN, ac)]


def route_mock_sync_acs(stories):
    """Move a schema story's mock-sync ACs onto the stories that consume its fields."""
    for schema_id in schema_story_ids(stories):
        schema = next((s for s in stories if s["id"] == schema_id), None)
        if schema is None or not _mock_acs(schema):
            continue

        # Step 1: camelCase / snake_case field names out of the schema story's text.
        fields = [
            name
            for name in _scan_lines(
                _story_text(schema),
                r"[a-z][a-zA-Z0-9]*[A-Z][a-zA-Z0-9]*|[a-z][a-z0-9_]*_[a-z][a-z0-9_]*",
            )
            if len(name) > 3
        ]
        # Step 2: consumers are the stories whose own text names one of them.
        consumers = []
        if fields:
            for story in stories:
                if story["id"] == schema_id:
                    continue
                text = _story_text(story)
                if any(re.search(field, text) for field in fields):
                    consumers.append(story["id"])
        # Step 3: CamelCase entity-name fuzzy fallback, on the title alone.
        if not consumers:
            words = _scan_lines(_cat(schema.get("title")), r"[A-Z][a-z]+")
            if words:
                for story in stories:
                    if story["id"] == schema_id:
                        continue
                    text = _story_text(story)
                    if any(re.search(word, text, re.I) for word in words):
                        consumers.append(story["id"])
        if not consumers:
            continue

        moved = _mock_acs(schema)
        for story in stories:
            if story["id"] == schema_id:
                story["acceptanceCriteria"] = [
                    ac
                    for ac in _list(story.get("acceptanceCriteria"))
                    if not re.search(MOCK_AC_PATTERN, ac)
                ]
            elif story["id"] in consumers and not _mock_acs(story):
                story["acceptanceCriteria"] = _list(story.get("acceptanceCriteria")) + moved


# ---------------------------------------------------------------------------
# The Phase 3.1 / 4.1 / 4.2 sweeps
# ---------------------------------------------------------------------------


def _has_inventory(story):
    inventory = story.get("referenceInventory")
    return isinstance(inventory, list) and len(inventory) > 0


def inventory_violations(stories):
    """Phase 3.1: every referenceInventory row must carry one of three verdicts."""
    out = []
    for story in stories:
        if not _has_inventory(story):
            continue
        unverdicted = [
            row
            for row in story["referenceInventory"]
            if row.get("verdict") is None
            or row.get("verdict") == ""
            or not re.search(r"^(encoded|excluded|deferred)$", row["verdict"])
        ]
        if unverdicted:
            out.append(
                "  Story "
                + story["id"]
                + ": "
                + str(len(unverdicted))
                + " unverdicted inventory row(s): "
                + _join(
                    ", ",
                    [
                        "unknown" if _falsy(row.get("element")) else row.get("element")
                        for row in unverdicted
                    ],
                )
            )
    return out


def coverage_violations(stories):
    """Phase 4.1: ac_anchors must reach floor(proto_elements * 0.6)."""
    out = []
    for story in stories:
        if not _has_inventory(story):
            continue
        proto_elements = len(story["referenceInventory"])
        anchors = story.get("ac_anchors")
        if _falsy(anchors):
            anchors = len(_list(story.get("acceptanceCriteria")))
        threshold = math.floor(proto_elements * 0.6)
        if anchors < threshold:
            out.append(
                "  Story "
                + story["id"]
                + ": ac_anchors="
                + _tostring(anchors)
                + " < floor("
                + _tostring(proto_elements)
                + " * 0.6)="
                + _tostring(threshold)
            )
    return out


def orphan_symbol_findings(stories):
    """Phase 4.2: a story whose every extracted symbol appears in no sibling's prose.

    Heuristic and warning-only. Skipped for a single-story merge, where every
    symbol would be trivially unreferenced.
    """
    if len(stories) < 2:
        return []
    findings = []
    for story in stories:
        approach = _implementation_approach(story)
        if not isinstance(approach, str) or approach == "":
            continue
        symbols = [
            symbol
            for symbol in re.findall(r"[A-Za-z][A-Za-z0-9_]*", approach)
            if len(symbol) >= 4
            and (
                re.search(r"^[a-z].*[A-Z]", symbol)
                or re.search(r"^[A-Z][a-z]+[A-Z]", symbol)
                or re.search(r"_[a-z]", symbol)
            )
        ]
        if not symbols:
            continue
        corpus = _join(
            " ",
            [
                _join(
                    " ",
                    [
                        _cat(other.get("title")),
                        _cat(other.get("description")),
                        _join(" ", _list(other.get("acceptanceCriteria"))),
                        _cat(_implementation_approach(other)),
                        _join(" ", _implementation_files(other)),
                    ],
                )
                for other in stories
                if other["id"] != story["id"]
            ],
        )
        # Word-boundary match: `userId` is NOT treated as referenced by an
        # unrelated `userIdentifier`. Symbols are [A-Za-z0-9_]+, so no regex
        # metacharacter can reach the search.
        unreferenced = [s for s in symbols if not re.search(r"\b" + s + r"\b", corpus)]
        if len(unreferenced) == len(symbols):
            findings.append({"id": story["id"], "symbols": symbols})
    return findings


def _read_repo_text(root, name):
    try:
        with open(os.path.join(root, name), "r", encoding="utf-8") as handle:
            return handle.read()
    except OSError:
        return None


_MAKEFILE_TARGET_RE = re.compile(r"(?m)^([A-Za-z0-9][A-Za-z0-9_.-]*)\s*:(?!=)")
_BACKTICK_SPAN_RE = re.compile(r"`([^`\n]+)`")
_FENCED_COMMAND_BLOCK_RE = re.compile(r"(?ms)^```(?:bash|sh)[ \t]*\n(.*?)^```[ \t]*$")


def _fenced_block_commands(text):
    """Commands from ```bash / ```sh fenced blocks in `text` -- the sixth
    repo_command_vocabulary source, for a repo (like this one) whose tooling
    is documented in prose rather than exposed through a manifest.

    Conservative, line by line, inside a matched block only: cut each line's
    comment from its first '#', strip the rest, then drop an empty line, a
    line that already starts with '#', a line whose first token is an
    assignment (`FOO=bar`) or is `cd`/`export`. What survives is command text.
    A prose block that fences no command contributes nothing, and a
    backtick-quoted identifier elsewhere in a document (an acceptance
    criterion, say) never reaches this function at all -- it only ever reads
    the two whole files repo_command_vocabulary hands it.
    """
    commands = set()
    for block in _FENCED_COMMAND_BLOCK_RE.findall(text):
        for line in block.splitlines():
            candidate = line.split("#", 1)[0].strip()
            if not candidate:
                continue
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", candidate):
                continue
            if candidate.split(None, 1)[0] in ("cd", "export"):
                continue
            commands.add(candidate)
    return commands


def repo_command_vocabulary(root):
    """The commands `root`'s own tooling actually exposes: package.json
    `scripts` keys, Makefile targets, the canonical runner a Cargo.toml,
    pyproject.toml or go.mod implies, and the commands CLAUDE.md/AGENTS.md
    document in fenced ```bash/```sh blocks (see _fenced_block_commands).
    DERIVED from the repository, never a fixed runner list -- a fixed list is
    wrong on the next repository, and wrong in the direction that
    manufactures false confidence (see verify_coverage_findings below).

    Returns None -- never an empty set -- when none of those seven files
    exists at `root`. None is the CANNOT-DETERMINE-THE-VOCABULARY state; an
    empty set would claim "this repo's tooling runs nothing," which is a
    finding about the repo, not an admission this function found nothing to
    read.
    """
    vocabulary = set()
    found_a_source = False

    package_json = _read_repo_text(root, "package.json")
    if package_json is not None:
        found_a_source = True
        try:
            scripts = json.loads(package_json).get("scripts")
        except (ValueError, AttributeError):
            scripts = None
        if isinstance(scripts, dict):
            for name in scripts:
                if isinstance(name, str) and name != "":
                    vocabulary.add("npm run " + name)
            if "test" in scripts:
                vocabulary.add("npm test")

    makefile = _read_repo_text(root, "Makefile")
    if makefile is not None:
        found_a_source = True
        for match in _MAKEFILE_TARGET_RE.finditer(makefile):
            target = match.group(1)
            if target != ".PHONY":
                vocabulary.add("make " + target)

    if _read_repo_text(root, "Cargo.toml") is not None:
        found_a_source = True
        vocabulary |= {"cargo test", "cargo build", "cargo check"}

    if _read_repo_text(root, "pyproject.toml") is not None:
        found_a_source = True
        vocabulary |= {"pytest", "python -m pytest", "python3 -m pytest"}

    if _read_repo_text(root, "go.mod") is not None:
        found_a_source = True
        vocabulary |= {"go test", "go build", "go vet"}

    for name in ("CLAUDE.md", "AGENTS.md"):
        prose = _read_repo_text(root, name)
        if prose is not None:
            found_a_source = True
            vocabulary |= _fenced_block_commands(prose)

    return vocabulary if found_a_source else None


def _cited_commands(text):
    """Backtick-delimited spans in `text` -- the generic, vocabulary-independent
    signal that prose NAMES a specific command, as opposed to describing intent
    ("tests pass" vs "`npm test` passes"). Used on the acceptanceCriteria side
    only: a plain substring search for a vocabulary term would also fire on
    "npm test" spelled out inside an unrelated sentence.
    """
    return {span.strip() for span in _BACKTICK_SPAN_RE.findall(text) if span.strip()}


_NOT_EVALUATED_MAX_STORIES = 5
_NOT_EVALUATED_MAX_SPANS = 3

_FILE_EXTENSION_RE = re.compile(r"^[^\s]*\.[A-Za-z]{1,8}$")
_DOTTED_KEY_RE = re.compile(
    r"^[A-Za-z_][A-Za-z0-9_]*(?:\[\d*\])?(?:\.[A-Za-z_][A-Za-z0-9_]*(?:\[\d*\])?)+$"
)
_QUOTED_LITERAL_RE = re.compile(r"^(?:\"[^\"]*\"|'[^']*')$")


def _shape_flags_alone(span):
    tokens = span.split()
    return bool(tokens) and all(t.startswith("-") for t in tokens)


def _shape_path(span):
    if len(span.split()) != 1 or "/" not in span:
        return False
    return not (span.startswith("./") or span.startswith("-"))


def _shape_file_extension(span):
    # A leading './' can be an executable, same carve-out as the path shape.
    return (
        len(span.split()) == 1
        and not span.startswith("./")
        and _FILE_EXTENSION_RE.match(span) is not None
    )


def _shape_dotted_key(span):
    return _DOTTED_KEY_RE.match(span) is not None


def _shape_no_shell_word(span):
    return re.search(r"[A-Za-z]", span) is None or _QUOTED_LITERAL_RE.match(span) is not None


_NON_COMMAND_SHAPES = (
    ("flags", _shape_flags_alone),
    ("path", _shape_path),
    ("file-extension", _shape_file_extension),
    ("dotted-key", _shape_dotted_key),
    ("no-shell-word", _shape_no_shell_word),
)


def _non_command_shape(span):
    """Name of the first shape in _NON_COMMAND_SHAPES `span` has, else None.

    A span that is not a command at all (a flag list, a path, a file name, a
    JSON key, a number or quoted literal). A bare identifier or a multi-word
    span (`npm test`, `pytest`, `./gradlew`) matches no shape.
    """
    for name, predicate in _NON_COMMAND_SHAPES:
        if predicate(span):
            return name
    return None


def _classify_not_evaluated_spans(story, cited):
    """Partition `cited` into {nonCommand, introduced, unrecognised}, each a
    sorted list. Precedence: nonCommand, then introduced, then unrecognised.

    `introduced`: the span appears as a whole term (no word character or '-'
    on either side) in the story's own title, implementation.approach or an
    implementation.files entry, case-insensitively. A heuristic that changes a
    label only -- the span stays not evaluated whichever class it lands in.
    """
    implementation = story.get("implementation")
    haystack_parts = [story.get("title"), _implementation_approach(story)]
    haystack_parts.extend(_implementation_files(story) if not _falsy(implementation) else [])
    haystack = "\n".join(p for p in haystack_parts if isinstance(p, str))
    classes = {"nonCommand": [], "introduced": [], "unrecognised": []}
    for span in sorted(cited):
        if _non_command_shape(span) is not None:
            classes["nonCommand"].append(span)
        elif re.search(
            r"(?<![\w-])" + re.escape(span) + r"(?![\w-])", haystack, re.IGNORECASE
        ):
            classes["introduced"].append(span)
        else:
            classes["unrecognised"].append(span)
    return classes


_SPAN_CLASS_LABELS = (
    ("unrecognised", "[unrecognised]"),
    ("introduced", "[introduced]"),
    ("nonCommand", "[non-command]"),
)
_NOT_EVALUATED_PREFIX = "cites nothing in its project's derived vocabulary: "


def _format_not_evaluated_line(entries):
    """The capped body of the NOT EVALUATED line (everything between the
    'for ' and the closing sentence). Stories: unrecognised-bearing first, then
    only nonCommand/introduced, then reason-(a) entries, stable within each
    group; at most _NOT_EVALUATED_MAX_STORIES shown, then '+N more stories'.
    Spans per story: unrecognised, introduced, nonCommand, each sorted and
    labelled, at most _NOT_EVALUATED_MAX_SPANS, then '+N more spans (class
    counts)'.
    """

    def priority(entry):
        classes = entry.get("spanClasses")
        if classes is None:
            return 2
        return 0 if classes["unrecognised"] else 1

    ordered = sorted(entries, key=priority)
    shown = ordered[:_NOT_EVALUATED_MAX_STORIES]
    parts = []
    for entry in shown:
        classes = entry.get("spanClasses")
        if classes is None:
            parts.append(entry["id"] + " (" + entry["reason"] + ")")
            continue
        flat = [
            (span, label)
            for key, label in _SPAN_CLASS_LABELS
            for span in classes[key]
        ]
        visible = flat[:_NOT_EVALUATED_MAX_SPANS]
        text = _join(", ", [span + " " + label for span, label in visible])
        omitted = flat[_NOT_EVALUATED_MAX_SPANS:]
        if omitted:
            counts = _join(
                ", ",
                [
                    str(n) + " " + label.strip("[]")
                    for key, label in _SPAN_CLASS_LABELS
                    for n in [sum(1 for _, lab in omitted if lab == label)]
                    if n
                ],
            )
            text += ", +" + str(len(omitted)) + " more spans (" + counts + ")"
        parts.append(entry["id"] + " (" + _NOT_EVALUATED_PREFIX + text + ")")
    line = _join("; ", parts)
    hidden = len(ordered) - len(shown)
    if hidden:
        line += "; +" + str(hidden) + " more stories"
    return line


_SCRIPT_EXPANSION_DEPTH_CAP = 5
_SCRIPT_NAME_CHARS = r"A-Za-z0-9_:.@/\-"
_RUNNER_INVOCATION_RE = re.compile(
    r"(?<![" + _SCRIPT_NAME_CHARS + r"])(?:npm|bun|pnpm|yarn)[ \t]+(?:"
    r"(?:run-script|run)[ \t]+(?:-{1,2}[A-Za-z0-9][A-Za-z0-9_-]*(?:=\S+)?[ \t]+)*"
    r"(?P<name>[" + _SCRIPT_NAME_CHARS + r"]+)"
    r"|(?P<test>test)(?![" + _SCRIPT_NAME_CHARS + r"])"
    r")"
)


def _runner_script_names(text):
    """Script names `text` invokes through a package manager, in order:
    `npm|bun|pnpm|yarn run <name>`, `npm run-script <name>` and `<pm> test`
    (script `test`). The name is a whole token, so `check:foo` and
    `check:foo-extra` are different names."""
    names = []
    for match in _RUNNER_INVOCATION_RE.finditer(text):
        names.append(match.group("name") or "test")
    return names


def _package_scripts(root):
    """`root`'s package.json `scripts` object, or None when the file is
    missing, unreadable, malformed or carries no scripts object."""
    text = _read_repo_text(root, "package.json")
    if text is None:
        return None
    try:
        scripts = json.loads(text).get("scripts")
    except (ValueError, AttributeError):
        return None
    return scripts if isinstance(scripts, dict) else None


def _expand_script_runs(text, scripts):
    """Follow package-manager script runs in `text` through `scripts`,
    transitively. Returns (reached_names, bodies, problems): every script name
    invoked anywhere along the chain, the body text of each script that was
    expanded, and one line per reason the expansion is incomplete (empty
    list == complete). A visited set stops re-expansion; a script already on
    the current path is a cycle; a chain deeper than the depth cap, a script
    absent from `scripts`, or `scripts` None are all incomplete."""
    reached = set()
    bodies = []
    problems = []
    expanded = set()

    def walk(body, path):
        for name in _runner_script_names(body):
            reached.add(name)
            if name in path:
                problems.append("cycle: " + " -> ".join(path + (name,)))
                continue
            if name in expanded:
                continue
            if scripts is None:
                problems.append(
                    "script '" + name + "' cannot be read: package.json is missing,"
                    " unreadable or has no scripts"
                )
                continue
            if name not in scripts or not isinstance(scripts[name], str):
                problems.append("script '" + name + "' is not defined in package.json")
                continue
            if len(path) + 1 > _SCRIPT_EXPANSION_DEPTH_CAP:
                problems.append(
                    "chain deeper than "
                    + str(_SCRIPT_EXPANSION_DEPTH_CAP)
                    + " at '"
                    + name
                    + "': "
                    + " -> ".join(path + (name,))
                )
                continue
            expanded.add(name)
            bodies.append(scripts[name])
            walk(scripts[name], path + (name,))

    walk(text, ())
    return reached, bodies, problems


def _token_in_text(command, text):
    """`command` as a whole token of `text`, case-insensitive -- never a
    substring of a longer token."""
    pattern = (
        r"(?<![" + _SCRIPT_NAME_CHARS + r"])"
        + re.escape(command.lower())
        + r"(?![" + _SCRIPT_NAME_CHARS + r"])"
    )
    return re.search(pattern, text.lower()) is not None


def verify_coverage_findings(stories, project_root):
    """Phase 4.3: a story whose acceptanceCriteria cite (in backticks) a
    repo-vocabulary command that implementation.verify's own text never runs.

    Mirrors orphan_symbol_findings' shape and pipeline position (~:732)
    rather than a parallel mechanism: per-story, warning-only, folded into
    the same metadata.smellWarnings sweep by main().

    The vocabulary is looked up per story's OWN project group (group_key),
    rooted under project_root -- the same routing key resolve_axis and the
    PROJECT writer already group by -- so a multi-repo plan checks each story
    against its own repository's tooling, never a sibling's.

    Returns (findings, undetermined_story_ids, clean_story_ids,
    not_evaluated) -- FOUR results, and the four lists PARTITION `stories`:
    every story lands in exactly one, so the four lengths sum to len(stories)
    and the union of their ids is the input's own id set. That partition is
    the contract this function exists to hold: the count of stories judged
    equals the count of stories that entered.

    A story that cites something lands in one of the first three: `findings`
    when a cited command is missing from verify, `undetermined_story_ids` when
    its group's vocabulary could not be derived at all, `clean_story_ids` when
    every cited command was found. The second list is the CANNOT-DETERMINE
    state constraint 3 requires kept distinct from CHECKED-AND-CLEAN (the
    third list): folding an undetermined story into "nothing to report" would
    be exactly the false confidence this split exists to prevent.

    `not_evaluated` is a FOURTH result and never a collapse of one of the
    three. It holds `{id, reason}` for the two states in which this function
    took no measurement at all: (a) the story cites no command in backticks
    anywhere in its acceptanceCriteria, so there was nothing to evaluate; and
    (b) the story DOES cite, but no citation is in its own project's derived
    vocabulary, so nothing it named could be checked. Both used to leave by a
    bare `continue`, which is how a story could enter the merge and receive no
    verdict from any of the three lists -- the defect this fourth list closes.

    Why (a) and (b) are not folded into `undetermined_story_ids`, which is the
    tempting one-line version: that list's printed message asserts a concrete
    cause -- no package.json, Makefile, Cargo.toml, pyproject.toml, go.mod,
    CLAUDE.md or AGENTS.md exists for that story's project. For a story whose
    group vocabulary was derived without trouble that sentence is FALSE, so
    folding either state in would trade a silence for a lie, which is a
    regression of the same family as the one this list fixes.

    Every reason-(b) entry also carries `spanClasses`, ADDED beside `id` and
    `reason` (both unchanged): {nonCommand, introduced, unrecognised}, three
    sorted lists partitioning the cited spans. Precedence is nonCommand
    (_non_command_shape), then introduced (whole term in the story's title,
    approach or files), then unrecognised. Reason-(a) entries carry no
    spanClasses. The NOT EVALUATED line caps what it prints
    (_NOT_EVALUATED_MAX_STORIES / _NOT_EVALUATED_MAX_SPANS), listing
    unrecognised spans first, then introduced, then non-command; the full
    classified data stays in this return value.

    A verify that invokes a package-manager script (`bun run verify`,
    `npm test`, ...) is expanded through the story's OWN project group's
    package.json `scripts` (see _expand_script_runs): a cited command is
    covered when the chain reaches it as a whole token. When a cited command
    is not found AND the expansion was incomplete (a cycle, a chain deeper
    than _SCRIPT_EXPANSION_DEPTH_CAP, a script absent from package.json, or
    an unreadable package.json), the story lands in `not_evaluated` with a
    reason naming the unexpandable chain and no `spanClasses` -- never in
    `findings`, since the chain that would have covered it could not be
    followed, and never in `clean_story_ids`. A verify that invokes no
    package manager is judged exactly as before.
    """
    vocabulary_cache = {}
    scripts_cache = {}
    findings = []
    undetermined_story_ids = []
    clean_story_ids = []
    not_evaluated = []

    for story in stories:
        criteria_text = _join(" ", _list(story.get("acceptanceCriteria")))
        cited = _cited_commands(criteria_text)
        if not cited:
            # Reason (a): nothing was named, so nothing could be measured.
            # Recorded rather than dropped -- a story that leaves here still
            # entered the merge and still owes the report a verdict.
            not_evaluated.append(
                {
                    "id": story["id"],
                    "reason": "no acceptance criterion cites a command in backticks",
                }
            )
            continue

        group = group_key(story.get("project"))
        if group not in vocabulary_cache:
            group_root = project_root if group is None else os.path.join(project_root, group)
            vocabulary_cache[group] = repo_command_vocabulary(group_root)
        vocabulary = vocabulary_cache[group]

        if vocabulary is None:
            undetermined_story_ids.append(story["id"])
            continue

        if group not in scripts_cache:
            group_root = project_root if group is None else os.path.join(project_root, group)
            scripts_cache[group] = _package_scripts(group_root)
        scripts = scripts_cache[group]

        lowered_vocabulary = {v.lower() for v in vocabulary}

        def _asserted(cmd):
            if cmd.lower() in lowered_vocabulary:
                return True
            names = _runner_script_names(cmd)
            return bool(names) and scripts is not None and all(n in scripts for n in names)

        asserted = sorted(cmd for cmd in cited if _asserted(cmd))
        if not asserted:
            # Reason (b), the more dangerous of the two: the story NAMED
            # something and the gate walked past it. `asserted` is empty
            # exactly when no citation is in the vocabulary, so every span in
            # `cited` is unrecognised -- name them, or the reader cannot tell
            # a story citing a file path from one citing a real command this
            # repository's tooling simply does not expose.
            not_evaluated.append(
                {
                    "id": story["id"],
                    "reason": "cites nothing in its project's derived vocabulary: "
                    + _join(", ", sorted(cited)),
                    "spanClasses": _classify_not_evaluated_spans(story, cited),
                }
            )
            continue

        verify_raw = _cat(_implementation_verify(story))
        verify_text = verify_raw.lower()
        reached, bodies, problems = _expand_script_runs(verify_raw, scripts)

        def _covered(cmd):
            if cmd.lower() in verify_text:
                return True
            names = _runner_script_names(cmd)
            if names:
                return all(n in reached for n in names)
            return any(_token_in_text(cmd, body) for body in bodies)

        missing = [cmd for cmd in asserted if not _covered(cmd)]
        if missing and problems:
            not_evaluated.append(
                {
                    "id": story["id"],
                    "reason": "verify script expansion is incomplete, so "
                    + _join(", ", missing)
                    + " could not be confirmed: "
                    + _join("; ", problems),
                }
            )
        elif missing:
            findings.append({"id": story["id"], "commands": missing})
        else:
            clean_story_ids.append(story["id"])

    return findings, undetermined_story_ids, clean_story_ids, not_evaluated


# ---------------------------------------------------------------------------
# .project: the one classification both the axis and the grouping go through
# ---------------------------------------------------------------------------
#
# Grouping/counting/classification ONLY -- neither the normalized nor the
# classified form is ever written back onto a story; .project must survive
# verbatim into the output files.


def norm_project(value):
    """Trim, drop one trailing slash, and read blank (or absent) as null."""
    if value is None:
        return None
    trimmed = re.sub(r"^\s+|\s+$", "", value)
    if trimmed == "":
        return None
    if trimmed.endswith("/"):
        return trimmed[:-1]
    return trimmed


def project_state(value):
    """"untagged" / "tagged" / "invalid", judged on the RAW value.

    Deliberately not on the trimmed one: " apps/web " is invalid rather than
    being quietly trimmed into a value whose raw form is what a downstream
    command would cd into. Only a fully blank string counts as untagged.
    """
    if value is None:
        return "untagged"
    if not isinstance(value, str):
        return "invalid"
    if re.sub(r"^\s+|\s+$", "", value) == "":
        return "untagged"
    if value == ".":
        return "tagged"
    if (
        re.search(PROJECT_GRAMMAR, value)
        and ".." not in value.split("/")
        and "//" not in value
    ):
        return "tagged"
    return "invalid"


def group_key(value):
    """The single routing key. The axis decision and the grouping pass share it."""
    return norm_project(value)


# ---------------------------------------------------------------------------
# The four metadata fields a --feature/--phase merge already knows
# ---------------------------------------------------------------------------


def _jq_number(value):
    """Collapse an integral float to an int, the way jq renders every number.

    roadmap.py's jq_numbers does this over a whole document; what is needed
    here is the same collapse over ONE scalar, so it is reproduced rather than
    imported. A cross-import between the two document modules is exactly the
    dependency sanitize.py was extracted to prevent -- "the one rule both
    import, so neither owns it" -- and jq_numbers carries jq's whole rendering
    contract over documents, which nothing here reads.
    """
    if isinstance(value, bool):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    return value


def _num(value):
    """Render a JSON number the way jq's tostring does: 2 not 2.0.

    Only ever used in a refusal message, so "phase 1 not found" reads the way
    the caller spelled the flag rather than as "phase 1.0 not found".
    """
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return str(value)


def _same_number(stored, wanted):
    """Numeric equality on a phase id, over a document people hand-edit.

    Phases are matched NUMERICALLY, never by string: 2.10 and 2.1 are one
    number and must name one phase, and 1.0 must find 1. A stored id that is a
    string, a bool or absent matches nothing -- Python's True == 1 is the trap
    the bool arm closes.
    """
    if isinstance(stored, bool) or not isinstance(stored, (int, float)):
        return False
    return stored == wanted


def derive_phase_metadata(roadmap_path, feature, phase_raw, base_ref, plugin_version):
    """The four metadata keys a phase-scoped merge can answer for itself.

    Called once, early -- before --foundation, cycle detection, the sweeps and
    every write -- for the reason resolve_axis's own docstring gives about its
    placement: a refusal here costs nothing and cannot warn about a plan that
    was never going to be written.

    THE PHASE ENTRY'S `.branch` IS READ FOR NOTHING. branchName is not derived,
    not validated and not reported here, and the value never reaches the
    document or stderr. Its prefix is metadata.type, which /aimi:plan decides
    inside Phase 4 -- AFTER the Phase 3e call that runs this merge -- so no
    caller can hand a composed name over at merge time and this function cannot
    compose one either: type is authored, has no validator anywhere, and a
    hardcoded "feat/" is wrong for most of the tasks files on disk.

    `dir` is taken VERBATIM and an entry without a usable one is REFUSED rather
    than reconstructed. roadmap-init already composed and validated that
    segment; re-deriving it from the id would turn phase-1.1-beta into
    phase-1-1-beta, which names no directory on disk. The refusal is the
    enforcement of "never re-derived", not politeness.

    roadmapPath is composed from the --feature VALUE, while the absolute
    --roadmap path (already confined by the bash half) is what gets read. One
    input, one slug, so the two can never disagree -- which matters, because on
    disk a feature directory and its document's own .feature field are measured
    to disagree, and the flag is what names the path.
    """
    try:
        with open(roadmap_path, encoding="utf-8") as handle:
            doc = json.load(handle)
    except (OSError, ValueError) as exc:
        die("Error: story-merge: unreadable roadmap.json: " + roadmap_path + ": " + str(exc))
    try:
        wanted = _jq_number(json.loads(phase_raw))
    except ValueError:
        die("Error: story-merge: --phase <id> must be a numeric phase id, got: " + phase_raw)
    if isinstance(wanted, bool) or not isinstance(wanted, (int, float)):
        die("Error: story-merge: --phase <id> must be a numeric phase id, got: " + phase_raw)
    entry = next(
        (
            p
            for p in _list(doc.get("phases") if isinstance(doc, dict) else None)
            if isinstance(p, dict) and _same_number(p.get("id"), wanted)
        ),
        None,
    )
    if entry is None:
        die("Error: story-merge: phase " + _num(wanted) + " not found in " + roadmap_path)
    directory = entry.get("dir")
    if not isinstance(directory, str) or directory == "":
        die("Error: story-merge: phase " + _num(wanted) + " has no dir in " + roadmap_path)
    derived = {
        "roadmapPath": ".aimi/tasks/" + feature + "/roadmap.json",
        # The entry's own JSON value, so an integer id stays 1 and a decimal
        # stays 1.1 -- the shape already on disk.
        "phase": {"id": entry.get("id"), "dir": directory},
    }
    # Each key exists only when its source answered: an absent flag is an
    # absent key, never null, never "" and never a placeholder.
    if base_ref:
        derived["baseRef"] = base_ref
    if plugin_version:
        derived["pluginVersion"] = plugin_version
    return derived


def resolve_axis(stories, split_mode):
    """Echo "project" or "side", or refuse what the axis cannot route.

    Called once, early -- before --foundation, cycle detection and the sweeps --
    so a refusal costs nothing and emits no warnings about a plan that was never
    going to be written.

    The untagged rule tests distinct >= 1, not >= 2, deliberately: the failure it
    exists to stop is ONE tagged repo plus untagged stories, which counts as a
    single distinct project and would otherwise take the SIDE axis -- one file,
    one branch, two repositories.

    rm_sanitize is applied HERE and only here. These lines print values that
    already failed validation and are therefore unbounded; on every success path
    .project is a routing key that must stay byte-identical between the key that
    groups and the key that is written.
    """
    invalid = [
        "  "
        + s["id"]
        + " ("
        + _cat(rm_sanitize(s.get("title"), TITLE_MAXLEN))
        + "): invalid project "
        + _cat(rm_sanitize(_tostring(s.get("project")), PROJECT_MAXLEN))
        for s in stories
        if project_state(s.get("project")) == "invalid"
    ]
    if invalid:
        die_list(
            'Error: story-merge: story .project must match ^[a-zA-Z0-9_][a-zA-Z0-9_./@-]*$'
            ' with no ".." component, no "//", no surrounding whitespace, and no leading'
            ' "./" (use "." for the root repository); no files were written:',
            invalid,
        )

    if split_mode != "full-stack":
        return "side"

    states = [(project_state(s.get("project")), group_key(s.get("project"))) for s in stories]
    distinct = len({key for state, key in states if state == "tagged"})
    untagged = len([1 for state, _ in states if state == "untagged"])

    if distinct >= 1 and untagged > 0:
        die_list(
            "Error: story-merge: --split full-stack: this plan tags "
            + str(distinct)
            + " project(s), so it is a multi-repo plan and EVERY story needs a project."
            ' A story that belongs to the root repository must say so explicitly with'
            ' "." -- an absent project is not the root, it is unrouteable. No files were'
            " written; the staging dir was kept. Stories missing a project:",
            [
                "  "
                + s["id"]
                + " ("
                + _cat(rm_sanitize(s.get("title"), TITLE_MAXLEN))
                + "): no project"
                for s in stories
                if project_state(s.get("project")) == "untagged"
            ],
        )

    return "project" if distinct >= 2 else "side"


# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------

_MKTEMP_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"


def _mktemp(path):
    """`mktemp "$path.XXXXXX"` -- six random characters, mode 600, same directory."""
    for _ in range(100):
        candidate = path + "." + "".join(random.choice(_MKTEMP_CHARS) for _ in range(6))
        try:
            return os.open(candidate, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), candidate
        except FileExistsError:
            continue
        except OSError:
            return None, None
    return None, None  # pragma: no cover - 100 collisions in a row


def _unlink(path):
    try:
        os.unlink(path)
    except OSError:
        pass


def write_atomically(path, document):
    """Lock beside the target, write a temp file, rename. Returns 0, or non-zero.

    Where the bash opened its lock with a `200>` redirect and reached for the
    `flock` binary (falling back to a mkdir spin when it was missing), this holds
    the same lock through fcntl, which is a syscall and needs no fallback.
    """
    text = json.dumps(document, indent=2, ensure_ascii=False) + "\n"
    tmp_fd, tmp_path = _mktemp(path)
    if tmp_fd is None:
        return 1
    lock_fd = None
    try:
        try:
            lock_fd = os.open(path + ".lock", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o666)
        except OSError:
            return 1
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as handle:
            tmp_fd = None
            handle.write(text)
        os.replace(tmp_path, path)
        tmp_path = None
        return 0
    except OSError:
        return 1
    finally:
        if tmp_fd is not None:
            os.close(tmp_fd)
        if tmp_path is not None:
            _unlink(tmp_path)
        if lock_fd is not None:
            os.close(lock_fd)


def _metadata(title, branch_name, smells, split_group=None):
    metadata = {
        "title": title,
        "type": "feat",
        "branchName": branch_name,
        "createdAt": time.strftime("%Y-%m-%d", time.gmtime()),
        "planPath": None,
    }
    if split_group is not None:
        metadata["splitGroup"] = split_group
    # Injected only when non-empty, so absent-by-default stays the norm.
    if smells:
        metadata["smellWarnings"] = smells
    return metadata


_WORKING_KEYS = (
    "referenceInventory",
    "ac_anchors",
    "_fe",
    "_side",
    "__droppedDeps",
    "__becameRoot",
    "_auditChanged",
)


def _for_output(stories):
    out = []
    for story in stories:
        story = dict(story)
        for key in _WORKING_KEYS:
            story.pop(key, None)
        if _falsy(story.get("status")):
            story["status"] = "pending"
        out.append(story)
    return out


# ---------------------------------------------------------------------------
# Advisory story smells: overlap, size, audit duplication, stale notes, outline
# leftovers and test enumeration
# ---------------------------------------------------------------------------
#
# All six are reported into metadata.smellWarnings and on stderr, and none ever
# drops a story, blocks the merge or changes its exit status. They are computed
# inside each writer, AFTER the id remap, so storyId is the id that lands on
# disk -- the orphan-symbol and verify-coverage entries are built in main
# before a split renumbers, and these deliberately do not copy that.
#
# Every threshold below is a named constant and was measured, not guessed:
# `python3 scripts/tests/calibrate_story_smells.py` prints the tables and
# `--check` exits 1 when a constant fires on any golden case or on the plan
# under test. Adjust a constant only within what that script prints, and
# update SMELL_CALIBRATION_AS_OF and the firing counts when you do.
#
# SMELL_CALIBRATION_AS_OF = the commit the constants were measured on, and the date.
# The figures below were taken on top of that commit with the four newest types
# in place, so the marker names the base the working tree stood on.
# Measured firing counts at the values below (calibrate_story_smells.py, default
# mode, run at that commit; plan files are live, so their figures are as of that run):
#   golden corpus (86 staged cases, 167 stories, bytes max 369):
#       all six types 0 (field-overlap, story-oversize, audit-duplication,
#       stale-sibling-note, leftover-outline-token, ac-test-enumeration)
#   the #164 plan, found under .aimi/ (it is archived now: the script globs
#   .aimi/**, so it still finds it) (7 stories, 6496-11570 bytes, median 7372;
#   overlap n=4 max 0.23):
#       field-overlap 0, story-oversize 0, audit-duplication 0,
#       stale-sibling-note 0, ac-test-enumeration 0,
#       leftover-outline-token 5 (US-002, 004, 005, 006, 007: 11 fields; the plan
#       predates the text remap)   <- the set `--check` enforces, exactly
#   every tasks file under .aimi/ (71 files, 433 stories, bytes p50 11903 p90 22183;
#   overlap n=4 over 419 eligible stories p50 0.10 p90 0.24 p95 0.29 max 0.45):
#       field-overlap 16, story-oversize 210 (floor 14336 would flag 160, 16384
#       would flag 109); the 2x-median rule alone flags 2 of 433.
#       stale-sibling-note 3, leftover-outline-token 174, ac-test-enumeration 28.
#       audit-duplication 0 there: no stored plan carries the audit's changed-field
#       record, so only a live merge can fire it.
#   This includes plans being executed when these were measured, whose largest
#   story fires story-oversize at 12288. That is expected and advisory, not a
#   calibration failure: the gate pins the #164 plan, not those.
# 12288 is the smallest 1 KiB step above the #164 plan's maximum (11570); 0.30 at
# n=4 is the p95 of history and sits above that plan's 0.23 maximum. n=3 is too
# noisy (max 0.31 there, 0.52 overall) and n=5 loses the signal (p95 0.23).
# AUDIT_DUPLICATION_THRESHOLD 0.20 is the p83 of the same distribution (72 of 419
# eligible stories reach it, 37 reach 0.25, 16 reach 0.30): the check only runs
# for a story an audit patch changed in both fields, so it can sit below 0.30.
SMELL_CALIBRATION_AS_OF = "9fcfa44 2026-10-23"
FIELD_OVERLAP_NGRAM = 4
FIELD_OVERLAP_THRESHOLD = 0.30
FIELD_OVERLAP_MIN_TASKS = 3
FIELD_OVERLAP_MIN_APPROACH_CHARS = 200
STORY_OVERSIZE_FLOOR_BYTES = 12288
STORY_OVERSIZE_MEDIAN_FACTOR = 2
STORY_OVERSIZE_MEDIAN_MIN_STORIES = 3
STORY_OVERSIZE_MEDIAN_MIN_BYTES = 4096
# audit-duplication asks the field-overlap question only of a story an audit patch
# already changed in BOTH tasks and implementation.approach, so the prior that the
# overlap is the audit's doing is far stronger than for a story picked at random,
# and the bar can sit below FIELD_OVERLAP_THRESHOLD. 0.20 is the p83 of history
# (72 of 419 eligible stories reach it; 37 reach 0.25, 16 reach 0.30).
AUDIT_DUPLICATION_THRESHOLD = 0.20
AUDIT_DUPLICATION_FIELDS = ("tasks", "implementation.approach")
# A citation of a sibling inside the older paragraphs of `notes`: US-NNN, or the
# prose form `story NN`. An outline token in notes has already been rewritten to
# US-NNN by the remap before this runs.
STALE_NOTE_SIBLING_PATTERN = re.compile(r"\bUS-([0-9]{3})\b|\b(?i:story) ([0-9]{1,3})\b")
# `outline:` followed by one or more digits. OUTLINE_TOKEN owns exactly two
# digits not followed by a third, so a one-digit `outline:7` or a longer
# `outline:041` is text the remap does not own and leaves in place.
LEFTOVER_OUTLINE_PATTERN = re.compile(r"outline:[0-9]+")
# A criterion listing test functions states coverage, which belongs in tasks[].
AC_TEST_ENUMERATION_PATTERN = re.compile(r"\btest_[a-z0-9_]+")
AC_TEST_ENUMERATION_MIN = 3

_WORD_RE = re.compile(r"[^\W_]+")


def _words(text):
    return _WORD_RE.findall(text.lower())


def _entry_ngrams(text, size):
    words = _words(text)
    return {tuple(words[i : i + size]) for i in range(len(words) - size + 1)}


def field_overlap_ratio(story, size=FIELD_OVERLAP_NGRAM):
    """Share of tasks[] word n-grams that also occur in implementation.approach.

    None when the story is not eligible: fewer than FIELD_OVERLAP_MIN_TASKS
    entries, an approach shorter than FIELD_OVERLAP_MIN_APPROACH_CHARS, or no
    n-gram in tasks[] at all. N-grams are built per entry, so none spans two.
    """
    tasks = story.get("tasks")
    implementation = story.get("implementation")
    approach = implementation.get("approach") if isinstance(implementation, dict) else None
    if not isinstance(tasks, list) or len(tasks) < FIELD_OVERLAP_MIN_TASKS:
        return None
    if not isinstance(approach, str) or len(approach) < FIELD_OVERLAP_MIN_APPROACH_CHARS:
        return None
    task_grams = set()
    for entry in tasks:
        if isinstance(entry, str):
            task_grams |= _entry_ngrams(entry, size)
    if not task_grams:
        return None
    return len(task_grams & _entry_ngrams(approach, size)) / len(task_grams)


def story_bytes(story):
    """Serialized size of a story as it lands on disk, minus `wave`.

    `wave` is left out so the figure does not depend on when waves are computed.
    surrogatepass keeps a lone surrogate in staging text from crashing the merge.
    """
    shaped = _for_output([story])[0]
    shaped.pop("wave", None)
    text = json.dumps(shaped, ensure_ascii=False, separators=(",", ":"))
    return len(text.encode("utf-8", errors="surrogatepass"))


def advisory_story_smells(stories):
    """The advisory entries for a plan's stories, in a fixed type order.

    `stories` is every story of the plan -- on a split, the union of all output
    files -- so the median is plan-wide. Returns field-overlap, story-oversize,
    audit-duplication, stale-sibling-note, leftover-outline-token and
    ac-test-enumeration entries, in that order.
    """
    stories = [s for s in stories if isinstance(s, dict)]
    overlap = []
    for story in stories:
        ratio = field_overlap_ratio(story)
        if ratio is not None and ratio >= FIELD_OVERLAP_THRESHOLD:
            rounded = round(ratio, 3)
            overlap.append(
                {
                    "type": "field-overlap",
                    "storyId": story.get("id"),
                    "ratio": rounded,
                    "ngram": FIELD_OVERLAP_NGRAM,
                    "message": "tasks[] restates implementation.approach ("
                    + str(rounded)
                    + " of its "
                    + str(FIELD_OVERLAP_NGRAM)
                    + "-word sequences also occur in the approach)",
                }
            )
    sizes = [story_bytes(s) for s in stories]
    median = int(statistics.median(sizes)) if sizes else 0
    oversize = []
    for story, size in zip(stories, sizes):
        over_floor = size > STORY_OVERSIZE_FLOOR_BYTES
        over_median = (
            len(stories) >= STORY_OVERSIZE_MEDIAN_MIN_STORIES
            and size > STORY_OVERSIZE_MEDIAN_FACTOR * median
            and size > STORY_OVERSIZE_MEDIAN_MIN_BYTES
        )
        if over_floor or over_median:
            oversize.append(
                {
                    "type": "story-oversize",
                    "storyId": story.get("id"),
                    "bytes": size,
                    "medianBytes": median,
                    "floorBytes": STORY_OVERSIZE_FLOOR_BYTES,
                    "message": "story serializes to "
                    + str(size)
                    + " bytes (plan median "
                    + str(median)
                    + ", floor "
                    + str(STORY_OVERSIZE_FLOOR_BYTES)
                    + ")",
                }
            )
    return (
        overlap
        + oversize
        + audit_duplication_smells(stories)
        + stale_sibling_note_smells(stories)
        + leftover_outline_token_smells(stories)
        + ac_test_enumeration_smells(stories)
    )


def audit_duplication_smells(stories):
    """Stories an audit patch left with tasks[] restating implementation.approach.

    Fires only when the audit's changed-field record (the `_auditChanged` working
    key main attaches from audit-result.json) lists BOTH tasks and
    implementation.approach for the story AND field_overlap_ratio reaches
    AUDIT_DUPLICATION_THRESHOLD. No record, a record naming one of the two, or a
    story the ratio is not defined for yields nothing.
    """
    entries = []
    for story in stories:
        changed = story.get("_auditChanged")
        if not isinstance(changed, list) or not all(f in changed for f in AUDIT_DUPLICATION_FIELDS):
            continue
        ratio = field_overlap_ratio(story)
        if ratio is None or ratio < AUDIT_DUPLICATION_THRESHOLD:
            continue
        rounded = round(ratio, 3)
        entries.append(
            {
                "type": "audit-duplication",
                "storyId": story.get("id"),
                "ratio": rounded,
                "ngram": FIELD_OVERLAP_NGRAM,
                "message": "an audit patch changed both tasks and implementation.approach, and"
                " tasks[] now restates the approach ("
                + str(rounded)
                + " of its "
                + str(FIELD_OVERLAP_NGRAM)
                + "-word sequences also occur in it)",
            }
        )
    return entries


def _sibling_id(match):
    if match.group(1):
        return "US-" + match.group(1)
    return "US-" + _pad(int(match.group(2)), 3)


def stale_sibling_note_smells(stories):
    """Older `notes` paragraphs that cite a different story of the merged set.

    Scans every paragraph before the last NOTES_SEPARATOR; the final paragraph
    (the one an audit appended) and a note with no separator are never scanned.
    A citation counts only when it names a story that exists in this plan and is
    not the story carrying the note.
    """
    ids = {s.get("id") for s in stories}
    entries = []
    for story in stories:
        notes = story.get("notes")
        if not isinstance(notes, str) or NOTES_SEPARATOR not in notes:
            continue
        cited = set()
        for paragraph in notes.split(NOTES_SEPARATOR)[:-1]:
            for match in STALE_NOTE_SIBLING_PATTERN.finditer(paragraph):
                sibling = _sibling_id(match)
                if sibling in ids and sibling != story.get("id"):
                    cited.add(sibling)
        if cited:
            ordered = sorted(cited)
            entries.append(
                {
                    "type": "stale-sibling-note",
                    "storyId": story.get("id"),
                    "cited": ordered,
                    "message": "notes written before the audit cite "
                    + ", ".join(ordered)
                    + ", which may no longer describe that story",
                }
            )
    return entries


def _string_fields(value, path):
    """(field path, text) for every string under `value`; list entries share the list's path."""
    if isinstance(value, str):
        yield path, value
    elif isinstance(value, dict):
        for key, child in value.items():
            yield from _string_fields(child, path + "." + str(key) if path else str(key))
    elif isinstance(value, list):
        for child in value:
            yield from _string_fields(child, path)


def leftover_outline_token_smells(stories):
    """Stories where an `outline:` + digits survived the remap in a non-dependsOn field."""
    entries = []
    for story in stories:
        fields = set()
        for key, value in story.items():
            if key == "dependsOn" or key in _WORKING_KEYS or key.startswith("_"):
                continue
            for path, text in _string_fields(value, key):
                if LEFTOVER_OUTLINE_PATTERN.search(text):
                    fields.add(path)
        if fields:
            ordered = sorted(fields)
            entries.append(
                {
                    "type": "leftover-outline-token",
                    "storyId": story.get("id"),
                    "fields": ordered,
                    "message": "an outline: token survived the remap in " + ", ".join(ordered),
                }
            )
    return entries


def ac_test_enumeration_smells(stories):
    """One entry per acceptance criterion naming AC_TEST_ENUMERATION_MIN or more distinct tests."""
    entries = []
    for story in stories:
        criteria = story.get("acceptanceCriteria")
        if not isinstance(criteria, list):
            continue
        for index, criterion in enumerate(criteria):
            if not isinstance(criterion, str):
                continue
            count = len(set(AC_TEST_ENUMERATION_PATTERN.findall(criterion)))
            if count >= AC_TEST_ENUMERATION_MIN:
                entries.append(
                    {
                        "type": "ac-test-enumeration",
                        "storyId": story.get("id"),
                        "index": index,
                        "count": count,
                        "message": "acceptanceCriteria["
                        + str(index)
                        + "] names "
                        + str(count)
                        + " distinct tests; coverage belongs in tasks[]",
                    }
                )
    return entries


def report_advisory_story_smells(entries):
    """One stderr banner per smell type, one line per story."""
    for kind, header in (
        (
            "field-overlap",
            "Warning: story-merge: field-overlap smell detected (advisory; tasks[] restates"
            " implementation.approach):",
        ),
        (
            "story-oversize",
            "Warning: story-merge: story-oversize smell detected (advisory; story is far above"
            " the plan's norm):",
        ),
        (
            "audit-duplication",
            "Warning: story-merge: audit-duplication smell detected (advisory; an audit patch"
            " left tasks[] restating implementation.approach):",
        ),
        (
            "stale-sibling-note",
            "Warning: story-merge: stale-sibling-note smell detected (advisory; an older notes"
            " paragraph cites another story):",
        ),
        (
            "leftover-outline-token",
            "Warning: story-merge: leftover-outline-token smell detected (advisory; an outline:"
            " token survived the remap):",
        ),
        (
            "ac-test-enumeration",
            "Warning: story-merge: ac-test-enumeration smell detected (advisory; a criterion"
            " lists test names):",
        ),
    ):
        lines = [
            "  Story " + str(e["storyId"]) + ": " + e["message"] for e in entries if e["type"] == kind
        ]
        if lines:
            warn_list(header, lines)


def _document(metadata, stories):
    return {"schemaVersion": "3.3", "metadata": metadata, "userStories": _for_output(stories)}


def _emit(value):
    json.dump(value, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")


def write_legacy(stories, output_path, staging_dir, smells, phase_metadata=None):
    advisory = advisory_story_smells(stories)
    report_advisory_story_smells(advisory)
    metadata = _metadata("feat: merged tasks", "feat/merged", smells + advisory)
    # Merged AFTER _metadata's own keys, which is where the hand-patched
    # phase-scoped files on disk carry them. _metadata's arguments are
    # untouched, so branchName still arrives from this caller as the literal it
    # has always been; with no phase metadata the dict is byte-identical to the
    # one this line built before.
    if phase_metadata:
        metadata.update(phase_metadata)
    document = _document(metadata, stories)
    os.makedirs(_dirname(output_path), exist_ok=True)
    if write_atomically(output_path, document) != 0:
        die("Error: story-merge: failed to write output file: " + output_path)
    # On success: delete the staging dir.
    shutil.rmtree(staging_dir, ignore_errors=True)
    _emit({"merged": output_path, "stories": len(stories)})


# ---------------------------------------------------------------------------
# The cross-file dependsOn sweep, shared in shape by both split writers
# ---------------------------------------------------------------------------


# One pattern for what a story-id reference looks like inside story text: "US-"
# and exactly three digits, with no word character before it and no digit after.
# XUS-001 and US-0011 are not references, so a longer number or an embedded id is
# never half-rewritten -- the same boundary rule OUTLINE_TOKEN applies to its own
# token.
STORY_ID_REF = re.compile(r"(?<!\w)US-[0-9]{3}(?![0-9])")


def _render_split_refs(story, id_map, global_map, axis_key):
    """Re-render the US-NNN references in one story's text after a split.

    Story text was written against the pre-split ids, which stop naming the same
    story once the split renumbers each output file. One substitution per field,
    single-pass, so ids that swap inside one block never chain. The target is found
    in this file's own id_map first (same file: the new id alone), then in
    global_map (another file: the new id plus a label naming where it went, the
    target's `axis_key` -- "frontend"/"backend" on the SIDE axis, the project key on
    the PROJECT axis, with "." read as "root"). Any other id is returned unchanged.

    verify and guardRails get the id only: a parenthesis there is a shell syntax
    error, and both receive the identical substitution, so every guardRails entry
    still equals a segment of the rewritten verify.
    """

    def sub(text, path, shell):
        def replace(match):
            old = match.group(0)
            if old in id_map:
                return id_map[old]
            target = global_map.get(old)
            if target is None:
                return old
            if shell:
                return target["newId"]
            label = target[axis_key]
            return target["newId"] + " (" + ("root" if label == "." else str(label)) + ")"

        return STORY_ID_REF.sub(replace, text)

    _rewrite_story_text(story, sub)


def _remap_block(stories, id_map, global_map=None, axis_key=None):
    """Rewrite ids and dependsOn inside one output file, recording what was lost.

    A dependsOn entry that fails to resolve against this file's OWN id map is by
    construction resolvable in another file -- the outline:NN remap and its
    unresolved check ran before this -- so it is dropped here and named later.

    With a global_map and the axis key it was built under, the same pass also
    re-renders the US-NNN references in each story's text (see _render_split_refs).
    """
    for story in stories:
        pre = _list(story.get("dependsOn"))
        had_deps = len(pre) > 0
        dropped = [dep for dep in pre if id_map.get(dep) is None]
        story["id"] = id_map.get(story["id"], story["id"])
        story["dependsOn"] = [id_map[dep] for dep in pre if id_map.get(dep) is not None]
        story["__droppedDeps"] = dropped
        story["__becameRoot"] = had_deps and story["dependsOn"] == []
        if global_map is not None:
            _render_split_refs(story, id_map, global_map, axis_key)


def _dropped_banner(warnings, kind, axis_note):
    """One summary line, then one enumeration line per FALSE-ROOT story only.

    Never per-edge: legitimate FE<->API edges and --foundation's one injected
    edge per story would otherwise flood every normal full-stack plan.
    """
    total = sum(len(entry["droppedDeps"]) for entry in warnings)
    sys.stderr.write(
        "Warning: story-merge: "
        + str(total)
        + " "
        + kind
        + " dependsOn edge(s) dropped across "
        + str(len(warnings))
        + " affected stories ("
        + axis_note
        + "; see metadata.smellWarnings)\n"
    )


def _false_root_lines(warnings, axis_key, kind):
    return [
        entry["storyId"]
        + " ("
        + entry[axis_key]
        + "): became a false wave-1 root -- its "
        + kind
        + " dependsOn target(s) "
        + _join(", ", [dep["id"] + " (" + dep[axis_key] + ")" for dep in entry["droppedDeps"]])
        + " were dropped"
        for entry in warnings
        if entry["becameRoot"] is True
    ]


def _false_root_note(lines):
    for line in lines:
        sys.stderr.write(line + "\n")


# ---------------------------------------------------------------------------
# SIDE axis: two files, frontend and backend
# ---------------------------------------------------------------------------


def fe_heuristic(story):
    """The per-story frontend verdict, applied unconditionally.

    This writer only ever sees a single-repo/monorepo merge -- every layout with
    two or more distinct normalized .project values goes to the PROJECT writer --
    so there is no project group to vote on and no project-aware branch.
    """
    files = _implementation_files(story)
    if any(
        isinstance(f, str) and any(re.search(p, f) for p in FE_FILE_PATTERNS) for f in files
    ):
        return True
    text = _cat(story.get("title")) + " " + _cat(story.get("description"))
    return re.search(FE_TEXT_PATTERN, text, re.I) is not None


def write_side_split(stories, output_path, staging_dir, smells, phase_aware):
    for story in stories:
        story["_fe"] = fe_heuristic(story)
        story["_side"] = story["_fe"]
    # Two select() passes over one sided array, so every id structurally lands in
    # exactly one output -- never lost, never duplicated.
    frontend = [s for s in stories if s["_side"] is True]
    backend = [s for s in stories if s["_side"] is False]

    # An empty side still writes its (empty userStories) file -- traced, does not
    # crash downstream -- but is surfaced rather than failing silently.
    if not frontend:
        sys.stderr.write("Warning: story-merge: frontend split produced zero stories\n")
    if not backend:
        sys.stderr.write("Warning: story-merge: backend split produced zero stories\n")

    fe_map = {s["id"]: "US-" + _pad(i + 1, 3) for i, s in enumerate(frontend)}
    be_map = {s["id"]: "US-" + _pad(i + len(frontend) + 1, 3) for i, s in enumerate(backend)}

    # Pre-remap id -> {newId, side, title}, built from BOTH sides before either
    # remap runs: a pre-remap id exists in neither output file, so naming a
    # dropped cross-file target usefully requires resolving it now.
    global_map = {}
    for story in frontend:
        global_map[story["id"]] = {
            "newId": fe_map.get(story["id"], story["id"]),
            "side": "frontend",
            "title": story.get("title"),
        }
    for story in backend:
        global_map[story["id"]] = {
            "newId": be_map.get(story["id"], story["id"]),
            "side": "backend",
            "title": story.get("title"),
        }

    _remap_block(frontend, fe_map, global_map, "side")
    _remap_block(backend, be_map, global_map, "side")

    cross = []
    for side, group in (("frontend", frontend), ("backend", backend)):
        for story in group:
            if not story["__droppedDeps"]:
                continue
            dropped = []
            for old in story["__droppedDeps"]:
                target = global_map.get(old, {"newId": old, "side": "unknown", "title": ""})
                dropped.append(
                    {
                        "id": target["newId"],
                        "side": target["side"],
                        "title": rm_sanitize(target["title"], TITLE_MAXLEN),
                    }
                )
            cross.append(
                {
                    "type": "cross-file-dep-dropped",
                    "storyId": story["id"],
                    "side": side,
                    "becameRoot": story["__becameRoot"],
                    "droppedDeps": dropped,
                    "message": str(len(dropped))
                    + " cross-file dependsOn edge(s) dropped targeting: "
                    + _join("; ", [d["title"] for d in dropped])
                    + (" (story became a false wave-1 root)" if story["__becameRoot"] else ""),
                }
            )

    # Merged before either file is built, so both carry the same combined set.
    # Computed here, after the remap, over BOTH sides: the ids are final and the
    # median is plan-wide rather than per file.
    advisory = advisory_story_smells(frontend + backend)
    combined = smells + cross + advisory
    if cross:
        _dropped_banner(cross, "cross-file", "--split full-stack")
        _false_root_note(_false_root_lines(cross, "side", "cross-file"))
    report_advisory_story_smells(advisory)

    compute_waves(frontend)
    compute_waves(backend)

    base = _strip_extension(_basename(output_path))
    # --phase-aware: a phase-scoped basename already ends in "-tasks", so strip
    # that one segment before appending, keeping a single "tasks" segment instead
    # of doubling it. The unflagged derivation is untouched.
    if phase_aware:
        base = base[: -len("-tasks")] if base.endswith("-tasks") else base
    directory = _dirname(output_path)
    fe_path = directory + "/" + base + "-frontend-tasks.json"
    be_path = directory + "/" + base + "-backend-tasks.json"

    os.makedirs(directory, exist_ok=True)

    fe_doc = _document(
        _metadata("feat: merged tasks (frontend)", "feat/merged-frontend", combined), frontend
    )
    if write_atomically(fe_path, fe_doc) != 0:
        die("Error: story-merge: failed to write frontend output: " + fe_path)
    be_doc = _document(
        _metadata("feat: merged tasks (backend)", "feat/merged-backend", combined), backend
    )
    if write_atomically(be_path, be_doc) != 0:
        die("Error: story-merge: failed to write backend output: " + be_path)

    # On success: delete the staging dir.
    shutil.rmtree(staging_dir, ignore_errors=True)
    _emit(
        {
            "frontend": fe_path,
            "backend": be_path,
            "frontend_stories": len(frontend),
            "backend_stories": len(backend),
        }
    )


# ---------------------------------------------------------------------------
# PROJECT axis: one file per repository
# ---------------------------------------------------------------------------
#
# All-or-nothing contract: every output path, slug and branchName is derived and
# validated BEFORE the first write, so a collision or an invalid branch name
# lands zero files. Once the write loop starts, a mid-loop failure names the
# files already on disk and keeps the staging dir so a retry is unambiguous.


def slugify(project):
    """A project path is NEVER interpolated raw into a filename."""
    slug = re.sub(r"[^A-Za-z0-9_-]", "-", project)
    slug = re.sub(r"-+", "-", slug)
    slug = re.sub(r"^-+|-+$", "", slug)
    return slug if slug != "" else "root"


def _derived_name_errors(group, branch_regex):
    """Every invariant a derived slug / path / branchName must satisfy.

    REFUSE, never truncate. Truncating two long project values to a common prefix
    manufactures a slug collision, which the guard above would then report as a
    conflict between projects that do not actually conflict.

    Legs, and why each limit is where it is:
      branchName regex  -- the invariant plan.md enforces before any git
                           operation. Currently unreachable given slugify's
                           output; kept because it costs one search and is the
                           only thing standing between a future slugify edit and
                           a branch name handed to git unchecked.
      slug <= 64        -- plan.md rewrites branchName to a ~87-char prefix in
                           phase mode; 87 + 64 stays inside every downstream limit.
      basename <= 248   -- NAME_MAX (255) minus the 7 bytes mktemp appends. This
                           is the leg that actually prevents a mid-loop mktemp
                           death, and it is checked on the basename rather than
                           the slug because most of that basename comes from
                           --output, not from .project.
      path <= 4000      -- PATH_MAX (4096) with headroom for the lock/tmp suffixes.
      branchName <= 100 -- worktree-manager places a worktree as a single
                           directory component, so branchName feeds a
                           NAME_MAX-bounded name downstream.
    """
    base = group["path"].split("/")[-1]
    errors = []
    if not re.search(branch_regex, group["branchName"]):
        errors.append(
            "derived branchName failed validation against " + branch_regex + ": " + group["branchName"]
        )
    if len(group["slug"]) > 64:
        errors.append(
            "derived basename slug is " + str(len(group["slug"])) + " chars (limit 64): " + group["slug"]
        )
    if len(base) > 248:
        errors.append(
            "derived output basename is "
            + str(len(base))
            + " chars (limit 248 = NAME_MAX 255 minus the 7-char mktemp suffix): "
            + base
        )
    if len(group["path"]) > 4000:
        errors.append("derived output path is " + str(len(group["path"])) + " chars (limit 4000)")
    if len(group["branchName"]) > 100:
        errors.append(
            "derived branchName is "
            + str(len(group["branchName"]))
            + " chars (limit 100): "
            + group["branchName"]
        )
    return ['  project "' + group["project"] + '": ' + error for error in errors]


def write_project_split(
    stories, output_path, staging_dir, smells, phase_aware, foundation_ids, branch_regex
):
    # 1. Route every story to a project group. There is no fallback for a null
    #    key and there must not be one: this writer is only reached on the
    #    PROJECT axis, which the resolver enters only when every story is
    #    tagged. Groups come out in lexicographic order by normalized project
    #    path, never staging-glob or first-encountered order.
    keys = sorted({group_key(s.get("project")) for s in stories})
    buckets = [
        (key, [s for s in stories if group_key(s.get("project")) == key]) for key in keys
    ]

    # 2. Contiguous US-NNN block per group, in group order, so ids stay unique
    #    across the whole N-file set.
    blocks = []
    offset = 0
    for key, bucket in buckets:
        blocks.append(
            {
                "project": key,
                "idmap": {s["id"]: "US-" + _pad(offset + i + 1, 3) for i, s in enumerate(bucket)},
                "stories": bucket,
            }
        )
        offset += len(bucket)

    # Built across EVERY group before any dependsOn remap runs, so a dropped
    # cross-group target can still be named usefully.
    global_map = {}
    for block in blocks:
        for story in block["stories"]:
            global_map[story["id"]] = {
                "newId": block["idmap"].get(story["id"], story["id"]),
                "project": block["project"],
                "title": story.get("title"),
            }

    for block in blocks:
        _remap_block(block["stories"], block["idmap"], global_map, "project")
        compute_waves(block["stories"])

    # This axis keys every entry by `project` at BOTH the top level and in every
    # droppedDeps[]. There is no frontend/backend verdict here, so there is no
    # `side` field to emit; the two keys are mutually exclusive per axis, which
    # is what lets the Step 5 renderer read whichever one an entry carries.
    #
    # foundationEdge marks a dropped edge whose target is a story --foundation
    # named, in whichever project group that story lives. It can no longer mark
    # an edge the merge itself injected: injection is per group, so both
    # endpoints of an injected edge share one group_key, hence one per-block
    # idmap, and _remap_block never drops it. Every true reading from here on is
    # therefore a HAND-AUTHORED dependency reaching into another group's
    # foundation -- worth naming apart from an ordinary cross-project drop
    # because of WHAT IT TARGETS, not because of where it came from. It is the
    # one repository's Foundation Gate resolved Accept while a sibling's
    # resolved Skip case, and it is why the field is kept rather than removed.
    # foundation_ids holds PRE-remap ids and is empty when --foundation was
    # omitted -- no real id matches anything in it.
    foundation_id_set = set(foundation_ids)
    cross = []
    for block in blocks:
        for story in block["stories"]:
            if not story["__droppedDeps"]:
                continue
            dropped = []
            for old in story["__droppedDeps"]:
                target = global_map.get(old, {"newId": old, "project": "unknown", "title": ""})
                dropped.append(
                    {
                        "id": target["newId"],
                        "project": target["project"],
                        "title": rm_sanitize(target["title"], TITLE_MAXLEN),
                        "foundationEdge": old in foundation_id_set,
                    }
                )
            foundation_hits = [d for d in dropped if d["foundationEdge"] is True]
            message = (
                str(len(dropped))
                + " cross-file dependsOn edge(s) dropped targeting: "
                + _join("; ", [d["title"] for d in dropped])
            )
            if foundation_hits:
                message += (
                    " -- "
                    + str(len(foundation_hits))
                    + " of these targets a --foundation story in another project group ("
                    + _join(
                        ", ",
                        [d["id"] + ' in project "' + d["project"] + '"' for d in foundation_hits],
                    )
                    + "), a --foundation story belonging to another project group -- a"
                    " hand-authored dependency reaching across the split, never an edge"
                    " the merge injected"
                )
            if story["__becameRoot"]:
                message += " (story became a false wave-1 root)"
            cross.append(
                {
                    "type": "cross-file-dep-dropped",
                    "storyId": story["id"],
                    "project": block["project"],
                    "becameRoot": story["__becameRoot"],
                    "droppedDeps": dropped,
                    "message": message,
                }
            )

    # After every block's remap, over every block: final ids, plan-wide median.
    advisory = advisory_story_smells([s for block in blocks for s in block["stories"]])
    combined = smells + cross + advisory
    if cross:
        _dropped_banner(cross, "cross-project", "--split full-stack, project axis")
        # The --foundation note is separate from the drop-count banner because
        # these edges are a different KIND of finding, not a louder count of the
        # same one. Injection is per project group, so the merge cannot have
        # produced one of them: each is a hand-authored dependency on a story
        # some group's Foundation Gate accepted, written against a different
        # foundation split than the one that shipped or predating the per-repo
        # split entirely. That is worth a look, not expected fallout.
        foundation_edges = [d for e in cross for d in e["droppedDeps"] if d["foundationEdge"]]
        foundation_stories = [
            e for e in cross if any(d["foundationEdge"] for d in e["droppedDeps"])
        ]
        if foundation_edges:
            sys.stderr.write(
                "Note: story-merge: "
                + str(len(foundation_edges))
                + " of those edge(s), across "
                + str(len(foundation_stories))
                + " stories, target a --foundation story in another project group;"
                " --foundation injects only within a group, so these are hand-authored"
                " dependencies reaching across the split (see"
                " droppedDeps[].foundationEdge)\n"
            )
        _false_root_note(_false_root_lines(cross, "project", "cross-project"))
    report_advisory_story_smells(advisory)

    # 3. Derive every output path / slug / branchName up front.
    base = _strip_extension(_basename(output_path))
    # Identical single-"tasks"-segment collapse the SIDE writer applies. Pure
    # string manipulation on the --output basename, independent of the axis.
    if phase_aware:
        base = base[: -len("-tasks")] if base.endswith("-tasks") else base
    directory = _dirname(output_path)

    plan = []
    for index, block in enumerate(blocks):
        slug = slugify(block["project"])
        plan.append(
            {
                "index": index + 1,
                # .project is carried through verbatim, never sanitized: it is
                # the routing key, and a lossy transform would make the key that
                # groups differ from the key that is written. Malformed values
                # were refused by resolve_axis before this writer was reached.
                "project": block["project"],
                "slug": slug,
                "path": directory + "/" + base + "-" + slug + "-tasks.json",
                "branchName": "feat/merged-" + slug,
                "storyCount": len(block["stories"]),
            }
        )

    # Two distinct project values that flatten to the same slug would silently
    # overwrite each other. Hard-fail the WHOLE merge before the first write.
    collisions = []
    for slug in sorted({group["slug"] for group in plan}):
        shared = [group for group in plan if group["slug"] == slug]
        if len(shared) > 1:
            collisions.append(
                '  basename slug "'
                + slug
                + '" is shared by projects: '
                + _join(", ", [group["project"] for group in shared])
            )
    if collisions:
        die_list(
            "Error: story-merge: --split full-stack: distinct project values collide on the"
            " same output basename; no files were written:",
            collisions,
        )

    bad_derived = [line for group in plan for line in _derived_name_errors(group, branch_regex)]
    if bad_derived:
        die_list(
            "Error: story-merge: --split full-stack: derived output name(s) failed"
            " validation; no files were written (shorten the offending project value --"
            " names are refused, never truncated, because truncation would manufacture a"
            " basename collision between two distinct projects):",
            bad_derived,
        )

    # 4. Write every group's file atomically.
    os.makedirs(directory, exist_ok=True)
    written = []
    for index, group in enumerate(plan):
        # metadata.splitGroup is the self-describing marker for this file's place
        # in the N-way split, so downstream consumers discover the full set from
        # it instead of re-deriving it from filename string conventions.
        split_group = {
            "project": group["project"],
            "index": group["index"],
            "total": len(plan),
            "siblings": [s["path"] for s in plan if s["index"] != group["index"]],
        }
        document = _document(
            _metadata(
                "feat: merged tasks (" + group["slug"] + ")",
                group["branchName"],
                combined,
                split_group,
            ),
            blocks[index]["stories"],
        )
        if write_atomically(group["path"], document) != 0:
            # Enumerate all THREE sets. The surviving files are the actionable
            # part: each advertises a splitGroup.total and a siblings[] list
            # describing a complete N-way split that does not exist on disk, so
            # the reader needs to know which of those siblings landed and which
            # never will.
            remaining = len(plan) - index - 1
            sys.stderr.write(
                "Error: story-merge: failed to write project split output: " + group["path"] + "\n"
            )
            sys.stderr.write("  Written before this failure (" + str(index) + "):\n")
            if written:
                for path in written:
                    sys.stderr.write("    " + path + "\n")
            else:
                sys.stderr.write("    (none)\n")
            sys.stderr.write("  Failed:\n")
            sys.stderr.write("    " + group["path"] + "\n")
            sys.stderr.write("  Not attempted (" + str(remaining) + "):\n")
            if remaining > 0:
                for later in plan[index + 1 :]:
                    sys.stderr.write("    " + later["path"] + "\n")
            else:
                sys.stderr.write("    (none)\n")
            sys.stderr.write("  Staging dir preserved for retry:\n")
            sys.stderr.write("    " + staging_dir + "\n")
            sys.exit(1)
        written.append(group["path"])

    # On success: delete the staging dir.
    shutil.rmtree(staging_dir, ignore_errors=True)
    _emit(
        [
            {
                "path": group["path"],
                "project": group["project"],
                "branchName": group["branchName"],
                "storyCount": group["storyCount"],
            }
            for group in plan
        ]
    )


# ---------------------------------------------------------------------------
# The one entry point
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# The verify refusal and validate-staging
# ---------------------------------------------------------------------------
#
# ONE helper decides whether a story's implementation.verify can swallow a
# failing line, and both callers use it: `validate-staging`, which /aimi:plan runs
# while stories are still being expanded, and the story-merge refusal below, which
# is the second gate because an audit patch that replaces a verify lands after the
# expansion-time check. Two copies of the rule could disagree about one story.
#
# The rule itself (tasks.py's verify_composition_findings) is imported INSIDE the
# function body: tasks.py imports story_merge at module level, so a top-level
# import here would close a cycle. roadmap.py's function-local imports are the
# precedent. A finding can quote a model-written verify, so every finding passes
# through rm_sanitize before it reaches stdout or stderr.

_FINDING_MAXLEN = 500


def verify_refusal_findings(story):
    """Sanitized findings for one story's verify; [] for a clean or absent one."""
    if not isinstance(story, dict):
        return []
    from tasks import verify_composition_findings

    return [
        rm_sanitize(finding, _FINDING_MAXLEN)
        for finding in verify_composition_findings(_implementation_verify(story))
    ]


def _depends_on_tokens(entries):
    tokens = set()
    for entry in entries:
        deps = entry.get("dependsOn")
        if isinstance(deps, list):
            tokens.update(dep for dep in deps if isinstance(dep, str))
    return tokens


def validate_staging(staging_dir, outline=None):
    """{idx: [finding, ...]} for the staged `NN-*.json` files that fail a rule.

    Files come from audit_patches.staged_idx_map -- the glob the audit gate uses,
    so sidecars and symlinks are excluded -- and a file that is not valid JSON is
    skipped, never fatal: its shape is Schema Validation step 2's business. With
    an outline, every producer -> consumer edge outline_contract reports (an
    `ext:` consume never makes one) requires `outline:<from>` in the `dependsOn`
    of the story staged as `<to>`; that is the only producer lookup there is.
    """
    edges = []
    if outline is not None:
        from outline_contract import validate_outline

        edges = validate_outline(outline)["edges"]
    report = {}
    for idx, path in sorted(staged_idx_map(staging_dir).items()):
        try:
            with open(path, "r", encoding="utf-8") as handle:
                value = json.load(handle)
        except (OSError, ValueError):
            continue
        entries = [e for e in (value if isinstance(value, list) else [value]) if isinstance(e, dict)]
        findings = []
        for entry in entries:
            findings.extend(verify_refusal_findings(entry))
        if entries:
            tokens = _depends_on_tokens(entries)
            for edge in edges:
                if edge["to"] == idx and "outline:" + edge["from"] not in tokens:
                    findings.append(
                        rm_sanitize(
                            "consumes " + str(edge["name"]) + ", which outline entry "
                            + edge["from"] + " produces, but dependsOn lacks outline:"
                            + edge["from"],
                            _FINDING_MAXLEN,
                        )
                    )
        if findings:
            report[idx] = findings
    return report


def verify_refusal_lines(stories):
    """One refusal line per story whose verify swallows a failing line."""
    lines = []
    for story in stories:
        for finding in verify_refusal_findings(story):
            lines.append(
                "  Story "
                + story["id"]
                + " (staged "
                + str(story.get("_stagedIdx", ""))
                + "): implementation.verify "
                + finding
            )
    return lines


def run_validate_staging(args):
    """The validate-only mode: print {idx: findings} and exit 1 when non-empty."""
    staging_dir = _flag(args, "--staging-dir", "")
    outline_path = _flag(args, "--outline", "")
    outline = None
    if outline_path:
        try:
            with open(outline_path, "r", encoding="utf-8") as handle:
                outline = json.load(handle)
        except (OSError, ValueError):
            die("Error: validate-staging: --outline is not readable JSON: " + outline_path)
        if not isinstance(outline, list):
            die("Error: validate-staging: --outline must hold a JSON array: " + outline_path)
    try:
        report = validate_staging(staging_dir, outline)
    except (AuditRefusal, OSError) as refusal:
        die("Error: validate-staging: " + rm_sanitize(str(refusal), _FINDING_MAXLEN))
    sys.stdout.write(json.dumps(report, ensure_ascii=False, indent=2 if report else None) + "\n")
    return 1 if report else 0


def _flag(argv, name, default=None):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return default


def _flags_all(argv, name):
    """Every value following an occurrence of `name`, in argv order.

    _flag() answers the FIRST occurrence, which is all a single-valued flag can
    mean. --foundation is the one repeatable flag -- one accepted foundation per
    project group -- so it needs the whole list; what to do with an exact repeat
    is inject_foundation's decision, not this helper's.
    """
    return [argv[i + 1] for i, token in enumerate(argv) if token == name and i + 1 < len(argv)]


def main(argv):
    args = argv[1:]
    if "--validate-staging" in args:
        return run_validate_staging(args)
    staging_dir = _flag(args, "--staging-dir", "")
    output_path = _flag(args, "--output", "")
    split_mode = _flag(args, "--split", "legacy")
    foundation_values = _flags_all(args, "--foundation")
    branch_regex = _flag(args, "--branch-regex", "")
    agent_mode = "--agent-mode" in args
    # --phase-aware is the --output-basename boolean; --phase below is the
    # roadmap phase id. Near-homonyms, unrelated semantics -- see the same note
    # beside cmd_story_merge's own two arms.
    phase_aware = "--phase-aware" in args
    feature = _flag(args, "--feature", "")
    phase_raw = _flag(args, "--phase", "")
    roadmap_path = _flag(args, "--roadmap", "")
    base_ref = _flag(args, "--base-ref", "")
    plugin_version = _flag(args, "--plugin-version", "")

    paths = staging_files(staging_dir)
    if not paths:
        die("Error: story-merge: no *.json files found in " + staging_dir)

    audit_status = require_audit(staging_dir, paths)
    # Read here, while the staging directory still exists: the writers delete it.
    audit_changed = read_changed_fields(staging_dir)

    stories = read_staging(paths)
    assign_ids(stories)
    # The second gate for a verify that can swallow a failing line (the first is
    # validate-staging during expansion). It sits after assign_ids so it can name
    # US-NNN and ahead of every remap and sweep so a refusal writes nothing. No
    # agent_mode branch: an audit patch can introduce the verify this refuses.
    swallowing = verify_refusal_lines(stories)
    if swallowing:
        die_list(
            "Error: story-merge: implementation.verify would swallow a failing line"
            " (start it with set -e or chain its lines with &&):",
            swallowing,
        )
    # Computed ONCE, while every story still carries its _stagedIdx, and reused by
    # --foundation below so the two can never resolve an idx differently.
    idx_map = outline_map(stories)
    remap_outline_tokens(stories, idx_map)
    unresolved = unresolved_outline_refs(stories)
    if unresolved:
        die_list("Error: story-merge: unresolved outline reference(s):", unresolved)
    text_unresolved = remap_story_text_tokens(stories, idx_map)
    if text_unresolved:
        die_list(
            "Error: story-merge: outline reference(s) in story text name no staged file"
            " (outline:NN is the staged filename index, never a position):",
            text_unresolved,
        )
    for story in stories:
        # Keyed by the staged filename idx the way outline_map is, and attached
        # as a working key (stripped from output) so the smell pass can ask which
        # fields an audit patch changed without reopening the staging directory.
        changed = audit_changed.get(story.get("_stagedIdx"))
        if changed:
            story["_auditChanged"] = changed
        story.pop("_srcIdx", None)
        story.pop("_stagedIdx", None)

    # Earliest point at which every story carries its final US-NNN id, and still
    # ahead of --foundation, cycle detection and the sweeps: a refusal here costs
    # nothing and cannot warn about a plan that was never going to be written.
    # The axis is decided ONCE, here, and the writers below only read the answer.
    split_axis = resolve_axis(stories, split_mode)

    # Same placement, same argument: ahead of --foundation, cycle detection and
    # every sweep, so a bad phase costs nothing. The bash half has already
    # refused half a pair, so both values are present or neither is.
    phase_metadata = (
        derive_phase_metadata(roadmap_path, feature, phase_raw, base_ref, plugin_version)
        if feature and phase_raw
        else None
    )

    foundation_ids = inject_foundation(stories, foundation_values, idx_map) if foundation_values else []

    in_cycle = cycle_stories(stories)
    if in_cycle:
        die(
            "Error: story-merge: circular dependency detected among stories: "
            + _join(", ", in_cycle)
        )

    compute_waves(stories)
    route_mock_sync_acs(stories)

    inventory = inventory_violations(stories)
    if inventory:
        if agent_mode:
            warn_list(
                "Warning: story-merge: Phase 3.1 inventory verdict incomplete"
                " (--agent-mode: proceeding):",
                inventory,
            )
        else:
            die_list(
                "Error: story-merge: Phase 3.1 Reference Element Inventory has unverdicted"
                " rows:",
                inventory,
            )

    coverage = coverage_violations(stories)
    if coverage:
        if agent_mode:
            warn_list(
                "Warning: story-merge: Phase 4.1 coverage ratio not met (--agent-mode:"
                " proceeding):",
                coverage,
            )
        else:
            die_list("Error: story-merge: Phase 4.1 Coverage Self-Check failed:", coverage)

    # Phase 4.2 is a warning in BOTH modes -- it never blocks -- so the two
    # headers differ only in which one names --agent-mode.
    orphans = orphan_symbol_findings(stories)
    if orphans:
        warn_list(
            "Warning: story-merge: Phase 4.2 orphan-symbol smell detected (--agent-mode:"
            " proceeding):"
            if agent_mode
            else "Warning: story-merge: Phase 4.2 orphan-symbol smell detected (heuristic;"
            " verify before proceeding):",
            [
                "  Story "
                + finding["id"]
                + ": introduces symbols no other story references: "
                + _join(", ", finding["symbols"])
                for finding in orphans
            ],
        )

    # Phase 4.3 is a warning in BOTH modes too, same character as 4.2. Its own
    # CANNOT-DETERMINE-THE-VOCABULARY state is reported separately from a
    # divergence AND from CHECKED-AND-CLEAN -- three distinct outcomes, never
    # collapsed into one another. NOT-EVALUATED is a FOURTH outcome beside
    # them, not a fourth name for one of the three: it is the state in which
    # this phase measured nothing about a story, either because the story
    # cited no command at all or because nothing it cited is in its project's
    # own vocabulary. It is kept out of UNDETERMINED specifically -- that
    # message asserts no manifest and no CLAUDE.md/AGENTS.md was found for the
    # story's project, which is FALSE for a story whose group vocabulary was
    # derived fine, so folding the two would trade this silence for a lie.
    # Reporting it is what makes the phase account for every story that
    # entered: before it existed a story leaving by one of those two paths got
    # no verdict from any line, and vanished among the ones CHECKED-AND-CLEAN
    # names.
    #
    # project_root mirrors PROJECT_ROOT, which find_aimi_root() has already
    # cd'd aimi-cli.sh into by the time it invokes this script; the env var is
    # read directly (rather than added as a flag)
    # because nothing here needs it confined -- it only ever opens a handful of
    # well-known top-level filenames, never a document-sourced path.
    project_root = os.environ.get("PROJECT_ROOT") or os.getcwd()
    (
        verify_coverage,
        verify_coverage_undetermined,
        verify_coverage_clean,
        verify_coverage_not_evaluated,
    ) = verify_coverage_findings(stories, project_root)
    phase_43_reported = False
    if verify_coverage:
        warn_list(
            "Warning: story-merge: Phase 4.3 verify-coverage smell detected (--agent-mode:"
            " proceeding):"
            if agent_mode
            else "Warning: story-merge: Phase 4.3 verify-coverage smell detected (heuristic;"
            " verify before proceeding):",
            [
                "  Story "
                + finding["id"]
                + ": asserts a command implementation.verify does not run: "
                + _join(", ", finding["commands"])
                for finding in verify_coverage
            ],
        )
        phase_43_reported = True
    if verify_coverage_undetermined:
        sys.stderr.write(
            "Warning: story-merge: Phase 4.3 verify-coverage VOCABULARY UNDETERMINED for "
            + _join(", ", verify_coverage_undetermined)
            + " (no package.json, Makefile, Cargo.toml, pyproject.toml, go.mod, CLAUDE.md or"
            + " AGENTS.md found for that story's project; its cited command(s) were not"
            + " evaluated -- do not read this as CHECKED-AND-CLEAN)\n"
        )
        phase_43_reported = True
    if verify_coverage_clean:
        sys.stderr.write(
            "story-merge: Phase 4.3 verify-coverage CHECKED-AND-CLEAN for "
            + _join(", ", verify_coverage_clean)
            + "\n"
        )
        phase_43_reported = True
    # Conditional on the phase having already spoken, and that condition is a
    # measured trade rather than caution: printing it unconditionally would add
    # a stderr line to 50 of the 92 recorded story_merge cases (109 stories, not
    # one of them citing a command) and turn
    # test_an_ordinary_merge_says_nothing_about_the_sidecars_beside_it red. The
    # accepted consequence is that a merge in which EVERY story is not-evaluated
    # stays silent -- but there the phase has asserted nothing about anyone, so
    # there is no CHECKED-AND-CLEAN line for a missing id to hide behind. The
    # partition itself is checked at the function level, not by this line.
    if verify_coverage_not_evaluated and phase_43_reported:
        sys.stderr.write(
            "Warning: story-merge: Phase 4.3 verify-coverage NOT EVALUATED for "
            + _format_not_evaluated_line(verify_coverage_not_evaluated)
            + " -- this phase measured nothing about these stories; do not read"
            + " them as CHECKED-AND-CLEAN\n"
        )

    # Surfaced to the orchestrator's Step 5 report through metadata.smellWarnings;
    # the writers inject the field only when non-empty.
    smells = [
        {
            "type": "orphan-symbol",
            "storyId": finding["id"],
            "symbols": finding["symbols"],
            "message": "introduces symbols no sibling story references",
        }
        for finding in orphans
    ] + [
        {
            "type": "verify-coverage",
            "storyId": finding["id"],
            "commands": finding["commands"],
            "message": "asserts a command implementation.verify does not run",
        }
        for finding in verify_coverage
    ]

    # Nothing is recomputed here -- this only dispatches on the answer resolve_axis
    # already gave, so there is no second partition rule that could disagree with
    # the one the writer groups by.
    if split_mode == "full-stack":
        if split_axis == "project":
            # foundation_ids is threaded into the PROJECT writer ONLY, and as
            # the whole SET rather than one id: a dropped cross-group edge is
            # worth flagging when it targets ANY group's foundation, and after
            # per-group injection there can be one per group. The SIDE writer's
            # signature is unchanged -- it emits no foundationEdge field.
            write_project_split(
                stories,
                output_path,
                staging_dir,
                smells,
                phase_aware,
                foundation_ids,
                branch_regex,
            )
        else:
            write_side_split(stories, output_path, staging_dir, smells, phase_aware)
    else:
        write_legacy(stories, output_path, staging_dir, smells, phase_metadata)
    # Once, and only for a merge that completed: a refusal above never shipped
    # anything, so it must not claim a plan did. Any other status adds no line.
    if audit_status == "audit-failed":
        sys.stderr.write(AUDIT_FAILED_NOTICE + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
