#!/usr/bin/env python3
"""The usage-validation record: its vocabulary, its checks and how one is built.

WHY THIS IS A MODULE OF ITS OWN
===============================

Two writers store the same record in two places by scope: roadmap.py's
`record-usage-validation` writes a phase's `phases[].usageValidation`, and
tasks.py's `usage-validation-record` writes a flat run's
`metadata.usageValidation`. Each used to carry its own copy of the constants,
the --findings-json parser, the flag checks, the accepted-findings carry-over,
the cap and the build, kept equal by hand. This module is the one copy; it
imports only the standard library and sanitize.py, the way sanitize.py itself is
shared, so neither writer owns the rule and neither imports the other.

A writer does three things with it, in this order:

1. `parse_request(argv, prefix)` before the document is read, so every
   vocabulary refusal happens without opening the file. `prefix` is the
   writer's own `Error: <verb>: ` text, so each refusal keeps its message.
2. Read the document and find the stored record (the previous one, or None).
3. `build_record(request, previous)` and write the record it returns in place
   of the stored one.
"""

import json
import re
import sys
import time

from sanitize import rm_sanitize


STATUSES = ("passed", "failing", "skipped")
KINDS = ("not-applicable", "unable-to-evaluate", "disabled-by-operator")
FINDING_STATUSES = ("open", "fixed", "accepted")
REASON_MAXLEN = 2000
FINDING_REASON_MAXLEN = 500
FINDINGS_MAX = 200
FINDING_KEY = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")


def _die(message):
    sys.stderr.write(message + "\n")
    sys.exit(1)


def _flag(argv, name):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return None


def parse_findings(raw, prefix):
    """Parse and check --findings-json: {key: {status, reason?}}. Dies naming the flag."""
    try:
        parsed = json.loads(raw)
    except ValueError:
        _die(prefix + "--findings-json is not valid JSON")
    if not isinstance(parsed, dict):
        _die(prefix + "--findings-json must be a JSON object")
    findings = {}
    for key, entry in parsed.items():
        if not FINDING_KEY.match(key):
            _die(prefix + "--findings-json key is not allowed: " + key)
        if not isinstance(entry, dict) or entry.get("status") not in FINDING_STATUSES:
            _die(
                prefix + "--findings-json entry '" + key + "' needs a status of "
                + "|".join(FINDING_STATUSES)
            )
        reason = entry.get("reason")
        if reason is not None and not isinstance(reason, str):
            _die(prefix + "--findings-json reason of '" + key + "' must be a string")
        clean = rm_sanitize(reason, FINDING_REASON_MAXLEN) if reason else ""
        if entry["status"] == "accepted" and not clean.strip():
            _die(prefix + "--findings-json entry '" + key + "' is accepted and needs a reason")
        built = {"status": entry["status"]}
        if clean.strip():
            built["reason"] = clean
        findings[key] = built
    return findings


def parse_request(argv, prefix):
    """Every vocabulary rule of a record write, before any document is read.

    Returns the request a later build_record turns into a record. Dies with the
    writer's own prefix on the first rule broken."""
    status = _flag(argv, "--status")
    if status not in STATUSES:
        _die(prefix + "--status must be one of " + "|".join(STATUSES) + ", got: " + str(status or ""))
    kind = _flag(argv, "--kind") if "--kind" in argv else None
    if kind is not None and kind not in KINDS:
        _die(prefix + "--kind must be one of " + "|".join(KINDS) + ", got: " + kind)
    if status == "skipped" and kind is None:
        _die(prefix + "--kind is required with --status skipped")
    if status != "skipped" and kind is not None:
        _die(prefix + "--kind is only allowed with --status skipped")
    raw_reason = _flag(argv, "--reason")
    clean_reason = rm_sanitize(raw_reason, REASON_MAXLEN) if raw_reason else ""
    if status in ("failing", "skipped") and not clean_reason.strip():
        _die(prefix + "--reason is required with --status " + status)
    rounds = 0
    if "--rounds" in argv:
        raw_rounds = _flag(argv, "--rounds")
        if raw_rounds is None or not re.fullmatch(r"[0-9]+", raw_rounds):
            _die(prefix + "--rounds must be a non-negative integer, got: " + str(raw_rounds or ""))
        rounds = int(raw_rounds)
    findings = {}
    if "--findings-json" in argv:
        findings = parse_findings(_flag(argv, "--findings-json") or "", prefix)
    return {
        "status": status,
        "kind": kind,
        "reason": clean_reason if clean_reason.strip() else "",
        "review": _flag(argv, "--review"),
        "rounds": rounds,
        "findings": findings,
    }


def build_record(request, previous):
    """The record that replaces `previous`, with the previous record's accepted
    findings that the request does not restate carried over, capped at
    FINDINGS_MAX entries."""
    merged = dict(request["findings"])
    previous_findings = previous.get("findings") if isinstance(previous, dict) else None
    if isinstance(previous_findings, dict):
        for key, entry in previous_findings.items():
            if key not in merged and isinstance(entry, dict) and entry.get("status") == "accepted":
                merged[key] = entry
    merged = dict(list(merged.items())[:FINDINGS_MAX])

    record = {"status": request["status"]}
    if request["kind"] is not None:
        record["kind"] = request["kind"]
    if request["reason"]:
        record["reason"] = request["reason"]
    if request["review"]:
        record["review"] = request["review"]
    record["rounds"] = request["rounds"]
    if merged:
        record["findings"] = merged
    record["recordedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    return record

