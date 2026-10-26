#!/usr/bin/env python3
"""apply-audit-patches: validate and apply the cross-story auditor's patches.

WHAT THIS MODULE IS FOR
=======================

/aimi:plan's Phase 3d.5 used to apply the auditor's patches to the staged
`NN-*.json` story files by hand, with Edit/Write calls, following prose. Two
things were wrong with that. A model hand-editing JSON can corrupt a staging
file halfway, and nothing recorded WHICH stories an audit had looked at, so an
unaudited plan was indistinguishable from an audited one. This module is the
one place that does both: it validates every patch, applies the survivors with
exactly one read and one atomic write per affected story file, and stamps the
audit result with `auditedIdx` (the staged idx set, sorted) and `appliedAt`.

`staged_idx_map` is public on purpose. story_merge.py's audit gate (a later
story) asks "which stories are staged?" and must get the SAME answer this verb
audited against, so both call this one function rather than each globbing the
directory. This module does not import story_merge.py for that reason in the
other direction: story_merge imports it.

TRUST MODEL
===========

audit-result.json is untrusted input -- an LLM wrote it. A non-JSON file, or a
`patches`/`unresolved` that is not an array, refuses with exit 1 and writes
nothing. The idx -> file map comes only from the `[0-9][0-9]-*.json` glob; no
path is ever built from an auditor string. Value text goes through
`sanitize_patch_value` (sanitize.py) with the patch's own field -- there is no
private copy of its patterns here -- and its `clean` result is stored as
returned. The two fields that hold shell (`implementation.verify` and
`implementation.guardRails`) go through `judge_patch_value` instead, which
judges and never rewrites: a script the expander wrote unsanitized would only be
corrupted by a rewrite. The two path fields (`implementation.files`,
`implementation.outputs`) take the plain sanitizer path and then one more
judgment, the shared path rule, on every add or replace value; a `matchValue`
is only sanitized, never path-judged, so an entry that already holds `..` can
still be named in order to be removed. Moving a wrong entry from one field to
the other is two patches, each judged on its own.

Every refusal is computed before the first write. Writes are staged to temp
files beside their targets first and renamed second, the audit result LAST, so
a failure leaves either the old tree or a tree whose result file still says
"unaudited".

DROP CLASSES
============

A patch the verb cannot apply is dropped. It appears in `dropped[]` and
NOWHERE else: a dropped patch does not add an `unresolved` entry (the plan
decided that as specFlow:ImportantQ15). Every entry names the patch's storyIdx,
field and op and the reason, plus `trigger` -- a name from PATCH_TRIGGERS --
when the matcher fired. It NEVER echoes a patch value or matchValue.

  malformed   not an object, missing keys, bad storyIdx, field outside the
              allowlist, op outside the field's set, non-string value, missing
              matchValue, bad dependsOn token, replace of a gate.prompt that
              does not exist.
  refused     well-formed, refused on its content: a sanitizer trigger, tasks[]
              over its cap, a matchValue that matched zero or several entries,
              an implementation.files / implementation.outputs value that the
              shared path rule refuses (`bad-path`; the value is judged by
              tasks.implementation_path_problem and never echoed),
              a patch that leaves a guard rail broken that was in sync before it
              (a rail that stops being exactly one top-level segment of the
              verify), a verify that can swallow a failing line, a post-patch
              validation failure. A rail that was already broken before the
              patch never causes a drop on its own: the check is differential.

The one `unresolved` entry this module still appends of its own is the cap
notice (`audit cap reached: N additional patches dropped`): capped patches are
counted in `capped`, not listed in `dropped[]`, so the notice is where a human
learns they exist.

REPORT
======

Apply mode prints one JSON object:

  applied     int   patches that landed in a story file
  dropped     list  [{storyIdx, field, op, reason[, trigger][, rails]}], one per
              dropped patch; every string is cut to 64 characters. `rails` is
              present on a `guardRails-out-of-sync` entry only: the ascending
              list of integer rail indices the patch newly broke, never an
              index that was already broken and never any rail text
  unresolved  int   length of the merged `unresolved` array now on disk
  capped      int   patches beyond the 10-per-storyIdx cap
  auditedIdx  list  the staged idx set, sorted

The rewritten audit result also gains `changedFields`: {idx: sorted list of the
distinct field names an applied patch changed}, with an entry only for an idx
that received at least one applied patch.

`--annotate-deferred --reason <text>` prints `{annotated, oqDecisions}` instead.
Annotate mode is not idempotent by design: the orchestrator calls it once per
Defer decision.
"""

import copy
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone

from sanitize import (
    PATCH_TRIGGERS,
    VERBATIM_PATCH_FIELDS,
    judge_patch_value,
    sanitize_patch_value,
)


class AuditRefusal(Exception):
    """A condition that stops the run with exit 1 before anything is written."""


# --- The rules, ported from commands/plan.md "Patch Validation and Application"

ALLOWED_FIELDS = (
    "dependsOn",
    "tasks",
    "notes",
    "acceptanceCriteria",
    "implementation.approach",
    "implementation.verify",
    "implementation.guardRails",
    "implementation.files",
    "implementation.outputs",
    "gate.prompt",
)
# The fields whose values are repository paths, judged by the shared path rule.
PATH_FIELDS = ("implementation.files", "implementation.outputs")
OPS_FOR_FIELD = {
    "dependsOn": frozenset({"add"}),
    "tasks": frozenset({"add", "replace", "remove"}),
    "notes": frozenset({"add", "replace"}),
    "acceptanceCriteria": frozenset({"replace"}),
    "implementation.approach": frozenset({"replace"}),
    "implementation.verify": frozenset({"replace"}),
    "implementation.guardRails": frozenset({"replace"}),
    "implementation.files": frozenset({"replace", "remove"}),
    "implementation.outputs": frozenset({"add", "replace", "remove"}),
    "gate.prompt": frozenset({"replace"}),
}
# (field, op) pairs that locate the text they change by an exact `matchValue`.
NEEDS_MATCH_VALUE = frozenset(
    {
        ("tasks", "replace"),
        ("tasks", "remove"),
        ("notes", "replace"),
        ("acceptanceCriteria", "replace"),
        ("implementation.verify", "replace"),
        ("implementation.guardRails", "replace"),
        ("implementation.files", "replace"),
        ("implementation.files", "remove"),
        ("implementation.outputs", "replace"),
        ("implementation.outputs", "remove"),
    }
)
MAX_PATCHES_PER_STORY = 10
MAX_TASKS = 50
NOTES_SEPARATOR = "\n\n---\n\n"
DEFER_MARKER = "[audit-deferred: unresolved — review before execution]"
AUDIT_SENTINEL = "_audit"

_STAGED_NAME = re.compile(r"[0-9]{2}-.*\.json", re.S)
_IDX = re.compile(r"[0-9]{2}")
_DEPENDS_TOKEN = re.compile(r"outline:([0-9]{2})")
_IDX_OR_SENTINEL = re.compile(r"[0-9]{2}|_audit")


# --- The staged set -------------------------------------------------------


def _within(real, root):
    return real == root or real.startswith(root + os.sep)


def staged_idx_map(staging_dir):
    """Return {idx: path} for the staged `NN-*.json` story files.

    Symlinks and names ending in `-outline.json` are skipped, the same
    exclusions story_merge.is_sidecar and staging_files apply (`find -type f`
    without -L). Two refusals are separate from skipping: an NN-named symlink
    whose realpath leaves the staging directory, and two files sharing one idx.
    Both raise AuditRefusal naming the file. Nothing here parses a file.
    """
    root = os.path.realpath(staging_dir)
    found = {}
    for name in sorted(os.listdir(staging_dir)):
        match = _STAGED_NAME.fullmatch(name)
        if not match or name.endswith("-outline.json"):
            continue
        path = os.path.join(staging_dir, name)
        if os.path.islink(path):
            if not _within(os.path.realpath(path), root):
                raise AuditRefusal(
                    name + " is a symlink that resolves outside the staging directory"
                )
            continue
        if not os.path.isfile(path):
            continue
        idx = name[:2]
        if idx in found:
            raise AuditRefusal(
                "two staging files share index "
                + idx
                + ": "
                + os.path.basename(found[idx])
                + " and "
                + name
            )
        found[idx] = path
    return found


def _read_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.loads(handle.read())


def _load_staged(idx_map):
    """Read every staged file ONCE. Returns {idx: dict-or-None}.

    A file holding a JSON array refuses at once (one story object per file).
    A file that is not JSON, or not an object, is recorded as None and refuses
    only if a patch or annotation turns out to need it.
    """
    docs = {}
    for idx, path in idx_map.items():
        try:
            doc = _read_json(path)
        except (OSError, ValueError, RecursionError):
            docs[idx] = None
            continue
        if isinstance(doc, list):
            raise AuditRefusal(
                os.path.basename(path) + " holds a JSON array; one story object per file"
            )
        docs[idx] = doc if isinstance(doc, dict) else None
    return docs


def _need_doc(idx_map, docs, idx):
    if docs[idx] is None:
        raise AuditRefusal(
            os.path.basename(idx_map[idx]) + " is not a readable JSON story object"
        )
    return docs[idx]


# --- The audit result -----------------------------------------------------


def load_result(path):
    try:
        data = _read_json(path)
    except FileNotFoundError:
        raise AuditRefusal("audit result does not exist: " + path)
    except (OSError, ValueError, RecursionError):
        raise AuditRefusal("audit result is not valid JSON: " + path)
    if not isinstance(data, dict):
        raise AuditRefusal("audit result is not a JSON object: " + path)
    for key in ("patches", "unresolved"):
        if not isinstance(data.get(key, []), list):
            raise AuditRefusal("audit result: '" + key + "' is not an array")
    return data


def _normalise_unresolved(entry):
    """Every unresolved entry leaves this module as {storyIdx, message}, however
    the auditor shaped it, so nothing downstream parses an untrusted shape."""
    if not isinstance(entry, dict):
        return {
            "storyIdx": AUDIT_SENTINEL,
            "message": "malformed unresolved entry in auditor output",
        }
    idx = entry.get("storyIdx")
    message = entry.get("message")
    if not (isinstance(idx, str) and _IDX_OR_SENTINEL.fullmatch(idx)):
        idx = AUDIT_SENTINEL
    if not isinstance(message, str):
        message = "unresolved entry without a message in auditor output"
    return {"storyIdx": idx, "message": message}


# --- Patch validation -----------------------------------------------------


def _echo(value):
    """A storyIdx/field as the report names it: a short string, or None."""
    return value[:64] if isinstance(value, str) else None


class _Plan:
    def __init__(self):
        self.by_idx = {}  # idx -> [patch dict], auditor order, after the cap
        self.order = []  # idx in first-appearance order
        self.dropped = []
        self.unresolved = []
        self.capped = 0

    def drop(self, idx, field, op, reason, trigger=None, rails=None):
        """Record a dropped patch. Strings are cut to 64 characters; the entry
        is built from validated names and a fixed reason, never from a value.
        `rails` (guardRails-out-of-sync only) is written as a sorted list of
        real ints, so no rail text can reach the report through it."""
        entry = {"storyIdx": _echo(idx), "field": _echo(field), "op": _echo(op), "reason": reason}
        if trigger is not None:
            entry["trigger"] = _trigger_name(trigger)
        if rails is not None:
            entry["rails"] = sorted(
                {r for r in rails if isinstance(r, int) and not isinstance(r, bool)}
            )
        self.dropped.append(entry)

    def drop_raw(self, patch, reason):
        """A drop decided before the patch was known to be well-formed."""
        get = patch.get if isinstance(patch, dict) else (lambda _key: None)
        self.drop(get("storyIdx"), get("field"), get("op"), reason)


def _trigger_name(trigger):
    # A name from PATCH_TRIGGERS, never anything derived from the value.
    return trigger if trigger in PATCH_TRIGGERS else "unknown"


def plan_patches(patches, idx_map, docs):
    plan = _Plan()
    candidates = {}
    seen_deps = {}
    for patch in patches:
        if not isinstance(patch, dict):
            plan.drop_raw(patch, "not-an-object")
            continue
        # `value` is the one key a `remove` patch does not need.
        if not all(key in patch for key in ("storyIdx", "field", "op")) or (
            "value" not in patch and patch.get("op") != "remove"
        ):
            plan.drop_raw(patch, "missing-keys")
            continue
        idx, field, op = (patch[k] for k in ("storyIdx", "field", "op"))
        value = patch.get("value")
        if not (isinstance(idx, str) and _IDX.fullmatch(idx) and idx in idx_map):
            plan.drop_raw(patch, "bad-storyIdx")
            continue
        if not (isinstance(field, str) and field in OPS_FOR_FIELD):
            plan.drop_raw(patch, "field-not-allowed")
            continue
        if not (isinstance(op, str) and op in OPS_FOR_FIELD[field]):
            plan.drop_raw(patch, "op-field-mismatch")
            continue
        if op != "remove" and not isinstance(value, str):
            plan.drop_raw(patch, "value-not-string")
            continue

        match_value = None
        if (field, op) in NEEDS_MATCH_VALUE:
            match_value = patch.get("matchValue")
            if not (isinstance(match_value, str) and match_value):
                plan.drop_raw(patch, "bad-matchValue")
                continue

        clean = value
        if field == "dependsOn":
            token = _DEPENDS_TOKEN.fullmatch(value)
            doc = _need_doc(idx_map, docs, idx)
            existing = doc.get("dependsOn")
            present = seen_deps.setdefault(
                idx, set(e for e in (existing if isinstance(existing, list) else []) if isinstance(e, str))
            )
            if not token or token.group(1) not in idx_map or token.group(1) == idx or value in present:
                plan.drop_raw(patch, "bad-dependsOn-token")
                continue
            present.add(value)
        else:
            verbatim = field in VERBATIM_PATCH_FIELDS
            if op != "remove":
                if verbatim:
                    clean, trigger = judge_patch_value(value, field)
                else:
                    clean, trigger = sanitize_patch_value(value, field)
                if trigger is not None:
                    plan.drop(idx, field, op, "sanitizer:" + _trigger_name(trigger), trigger)
                    continue
            if match_value is not None:
                if verbatim:
                    _, trigger = judge_patch_value(match_value, field)
                else:
                    _, trigger = sanitize_patch_value(match_value, field)
                if trigger is not None:
                    plan.drop(idx, field, op, "matchValue-sanitizer:" + _trigger_name(trigger), trigger)
                    continue
            if field in PATH_FIELDS and op != "remove":
                # Lazy for the reason _broken_rails gives: importing this module
                # must not load tasks. The matchValue is deliberately not judged.
                from tasks import implementation_path_problem

                if implementation_path_problem(field, clean) is not None:
                    plan.drop(idx, field, op, "bad-path")
                    continue

        candidates.setdefault(idx, []).append(
            {"field": field, "op": op, "value": clean, "matchValue": match_value}
        )

    for idx, group in candidates.items():
        plan.order.append(idx)
        plan.by_idx[idx] = group[:MAX_PATCHES_PER_STORY]
        extra = len(group) - MAX_PATCHES_PER_STORY
        if extra > 0:
            plan.capped += extra
            plan.unresolved.append(
                {
                    "storyIdx": idx,
                    "message": "audit cap reached: " + str(extra) + " additional patches dropped",
                }
            )
    return plan


# --- Applying one patch ---------------------------------------------------


class _Drop(Exception):
    """Raised inside _apply_one to refuse the patch it was applying."""

    def __init__(self, reason, rails=None):
        super().__init__(reason)
        self.reason = reason
        self.rails = rails


def _paragraph_append(existing, addition):
    if isinstance(existing, str) and existing:
        return existing + NOTES_SEPARATOR + addition
    return addition


def _single_hit(entries, match_value):
    """The index of the ONE element equal to match_value, else a drop."""
    hits = [i for i, entry in enumerate(entries) if entry == match_value]
    if len(hits) != 1:
        raise _Drop("matchValue-match-count")
    return hits[0]


def _broken_rails(doc):
    """The set of guardRails indices that are not exactly one top-level segment
    of the story's verify.

    The rule lives in tasks.py (`broken_rail_indices`, which cuts the verify with
    `verify_segments`); this calls it rather than restating it. Imported here
    and not at the top because tasks imports story_merge, which imports this
    module, so a top-level import would be a cycle -- and importing it lazily
    also keeps `import audit_patches` from loading the tasks module at all.
    """
    from tasks import broken_rail_indices

    return set(broken_rail_indices(doc))


def _require_no_new_broken_rails(doc, before):
    """Drop the patch when it broke a rail that was in sync before it.

    Differential, not whole-list: one rail that was already broken must not
    discard every patch of its story. `before` is `_broken_rails(doc)` taken
    before the branch mutated the candidate. The two sets are compared by
    position, which is sound because a guardRails replace assigns in place
    (`_single_hit`, same index) and a verify replace rebuilds the rail list one
    to one (same length), so an index names the same rail on both sides.
    """
    newly = _broken_rails(doc) - before
    if newly:
        raise _Drop("guardRails-out-of-sync", sorted(newly))


def _apply_one(doc, patch):
    field, op, value = patch["field"], patch["op"], patch["value"]
    if field == "dependsOn":
        deps = doc.get("dependsOn")
        if not isinstance(deps, list):
            raise _Drop("post-validation")
        deps.append(value)
    elif field == "tasks":
        tasks = doc.setdefault("tasks", [])
        if not isinstance(tasks, list):
            raise _Drop("post-validation")
        if op == "add":
            tasks.append(value)
            if len(tasks) > MAX_TASKS:
                raise _Drop("tasks-cap")
        else:
            hit = _single_hit(tasks, patch["matchValue"])
            if op == "replace":
                tasks[hit] = value
            else:
                del tasks[hit]
    elif field == "notes":
        existing = doc.get("notes")
        if existing is not None and not isinstance(existing, str):
            raise _Drop("post-validation")
        if op == "add":
            doc["notes"] = _paragraph_append(existing, value)
        else:
            if not isinstance(existing, str):
                raise _Drop("post-validation")
            paragraphs = existing.split(NOTES_SEPARATOR)
            paragraphs[_single_hit(paragraphs, patch["matchValue"])] = value
            doc["notes"] = NOTES_SEPARATOR.join(paragraphs)
    elif field == "acceptanceCriteria":
        criteria = doc.get("acceptanceCriteria")
        if not isinstance(criteria, list):
            raise _Drop("post-validation")
        criteria[_single_hit(criteria, patch["matchValue"])] = value
    elif field == "implementation.approach":
        impl = doc.setdefault("implementation", {})
        if not isinstance(impl, dict):
            raise _Drop("post-validation")
        impl["approach"] = value
    elif field == "implementation.verify":
        impl = doc.get("implementation")
        verify = impl.get("verify") if isinstance(impl, dict) else None
        if not isinstance(verify, str):
            raise _Drop("post-validation")
        match_value = patch["matchValue"]
        if verify.count(match_value) != 1:
            raise _Drop("matchValue-match-count")
        before = _broken_rails(doc)
        # The same substitution lands in every rail that contains the matched
        # text, so a rewritten assertion and its label move together.
        rails = impl.get("guardRails")
        if isinstance(rails, list):
            impl["guardRails"] = [
                entry.replace(match_value, value) if isinstance(entry, str) else entry
                for entry in rails
            ]
        impl["verify"] = verify.replace(match_value, value)
        _require_no_new_broken_rails(doc, before)
        # Lazy for the reason _broken_rails gives.
        from tasks import verify_composition_findings

        if verify_composition_findings(impl["verify"]):
            raise _Drop("verify-composition")
    elif field in PATH_FIELDS:
        key = field.split(".", 1)[1]
        # Only an outputs add may create what is absent; every other op names
        # an existing entry.
        creates = field == "implementation.outputs" and op == "add"
        impl = doc.setdefault("implementation", {}) if creates else doc.get("implementation")
        if not isinstance(impl, dict):
            raise _Drop("post-validation")
        entries = impl.setdefault(key, []) if creates and key not in impl else impl.get(key)
        if not isinstance(entries, list):
            raise _Drop("post-validation")
        if op == "add":
            if value in entries:
                raise _Drop("post-validation")
            entries.append(value)
        else:
            hit = _single_hit(entries, patch["matchValue"])
            if op == "replace":
                entries[hit] = value
            else:
                del entries[hit]
    elif field == "implementation.guardRails":
        impl = doc.get("implementation")
        if not isinstance(impl, dict):
            raise _Drop("post-validation")
        rails = impl.get("guardRails")
        if rails is None:
            rails = []
        if not isinstance(rails, list):
            raise _Drop("post-validation")
        hit = _single_hit(rails, patch["matchValue"])
        before = _broken_rails(doc)
        rails[hit] = value
        impl["guardRails"] = rails
        _require_no_new_broken_rails(doc, before)
    else:  # gate.prompt
        gate = doc.get("gate")
        if not isinstance(gate, dict) or gate.get("prompt") is None:
            raise _Drop("gate-prompt-absent")
        gate["prompt"] = value


def _nonempty_str(v):
    return isinstance(v, str) and v.strip() != ""


def _valid_story(doc, field, op, value):
    """plan.md's post-patch check: required fields plus the patched field's type."""
    if not isinstance(doc, dict):
        return False
    if not (_nonempty_str(doc.get("title")) and _nonempty_str(doc.get("description"))):
        return False
    criteria = doc.get("acceptanceCriteria")
    if not (isinstance(criteria, list) and criteria and all(isinstance(e, str) for e in criteria)):
        return False
    if doc.get("status") != "pending":
        return False
    deps = doc.get("dependsOn")
    if not (isinstance(deps, list) and all(isinstance(e, str) for e in deps)):
        return False
    verification = doc.get("verification")
    if not (isinstance(verification, dict) and "strategy" in verification and "status" in verification):
        return False
    # A `remove` carries no replacement text, so there is none to be non-empty.
    if op != "remove" and not _nonempty_str(value) and field != "dependsOn":
        return False
    if field == "tasks":
        tasks = doc.get("tasks")
        return isinstance(tasks, list) and all(isinstance(e, str) for e in tasks)
    if field == "notes":
        return isinstance(doc.get("notes"), str)
    if field == "implementation.approach":
        impl = doc.get("implementation")
        return isinstance(impl, dict) and _nonempty_str(impl.get("approach"))
    if field == "implementation.verify":
        impl = doc.get("implementation")
        return isinstance(impl, dict) and _nonempty_str(impl.get("verify"))
    if field == "implementation.guardRails":
        impl = doc.get("implementation")
        rails = impl.get("guardRails") if isinstance(impl, dict) else None
        return isinstance(rails, list) and all(_nonempty_str(e) for e in rails)
    if field in PATH_FIELDS:
        impl = doc.get("implementation")
        entries = impl.get(field.split(".", 1)[1]) if isinstance(impl, dict) else None
        return isinstance(entries, list) and all(isinstance(e, str) for e in entries)
    if field == "gate.prompt":
        gate = doc.get("gate")
        return isinstance(gate, dict) and _nonempty_str(gate.get("prompt"))
    return True


def apply_plan(plan, docs):
    """Apply each story's surviving patches in auditor order. Returns
    ({idx: patched doc}, applied count, {idx: set of changed field names});
    drops are recorded on the plan."""
    patched = {}
    changed_fields = {}
    applied = 0
    for idx in plan.order:
        doc = docs[idx]
        changed = False
        for patch in plan.by_idx[idx]:
            candidate = copy.deepcopy(doc)
            field, op = patch["field"], patch["op"]
            try:
                _apply_one(candidate, patch)
                if not _valid_story(candidate, field, op, patch["value"]):
                    raise _Drop("post-validation")
            except _Drop as drop:
                plan.drop(idx, field, op, drop.reason, rails=drop.rails)
                continue
            doc = candidate
            changed = True
            changed_fields.setdefault(idx, set()).add(field)
            applied += 1
        if changed:
            patched[idx] = doc
    return patched, applied, changed_fields


# --- Writing --------------------------------------------------------------


def _write_tmp(path, document):
    directory = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".audit-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(document, indent=2, ensure_ascii=False) + "\n")
        try:
            os.chmod(tmp, os.stat(path).st_mode & 0o7777)
        except OSError:
            pass
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return tmp


def commit_writes(writes):
    """writes: [(final path, document)], the audit result last. Stages every temp
    file before renaming any, so a failed stage changes nothing."""
    staged = []
    try:
        for path, document in writes:
            staged.append((_write_tmp(path, document), path))
    except OSError as exc:
        for tmp, _ in staged:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        raise AuditRefusal("could not stage a write (" + exc.strerror + "); nothing was changed")
    for position, (tmp, final) in enumerate(staged):
        try:
            os.replace(tmp, final)
        except OSError as exc:
            for rest, _ in staged[position:]:
                try:
                    os.unlink(rest)
                except OSError:
                    pass
            raise AuditRefusal(
                "could not replace " + os.path.basename(final) + " (" + exc.strerror + ")"
            )


# --- The two modes --------------------------------------------------------


def run_apply(staging_dir, result_path):
    idx_map = staged_idx_map(staging_dir)
    docs = _load_staged(idx_map)
    result = load_result(result_path)

    plan = plan_patches(result.get("patches", []), idx_map, docs)
    for idx in plan.order:
        _need_doc(idx_map, docs, idx)
    patched, applied, changed_fields = apply_plan(plan, docs)

    unresolved = [_normalise_unresolved(e) for e in result.get("unresolved", [])]
    unresolved.extend(plan.unresolved)
    audited = sorted(idx_map)

    rewritten = dict(result)
    rewritten["patches"] = result.get("patches", [])
    rewritten["unresolved"] = unresolved
    rewritten["auditedIdx"] = audited
    rewritten["appliedAt"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    rewritten["changedFields"] = {
        idx: sorted(changed_fields[idx]) for idx in sorted(changed_fields)
    }

    writes = [(idx_map[idx], patched[idx]) for idx in plan.order if idx in patched]
    writes.append((result_path, rewritten))
    commit_writes(writes)

    return {
        "applied": applied,
        "dropped": plan.dropped,
        "unresolved": len(unresolved),
        "capped": plan.capped,
        "auditedIdx": audited,
    }


def _strip_shell_markers(text):
    text = text.replace("`", "")
    while "$(" in text:
        text = text.replace("$(", "")
    return text


def _one_line(text):
    return re.sub(r"\r\n|\r|\n", " ", text)


def sanitize_reason(reason):
    return _strip_shell_markers(_one_line(reason))[:500]


def sanitize_message(message):
    text = _strip_shell_markers(_one_line(message))
    return text[:200] + "…" if len(text) > 200 else text


def run_annotate(staging_dir, result_path, reason):
    idx_map = staged_idx_map(staging_dir)
    docs = _load_staged(idx_map)
    result = load_result(result_path)
    reason_text = sanitize_reason(reason)

    entries = [_normalise_unresolved(e) for e in result.get("unresolved", [])]
    additions = {}
    decisions = []
    for entry in entries:
        message = sanitize_message(entry["message"])
        idx = entry["storyIdx"]
        decisions.append(
            {
                "anchor": "auditUnresolved:" + idx,
                "source": "auditGate",
                "text": message + " — reason: " + reason_text,
                "resolution": "deferred",
            }
        )
        if idx != AUDIT_SENTINEL and idx in idx_map:
            additions.setdefault(idx, []).append(DEFER_MARKER + " " + message)

    writes = []
    annotated = []
    for idx in sorted(additions):
        doc = copy.deepcopy(_need_doc(idx_map, docs, idx))
        existing = doc.get("notes")
        if existing is not None and not isinstance(existing, str):
            continue
        notes = existing
        for addition in additions[idx]:
            notes = _paragraph_append(notes, addition)
        doc["notes"] = notes
        writes.append((idx_map[idx], doc))
        annotated.append(idx)
    if writes:
        commit_writes(writes)
    return {"annotated": annotated, "oqDecisions": decisions}


# --- Entry point ----------------------------------------------------------


def _flag(args, name, default=""):
    if name in args:
        position = args.index(name)
        if position + 1 < len(args):
            return args[position + 1]
    return default


def main(argv):
    args = argv[1:]
    staging_dir = _flag(args, "--staging-dir")
    result_path = _flag(args, "--result") or os.path.join(staging_dir, "audit-result.json")
    annotate = "--annotate-deferred" in args
    try:
        if not staging_dir or not os.path.isdir(staging_dir):
            raise AuditRefusal("staging directory does not exist: " + staging_dir)
        if annotate:
            report = run_annotate(staging_dir, result_path, _flag(args, "--reason"))
        else:
            report = run_apply(staging_dir, result_path)
    except AuditRefusal as refusal:
        sys.stderr.write("Error: apply-audit-patches: " + str(refusal) + "\n")
        return 1
    sys.stdout.write(json.dumps(report, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
