"""The completed screen stories a run never checked against the running product.

The module behind `unverified-screens`. It answers one question from the tasks
file(s) and the record(s) beside them, read-only, so a run that skipped usage
validation cannot close looking like a pass while a screen nobody looked at is
in it:

  phase --roadmap <path> --feature <slug> --phase <id>
        a roadmap phase; every member of a split phase is read
  files --tasks-file <path> --project-root <path>
        one tasks file: a flat run, or a phase-scoped file followed to its
        roadmap phase for the gate and the usage record

Both print one JSON object:

  count, scope, feature, phase, visualGate, usageValidation, reason, stories

THE RULE, in the order it is applied:

  1. A stored usage-validation record whose status is passed or failing answers
     count 0 with a reason naming that status, whatever the gate says. The
     product was used; this check has nothing to add.
  2. Otherwise a phase visual gate of passed or accepted answers count 0 with a
     reason naming the gate: the live implementation was compared as a whole.
  3. Otherwise every COMPLETED screen story (usage_validation.is_screen_story)
     whose own verification is not a passed visual verdict is listed:

       cause "no-visual-check"    a test-strategy story with a web url; no
                                  visual verdict was ever possible for it
       cause "visual-not-passed"  a visual story whose verification.status is
                                  not passed (pending, skipped, failed)

A visual story with status passed has a verdict and is not listed. The word
passed appears in no entry field but `title`: the cause vocabulary keeps a test
story's passed result out of every visual field, so a caller can print the list
with no pass line beside a screen nobody saw.

IMPORT ORDER. This module imports `roadmap` and `usage_validation` at module
scope and `tasks` inside the function, as usage_validation.py does, because
tasks.py imports roadmap.py at its own module scope.
"""

import json
import os
import sys

import roadmap as R
from sanitize import rm_sanitize
from usage_validation import is_screen_story, _stories

VERB = "unverified-screens"
TITLE_MAXLEN = 200
REASON_MAXLEN = 500
USAGE_STATUSES = ("passed", "failing", "skipped")
CAUSE_NO_CHECK = "no-visual-check"
CAUSE_NOT_PASSED = "visual-not-passed"


def _die(message):
    sys.stderr.write("Error: " + VERB + ": " + message + "\n")
    sys.exit(1)


def _advise(detail):
    sys.stderr.write("Advisory: " + VERB + ": " + detail + "\n")


def _clean(value, maxlen):
    return rm_sanitize(value, maxlen) if isinstance(value, str) else ""


def _text_or_none(value, maxlen):
    cleaned = _clean(value, maxlen)
    return cleaned if cleaned.strip() else None


def _flag(argv, name):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return None


def _emit(value):
    json.dump(value, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")


def _usage(record):
    """{status, kind, reason} of a stored usage-validation record. A value that
    is not an object, or whose status is not one of the three, reads as
    not-recorded: this verb never trusts a half-written record into a pass."""
    status = record.get("status") if isinstance(record, dict) else None
    if status not in USAGE_STATUSES:
        return {"status": "not-recorded", "kind": None, "reason": None}
    return {
        "status": status,
        "kind": _text_or_none(record.get("kind"), 40),
        "reason": _text_or_none(record.get("reason"), REASON_MAXLEN),
    }


def _gate_status(phase):
    record = phase.get("visualGate") if isinstance(phase, dict) else None
    status = record.get("status") if isinstance(record, dict) else None
    return status if isinstance(status, str) and status != "" else None


def _entries(read, usage):
    """The listed stories of every readable member, in member then document
    order."""
    from tasks import _report_project

    skip = {"status": usage["status"], "kind": usage["kind"], "reason": usage["reason"]}
    entries = []
    for _path, tasks in read:
        done = set(i for i in R._completed_story_ids(tasks) if isinstance(i, str))
        for story in _stories(tasks):
            sid = story.get("id")
            if not isinstance(sid, str) or sid not in done or not is_screen_story(story):
                continue
            verification = story["verification"]
            if verification.get("strategy") == "visual":
                status = verification.get("status")
                if status == "passed":
                    continue
                cause = CAUSE_NOT_PASSED
                visual_status = status if isinstance(status, str) else None
                skip_reason = _text_or_none(verification.get("skipReason"), REASON_MAXLEN)
            else:
                cause, visual_status, skip_reason = CAUSE_NO_CHECK, None, None
            entries.append({
                "id": sid,
                "title": _clean(story.get("title"), TITLE_MAXLEN),
                "project": _report_project(story) or ".",
                "cause": cause,
                "visualStatus": visual_status,
                "skipReason": skip_reason,
                "usageSkip": dict(skip),
            })
    return entries


def _answer(scope, feature, phase_id, gate, usage_record, read):
    usage = _usage(usage_record)
    stories = []
    if usage["status"] in ("passed", "failing"):
        reason = ("a usage validation record with status " + usage["status"]
                  + " is stored, so no screen is reported as unverified")
    elif gate in ("passed", "accepted"):
        reason = "the phase visual gate is " + gate + ", so no screen is reported as unverified"
    else:
        stories = _entries(read, usage)
        why = ("usage validation was skipped" + (" (" + usage["kind"] + ")" if usage["kind"] else "")
               if usage["status"] == "skipped" else "no usage validation was recorded")
        if stories:
            reason = (str(len(stories)) + " completed screen story(ies) have no visual verdict and "
                      + why)
        else:
            reason = "no completed screen story lacks a visual verdict (" + why + ")"
    return {
        "count": len(stories),
        "scope": scope,
        "feature": feature,
        "phase": phase_id,
        "visualGate": gate,
        "usageValidation": usage,
        "reason": _clean(reason, REASON_MAXLEN),
        "stories": stories,
    }


def _read_members(paths, label):
    read = []
    for path in paths:
        tasks, why = R._read_tasks_with_reason(path)
        if tasks is None or not isinstance(tasks, dict):
            _advise(label + " could not read " + path + " -- " + (why or "not an object"))
            continue
        read.append((path, tasks))
    if not read:
        _die(label + " has no readable tasks file")
    return read


def _find_phase(doc, phase_id, roadmap_path):
    if not isinstance(doc, dict):
        _die("malformed roadmap.json: " + roadmap_path)
    phase = next((p for p in (doc.get("phases") or []) if isinstance(p, dict) and p.get("id") == phase_id), None)
    if phase is None:
        _die("phase " + R._num(phase_id) + " not found in " + roadmap_path)
    return phase


def _op_phase(argv):
    path = _flag(argv, "--roadmap")
    feature = _flag(argv, "--feature")
    phase_raw = _flag(argv, "--phase")
    if not path or phase_raw is None or feature is None:
        sys.stderr.write("Usage: unverified_screens.py phase --roadmap <path> --feature <slug> --phase <id>\n")
        return 2
    doc = R.read_doc(path, VERB)
    try:
        phase_id = R.jq_numbers(json.loads(phase_raw))
    except ValueError:
        _die("--phase <id> must be a numeric phase id")
    phase = _find_phase(doc, phase_id, path)
    members = R._completed_gate_resolve_members(path, doc, phase)
    read = _read_members(members, "phase " + R._num(phase_id))
    _emit(_answer("phase", feature, phase_id, _gate_status(phase), phase.get("usageValidation"), read))
    return 0


def _op_files(argv):
    path = _flag(argv, "--tasks-file")
    project_root = _flag(argv, "--project-root")
    if not path or not project_root:
        sys.stderr.write("Usage: unverified_screens.py files --tasks-file <path> --project-root <path>\n")
        return 2
    tasks, why = R._read_tasks_with_reason(path)
    if tasks is None or not isinstance(tasks, dict):
        _die("cannot read tasks file " + path + " -- " + (why or "not an object"))
    metadata = tasks.get("metadata")
    metadata = metadata if isinstance(metadata, dict) else {}
    read = [(path, tasks)]

    phase_meta = metadata.get("phase")
    if phase_meta is None:
        record = metadata.get("usageValidation")
        _emit(_answer("flat", None, None, None, record, read))
        return 0

    # A phase-scoped file is followed to its roadmap phase for the gate and the
    # usage record, the way usage-validation-get follows it.
    from tasks import confined_spec_path

    raw_id = phase_meta.get("id") if isinstance(phase_meta, dict) else None
    if isinstance(raw_id, bool) or not isinstance(raw_id, (int, float)):
        _die("metadata.phase.id is not a number in " + path)
    phase_id = R.jq_numbers(raw_id)
    roadmap_rel = metadata.get("roadmapPath")
    if not (isinstance(roadmap_rel, str) and roadmap_rel):
        roadmap_rel = os.path.relpath(
            os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(path))), "roadmap.json"),
            project_root,
        )
    roadmap_path, inside = confined_spec_path(project_root, roadmap_rel)
    if not inside:
        _die("the roadmap path escapes the project: " + roadmap_rel)
    feature = os.path.basename(os.path.dirname(roadmap_path))
    doc = R.read_doc(roadmap_path, VERB)
    phase = _find_phase(doc, phase_id, roadmap_path)
    _emit(_answer("phase", feature, phase_id, _gate_status(phase), phase.get("usageValidation"), read))
    return 0


_OPS = {"phase": _op_phase, "files": _op_files}


def main(argv):
    if len(argv) < 2 or argv[1] not in _OPS:
        sys.stderr.write("Usage: unverified_screens.py <" + "|".join(sorted(_OPS)) + "> [flags]\n")
        return 2
    return _OPS[argv[1]](argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
