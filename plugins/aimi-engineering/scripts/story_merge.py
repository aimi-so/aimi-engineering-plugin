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
import sys
import time

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
# Non-story sidecars written by plan.md Phase 3b (outline.json) and any future
# *outline*.json metadata file have a different shape and would be mis-merged as
# bogus stories, so they are skipped by name.

_SIDECARS = ("outline.json", "metadata.json", "audit-result.json")


def is_sidecar(base):
    if base in _SIDECARS:
        return True
    return base.endswith(".json") and "outline" in base[: -len(".json")]


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
    return [p for p in paths if not is_sidecar(_basename(p))]


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
        for entry in entries:
            if not isinstance(entry, dict):
                die(
                    "Error: story-merge: staging file must hold a story object or an "
                    "array of story objects: " + _basename(path)
                )
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


def outline_map(stories):
    """outline:NN is a 1-based position in the merged array, zero-padded to two."""
    return {_pad(position + 1, 2): story["id"] for position, story in enumerate(stories)}


def remap_outline_tokens(stories):
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


def inject_foundation(stories, foundation_values):
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


def _document(metadata, stories):
    return {"schemaVersion": "3.3", "metadata": metadata, "userStories": _for_output(stories)}


def _emit(value):
    json.dump(value, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")


def write_legacy(stories, output_path, staging_dir, smells):
    document = _document(_metadata("feat: merged tasks", "feat/merged", smells), stories)
    os.makedirs(_dirname(output_path), exist_ok=True)
    if write_atomically(output_path, document) != 0:
        die("Error: story-merge: failed to write output file: " + output_path)
    # On success: delete the staging dir.
    shutil.rmtree(staging_dir, ignore_errors=True)
    _emit({"merged": output_path, "stories": len(stories)})


# ---------------------------------------------------------------------------
# The cross-file dependsOn sweep, shared in shape by both split writers
# ---------------------------------------------------------------------------


def _remap_block(stories, id_map):
    """Rewrite ids and dependsOn inside one output file, recording what was lost.

    A dependsOn entry that fails to resolve against this file's OWN id map is by
    construction resolvable in another file -- the outline:NN remap and its
    unresolved check ran before this -- so it is dropped here and named later.
    """
    for story in stories:
        pre = _list(story.get("dependsOn"))
        had_deps = len(pre) > 0
        dropped = [dep for dep in pre if id_map.get(dep) is None]
        story["id"] = id_map.get(story["id"], story["id"])
        story["dependsOn"] = [id_map[dep] for dep in pre if id_map.get(dep) is not None]
        story["__droppedDeps"] = dropped
        story["__becameRoot"] = had_deps and story["dependsOn"] == []


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

    _remap_block(frontend, fe_map)
    _remap_block(backend, be_map)

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
    combined = smells + cross
    if cross:
        _dropped_banner(cross, "cross-file", "--split full-stack")
        _false_root_note(_false_root_lines(cross, "side", "cross-file"))

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
        _remap_block(block["stories"], block["idmap"])
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

    combined = smells + cross
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
    staging_dir = _flag(args, "--staging-dir", "")
    output_path = _flag(args, "--output", "")
    split_mode = _flag(args, "--split", "legacy")
    foundation_values = _flags_all(args, "--foundation")
    branch_regex = _flag(args, "--branch-regex", "")
    agent_mode = "--agent-mode" in args
    phase_aware = "--phase-aware" in args

    paths = staging_files(staging_dir)
    if not paths:
        die("Error: story-merge: no *.json files found in " + staging_dir)

    stories = read_staging(paths)
    assign_ids(stories)
    remap_outline_tokens(stories)
    unresolved = unresolved_outline_refs(stories)
    if unresolved:
        die_list("Error: story-merge: unresolved outline reference(s):", unresolved)
    for story in stories:
        story.pop("_srcIdx", None)

    # Earliest point at which every story carries its final US-NNN id, and still
    # ahead of --foundation, cycle detection and the sweeps: a refusal here costs
    # nothing and cannot warn about a plan that was never going to be written.
    # The axis is decided ONCE, here, and the writers below only read the answer.
    split_axis = resolve_axis(stories, split_mode)

    foundation_ids = inject_foundation(stories, foundation_values) if foundation_values else []

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
        write_legacy(stories, output_path, staging_dir, smells)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
