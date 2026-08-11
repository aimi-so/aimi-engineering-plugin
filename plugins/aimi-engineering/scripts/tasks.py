#!/usr/bin/env python3
"""Read-only tasks.json document logic for aimi-cli.sh.

WHY THIS FILE EXISTS, AND WHAT IT IS ALLOWED TO DO
==================================================

Same split roadmap.py made, for the other document. aimi-cli.sh keeps the
shell-shaped work -- flag parsing, `flock`, path confinement, resolving where a
tasks file lives, reading .aimi/state/ -- and this file owns what a verb then
computes over the document it was handed. The boundary is one crossing per
verb: bash resolves the path, calls here once, and prints whatever comes back.

It holds READ-ONLY verbs and nothing else: `status` (both branches),
`metadata`, `get-story`, `current-story`, `get-state`, `count-pending`,
`list-ready` and `next-story`, plus `validate-story-exists`, which is a twin of
a bash gate rather than a verb and is explained below. Nothing here takes a
lock and nothing here writes, which is why these could be the first crossings
-- there is no writer to get the lock ordering wrong.

WHAT THESE SLICES ACTUALLY COLLAPSED
------------------------------------

The maxConcurrency default was written out THREE times in aimi-cli.sh --
`((.metadata.maxConcurrency // 20) | if . <= 0 then 20 else . end)` in both
branches of cmd_status and once more, spelled differently, in cmd_metadata.
All three call sites are verbs in this file, so the rule left aimi-cli.sh
entirely rather than being reduced to one bash copy. It lives once, below, in
clamp_max_concurrency. A port that only moved code would not have been worth
running; this is the duplicated rule it was worth running for.

The readiness predicate is the second. cmd_next_story reached it by running
cmd_list_ready as a shell FUNCTION and re-sorting its output through a second
jq -- so the two verbs were one implementation only for as long as nobody
touched them, and porting either alone would have left the other holding a jq
copy of the same rule. They move together and now stand on one is_ready and one
next_story, at one crossing each.

WHAT THIS FILE MUST NOT BECOME
------------------------------

  * A place that re-derives a rule aimi-cli.sh still owns. Story-id FORMAT, the
    tasks-file search and its stale-state self-heal all stayed in bash and are
    NOT reimplemented here. Two opinions about which file is current is the
    disease this whole branch cures.
  * A second opinion about whether a story exists. That gate is the ONE thing
    deliberately written twice, because ten bash call sites outlive the slice
    that ported list-ready -- op_validate_story_exists exists so a verb already
    on this side need not go back to bash for it, and it prints the bash
    function's line verbatim. The duplication is temporary and the byte
    identity is asserted, not assumed: test_tasks.py runs both and compares
    stderr. The bash copy is deleted by whichever slice moves its last caller,
    and this op's message dies with it.
  * A writer. Nothing here opens a file for writing, and in particular nothing
    here touches .aimi/state/ -- read_state/write_state carry their own
    .state.lock and their own path confinement, and cmd_get_state hands the
    four values it already read in as flags for exactly that reason.
  * A second self-resolver. cmd_init_session runs `resolve_path "$0"` and feeds
    the result to write_state "cli-path" AND write_global_cli_cache. Inside
    this file `$0` is tasks.py, so porting it would put a Python module's path
    into ~/.config/aimi/cli-path and every later $AIMI_CLI resolution would
    load a .py as a shell script -- on the NEXT session, long after the test
    run that passed. init-session stays in bash permanently, and the string
    "cli-path" appears nowhere in this file.

WHERE jq AND PYTHON PART COMPANY
--------------------------------

jq indexes null happily, orders values across types, reads a STREAM of JSON
values rather than one, gives a number a length, ends an `all` at the first
element that answers nothing, and aborts with its own engine message on a shape
it cannot handle. Each of those is reproduced deliberately below -- jq_index,
clamp_max_concurrency's comparison, read_docs, jq_length, jq_all_over, and
MalformedTasks -- and the one place fidelity is impossible (the engine's own
wording and exit status) is recorded case by case in
tests/golden_from_jq.json's `tasks_read_cases` and `tasks_ready_cases`, whose
`_comment_tasks_read` and `_comment_tasks_ready` name every divergence and what
it cost.
"""

import json
import sys

# jq's number rendering and jq's cross-type ordering, both already solved for
# roadmap.json and neither of them roadmap-specific. Importing beats a second
# copy: clamp_max_concurrency's whole trap is that `true <= 0` is TRUE in jq
# and a TypeError in Python, and there must be exactly one answer to that in
# this tree. _json_type is private to the roadmap VERBS, not to the file, and
# comes along so two diagnostics cannot name the same shape differently.
#
# If a third module ever needs these, they follow rm_sanitize into a module of
# their own -- that is what sanitize.py is, and why it was extracted in its own
# commit rather than being imported out of whichever file happened to hold it.
from roadmap import _json_type, jq_numbers, jq_sort_key

# THE default, in the one place it is now written.
#
# A FOURTH copy lives in hooks/pre-bash-dispatcher.py's worktree-budget handler
# and stays there on purpose. That hook is a separate process Claude Code spawns
# on every Bash call, with no import path to scripts/ and no guarantee this CLI
# is even resolvable at hook time; making it import this module would put a
# plugin-path resolution on the hot path of every command the user runs. It also
# does not implement the same rule -- it accepts any int, a negative one
# included, where this clamps anything <= 0 -- so collapsing it would be a
# behaviour change rather than a refactor, and belongs to its own slice. The
# comment at that end names this one, so the divergence is discoverable from
# either side.
DEFAULT_MAX_CONCURRENCY = 20


class MalformedTasks(Exception):
    """A tasks.json shaped so the verb cannot answer -- where jq aborted.

    Raised, never caught inside a rule. main() turns it into one stderr line
    and a non-zero exit, so a document that is not a tasks file stops the verb
    instead of quietly shrinking what it looked at. jq printed its own message
    and its own exit status here; both are recorded in the golden as named
    divergences rather than synthesized.
    """


# ---------------------------------------------------------------------------
# jq's evaluation semantics, only the parts these six verbs actually reach
# ---------------------------------------------------------------------------


def jq_index(value, key, owner=""):
    """jq's `.key`. `owner` is the expression that produced `value`, so a
    refusal quotes the whole path -- `.metadata.title`, not `title`.

    null indexes to null -- that is not leniency, it is the rule that makes
    `.metadata.title` return null for a document with no metadata instead of
    failing, and it is why a null STORY inside userStories produces a row of
    nulls rather than an abort. Anything that is neither null nor an object
    aborts, which is what jq did.
    """
    if value is None:
        return None
    if isinstance(value, dict):
        return value.get(key)
    raise MalformedTasks(owner + "." + key + ": cannot index " + _json_type(value))


def jq_iterate(value, owner):
    """jq's `.[]`. An object yields its VALUES, which is why `userStories: {}`
    reaches the per-story rules at all instead of being refused up front."""
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        return list(value.values())
    raise MalformedTasks(owner + ": cannot iterate over " + _json_type(value))


def jq_alternative(value, fallback):
    """jq's `//`: null and false take the alternative, EVERYTHING else passes.

    Note what does not take it -- 0, "", [] and {} are all truthy in jq, so
    `.dependsOn // []` leaves an empty string alone and `.maxConcurrency // 20`
    leaves a 0 alone for the comparison below to catch.
    """
    if value is None or value is False:
        return fallback
    return value


def jq_length(value, owner):
    """jq's `length`, over the values `.dependsOn // []` can actually hold.

    It is not Python's len(), and the difference decides whether a story is
    ready: a NUMBER's length is its absolute value, so `dependsOn: 0` has
    length 0 and short-circuits the dependency walk to true exactly as `[]`
    does, and an empty STRING does the same. Both are recorded (depende-formas)
    because both are stories the pre-port CLI listed as ready.

    A boolean is the one value with no length at all -- jq aborts there, and so
    does this. null and false never arrive: `//` replaced them with [] first.
    """
    if isinstance(value, bool):
        raise MalformedTasks(
            owner + ": boolean (" + ("true" if value else "false") + ") has no length"
        )
    if isinstance(value, (int, float)):
        return abs(value)
    return len(value)


def jq_all_over(elements, outputs_for):
    """jq's `all(.[]; condition)` AS JQ 1.6 ACTUALLY EVALUATES IT.

    `outputs_for(element)` yields what the condition produced for one element:
    zero values when the element selected nothing, one per selection otherwise.
    The walk then follows jq's own three-way rule, and the middle arm is the
    one no reading of the manual gives you:

      * a falsy output   -> false, immediately; later elements are not reached
      * NO output at all -> true, immediately; later elements are not reached
      * otherwise        -> keep going, true if the elements run out

    That middle arm is the whole of trap 3 and it is stronger than "vacuously
    true for that element". A `dependsOn` of ["US-999", "US-001"] where US-999
    matches no story is READY today even when US-001 is still pending, because
    the dangling id ENDS the walk before US-001 is looked at -- while
    ["US-001", "US-999"] is blocked, same two ids, other order. Both are
    recorded side by side in tasks_ready_cases as dep-pendurada-antes, because
    the difference is invisible in the jq source and a port that treated a
    dangling id as merely "not blocking" would silently drop stories from a
    wave that runs today.

    Reproduced, not fixed. A dangling dependsOn id is a broken tasks file and
    what to do about it is a decision, not a port.
    """
    for element in elements:
        empty = True
        for output in outputs_for(element):
            empty = False
            if output is None or output is False:
                return False
        if empty:
            return True
    return True


def clamp_max_concurrency(value):
    """metadata.maxConcurrency, defaulted and floor-guarded, in ONE place.

    Reproduces `((. // 20) | if . <= 0 then 20 else . end)` over the whole value
    space, and the whole reason it needs a function is that the comparison is
    not the Python one:

      absent / null / false  -> 20, the alternative fires
      0, 0.0, -1, -0.5       -> 20, the ordinary floor
      true                   -> 20, because jq orders booleans BELOW numbers,
                                so `true <= 0` holds. Python would say False.
      20.0                   -> 20, not 20.0 -- jq puts every number through a
                                double and prints the shortest round-trip form
      "muitos", [1], {"n":3} -> UNCHANGED, because jq orders strings, arrays and
                                objects ABOVE numbers, so the comparison is
                                simply false and the value passes through. A
                                naive `value <= 0` raises TypeError here.

    The last two rows are the ones worth a test: a caller that writes a string
    keeps getting its string back, exactly as it did before the port, and finds
    out downstream rather than here -- which is the behaviour, not a fix.
    """
    value = jq_alternative(value, DEFAULT_MAX_CONCURRENCY)
    if jq_sort_key(value) <= jq_sort_key(0):
        return DEFAULT_MAX_CONCURRENCY
    return jq_numbers(value)


# ---------------------------------------------------------------------------
# Primitives -- roadmap.py's, deliberately, rather than a second convention
# ---------------------------------------------------------------------------


def die(message, code=1):
    sys.stderr.write(message + "\n")
    sys.exit(code)


def _flag(argv, name):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return None


def _emit(value):
    """One JSON value on stdout, rendered the way jq's default output did.

    jq_numbers runs on the way out rather than at each rule, because every one
    of these verbs copies numbers straight out of the document -- a story's
    priority, a schemaVersion someone wrote as 3.0 -- and jq rendered all of
    them through the same double.
    """
    json.dump(jq_numbers(value), sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")


def load_docs(path):
    """Every JSON value in the file, in order, RAISING on a file it cannot read.

    jq reads a STREAM, not one value, and two behaviours depend on it: an EMPTY
    tasks file yields zero values, so the verb prints nothing and exits 0, and a
    file holding two concatenated documents runs the verb twice. Both are
    faithful here rather than convenient -- the empty-file case in particular is
    a silent hole (a truncated write reports success), and reproducing it is
    what keeps this a port. It is ranked, not fixed, and not in this slice.

    Split from read_docs because op_validate_story_exists needs the failure as a
    VALUE rather than as an exit: the bash gate it twins runs jq with stderr
    redirected to /dev/null and answers "not found" for every failure it could
    have had, and a twin that died with a different message would not be one.
    """
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()

    decoder = json.JSONDecoder()
    docs = []
    index = 0
    while True:
        while index < len(text) and text[index] in " \t\r\n":
            index += 1
        if index >= len(text):
            return docs
        value, index = decoder.raw_decode(text, index)
        docs.append(value)


def read_docs(path, verb):
    """load_docs, with a refusal instead of a traceback. What every verb uses."""
    try:
        return load_docs(path)
    # UnicodeDecodeError is a ValueError, so this arm has to come first -- a
    # file that is not UTF-8 is one the verb could not READ, not one whose JSON
    # was malformed, and the two messages are told apart in the golden.
    except (OSError, UnicodeDecodeError) as err:
        return die("Error: " + verb + ": cannot read tasks file " + path + ": " + str(err))
    except ValueError as err:
        return die("Error: " + verb + ": malformed JSON in tasks file " + path + ": " + str(err))


# ---------------------------------------------------------------------------
# The document rules
# ---------------------------------------------------------------------------

STATUS_COUNTS = ("pending", "in_progress", "completed", "failed", "skipped")


def _stories(doc):
    return jq_iterate(jq_index(doc, "userStories"), ".userStories")


def count_with_status(stories, status):
    """`[.userStories[] | select(.status == $s)] | length`."""
    return len([s for s in stories if jq_index(s, "status", ".userStories[]") == status])


def story_row(story):
    """The status projection: `{id, title, status, dependsOn: (.dependsOn // []),
    priority, notes}`. Key order is jq's written order, which a diff of two
    status outputs depends on."""
    return {
        "id": jq_index(story, "id", ".userStories[]"),
        "title": jq_index(story, "title", ".userStories[]"),
        "status": jq_index(story, "status", ".userStories[]"),
        "dependsOn": jq_alternative(jq_index(story, "dependsOn", ".userStories[]"), []),
        "priority": jq_index(story, "priority", ".userStories[]"),
        "notes": jq_index(story, "notes", ".userStories[]"),
    }


def status_view(doc, counts_only):
    """Both branches of cmd_status, which differed in exactly one key.

    They were two 11-line jq programs whose first ten lines were identical, and
    keeping them identical was nobody's job. --counts-only now omits one key
    from one dict; nothing else can drift apart.
    """
    # Indexed in the order the jq object literal named them, so a document that
    # is not an object is refused over the same field jq refused it over.
    schema_version = jq_index(doc, "schemaVersion")
    metadata = jq_index(doc, "metadata")
    view = {
        "schemaVersion": schema_version,
        "title": jq_index(metadata, "title", ".metadata"),
        "branch": jq_index(metadata, "branchName", ".metadata"),
        "maxConcurrency": clamp_max_concurrency(
            jq_index(metadata, "maxConcurrency", ".metadata")
        ),
    }
    stories = _stories(doc)
    for status in STATUS_COUNTS:
        view[status] = count_with_status(stories, status)
    view["total"] = len(stories)
    if not counts_only:
        view["userStories"] = [story_row(story) for story in stories]
    return view


def metadata_view(doc):
    """`.metadata | .maxConcurrency = (<clamp>)`.

    A document with no metadata yields `{"maxConcurrency": 20}` and not null,
    because jq's assignment onto null BUILDS the object. Preserved: a caller
    reading .maxConcurrency off this gets a number either way.
    """
    metadata = jq_index(doc, "metadata")
    clamped = clamp_max_concurrency(jq_index(metadata, "maxConcurrency", ".metadata"))
    if metadata is None:
        return {"maxConcurrency": clamped}
    # dict assignment keeps an existing key in place and appends a new one --
    # the same thing jq's `.k = v` does, and what makes the key order stable.
    view = dict(metadata)
    view["maxConcurrency"] = clamped
    return view


def stories_with_id(doc, story_id):
    """`.userStories[] | select(.id == $id)` -- a LIST, because a tasks file
    carrying the same id twice made jq print both objects and still does."""
    return [s for s in _stories(doc) if jq_index(s, "id", ".userStories[]") == story_id]


# ---------------------------------------------------------------------------
# Readiness -- the predicate list-ready and next-story now SHARE
# ---------------------------------------------------------------------------

# The jq expression that produced a story, quoted back by every diagnostic
# these rules raise. One constant because a refusal that names `.userStories[]`
# in one rule and `.story` in the next reads like two different files.
STORY = ".userStories[]"


def _dependencies(story):
    """`$story.dependsOn // []`, which the jq wrote out at all four of its
    sites. Note what `//` does NOT replace: 0, "" and {} all survive it and
    reach jq_length, where 0 and "" turn out to have length 0 too."""
    return jq_alternative(jq_index(story, "dependsOn", STORY), [])


def _matching_deps(stories, dep_id, condition):
    """`$root.userStories[] | select(.id == $dep_id) | condition`, lazily.

    Lazy on purpose: jq stops the moment `all` has its answer, so a story
    AFTER the one that decided it is never indexed and never aborts on a shape
    it does not like. A list comprehension here would evaluate the rest and
    turn a story jq listed into a refusal.
    """
    for story in stories:
        if jq_index(story, "id", STORY) == dep_id:
            yield condition(story)


def _no_dependency_blocks(story, stories, condition):
    """One `(deps | length == 0) or (deps | all(...))` arm.

    The jq wrote this shape out twice, once per walk, and the two copies
    differed only in the condition -- which is the duplication a shared
    parameter removes. The length arm is checked first for the reason jq
    checked it first: `or` short-circuits, so a dependsOn that cannot be
    iterated (a number, a bare string) is only reached when its length is NOT
    zero -- which is how `dependsOn: 0` stays readable and `dependsOn: 2`
    aborts.
    """
    deps = _dependencies(story)
    if jq_length(deps, STORY + ".dependsOn") == 0:
        return True
    return jq_all_over(
        jq_iterate(deps, STORY + ".dependsOn"),
        lambda dep_id: _matching_deps(stories, dep_id, condition),
    )


def _dep_action_gate_clear(dep):
    """`(.gate.type != "action") or (.gate.status != "pending")` on a DEPENDENCY.
    A dependency holding a pending ACTION gate blocks its dependents; every
    other gate kind and status does not."""
    gate = jq_index(dep, "gate", STORY)
    return jq_index(gate, "type", STORY + ".gate") != "action" or (
        jq_index(gate, "status", STORY + ".gate") != "pending"
    )


def _dep_status_done(dep):
    """`$dep_status == "completed" or $dep_status == "skipped"`. Anything else
    -- pending, in_progress, failed, absent -- leaves the dependent blocked."""
    status = jq_index(dep, "status", STORY)
    return status == "completed" or status == "skipped"


def is_ready(story, stories):
    """THE readiness predicate, in the order jq applied its four filters.

    The order is load-bearing rather than stylistic: each filter can abort on a
    shape the one before it never looked at, so running them in a different
    order would refuse a different file. Same reason the two dependency walks
    stay separate even though they iterate the same list -- jq ran the gate
    walk to completion first, and a document that aborts in the gate walk must
    not get as far as the status walk.
    """
    if jq_index(story, "status", STORY) != "pending":
        return False
    # The story's OWN gate. Only a pending DECISION gate holds it back: an
    # action or verify gate on itself is what /aimi:execute resolves after the
    # story runs, so it never blocks the story that carries it.
    gate = jq_index(story, "gate", STORY)
    own_gate_blocks = jq_index(gate, "type", STORY + ".gate") == "decision" and (
        jq_index(gate, "status", STORY + ".gate") == "pending"
    )
    if own_gate_blocks:
        return False
    if not _no_dependency_blocks(story, stories, _dep_action_gate_clear):
        return False
    return _no_dependency_blocks(story, stories, _dep_status_done)


def ready_stories(doc):
    """The whole list-ready array, in tasks.json FILE ORDER -- jq filtered a
    stream and never sorted, and execute.md says selection order follows this
    output, "tasks.json file order, deterministic"."""
    stories = _stories(doc)
    return [story for story in stories if is_ready(story, stories)]


BRIEF_KEYS = ("id", "title", "priority", "dependsOn", "project", "gate")


def brief_row(story):
    """`{id, title, priority, dependsOn, project, gate}`, all six, always.

    jq's object-construction shorthand emits a key holding null when the story
    has no such field, so a story with no project and no gate still yields six
    keys -- which is why this null-fills instead of copying what is present.
    /aimi:execute's wave selection reads these stubs and part1-core asserts the
    count is exactly 6. Note `dependsOn` is the RAW field here, null and all: the
    `// []` above belongs to the predicate, not to this projection, and a story
    listed with `"dependsOn": null` is what the pre-port CLI printed.
    """
    return {key: jq_index(story, key, STORY) for key in BRIEF_KEYS}


def next_story(doc):
    """`sort_by(.priority) | .[0]` over the ready list, with both of its traps.

    jq's sort is STABLE, so stories tied on priority stay in tasks.json file
    order -- which is the determinism /aimi:execute documents. And jq's total
    order puts null BELOW every number, so a story whose priority is null or
    absent is picked FIRST, ahead of priority 1. jq_sort_key is what reproduces
    the second; `sorted` being stable is what reproduces the first, and both are
    pinned by recorded cases (empate, prioridade-nula, prioridade-ausente)
    rather than left to the reader to trust.

    None for an empty list, because `[] | .[0]` is null and bash keys its
    clear-the-pointer branch off exactly that token.
    """
    ready = ready_stories(doc)
    if not ready:
        return None
    ordered = sorted(ready, key=lambda story: jq_sort_key(jq_index(story, "priority", STORY)))
    return ordered[0]


# ---------------------------------------------------------------------------
# Ops -- one per verb (plus the one twin), each handed an already-resolved path
# ---------------------------------------------------------------------------


def op_status(argv):
    path = _flag(argv, "--tasks-file")
    if not path:
        die("Usage: tasks.py status --tasks-file <path> [--counts-only]")
    counts_only = "--counts-only" in argv
    for doc in read_docs(path, "status"):
        _emit(status_view(doc, counts_only))
    return 0


def op_metadata(argv):
    path = _flag(argv, "--tasks-file")
    if not path:
        die("Usage: tasks.py metadata --tasks-file <path>")
    for doc in read_docs(path, "metadata"):
        _emit(metadata_view(doc))
    return 0


def op_count_pending(argv):
    path = _flag(argv, "--tasks-file")
    if not path:
        die("Usage: tasks.py count-pending --tasks-file <path>")
    for doc in read_docs(path, "count-pending"):
        _emit(count_with_status(_stories(doc), "pending"))
    return 0


def op_get_story(argv):
    """The story bash already proved exists -- validate_story_id and
    validate_story_exists both ran before this process started, and neither is
    repeated here."""
    path = _flag(argv, "--tasks-file")
    story_id = _flag(argv, "--story-id")
    if not path or story_id is None:
        die("Usage: tasks.py get-story --tasks-file <path> --story-id <id>")
    for doc in read_docs(path, "get-story"):
        for story in stories_with_id(doc, story_id):
            _emit(story)
    return 0


def op_current_story(argv):
    """Same selection as get-story, and deliberately NOT the same guarantees.

    cmd_current_story reads its id out of .aimi/state/current-story, which no
    one validated and which may name a story that has since been renamed away.
    jq printed nothing and exited 0 for that, and so does this -- an empty
    stdout is how the caller learns the pointer is stale.
    """
    path = _flag(argv, "--tasks-file")
    story_id = _flag(argv, "--story-id")
    if not path or story_id is None:
        die("Usage: tasks.py current-story --tasks-file <path> --story-id <id>")
    for doc in read_docs(path, "current-story"):
        for story in stories_with_id(doc, story_id):
            _emit(story)
    return 0


def op_get_state(argv):
    """Pure assembly over four values bash already read.

    No path is opened here and none is named: .aimi/state/ has its own
    .state.lock and its own confinement in read_state, and this op exists only
    because the four-way "" -> null mapping was jq's.
    """
    _emit(
        {
            "tasks": _state_or_null(_flag(argv, "--tasks")),
            "branch": _state_or_null(_flag(argv, "--branch")),
            "story": _state_or_null(_flag(argv, "--story")),
            "last": _state_or_null(_flag(argv, "--last")),
        }
    )
    return 0


def _state_or_null(value):
    """`if $v == "" then null else $v end`. An absent flag is an unset state
    file, which read_state also returns as the empty string."""
    return None if value in (None, "") else value


def op_list_ready(argv):
    path = _flag(argv, "--tasks-file")
    if not path:
        die("Usage: tasks.py list-ready --tasks-file <path> [--brief]")
    brief = "--brief" in argv
    for doc in read_docs(path, "list-ready"):
        ready = ready_stories(doc)
        _emit([brief_row(story) for story in ready] if brief else ready)
    return 0


def op_next_story(argv):
    """The selection only. The current-story write stays in bash with every
    other .aimi/state/ write, so this verb is as read-only as the other six."""
    path = _flag(argv, "--tasks-file")
    if not path:
        die("Usage: tasks.py next-story --tasks-file <path>")
    for doc in read_docs(path, "next-story"):
        _emit(next_story(doc))
    return 0


def op_validate_story_exists(argv):
    """aimi-cli.sh's validate_story_exists, in Python, for the verbs that have
    already crossed. NOT a verb -- the twin of a bash gate that ten call sites
    still use, and the only op here not named after a command.

    Its message is the bash one to the byte, and so is its exit status. The
    bash gate is `jq -e ... > /dev/null 2>&1`, which answers no differently for
    a missing id, an unreadable file, a malformed document and a userStories
    that cannot be iterated -- jq's own message went to /dev/null and the
    caller saw one line. Reproduced by catching the lot: a twin that refused a
    malformed file with a better message would diverge from the copy it exists
    to match, and there are two of these only until the last bash caller moves.
    """
    path = _flag(argv, "--tasks-file")
    story_id = _flag(argv, "--story-id")
    if not path or story_id is None:
        die("Usage: tasks.py validate-story-exists --tasks-file <path> --story-id <id>")
    try:
        found = any(stories_with_id(doc, story_id) for doc in load_docs(path))
    except (OSError, ValueError, MalformedTasks):
        found = False
    if not found:
        die("Error: Story " + story_id + " not found in " + path)
    return 0


_OPS = {
    "status": op_status,
    "metadata": op_metadata,
    "get-story": op_get_story,
    "current-story": op_current_story,
    "get-state": op_get_state,
    "count-pending": op_count_pending,
    "list-ready": op_list_ready,
    "next-story": op_next_story,
    "validate-story-exists": op_validate_story_exists,
}

# No _VERB_FOR_OP table, unlike roadmap.py: every op here is named after the
# aimi-cli.sh verb that calls it, so a diagnostic already names a command the
# reader can run. Keep it that way -- a rename on one side needs the other.
# The single exception is validate-story-exists, which names the bash FUNCTION
# it twins for the same reason: `grep validate_story_exists` has to find both
# copies while both exist.


def main(argv):
    if len(argv) < 2 or argv[1] not in _OPS:
        die("Usage: tasks.py <" + "|".join(sorted(_OPS)) + "> [flags]", 2)
    try:
        return _OPS[argv[1]](argv[2:])
    except MalformedTasks as malformed:
        # The ONE exception this file catches, caught here rather than at any
        # rule so no rule can be tempted to carry on without it. The file is
        # added from the flag rather than threaded through every raise site:
        # jq named it too, and it is the first thing a reader needs.
        path = _flag(argv[2:], "--tasks-file")
        where = (path + ": ") if path else ""
        die("Error: " + argv[1] + ": " + where + str(malformed))


if __name__ == "__main__":
    sys.exit(main(sys.argv))
