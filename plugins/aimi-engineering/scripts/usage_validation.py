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

import os
import sys

import roadmap as R
from sanitize import rm_sanitize
import usage_recipe as U

VERB = "usage-validation-required"
SURFACE_KINDS = ("web", "cli")
TITLE_MAXLEN = 200
REASON_MAXLEN = 500
ENV_SWITCH = "AIMI_USAGE_VALIDATION"


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


_OPS = {"required": _op_required, "files": _op_files}


def main(argv):
    if len(argv) < 2 or argv[1] not in _OPS:
        sys.stderr.write("Usage: usage_validation.py <" + "|".join(sorted(_OPS)) + "> [flags]\n")
        return 2
    return _OPS[argv[1]](argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
