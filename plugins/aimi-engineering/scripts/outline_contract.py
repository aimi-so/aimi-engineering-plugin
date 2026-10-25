#!/usr/bin/env python3
"""validate-outline: check an outline's produces/consumes contract, derive waves.

WHAT THIS MODULE IS FOR
=======================

/aimi:plan's two-pass pipeline expands one outline entry into one story. When
one story depends on a name another story introduces (a symbol, a file, a CLI
verb, an HTTP route), the expansion of the consumer should see the producer's
result, so expansion has to be ordered. That order used to be reasoned out in
prose. This module is the deterministic check: it validates the `produces` /
`consumes` declarations on outline entries and layers the entries into waves
so every consumer comes after every in-plan producer of a name it consumes.

CONTRACT TOKENS
===============

A contract token is `[ext:]<kind>:<name>` with kind one of sym, path, cli, http.

  * The NAME is judged by roadmap.py's `_identity_reasons`, imported rather
    than mirrored, so the two never disagree on what an identity is. On top of
    it a non-http name may hold no whitespace and an http name is exactly
    `METHOD /path` with one space. A path name has no leading slash and no
    `..` segment.
  * `ext:` is accepted only in `consumes` and means the name already exists in
    the repository, so it needs no in-plan producer.

An outline entry carrying neither key is valid; an outline with no declarations
at all yields exactly one wave holding every idx.

REPORT
======

One JSON object on stdout: {valid, errors, waves, edges, counts}.

  errors  [{code, idx, message}] -- the codes are exactly bad-idx,
          duplicate-idx, bad-contract, bad-token, duplicate-produces,
          unproduced-consume, self-consume, external-also-produced, cycle.
          `message` names the offending token.
  waves   [[idx, ...], ...] -- Kahn layering over producer -> consumer edges,
          each wave sorted by idx; `[]` when the outline is invalid.
  edges   [{from, to, name}] sorted by (from, to, name).
  counts  {idx: {produces, consumes}}.

Exit status 0 for a valid outline and 1 for an invalid one (the object is still
printed). An unreadable argument -- a missing flag, a file that is absent, not
JSON, or not an array -- is a refusal on stderr, exit 1, with nothing on stdout.

OUTLINE SHIFT
=============

`--shift --staging-dir <dir> --old <outline> --new <outline>` (the CLI's
`outline-shift`) is the second job of this module. When the outline is edited
after stories were expanded, most staged files only moved: the same entry sits
at another idx. `plan_shift` classifies every entry by exact title, `apply_shift`
renames the shifted `NN-<slug>.json` files and rewrites their `outline:NN`
tokens in one pass, and only the stories the edit really affects are listed for
re-expansion. Nothing is written until every refusal is decided. One JSON
report on stdout: {renamed[{from,to,file}], removed[], reexpand[{idx,reason}],
expand[], auditInvalidated}. `renamed[].from`/`removed[]` are OLD idx, every
other idx is NEW; `file` is the renamed file's new basename.

IMPORT SAFETY
=============

roadmap.py imports only sanitize at module level and defers its tasks import
into functions, so importing it here loads none of tasks, story_merge or
audit_patches. This module must never import those three AT MODULE LEVEL: it is
the pure-logic end of the planning verbs and stays out of the tasks ->
story_merge -> audit_patches chain. The shift reuses `staged_idx_map` and
`OUTLINE_TOKEN` and takes them with a function-level import, which is exactly
the deferral roadmap.py uses for the same reason.
"""

import json
import os
import re
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from roadmap import _identity_reasons  # noqa: E402

KINDS = ("sym", "path", "cli", "http")
HTTP_METHODS = ("GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS")

_IDX = re.compile(r"^[0-9]{2}$")
_HTTP_NAME = re.compile(r"^(" + "|".join(HTTP_METHODS) + r") /[^ \t\r\n]*$")
_DOTDOT = re.compile(r"(^|/)\.\.($|/)")
_WHITESPACE = re.compile(r"[ \t\r\n]")
_MAX_TOKEN_ECHO = 200


class OutlineRefusal(Exception):
    """The argument cannot be judged at all (not a validation finding)."""


def _echo(token):
    """A token as it appears in a message, bounded so a hostile one stays small."""
    text = token if isinstance(token, str) else json.dumps(token, ensure_ascii=False)
    if len(text) > _MAX_TOKEN_ECHO:
        text = text[:_MAX_TOKEN_ECHO] + "..."
    return '"' + text + '"'


def _error(code, idx, message):
    return {"code": code, "idx": idx, "message": message}


def parse_token(token, allow_ext):
    """Return (key, None) for a usable token, or (None, (code, message)).

    `key` is the `<kind>:<name>` form with any `ext:` marker removed, plus a
    boolean for whether the marker was present: (key, ext) on success.
    """
    if not isinstance(token, str) or not token:
        return None, ("bad-token", "token " + _echo(token) + " is not a non-empty string")
    rest = token
    ext = False
    if rest.startswith("ext:"):
        if not allow_ext:
            return None, (
                "bad-token",
                "token " + _echo(token) + " carries the ext: marker, which is accepted only in consumes",
            )
        ext = True
        rest = rest[len("ext:"):]
    kind, sep, name = rest.partition(":")
    if not sep or kind not in KINDS:
        return None, (
            "bad-token",
            "token " + _echo(token) + " is not [ext:]<kind>:<name> with kind one of " + ", ".join(KINDS),
        )
    if name == "":
        return None, ("bad-token", "token " + _echo(token) + " has an empty name")

    reasons = list(_identity_reasons(name, ""))
    if kind == "http":
        if not _HTTP_NAME.match(name):
            reasons.append('an http name is exactly "METHOD /path" with one space and a method of ' + ", ".join(HTTP_METHODS))
    else:
        if _WHITESPACE.search(name):
            reasons.append("a " + kind + " name may hold no whitespace")
        if kind == "path":
            if name.startswith("/"):
                reasons.append("a path name has no leading slash")
            if _DOTDOT.search(name):
                reasons.append('a path name has no ".." segment')
    if reasons:
        unique = []
        for reason in reasons:
            if reason not in unique:
                unique.append(reason)
        return None, ("bad-contract", "token " + _echo(token) + " is not a usable contract name: " + "; ".join(unique))
    return (kind + ":" + name, ext), None


def _declared(entry, key):
    """The list under `key`, or (None, message) when it is not a list."""
    value = entry.get(key)
    if value is None:
        return [], None
    if not isinstance(value, list):
        return None, key + " must be an array of contract tokens"
    return value, None


def _layer(idxs, edges):
    """Kahn layering. Returns (waves, unplaced) -- unplaced is the cycle's nodes."""
    preds = {i: set() for i in idxs}
    for edge in edges:
        preds[edge["to"]].add(edge["from"])
    placed = set()
    waves = []
    remaining = set(idxs)
    while remaining:
        wave = sorted(i for i in remaining if preds[i] <= placed)
        if not wave:
            break
        waves.append(wave)
        placed.update(wave)
        remaining.difference_update(wave)
    return waves, sorted(remaining), preds


def _cycle_path(unplaced, preds):
    """One concrete cycle among the unplaced idxs, producer -> consumer order.

    Every unplaced node has at least one unplaced predecessor (otherwise Kahn
    would have placed it), so walking to the smallest unplaced predecessor
    repeats a node within len(unplaced) steps. The walk is deterministic.
    """
    live = set(unplaced)
    node = unplaced[0]
    seen = []
    while node not in seen:
        seen.append(node)
        node = sorted(p for p in preds[node] if p in live)[0]
    ring = seen[seen.index(node):]
    ring.reverse()  # the walk followed consumer <- producer; report producer -> consumer
    start = ring.index(min(ring))
    ring = ring[start:] + ring[:start]
    return ring + [ring[0]]


def validate_outline(outline):
    """Judge a parsed outline array and return the report dict."""
    errors = []
    idxs = []
    produced = {}   # key -> idx of its first producer
    consumed = []   # (consumer idx, key, ext)
    counts = {}
    seen_idx = set()

    for position, entry in enumerate(outline):
        if not isinstance(entry, dict):
            errors.append(_error("bad-idx", None, "entry " + str(position) + " is not an object, so it has no idx"))
            continue
        idx = entry.get("idx")
        if not isinstance(idx, str) or not _IDX.match(idx):
            errors.append(_error("bad-idx", idx if isinstance(idx, str) else None,
                                 "entry " + str(position) + " has idx " + _echo(idx) + ", which is not a two-digit string"))
            continue
        if idx in seen_idx:
            errors.append(_error("duplicate-idx", idx, "idx " + _echo(idx) + " is used by more than one entry"))
            continue
        seen_idx.add(idx)
        idxs.append(idx)

        produces, produces_problem = _declared(entry, "produces")
        consumes, consumes_problem = _declared(entry, "consumes")
        for key, problem in (("produces", produces_problem), ("consumes", consumes_problem)):
            if problem:
                errors.append(_error("bad-contract", idx, "entry " + idx + ": " + problem))
        produces = produces or []
        consumes = consumes or []
        counts[idx] = {"produces": len(produces), "consumes": len(consumes)}

        for token in produces:
            parsed, problem = parse_token(token, allow_ext=False)
            if problem:
                errors.append(_error(problem[0], idx, "entry " + idx + ": " + problem[1]))
                continue
            key = parsed[0]
            if key in produced:
                errors.append(_error(
                    "duplicate-produces", idx,
                    "name " + _echo(key) + " is produced by entry " + produced[key]
                    + " and again by entry " + idx,
                ))
            else:
                produced[key] = idx
        for token in consumes:
            parsed, problem = parse_token(token, allow_ext=True)
            if problem:
                errors.append(_error(problem[0], idx, "entry " + idx + ": " + problem[1]))
                continue
            consumed.append((idx, parsed[0], parsed[1]))

    edge_set = set()
    for consumer, key, ext in consumed:
        producer = produced.get(key)
        if ext:
            if producer is not None:
                errors.append(_error(
                    "external-also-produced", consumer,
                    "entry " + consumer + " consumes " + _echo("ext:" + key)
                    + " as already existing, but entry " + producer + " produces it",
                ))
            continue
        if producer is None:
            errors.append(_error(
                "unproduced-consume", consumer,
                "entry " + consumer + " consumes " + _echo(key)
                + ", which no entry produces and which is not marked ext:",
            ))
        elif producer == consumer:
            errors.append(_error(
                "self-consume", consumer,
                "entry " + consumer + " both produces and consumes " + _echo(key),
            ))
        else:
            edge_set.add((producer, consumer, key))

    edges = [{"from": a, "to": b, "name": n} for a, b, n in sorted(edge_set)]
    ordered = sorted(idxs)
    waves, unplaced, preds = _layer(ordered, edges)
    if unplaced:
        path = _cycle_path(unplaced, preds)
        errors.append(_error(
            "cycle", path[0],
            "entries depend on each other in a cycle: " + " -> ".join(path),
        ))

    valid = not errors
    return {
        "valid": valid,
        "errors": errors,
        "waves": waves if valid else [],
        "edges": edges,
        "counts": {i: counts[i] for i in sorted(counts)},
    }


# --- Outline shift --------------------------------------------------------

_TMP_PREFIX = ".outline-shift-"


def _load_outline_file(path, label):
    if not path:
        raise OutlineRefusal(label + " <path> is required")
    if not os.path.isfile(path):
        raise OutlineRefusal(label + " outline file does not exist: " + path)
    try:
        with open(path, encoding="utf-8") as handle:
            outline = json.load(handle)
    except (ValueError, OSError) as exc:
        raise OutlineRefusal(label + " outline is not valid JSON: " + path + " (" + str(exc) + ")")
    if not isinstance(outline, list):
        raise OutlineRefusal(label + " outline must be a JSON array of entries: " + path)
    entries = {}
    for position, item in enumerate(outline):
        if not isinstance(item, dict):
            raise OutlineRefusal(label + " outline entry " + str(position) + " is not an object")
        idx = item.get("idx")
        if not isinstance(idx, str) or not _IDX.match(idx):
            raise OutlineRefusal(label + " outline entry " + str(position) + " has idx " + _echo(idx) + ", not a two-digit string")
        if idx in entries:
            raise OutlineRefusal(label + " outline uses idx " + idx + " more than once")
        if not isinstance(item.get("title"), str):
            raise OutlineRefusal(label + " outline entry " + idx + " has no string title")
        entries[idx] = item
    return entries


def _contract(entry, key):
    """The names under `key` as a sorted list of opaque strings."""
    value = entry.get(key)
    if not isinstance(value, list):
        return []
    return sorted({item if isinstance(item, str) else json.dumps(item, sort_keys=True) for item in value})


def _strings_of(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, list):
        for item in node:
            yield from _strings_of(item)
    elif isinstance(node, dict):
        for item in node.values():
            yield from _strings_of(item)


def _rewrite_tokens(node, mapping, pattern):
    """Return (new node, changed) with every outline token renumbered in one pass."""
    if isinstance(node, str):
        def swap(match):
            return "outline:" + mapping.get(match.group(1), match.group(1))
        out = pattern.sub(swap, node)
        return out, out != node
    if isinstance(node, list):
        changed = False
        items = []
        for item in node:
            new, did = _rewrite_tokens(item, mapping, pattern)
            items.append(new)
            changed = changed or did
        return items, changed
    if isinstance(node, dict):
        changed = False
        out = {}
        for key, item in node.items():
            new, did = _rewrite_tokens(item, mapping, pattern)
            out[key] = new
            changed = changed or did
        return out, changed
    return node, False


def plan_shift(staging_dir, old_entries, new_entries):
    """Decide the whole shift in memory. Writes nothing; raises OutlineRefusal.

    Returns a plan dict: the report fields plus the file operations apply_shift
    carries out. Matching is by exact title; two entries sharing a title pair
    up in idx order.
    """
    from audit_patches import AuditRefusal, staged_idx_map
    from story_merge import OUTLINE_TOKEN

    try:
        staged = staged_idx_map(staging_dir)
    except AuditRefusal as refusal:
        raise OutlineRefusal(str(refusal))
    for idx in sorted(staged):
        if idx not in old_entries:
            raise OutlineRefusal(
                os.path.basename(staged[idx]) + " matches no entry of the --old outline (idx " + idx + ")"
            )

    by_title = {}
    for idx in sorted(new_entries):
        by_title.setdefault(new_entries[idx]["title"], []).append(idx)
    mapping = {}        # old idx -> new idx, for every matched entry
    removed = []
    for idx in sorted(old_entries):
        candidates = by_title.get(old_entries[idx]["title"])
        if candidates:
            mapping[idx] = candidates.pop(0)
        else:
            removed.append(idx)
    matched_new = set(mapping.values())
    new_only = sorted(i for i in new_entries if i not in matched_new)

    changed_contract = {}   # old idx -> True when produces or consumes differ
    produces_changed = {}   # old idx -> True when produces differ
    for old_idx, new_idx in mapping.items():
        o, n = old_entries[old_idx], new_entries[new_idx]
        produces_changed[old_idx] = _contract(o, "produces") != _contract(n, "produces")
        changed_contract[old_idx] = produces_changed[old_idx] or _contract(o, "consumes") != _contract(n, "consumes")

    # Who produces which name, before and after the edit.
    old_producers = {}
    for idx, entry in old_entries.items():
        for name in _contract(entry, "produces"):
            old_producers.setdefault(name, []).append(idx)
    new_producers = {}
    for idx, entry in new_entries.items():
        for name in _contract(entry, "produces"):
            new_producers.setdefault(name, []).append(idx)
    old_of_new = {n: o for o, n in mapping.items()}

    docs = {}
    for old_idx in sorted(staged):
        if old_idx in removed:
            continue
        path = staged[old_idx]
        try:
            with open(path, encoding="utf-8") as handle:
                doc = json.load(handle)
        except (OSError, ValueError, RecursionError) as exc:
            raise OutlineRefusal(os.path.basename(path) + " is not readable JSON (" + str(exc) + ")")
        if not isinstance(doc, dict):
            raise OutlineRefusal(os.path.basename(path) + " does not hold a story object")
        docs[old_idx] = doc

    reasons = {}
    for old_idx in sorted(mapping):
        new_idx = mapping[old_idx]
        why = []
        if old_idx in staged:
            cited = sorted({m.group(1) for s in _strings_of(docs[old_idx]) for m in OUTLINE_TOKEN.finditer(s)} & set(removed))
            if cited:
                why.append("cites removed entry " + ", ".join(cited))
        if changed_contract[old_idx]:
            why.append("its own produces/consumes changed")
        for name in _contract(new_entries[new_idx], "consumes"):
            if name.startswith("ext:"):
                continue
            for producer in old_producers.get(name, []):
                if producer in removed:
                    why.append("consumes " + name + ", produced by removed entry " + producer)
                elif produces_changed[producer]:
                    why.append("consumes " + name + ", produced by entry " + mapping[producer] + " whose produces changed")
            for producer in new_producers.get(name, []):
                if producer not in old_of_new:
                    why.append("consumes " + name + ", produced by new entry " + producer)
        if why:
            reasons[new_idx] = "; ".join(dict.fromkeys(why))

    reexpand = []
    expand = []
    for new_idx in sorted(new_entries):
        old_idx = old_of_new.get(new_idx)
        if old_idx is None or old_idx not in staged:
            expand.append(new_idx)
        elif new_idx in reasons:
            reexpand.append({"idx": new_idx, "reason": reasons[new_idx]})

    token_map = {o: n for o, n in mapping.items() if o != n}
    ops = []     # (old path, new basename, rewritten doc or None)
    renamed = []
    for old_idx in sorted(staged):
        if old_idx in removed:
            continue
        path = staged[old_idx]
        name = os.path.basename(path)
        new_idx = mapping[old_idx]
        new_name = new_idx + name[2:]
        doc, changed = _rewrite_tokens(docs[old_idx], token_map, OUTLINE_TOKEN)
        if new_name != name or changed:
            ops.append((path, new_name, doc if changed else None))
        if new_name != name:
            renamed.append({"from": old_idx, "to": new_idx, "file": new_name})
    deletions = [staged[i] for i in sorted(staged) if i in removed]

    touched = bool(ops or deletions or reexpand or expand)
    return {
        "report": {
            "renamed": renamed,
            "removed": removed,
            "reexpand": reexpand,
            "expand": expand,
            "auditInvalidated": touched,
        },
        "ops": ops,
        "deletions": deletions,
    }


def apply_shift(staging_dir, plan):
    """Carry out a plan_shift plan. Files move in two phases so chains cannot collide.

    A failure before the deletions restores every file it had moved; one after
    them cannot bring a deleted file back, which is why plan_shift decides every
    refusal first.
    """
    moved = []   # (temporary path, original path), for the rollback
    try:
        # Phase 1: every file that has to move or change leaves its name.
        staged_ops = []
        for position, (path, new_name, doc) in enumerate(plan["ops"]):
            temp = os.path.join(staging_dir, _TMP_PREFIX + str(position) + ".tmp")
            os.rename(path, temp)
            moved.append((temp, path))
            if doc is not None:
                fd, scratch = tempfile.mkstemp(prefix=_TMP_PREFIX, suffix=".new", dir=staging_dir)
                try:
                    with os.fdopen(fd, "w", encoding="utf-8") as handle:
                        handle.write(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
                    os.replace(scratch, temp)
                except BaseException:
                    if os.path.exists(scratch):
                        os.unlink(scratch)
                    raise
            staged_ops.append((temp, os.path.join(staging_dir, new_name)))
        for path in plan["deletions"]:
            os.remove(path)
        # Phase 2: every file arrives at its final name.
        for temp, final in staged_ops:
            os.replace(temp, final)
    except BaseException:
        for temp, original in moved:
            if os.path.exists(temp):
                try:
                    os.replace(temp, original)
                except OSError:
                    pass
        raise
    if plan["report"]["auditInvalidated"]:
        audit = os.path.join(staging_dir, "audit-result.json")
        if os.path.lexists(audit):
            os.remove(audit)


def shift_main(args):
    allowed = ("--shift", "--staging-dir", "--old", "--new")
    for arg in args:
        if arg.startswith("--") and arg not in allowed:
            raise OutlineRefusal("unknown flag: " + arg)
    staging_dir = _flag(args, "--staging-dir")
    if not staging_dir:
        raise OutlineRefusal("--staging-dir <dir> is required")
    if not os.path.isdir(staging_dir):
        raise OutlineRefusal("staging directory does not exist: " + staging_dir)
    old_entries = _load_outline_file(_flag(args, "--old"), "--old")
    new_entries = _load_outline_file(_flag(args, "--new"), "--new")
    plan = plan_shift(staging_dir, old_entries, new_entries)
    try:
        apply_shift(staging_dir, plan)
    except OSError as exc:
        raise OutlineRefusal("could not move the staged files (" + str(exc) + ")")
    return plan["report"]


# --- Entry point ----------------------------------------------------------


def _flag(args, name):
    if name in args:
        position = args.index(name)
        if position + 1 < len(args):
            return args[position + 1]
    return ""


def _load(args):
    for arg in args:
        if arg.startswith("--") and arg != "--outline":
            raise OutlineRefusal("unknown flag: " + arg)
    path = _flag(args, "--outline")
    if not path:
        raise OutlineRefusal("--outline <path> is required")
    if not os.path.isfile(path):
        raise OutlineRefusal("outline file does not exist: " + path)
    try:
        with open(path, encoding="utf-8") as handle:
            outline = json.load(handle)
    except (ValueError, OSError) as exc:
        raise OutlineRefusal("outline is not valid JSON: " + path + " (" + str(exc) + ")")
    if not isinstance(outline, list):
        raise OutlineRefusal("outline must be a JSON array of entries: " + path)
    return outline


def main(argv):
    if "--shift" in argv[1:]:
        try:
            report = shift_main(argv[1:])
        except OutlineRefusal as refusal:
            sys.stderr.write("Error: outline-shift: " + str(refusal) + "\n")
            return 1
        sys.stdout.write(json.dumps(report, ensure_ascii=False) + "\n")
        return 0
    try:
        outline = _load(argv[1:])
    except OutlineRefusal as refusal:
        sys.stderr.write("Error: validate-outline: " + str(refusal) + "\n")
        return 1
    report = validate_outline(outline)
    sys.stdout.write(json.dumps(report, ensure_ascii=False) + "\n")
    return 0 if report["valid"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
