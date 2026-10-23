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
returned.

Every refusal is computed before the first write. Writes are staged to temp
files beside their targets first and renamed second, the audit result LAST, so
a failure leaves either the old tree or a tree whose result file still says
"unaudited".

DROP CLASSES
============

A patch the verb cannot apply is dropped, and the drop is classified:

  schema   the patch is malformed (not an object, missing keys, bad storyIdx,
           field outside the allowlist, op/field mismatch, non-string value,
           bad dependsOn token, replace of a gate.prompt that does not exist).
           It appears in `dropped[]` only: a malformed patch carries no finding
           worth a human's attention.
  semantic the patch was well-formed and was refused on its content: a
           sanitizer trigger, tasks[] over its cap, a matchValue that matched
           zero or several entries, a post-patch validation failure. It appears
           in `dropped[]` AND appends an `unresolved` entry, because a finding
           was lost. That entry names the trigger and the field and NEVER
           echoes the offending value.

REPORT
======

Apply mode prints one JSON object:

  applied     int   patches that landed in a story file
  dropped     list  [{storyIdx, field, reason}] for every dropped patch
  unresolved  int   length of the merged `unresolved` array now on disk
  capped      int   patches beyond the 10-per-storyIdx cap
  auditedIdx  list  the staged idx set, sorted

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

from sanitize import PATCH_TRIGGERS, sanitize_patch_value


class AuditRefusal(Exception):
    """A condition that stops the run with exit 1 before anything is written."""


# --- The rules, ported from commands/plan.md "Patch Validation and Application"

ALLOWED_FIELDS = (
    "dependsOn",
    "tasks",
    "notes",
    "acceptanceCriteria",
    "implementation.approach",
    "gate.prompt",
)
OP_FOR_FIELD = {
    "dependsOn": "add",
    "tasks": "add",
    "notes": "add",
    "acceptanceCriteria": "replace",
    "implementation.approach": "replace",
    "gate.prompt": "replace",
}
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

    def schema_drop(self, patch, reason):
        idx = patch.get("storyIdx") if isinstance(patch, dict) else None
        field = patch.get("field") if isinstance(patch, dict) else None
        self.dropped.append({"storyIdx": _echo(idx), "field": _echo(field), "reason": reason})

    def semantic_drop(self, idx, field, reason, message):
        self.dropped.append({"storyIdx": idx, "field": field, "reason": reason})
        self.unresolved.append({"storyIdx": idx, "message": message})


def _trigger_name(trigger):
    # A name from PATCH_TRIGGERS, never anything derived from the value.
    return trigger if trigger in PATCH_TRIGGERS else "unknown"


def plan_patches(patches, idx_map, docs):
    plan = _Plan()
    candidates = {}
    seen_deps = {}
    for patch in patches:
        if not isinstance(patch, dict):
            plan.schema_drop(patch, "not-an-object")
            continue
        if not all(key in patch for key in ("storyIdx", "field", "op", "value")):
            plan.schema_drop(patch, "missing-keys")
            continue
        idx, field, op, value = (patch[k] for k in ("storyIdx", "field", "op", "value"))
        if not (isinstance(idx, str) and _IDX.fullmatch(idx) and idx in idx_map):
            plan.schema_drop(patch, "bad-storyIdx")
            continue
        if not (isinstance(field, str) and field in ALLOWED_FIELDS):
            plan.schema_drop(patch, "field-not-allowed")
            continue
        if op != OP_FOR_FIELD[field]:
            plan.schema_drop(patch, "op-field-mismatch")
            continue
        if not isinstance(value, str):
            plan.schema_drop(patch, "value-not-string")
            continue

        match_value = None
        if field == "acceptanceCriteria":
            match_value = patch.get("matchValue")
            if not (isinstance(match_value, str) and match_value):
                plan.schema_drop(patch, "bad-matchValue")
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
                plan.schema_drop(patch, "bad-dependsOn-token")
                continue
            present.add(value)
        else:
            clean, trigger = sanitize_patch_value(value, field)
            if trigger is not None:
                name = _trigger_name(trigger)
                plan.semantic_drop(
                    idx,
                    field,
                    "sanitizer:" + name,
                    "audit patch dropped: sanitizer trigger " + name + " in field " + field,
                )
                continue
            if match_value is not None:
                _, trigger = sanitize_patch_value(match_value, field)
                if trigger is not None:
                    name = _trigger_name(trigger)
                    plan.semantic_drop(
                        idx,
                        field,
                        "matchValue-sanitizer:" + name,
                        "audit patch dropped: sanitizer trigger " + name + " in matchValue of field " + field,
                    )
                    continue

        candidates.setdefault(idx, []).append(
            {"field": field, "value": clean, "matchValue": match_value}
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
    def __init__(self, kind, reason, message=None):
        super().__init__(reason)
        self.kind = kind  # "schema" or "semantic"
        self.reason = reason
        self.message = message


def _paragraph_append(existing, addition):
    if isinstance(existing, str) and existing:
        return existing + NOTES_SEPARATOR + addition
    return addition


def _apply_one(doc, patch):
    field, value = patch["field"], patch["value"]
    if field == "dependsOn":
        deps = doc.get("dependsOn")
        if not isinstance(deps, list):
            raise _Drop("semantic", "post-validation")
        deps.append(value)
    elif field == "tasks":
        tasks = doc.setdefault("tasks", [])
        if not isinstance(tasks, list):
            raise _Drop("semantic", "post-validation")
        tasks.append(value)
        if len(tasks) > MAX_TASKS:
            raise _Drop(
                "semantic",
                "tasks-cap",
                "audit patch dropped: tasks[] would exceed " + str(MAX_TASKS) + " entries (field tasks)",
            )
    elif field == "notes":
        existing = doc.get("notes")
        if existing is not None and not isinstance(existing, str):
            raise _Drop("semantic", "post-validation")
        doc["notes"] = _paragraph_append(existing, value)
    elif field == "acceptanceCriteria":
        criteria = doc.get("acceptanceCriteria")
        if not isinstance(criteria, list):
            raise _Drop("semantic", "post-validation")
        hits = [i for i, entry in enumerate(criteria) if entry == patch["matchValue"]]
        if len(hits) != 1:
            raise _Drop(
                "semantic",
                "matchValue-match-count",
                "audit patch dropped: matchValue matched "
                + str(len(hits))
                + " entries in field acceptanceCriteria",
            )
        criteria[hits[0]] = value
    elif field == "implementation.approach":
        impl = doc.setdefault("implementation", {})
        if not isinstance(impl, dict):
            raise _Drop("semantic", "post-validation")
        impl["approach"] = value
    else:  # gate.prompt
        gate = doc.get("gate")
        if not isinstance(gate, dict) or gate.get("prompt") is None:
            raise _Drop("schema", "gate-prompt-absent")
        gate["prompt"] = value


def _nonempty_str(v):
    return isinstance(v, str) and v.strip() != ""


def _valid_story(doc, field, value):
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
    if not _nonempty_str(value) and field != "dependsOn":
        return False
    if field == "tasks":
        tasks = doc.get("tasks")
        return isinstance(tasks, list) and all(isinstance(e, str) for e in tasks)
    if field == "notes":
        return isinstance(doc.get("notes"), str)
    if field == "implementation.approach":
        impl = doc.get("implementation")
        return isinstance(impl, dict) and _nonempty_str(impl.get("approach"))
    if field == "gate.prompt":
        gate = doc.get("gate")
        return isinstance(gate, dict) and _nonempty_str(gate.get("prompt"))
    return True


def apply_plan(plan, docs):
    """Apply each story's surviving patches in auditor order. Returns
    ({idx: patched doc}, applied count); drops are recorded on the plan."""
    patched = {}
    applied = 0
    for idx in plan.order:
        doc = docs[idx]
        changed = False
        for patch in plan.by_idx[idx]:
            candidate = copy.deepcopy(doc)
            field = patch["field"]
            try:
                _apply_one(candidate, patch)
                if not _valid_story(candidate, field, patch["value"]):
                    raise _Drop("semantic", "post-validation")
            except _Drop as drop:
                if drop.kind == "schema":
                    plan.dropped.append({"storyIdx": idx, "field": field, "reason": drop.reason})
                else:
                    message = drop.message or (
                        "audit patch dropped: post-patch validation failed in field " + field
                    )
                    plan.semantic_drop(idx, field, drop.reason, message)
                continue
            doc = candidate
            changed = True
            applied += 1
        if changed:
            patched[idx] = doc
    return patched, applied


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
    patched, applied = apply_plan(plan, docs)

    unresolved = [_normalise_unresolved(e) for e in result.get("unresolved", [])]
    unresolved.extend(plan.unresolved)
    audited = sorted(idx_map)

    rewritten = dict(result)
    rewritten["patches"] = result.get("patches", [])
    rewritten["unresolved"] = unresolved
    rewritten["auditedIdx"] = audited
    rewritten["appliedAt"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

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
