#!/usr/bin/env python3
"""tasks.json document logic for aimi-cli.sh.

WHY THIS FILE EXISTS, AND WHAT IT IS ALLOWED TO DO
==================================================

Same split roadmap.py made, for the other document. aimi-cli.sh keeps the
shell-shaped work -- flag parsing, `flock`, path confinement, resolving where a
tasks file lives, reading .aimi/state/ -- and this file owns what a verb then
computes over the document it was handed. The boundary is one crossing per
verb: bash resolves the path, calls here once, and prints whatever comes back.

The read-only verbs came first: `status` (both branches), `metadata`,
`get-story`, `current-story`, `get-state`, `count-pending`, `list-ready` and
`next-story`, plus `validate-story-exists`, which is a twin of a bash gate
rather than a verb and is explained below. They could be the first crossings
because they take no lock and there is no writer to get the lock ordering
wrong.

The seven LOCKED WRITERS followed: `mark-complete`, `mark-failed`,
`mark-in-progress`, `mark-skipped`, `update-field`, `normalize-status` and
`normalize-verification`. They were chosen as the first writers because they
were already correct -- every one of them already did its whole read, decide
and write inside the lock -- so the wrapper shape could be established at
almost no behavioural risk. THE LOCK ITSELF IS STILL BASH'S: the wrapper is
`( _lock "$f.lock"; python3 tasks.py <op> ... ) 200>"$f.lock"`, one crossing
inside the lock, and nothing in this file acquires or releases anything.
Reimplementing `_lock` here -- two strategies, `flock -x 200` and an `mkdir`
spinlock -- would be the exact duplication the port exists to remove.

The FOUR RACING WRITERS came last, and they are the one place in this port
where behaviour changed: `cascade-skip`, `gate-pass`, `gate-fail` and
`reset-orphaned`. Each of them used to read its precondition in an UNLOCKED jq
and then act on that answer under the lock, so a concurrent writer could
invalidate the answer in between. There is nowhere left to put an unlocked
read once a verb makes one crossing, so adopting the template above closed
those races by construction; keeping them would have meant deliberately
authoring a two-crossing wrapper whose only purpose was preserving a defect.
The three rules the unlocked calls owned -- cascade-skip's transitive closure
and its two status filters, the gate-present precondition, and
reset-orphaned's orphan list -- all live below, evaluated against the same
document the write goes on to produce. What that cost is recorded in
scripts/test-tasks-concurrency.sh, whose assertions INVERT in the commit that
introduced these four ops; the golden corpus is single-threaded by
construction and covers none of it.

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
  * A writer of anything but the ONE tasks file it was handed. In particular
    nothing here touches .aimi/state/ -- read_state/write_state carry their own
    .state.lock and their own path confinement, cmd_get_state hands the four
    values it already read in as flags for exactly that reason, and the four
    mark-* verbs still run their own write_state/clear_state_file lines in bash
    after the crossing returns.
  * A lock. See above: `_lock` stays in aimi-cli.sh, both strategies intact,
    and every writer here is called from inside a subshell that already holds
    it. A second opinion about locking is worse than none.
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
tests/golden_from_jq.json's `tasks_read_cases`, `tasks_ready_cases` and
`tasks_write_cases`, whose `_comment_tasks_read`, `_comment_tasks_ready` and
`_comment_tasks_write` name every divergence and what it cost.

Three more of jq's habits belong to the writers alone: `. + {…}` treats null as
the empty object, `.a.b = v` BUILDS the intermediates it walks through, and
`map` over an object yields an ARRAY. jq_add_object, jq_setpath and the two
normalize rules reproduce all three.
"""

import json
import os
import sys
import tempfile

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


def jq_unique(values):
    """jq's `unique`: sort by jq's total order, then drop adjacent equals.

    cascade-skip's closure ran its accumulator through this on every iteration,
    so the id list it printed was SORTED rather than in discovery order, and
    part1 pins that. jq_sort_key is what makes a list holding an id nobody
    expected -- a number, a null -- sort instead of raising, exactly as
    next_story needs it to.
    """
    ordered = sorted(values, key=jq_sort_key)
    unique = []
    for value in ordered:
        if not unique or unique[-1] != value:
            unique.append(value)
    return unique


def jq_add_object(value, patch, owner):
    """jq's `. + {…}`, as the four mark-* verbs used it.

    null is the empty object on the left of `+`, so a null story SELECTED by
    the update would come back as the patch alone. Nothing else non-object can:
    jq refuses to add an object to a string or a number, and so does this.
    """
    if value is None:
        return dict(patch)
    if isinstance(value, dict):
        merged = dict(value)
        merged.update(patch)
        return merged
    raise MalformedTasks(owner + ": cannot add an object to " + _json_type(value))


def jq_setpath(value, segments, new_value, owner):
    """jq's `.a.b.c = $v`, which BUILDS every intermediate it walks through.

    Two behaviours update-field depends on, both recorded:

      * a dotted path whose intermediates are absent (or null) creates them as
        objects, so `novo.ramo.folha` lands three levels down in a story that
        had no `novo` -- update-field-cria-intermediarios.
      * a path THROUGH a non-object fails and writes nothing at all, so
        `verification.status` on a story whose verification is the string
        "manual" leaves the document untouched --
        update-field-intermediario-nao-objeto.

    Returns a new object rather than mutating, so a failure deeper in the path
    cannot leave a half-assigned story behind for the caller to write out.
    """
    head = segments[0]
    if segments[1:]:
        child = jq_setpath(
            jq_index(value, head, owner), segments[1:], new_value, owner + "." + head
        )
    else:
        child = new_value
    if value is None:
        return {head: child}
    if isinstance(value, dict):
        # Same as jq's `.k = v`: an existing key keeps its position, a new one
        # is appended. update-field's own echo-back printed the result, so the
        # order was always visible.
        updated = dict(value)
        updated[head] = child
        return updated
    raise MalformedTasks(owner + "." + head + ": cannot index " + _json_type(value))


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


def _emit_compact(value):
    """One JSON value on stdout with no spaces at all -- bash's `echo`, not jq.

    The gate refusal was a literal string in aimi-cli.sh, not a jq program, so
    it never had jq's two-space indent. part1 compares the whole line, so the
    separators are the contract rather than a preference.
    """
    json.dump(value, sys.stdout, separators=(",", ":"), ensure_ascii=False)
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


def write_docs_atomically(path, docs):
    """The whole STREAM back, into a temp file beside the target, then rename.

    roadmap.py's write_doc_atomically discipline exactly -- NamedTemporaryFile
    in the target's OWN directory (so the rename is within one filesystem and
    therefore atomic), fully written and closed, then os.replace, and on any
    exception the temp file is closed and unlinked before the exception
    propagates. A half-written tasks.json is the worst failure this port could
    introduce: /aimi:execute reads this file after every story.

    Not imported from roadmap.py, and this is the reason: jq read a stream and
    wrote a stream, so a tasks file holding two concatenated documents came
    back with BOTH of them rewritten. write_doc_atomically writes one value.
    mark-complete-dois-documentos records what jq produced and this reproduces
    it; the pre-port mktemp-then-mv it replaces is gone from bash entirely.

    jq_numbers on the way out for the same reason _emit applies it on the way
    to stdout: jq put every number through a double before printing it, so a
    priority someone wrote as 3.0 came back out of a rewrite as 3.
    """
    directory = os.path.dirname(path) or "."
    handle = tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=directory, prefix=os.path.basename(path) + ".", delete=False
    )
    try:
        for doc in docs:
            json.dump(jq_numbers(doc), handle, indent=2, ensure_ascii=False)
            handle.write("\n")
        handle.close()
        os.replace(handle.name, path)
    except BaseException:
        handle.close()
        try:
            os.unlink(handle.name)
        except OSError:
            pass
        raise


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
# The write rules -- seven verbs, all of them called from inside bash's lock
# ---------------------------------------------------------------------------


def _story_slots(doc):
    """`.userStories` and the keys an update can write back through.

    jq's `(.userStories[] | select(...)) |= f` is a PATH expression: it updates
    in place, and it does so for an object exactly as for an array, which is
    why `userStories: {"a": {...}}` comes back an object while `map` (the
    normalizers' verb) turns the same input into an array. Both are recorded.

    jq_iterate is called for its refusal alone, so a userStories the readers
    cannot iterate is refused here over the same field and in the same words.
    """
    container = jq_index(doc, "userStories")
    jq_iterate(container, ".userStories")
    keys = range(len(container)) if isinstance(container, list) else list(container)
    return container, keys


def _selected_slots(doc, story_id):
    """The `select(.id == $id)` half, over every slot.

    Every story is indexed, not only the matching ones -- that is jq's own
    order of business and it is why a userStories carrying a bare string is
    refused even when the story being marked sits before it.
    """
    container, keys = _story_slots(doc)
    return container, [key for key in keys if jq_index(container[key], "id", STORY) == story_id]


def mark_stories(doc, story_id, patch):
    """`(.userStories[] | select(.id == $id)) |= . + $patch`, the four mark-*.

    Every match is updated, not the first: a tasks file carrying the same id
    twice had both stories marked, and mark-complete-id-duplicado records it.
    """
    container, selected = _selected_slots(doc, story_id)
    for key in selected:
        container[key] = jq_add_object(container[key], patch, STORY)


def assign_field(doc, story_id, segments, value):
    """`(.userStories[] | select(.id == $id) | .a.b) = $val` -- update-field.

    `value` arrives as a str and is assigned as one. jq passed it with --arg,
    so "3" stayed the string "3" and "true" stayed the string "true"; a caller
    that wanted a number never got one and still does not.
    """
    container, selected = _selected_slots(doc, story_id)
    for key in selected:
        container[key] = jq_setpath(container[key], segments, value, STORY)


def field_payload(doc, story_id, top):
    """`.userStories[] | select(.id == $id) | {id, <top>}`, read back AFTER the
    write -- one object per match, and jq's shorthand emits a key holding null
    when the story has no such field."""
    return [
        {"id": jq_index(story, "id", STORY), top: jq_index(story, top, STORY)}
        for story in stories_with_id(doc, story_id)
    ]


def _status_defaulted(story):
    """`.status //= "pending"` on one story.

    `//=` is `. = (. // "pending")`, so it ALWAYS assigns: a story whose status
    is null or false gets "pending", one whose status is the empty string keeps
    "" (jq's `//` fires on null and false alone), and a story that had no
    status at all ends up with one. Assignment onto null builds the object, so
    a null STORY comes back as {"status": "pending"} -- recorded as
    normalize-status-historia-null.
    """
    value = jq_alternative(jq_index(story, "status", STORY), "pending")
    if story is None:
        return {"status": value}
    updated = dict(story)
    updated["status"] = value
    return updated


def _verification_migrated(story):
    """The one rewrite normalize-verification performs, and only that one.

    A string-typed verification (including the EMPTY string, which is not null)
    becomes the four-key object; every other shape -- absent, null, a number,
    an array, an object already -- is returned untouched, null stories
    included.
    """
    verification = jq_index(story, "verification", STORY)
    if verification is None or not isinstance(verification, str):
        return story
    updated = dict(story)
    updated["verification"] = {
        "strategy": verification,
        "status": "pending",
        "url": None,
        "expect": None,
    }
    return updated


def _mapped_stories(doc, rule):
    """`.userStories |= map(rule)`, which yields an ARRAY whatever it was given.

    That is jq's `map`, not a detail of this port: `userStories: {"a": …}`
    normalizes into a LIST of stories, and the two -us-objeto cases record it.
    """
    stories = [rule(story) for story in jq_iterate(jq_index(doc, "userStories"), ".userStories")]
    doc["userStories"] = stories
    return stories


def _counted(stories, predicate):
    """The `[…] | length` report both normalizers print, read off the document
    the write just produced rather than off a second read of the file."""
    return len([story for story in stories if predicate(story)])


def normalize_status(doc):
    """map, then `[.userStories[] | select(has("status"))] | length`.

    The count is always the story count once the map has run, because `//=`
    gives every story the key. It is computed rather than assumed so that a
    rule change shows up in the number.
    """
    return _counted(_mapped_stories(doc, _status_defaulted), lambda s: "status" in s)


def normalize_verification(doc):
    """map, then the count of stories whose verification is a non-null OBJECT
    -- which includes the ones that were already objects before the run, and
    excludes a number or an array that this verb declines to touch."""
    return _counted(
        _mapped_stories(doc, _verification_migrated),
        lambda s: isinstance(jq_index(s, "verification", STORY), dict),
    )


# ---------------------------------------------------------------------------
# The four rules that used to be evaluated before the lock
# ---------------------------------------------------------------------------
#
# Read the module docstring's third paragraph first. Everything in this section
# is a rule aimi-cli.sh used to evaluate in an unlocked jq and then act on
# under the lock. Here each one is evaluated against the very document its
# write goes on to produce, which is the whole of the fix -- there is no second
# read, so there is nothing for a concurrent writer to invalidate.


CASCADE_NOTE = "Skipped: depends on failed story "
ORPHAN_PATCH = {"status": "failed", "notes": "Reset: orphaned from previous session"}


def _depends_on_any(story, skip_ids):
    """`(.dependsOn // []) | any(. as $d | $skip_ids | any(. == $d))`.

    Both `any`s short-circuit, as jq's do. `//` leaves 0, "" and {} alone, so a
    `dependsOn` of 0 reaches jq_iterate and aborts there -- which is what jq
    did, and is NOT the same value space `_dependencies` walks through
    jq_length in the readiness predicate.
    """
    deps = jq_alternative(jq_index(story, "dependsOn", STORY), [])
    for dep in jq_iterate(deps, STORY + ".dependsOn"):
        for skip_id in skip_ids:
            if skip_id == dep:
                return True
    return False


def cascade_skip_ids(stories, failed_id):
    """The transitive skip set, WITH the two status filters that decide it.

    jq built this with `reduce range($root.userStories | length)` -- one pass
    per story, each pass adding every not-completed, not-skipped story that
    depends on something already in the set, and `unique` on every iteration.
    n passes always reach the fixpoint for n stories, so stopping when the set
    stops growing gives the identical answer; a fan of 400 stories converges in
    two passes rather than four hundred. Ranging over the whole length was also
    what made this quadratic, and the seconds of unlocked computation it cost
    were what made the lost-update window wide enough to hit deterministically.

    THE TWO FILTERS ARE THE FIX. `status != "completed"` and `status !=
    "skipped"` were tested only here, in the call that used to run outside the
    lock; the locked apply asked a weaker question -- is this id in the list --
    and never re-read status. They are now decided against the same document
    the write goes on to produce, so a story that completed a moment ago is
    seen as completed and is never added.

    `and` short-circuits the way jq's does, so a completed story's `dependsOn`
    is never iterated and never aborts on a shape the walk would not like.
    """
    skip_ids = [failed_id]
    while True:
        grown = jq_unique(
            skip_ids
            + [
                jq_index(story, "id", STORY)
                for story in stories
                if jq_index(story, "status", STORY) != "completed"
                and jq_index(story, "status", STORY) != "skipped"
                and _depends_on_any(story, skip_ids)
            ]
        )
        if grown == skip_ids:
            # `map(select(. != $failed_id))`: the failed story is the seed of
            # its own closure and never appears in its own skip list.
            return [skip_id for skip_id in skip_ids if skip_id != failed_id]
        skip_ids = grown


def cascade_skip(doc, failed_id):
    """The closure, then `.userStories |= [.[] | if <in set> then . + {…}]`.

    The apply keeps jq's ARRAY-producing form -- `[...]`, not the in-place path
    update reset_orphaned uses -- so a `userStories` object comes back a list,
    which is what the jq did.
    """
    skip_ids = cascade_skip_ids(_stories(doc), failed_id)
    patch = {"status": "skipped", "notes": CASCADE_NOTE + failed_id}
    _mapped_stories(
        doc,
        lambda story: jq_add_object(story, patch, STORY)
        if any(skip_id == jq_index(story, "id", STORY) for skip_id in skip_ids)
        else story,
    )
    return skip_ids


def reset_orphaned(doc):
    """The orphan list AND the reset, from one selection.

    jq made the same selection twice: once unlocked to build the printed
    report, once under the lock to write. Only the report could be wrong --
    the locked apply re-selected `status == "in_progress"` and ignored the
    precomputed list entirely, so the file was already correct and a story that
    completed mid-flight was already left alone. COSMETIC, and deliberately not
    ranked with cascade-skip: no data was ever lost here, and the fix recovers
    none. What it fixes is that the ids printed are now the ids written.

    `(.userStories[] | select(...)) |= . + {…}` is an in-place path update, so
    a `userStories` object stays an object -- the opposite of cascade_skip's
    form, and both are jq's.
    """
    container, keys = _story_slots(doc)
    selected = [
        key for key in keys if jq_index(container[key], "status", STORY) == "in_progress"
    ]
    reset = [jq_index(container[key], "id", STORY) for key in selected]
    for key in selected:
        container[key] = jq_add_object(container[key], ORPHAN_PATCH, STORY)
    return reset


def story_gates(docs, story_id):
    """Every matching story's `.gate`, across the whole stream.

    The precondition bash evaluated before the lock, in the shape it evaluated
    it: `[.userStories[] | select(.id == $id) | .gate] | length` counted the
    MATCHES (a story with no gate still yields one null), and the second jq
    printed those gates for a string comparison against "null". Both are one
    read of one list here.
    """
    return [
        jq_index(story, "gate", STORY)
        for doc in docs
        for story in stories_with_id(doc, story_id)
    ]


def gate_is_absent(gates):
    """bash's `[ "$has_gate" -eq 0 ] || [ "$(jq …)" = "null" ]`, to the case.

    No match at all is the first arm -- reachable now that the check runs under
    the lock, because the story can be deleted between validate_story_exists
    and the crossing. One match whose gate is null is the second: jq rendered
    that single value as the four characters `null`. TWO matches rendered as
    two lines, which never equalled "null", so a duplicated story id fell
    through to the write -- reproduced rather than tidied, because a tasks file
    carrying one id twice is a broken file and what to do about it is a
    decision, not a port.
    """
    return not gates or (len(gates) == 1 and gates[0] is None)


def set_gate(doc, story_id, patch):
    """`(.userStories[] | select(.id == $id) | .gate) |= . + $patch`.

    jq_setpath for the `.gate` half so an existing gate keeps its position in
    the story and a story with no gate gains the key at the end; jq_add_object
    for the `+` so the fixture's type, prompt and options survive a merge that
    only writes status (and selectedOption).
    """
    container, selected = _selected_slots(doc, story_id)
    for key in selected:
        story = container[key]
        merged = jq_add_object(jq_index(story, "gate", STORY), patch, STORY + ".gate")
        container[key] = jq_setpath(story, ["gate"], merged, STORY)


def gate_payload(docs, story_id):
    """`.userStories[] | select(.id == $id) | {id, gate}`, read off the
    document the write just produced rather than off a second read of the
    file -- which is what the jq echo-back after the lock was."""
    return [
        {"id": jq_index(story, "id", STORY), "gate": jq_index(story, "gate", STORY)}
        for doc in docs
        for story in stories_with_id(doc, story_id)
    ]


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


# The four mark-* verbs differed in one string, and mark-failed in one more
# field. They were four near-identical jq programs in aimi-cli.sh; here they are
# one op built four times, so a fifth status could not acquire a fifth spelling.
MARK_STATUS = {
    "mark-complete": "completed",
    "mark-failed": "failed",
    "mark-in-progress": "in_progress",
    "mark-skipped": "skipped",
}


def _mark_op(verb):
    """One locked mark, read-decide-write in the single crossing bash makes.

    Prints NOTHING. All four verbs keep their own `printf` line in bash,
    together with the write_state/clear_state_file calls that belong to
    .aimi/state/ -- this op owns the tasks file and nothing else.
    """
    status = MARK_STATUS[verb]

    def op(argv):
        path = _flag(argv, "--tasks-file")
        story_id = _flag(argv, "--story-id")
        if not path or story_id is None:
            die(
                "Usage: tasks.py " + verb + " --tasks-file <path> --story-id <id>"
                + (" [--notes <text>]" if status == "failed" else "")
            )
        patch = {"status": status}
        if status == "failed":
            # jq's `--arg notes "$notes"`: always a string, "" when the caller
            # gave none, and it lands beside status in one merge.
            patch["notes"] = _flag(argv, "--notes") or ""
        docs = read_docs(path, verb)
        for doc in docs:
            mark_stories(doc, story_id, patch)
        write_docs_atomically(path, docs)
        return 0

    return op


def op_update_field(argv):
    """The write and the echo-back, in one crossing.

    They were two jq programs over the same file, the second re-reading what
    the first had just written. The field path is NOT re-validated here:
    validate_field_path gates it in bash before the lock is taken, and in
    Python there is no filter to inject into -- the segments index a dict.
    """
    path = _flag(argv, "--tasks-file")
    story_id = _flag(argv, "--story-id")
    field_path = _flag(argv, "--field-path")
    # --value LAST on the command line, and read by name: it is the one
    # argument bash has not pattern-checked, so a value that looks like a flag
    # must not be able to answer for one. Every earlier flag wins its own
    # lookup because _flag takes the FIRST occurrence.
    value = _flag(argv, "--value")
    if not path or story_id is None or not field_path or value is None:
        die(
            "Usage: tasks.py update-field --tasks-file <path> --story-id <id> "
            "--field-path <a.b> --value <text>"
        )
    segments = field_path.split(".")
    docs = read_docs(path, "update-field")
    for doc in docs:
        assign_field(doc, story_id, segments, value)
    write_docs_atomically(path, docs)
    for doc in docs:
        for payload in field_payload(doc, story_id, segments[0]):
            _emit(payload)
    return 0


def _normalize_op(verb, rule):
    """Both normalizers: map, write, and report the count from the SAME call.

    The count used to be a second jq run after the lock had been released,
    which made it a re-read of a document another writer could already have
    changed. Folding it into the crossing makes it a read of what this write
    produced; in the single-process case the value is identical, which is why
    the golden is delta zero here.
    """

    def op(argv):
        path = _flag(argv, "--tasks-file")
        if not path:
            die("Usage: tasks.py " + verb + " --tasks-file <path>")
        docs = read_docs(path, verb)
        counts = [rule(doc) for doc in docs]
        write_docs_atomically(path, docs)
        for count in counts:
            _emit({"normalized": count})
        return 0

    return op


def op_cascade_skip(argv):
    """Closure, filters, write and report -- the one crossing bash now makes.

    It was two jq calls with the lock between them, and the report was built
    from the first. Prints `{skipped, count}` in that key order, which is the
    order the jq object literal named them in.
    """
    path = _flag(argv, "--tasks-file")
    failed_id = _flag(argv, "--failed-id")
    if not path or failed_id is None:
        die("Usage: tasks.py cascade-skip --tasks-file <path> --failed-id <id>")
    docs = read_docs(path, "cascade-skip")
    reports = [cascade_skip(doc, failed_id) for doc in docs]
    write_docs_atomically(path, docs)
    for skipped in reports:
        _emit({"skipped": skipped, "count": len(skipped)})
    return 0


def op_reset_orphaned(argv):
    """One selection, used for both the write and the report.

    Writes NOTHING when nothing was orphaned. bash returned before the lock was
    even set up in that case, and part1 asserts the file is untouched; the
    decision moves inside the lock, the guarantee does not move at all.
    """
    path = _flag(argv, "--tasks-file")
    if not path:
        die("Usage: tasks.py reset-orphaned --tasks-file <path>")
    docs = read_docs(path, "reset-orphaned")
    reports = [reset_orphaned(doc) for doc in docs]
    if any(reports):
        write_docs_atomically(path, docs)
    for reset in reports:
        _emit({"count": len(reset), "reset": reset})
    return 0


def _gate_op(verb, status):
    """gate-pass and gate-fail, which differed in one string and one flag.

    The refusal, the write and the echo-back were three crossings with the lock
    around only the middle one. They are one call now, so the gate a story has
    when the write lands is the gate the precondition looked at.
    """

    def op(argv):
        path = _flag(argv, "--tasks-file")
        story_id = _flag(argv, "--story-id")
        if not path or story_id is None:
            die(
                "Usage: tasks.py " + verb + " --tasks-file <path> --story-id <id>"
                + (" [--option <text>]" if status == "passed" else "")
            )
        docs = read_docs(path, verb)
        if gate_is_absent(story_gates(docs, story_id)):
            # bash's own line, to the byte and on stdout, because that is where
            # it printed it and part1 compares the whole string. Exit 1, and
            # nothing has been written -- the write is below this return.
            _emit_compact(
                {"valid": False, "errors": ["Story " + story_id + " has no gate defined"]}
            )
            return 1
        patch = {"status": status}
        option = _flag(argv, "--option")
        if option is not None:
            # bash refuses an empty --option before the crossing, so a value
            # that arrives here is one the caller meant.
            patch["selectedOption"] = option
        for doc in docs:
            set_gate(doc, story_id, patch)
        write_docs_atomically(path, docs)
        for payload in gate_payload(docs, story_id):
            _emit(payload)
        return 0

    return op


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
    "mark-complete": _mark_op("mark-complete"),
    "mark-failed": _mark_op("mark-failed"),
    "mark-in-progress": _mark_op("mark-in-progress"),
    "mark-skipped": _mark_op("mark-skipped"),
    "update-field": op_update_field,
    "normalize-status": _normalize_op("normalize-status", normalize_status),
    "normalize-verification": _normalize_op("normalize-verification", normalize_verification),
    "cascade-skip": op_cascade_skip,
    "reset-orphaned": op_reset_orphaned,
    "gate-pass": _gate_op("gate-pass", "passed"),
    "gate-fail": _gate_op("gate-fail", "failed"),
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
