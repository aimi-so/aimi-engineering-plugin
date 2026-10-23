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

IMPORT SAFETY
=============

roadmap.py imports only sanitize at module level and defers its tasks import
into functions, so importing it here loads none of tasks, story_merge or
audit_patches. This module must never import those three: it is the pure-logic
end of the planning verbs and stays out of the tasks -> story_merge ->
audit_patches chain.
"""

import json
import os
import re
import sys

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
