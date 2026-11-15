"""Whether usage validation is owed for a phase or a flat run.

The module behind `usage-validation-required`. It answers one question from the
tasks file(s) alone, read-only, so no execute step decides it from prose and
every skip says why:

  required --roadmap <path> --phase <id>   a phase (every member of a split one)
  files    --tasks-file <path>...          a flat run

Both print one JSON object:

  required, skipKind, reason, surfaceSource, askUndeclared, members, projects,
  recipeRecorded, surfaces, charters, specs

`members` counts the tasks files that were READ (a split phase counts each);
`projects` is the sorted distinct story `project`, `.` when a story has none.
They are different measures, and neither is called "groups".

The skip is chosen in a fixed order, first match winning, after surfaces and
charters have been built from every readable member (so a skipped answer still
names what stayed unvalidated):

  1. AIMI_USAGE_VALIDATION=off            -> disabled-by-operator
  2. no readable member                   -> unable-to-evaluate
  3. no surface                           -> not-applicable (an unreadable
                                             member makes it unable-to-evaluate)
  4. a surface with no recorded recipe    -> unable-to-evaluate
  5. otherwise                            -> required

IMPORT ORDER. This module imports `roadmap` at module scope and `tasks` inside
the function, because tasks.py imports roadmap.py at its own module scope.
roadmap.py must therefore import THIS module inside a function, never at module
scope, or the three would form a cycle.

The recipe is read through `usage_recipe.get`, the reader behind
`usage-recipe-get`; this module never opens `.aimi/config.json` itself. A
surface with a project whose recipe is absent, untrusted or unreadable counts as
"no recipe recorded".
"""

import json
import os
import re
import sys

import roadmap as R
from sanitize import rm_sanitize
import usage_recipe as U

VERB = "usage-validation-required"
SURFACE_KINDS = ("web", "cli")
TITLE_MAXLEN = 200
REASON_MAXLEN = 500
ENV_SWITCH = "AIMI_USAGE_VALIDATION"

VERDICT_VERB = "usage-validation-verdict"
VERDICT_TAG = "usage_validation_verdict"
FENCE = "```"
MAX_CHARTERS = 100
MAX_FINDINGS = 200
MAX_EVIDENCE = 10
HEURISTICS = tuple("H" + str(n) for n in range(1, 11)) + ("S", "F", "D", "P", "O", "T")
FINDING_KINDS = ("bug", "decision", "unmapped")
EVIDENCE_TYPES = ("screenshot", "console", "network", "command")
RATINGS = ("severity", "frequency", "impact", "persistence")
TEXT_MAXLEN = 1000
KEY_PATTERN = re.compile(r"^[^:/\s]+:[1-9][0-9]*:(?:H10|H[1-9]|S|F|D|P|O|T)$")
# A validator lists every origin it contacted, a live-reload socket included.
ORIGIN_SCHEMES = U.WEB_SCHEMES + U.SOCKET_SCHEMES


def _advise(detail):
    """One stderr line in the 'Advisory: <verb>: ...' shape. roadmap's own
    _completed_gate_advise hard-codes `roadmap-set-status`, so it is not reused."""
    sys.stderr.write("Advisory: " + VERB + ": " + detail + "\n")


def _clean(value, maxlen):
    return rm_sanitize(value, maxlen) if isinstance(value, str) else ""


def _aimi_root(anchor):
    """The directory holding `.aimi/`, found by walking up from <anchor>;
    the current directory when there is none."""
    path = os.path.dirname(os.path.abspath(anchor))
    while True:
        if os.path.basename(path) == ".aimi":
            return os.path.dirname(path)
        parent = os.path.dirname(path)
        if parent == path:
            return os.getcwd()
        path = parent


def _recipe_recorded(root, project):
    """True when usage-recipe-get would answer `recorded` for <project>."""
    try:
        answer = U.get(os.path.join(root, ".aimi", "config.json"), project)
    except (U.Refusal, OSError):
        return False
    return answer.get("status") == "recorded"


def _stories(tasks):
    stories = tasks.get("userStories") if isinstance(tasks, dict) else None
    if isinstance(stories, dict):
        stories = list(stories.values())
    if not isinstance(stories, list):
        return []
    return [s for s in stories if isinstance(s, dict)]


def _declared(metadata):
    """The declared usageSurfaces of one member: None when the key is absent,
    otherwise the list of well-formed entries (possibly empty)."""
    if not isinstance(metadata, dict) or "usageSurfaces" not in metadata:
        return None
    raw = metadata.get("usageSurfaces")
    if not isinstance(raw, list):
        _advise("metadata.usageSurfaces is not a list, read as a declared none")
        return []
    entries = []
    for entry in raw:
        if not isinstance(entry, dict):
            _advise("a usageSurfaces entry is not an object, dropped")
            continue
        kind = entry.get("kind")
        if kind not in SURFACE_KINDS:
            _advise("a usageSurfaces entry of kind " + repr(_clean(kind, 40) if isinstance(kind, str) else kind)
                    + " is neither web nor cli, dropped")
            continue
        stories = entry.get("stories")
        if not isinstance(stories, list):
            _advise("a usageSurfaces entry names no stories list, dropped")
            continue
        copy = dict(entry)
        copy["source"] = "declared"
        entries.append(copy)
    return entries


def _spec_path(root, relative, label):
    """The path as written when it stays inside the project, else None."""
    from tasks import confined_spec_path

    if not isinstance(relative, str) or relative == "":
        return None
    if os.path.isabs(relative):
        _advise(label + " " + repr(relative) + " is absolute, dropped")
        return None
    _, inside = confined_spec_path(root, relative)
    if not inside:
        _advise(label + " " + repr(relative) + " escapes the project, dropped")
        return None
    return relative


def _qualifier(tasks, position, count):
    """The charter-id infix of one member: its own splitGroup.index, or its
    1-based position when several members have none, or None for a flat file."""
    metadata = tasks.get("metadata") if isinstance(tasks, dict) else None
    group = metadata.get("splitGroup") if isinstance(metadata, dict) else None
    index = group.get("index") if isinstance(group, dict) else None
    if isinstance(index, int) and not isinstance(index, bool):
        return str(index)
    if count > 1:
        return str(position)
    return None


def _answer(paths, anchor, label):
    from tasks import MalformedTasks, _report_project, verification_report

    root = _aimi_root(anchor)
    read = []  # (path, tasks)
    unreadable = 0
    for path in paths:
        tasks, reason = R._read_tasks_with_reason(path)
        if tasks is None:
            _advise(label + " could not read " + path + " -- " + reason)
            unreadable += 1
            continue
        try:
            report = verification_report(tasks)
        except MalformedTasks:
            _advise(label + " could not read " + path + " -- malformed document (unexpected shape)")
            unreadable += 1
            continue
        read.append((path, tasks, report))

    projects = set()
    any_declared = False
    declared_by_member = []
    for _path, tasks, _report in read:
        metadata = tasks.get("metadata") if isinstance(tasks, dict) else None
        entries = _declared(metadata)
        declared_by_member.append(entries)
        any_declared = any_declared or entries is not None
        for story in _stories(tasks):
            projects.add(_report_project(story) or ".")

    surfaces = []
    charters = []
    covered_projects = set()
    prototype_paths = []
    business_spec = design_spec = None
    fallback_used = False

    for position, (path, tasks, report) in enumerate(read, start=1):
        done = set(i for i in R._completed_story_ids(tasks) if isinstance(i, str))
        by_id = {s.get("id"): s for s in _stories(tasks) if isinstance(s.get("id"), str)}
        entries = declared_by_member[position - 1]
        member_surfaces = []
        if entries is not None:
            member_surfaces = entries
        elif not any_declared:
            urls = [v for v in report.get("visual") or []
                    if v.get("id") in done and isinstance(v.get("url"), str) and v.get("url") != ""]
            if urls:
                fallback_used = True
                member_surfaces = [{
                    "kind": "web",
                    "stories": [v["id"] for v in urls],
                    "url": urls[0]["url"],
                    "source": "visual-stories",
                }]

        # A surface counts only for the stories that actually completed.
        owner = {}
        for surface in member_surfaces:
            covering = [s for s in surface.get("stories") or [] if isinstance(s, str) and s in done]
            if covering:
                surfaces.append(surface)
                for story_id in covering:
                    owner.setdefault(story_id, surface)

        deferred = {}
        for entry in report.get("skipped") or []:
            sid = entry.get("id")
            if sid in done:
                reason = entry.get("reason")
                deferred[sid] = ("verification skipped: " + _clean(reason, REASON_MAXLEN)
                                 if isinstance(reason, str) and reason != ""
                                 else "verification skipped, no reason recorded")
        for sid in report.get("pending") or []:
            if sid in done and sid not in deferred:
                deferred[sid] = "verification still pending"

        infix = _qualifier(tasks, position, len(read))
        prefix = "CH-" + infix + "-" if infix is not None else "CH-"
        for story in _stories(tasks):
            sid = story.get("id")
            if not isinstance(sid, str) or sid not in done:
                continue
            project = _report_project(story) or "."
            charter = {
                "id": prefix + sid,
                "kind": None,
                "story": sid,
                "title": _clean(story.get("title"), TITLE_MAXLEN),
                "tasksFile": path,
                "project": project,
            }
            if sid in deferred:
                charter["kind"] = "deferred-verification"
                charter["mandatory"] = True
                charter["reason"] = deferred[sid]
            elif sid in owner:
                charter["kind"] = owner[sid]["kind"]
            else:
                continue
            if sid in owner:
                covered_projects.add(project)
                surface = owner[sid]
                charter["surface"] = surface.get("url") if surface["kind"] == "web" else surface.get("command")
            charters.append(charter)

        metadata = tasks.get("metadata") if isinstance(tasks, dict) else None
        if isinstance(metadata, dict):
            declared_paths = metadata.get("prototypePaths")
            if isinstance(declared_paths, list):
                for entry in declared_paths:
                    good = _spec_path(root, entry, "prototype path")
                    if good is not None and good not in prototype_paths:
                        prototype_paths.append(good)
            bundle = metadata.get("designBundle")
            if isinstance(bundle, dict):
                if business_spec is None:
                    business_spec = _spec_path(root, bundle.get("businessSpec"), "businessSpec")
                if design_spec is None:
                    design_spec = _spec_path(root, bundle.get("designSpec"), "designSpec")

    if any_declared:
        source = "declared"
    elif fallback_used:
        source = "visual-stories"
    else:
        source = "none"
    ask_undeclared = bool(read) and source == "none"

    recipe_recorded = bool(surfaces) and all(
        _recipe_recorded(root, project) for project in sorted(covered_projects)
    ) if covered_projects else False

    if os.environ.get(ENV_SWITCH) == "off":
        skip, reason = "disabled-by-operator", ENV_SWITCH + "=off"
    elif not read:
        skip, reason = "unable-to-evaluate", "no readable tasks file"
    elif not surfaces:
        if unreadable:
            skip = "unable-to-evaluate"
            reason = str(unreadable) + " tasks file(s) could not be read and no surface was found in the rest"
        else:
            skip = "not-applicable"
            reason = "no completed story delivers a declared usage surface"
            if source == "none":
                reason = "no usage surface declared and no completed visual story carries a url"
    elif not recipe_recorded:
        skip, reason = "unable-to-evaluate", "no usage recipe recorded"
    else:
        skip = None
        reason = (str(len(surfaces)) + " usage surface(s) from " + source + " across "
                  + str(len(read)) + " tasks file(s), recipe recorded")

    return {
        "required": skip is None,
        "skipKind": skip,
        "reason": _clean(reason, REASON_MAXLEN),
        "surfaceSource": source,
        "askUndeclared": ask_undeclared,
        "members": len(read),
        "projects": sorted(projects) if projects else ["."],
        "recipeRecorded": recipe_recorded,
        "surfaces": surfaces,
        "charters": charters,
        "specs": {
            "businessSpec": business_spec,
            "designSpec": design_spec,
            "prototypePaths": prototype_paths,
        },
    }


def usage_validation_requirement(roadmap_path, doc, phase):
    """Does this phase owe usage validation, from its own tasks file(s).

    The call shape of roadmap._visual_gate_requirement. Members come from
    roadmap._completed_gate_resolve_members; an unreadable one draws an
    advisory and is not counted in `members`."""
    members = R._completed_gate_resolve_members(roadmap_path, doc, phase)
    return _answer(members, roadmap_path, "phase " + R._num(phase.get("id")))


def usage_validation_requirement_for_files(paths):
    """The same answer for a flat run: the tasks file(s) given."""
    paths = list(paths)
    anchor = paths[0] if paths else os.getcwd()
    return _answer(paths, anchor, "run")


class _Unusable(Exception):
    """The block cannot be used; the message names the field."""


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _last_block(message):
    """The body of the LAST fenced usage_validation_verdict block.

    The opening line is exactly the fence plus the tag and the closing line
    exactly the fence, as the visual gate reads its own block. A later open line
    replaces an earlier block, and a last block left open fails: an earlier
    valid block never rescues a later one."""
    opening = FENCE + VERDICT_TAG
    inside = False
    buf = []
    last = None
    for line in message.split("\n"):
        if line == opening:
            inside, buf = True, []
        elif inside and line == FENCE:
            inside = False
            last = "\n".join(buf)
        elif inside:
            buf.append(line)
    if inside:
        raise _Unusable("the last " + VERDICT_TAG + " block has no closing fence")
    if last is None:
        raise _Unusable("no " + VERDICT_TAG + " block in the message")
    return last


def _need(obj, key, kind, where):
    if key not in obj:
        raise _Unusable(where + "." + key + " is missing")
    value = obj[key]
    if kind == "int":
        ok = _is_int(value)
    elif kind == "str":
        ok = isinstance(value, str)
    elif kind == "list":
        ok = isinstance(value, list)
    else:
        ok = False
    if not ok:
        raise _Unusable(where + "." + key + " must be " + {"int": "an integer", "str": "a string", "list": "a list"}[kind])
    return value


def _parse_block(body):
    try:
        block = json.loads(body)
    except (ValueError, RecursionError):
        raise _Unusable("the block is not valid JSON")
    if not isinstance(block, dict):
        raise _Unusable("the block is not a JSON object")
    charters = _need(block, "charters", "list", "block")
    findings = _need(block, "findings", "list", "block")
    origins = _need(block, "origins", "list", "block")
    actions = _need(block, "exploratoryActions", "int", "block")
    if actions < 0:
        raise _Unusable("block.exploratoryActions must not be negative")
    if "summary" in block and not isinstance(block["summary"], str):
        raise _Unusable("block.summary must be a string")
    if len(charters) > MAX_CHARTERS:
        raise _Unusable("block.charters has more than " + str(MAX_CHARTERS) + " entries")
    if len(findings) > MAX_FINDINGS:
        raise _Unusable("block.findings has more than " + str(MAX_FINDINGS) + " entries")
    for i, origin in enumerate(origins):
        if not isinstance(origin, str):
            raise _Unusable("block.origins[" + str(i) + "] must be a string")

    status = {}
    reasons = {}
    for i, charter in enumerate(charters):
        where = "block.charters[" + str(i) + "]"
        if not isinstance(charter, dict):
            raise _Unusable(where + " must be an object")
        cid = _need(charter, "id", "str", where)
        if cid == "" or re.search(r"[:/\s]", cid):
            raise _Unusable(where + ".id must be non-empty and hold no colon, slash or whitespace")
        if cid in status:
            raise _Unusable(where + ".id repeats charter id " + repr(_clean(cid, 60)))
        st = _need(charter, "status", "str", where)
        if st not in ("executed", "blocked"):
            raise _Unusable(where + ".status must be executed or blocked")
        reason = charter.get("reason")
        if "reason" in charter and not isinstance(reason, str):
            raise _Unusable(where + ".reason must be a string")
        if st == "blocked" and not (isinstance(reason, str) and reason.strip() != ""):
            raise _Unusable(where + ".reason is required when the charter is blocked")
        status[cid] = st
        reasons[cid] = reason if isinstance(reason, str) else ""

    parsed = []
    seen = set()
    for i, finding in enumerate(findings):
        where = "block.findings[" + str(i) + "]"
        if not isinstance(finding, dict):
            raise _Unusable(where + " must be an object")
        cid = _need(finding, "charterId", "str", where)
        if cid not in status:
            raise _Unusable(where + ".charterId names no charter of the block")
        step = _need(finding, "step", "int", where)
        if step < 1:
            raise _Unusable(where + ".step must be a positive integer")
        heuristic = _need(finding, "heuristic", "str", where)
        if heuristic not in HEURISTICS:
            raise _Unusable(where + ".heuristic is not one of H1 to H10, S, F, D, P, O, T")
        kind = _need(finding, "kind", "str", where)
        if kind not in FINDING_KINDS:
            raise _Unusable(where + ".kind must be bug, decision or unmapped")
        ratings = {}
        for name in RATINGS:
            value = _need(finding, name, "int", where)
            if value < 0 or value > 4:
                raise _Unusable(where + "." + name + " must be an integer from 0 to 4")
            ratings[name] = value
        texts = {name: _need(finding, name, "str", where) for name in ("title", "expected", "observed")}
        evidence = _need(finding, "evidence", "list", where)
        if len(evidence) > MAX_EVIDENCE:
            raise _Unusable(where + ".evidence has more than " + str(MAX_EVIDENCE) + " entries")
        for j, entry in enumerate(evidence):
            if not isinstance(entry, dict):
                raise _Unusable(where + ".evidence[" + str(j) + "] must be an object")
            if entry.get("type") not in EVIDENCE_TYPES:
                raise _Unusable(where + ".evidence[" + str(j) + "].type must be screenshot, console, network or command")
        key = cid + ":" + str(step) + ":" + heuristic
        if key in seen:
            raise _Unusable(where + " repeats finding key " + repr(_clean(key, 80)))
        seen.add(key)
        parsed.append({"key": key, "charterId": cid, "step": step, "heuristic": heuristic, "kind": kind,
                       "ratings": ratings, "texts": texts, "evidence": evidence})
    return {"status": status, "reasons": reasons, "findings": parsed, "origins": origins,
            "actions": actions, "summary": block.get("summary")}


def _evidence_counts(entry, evidence_dir):
    """True when the evidence entry names a re-checkable artifact: a relative
    path with no .. segment that crosses no symlink and ends at an existing
    regular file under the evidence directory, and, for a command, an integer
    exit code."""
    from tasks import confined_spec_path

    path = entry.get("path")
    if not isinstance(path, str) or path == "" or "\0" in path:
        return False
    if entry["type"] == "command" and not _is_int(entry.get("exitCode")):
        return False
    if os.path.isabs(path) or path.startswith("\\"):
        return False
    parts = path.replace("\\", "/").split("/")
    if ".." in parts:
        return False
    here = evidence_dir
    for part in parts:
        if part in ("", "."):
            continue
        here = os.path.join(here, part)
        if os.path.islink(here):
            return False
    _, inside = confined_spec_path(evidence_dir, path)
    return inside and os.path.isfile(here) and not os.path.islink(here)


def _verdict_answer(outcome, reason, planned, executed=0, blocked_list=(), actions=0,
                    bugs=(), decisions=(), unmapped=(), unconfirmed=(), reported=(),
                    dropped=0, summary=None):
    return {
        "outcome": outcome,
        "reason": _clean(reason, REASON_MAXLEN),
        "counts": {"planned": planned, "executed": executed, "blocked": len(blocked_list),
                   "exploratoryActions": actions},
        "bugs": list(bugs),
        "decisions": list(decisions),
        "unmapped": list(unmapped),
        "unconfirmed": list(unconfirmed),
        "reported": list(reported),
        "blockedCharters": list(blocked_list),
        "droppedEvidence": dropped,
        "summary": _clean(summary, TEXT_MAXLEN) if isinstance(summary, str) else "",
    }


def usage_validation_verdict(message, planned_ids, evidence_dir, reproduced=(), accepted=()):
    """The gate outcome of one usage validation, computed here and never read
    from the validator.

    <message> is the validator's final message, <planned_ids> the charter ids of
    the `usage-validation-required` answer, <evidence_dir> the directory its
    evidence paths are relative to. <reproduced> and <accepted> are finding keys
    the orchestrator confirmed or the user accepted. Every outcome is an answer,
    never an exception.

    THE BLOCK (the one place its schema is written). Only the LAST fenced block
    tagged `usage_validation_verdict` is read; it is one JSON object:

      charters          [{id, status "executed"|"blocked", reason}], at most 100;
                        ids unique; reason required when blocked
      findings          [{charterId, step, heuristic, kind, severity, frequency,
                          impact, persistence, title, expected, observed,
                          evidence}], at most 200
                        charterId  an id of `charters`
                        step       positive integer
                        heuristic  H1..H10, S, F, D, P, O or T
                        kind       "bug" | "decision" | "unmapped"
                        severity, frequency, impact, persistence   integers 0-4
                        evidence   at most 10 of {type "screenshot"|"console"|
                                   "network"|"command", path, exitCode}
      origins           [str], every origin the validator drove
      exploratoryActions  integer >= 0
      summary           optional str

    A `verdict` key is never read. A finding's key is
    <charterId>:<step>:<heuristic>, computed here. An evidence entry counts only
    for a relative path with no .. segment, crossing no symlink, naming an
    existing regular file under <evidence_dir>, and a command entry also needs an
    integer exitCode; the rest are dropped and tallied in droppedEvidence. A
    finding rated 3 or 4 with no counted entry is capped to severity 2
    (capped true, ratedSeverity kept).

    OUTCOME, first match winning: tooling-failed (unusable block, no charter
    planned or reported, or a non-loopback origin), unable-to-evaluate (no
    planned charter executed), fails (a blocking bug or decision, or a planned
    charter blocked or absent), pass."""
    planned = []
    for cid in planned_ids:
        if isinstance(cid, str) and cid not in planned:
            planned.append(cid)
    n_planned = len(planned)
    if not isinstance(message, str):
        message = ""

    try:
        block = _parse_block(_last_block(message))
    except _Unusable as err:
        return _verdict_answer("tooling-failed", str(err), n_planned)

    status = block["status"]
    if not planned and not status:
        return _verdict_answer("tooling-failed", "no charter is planned or reported", 0)
    for origin in block["origins"]:
        if not U.is_loopback_origin(origin, ORIGIN_SCHEMES):
            return _verdict_answer("tooling-failed",
                                   "origin " + repr(_clean(origin, 200)) + " is not a loopback origin",
                                   n_planned, actions=block["actions"])

    reproduced, accepted = set(reproduced), set(accepted)
    planned_set = set(planned)
    bugs, decisions, unmapped, unconfirmed, reported = [], [], [], [], []
    dropped = 0
    for f in block["findings"]:
        counted = [e for e in f["evidence"] if _evidence_counts(e, evidence_dir)]
        dropped += len(f["evidence"]) - len(counted)
        rated = f["ratings"]["severity"]
        severity, capped = rated, False
        if rated >= 3 and not counted:
            severity, capped = 2, True
        origin = "charter" if f["charterId"] in planned_set else "exploratory"
        item = {
            "key": f["key"], "origin": origin, "kind": f["kind"], "charterId": f["charterId"],
            "step": f["step"], "heuristic": f["heuristic"], "severity": severity, "capped": capped,
            "ratedSeverity": rated, "frequency": f["ratings"]["frequency"],
            "impact": f["ratings"]["impact"], "persistence": f["ratings"]["persistence"],
            "title": _clean(f["texts"]["title"], TITLE_MAXLEN),
            "expected": _clean(f["texts"]["expected"], TEXT_MAXLEN),
            "observed": _clean(f["texts"]["observed"], TEXT_MAXLEN),
            "evidence": [{"type": e["type"], "path": _clean(e["path"], 300)} for e in counted],
        }
        if f["kind"] == "unmapped":
            unmapped.append(item)
        elif severity == 0:
            continue
        elif severity >= 3:
            is_decision = f["kind"] == "decision"
            named = origin == "charter" or f["key"] in reproduced
            if is_decision and f["key"] in accepted:
                reported.append(item)
            elif named:
                (decisions if is_decision else bugs).append(item)
            else:
                unconfirmed.append(item)
        else:
            reported.append(item)

    executed = sum(1 for cid in planned if status.get(cid) == "executed")
    blocked_list = []
    for cid in planned:
        if cid not in status:
            blocked_list.append({"id": cid, "reason": "not reported"})
        elif status[cid] == "blocked":
            blocked_list.append({"id": cid, "reason": _clean(block["reasons"][cid], REASON_MAXLEN)})

    common = dict(planned=n_planned, executed=executed, blocked_list=blocked_list,
                  actions=block["actions"], bugs=bugs, decisions=decisions, unmapped=unmapped,
                  unconfirmed=unconfirmed, reported=reported, dropped=dropped, summary=block["summary"])
    if executed == 0:
        return _verdict_answer("unable-to-evaluate", "no planned charter was executed", **common)
    if bugs or decisions or blocked_list:
        return _verdict_answer("fails", str(len(bugs)) + " blocking bug(s), " + str(len(decisions))
                               + " blocking decision(s), " + str(len(blocked_list)) + " planned charter(s) blocked or absent",
                               **common)
    return _verdict_answer("pass", "every planned charter executed, no blocking finding", **common)


def _op_verdict(argv):
    required = R._flag(argv, "--required-file")
    evidence_dir = R._flag(argv, "--evidence-dir")
    if not required or not evidence_dir:
        sys.stderr.write("Usage: usage_validation.py verdict --required-file <path> --evidence-dir <dir> "
                         "[--reproduced <key>]... [--accepted <key>]...\n")
        return 2
    lists = {"--reproduced": [], "--accepted": []}
    i = 0
    while i < len(argv):
        if argv[i] in lists:
            value = argv[i + 1] if i + 1 < len(argv) else ""
            if not KEY_PATTERN.match(value):
                sys.stderr.write("Error: " + VERDICT_VERB + ": " + argv[i] + " key " + repr(value)
                                 + " is not <charterId>:<step>:<heuristic>\n")
                return 1
            lists[argv[i]].append(value)
            i += 2
        else:
            i += 1
    try:
        with open(required, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        sys.stderr.write("Error: " + VERDICT_VERB + ": --required-file " + required + " is missing or unreadable\n")
        return 1
    charters = doc.get("charters") if isinstance(doc, dict) else None
    if not isinstance(charters, list):
        sys.stderr.write("Error: " + VERDICT_VERB + ": --required-file " + required + " has no charters list\n")
        return 1
    if not os.path.isdir(evidence_dir):
        sys.stderr.write("Error: " + VERDICT_VERB + ": --evidence-dir " + evidence_dir + " is not a directory\n")
        return 1
    planned = [c.get("id") for c in charters if isinstance(c, dict) and isinstance(c.get("id"), str)]
    message = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    R._emit(usage_validation_verdict(message, planned, evidence_dir, lists["--reproduced"], lists["--accepted"]))
    return 0


def _op_required(argv):
    path = R._flag(argv, "--roadmap")
    phase_raw = R._flag(argv, "--phase")
    if not path or phase_raw is None:
        sys.stderr.write("Usage: usage_validation.py required --roadmap <path> --phase <id>\n")
        return 2
    doc = R.read_doc(path, VERB)
    try:
        phase_id = R.jq_numbers(R.json.loads(phase_raw))
    except ValueError:
        sys.stderr.write("Error: " + VERB + ": --phase <id> must be a numeric phase id\n")
        return 1
    phase = next((p for p in (doc.get("phases") or []) if isinstance(p, dict) and p.get("id") == phase_id), None)
    if phase is None:
        sys.stderr.write("Error: " + VERB + ": phase " + phase_raw + " not found in " + path + "\n")
        return 1
    R._emit(usage_validation_requirement(path, doc, phase))
    return 0


def _op_files(argv):
    paths = [argv[i + 1] for i, a in enumerate(argv) if a == "--tasks-file" and i + 1 < len(argv)]
    if not paths:
        sys.stderr.write("Usage: usage_validation.py files --tasks-file <path>...\n")
        return 2
    R._emit(usage_validation_requirement_for_files(paths))
    return 0


_OPS = {"required": _op_required, "files": _op_files, "verdict": _op_verdict}


def main(argv):
    if len(argv) < 2 or argv[1] not in _OPS:
        sys.stderr.write("Usage: usage_validation.py <" + "|".join(sorted(_OPS)) + "> [flags]\n")
        return 2
    return _OPS[argv[1]](argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
