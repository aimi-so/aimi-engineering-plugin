#!/usr/bin/env python3
"""bookkeeping_rules: resolve a conflicted bookkeeping file by a declared rule.

WHAT THIS MODULE IS FOR
=======================

Some files change on every branch in a mechanical way: a changelog gains a
bullet, a manifest gains a version, a test script's assertion total moves, a size
baseline row grows. When two branches touch the same such file, the conflict has
exactly one right answer that needs no judgment. `resolve_by_rule` turns the
three versions of the file into that one merged text, or into a structured
`RuleRefusal` saying why the rule cannot answer and the file falls to a person.

The module is pure. It imports nothing that touches the filesystem, git or a
subprocess, and takes every file version as a `str`, or `None` when that side
has no file. What the merged tree measures (for `size-step`) comes in through
the injected `measure` callable; the caller decides, this module never reads a
disk.

THE FOUR RULES
==============

    union-lines   whole-line set union, order-preserving, idempotent
    max-version   the highest dotted-numeric version on a conflicting line
    sum-delta     ours + theirs - base on the one integer of a conflicting line
    size-step     the smallest multiple of 4096 covering the measured size

`max-version`, `sum-delta` and `size-step` share one three-way line walk: per
line, equal sides keep it, a side equal to base yields to the other, and only a
line both sides changed is handed to the rule's claim test. The file is resolved
only when the rule claims EVERY such line; one it cannot claim, or a line-count
mismatch between the versions, refuses the whole file as 'unclaimed' and no
partial text is returned. `union-lines` does not use the walk and applies its own
whole-file claim.

THE CHANGES LIST
================

`Resolution.changes` is a list of `{line, before, after}` describing how the
merged text differs from OURS: `line` is the 1-based line in the merged text,
`before` is ours' line there (`None` for a line the merge inserted) and `after`
is the merged line.

REFUSALS
========

`RuleRefusal.kind` is 'unclaimed' (the rule does not claim every conflicting
line, so the whole file falls to judgment) or 'unproducible' (the rule cannot
produce a result). A caller branches on `kind`, never on `reason` text. An
unknown rule is a programming error and raises `ValueError`, not `RuleRefusal`.
"""

import re
from dataclasses import dataclass, field

RULE_KINDS = ("union-lines", "max-version", "sum-delta", "size-step")

REFUSAL_KINDS = ("unclaimed", "unproducible")

SIZE_STEP = 4096
SIZE_FLOOR = 16384  # a size at or under this has no baseline row


class RuleRefusal(Exception):
    """The rule could not resolve the file. Branch on `kind`, not `reason`."""

    def __init__(self, path, rule, reason, kind):
        if kind not in REFUSAL_KINDS:
            raise ValueError(
                "RuleRefusal kind must be one of %r, got %r" % (REFUSAL_KINDS, kind)
            )
        super().__init__("%s: rule %s refused (%s): %s" % (path, rule, kind, reason))
        self.path = path
        self.rule = rule
        self.reason = reason
        self.kind = kind


@dataclass(frozen=True)
class Resolution:
    text: str
    changes: list = field(default_factory=list)


class _Conflicted:
    """Sentinel a `measure` returns when the measured file is itself conflicted."""

    def __repr__(self):
        return "CONFLICTED"


CONFLICTED = _Conflicted()


class _Refuse(Exception):
    """Internal: a claim test refusing; resolve_by_rule adds path and rule."""

    def __init__(self, kind, reason):
        super().__init__(reason)
        self.kind = kind
        self.reason = reason


# --------------------------------------------------------------------------
# Text <-> lines
# --------------------------------------------------------------------------


def _split(text):
    """Return (lines, ends_with_newline). Blank lines are ordinary lines."""
    if text == "":
        return [], False
    if text.endswith("\n"):
        return text[:-1].split("\n"), True
    return text.split("\n"), False


def _join(lines, final_newline):
    if not lines:
        return ""
    return "\n".join(lines) + ("\n" if final_newline else "")


def _decodable(text):
    try:
        text.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return True


# --------------------------------------------------------------------------
# The shared three-way walk
# --------------------------------------------------------------------------


def _walk(base, ours, theirs, claim):
    """Resolve by the three-way line walk; `claim(b, o, t)` returns the new line.

    Returns (lines, final_newline). A line-count mismatch is 'unclaimed'.
    """
    b_lines, _ = _split(base)
    o_lines, o_nl = _split(ours)
    t_lines, t_nl = _split(theirs)
    if not (len(b_lines) == len(o_lines) == len(t_lines)):
        raise _Refuse(
            "unclaimed",
            "line count differs between versions (base %d, ours %d, theirs %d)"
            % (len(b_lines), len(o_lines), len(t_lines)),
        )
    merged = []
    for b, o, t in zip(b_lines, o_lines, t_lines):
        if o == t:
            merged.append(o)
        elif o == b:
            merged.append(t)
        elif t == b:
            merged.append(o)
        else:
            merged.append(claim(b, o, t))
    return merged, (o_nl or t_nl)


def _changes_against(ours_lines, merged_lines):
    changes = []
    for i, after in enumerate(merged_lines):
        before = ours_lines[i] if i < len(ours_lines) else None
        if before != after:
            changes.append({"line": i + 1, "before": before, "after": after})
    return changes


# --------------------------------------------------------------------------
# union-lines
# --------------------------------------------------------------------------


def _union_lines(base, ours, theirs):
    b_lines, _ = _split(base) if base is not None else ([], False)
    o_lines, o_nl = _split(ours)
    t_lines, t_nl = _split(theirs)
    o_set, t_set = set(o_lines), set(t_lines)
    for line in b_lines:
        if line not in o_set or line not in t_set:
            raise _Refuse(
                "unclaimed",
                "a side removed or changed a base line: %r" % (line,),
            )

    result = [(line, False) for line in o_lines]
    inserted = set()
    cursor = 0  # result index just past the last shared line matched
    run = []

    def flush():
        nonlocal cursor, run
        if not run:
            return
        pos = cursor
        while pos < len(result) and result[pos][0] not in t_set:
            pos += 1  # ours-only lines at this spot stay first
        result[pos:pos] = [(r, True) for r in run]
        cursor = pos + len(run)
        run = []

    for line in t_lines:
        if line in o_set:
            flush()
            idx = _find(result, line, cursor)
            if idx is None:
                idx = _find(result, line, 0)
            cursor = idx + 1
        elif line not in inserted:
            run.append(line)
            inserted.add(line)
    flush()

    lines = [line for line, _ in result]
    changes = [
        {"line": n + 1, "before": None, "after": line}
        for n, (line, new) in enumerate(result)
        if new
    ]
    return _join(lines, o_nl or t_nl), changes


def _find(result, line, start):
    for k in range(start, len(result)):
        if result[k][0] == line:
            return k
    return None


# --------------------------------------------------------------------------
# max-version
# --------------------------------------------------------------------------

_JSON_VERSION = re.compile(r'^(\s*"version"\s*:\s*")([^"]*)("\s*,?\s*)$')
_BARE_VERSION = re.compile(r"^(\s*)([0-9][0-9A-Za-z.+\-]*)(\s*)$")
_DOTTED = re.compile(r"^[0-9]+(\.[0-9]+)*$")


def _version_line(line):
    """Return (form, prefix, version, suffix) or None when not a version line."""
    m = _JSON_VERSION.match(line)
    if m:
        return ("json", m.group(1), m.group(2), m.group(3))
    m = _BARE_VERSION.match(line)
    if m:
        return ("bare", m.group(1), m.group(2), m.group(3))
    return None


def _parse_version(text):
    if not _DOTTED.match(text):
        raise _Refuse("unproducible", "unparseable version %r" % (text,))
    return tuple(int(p) for p in text.split("."))


def _claim_max_version(b, o, t):
    po, pt = _version_line(o), _version_line(t)
    if po is None or pt is None:
        raise _Refuse("unclaimed", "not a version line: %r / %r" % (o, t))
    if po[0] != pt[0] or po[1] != pt[1] or po[3] != pt[3]:
        raise _Refuse("unclaimed", "version line differs beyond the version")
    vo, vt = _parse_version(po[2]), _parse_version(pt[2])
    if len(vo) != len(vt):
        raise _Refuse(
            "unproducible",
            "versions have different part counts: %r / %r" % (po[2], pt[2]),
        )
    return t if vt > vo else o


# --------------------------------------------------------------------------
# sum-delta
# --------------------------------------------------------------------------

_NUMBER = re.compile(r"[0-9]+(?:\.[0-9]+)*")


def _split_integer(line):
    """Return (skeleton, int) for a line holding exactly one integer token."""
    tokens = list(_NUMBER.finditer(line))
    if not tokens:
        raise _Refuse("unproducible", "no integer on line %r" % (line,))
    if len(tokens) > 1:
        raise _Refuse("unclaimed", "more than one number on line %r" % (line,))
    m = tokens[0]
    if "." in m.group(0):
        raise _Refuse("unproducible", "non-integer %r on line" % (m.group(0),))
    return (line[: m.start()], line[m.end() :]), int(m.group(0))


def _claim_sum_delta(b, o, t):
    if not any(_NUMBER.search(x) for x in (b, o, t)):
        raise _Refuse("unclaimed", "no integer on a conflicting line")
    sk_b, n_b = _split_integer(b)
    sk_o, n_o = _split_integer(o)
    sk_t, n_t = _split_integer(t)
    if not (sk_b == sk_o == sk_t):
        raise _Refuse("unclaimed", "line differs beyond its integer")
    total = n_o + n_t - n_b
    if total < 0:
        raise _Refuse("unproducible", "negative total %d" % total)
    return "%s%d%s" % (sk_o[0], total, sk_o[1])


# --------------------------------------------------------------------------
# size-step
# --------------------------------------------------------------------------


def _row(line):
    path, sep, budget = line.partition("\t")
    if not sep or not path or not budget.strip().isdigit():
        raise _Refuse("unclaimed", "not a '<path><TAB><budget>' row: %r" % (line,))
    return path


def _make_size_claim(measure):
    def claim(b, o, t):
        path_o, path_t = _row(o), _row(t)
        if path_o != path_t:
            raise _Refuse("unclaimed", "the sides name different paths")
        if measure is None:
            raise _Refuse("unproducible", "no measure given for %s" % path_o)
        size = measure(path_o)
        if size is CONFLICTED:
            raise _Refuse("unclaimed", "%s is itself still conflicted" % path_o)
        if size is None:
            raise _Refuse("unproducible", "%s could not be measured" % path_o)
        if isinstance(size, bool) or not isinstance(size, int) or size < 0:
            raise _Refuse("unproducible", "measure returned %r" % (size,))
        if size <= SIZE_FLOOR:
            raise _Refuse(
                "unclaimed",
                "%s measures %d, at or under %d: the row would be dropped"
                % (path_o, size, SIZE_FLOOR),
            )
        budget = -(-size // SIZE_STEP) * SIZE_STEP
        return "%s\t%d" % (path_o, budget)

    return claim


# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------


def resolve_by_rule(rule, path, base, ours, theirs, measure=None):
    """Resolve the conflicted file `path` by `rule`; return a Resolution.

    `base`, `ours` and `theirs` are `str`, or `None` when that side has no file.
    Raises `ValueError` for an unknown rule and `RuleRefusal` when the rule
    cannot resolve the file.
    """
    if rule not in RULE_KINDS:
        raise ValueError("unknown rule %r; expected one of %r" % (rule, RULE_KINDS))

    def refuse(kind, reason):
        return RuleRefusal(path, rule, reason, kind)

    for name, side in (("base", base), ("ours", ours), ("theirs", theirs)):
        if side is None:
            continue
        if not isinstance(side, str) or not _decodable(side):
            raise refuse("unproducible", "the %s version is undecodable" % name)

    try:
        if rule == "union-lines":
            # Only add/add (no base file, both sides present) or a present
            # base with both sides present is a case this rule can resolve.
            if ours is None or theirs is None:
                raise _Refuse("unproducible", "a side has no file")
            text, changes = _union_lines(base, ours, theirs)
            return Resolution(text=text, changes=changes)

        if base is None or ours is None or theirs is None:
            raise _Refuse("unproducible", "a side has no file")
        if rule == "max-version":
            claim = _claim_max_version
        elif rule == "sum-delta":
            claim = _claim_sum_delta
        else:
            claim = _make_size_claim(measure)
        merged, final_nl = _walk(base, ours, theirs, claim)
        o_lines, _ = _split(ours)
        return Resolution(
            text=_join(merged, final_nl),
            changes=_changes_against(o_lines, merged),
        )
    except _Refuse as r:
        raise refuse(r.kind, r.reason) from None
