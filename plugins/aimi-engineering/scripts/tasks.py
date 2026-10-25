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

The FOUR VALIDATORS -- `validate-deps`, `validate-stories`, `validate-ids` and
`validate-waves` -- are readers too, and took no lock either. Their whole
observable contract is a JSON verdict plus an exit status, which made them the
cleanest thing in this port to prove: every input maps to one deterministic
answer with no document left behind to reason about. What makes them delicate
is the other end -- /aimi:plan's Phase 4.5 loop and its Phase 3e staging check
read the error STRINGS, so a divergence surfaces as a planning failure rather
than as a test failure. Three of their contract details look like defects and
are reproduced deliberately; the section that holds them says which and why.

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
    run that passed. THOSE THREE LINES stay in bash permanently, and the string
    "cli-path" appears nowhere in this file. Its three DOCUMENT reads did cross
    -- op_init_session below -- and the seam between the two halves is marked in
    aimi-cli.sh: everything above it is about where this script is, everything
    below it about what the document says.

WHERE jq AND PYTHON PART COMPANY
--------------------------------

jq indexes null happily, orders values across types, reads a STREAM of JSON
values rather than one, gives a number a length, ends an `all` at the first
element that answers nothing, and aborts with its own engine message on a shape
it cannot handle. Each of those is reproduced deliberately below -- jq_index,
clamp_max_concurrency's comparison, read_docs, jq_length, jq_all_over, and
MalformedTasks -- and the one place fidelity is impossible (the engine's own
wording and exit status) is recorded case by case in
tests/golden_from_jq.json's `tasks_read_cases`, `tasks_ready_cases`,
`tasks_write_cases` and `tasks_validate_cases`, whose `_comment_tasks_read`,
`_comment_tasks_ready`, `_comment_tasks_write` and `_comment_tasks_validate`
name every divergence and what it cost.

The validators added five more of jq's habits, none of them optional: `==`
says a boolean is not a number where Python says it is (jq_equal), `index`
searches for a SUBSEQUENCE when handed an array (jq_index_in), `-r` unquotes a
string and pretty-prints everything else over as many lines as it takes
(jq_raw), interpolation compacts the same values onto one (jq_tostring), and
`has` refuses both a non-object and a non-string key rather than answering
false (jq_has).

Three more of jq's habits belong to the writers alone: `. + {…}` treats null as
the empty object, `.a.b = v` BUILDS the intermediates it walks through, and
`map` over an object yields an ARRAY. jq_add_object, jq_setpath and the two
normalize rules reproduce all three.
"""

import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

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
from roadmap import (
    TERMINAL_STORY_STATUSES,
    _completed_gate_has_marker,
    _completed_story_ids,
    _json_type,
    ground_truth,
    jq_numbers,
    jq_sort_key,
)

# compute_waves is the WRITER's own rule -- roots at 1, everyone else at
# max(dependency waves) + 1. normalize_waves (below) recomputes a stale
# `wave` field with this same import rather than restating the rule from
# prose: two implementations of one rule drift, and story_merge.py is the
# one this verb exists to agree with. computed_waves further down in this
# file is a DIFFERENT function -- validate_waves' own read-only twin, which
# returns a dict and omits any story a cycle or a dangling dependency never
# reaches. This import is the writer; that one stays the checker.
from story_merge import compute_waves

# The one prose sanitizer roadmap.py and story_merge.py already import -- see
# sanitize.py's own docstring for why it is a module of its own rather than a
# copy in whichever file reached for it first. op_remove_story (below) is the
# first WRITER of metadata.decisions anywhere in this file -- every existing
# entry is written command-side, at plan time -- so it needs the identical
# rule rather than a third copy of it.
from sanitize import rm_sanitize, SUSPICIOUS

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
    """jq's `length`, over the values these verbs can actually hand it.

    It is not Python's len(), and the difference decides whether a story is
    ready: a NUMBER's length is its absolute value, so `dependsOn: 0` has
    length 0 and short-circuits the dependency walk to true exactly as `[]`
    does, and an empty STRING does the same. Both are recorded (depende-formas)
    because both are stories the pre-port CLI listed as ready.

    NULL HAS LENGTH 0, which the readiness predicate never sees -- `//` had
    already replaced it -- and validate-stories reaches on its first line:
    `.title | length` runs against a story with no title, and answering 0 there
    is what keeps such a story merely un-flagged rather than refused.

    A boolean is the one value with no length at all -- jq aborts there, and so
    does this.
    """
    if value is None:
        return 0
    if isinstance(value, bool):
        raise MalformedTasks(
            owner + ": boolean (" + ("true" if value else "false") + ") has no length"
        )
    if isinstance(value, (int, float)):
        return abs(value)
    return len(value)


def jq_type(value):
    """jq's `type` builtin -- the six names jq itself prints, not prose.

    Distinct from roadmap.py's _json_type, which produces "a string" for a
    DIAGNOSTIC. These names are compared against string literals the jq source
    wrote out (`!= "array"`, `== "string"`), so they have to be jq's spelling.
    """
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, str):
        return "string"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, list):
        return "array"
    return "object"


def jq_equal(left, right):
    """jq's `==`, which is NOT Python's over the shapes a tasks file can hold.

    Python says `1 == True` and `0 == False`; jq says neither, because a
    boolean and a number are different types in its total order. validate-waves
    compares a stored wave against a computed one and a hand-edited `wave: true`
    has to come out as a mismatch (wave-true records that it does), so the type
    is checked before the value.

    Deep for arrays and objects, because a dependsOn entry can be either and
    `[1] == [true]` would otherwise be true here and false in jq.
    """
    if jq_type(left) != jq_type(right):
        return False
    if isinstance(left, list):
        return len(left) == len(right) and all(
            jq_equal(a, b) for a, b in zip(left, right)
        )
    if isinstance(left, dict):
        return set(left) == set(right) and all(
            jq_equal(left[key], right[key]) for key in left
        )
    return left == right


def jq_tostring(value):
    """jq's `tostring`, which is also what string INTERPOLATION does.

    A string interpolates as itself with no quotes; everything else as its
    COMPACT JSON form. Both halves are load-bearing: `\\($story.id)` on a real
    id must not gain quotes, and `\\($dep)` on a hand-edited number has to read
    `3` -- deps-heterogeneo records "depends on 3 which does not exist".
    """
    if isinstance(value, str):
        return value
    return json.dumps(jq_numbers(value), separators=(",", ":"), ensure_ascii=False)


def jq_quoted(value):
    """`tostring`'s own JSON-encode branch, applied unconditionally.

    jq_tostring above deliberately leaves a STRING unquoted, because every
    existing caller interpolates the result inline next to prose that already
    marks where it sits (an id before a colon, a skill name inside brackets).
    validate-stories' verification.strategy/status refusal is the first
    caller that needs the opposite: the found value has to stand out as a
    literal inside a sentence that also names the allowed set, so a string
    renders through its own JSON quotes here -- `"vizual"`, not `vizual` --
    rather than dropping them the way interpolation does. Anything that is
    not a string already renders identically to jq_tostring, because this
    IS jq_tostring's own non-string branch, reused rather than duplicated.
    """
    return json.dumps(jq_numbers(value), separators=(",", ":"), ensure_ascii=False)


def jq_raw(value):
    """One line of `jq -r` output, which is NOT jq_tostring.

    `-r` unquotes a STRING and leaves every other value to jq's ordinary
    printer, which is the PRETTY one -- so an id that is `[1, 2]` comes out over
    four lines and validate-ids, which reads that output a line at a time,
    reports four malformed ids from one story. Recorded as id-array.
    """
    if isinstance(value, str):
        return value
    return json.dumps(jq_numbers(value), indent=2, ensure_ascii=False)


def jq_has(value, key, owner):
    """jq's `has`, which is strict about both halves and says so.

    Only an object answers -- `has` on a string is jq's "Cannot check whether
    string has a string key", which is what a story whose `gate` is a bare
    string hits -- and only a string is a key an object can be asked about,
    which is what validate-waves hits on a dependsOn holding null.
    """
    if not isinstance(value, dict):
        raise MalformedTasks(owner + ": cannot check whether " + _json_type(value) + " has a key")
    if not isinstance(key, str):
        raise MalformedTasks(
            owner + ": cannot check whether an object has " + _json_type(key) + " as a key"
        )
    return key in value


def jq_test(value, pattern, owner, ignore_case=True):
    """jq's `test(re)`, with or without the "i" validate-stories always passed.

    jq refuses a non-string input rather than treating it as no match, which is
    why a story whose `project` is a number aborts validate-stories instead of
    being reported -- projeto-numero records the abort.

    validate-tasks' url charset test is the one call site with NO flag, and it
    passes ignore_case=False rather than relying on its allowlist spelling both
    cases out. The two are the same answer today; a later edit to the allowlist
    should not be able to change that quietly.
    """
    if not isinstance(value, str):
        raise MalformedTasks(
            owner + ": " + _json_type(value) + " cannot be matched, as it is not a string"
        )
    return re.search(pattern, value, re.IGNORECASE if ignore_case else 0) is not None


def jq_index_in(array, needle):
    """jq's `index`, whose two behaviours are decided by the NEEDLE's type.

    A scalar needle is an element search. An ARRAY needle is a contiguous
    SUBSEQUENCE search, so `["US-001"] | index(["US-001"])` is 0 and a
    `dependsOn` holding `["US-001"]` is therefore NOT reported as a missing id
    -- deps-array-elemento records that pass, which an element search would
    turn into a false error. An empty array needle finds nothing at all.
    """
    if isinstance(needle, list):
        if not needle:
            return None
        for start in range(len(array) - len(needle) + 1):
            if all(jq_equal(array[start + offset], needle[offset]) for offset in range(len(needle))):
                return start
        return None
    for position, item in enumerate(array):
        if jq_equal(item, needle):
            return position
    return None


def jq_group_by(values):
    """jq's `group_by(.)`: sort by jq's total order, then group adjacent equals.

    Only validate-stories' duplicate-skill rule reaches it, and it reaches it
    for the FIRST element of each group of more than one -- which is why the
    order matters at all: the reported duplicate is the sorted-first copy, not
    the first one the author wrote.
    """
    groups = []
    for value in sorted(values, key=jq_sort_key):
        if groups and jq_equal(groups[-1][0], value):
            groups[-1].append(value)
        else:
            groups.append([value])
    return groups


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


def streamed_docs(path):
    """The file's JSON values ONE AT A TIME, raising where jq stopped.

    jq is a streaming filter: it had already printed document 1's answer when
    document 2 failed to parse. Every verb but one wants the whole file or
    nothing, and load_docs below gives them that by draining this. research-gc
    is the exception -- it reads the stream for its side effects and keeps what
    arrived before the abort, because a port that parsed each file whole would
    lose document 1's researchPaths and then DELETE the research file they
    name (rgc-dois-documentos-segundo-malformado).
    """
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()

    decoder = json.JSONDecoder()
    index = 0
    while True:
        while index < len(text) and text[index] in " \t\r\n":
            index += 1
        if index >= len(text):
            return
        value, index = decoder.raw_decode(text, index)
        yield value


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

    The list() is eager on purpose: every caller here is inside a `try` that
    expects the parse failure to surface from THIS call, not from whatever
    iterates the result later.
    """
    return list(streamed_docs(path))


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


# ground_truth's six phase-classification answers, remapped onto the four
# run-verdict values a caller outside roadmap.py's own phase-claim machinery
# actually needs. "" and "unknown" both mean the document told ground_truth
# nothing usable (unreadable as a tasks file, or userStories absent/empty);
# verification_failed and in_progress both mean the run is stuck rather than
# finished, including ground_truth's residual in_progress bucket -- a mix of
# pending and completed/skipped with no story ever explicitly claimed, i.e. a
# session killed at a wave boundary before the next story was claimed. That
# case is not a fifth verdict: it falls out of importing ground_truth whole
# rather than restating its four bullets, exactly as the mapping intends.
_RUN_VERDICT_FROM_GROUND_TRUTH = {
    "": "undetermined",
    "unknown": "undetermined",
    "verification_failed": "interrupted",
    "in_progress": "interrupted",
    "planned": "never-run",
    "completed": "delivered",
}


def run_verdict(doc):
    """Classify a tasks file's execution state: never-run, delivered,
    interrupted, or undetermined.

    Answers by calling roadmap.ground_truth(doc) and remapping its six-way
    phase classification through _RUN_VERDICT_FROM_GROUND_TRUTH, rather than
    re-implementing ground_truth's branching rule here. ground_truth's own
    docstring names why: "the one rule reconcile and the has-work map both
    read, so they cannot drift" -- a third copy in tasks.py would be exactly
    the drift risk that warning is about, and would also have to reproduce a
    precedence that is easy to get wrong by hand: failed is checked BEFORE
    either terminal-set branch, and completed-or-skipped is ONE terminal set.

    The mapping also picks up ground_truth's own residual case for free: a
    tasks file with one story completed and the rest still pending, with no
    story ever marked in_progress or failed, is not "every story pending"
    (not never-run) and not "every story terminal" (not delivered) -- it is
    the in_progress bucket ground_truth falls through to by elimination, and
    that reads interrupted here too. A hand-written four-bullet restatement
    of "interrupted = any story is in_progress or failed" would miss exactly
    this case; importing ground_truth's actual rule does not.
    """
    return {"verdict": _RUN_VERDICT_FROM_GROUND_TRUTH[ground_truth(doc)]}


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
    -- pending, in_progress, failed, absent -- leaves the dependent blocked.

    The pair is TERMINAL_STORY_STATUSES rather than two literals: the identical
    rule decides whether a PHASE is finished (roadmap.py's ground_truth) and
    whether a split member is still active (aimi-cli.sh's split-detect), and the
    three answered differently once. See the constant for why it lives in
    roadmap.py and not here."""
    status = jq_index(dep, "status", STORY)
    return status in TERMINAL_STORY_STATUSES


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
# The four validators -- a verdict and an exit status, and nothing else
# ---------------------------------------------------------------------------
#
# /aimi:plan's Phase 4.5 loop and its Phase 3e staging check read these error
# STRINGS, not merely the boolean beside them, so every message below is the jq
# one to the character. Two of them look like typos and are not corrections to
# make here:
#
#   * validate-ids says "(expected US-NNN)" while its regex accepts an optional
#     lowercase suffix. task-format-v3.md documents `^US-\d{3}[a-z]?$` with
#     US-012a as its example, so the REGEX is the contract and the message
#     describes the common case. US-001a is accepted, and id-sufixo records it.
#   * the plural-gates message reads `gates` and `gate` with no quotes around
#     either, because the jq program was inside a bash SINGLE-quoted string and
#     the quotes the author wrote closed and reopened it. gates-plural records
#     the string bash actually assembled, which is the string /aimi:plan matches.
#
# And one omission, pinned rather than fixed: validate-waves has no `return 1`.
# Its bash body ended at the jq call, so an invalid verdict still exits 0 --
# the verdict lives in `.valid`, never in `$?`. See op_validate_waves.

# The prompt-injection screen's pattern, and the rationale for what it does and
# does not refuse, now live in sanitize.py beside the patch matcher that shares
# it. This module cannot own the definition: sanitize.py is imported here, and an
# import the other way would be circular. The three call sites are in
# _story_errors below.

# aimi-cli.sh's `[[ "$id" =~ ^US-[0-9]{3}[a-z]?$ ]]`, verbatim. The optional
# lowercase suffix is the contract; see the note above before "fixing" it.
STORY_ID_PATTERN = "^US-[0-9]{3}[a-z]?$"

VALID_SKILL = "^[a-zA-Z0-9][a-zA-Z0-9_-]*$"
VALID_PROJECT = "^[a-zA-Z0-9_.][a-zA-Z0-9_./@-]*$"
PATH_COMPONENT = ("\\.\\.", "/", "[\\$`;|&]")
GATE_KEYS = ("type", "status", "prompt")

# The ONLY place either tuple is written as a literal. A later verb that needs
# the documented value set (set-verification, judge-verification, the
# completed gate) imports these two rather than restating them -- the same
# discipline GATE_KEYS above already keeps. See
# plugins/aimi-engineering/skills/task-planner/references/task-format-v3.md's
# Verification Object table for the schema-level statement of the same set.
VERIFICATION_STRATEGIES = ("test", "visual", "api")
VERIFICATION_STATUSES = ("pending", "passed", "failed", "skipped")

# set-verification's own cap on --reason, applied through rm_sanitize the same
# way remove-story caps its own --reason at 2000 -- picked and documented here
# rather than left as a bare literal at the call site. 500 is generous for a
# one-line explanation ("agent-browser not installed") while still bounding
# what a skipped verdict can carry into the document.
VERIFICATION_SKIP_REASON_MAXLEN = 500

# acknowledge-smell's own cap on --reason, through rm_sanitize like
# set-verification's -- its own name rather than a reuse of the verification
# constant, because the two are different fields that merely agree today.
SMELL_ACKNOWLEDGE_REASON_MAXLEN = 500

# acknowledge-evidence's own cap on --reason, through rm_sanitize. Its own
# name for the same reason: a different field that merely agrees today.
EVIDENCE_ACKNOWLEDGE_REASON_MAXLEN = 500

# set-verification never writes "pending" -- recording a verdict is the
# opposite of "nobody looked yet" -- so its own allowed set is this tuple
# minus "pending", DERIVED rather than re-literalled: the cross-story contract
# is one home for the value set, and a second tuple typed out by hand would be
# the second list that contract forbids.
_SET_VERIFICATION_STATUSES = tuple(s for s in VERIFICATION_STATUSES if s != "pending")


def _verdict(errors):
    """`if length == 0 then {valid: true, errors: []} else {valid: false, errors: .}`.

    The same two-branch literal all three of deps, stories and waves ended on.
    validate-ids is the one that does NOT use it -- its shape is asymmetric on
    purpose and is built in validate_ids itself.
    """
    if not errors:
        return {"valid": True, "errors": []}
    return {"valid": False, "errors": errors}


def validate_deps(doc):
    """Self-references, dangling ids and cycles, in the order jq appended them.

    The order is the output: `$self_refs + $missing_refs + $cycles` is one
    concatenation, so every self-reference precedes every missing id and every
    missing id precedes every cycle, whatever order the stories are in.
    """
    stories = _stories(doc)
    all_ids = [jq_index(story, "id", STORY) for story in stories]
    errors = []

    for story in stories:
        story_id = jq_index(story, "id", STORY)
        deps = jq_iterate(_dependencies(story), STORY + ".dependsOn")
        if any(jq_equal(dep, story_id) for dep in deps):
            errors.append("Self-reference: " + jq_tostring(story_id) + " depends on itself")

    for story in stories:
        story_id = jq_index(story, "id", STORY)
        for dep in jq_iterate(_dependencies(story), STORY + ".dependsOn"):
            if jq_index_in(all_ids, dep) is None:
                errors.append(
                    "Missing ID: " + jq_tostring(story_id) + " depends on "
                    + jq_tostring(dep) + " which does not exist"
                )

    for start in stories:
        start_id = jq_index(start, "id", STORY)
        reached = _reachable_deps(start, stories)
        if any(jq_equal(value, start_id) for value in reached):
            errors.append(
                "Circular dependency: " + jq_tostring(start_id)
                + " is part of a dependency cycle"
            )

    return _verdict(errors)


def _reachable_deps(start, stories):
    """One story's dependency closure -- jq's `reduce range(length)`, at a fixpoint.

    The jq ran exactly n passes for n stories, each pass adding the dependsOn of
    every story already named in the accumulator and running the result through
    `unique`. The accumulator only grows and n passes always reach the fixpoint
    (the longest chain through n stories is n-1 edges), so stopping when it
    stops growing gives the identical array -- the same argument cascade_skip_ids
    makes, and the same reason: n passes over n stories is quadratic for nothing.

    `unique` is why jq_sort_key has to be here. A hand-edited dependsOn holding
    a null beside a string sorts fine in jq and raises TypeError under a naive
    Python `sorted`; deps-heterogeneo is the recorded case.
    """
    current = _dependencies(start)
    if not isinstance(current, list):
        # jq's `$current + [...]`, which refuses anything but two arrays. The
        # self-reference walk above already refused a dependsOn it could not
        # ITERATE, so only a shape that iterates and cannot be added reaches here.
        raise MalformedTasks(
            STORY + ".dependsOn: cannot add an array to " + _json_type(current)
        )
    while True:
        grown = jq_unique(
            current
            + [
                dep
                for story in stories
                if any(jq_equal(value, jq_index(story, "id", STORY)) for value in current)
                for dep in jq_iterate(_dependencies(story), STORY + ".dependsOn")
            ]
        )
        if grown == current:
            return current
        current = grown


def _story_errors(story):
    """Every rule validate-stories applies to ONE story, in the jq's own order.

    The order is load-bearing for the same reason it is in is_ready: each rule
    can abort on a shape the one before it never looked at, so a document that
    aborts has to abort in the same place. A story with no acceptanceCriteria
    dies on rule 3 rather than reaching the title screen -- sem-criterios.
    """
    story_id = jq_tostring(jq_index(story, "id", STORY))
    errors = []

    if jq_length(jq_index(story, "title", STORY), STORY + ".title") > 200:
        errors.append(story_id + ": title exceeds 200 chars")
    if jq_length(jq_index(story, "description", STORY), STORY + ".description") > 500:
        errors.append(story_id + ": description exceeds 500 chars")
    criteria = jq_iterate(
        jq_index(story, "acceptanceCriteria", STORY), STORY + ".acceptanceCriteria"
    )
    if any(jq_length(c, STORY + ".acceptanceCriteria[]") > 5000 for c in criteria):
        errors.append(story_id + ": acceptance criterion exceeds 5000 chars")
    if jq_test(jq_index(story, "title", STORY), SUSPICIOUS, STORY + ".title"):
        errors.append(story_id + ": title contains suspicious content")
    if jq_test(jq_index(story, "description", STORY), SUSPICIOUS, STORY + ".description"):
        errors.append(story_id + ": description contains suspicious content")

    # The project chain is an if/elif in the jq too, so a project that is both
    # absolute and traversing is reported once, as absolute.
    project = jq_index(story, "project", STORY)
    if project is not None:
        owner = STORY + ".project"
        if jq_test(project, "^/", owner):
            errors.append(story_id + ": project must not be an absolute path")
        elif jq_test(project, "\\.\\.", owner):
            errors.append(story_id + ": project must not contain path traversal (..)")
        elif jq_test(project, "[\\$`;|&]", owner):
            errors.append(story_id + ": project contains shell metacharacters")
        elif not jq_test(project, VALID_PROJECT, owner):
            errors.append(story_id + ": project contains invalid characters")

    # No rule governs implementation.verify's working directory here, and that
    # is deliberate rather than an omission. A rule requiring a `cd <project>`
    # prefix shipped briefly and was removed: the executor already establishes
    # the CWD before verify ever runs (skills/story-executor/SKILL.md step 0),
    # so the prefix pointed at <project>/<project> in three of the four
    # layout-by-mode combinations. Issue #105's real defect is in that step 0
    # contract, not in what an author writes here. If a future rule does need
    # to read .implementation, it must go through a jq_type(...) == "object"
    # guard first -- a bare jq_index on it aborts the whole run on a document
    # whose implementation is a scalar, which is exactly how the removed rule
    # turned a per-story verdict into an exit 1.

    skills = jq_index(story, "skills", STORY)
    if skills is not None:
        owner = STORY + ".skills"
        if jq_type(skills) != "array":
            errors.append(story_id + ": skills must be an array")
        else:
            entries = jq_iterate(skills, owner)
            if jq_length(skills, owner) > 10:
                errors.append(story_id + ": skills array exceeds 10 entries")
            # Two separate passes, as the jq wrote them: a skill that is both
            # malformed and path-bearing is reported twice, once under each
            # heading, and skills-caminho records both lines.
            for skill in entries:
                if not jq_test(skill, VALID_SKILL, owner + "[]"):
                    errors.append(
                        story_id + ": skills[" + jq_tostring(skill) + "] contains invalid characters"
                    )
            for skill in entries:
                if any(jq_test(skill, p, owner + "[]") for p in PATH_COMPONENT):
                    errors.append(
                        story_id + ": skills[" + jq_tostring(skill)
                        + "] must not contain path components"
                    )
            if len(jq_unique(entries)) != jq_length(skills, owner):
                for group in jq_group_by(entries):
                    if len(group) > 1:
                        errors.append(
                            story_id + ": skills contains duplicate entry " + jq_tostring(group[0])
                        )

    tasks = jq_index(story, "tasks", STORY)
    if tasks is not None:
        owner = STORY + ".tasks"
        if jq_type(tasks) != "array":
            errors.append(story_id + ": tasks must be an array")
        elif jq_length(tasks, owner) == 0:
            errors.append(story_id + ": tasks must be omitted when empty")
        else:
            entries = jq_iterate(tasks, owner)
            if jq_length(tasks, owner) > 50:
                errors.append(story_id + ": tasks array exceeds 50 entries")
            for entry in entries:
                if jq_type(entry) != "string":
                    errors.append(story_id + ": tasks[] element must be a string")
            # `type == "string" and length > 5000` -- jq's `and` short-circuits,
            # which is what keeps a non-string entry from reaching `length` here
            # after it has already been reported above.
            for entry in entries:
                if jq_type(entry) == "string" and jq_length(entry, owner + "[]") > 5000:
                    errors.append(story_id + ": tasks[] entry exceeds 5000 chars")
            for entry in entries:
                if jq_type(entry) == "string" and jq_test(entry, SUSPICIOUS, owner + "[]"):
                    errors.append(story_id + ": tasks[] entry contains suspicious content")

    # No quotes around either word: see the note at the top of this section.
    if jq_has(story, "gates", STORY):
        errors.append(
            story_id + ": gate: gates field is invalid; use singular gate (see references/plan/phase-4-schema-v33.md § Schema v3.3 Structure)"
        )
    gate = jq_index(story, "gate", STORY)
    if gate is not None:
        for key in GATE_KEYS:
            if not jq_has(gate, key, STORY + ".gate"):
                errors.append(story_id + ": gate: missing required field " + key)

    verification = jq_index(story, "verification", STORY)
    if verification is not None and jq_type(verification) == "string":
        errors.append(
            story_id + ": verification must be an object {strategy, status, url, expect}; "
            "found bare string — run normalize-verification to fix"
        )
    elif jq_type(verification) == "object":
        # Guarding on the object type first is load-bearing, not defensive
        # style: jq_index raises MalformedTasks on a non-null, non-dict value,
        # so a hand-edited verification that is e.g. a number or array must
        # never reach jq_index(verification, "strategy", ...) below -- that
        # would abort the whole run instead of reporting a per-story error,
        # same as the .implementation guard a few rules above this one.
        owner = STORY + ".verification"
        strategy = jq_index(verification, "strategy", owner)
        if strategy is not None and strategy not in VERIFICATION_STRATEGIES:
            errors.append(
                story_id + ": verification.strategy " + jq_quoted(strategy)
                + " is not one of: " + ", ".join(VERIFICATION_STRATEGIES)
            )
        status = jq_index(verification, "status", owner)
        if status is not None and status not in VERIFICATION_STATUSES:
            errors.append(
                story_id + ": verification.status " + jq_quoted(status)
                + " is not one of: " + ", ".join(VERIFICATION_STATUSES)
            )
        # No skipReason presence check here on purpose: a legacy
        # status: "skipped" with no skipReason key at all is the on-disk
        # shape this phase's own research found, and it stays valid at this
        # verb. Requiring the field belongs to set-verification, which WRITES
        # it, never to this read-only validator.
    if not jq_has(story, "status", STORY):
        errors.append(
            story_id + ": missing required field: status — run normalize-status to fix"
        )
    errors += _guard_rail_errors(story_id, story)
    return errors


def _broken_guard_rails(implementation, rails):
    """The one place a guard rail is tested for being a top-level segment.

    Returns `(broken, texts)`: `broken` is `[(index, entry, kind)]` in index
    order for every rail that is not exactly one segment of the story's own
    implementation.verify, and `texts` the ordered segment texts the test was
    made against (empty when verify is not a string). `kind` is `not-string`
    for a non-string or empty entry, `no-verify` when verify is not a string
    at all, and `not-segment` for a string that equals no segment. The
    membership test is `verify_segments` reused rather than re-implemented,
    and `_guard_rail_errors`, `broken_rail_indices` and `guard_rail_findings`
    all read this list, so the three cannot disagree about which rails are
    broken.
    """
    verify = implementation.get("verify") if isinstance(implementation, dict) else None
    verified = isinstance(verify, str)
    texts = [segment for _, segment in verify_segments(verify)] if verified else []
    known = set(texts)
    broken = []
    for index, entry in enumerate(rails):
        if not isinstance(entry, str) or entry == "":
            broken.append((index, entry, "not-string"))
        elif not verified:
            broken.append((index, entry, "no-verify"))
        elif entry not in known:
            broken.append((index, entry, "not-segment"))
    return broken, texts


def _guard_rail_errors(story_id, story):
    """The implementation.guardRails rule, run last so no earlier error moves.

    A guard-rail label is the EXACT text of one segment `verify_segments` cuts
    from the story's own implementation.verify -- the splitter probe_verify
    walks, reused rather than re-implemented. The object-type guard comes
    first for the reason the note above gives: a bare jq_index on a scalar
    implementation would abort the whole run. An absent guardRails is no rule
    at all, so a document without the key validates byte for byte as before.
    The segment test itself is `_broken_guard_rails`, shared with the two
    readers below; this function only words its three messages.
    """
    implementation = jq_index(story, "implementation", STORY)
    if jq_type(implementation) != "object":
        return []
    rails = jq_index(implementation, "guardRails", STORY + ".implementation")
    if rails is None:
        return []
    if jq_type(rails) != "array":
        return [story_id + ": implementation.guardRails must be an array"]
    errors = []
    for index, _entry, kind in _broken_guard_rails(implementation, rails)[0]:
        label = story_id + ": implementation.guardRails[" + str(index) + "]"
        if kind == "not-string":
            errors.append(label + " must be a non-empty string")
        else:
            errors.append(label + " matches no segment of implementation.verify")
    return errors


def _guard_rail_subject(story):
    """`(implementation, rails)` when a story carries a guardRails LIST, else None.

    The public readers below take a plain dict and never raise, so each shape
    check is an isinstance rather than the jq_index the validator uses. A
    guardRails that is not a list is `_guard_rail_errors`' message to give and
    these two report nothing for it.
    """
    if not isinstance(story, dict):
        return None
    implementation = story.get("implementation")
    if not isinstance(implementation, dict):
        return None
    rails = implementation.get("guardRails")
    if not isinstance(rails, list):
        return None
    return implementation, rails


def broken_rail_indices(story):
    """Ascending indices of the guardRails entries that are not exactly one
    top-level segment of implementation.verify.

    `[]` when implementation or guardRails is absent, or guardRails is not a
    list. Duplicated rails are allowed: the test is membership.
    """
    subject = _guard_rail_subject(story)
    if subject is None:
        return []
    return [index for index, _entry, _kind in _broken_guard_rails(*subject)[0]]


_GUARD_RAIL_HEAD_CHARS = 40
_GUARD_RAIL_FUNCTION = re.compile(r"(?:function\s+[\w.:-]+|[A-Za-z_][\w.:-]*\s*\(\s*\))")
_GUARD_RAIL_HEREDOC = re.compile(r"(?<!<)<<(?!<)-?\s*['\"\\]?[A-Za-z_]")
_GUARD_RAIL_REMEDY = (
    "List the whole %s as the rail, or its top-level call line, never a line inside it."
)


def _guard_rail_head(entry):
    """A short, single-line, retry-safe quote of a rail: no backtick, no
    dollar followed by an open paren, whitespace collapsed, cut to a head."""
    text = " ".join(entry.replace("`", "").split())
    while "$(" in text:
        text = text.replace("$(", "(")
    if len(text) > _GUARD_RAIL_HEAD_CHARS:
        text = text[:_GUARD_RAIL_HEAD_CHARS].rstrip() + "..."
    return text


def _guard_rail_container_kind(segment):
    """What kind of larger segment `segment` is, by its leading token or, for
    a command that opens a heredoc, by the operator; None when it is neither."""
    if _GUARD_RAIL_FUNCTION.match(segment):
        return "function definition"
    word = re.match(r"[A-Za-z]+", segment)
    word = word.group(0) if word else ""
    if word in ("for", "while", "until"):
        return "for/while/until loop"
    if word in ("if", "case"):
        return "if/case block"
    if segment.startswith("{"):
        return "{ } group"
    if segment.startswith("("):
        return "( ) subshell"
    if _GUARD_RAIL_HEREDOC.search(segment):
        return "heredoc"
    return None


def guard_rail_findings(story):
    """One plain sentence per broken guard rail, in index order.

    Each names `implementation.guardRails[<i>]`. A rail found inside a larger
    segment says what that segment is and gives the remedy; one that matches
    nothing asks for the exact segment text; a non-string or empty entry and a
    missing verify each have a sentence of their own. The text is built by
    concatenation and the quoted head is cut short and stripped of backticks
    and the dollar-open-paren pair, because the retry sanitizer drops both.
    """
    subject = _guard_rail_subject(story)
    if subject is None:
        return []
    broken, texts = _broken_guard_rails(*subject)
    findings = []
    for index, entry, kind in broken:
        label = "implementation.guardRails[" + str(index) + "]"
        if kind == "not-string":
            findings.append(
                label + " is not a non-empty string. List the exact text of one"
                " top-level segment of implementation.verify."
            )
            continue
        if kind == "no-verify":
            findings.append(
                label + " cannot be checked because the story has no"
                " implementation.verify string. Add the verify or remove the guard rail."
            )
            continue
        head = _guard_rail_head(entry)
        container = next((text for text in texts if entry in text and text != entry), None)
        if container is None:
            findings.append(
                label + " (starts: " + head + ") matches no segment of"
                " implementation.verify and sits inside none. Give the exact text"
                " of one top-level segment."
            )
            continue
        what = _guard_rail_container_kind(container)
        if what is None:
            findings.append(
                label + " (starts: " + head + ") sits inside a larger segment of"
                " implementation.verify rather than being a top-level segment. "
                + _GUARD_RAIL_REMEDY % "segment"
            )
        else:
            findings.append(
                label + " (starts: " + head + ") sits inside a " + what
                + " rather than being a top-level segment of implementation.verify. "
                + _GUARD_RAIL_REMEDY % what
            )
    return findings


def validate_stories(doc):
    stories = _stories(doc)
    errors = []
    for story in stories:
        errors += _story_errors(story)
    return _verdict(errors)


def id_lines(docs):
    """The LINES bash's `while read` walked, which is not the list of ids.

    `ids=$(jq -r '.userStories[].id' "$f")` renders one output per story, joins
    them with newlines, and then command substitution strips the trailing ones;
    `<<< "$ids"` puts exactly one back. So an id containing a newline arrives as
    TWO lines (id-newline: two well-formed ids out of one story), an id that is
    an array arrives as four (id-array), and an empty ids string still yields one
    empty line -- which the loop skips, giving `{valid: true, count: 0}` for an
    empty userStories.

    The whole STREAM feeds one pool: a file holding two documents produces a
    single verdict over both, and dois-documentos records it.
    """
    rendered = ""
    for doc in docs:
        for story in _stories(doc):
            rendered += jq_raw(jq_index(story, "id", STORY)) + "\n"
    return rendered.rstrip("\n").split("\n")


def validate_ids(docs):
    """The verdict AND its exit status, because the two shapes disagree.

    THE OUTPUT IS ASYMMETRIC and that is the contract: the pass branch is
    `{valid, count}` with no `errors` key, the failure branch is
    `{valid, errors}` with no `count`. A port that emitted both keys on both
    branches would look tidier and would break /aimi:plan, which reads them
    apart. part1-core pins each half on its own line.
    """
    errors = []
    count = 0
    for line in id_lines(docs):
        if line == "":
            continue
        count += 1
        if not re.match(STORY_ID_PATTERN, line):
            errors.append("Invalid story ID: " + line + " (expected US-NNN)")
    if not errors:
        return {"valid": True, "count": count}, 0
    return {"valid": False, "errors": errors}, 1


def computed_waves(stories):
    """Roots are wave 1; everyone else is max(dependency waves) + 1.

    THE SEED USED TO BE 0, AND THAT WAS THE OUTLIER. Four components state the
    1-based convention and only this one stated 0-based, so every tasks file
    story-merge writes reported a mismatch on every story it contains:

      * story_merge.py's compute_waves -- the WRITER, "Roots are wave 1";
      * commands/plan.md's schema -- "computed from dependsOn: roots=1, others
        = max(dep waves)+1", repeated as "wave 1 for roots";
      * commands/execute.md -- starts its display at `wave = 1` and prints it
        as "--- Wave [wave] ---", so the stored field now agrees with the
        number the user actually reads on screen.

    The off-by-one was inherited, not introduced by the port: the jq this is a
    port of already disagreed with the jq story_merge.py is a port of. Which is
    why correcting it moves recorded answers in tests/golden_from_jq.json's
    tasks_validate_cases block -- a rule change, recorded as one.

    The walk itself is untouched, and its structure is load-bearing. n outer
    passes over the stories still unassigned; a story with no dependencies
    lands in wave 1, one whose dependencies are ALL already assigned lands one
    above their max, and one whose dependencies are not lands nowhere this
    pass. A story inside a cycle is therefore never assigned at all -- which is
    why validate-waves reports nothing for a cyclic file (wave-ciclo) and why a
    dangling dependsOn hides every wave error in its story (dep-pendurada).
    Both are recorded passes, not oversights: reporting them is validate-deps'
    job. Assignment is still tracked by key PRESENCE in $assigned, never by the
    wave value, so seeding roots at 1 shifts every assigned story by exactly
    one and changes nothing about who gets assigned.
    """
    deps = {}
    for story in stories:
        key = jq_index(story, "id", STORY)
        if not isinstance(key, str):
            # jq's "Cannot use null (null) as object key", from the
            # `map({(.id): ...})` that builds this table before anything else
            # runs. A story with no id aborts the verb -- id-ausente-waves.
            raise MalformedTasks(
                ".userStories: cannot use " + _json_type(key) + " as an object key"
            )
        deps[key] = jq_alternative(jq_index(story, "dependsOn", STORY), [])
    all_ids = [jq_index(story, "id", STORY) for story in stories]

    assigned = {}
    for _ in range(len(all_ids)):
        remaining = [i for i in all_ids if not jq_has(assigned, i, "$assigned")]
        current = assigned
        for story_id in remaining:
            story_deps = jq_alternative(deps.get(story_id), [])
            if jq_length(story_deps, STORY + ".dependsOn") == 0:
                current = dict(current)
                current[story_id] = 1
            elif all(
                jq_has(current, dep, "$assigned")
                for dep in jq_iterate(story_deps, STORY + ".dependsOn")
            ):
                current = dict(current)
                current[story_id] = max(current[dep] for dep in story_deps) + 1
        assigned = current
    return assigned


def validate_waves(doc):
    """Stored wave against computed wave, for the stories that have both.

    A story the walk never reached is skipped entirely -- `$computed_wave !=
    null` guards both arms of the select -- so only a story that COULD be placed
    is ever reported. A stored wave that is absent, null or false reads as null
    and is reported against its computed one; wave-false records that `false`
    takes `//`'s alternative and comes out as `stored=null`.
    """
    stories = _stories(doc)
    assigned = computed_waves(stories)
    errors = []
    for story in stories:
        computed = jq_alternative(assigned.get(jq_index(story, "id", STORY)), None)
        stored = jq_alternative(jq_index(story, "wave", STORY), None)
        mismatch = (
            computed is not None and stored is not None and not jq_equal(computed, stored)
        ) or (computed is not None and stored is None)
        if mismatch:
            errors.append(
                "Wave mismatch: " + jq_tostring(jq_index(story, "id", STORY))
                + " stored=" + jq_tostring(stored)
                + " computed=" + jq_tostring(computed)
            )
    return _verdict(errors)


def wave_contention(doc):
    """One error per `implementation.files` path two or more stories in the
    SAME wave both claim -- the check that catches two executors racing each
    other for one literal, which `validate_waves` never asked about at all.

    KEYED ON THE COMPUTED WAVE, NEVER THE STORED ONE. `list-ready` never reads
    `wave` -- `ready_stories` decides readiness from status plus completed
    dependencies, and the schema itself says `wave` is informational only,
    never consumed by dispatch. So `computed_waves` is the static model of what
    `/aimi:execute`'s dynamic ready-set will actually dispatch together, and a
    stale STORED wave must never be allowed to hide a real contention.

    Path comparison is exact string equality -- `a/b.py` and `./a/b.py` read
    as different paths. That is a false NEGATIVE (a missed contention), never a
    false positive, and is accepted rather than routed through path
    confinement: this is a question of identity between two document values,
    not of whether either escapes the project root.

    A story `computed_waves` never assigned (a cycle, a dangling `dependsOn`)
    is skipped, exactly as `validate_waves` skips it -- reporting those is
    `validate_deps`' job. A story whose own `implementation` is not an object,
    or whose `implementation.files` is not a list, is skipped too: the guard is
    R17's, reused verbatim rather than respelled (see its comment, and the
    account beside `.project` in `validate_stories`). Each story's own repeated
    paths are deduplicated before comparison, so a story cannot contend with
    itself.

    Errors are built in a deterministic order because the verdict is compared
    byte for byte by tests: waves ascending, paths in first-appearance document
    order within a wave, ids in document order -- which plain dict insertion
    order already gives, since stories are walked in document order throughout.
    """
    stories = _stories(doc)
    assigned = computed_waves(stories)
    by_wave = {}
    for story in stories:
        story_id = jq_index(story, "id", STORY)
        wave = assigned.get(story_id)
        if wave is None:
            continue
        implementation = jq_index(story, "implementation", STORY)
        if jq_type(implementation) != "object":
            continue
        files = jq_index(implementation, "files", STORY + ".implementation")
        if not isinstance(files, list):
            continue
        claims = by_wave.setdefault(wave, {})
        seen = set()
        for entry in files:
            if not isinstance(entry, str) or entry in seen:
                continue
            seen.add(entry)
            claims.setdefault(entry, []).append(story_id)

    errors = []
    for wave in sorted(by_wave):
        for path, ids in by_wave[wave].items():
            if len(ids) > 1:
                errors.append(
                    "Wave contention: wave " + str(wave)
                    + " path " + path
                    + " claimed by " + ", ".join(ids)
                )
    return _verdict(errors)


# ---------------------------------------------------------------------------
# validate-tasks: fifteen rules, and the three pieces of scaffolding that died
# ---------------------------------------------------------------------------
#
# THIS IS THE VERB THE PORT WAS JUSTIFIED ON, so it is worth saying what stood
# where the next forty lines stand.
#
# cmd_validate_tasks read eight scalar metadata fields, and it read them with
# ONE `jq -r '[...] | @tsv'` rather than eight, because a jq process cost ~18ms
# to start and ~1ms to read a 46KB tasks file -- eight separate reads of the
# same document paid ~8x the startup and bought nothing. Batching them saved
# roughly 140ms per invocation and cost three pieces of scaffolding, each
# defending the packing rather than any rule:
#
#   * `\037` as the delimiter instead of the tab @tsv emits. A tab is IFS
#     WHITESPACE, and bash collapses runs of it -- so two adjacent empty fields
#     (the common case: no designBundle, no execution) vanished and every later
#     value landed in the wrong variable.
#   * `// ""` at every position and never `// empty`, because `empty` emits no
#     field at all and shifts every following field one place left. Nothing
#     errored; the wrong branchName was simply validated against the pattern.
#   * `_vt_probe`, a ninth variable with no ninth field, asserted empty so that
#     a future edit adding fields without adding variables could not pass
#     silently -- the assertion being on what the SHELL parsed, never on what
#     jq emitted.
#
# All three answer questions that exist only while a document crosses a process
# boundary flattened onto one line. Below, the document is parsed once and the
# eight questions are eight expressions over a dict: there is no position to
# preserve, nothing to tell apart, and no split to probe. Every guarantee the
# scaffolding bought still holds, by construction rather than by convention --
# absent still reads as the empty string, and no field can be mistaken for its
# neighbour because no two of them are ever adjacent.
#
# @tsv's own ESCAPING is not scaffolding and is reproduced below: it is
# observable. A designSpec holding a backslash or a tab reached the filesystem
# in its escaped form and the "file not found" message quoted the escaped path.

_TSV_ESCAPES = (("\\", "\\\\"), ("\t", "\\t"), ("\n", "\\n"), ("\r", "\\r"))


def jq_tsv_cell(value, owner):
    """One cell of jq's `@tsv`: its rendering, then its four escapes.

    @tsv takes scalars only -- an array or an object is jq's "is not valid in a
    csv row" abort, which is why a `branchName` holding a list stops the verb
    rather than being reported. null renders as the EMPTY string, which is what
    made `// ""` look redundant and is not: `//` fires on false too.
    """
    if value is None:
        rendered = ""
    elif isinstance(value, bool):
        rendered = "true" if value else "false"
    elif isinstance(value, (int, float)):
        rendered = jq_tostring(value)
    elif isinstance(value, str):
        rendered = value
    else:
        raise MalformedTasks(owner + ": " + jq_type(value) + " is not valid in a csv row")
    for raw, escaped in _TSV_ESCAPES:
        rendered = rendered.replace(raw, escaped)
    return rendered


def _read_ifs_whitespace(line, count, separator="\t"):
    """bash's `IFS=$'\\t' read -r a b c`, tab-collapse and all.

    THE BUG THE `\\037` DELIMITER EXISTED TO AVOID, still live in the two scans
    that never got the treatment: a tab is IFS whitespace, so bash drops leading
    and trailing runs of it and treats an interior run as ONE delimiter. A
    visual story whose id is "" therefore yields `\\t0\\ttext`, which splits into
    two fields -- story_id becomes the AC INDEX and the text is lost -- and the
    citation in it is never checked. ds-id-vazio and url-id-nulo record both
    halves of that; reproduced rather than fixed, because which of the two the
    author meant is a decision and not a port.

    The last name takes the remainder, minus the trailing run bash already
    stripped.
    """
    stripped = line.strip(separator)
    fields = []
    rest = stripped
    run = re.compile(re.escape(separator) + "+")
    for _ in range(count - 1):
        found = run.search(rest)
        if found is None:
            fields.append(rest)
            rest = ""
        else:
            fields.append(rest[: found.start()])
            rest = rest[found.end() :]
    fields.append(rest)
    return fields


def _vc_order(byte):
    """gnulib's `order()`: `~` first, then digits, then letters, then the rest."""
    if 0x30 <= byte <= 0x39:
        return 0
    if (0x41 <= byte <= 0x5A) or (0x61 <= byte <= 0x7A):
        return byte
    if byte == 0x7E:
        return -1
    return byte + 0x100 + 1


def _verrevcmp(left, right):
    """gnulib's verrevcmp, over bytes: the core of `sort -V`."""
    i = j = 0
    n, m = len(left), len(right)
    while i < n or j < m:
        first_diff = 0
        while (i < n and not 0x30 <= left[i] <= 0x39) or (j < m and not 0x30 <= right[j] <= 0x39):
            a = 0 if i == n else _vc_order(left[i])
            b = 0 if j == m else _vc_order(right[j])
            if a != b:
                return a - b
            i += 1
            j += 1
        while i < n and left[i] == 0x30:
            i += 1
        while j < m and right[j] == 0x30:
            j += 1
        while i < n and j < m and 0x30 <= left[i] <= 0x39 and 0x30 <= right[j] <= 0x39:
            if not first_diff:
                first_diff = left[i] - right[j]
            i += 1
            j += 1
        if i < n and 0x30 <= left[i] <= 0x39:
            return 1
        if j < m and 0x30 <= right[j] <= 0x39:
            return -1
        if first_diff:
            return first_diff
    return 0


_FILE_SUFFIX = re.compile(rb"(?:\.[A-Za-z~][A-Za-z0-9~]*)*\Z")


def _filevercmp(left, right):
    """gnulib's filevercmp, over bytes, which is the key `sort -V` sorts on."""
    if not left:
        return -1 if right else 0
    if not right:
        return 1
    one_pass_only = False
    if left[:1] == b".":
        if right[:1] != b".":
            return -1
        for dots in (b".", b".."):
            if left == dots:
                return 0 if right == dots else -1
            if right == dots:
                return 1
        left, right = left[1:], right[1:]
        one_pass_only = True
    elif right[:1] == b".":
        return 1

    left_prefix = len(left) if one_pass_only else _FILE_SUFFIX.search(left).start()
    right_prefix = len(right) if one_pass_only else _FILE_SUFFIX.search(right).start()
    result = _verrevcmp(left[:left_prefix], right[:right_prefix])
    if result or (left_prefix == len(left) and right_prefix == len(right)):
        return result
    return _verrevcmp(left, right)


def sort_v_first(left, right):
    """`printf '%s\\n' "$a" "$b" | sort -V | head -n1`, which is the whole of R1.

    The gate is a two-line sort, not a comparison anyone wrote, so what it
    accepts is filevercmp's business rather than semver's: "abc" sorts ABOVE
    "3.3" and passes the gate, while "3.10" also passes and "3.03" does not.
    schema-lixo records the first of those.

    `sort` falls back to comparing whole lines when its key ties, which is why
    the byte comparison is here and not an afterthought.
    """
    left_bytes = left.encode("utf-8", "surrogateescape")
    right_bytes = right.encode("utf-8", "surrogateescape")
    order = _filevercmp(left_bytes, right_bytes)
    if order == 0:
        order = (left_bytes > right_bytes) - (left_bytes < right_bytes)
    return left if order <= 0 else right


# The sed chain _validate_designspec_citation applied to BOTH sides, in the
# order it wrote them -- and the order is load-bearing, because sed runs every
# -e over the same pattern space in turn, so `&amp;nbsp;` becomes `&nbsp;`
# becomes a space. Bytes rather than text because sed matched bytes.
_NORMALIZATIONS = tuple(
    (raw.encode("utf-8"), cooked.encode("utf-8"))
    for raw, cooked in (
        ("“", '"'),
        ("”", '"'),
        ("‘", "'"),
        ("’", "'"),
        ("—", "-"),
        (" ", " "),
        ("&amp;", "&"),
        ("&nbsp;", " "),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", '"'),
    )
)

# awk's [[:space:]] in a record that can hold no newline.
_AWK_SPACE = rb"[ \t\v\f\r]"
_HEADING = re.compile(rb"^#+" + _AWK_SPACE)


def _normalize_text(raw):
    for pattern, replacement in _NORMALIZATIONS:
        raw = raw.replace(pattern, replacement)
    return raw


def subsection_body(spec_bytes, section, normalize):
    """The awk heading-boundary scanner, ONCE, for both specs.

    It was copy-pasted between _validate_designspec_citation and
    _validate_businessspec_field, identical to the character, and the two
    differed only in what they did afterwards -- the DesignSpec side normalized
    both sides, the BusinessSpec side did not. That asymmetry is PRE-EXISTING
    and is preserved rather than tidied: normalizing the field-name lookup too
    would change which responseShape keys validate.

    The rule: from the first heading whose text is the cited section, collect
    every line until a heading of equal or SHALLOWER level. A deeper heading is
    collected along with its body, which is why a literal under 2.1.1 satisfies
    a citation of 2.1. `section` goes into the regex unescaped, exactly as awk
    interpolated it, so the `.` in "2.1" is a wildcard and matches a heading
    reading "2X1" -- ds-secao-ponto-curinga-sozinha records that.

    The boundary after `section` accepts an optional literal '.' before the
    space-or-end-of-line it already required, so a heading written
    `## <n>. <title>` -- the only shape skills/aimi-design-handoff/references/
    spec-output-shape.md documents that skill as writing -- matches the same as
    the pre-existing period-less `## <n> <title>` form every golden fixture
    uses. The added `\.?` sits strictly after the existing literal match, so
    the digit-dot-as-wildcard behaviour above is unaffected: a period in
    "2.1" is still consumed by the section literal itself, never by this group.

    Returns b"" for a section that is not there, which the callers read as "not
    found" -- the same conflation `[ -z "$subsection_body" ]` made, so a section
    that exists but holds only blank lines is reported as missing too.
    """
    heading_matches = re.compile(
        rb"^(?:\xc2\xa7" + _AWK_SPACE + rb"*)?" + section + rb"\.?(?:" + _AWK_SPACE + rb"|\Z)"
    )
    heading_anywhere = re.compile(
        rb"\xc2\xa7" + _AWK_SPACE + rb"*" + section + rb"\.?(?:" + _AWK_SPACE + rb"|\Z)"
    )
    lines = spec_bytes.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()

    collected = []
    in_section = False
    heading_level = 0
    for line in lines:
        if _HEADING.match(line):
            level = len(line) - len(line.lstrip(b"#"))
            if not in_section:
                heading_text = re.sub(rb"^" + _AWK_SPACE + rb"+", b"", line[level:])
                if heading_matches.search(heading_text) or heading_anywhere.search(heading_text):
                    in_section = True
                    heading_level = level
                    continue
            elif level <= heading_level:
                break
        if in_section:
            collected.append(line)

    # `$(awk …)` stripped every trailing newline, and _normalize_text's own
    # command substitution stripped them again afterwards.
    body = b"\n".join(collected).rstrip(b"\n")
    if normalize:
        body = _normalize_text(body).rstrip(b"\n")
    return body


def spec_contains(spec_path, needle, section, normalize):
    """`grep -qF` against the cited subsection: fixed-string containment, and
    nothing else.

    THE responseShape CONTRACT DEPENDS ON THIS STAYING DUMB. /aimi:plan
    documents a flat-key rule (commands/plan.md § "responseShape contract") and
    it holds only because the key is one opaque literal here: nothing splits on
    ".", nothing walks a path, and no regex is ever built out of the key. A
    subsection naming `portfolio` and `totalUsinas` separately still rejects
    `portfolio.totalUsinas`, which is what makes the rejection meaningful.

    grep is line-oriented and the needle can hold no newline, so containment
    over the whole body is the same answer for less machinery.
    """
    try:
        with open(spec_path, "rb") as handle:
            spec_bytes = handle.read()
    except OSError:
        # awk printed its own complaint and produced nothing; the callers'
        # `[ -z … ]` then read that as "section not found".
        return False
    body = subsection_body(spec_bytes, section.encode("utf-8", "surrogateescape"), normalize)
    if not body:
        return False
    needle_bytes = needle.encode("utf-8", "surrogateescape")
    if normalize:
        needle_bytes = _normalize_text(needle_bytes).rstrip(b"\n")
    return needle_bytes in body


def confined_spec_path(project_root, relative):
    """Resolve a spec path against PROJECT_ROOT and REFUSE one that escapes it.

    THE ONE PLACE THIS IS DECIDED, and it is decided rather than left. A tasks
    file is a document /aimi:plan wrote, but it is also a file a human edits and
    a file that arrives in a branch, so `metadata.designBundle.designSpec` is an
    attacker-supplied path in exactly the sense that matters: before this,
    `"designSpec": "../../etc/passwd"` was opened and read, and whether its
    contents matched a citation was reported back. Confinement turns that from a
    hole the validator walked through into a rule it enforces.

    It lives HERE, in Python, and not beside get_tasks_file's own
    validate_path_in_project in bash, because these two paths are only visible
    after the crossing -- they come out of the parsed document. Confining them in
    bash would mean reading the document a second time, which is the shape this
    whole port exists to remove. The rule is bash's, reproduced: resolve to an
    absolute path (following symlinks, so a link out of the tree is caught too),
    and accept only the project root itself or something beneath it. A path that
    does not exist is resolved through its parent, exactly as
    validate_path_in_project does, so a missing file is still reported as
    missing rather than as an escape.

    Returns (path, inside). The caller reports the refusal as a validation error
    naming the path, rather than exiting: the point is to tell whoever ran
    /aimi:plan which field is wrong, and one bad spec path should not hide the
    other fourteen rules' findings.
    """
    path = project_root + "/" + relative
    if os.path.exists(path):
        resolved = os.path.realpath(path)
    else:
        parent = os.path.dirname(path)
        if os.path.exists(parent):
            resolved = os.path.join(os.path.realpath(parent), os.path.basename(path))
        else:
            resolved = path
    root = os.path.realpath(project_root)
    return path, resolved == root or resolved.startswith(root + os.sep)


def _to_entries(value, owner):
    """jq's `to_entries[]`, which refuses anything with no keys.

    An acceptanceCriteria that is absent or null is jq's "has no keys" abort,
    and that abort is REACHED BEFORE the execution, branchName and url rules --
    so a file carrying both a null acceptanceCriteria and a bad branchName is
    refused without the branch ever being looked at. aborta-antes-das-regras-
    finais records exactly that, and it is why this port evaluates the rules in
    the order bash ran them rather than all fifteen unconditionally.
    """
    if isinstance(value, list):
        return list(enumerate(value))
    if isinstance(value, dict):
        return list(value.items())
    raise MalformedTasks(owner + ": " + jq_type(value) + " has no keys")


CITATION = re.compile(r'"([^"]+)" \(DesignSpec § ([0-9]+\.[0-9]+) L([0-9]+)\)')
# A `path:line` anchor inside an acceptanceCriteria, for R16 below. The
# extension list is what makes it an anchor at all: a bare `foo:12` is a ratio,
# a timestamp or a namespace far more often than it is a file and a line, and a
# matcher without the extension would warn about all three.
LINE_ANCHOR = re.compile(r"[A-Za-z0-9_./-]+\.(?:md|py|sh|js|ts|json):[0-9]+")
BRANCH_NAME = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9/_-]*")
URL_CHARSET = r"^[A-Za-z0-9/][A-Za-z0-9:/?#@!&*+,._~%=-]*$"
SOURCE_CITATION = re.compile(r"^BusinessSpec § [0-9]+(\.[0-9]+)? L[0-9]+$")
SOURCE_SECTION = re.compile(r"§ [0-9]+(\.[0-9]+)?")
# A `metadata.decisions[].source` shaped like `<brainstorm-path>:L<line>` --
# see commands/plan.md's thirteen-value source enum. Two OTHER fixed tags
# also end in ":L<line>" -- `businessSpec:L<line>` and `designSpec:L<line>`
# -- and both are excluded by the negative lookahead, because they name a
# spec file rather than a brainstorm and R20 below must never warn about
# them. Every other fixed source tag (researchFile:..., specFlow:...,
# scopeNegVerifier, scopePosVerifier, codebaseVerified, outline, phase,
# auditGate, researchConflict) never ends in ":L<digits>" at all, so no
# further exclusion is needed.
BRAINSTORM_DECISION_SOURCE = re.compile(r"^(?!businessSpec:|designSpec:).+:L[0-9]+$")

VALIDATE_METADATA_FIELDS = (
    "schema_version",
    "design_spec",
    "prototype_count",
    "frontend_only",
    "business_spec",
    "execution",
    "has_phase",
    "branch_name",
)


def validate_tasks_metadata(doc):
    """The eight fields, as eight expressions. See the note above this section.

    Each one is exactly the jq that produced its position in the packed array,
    so `// ""` survives as jq_alternative and "absent" still arrives as the
    empty string every consumer below already tested for.
    """
    meta = jq_index(doc, "metadata", "")

    def bundle(key):
        return jq_index(jq_index(meta, "designBundle", ".metadata"), key, ".metadata.designBundle")

    def prototype_count():
        prototypes = jq_index(meta, "prototypePaths", ".metadata")
        if jq_type(prototypes) != "array":
            return 0
        return jq_length(prototypes, ".metadata.prototypePaths")

    # Written out IN ORDER, and evaluated in order, because a document that
    # aborts one of them aborts there rather than at whichever expression a
    # rearrangement happened to reach first.
    values = (
        jq_alternative(
            jq_alternative(jq_index(meta, "schemaVersion", ".metadata"), jq_index(doc, "schemaVersion", "")),
            "0",
        ),
        jq_alternative(bundle("designSpec"), ""),
        jq_tostring(prototype_count()),
        jq_tostring(jq_alternative(jq_index(meta, "frontendOnly", ".metadata"), False)),
        jq_alternative(bundle("businessSpec"), ""),
        jq_alternative(jq_index(meta, "execution", ".metadata"), ""),
        "false" if jq_equal(jq_alternative(jq_index(meta, "phase", ".metadata"), None), None) else "true",
        jq_alternative(jq_index(meta, "branchName", ".metadata"), ""),
    )
    owners = (
        ".metadata.schemaVersion",
        ".metadata.designBundle.designSpec",
        ".metadata.prototypePaths",
        ".metadata.frontendOnly",
        ".metadata.designBundle.businessSpec",
        ".metadata.execution",
        ".metadata.phase",
        ".metadata.branchName",
    )
    return dict(
        zip(
            VALIDATE_METADATA_FIELDS,
            [jq_tsv_cell(value, owner) for value, owner in zip(values, owners)],
        )
    )


def finalize_shape_errors(finalize):
    """`metadata.finalize`'s shape, for R18. Returns a list of suffixes.

    ABSENT IS VALID AND IS THE WHOLE CONTRACT OF THE KEY. `metadata.finalize`
    declares the round's single end-of-round step -- the release commit no story
    can structurally make -- and every plan written before the key existed must
    keep validating byte for byte, which is why the caller skips this helper
    entirely on a `None`. It follows the omitted-when-empty convention
    `baseRef`, `pluginVersion` and `issues` already have in commands/plan.md:
    the key is written when there is a step to declare and left out otherwise,
    never `null` and never `{}`.

    `null` AND ABSENT ARE THE SAME VALUE HERE, and that is jq's doing rather
    than a softening of the rule. `.metadata.finalize` answers `null` for a key
    that is missing and for a key that is explicitly null, so nothing on this
    side of the read can tell them apart -- exactly the position R12 is in with
    `metadata.execution`'s `// ""`, where an absent enum and an empty one both
    reach the rule as the empty string and both pass. An explicit `null` is
    therefore ACCEPTED. plan.md's checklist is what tells the writer not to
    emit one; a validator that refused it would refuse every absent key too.

    Well-formed means an object carrying all three of `intent` (string),
    `files` (non-empty array of strings) and `commitSubject` (string). `files`
    is the half other rules read -- R19 warns when a story claims one of those
    paths -- so an empty array is refused rather than accepted as "declares
    nothing": a step that names no file has nothing to collide with and nothing
    to run against, and writing the key at all is then the mistake.
    """
    if jq_type(finalize) != "object":
        return [" is not an object (expected {intent, files[], commitSubject})"]

    problems = []
    intent = jq_index(finalize, "intent", ".metadata.finalize")
    if not isinstance(intent, str):
        problems.append(".intent is missing or not a string")

    files = jq_index(finalize, "files", ".metadata.finalize")
    if not isinstance(files, list) or not files:
        problems.append(".files is missing or not a non-empty array")
    elif not all(isinstance(entry, str) for entry in files):
        problems.append(".files holds an entry that is not a string")

    subject = jq_index(finalize, "commitSubject", ".metadata.finalize")
    if not isinstance(subject, str):
        problems.append(".commitSubject is missing or not a string")

    return problems


def finalize_claimed_files(finalize):
    """The paths R19 compares a story's `implementation.files` against.

    Read separately from the shape check above rather than out of it, so a
    finalize that R18 has already refused still contributes whatever paths it
    does carry: a document with two defects should report both, not hide the
    collision behind the shape error. A `files` that is not a list of strings
    yields nothing and R19 then warns about nothing at all.
    """
    if jq_type(finalize) != "object":
        return []
    files = jq_index(finalize, "files", ".metadata.finalize")
    if not isinstance(files, list):
        return []
    return [entry for entry in files if isinstance(entry, str)]


def prototype_dropped_shape_errors(dropped):
    """`metadata.prototypeDropped`'s shape, for R21. Returns a list of suffixes.

    ABSENT IS VALID AND IS THE WHOLE CONTRACT OF THE KEY, exactly as it is for
    finalize_shape_errors above. `metadata.prototypeDropped` records the
    prototype blocks /aimi:plan weighed and did NOT load, so a plan that
    dropped nothing has nothing to declare, and every tasks.json written before
    the key existed must keep validating byte for byte -- which is why the
    caller skips this helper entirely on a `None`. It follows the
    omitted-when-empty convention `baseRef`, `pluginVersion` and `issues`
    already have: the key is written when something was dropped and left out
    otherwise, never `[]` and never `{}`.

    `null` AND ABSENT ARE THE SAME VALUE HERE, and that is jq's doing rather
    than a softening of the rule, the same position R18 is in:
    `.metadata.prototypeDropped` answers `null` for a key that is missing and
    for a key that is explicitly null, so nothing on this side of the read can
    tell them apart. An explicit `null` is therefore ACCEPTED.

    THE EMPTY ARRAY GETS A MESSAGE OF ITS OWN because `[]` is the exact mistake
    the convention exists to prevent, and " is not an array" would misdescribe
    it -- it IS an array. The writer is told to omit the key instead.

    Well-formed means a non-empty array whose every element is an object
    carrying `path` (non-empty string), `reason` (non-empty string) and `bytes`
    (a number). `bytes` rejects the JSON literals `true`/`false` explicitly,
    checking `bool` BEFORE `int`, since Python's bool is an int subclass and
    `isinstance(True, int)` would otherwise let the literal through as a size.

    `reason` is checked as a non-empty string and NOT against an enum: the
    writer decides which reasons exist, and a validator enum written before its
    writer would refuse that writer's first legitimate new value.
    """
    if jq_type(dropped) != "array":
        return [" is not an array (expected [{path, reason, bytes}, …])"]

    if not dropped:
        return [
            " is an empty array — omit the key entirely when nothing was dropped"
        ]

    problems = []
    for index, entry in enumerate(dropped):
        where = "[" + str(index) + "]"
        owner = ".metadata.prototypeDropped" + where
        if jq_type(entry) != "object":
            problems.append(
                where + " is not an object (expected {path, reason, bytes})"
            )
            continue

        path = jq_index(entry, "path", owner)
        if not isinstance(path, str) or not path:
            problems.append(where + ".path is missing or not a non-empty string")

        reason = jq_index(entry, "reason", owner)
        if not isinstance(reason, str) or not reason:
            problems.append(where + ".reason is missing or not a non-empty string")

        size = jq_index(entry, "bytes", owner)
        if isinstance(size, bool) or not isinstance(size, (int, float)):
            problems.append(where + ".bytes is missing or not a number")

    return problems


def prototype_superseded_shape_errors(superseded):
    """`metadata.prototypeSuperseded`'s shape, for R22. Returns a list of suffixes.

    The sibling of prototype_dropped_shape_errors above and the same contract:
    ABSENT (or an explicit null, which jq cannot tell from absent) is valid and
    skipped by the caller, `[]` gets a message of its own because the key is
    omitted-when-empty, and every element is an object carrying EXACTLY
    `path`, `decision` and `note` -- each a non-empty string. An unknown key is
    an error: the writer is /aimi:plan Phase 4 alone, so a stray key is the
    plugin having written a record its own reader cannot parse.

    The record names a prototype a later decision (`oqDecisions[]`) changed
    something of. It stays in `metadata.prototypePaths` -- recorded, never
    regenerated. `path` confinement is the CALLER's job, since it needs
    project_root; this helper only judges shape.
    """
    if jq_type(superseded) != "array":
        return [" is not an array (expected [{path, decision, note}, …])"]

    if not superseded:
        return [
            " is an empty array — omit the key entirely when nothing was superseded"
        ]

    problems = []
    for index, entry in enumerate(superseded):
        where = "[" + str(index) + "]"
        if jq_type(entry) != "object":
            problems.append(
                where + " is not an object (expected {path, decision, note})"
            )
            continue

        for key in ("path", "decision", "note"):
            value = jq_index(entry, key, ".metadata.prototypeSuperseded" + where)
            if not isinstance(value, str) or not value:
                problems.append(
                    where + "." + key + " is missing or not a non-empty string"
                )

        for key in entry:
            if key not in ("path", "decision", "note"):
                problems.append(
                    where + " has unknown key \"" + str(key)
                    + "\" (allowed: path, decision, note)"
                )

    return problems


def _visual_ac_lines(docs):
    """`.userStories[] | select(.verification.strategy == "visual") | …| @tsv`,
    over the whole STREAM -- unlike the metadata above, which took line one."""
    lines = []
    for doc in docs:
        for story in _stories(doc):
            verification = jq_index(story, "verification", ".userStories[]")
            strategy = jq_index(verification, "strategy", ".userStories[].verification")
            if not jq_equal(strategy, "visual"):
                continue
            criteria = jq_index(story, "acceptanceCriteria", ".userStories[]")
            for key, value in _to_entries(criteria, ".userStories[].acceptanceCriteria"):
                lines.append(
                    "\t".join(
                        (
                            jq_tsv_cell(jq_index(story, "id", ".userStories[]"), ".userStories[].id"),
                            jq_tsv_cell(jq_tostring(key), ".userStories[].acceptanceCriteria"),
                            jq_tsv_cell(value, ".userStories[].acceptanceCriteria[]"),
                        )
                    )
                )
    return lines


def _bad_url_lines(docs):
    """The verification.url charset scan, whose own `@tsv` carries the same
    tab-collapse the citation scan does -- a story with a null id hands its URL
    to the id position and reports an empty one. url-id-nulo records it."""
    lines = []
    for doc in docs:
        for story in _stories(doc):
            verification = jq_index(story, "verification", ".userStories[]")
            if jq_type(verification) != "object":
                continue
            url = jq_index(verification, "url", ".userStories[].verification")
            if jq_type(url) != "string" or url == "":
                continue
            if jq_test(url, URL_CHARSET, ".userStories[].verification.url", ignore_case=False):
                continue
            lines.append(
                "\t".join(
                    (
                        jq_tsv_cell(jq_index(story, "id", ".userStories[]"), ".userStories[].id"),
                        jq_tsv_cell(url, ".userStories[].verification.url"),
                    )
                )
            )
    return lines


def _grep_lines(text, pattern):
    """`grep -oE` over a value command substitution has already de-newlined:
    every match on the whole text, which for these one-line values is the
    same list grep printed."""
    return pattern.findall(text)


def _line_anchors(text):
    """Every `path:line` anchor in one acceptanceCriteria, DesignSpec citations
    excluded, in first-seen order.

    THE EXCLUSION IS PART OF THE RULE, not a refinement bolted on after it.
    CITATION above already captures an `L([0-9]+)` group that the R2/R3/R4 walk
    binds to `_line_number` and never reads: a DesignSpec citation is validated
    by its LITERAL against its SECTION, and the line it names is not consulted.
    The code reached the conclusion this rule exists to enforce long before the
    rule did, and recorded it by throwing the capture away. So a citation whose
    quoted literal happens to name a file and a line is the one anchor in the
    file already answered for by content, and a naive matcher would fire on
    exactly that. Blanking every citation span before the scan says it once.
    """
    seen = []
    for anchor in LINE_ANCHOR.findall(CITATION.sub(" ", text)):
        if anchor not in seen:
            seen.append(anchor)
    return seen


def _endpoints(doc):
    backend = jq_index(jq_index(doc, "metadata", ""), "backendSpec", ".metadata")
    endpoints = jq_index(backend, "endpoints", ".metadata.backendSpec")
    if jq_type(endpoints) != "array":
        return None
    return endpoints


def _story_project_base(story, project_root):
    """The directory a story's relative paths are relative to, or `None` when
    that directory cannot be named inside the project root.

    A story's entries are relative to ITS project, not to the layout root: in a
    multi-repo layout `project` names the child repository the story's files
    live in. Absent, non-string, "" or "." keeps the root as the base (the
    single-repo behaviour, byte for byte). A project that escapes the root --
    `..` segments or an absolute path -- is never traversed: the caller reports
    every entry through its own refusal. The leading "/" is checked first
    because confined_spec_path joins with a string, so `/etc` would become
    `<root>//etc` and look lexically inside the root.

    R17 and R23 both ask this, so the derivation lives once.
    """
    project = _report_project(story)
    if project in (None, "", "."):
        return project_root
    if project.startswith("/"):
        return None
    project_path, project_inside = confined_spec_path(project_root, project)
    return project_path if project_inside else None


def validate_tasks(docs, tasks_file, project_root, fields, warn):
    """R2 through R15, in the order bash ran them, over the parsed stream.

    THE ORDER IS PART OF THE CONTRACT, not a rendering detail. Every scan below
    could abort -- jq did, and this raises MalformedTasks where it did -- and an
    abort inside the DesignSpec walk means the execution, branchName and url
    rules are never reached at all. Evaluating all fifteen unconditionally would
    report errors on a document the pre-port CLI refused outright.

    `fields` is the metadata row the caller already read, and R1 has already
    fired or not by the time this runs. Returns the error list; warnings go to
    `warn` as they are produced, in the order stderr received them.

    R16 THROUGH R20 ARE THE RULES HERE BASH NEVER RAN. Each is appended below
    the last one already present, which is the only position from which a new
    rule can add lines after everything the golden corpus recorded without
    reordering either channel; each one's own comment carries why it warns or
    errors, why it sits where it sits, and why it is defensive where every rule
    above it is faithful. R16, R17, R19 and R20 reach the `warn` channel only.
    R18 is the one of the five that reaches `errors`, and its own comment says
    why a malformed `metadata.finalize` is a different kind of wrong from a
    stale line anchor or a directory that is not there yet.
    """
    errors = []

    # R2/R3/R4 -- the DesignSpec scan, gated on a spec AND at least one prototype
    design_spec = fields["design_spec"]
    if design_spec and int(fields["prototype_count"]) > 0:
        # The path is CONCATENATED, never joined: a designSpec that is already
        # absolute lands under the project root anyway and is simply not found.
        design_spec_path, inside = confined_spec_path(project_root, design_spec)
        if not inside:
            errors.append(
                tasks_file + ": DesignSpec path escapes the project root: " + design_spec
            )
        elif not os.path.isfile(design_spec_path):
            errors.append(tasks_file + ": DesignSpec file not found: " + design_spec)
        else:
            for line in _visual_ac_lines(docs):
                story_id, ac_index, ac_text = _read_ifs_whitespace(line, 3)
                if not story_id:
                    continue
                for literal, section, _line_number in _grep_lines(ac_text, CITATION):
                    if not spec_contains(design_spec_path, literal, section, normalize=True):
                        errors.append(
                            tasks_file + ": " + story_id + " AC[" + ac_index + "]: "
                            "missing DesignSpec citation for \"" + literal + "\" in section § " + section
                        )

    # R5/R6 through R11 -- the BusinessSpec scan, gated on frontendOnly AND a spec
    business_spec = fields["business_spec"]
    if fields["frontend_only"] == "true" and business_spec:
        business_spec_path, inside = confined_spec_path(project_root, business_spec)
        if not inside:
            errors.append(
                tasks_file + ": BusinessSpec path escapes the project root: " + business_spec
            )
        elif not os.path.isfile(business_spec_path):
            errors.append(tasks_file + ": BusinessSpec file not found: " + business_spec)
        else:
            _validate_endpoints(docs, tasks_file, business_spec_path, errors, warn)

    # R12 -- the execution enum. Absent is valid; every tasks.json written
    # before the field existed defaults to inline.
    execution = fields["execution"]
    if execution and execution not in ("container", "inline"):
        errors.append(
            tasks_file + ": metadata.execution has invalid value \"" + execution
            + "\" (expected \"container\" or \"inline\")"
        )

    # R13 -- execution and phase are mutually exclusive: a phase-scoped file
    # always executes inside its own phase container, so execution is dead data.
    if fields["has_phase"] == "true" and execution:
        errors.append(
            tasks_file + ": metadata.execution and metadata.phase cannot both be present "
            "(phase-scoped files never carry metadata.execution)"
        )

    # R14 -- branchName, the same charset cmd_init_session and open-pr.md
    # enforce, because git and gh consume it downstream. Absent fails too: the
    # pattern needs a leading alphanumeric and the empty string has none.
    branch_name = fields["branch_name"]
    if not BRANCH_NAME.fullmatch(branch_name):
        errors.append(
            tasks_file + ": metadata.branchName \"" + branch_name
            + "\" does not match the required pattern ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$"
        )

    # R15 -- verification.url against a conservative allowlist. A story with no
    # verification object, or a null/empty/non-string url, is ignored.
    for line in _bad_url_lines(docs):
        story_id, bad_url = _read_ifs_whitespace(line, 2)
        if not story_id:
            continue
        errors.append(
            tasks_file + ": " + story_id + " verification.url \"" + bad_url
            + "\" contains characters outside the allowed charset"
        )

    # R16 -- acceptanceCriteria anchored to a line number. A WARNING, never an
    # error: `errors` is what makes validate-tasks exit 1, and a line number is
    # fragile rather than invalid, so promoting this would refuse plans that
    # pass today. It is also why the rule lives here and not in
    # validate_stories, which returns {valid, errors} with no warn channel at
    # all -- giving it one would move a golden corpus this rule has no business
    # moving.
    #
    # Below every rule that can abort, on purpose, and defensive on purpose.
    # Every scan above can abort (see this function's docstring), so a rule
    # appended here can never move an abort earlier than the port recorded it;
    # and R15 has already indexed every story by the time this runs, so a story
    # that is not an object still aborts exactly where it did. What is left -- an
    # acceptanceCriteria that is a number, a criterion that is not a string --
    # is skipped rather than refused, because a warning must not be the thing
    # that turns a document the port accepts into one it rejects.
    for doc in docs:
        for story in _stories(doc):
            criteria = jq_index(story, "acceptanceCriteria", ".userStories[]")
            if isinstance(criteria, dict):
                criteria = list(criteria.values())
            if not isinstance(criteria, list):
                continue
            anchors = []
            for criterion in criteria:
                if not isinstance(criterion, str):
                    continue
                for anchor in _line_anchors(criterion):
                    if anchor not in anchors:
                        anchors.append(anchor)
            if anchors:
                warn(
                    tasks_file + ": "
                    + jq_tostring(jq_index(story, "id", ".userStories[]"))
                    + ": acceptanceCriteria cites a line number: "
                    + ", ".join(anchors)
                    + " — the tree moves and the anchor does not"
                )

    # R17 -- implementation.files naming a directory that is not there. A
    # WARNING for R16's reason and, additionally, for one of its own: a plan is
    # written before the tree it describes exists, so a path that cannot be
    # opened today is a question to the author, not a verdict on the document.
    #
    # THE PARENT DIRECTORY IS WHAT IS CHECKED, NEVER THE FILE. A story whose
    # whole job is to create a file is the ordinary case, so requiring the file
    # would refuse every scaffolding story in the corpus -- the exact opposite
    # of what a reality check is for. Requiring the directory still catches the
    # failure that motivated the rule: a plan naming a tree nobody can open.
    #
    # It sits BELOW R16 for a measurable reason rather than a stylistic one.
    # Warnings are compared byte for byte by the golden corpus, so a rule
    # inserted ABOVE R16 would reorder the stderr of any document that trips
    # both, while one appended below it can only ever add lines after the last
    # one already recorded. Nothing above moves, in either channel.
    #
    # `implementation` is read ONLY once jq_type says "object". That guard is
    # not defensive habit -- it is the removed cd-prefix rule's regression
    # written down, and validate_stories carries the account of it beside
    # .project rather than this comment repeating it.
    #
    # Confinement goes through confined_spec_path because that is the one place
    # a document-sourced path is resolved against PROJECT_ROOT; a path that
    # escapes warns for the same reason a missing directory does, since neither
    # names a directory that exists UNDER the project root.
    for doc in docs:
        for story in _stories(doc):
            implementation = jq_index(story, "implementation", ".userStories[]")
            if jq_type(implementation) != "object":
                continue
            files = jq_index(implementation, "files", ".userStories[].implementation")
            if not isinstance(files, list):
                continue
            base = _story_project_base(story, project_root)
            unopenable = []
            for entry in files:
                if not isinstance(entry, str):
                    continue
                if base is None:
                    inside = False
                    path = entry
                else:
                    path, inside = confined_spec_path(base, entry)
                if inside and os.path.isdir(os.path.dirname(path)):
                    continue
                if entry not in unopenable:
                    unopenable.append(entry)
            if unopenable:
                warn(
                    tasks_file + ": "
                    + jq_tostring(jq_index(story, "id", ".userStories[]"))
                    + ": implementation.files names a directory that does not exist: "
                    + ", ".join(unopenable)
                    + " — the file may be new, the directory it lands in may not"
                )

    # R18 -- metadata.finalize's shape. An ERROR where R16 and R17 warn, and
    # the difference is which way the document is wrong. A line anchor and a
    # missing directory are questions to the author about a plan that is still
    # legible; a finalize carrying an `intent` and nothing else is a key whose
    # own consumer cannot read it, so accepting it would hand the end-of-round
    # step a declaration it has to guess at.
    #
    # ABSENT DOES NOTHING AT ALL, which is the guard-rail this rule is written
    # around rather than a convenience: every tasks.json written before the key
    # existed must validate byte for byte, both channels, and the caller's
    # `is None` skip is what guarantees it. finalize_shape_errors' own docstring
    # carries why `null` and absent are one value here.
    #
    # It sits BELOW R17 for R17's own reason, stated in its comment: a rule
    # appended below the last one can only add lines after everything already
    # recorded, and can never reorder either channel. R18 reaches `errors`,
    # which is the channel that had not been touched below R15 -- the append
    # position is what keeps that safe too, since `errors` is rendered as one
    # array in the order it was built.
    finalize = None
    if docs:
        finalize = jq_index(jq_index(docs[0], "metadata", ""), "finalize", ".metadata")
    if finalize is not None:
        for problem in finalize_shape_errors(finalize):
            errors.append(tasks_file + ": metadata.finalize" + problem)

    # R19 -- a story claiming a path metadata.finalize declares. A WARNING and
    # never an error, and that is the rule rather than a soft start: a file can
    # legitimately appear in both places -- a story that adds a CHANGELOG entry
    # beside a finalize step that bumps the version writes the same file for
    # two different reasons -- so the collision is information, not a verdict.
    # Whoever reads the line decides which of the two should own the write.
    #
    # Consequently `errors` does not grow here, the exit status does not move,
    # and the stdout verdict of a colliding document is byte-identical to the
    # same document without the collision. Only stderr gains a line.
    #
    # The `jq_type(implementation) != "object"` guard is R17's, reused verbatim
    # rather than rewritten: it is the removed cd-prefix rule's regression
    # written down, and a second spelling of it would be a second thing to keep
    # in step. One warn call per story, listing every path that story claims,
    # so a story naming three declared files is one line and not three.
    claimed_by_finalize = finalize_claimed_files(finalize) if finalize is not None else []
    if claimed_by_finalize:
        for doc in docs:
            for story in _stories(doc):
                implementation = jq_index(story, "implementation", ".userStories[]")
                if jq_type(implementation) != "object":
                    continue
                files = jq_index(implementation, "files", ".userStories[].implementation")
                if not isinstance(files, list):
                    continue
                collisions = []
                for entry in files:
                    if not isinstance(entry, str):
                        continue
                    if entry in claimed_by_finalize and entry not in collisions:
                        collisions.append(entry)
                if collisions:
                    warn(
                        tasks_file + ": "
                        + jq_tostring(jq_index(story, "id", ".userStories[]"))
                        + ": implementation.files claims a path metadata.finalize declares: "
                        + ", ".join(collisions)
                        + " — the end-of-round step writes it too"
                    )

    # R20 -- metadata.decisions[] carries a brainstorm-sourced entry while
    # metadata.brainstormPath is absent. A WARNING for R16's reason: a broken
    # link between the two is a question to the plan's author, not a verdict
    # on the document.
    #
    # THE FALSE-POSITIVE CONTROL IS THE RULE THIS EXISTS TO SATISFY. A plan
    # with no metadata.decisions[] key at all is the ordinary, legitimate
    # shape of a plan that never went through a brainstorm, and must never
    # trip this rule; neither must a decisions[] populated entirely with
    # non-brainstorm sources (outline, businessSpec:L<line>, designSpec:L
    # <line>, researchFile:..., specFlow:..., scopeNegVerifier,
    # scopePosVerifier, codebaseVerified, phase, auditGate, researchConflict).
    # A rule that warned on either shape would fire on the common case and
    # teach the reader to ignore the channel.
    #
    # WHY THIS SIGNAL: a metadata.decisions[] entry only carries a
    # <brainstorm-path>:L<line> source (BRAINSTORM_DECISION_SOURCE, defined
    # above) when /aimi:plan's Phase 0.5 actually parsed a brainstorm doc's
    # Open Questions section, so its presence is proof a brainstorm fed this
    # plan rather than a guess -- and it costs nothing beyond a second field
    # read off docs[0], the same read R18/R19 already make for
    # metadata.finalize. This story's notes carry the two other candidate
    # signals considered and rejected (a roadmap.json brainstormPath check;
    # a .aimi/brainstorms/ slug match).
    #
    # It sits BELOW R19 for R17's own stated reason: a rule appended after
    # the last one already present can only add lines after everything the
    # golden corpus recorded, in either channel, and can never reorder one.
    #
    # ONE warn call for the WHOLE document, on the FIRST matching entry, not
    # one per matching entry -- R19's own one-line-per-story precedent
    # (a story naming three collisions is one line), widened here to one
    # line per document: the broken link is one fact about the document, not
    # one fact per decision that cites it.
    doc0_metadata = jq_index(docs[0], "metadata", "") if docs else None
    brainstorm_path = jq_index(doc0_metadata, "brainstormPath", ".metadata")
    if not brainstorm_path:
        decisions = jq_index(doc0_metadata, "decisions", ".metadata")
        if isinstance(decisions, dict):
            decisions = list(decisions.values())
        if isinstance(decisions, list):
            for decision in decisions:
                if not isinstance(decision, dict):
                    continue
                source = decision.get("source")
                if isinstance(source, str) and BRAINSTORM_DECISION_SOURCE.match(source):
                    warn(
                        tasks_file
                        + ": metadata.decisions[] cites a brainstorm-sourced decision ("
                        + source
                        + ") but metadata.brainstormPath is absent — every one of that "
                        "brainstorm's design decisions is silently dropped from every "
                        "story's execution context"
                    )
                    break

    # R21 -- metadata.prototypeDropped's shape. An ERROR where R16, R17, R19
    # and R20 warn, and R18 is the precedent rather than a coin toss. Those
    # four warn because each is a question to a human author about a plan that
    # is still legible. This one is not: the key has exactly one writer --
    # /aimi:plan's aggregate-ceiling path -- so a malformed value is never an
    # author's judgement call. It is the plugin having written a record its own
    # future reader cannot parse, which is precisely R18's stated reason for
    # reaching `errors`.
    #
    # AND A WARNING WOULD HAND BACK THE SILENCE THE RECORD EXISTS TO BREAK. An
    # unparseable record is indistinguishable from no record at all, so a round
    # that dropped a prototype would once again end with no artifact separating
    # "the planner saw the prototype" from "the planner saw the filename" --
    # the exact failure this key was added to close.
    #
    # ABSENT DOES NOTHING AT ALL -- R18's guard-rail, held for R18's reason:
    # every tasks.json written before the key existed must validate byte for
    # byte on both channels, and the caller's `is None` skip is what guarantees
    # it. The error can therefore only fire on a document that deliberately
    # wrote the key.
    #
    # NO PATH CONFINEMENT, decided rather than forgotten. The repo CLAUDE.md
    # routes a new document-sourced path behind require_in_project or
    # confined_spec_path and never behind a fresh check; this path belongs
    # behind NEITHER, because it is not a path the pipeline opens -- it names a
    # file that was explicitly NOT loaded. Every confined sibling is confined
    # because something acts on it: designBundle's spec paths are read by
    # validate-tasks itself, and researchPaths/prototypePaths are moved and
    # deleted by archive-task. Nothing reads, moves or stats a
    # prototypeDropped path, so STORY_CONTEXT_METADATA_KEYS and archive-task's
    # own two-key tuple are both left alone to keep it that way. A later story
    # that makes something open one of these paths is the story that adds
    # require_in_project -- not this one.
    #
    # It sits BELOW R20 for R17's own stated reason: a rule appended after the
    # last one already present can only add lines after everything the golden
    # corpus recorded, in either channel, and can never reorder one.
    #
    # `doc0_metadata` is R20's own local, reused rather than re-read: a third
    # read of the same field would be a third thing to keep in step.
    prototype_dropped = jq_index(doc0_metadata, "prototypeDropped", ".metadata")
    if prototype_dropped is not None:
        for problem in prototype_dropped_shape_errors(prototype_dropped):
            errors.append(tasks_file + ": metadata.prototypeDropped" + problem)

    # R22 -- metadata.prototypeSuperseded's shape and path confinement. Appended
    # AFTER R21 for R17's reason: a rule below the last one can only add lines
    # after everything already recorded. An ERROR, R21's reasoning held: the key
    # has one writer (/aimi:plan Phase 4), so a malformed value is the plugin
    # having written a record its reader cannot parse, and a warning would hand
    # back the silence the record exists to break. ABSENT/null does nothing.
    #
    # UNLIKE prototypeDropped, this `path` IS confined, because it names a
    # prototype the executor is told to read next to -- through
    # confined_spec_path, never a fresh check. archive-task's cleanup tuple is
    # deliberately NOT extended with this key (prototypeDropped is not in it
    # either): `path` always points at an entry already in
    # metadata.prototypePaths, which archive-task already confines and removes.
    prototype_superseded = jq_index(doc0_metadata, "prototypeSuperseded", ".metadata")
    if prototype_superseded is not None:
        for problem in prototype_superseded_shape_errors(prototype_superseded):
            errors.append(tasks_file + ": metadata.prototypeSuperseded" + problem)
        if isinstance(prototype_superseded, list):
            for index, entry in enumerate(prototype_superseded):
                if jq_type(entry) != "object":
                    continue
                given = jq_index(
                    entry, "path", ".metadata.prototypeSuperseded[" + str(index) + "]"
                )
                if not isinstance(given, str) or not given:
                    continue
                _resolved, inside = confined_spec_path(project_root, given)
                if not inside:
                    errors.append(
                        tasks_file + ": metadata.prototypeSuperseded[" + str(index)
                        + "].path escapes the project root: " + given
                    )

    # R23 -- an implementation.verify that cannot fail. Appended AFTER R22 for
    # R17's reason: a rule below the last one can only add lines after
    # everything already recorded. WARNINGS only, R16's and R17's reasoning
    # held: a verify is a script an author wrote on purpose, and what these two
    # predicates catch is a shape that usually is not what was meant, not a
    # document the validator may refuse. (1) A multi-line verify whose exit
    # status is only its LAST line's, because nothing stops the script at a
    # failing line. (2) A `grep` aimed at a directory with no -r, which exits 2
    # and which a leading `!` then turns into a pass. Both read the same
    # decomposition verify-probe uses, and neither expands or runs anything.
    #
    # The grep base is the story's project the way R17 derives it, through the
    # one helper both call; a project that escapes the root has no base, so only
    # the composition finding applies there. `implementation` is read only once
    # jq_type says "object" -- R17's guard, reused -- and a non-string verify is
    # not this rule's to judge.
    for doc in docs:
        for story in _stories(doc):
            implementation = jq_index(story, "implementation", ".userStories[]")
            if jq_type(implementation) != "object":
                continue
            verify = jq_index(implementation, "verify", ".userStories[].implementation")
            if not isinstance(verify, str):
                continue
            findings = verify_composition_findings(verify)
            base = _story_project_base(story, project_root)
            if base is not None:
                findings = findings + verify_grep_directory_findings(verify, base)
            for finding in findings:
                warn(
                    tasks_file + ": "
                    + jq_tostring(jq_index(story, "id", ".userStories[]"))
                    + ": implementation.verify " + finding
                )

    return errors


def _validate_endpoints(docs, tasks_file, business_spec_path, errors, warn):
    """R7 through R11, over `metadata.backendSpec.endpoints`.

    The loop bound came from `[ "$ep_index" -lt "$endpoint_count" ]`, and
    `endpoint_count` was one jq run over the WHOLE stream -- so a file holding
    two documents handed bash two numbers on two lines and the test refused
    them as a non-integer, skipping every endpoint rule. Reproduced by bounding
    on the stream having exactly one document; the shell's own complaint about
    the non-integer is named in the golden as a divergence, because it quotes a
    line number in a file that no longer holds that line.
    """
    per_document = [_endpoints(doc) for doc in docs]
    counts = "\n".join(str(0 if found is None else len(found)) for found in per_document) or "0"
    if not counts.isdigit():
        return
    endpoints = per_document[0] or []

    for index, endpoint in enumerate(endpoints[: int(counts)]):
        where = tasks_file + ": backendSpec.endpoints[" + str(index) + "]"
        source = jq_alternative(
            jq_index(endpoint, "source", ".metadata.backendSpec.endpoints[]"), None
        )
        # `jq -r … // empty` printed nothing for an absent, null or false
        # source, and command substitution then stripped the trailing newlines
        # a multi-line pretty-print left behind.
        source_text = "" if source is None else jq_raw(source).rstrip("\n")
        if not source_text:
            errors.append(where + ": missing source field")
            continue

        if _any_line(source_text, lambda text: text.startswith("derived:")):
            warn(where + ": derived source — manual review required")
            continue

        if not _any_line(source_text, SOURCE_CITATION.match):
            errors.append(
                where + ": malformed source \"" + source_text
                + "\" (expected 'BusinessSpec § N[.N] L<line>' or 'derived: ...')"
            )
            continue

        endpoint_section = _sections(source_text)
        shape = jq_index(endpoint, "responseShape", ".metadata.backendSpec.endpoints[]")
        if jq_type(shape) != "object":
            continue

        # jq's `keys` SORTS, so two invented fields are reported alphabetically
        # rather than in the order the author wrote them. bs-campos-ordem pins it.
        for field_name in _named_lines(sorted(shape)):
            if not field_name:
                continue
            field = shape[field_name] if field_name in shape else None
            field_source = None
            if jq_type(field) == "object":
                field_source = jq_alternative(
                    jq_index(field, "source", ".metadata.backendSpec.endpoints[].responseShape[]"), None
                )
            field_text = "" if field_source is None else jq_raw(field_source).rstrip("\n")
            field_where = where + ".responseShape." + field_name

            if field_text:
                if _any_line(field_text, lambda text: text.startswith("derived:")):
                    warn(field_where + ": derived source — manual review required")
                    continue
                if not _any_line(field_text, SOURCE_CITATION.match):
                    errors.append(field_where + ": malformed source \"" + field_text + "\"")
                    continue
                section = _sections(field_text)
            else:
                section = endpoint_section

            if not spec_contains(business_spec_path, field_name, section, normalize=False):
                errors.append(
                    field_where + ": field name not found in BusinessSpec § " + section
                )


def _any_line(text, predicate):
    """grep is line-oriented: one matching line is a match for the whole value."""
    return any(predicate(line) for line in text.split("\n"))


def _sections(text):
    """`grep -oE '§ N[.N]' | sed 's/§ //'` -- every match, newline-joined, which
    for a well-formed one-line source is one section."""
    return "\n".join(match.group(0)[2:] for match in SOURCE_SECTION.finditer(text))


def _named_lines(values):
    """`jq -r` printed one value per line and `read` took them back a line at a
    time, so a key holding a newline arrives as two names."""
    return "\n".join(jq_raw(value) for value in values).split("\n") if values else []


# ---------------------------------------------------------------------------
# get-story-context -- the payload every spawned story executor reads first
# ---------------------------------------------------------------------------
#
# 155 lines of bash and 8 fixed jq calls plus one per skill. It is the ONLY
# verb a story-executor agent runs, once per story, so its cost is paid inside
# every agent /aimi:execute spawns and its SHAPE is what every one of them
# parses. The measurement is in op_get_story_context's docstring, beside the
# code it measures.
#
# FOUR RULES CHANGED HERE ON PURPOSE, and the golden file's
# `_comment_story_context` states each one beside what it cost:
#
#   1. The cap counts BYTES. `${#skill_content}` counted bytes under LC_ALL=C
#      and characters under LC_ALL=C.UTF-8, so the same skill set was kept on
#      one host and evicted on another. cap-multibyte-c and
#      cap-multibyte-c-utf-8 are the same input recorded under both locales and
#      they disagree; a payload cap defends a payload, so bytes is the reading
#      that was kept.
#   2. A skill whose OWN body exceeds the cap is dropped up front, before the
#      aggregate loop. The pop-from-the-end loop used to drain the whole array
#      behind it -- and then abort the verb, because `(( total -= n ))` yielding
#      0 exits 1 under `set -e`. cap-gigante-primeiro records that: one oversized
#      skill declared first cost two legitimate ones AND the entire payload.
#   3. `skillsDropped[]` is emitted, always, `[]` when nothing was dropped. The
#      warnings stay on stderr where they were, but a caller running this verb
#      with `2>/dev/null` -- which a JSON-parsing caller reasonably does -- could
#      not previously tell a hydrated skill set from a halved one.
#   4. `metadata` is PROJECTED, not copied whole. The payload used to carry the
#      document's entire metadata object into every spawn; the projection keeps
#      the keys STORY_CONTEXT_METADATA_KEYS names -- the ones with a measured
#      reader in the story-executor -- and drops the rest, `decisions` first
#      among them. The constant and the grep that produced it sit beside
#      op_get_story_context; the golden's story_context_cases moved with the
#      rule, in the rule's own commit.
#
# Everything else is the bash reproduced, aborts included, and the abort classes
# are named in the golden comment rather than reproduced: there is no shell
# pipeline left to raise SIGPIPE and no `set -e` to trip.

SKILLS_CAP = 102400

# `head -c 65536` on the decisions pipeline, before this cap became a whole-
# section eviction budget (see design_decisions() below) rather than a byte
# slice point. Bytes, like the skills cap above, and for the same reason: the
# old `head -c` counted them and never had a locale to depend on, and every
# size compared against this cap today is still `len()` on a bytes object.
DECISIONS_CAP = 65536

# A dedicated budget for the spec content a story's payload embeds (see
# capped_spec_sections() below), independent of both caps above by operator
# decision at the phase 2.5 gate: sized on DECISIONS_CAP's own order of
# magnitude, never reused from SKILLS_CAP, and never reused from the
# unrelated 200KB plan-time per-file spec truncation cap elsewhere in this
# module -- that cap is paid once per plan run, this one is paid on every
# story spawn.
SPEC_CAP = 65536

# The shape rule a `## ` heading's own text is tested against, from US-001's
# corpus measurement (`.aimi/research/design-decisions-section-shapes.md`):
# case-insensitive, matches a word starting `Decis` continuing `ion` (covers
# "Decision"/"Decisions"), `ão` (covers "Decisão") or `õe` (covers "Decisões").
# Confirmed against the corpus to accept "## Design Decisions", "## Design
# Decisions e mais" and "## Key Decisions", and to reject "## Overview" and
# "## Next Steps" (the second of which is a real heading in both corpus files,
# correcting an earlier assumption that it did not exist). The `\b` before
# `Decis` blocks a false hit inside an unrelated word (e.g. "indecisão") for
# free; no such heading is in the corpus, but the guard costs nothing.
DECISIONS_HEADING_RE = re.compile(r"(?i)^##\s+.*\bDecis(ion|ão|õe)")

# The two tag-breakout escapes, in the order the per-skill `sed` applied them.
# Order matters and is not alphabetical: the closing form has to go first, or
# the opening rule would already have eaten its `<` and left `&lt;/…` unescaped.
TAG_BREAKOUT = (("</required_skills", "&lt;/required_skills"),
                ("<required_skills", "&lt;required_skills"))


def _raw_lines(values):
    """`jq -r` over a stream, then `$( )`: every value on its own line, with the
    trailing newlines stripped -- and a value jq -r PRETTY-PRINTS arrives as
    several lines rather than one. Same rule _named_lines states, over a stream
    of documents rather than over the keys of one object."""
    return "\n".join(jq_raw(value) for value in values).rstrip("\n")


def declared_skill_names(docs, story_id):
    """`(.userStories[] | select(.id == $id) | .skills // []) | @json` piped into
    `jq -r '.[]' 2>/dev/null` and read back by `mapfile -t`.

    Three of that pipeline's habits are load-bearing and none of them is
    obvious. It runs over the WHOLE stream, so a two-document tasks file
    contributes both documents' skills to one payload whose story and metadata
    come from the first (dois-documentos). The second jq's stderr is discarded
    and its exit status is never read, so a `skills` that cannot be iterated --
    a string, a number -- silently yields NO skills rather than a refusal
    (skills-string, skills-numero), while an OBJECT iterates to its values
    (skills-objeto). And `-r` pretty-prints a non-string element over as many
    lines as it takes, each of which `mapfile` then treats as a skill name:
    skills-item-array records `["alpha"]` becoming the three names `[`,
    `  "alpha"` and `]`.

    jq streams its output, so an element that aborts the iteration keeps
    whatever was already printed -- the loop below stops at the first refusal
    instead of discarding what came before it.
    """
    printed = []
    for doc in docs:
        for story in stories_with_id(doc, story_id):
            declared = jq_alternative(jq_index(story, "skills", ".userStories[]"), [])
            try:
                elements = jq_iterate(declared, ".skills")
            except MalformedTasks:
                return printed
            for element in elements:
                printed.extend(jq_raw(element).split("\n"))
    return printed


def resolve_skill(base_dir, name, warn):
    """The bare directory, then the `aimi-` prefixed one, then a warning.

    OpenCode's install.sh writes `aimi-<skill>` while a story declares the bare
    name; Claude Code's cache is unprefixed and resolves on the first try, so
    the fallback is host-agnostic rather than host-gated. The path REPORTED is
    the bare plugin-relative one either way -- it names what the story asked
    for, not where this host happened to keep it.
    """
    relative = "skills/" + name + "/SKILL.md"
    if not base_dir:
        # bash could not resolve a skills directory at all. The pre-port loop
        # `continue`d without a word and so does this: on a host with no plugin
        # install there is nothing to report per skill that the empty array does
        # not already say.
        return relative, None
    path = base_dir + "/" + name + "/SKILL.md"
    if not os.path.isfile(path):
        prefixed = base_dir + "/aimi-" + name + "/SKILL.md"
        if os.path.isfile(prefixed):
            path = prefixed
        else:
            warn("skill " + name + " not found at " + relative + " — skipped")
            return relative, None
    return relative, path


def read_skill(path):
    """The per-skill `sed` and the command substitution that swallowed it.

    `$(sed …)` strips EVERY trailing newline, so a SKILL.md ending in one comes
    back without it -- every recording in the corpus shows that, and a consumer
    diffing content against the file on disk needs to know it is not a bug.
    Malformed UTF-8 is replaced rather than refused because jq's `--arg` did
    exactly that; no recording reaches it, so it is stated here instead of
    claimed to be tested.
    """
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        content = handle.read()
    for pattern, replacement in TAG_BREAKOUT:
        content = content.replace(pattern, replacement)
    return content.rstrip("\n")


def skills_payload(names, base_dir, warn):
    """The skills array and the drop report, one pass over the declared names.

    THE QUADRATIC IS THE POINT OF THIS FUNCTION. The pre-port loop re-fed the
    whole accumulated array back through `jq -n --argjson existing` on every
    iteration, so N skills serialized N(N+1)/2 bodies; here each body is
    appended once and the array is serialized once, by the single `_emit` at the
    end of the verb.

    The cap runs in two explicit passes and the ORDER is the rule, not an
    implementation detail: a skill too big on its own is dropped first, then the
    aggregate is trimmed from the end. Declaration order stays priority order --
    what a story lists first is what survives -- which is precisely what the
    single reverse-pop loop could not offer once an oversized entry was in the
    array ahead of the others.

    `dropped` entries carry the seven-key shape every kind of drop in this
    module now shares (see op_get_story_context's own `dropped[]` assembly):
    `kind:"skill"`, `name` set, `path`/`section` null (a skill has neither),
    `reason` unchanged ("oversized"/"aggregate"), `bytes` the measured size,
    `deferred:false` -- a dropped skill is gone from this payload entirely,
    with nowhere left for the executor to read it on demand.
    """
    kept = []
    dropped = []
    for name in names:
        relative, path = resolve_skill(base_dir, name, warn)
        if path is None:
            continue
        content = read_skill(path)
        size = len(content.encode("utf-8"))
        if size > SKILLS_CAP:
            warn(
                "skill " + name + " dropped — " + str(size)
                + " bytes exceeds the 100KB skills cap on its own"
            )
            dropped.append({
                "kind": "skill", "name": name, "path": None, "section": None,
                "reason": "oversized", "bytes": size, "deferred": False,
            })
            continue
        kept.append(({"name": name, "path": relative, "content": content}, size))

    aggregate = sum(size for _, size in kept)
    while aggregate > SKILLS_CAP and kept:
        entry, size = kept.pop()
        warn("skill " + entry["name"] + " dropped — aggregate skills context exceeded 100KB")
        dropped.append({
            "kind": "skill", "name": entry["name"], "path": None, "section": None,
            "reason": "aggregate", "bytes": size, "deferred": False,
        })
        aggregate -= size

    return [entry for entry, _ in kept], dropped


def _is_decisions_heading(heading_line):
    """The shape predicate: does this `## ` heading's own text match
    DECISIONS_HEADING_RE? Decoded to text for the regex the same way every
    other text this module hands back to the agent is decoded -- malformed
    UTF-8 is replaced rather than refused, matching read_skill()'s rule."""
    return bool(DECISIONS_HEADING_RE.match(heading_line.decode("utf-8", "replace")))


def _split_top_sections(lines):
    """Every top-level `## ` heading and its body (to the next `## ` or EOF),
    in document order. A deeper `### ` heading is not a boundary -- its line
    starts with three hashes and a space, not two hashes and a space, so it
    stays inside whichever section is open, unchanged from the pre-port
    scanner. Content before the first `## ` heading belongs to no section and
    is dropped, matching the pre-port scanner, which only ever started
    collecting once a heading had already been seen."""
    sections = []
    heading = None
    body = []
    for line in lines:
        if line.startswith(b"## "):
            if heading is not None:
                sections.append((heading, body))
            heading = line
            body = []
        elif heading is not None:
            body.append(line)
    if heading is not None:
        sections.append((heading, body))
    return sections


def _section_body(body_lines):
    """`sed 's/^[[:space:]]*//;s/[[:space:]]*$//'` over every body line, then
    the blank-line drop that used to be a squeeze-then-delete pair (see the
    docstring this rule carried before the shape rewrite: `awk 'NF ||
    prev_nf'` collapsed blank runs to one and the `sed '/^$/d'` right after it
    deleted the survivor too, so the composition drops every blank line and
    writing the squeeze out would be dead code). Bytes throughout, for the
    same reason DECISIONS_CAP counts them."""
    collected = [stripped for stripped in (line.strip(b" \t\v\f\r") for line in body_lines) if stripped]
    return b"\n".join(collected)


def _decisions_dropped_marker(dropped):
    """One bracketed marker naming every dropped heading and the byte size of
    the block it cost, in the order design_decisions() dropped them (oversized
    entries first in document order, then aggregate evictions in reverse
    document order -- see design_decisions()'s own docstring)."""
    parts = [
        entry_heading.strip(b" \t\v\f\r").decode("utf-8", "replace") + " (" + str(entry_size) + " bytes)"
        for entry_heading, entry_size in dropped
    ]
    return ("[design decisions dropped — cap exceeded: " + "; ".join(parts) + "]").encode("utf-8")


# The spec-section-contract's own two tables (commands/references/spec-
# section-contract.md), copied verbatim in the table's own row order.
# BusinessSpec has 11 rows -- § 6 is not one of them; that file's own
# "No Project-Specific Assumption" prose calls § 6 nonexistent. Re-read the
# contract file rather than trust this copy if it has since changed.
BUSINESS_SPEC_SECTIONS = ("1", "2", "3", "4", "4.1", "5", "5.1", "5.3", "7", "9", "11")
DESIGN_SPEC_SECTIONS = ("1", "2.2", "3", "4", "6", "8")


def spec_sections(docs, project_root, file_facts=None):
    """Slice BusinessSpec.md/DesignSpec.md content by the contract's own §
    number, for the two spec paths `metadata.designBundle` names on docs[0].

    BINDS TO docs[0] ALONE -- the same story/metadata scope
    op_get_story_context already uses for `story`/`metadata` -- and never
    folds over the whole document stream the way bundle_guidance() does.
    bundle_guidance()'s own docstring calls that whole-stream fold "faithful
    rather than sensible" for prose nobody parses; this function returns
    structured content a story executor reads, so the same shortcut is wrong
    here on purpose.

    Each of businessSpec/designSpec is resolved through confined_spec_path()
    UNCONDITIONALLY -- no frontend_only/prototype_count gate, unlike
    validate_tasks' two guarded call sites -- using its soft (path, inside)
    return, never require_in_project()'s hard exit: get-story-context is a
    no-lock, always-must-succeed read every spawned executor's first action
    depends on. A path absent from metadata, not a non-empty string, escaping
    --project-root, or naming a file absent on disk contributes no pairs for
    that spec and raises nothing -- it is skipped silently and the other spec
    is unaffected.

    THE RETURN ORDER IS A DECLARED CONTRACT, not contract-table order. Plain
    table order (every BusinessSpec row, then every DesignSpec row) composed
    with a FIFO-from-the-end eviction cap would drop every DesignSpec section
    before any BusinessSpec one -- backwards for a phase whose whole goal is
    delivering the design contract to a UI-implementing executor. Instead the
    two tuples are interleaved position by position -- BUSINESS_SPEC_SECTIONS[i]
    paired with DESIGN_SPEC_SECTIONS[i] for each i, BusinessSpec first at each
    position -- and once the shorter tuple is exhausted the longer one
    continues alone, in its own table order. With 11 BusinessSpec rows and 6
    DesignSpec rows that reads B§1, D§1, B§2, D§2.2, B§3, D§3, B§4, D§4,
    B§4.1, D§6, B§5, D§8, then the remaining B§5.1, B§5.3, B§7, B§9, B§11. A
    section absent from either tuple's slot (the tuples are already the same
    length as each other's contract, so this only happens past the shorter
    tuple's end) is simply not offered that turn. Eviction from the end (see
    the story that caps this list) therefore removes the lowest-priority
    sections of BOTH specs before it reaches a high-priority section of
    either.

    A contract-listed section with no heading matching it anywhere in the
    resolved spec produces NO entry -- never an entry with empty content.
    Returns `list[(label, content)]`, never a dict.

    A section number that is a strict prefix of another in the same spec
    (BusinessSpec § 4 and § 4.1; § 5, § 5.1 and § 5.3) means the boundary
    scanner's own nesting rule -- a deeper heading is collected along with its
    body -- makes a parent section's sliced text legitimately CONTAIN its
    child section's text too. Both pairs are still emitted separately; this is
    expected duplication, not a bug.

    design_context() is the one caller (via op_get_story_context), and it
    needs one fact this function's own return cannot carry: WHY a spec
    produced no pairs at all -- absent from metadata, escaping --project-root,
    or missing on disk are three different `dropped[]` reasons (or no drop at
    all), and confined_spec_path() is only ever called here, once per label,
    to answer it. `file_facts`, when passed a dict, is populated in place with
    one entry per label -- {"relative": <declared path or None>, "inside":
    <bool or None>, "isfile": <bool or None>} -- reusing the exact
    confined_spec_path()/os.path.isfile() results this function already
    computes for slicing, so a caller that wants both the sliced pairs and the
    confinement facts resolves each spec path through confined_spec_path()
    exactly ONCE rather than calling it a second time of its own. Every
    existing caller (the pairs-only signature) is unaffected: the default
    `None` skips the extra bookkeeping and the return value is unchanged.
    """
    first = docs[0] if docs else None
    bundle = jq_index(jq_index(first, "metadata"), "designBundle")

    spec_bytes = {}
    for label, key in (("BusinessSpec", "businessSpec"), ("DesignSpec", "designSpec")):
        relative = jq_index(bundle, key)
        declared = relative if isinstance(relative, str) and relative else None
        content = None
        inside = None
        isfile = None
        if declared is not None:
            path, inside = confined_spec_path(project_root, declared)
            isfile = inside and os.path.isfile(path)
            if isfile:
                with open(path, "rb") as handle:
                    content = handle.read()
        spec_bytes[label] = content
        if file_facts is not None:
            file_facts[label] = {
                "relative": declared,
                "inside": inside,
                "isfile": bool(isfile) if isfile is not None else None,
            }

    width = max(len(BUSINESS_SPEC_SECTIONS), len(DESIGN_SPEC_SECTIONS))
    pairs = []
    for index in range(width):
        for label, sections in (
            ("BusinessSpec", BUSINESS_SPEC_SECTIONS),
            ("DesignSpec", DESIGN_SPEC_SECTIONS),
        ):
            if index >= len(sections) or spec_bytes[label] is None:
                continue
            section = sections[index]
            body = subsection_body(spec_bytes[label], section.encode("utf-8"), normalize=False)
            if body:
                pairs.append((label + " § " + section, body.decode("utf-8", "replace")))
    return pairs


SPEC_RECORD_KINDS = ("entity", "endpoint")
SPEC_RECORD_STATUSES = ("present", "absent", "unchecked")
SPEC_RELABELED_LABEL = "unchecked (claimed absent, no evidence)"


def derive_spec_records(payload):
    """Validate a research agent's entity/endpoint presence findings, relabel
    every `absent` claim that carries no evidence to `unchecked`, and render the
    BusinessSpec section 4 / section 5 markdown rows.

    `absent` is a positive claim ("I looked and it is not there") and an empty
    `evidence` array says nothing was looked at, so the claim is downgraded to
    the honest answer. A record that arrived as `unchecked` with no evidence is
    the genuine never-checked case and passes through untouched -- it is NOT
    added to `relabeled`, which lists only the records this function changed.

    Raises ValueError naming the record's index and the invalid field.
    """
    if not isinstance(payload, dict):
        raise ValueError("input must be a JSON object with a 'records' list")
    raw = payload.get("records")
    if not isinstance(raw, list):
        raise ValueError("'records' must be a list")
    records = []
    relabeled = []
    labels = []
    for index, item in enumerate(raw):
        where = "records[%d]" % index
        if not isinstance(item, dict):
            raise ValueError(where + " must be an object")
        kind = item.get("kind")
        if kind not in SPEC_RECORD_KINDS:
            raise ValueError(
                where + ".kind must be 'entity' or 'endpoint' (got %s)" % json.dumps(kind)
            )
        name = item.get("name")
        if not isinstance(name, str) or not name.strip():
            raise ValueError(where + ".name must be a non-empty string")
        status = item.get("status")
        if status not in SPEC_RECORD_STATUSES:
            raise ValueError(
                where
                + ".status must be 'present', 'absent' or 'unchecked' (got %s)"
                % json.dumps(status)
            )
        evidence = item.get("evidence", [])
        if not isinstance(evidence, list) or not all(isinstance(e, str) for e in evidence):
            raise ValueError(where + ".evidence must be a list of strings")
        relabel = status == "absent" and not evidence
        if relabel:
            status = "unchecked"
            relabeled.append(kind + ":" + name)
            sys.stderr.write(
                "spec-derivation: %s '%s' claimed absent with no evidence - relabeled unchecked\n"
                % (kind, name)
            )
        records.append(
            {"kind": kind, "name": name, "status": status, "evidence": list(evidence)}
        )
        labels.append(SPEC_RELABELED_LABEL if relabel else status)
    rows = {"entity": [], "endpoint": []}
    for record, label in zip(records, labels):
        rows[record["kind"]].append(
            "| %s | %s | %s |"
            % (record["name"], label, "; ".join(record["evidence"]) or "\u2014")
        )
    return {
        "records": records,
        "relabeled": relabeled,
        "markdown": {
            "entities": "\n".join(rows["entity"]),
            "endpoints": "\n".join(rows["endpoint"]),
        },
    }


STRUCTURAL_LEXICON = (
    "bottom sheet",
    "dialog",
    "modal",
    "drawer",
    "sidebar",
    "side panel",
    "header",
    "footer",
    "tab bar",
    "toolbar",
    "stepper",
    "step indicator",
    "card",
    "list",
    "grid",
    "popover",
    "tooltip",
    "toast",
    "banner",
    "accordion",
    "carousel",
    "full-screen",
    "overlay",
    "split view",
)


def _story_text(story):
    """One story's text for structural-vocabulary: title, description, every
    acceptanceCriteria entry, implementation.approach, every tasks[] entry and
    notes -- and no other field. A missing or mistyped field is empty text."""
    if not isinstance(story, dict):
        return ""
    implementation = story.get("implementation")
    parts = [story.get("title"), story.get("description")]
    criteria = story.get("acceptanceCriteria")
    parts.extend(criteria if isinstance(criteria, list) else [criteria])
    parts.append(implementation.get("approach") if isinstance(implementation, dict) else None)
    tasks = story.get("tasks")
    parts.extend(tasks if isinstance(tasks, list) else [tasks])
    parts.append(story.get("notes"))
    return "\n".join(part for part in parts if isinstance(part, str))


def measure_structural_vocabulary(stories, source_texts):
    """Count each STRUCTURAL_LEXICON term, verbatim, case-insensitive and as a
    whole phrase (a word-boundary match, so "playlist" is not "list"), in the
    spec/prototype texts and in the stories' text.

    `terms` lists only terms that occur somewhere, as {term, sourceCount,
    storyCount}. `missing` holds terms a source names that no story mentions;
    `unsourced` holds terms stories use that no source names. `measured` is
    false when no term occurs anywhere -- there was nothing to measure.
    """
    story_blob = "\n".join(_story_text(story) for story in stories)
    source_blob = "\n".join(source_texts)
    terms = []
    missing = []
    unsourced = []
    for term in STRUCTURAL_LEXICON:
        pattern = re.compile(r"(?<!\w)" + re.escape(term) + r"(?!\w)", re.IGNORECASE)
        source_count = len(pattern.findall(source_blob))
        story_count = len(pattern.findall(story_blob))
        if not (source_count or story_count):
            continue
        terms.append({"term": term, "sourceCount": source_count, "storyCount": story_count})
        if source_count and not story_count:
            missing.append(term)
        if story_count and not source_count:
            unsourced.append(term)
    return {
        "measured": bool(terms),
        "terms": terms,
        "missing": missing,
        "unsourced": unsourced,
    }


def design_decisions(brainstorm_bytes):
    """The awk/sed/awk/sed/head pipeline, rewritten from a single-heading
    prefix match into a shape rule over every top-level `## ` heading (see
    DECISIONS_HEADING_RE), because a real brainstorm can carry its decisions
    under `## Key Decisions` with no `## Design Decisions` heading anywhere,
    and the old prefix match silently returned "" for one.

    Every `## ` section whose heading matches DECISIONS_HEADING_RE is a
    matched section, in document order. A SECOND matching heading does not
    close the first -- two `## Design Decisions` sections still both survive
    (brainstorm-secao-duplicada), the same merge-not-close rule the old
    prefix-match scanner had, now over the wider match set. Exactly one
    matched section returns its bare body unchanged, same as before a shape
    rule existed at all. Two or more matched sections concatenate in document
    order, each carrying its own `## <Heading>` line as provenance -- the
    reader can no longer tell two concatenated sections apart by content
    alone, so the heading is what tells them apart.

    DECISIONS_CAP is no longer a byte-slice point (`head -c` truncated a
    single stream mid-sentence); it is a whole-section eviction budget, in the
    same two-pass shape skills_payload() already uses a few functions up:
    drop any section whose own block alone exceeds the cap before aggregating,
    then evict whole sections from the end -- lowest priority, meaning
    last-matched in document order -- while the remaining concatenation is
    still over the cap. No section's body is ever byte-sliced; a section
    either survives whole or is dropped whole, and a marker names every
    dropped heading and the byte size of the block it cost.
    """
    lines = brainstorm_bytes.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()

    matched = [
        (heading, _section_body(body))
        for heading, body in _split_top_sections(lines)
        if _is_decisions_heading(heading)
    ]
    if not matched:
        return ""

    multi = len(matched) > 1
    blocks = []
    for heading, body in matched:
        if not multi:
            block = body
        else:
            heading_text = heading.strip(b" \t\v\f\r")
            block = heading_text if not body else heading_text + b"\n" + body
        blocks.append((heading, block, len(block)))

    kept = []
    dropped = []
    for heading, block, size in blocks:
        if size > DECISIONS_CAP:
            dropped.append((heading, size))
            continue
        kept.append((heading, block, size))

    aggregate = sum(size for _, _, size in kept)
    while aggregate > DECISIONS_CAP and kept:
        heading, block, size = kept.pop()
        dropped.append((heading, size))
        aggregate -= size

    survivors = b"\n\n".join(block for _, block, _ in kept)
    if not dropped:
        return survivors.decode("utf-8", "replace")

    marker = _decisions_dropped_marker(dropped)
    result = marker if not survivors else survivors + b"\n\n" + marker
    return result.decode("utf-8", "replace")


def capped_spec_sections(sections):
    """Whole-section eviction over an already-sliced spec section list, the
    same two-pass shape skills_payload() and design_decisions() already use:
    drop any section whose own content alone exceeds SPEC_CAP first, then
    evict whole sections from the end of what remains while the aggregate is
    still over cap. No section is ever partially included -- this is a lazy-
    loading optimisation over what a payload carries inline, never a hard
    information cap: a section dropped here is deferred, not lost, since the
    bundle root and spec paths it was sliced from stay in the payload
    unconditionally via bundle_guidance() and can still be read on demand.

    `sections` is the caller's DECLARED PRIORITY ORDER, highest priority
    first -- the same declaration-order-is-priority-order rule
    skills_payload()'s own docstring states. Every section list this
    function receives is already sliced by contract section number (see the
    § N[.N] extractor, spec_sections() above); this function does no
    markdown heading-shape detection of its own and reuses none of
    design_decisions()'s DECISIONS_HEADING_RE / _split_top_sections
    machinery, which exists to find a section inside a raw brainstorm
    document -- a shape this input has already had removed before it
    arrives here.

    Returns (kept, dropped): `kept` is the surviving (label, content) pairs,
    in their original order; `dropped` is a list of
    {"section": label, "bytes": size, "reason": "oversized"|"aggregate"}
    dicts, one per evicted section, in the order each was evicted, reusing
    skills_payload()'s own reason vocabulary.
    """
    sized = [(label, content, len(content.encode("utf-8"))) for label, content in sections]

    kept = []
    dropped = []
    for label, content, size in sized:
        if size > SPEC_CAP:
            dropped.append({"section": label, "bytes": size, "reason": "oversized"})
            continue
        kept.append((label, content, size))

    aggregate = sum(size for _, _, size in kept)
    while aggregate > SPEC_CAP and kept:
        label, content, size = kept.pop()
        dropped.append({"section": label, "bytes": size, "reason": "aggregate"})
        aggregate -= size

    return [(label, content) for label, content, _ in kept], dropped


BUNDLE_GUIDANCE = (
    "Apply design bundle fidelity rules. Read the spec files cited below using "
    "the Read tool before authoring implementation code.\n"
    "\nBundle root: {root}\nDesignSpec: {design}\nBusinessSpec: {business}"
)


def bundle_guidance(docs):
    """The four `jq -r` reads of metadata.designBundle, in bash's order.

    The first one decided whether the block fires at all: `// empty` under `-r`,
    so null and false and an absent key produce nothing and an EMPTY OBJECT
    produces `{}` -- two characters, non-empty, gate open, three `(none)`s
    (bundle-vazio). The three that follow each default to the literal `(none)`
    rather than to the empty string, which is why a partial bundle reads as
    three labelled lines instead of three blanks.

    Each read ran over the whole STREAM, so a two-document file contributes two
    lines to a single field. Faithful rather than sensible: nothing downstream
    parses this text, it is prose handed to an agent.
    """
    present = _raw_lines(
        value
        for doc in docs
        for value in [jq_index(jq_index(doc, "metadata"), "designBundle")]
        if value is not None and value is not False
    )
    if not present:
        return ""

    def field(key):
        return _raw_lines(
            jq_alternative(
                jq_index(jq_index(jq_index(doc, "metadata"), "designBundle"), key), "(none)"
            )
            for doc in docs
        )

    return BUNDLE_GUIDANCE.format(
        root=field("root"), design=field("designSpec"), business=field("businessSpec")
    )


def design_context(docs, project_root, warn):
    """`{decisions, bundleGuidance, specSections}`, all three always present
    and always the right empty value when there is nothing to say -- never
    null, never absent. The story-executor prompt interpolates them directly,
    so an absent key and an empty one are not the same thing to the only
    consumer there is. Returns `(context, dropped)`: `context` is the dict
    above, `dropped` is this function's own contribution to
    op_get_story_context's unified `dropped[]` list (skills_payload()
    contributes the rest) -- kept apart from `context` because `dropped` is a
    TOP-LEVEL payload key, not a `designContext` one.

    The brainstorm path is NOT confined to the project root, and that is the
    pre-port rule reproduced rather than an oversight: an absolute
    `metadata.brainstormPath` is used as given and a relative one is joined onto
    PROJECT_ROOT with no traversal check. validate-tasks' spec paths were
    confined in their own commit, with their own diff; doing the same here on
    the way past would hide a rule change inside a port.

    `specSections` and the spec-shaped `dropped` entries are this function's
    own wiring of spec_sections()/capped_spec_sections() into the live
    payload (see their own docstrings for the slicing and cap rules). Both
    spec paths are resolved through confined_spec_path() exactly ONCE for the
    whole payload build -- spec_sections()'s own `file_facts` out-parameter
    hands back the confinement/existence facts it already computed for
    slicing, so this function never re-resolves either path itself.
    """
    relative = _raw_lines(
        value
        for doc in docs
        for value in [jq_index(jq_index(doc, "metadata"), "brainstormPath")]
        if value is not None and value is not False
    )
    decisions = ""
    if relative:
        path = relative if relative.startswith("/") else project_root + "/" + relative
        if os.path.isfile(path):
            with open(path, "rb") as handle:
                decisions = design_decisions(handle.read())

    file_facts = {}
    pairs = spec_sections(docs, project_root, file_facts)
    kept, capped_dropped = capped_spec_sections(pairs)
    spec_sections_payload = {label: content for label, content in kept}

    dropped = []
    for label in ("BusinessSpec", "DesignSpec"):
        facts = file_facts.get(label) or {}
        if facts.get("relative") is None:
            continue
        if not facts["inside"]:
            reason = "escapes-project-root"
        elif not facts["isfile"]:
            reason = "missing-on-disk"
        else:
            continue
        warn("spec file " + facts["relative"] + " dropped — " + reason)
        dropped.append({
            "kind": "specFile", "name": None, "path": facts["relative"],
            "section": None, "reason": reason, "bytes": None, "deferred": False,
        })

    for entry in capped_dropped:
        section_label = entry["section"]
        spec_label = section_label.split(" § ", 1)[0]
        relative_path = (file_facts.get(spec_label) or {}).get("relative")
        warn(
            "spec section " + section_label + " dropped — "
            + entry["reason"] + " (" + str(entry["bytes"]) + " bytes)"
        )
        dropped.append({
            "kind": "specSection", "name": None, "path": relative_path,
            "section": section_label, "reason": entry["reason"],
            "bytes": entry["bytes"], "deferred": True,
        })

    context = {
        "decisions": decisions,
        "bundleGuidance": bundle_guidance(docs),
        "specSections": spec_sections_payload,
    }
    return context, dropped


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


def write_verification_verdict(story, status, reason):
    """The ONE mutation point a verification verdict is ever written through.

    `op_set_verification` below calls this directly, and outline:03's
    `judge-verification` is documented to call it too, so an evidence-derived
    verdict and an operator-typed one share exactly one path rather than two
    that could drift apart -- the same reasoning that keeps VERIFICATION_
    STRATEGIES/STATUSES to one definition instead of a second list per caller.

    Copies the story's existing verification object, sets `status`, and --
    for `status == "skipped"` only -- sets `skipReason` to the reason,
    sanitized through `rm_sanitize` at `VERIFICATION_SKIP_REASON_MAXLEN`.
    `rm_sanitize` already collapses \\r\\n/\\r/\\n to a space, so this does not
    hand-roll a second collapse. Every OTHER status pops any stale
    `skipReason` key instead: a passed/failed verdict recorded after an
    earlier skip must not leave that reason sitting beside the new one.

    Returns a new story dict -- never mutates `story` in place, the same
    discipline `jq_setpath` already keeps -- so a caller still holding the
    old object sees the old verification untouched.
    """
    verification = dict(story.get("verification") or {})
    verification["status"] = status
    if status == "skipped":
        verification["skipReason"] = rm_sanitize(reason, VERIFICATION_SKIP_REASON_MAXLEN)
    else:
        verification.pop("skipReason", None)
    updated = dict(story)
    updated["verification"] = verification
    return updated


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


def normalize_waves(doc):
    """Recompute every story's `wave` from `dependsOn`, in place.

    The rule is compute_waves' own -- roots at 1, everyone else at
    max(dependency waves) + 1 -- imported at the top of this file and called
    here unchanged. `wave` is documented (commands/plan.md) as DERIVED and
    informational only: nothing in dispatch reads it (list_ready does not
    mention it, and validate_waves is the one place in this file that does),
    so this verb exists to correct a stale number by hand, never to hand
    dispatch a new one to read.

    Unlike the two normalizers above, compute_waves needs every story's `id`
    as a plain dict key rather than through the null-tolerant jq_index --
    that plain `story["id"]` is exactly what makes it the writer's own rule
    and not a restatement, so the one precondition it assumes is guarded
    here instead of inside it: a story whose id is missing, null, or not a
    string raises the same MalformedTasks a null-keyed userStories map
    raises everywhere else in this file, before compute_waves ever runs.
    dependsOn is left to compute_waves' own `// []` equivalent, the same as
    at every other call site.

    Returns the count of stories whose stored wave this write actually
    changed -- computed by comparing before and after with jq_equal, read
    off the document AFTER compute_waves ran, the same shape the other two
    normalizers already report in and for the same reason: a second read
    once the lock has released could see a document another writer already
    changed.
    """
    stories = _stories(doc)
    for story in stories:
        story_id = jq_index(story, "id", STORY)
        if not isinstance(story_id, str):
            raise MalformedTasks(
                ".userStories: cannot use " + _json_type(story_id) + " as an object key"
            )
    before = [story.get("wave") for story in stories]
    compute_waves(stories)
    doc["userStories"] = stories
    return sum(1 for story, prior in zip(stories, before) if not jq_equal(story.get("wave"), prior))


def _report_project(story):
    """The `project` a visual story reports through verification-report --
    a STRING passes through unchanged, everything else -- absent, null, or any
    other JSON type -- collapses to `None`.

    This is a deliberate divergence from raw `.project`, closing the
    array-valued-project hazard at its one source rather than at each of the
    sites that used to read it. jq's `// "DEFAULT"` (or `// "."`) only
    substitutes on null and false, so a `.project` that arrived as an ARRAY
    sailed through the alternative unchanged, and `jq -r` printed it across
    several lines -- turning one story into several bogus group keys in a
    caller's read loop. Collapsing every non-string here means each caller's
    own default still fires on exactly the shapes that used to explode, and on
    nothing else -- string projects are untouched, an absent or null one still
    reports as no-project.
    """
    project = jq_index(story, "project", STORY)
    return project if isinstance(project, str) else None


def _report_url(verification):
    """The `url` a visual story reports through verification-report -- the
    same divergence as `_report_project`, applied to `.verification.url`.

    jq's `// empty` (the guard every per-story url site used) only fires on
    null and false, so a non-string url -- an array, say -- sailed through
    unrewritten and reached `$WORKTREE_MGR serve url` as `jq -r`'s multi-line
    pretty-print of it. A STRING passes through unchanged; everything else --
    absent, null, false, or any other type -- reports as the empty string,
    which is what every caller already treats as "no url" today.
    """
    url = jq_index(verification, "url", STORY + ".verification")
    return url if isinstance(url, str) else ""


def _report_status(verification):
    """The `status` a visual story reports through verification-report, and
    the same value the `pending` partition is decided on -- one reading of
    `.verification.status`, not two.

    Collapses like `_report_project` rather than `_report_url`: a STRING
    passes through unchanged, every other shape -- absent, null, a number, an
    array -- reports as `None`. The empty string is a string and survives as
    one. `None` is the honest answer here because the whole point of the
    partition beside this field is telling "declared and not looked at" apart
    from "never declared": defaulting an absent status to "pending" would make
    a `visual` entry claim a status the `pending` list, which matches the
    LITERAL only, refuses to count -- two halves of one report disagreeing
    about the same story.
    """
    status = jq_index(verification, "status", STORY + ".verification")
    return status if isinstance(status, str) else None


def _report_skip_reason(verification):
    """The `reason` a skipped verification reports through verification-report
    -- `.verification.skipReason` when it is a non-empty STRING, `None` for
    every other shape (absent, null, empty, or any non-string).

    Collapses like `_report_status` immediately above, not like `_report_url`:
    a legacy skip written before `skipReason` existed (the specFlow:Gap2/
    Gap3-era shape) carries no such key at all, and `None` is the honest
    answer for that story. "no reason recorded" is completion-report and
    handoff-line WORDING, chosen by the reader that renders this value --
    inventing that string, or any other, at THIS layer would fabricate
    evidence for a run that recorded none, which is the exact defect this
    report exists to refuse.
    """
    reason = jq_index(verification, "skipReason", STORY + ".verification")
    return reason if isinstance(reason, str) and reason else None


def _report_discriminating(verification, vtype):
    """The count at `.verification.evidence.discriminating` -- how many of a
    story's verify segments behaved differently before its work than after --
    or `None` when NOTHING usable was recorded there.

    `None` is a third answer, not a zero. Every shape that fails to produce a
    real count reports it: a non-object `verification` (absent, null, a bare
    string, a number), an `evidence` that is not an object, an absent
    `discriminating` key, and a value that is not a plain integer. The caller
    routes `None` to `unrecorded` and a real `0` to `blind`, and the whole
    partition exists to keep those two apart -- see `verification_report`.

    THE BOOL TEST COMES FIRST AND IS NOT OPTIONAL. Python's
    `isinstance(True, int)` is `True`, so `{"discriminating": true}` would
    otherwise read as the count 1 and land a story in `checked` on the
    strength of a boolean nobody meant as a number. A float, a string, a
    negative int and an absent key are rejected for the same reason in a
    milder form: each of them is a field somebody wrote in a shape this
    partition cannot count, and inventing a number for it would be worse than
    saying nothing was recorded.

    That tolerance is also the phase's integration safety net. The writers of
    this field live in other stories; if one of them ships a different field
    name, every reading here degrades to "never recorded" -- visible in
    `unrecorded`, never a fabricated zero in `blind`.
    """
    if vtype != "object":
        return None
    evidence = jq_index(verification, "evidence", STORY + ".verification")
    if jq_type(evidence) != "object":
        return None
    count = jq_index(evidence, "discriminating", STORY + ".verification.evidence")
    if isinstance(count, bool) or not isinstance(count, int) or count < 0:
        return None
    return count


def _evidence_exit(verification, vtype):
    """The verify exit code at `.verification.evidence.exit`, or `None` when
    nothing usable was recorded there -- the same three-way shape
    `_report_discriminating` above already uses for `.evidence.discriminating`,
    reused here rather than re-derived, over the sibling field `op_judge_
    verification` actually judges.

    `None` covers every shape that is not a real exit code: a non-object
    `verification`, an `evidence` that is not an object, an absent `exit` key
    (including the story that recorded only `preExit`), and a value that is
    not a plain integer. The caller reads `None` as "no usable exit" and
    falls through to a skipped verdict; this function only answers whether an
    integer WAS recorded, never what to do about its absence.

    THE BOOL TEST COMES FIRST AND IS NOT OPTIONAL, for the identical reason
    `_report_discriminating`'s docstring gives: Python's `isinstance(True,
    int)` is `True`, so `{"evidence": {"exit": true}}` would otherwise read as
    the passing code 0 on the strength of a boolean nobody meant as an exit
    status. A float or a string is rejected the same way, in a milder form.
    """
    if vtype != "object":
        return None
    evidence = jq_index(verification, "evidence", STORY + ".verification")
    if jq_type(evidence) != "object":
        return None
    exit_code = jq_index(evidence, "exit", STORY + ".verification.evidence")
    if isinstance(exit_code, bool) or not isinstance(exit_code, int):
        return None
    return exit_code


def verification_report(doc):
    """One document read answering the three questions ten separate jq
    programs used to open the tasks file for: which stories carry a visual
    verification strategy (each with its own already-normalized `project`,
    `url` and `status`, see `_report_project`/`_report_url`/`_report_status`
    above), and how the old `type != "object"` malformed scan partitions into
    the shapes normalize-verification actually repairs and the shapes it does
    not -- plus four questions no jq program ever asked: which stories
    declared a verification nobody has looked at yet, which FINISHED stories
    left evidence that their verification discriminated anything at all,
    which FINISHED stories short-circuited their own verdict with a skip --
    and why -- and how the whole declared-and-finished population's verdicts
    are distributed across the value set.

    The `visual` list is exactly the old `select(.verification | type ==
    "object" and .strategy == "visual")` scan, order preserved -- a caller
    filtering it by `project`, taking its length, or reading its first entry
    is projecting from ONE read rather than opening a second one. Its `status`
    is the one field the old scan left a caller to reopen the file for: an
    entry carrying `id`, `project` and `url` alone cannot say whether the
    visual check passed, which is the second read this verb exists to remove.

    `pending` is the ids of every story whose `verification.status` is the
    LITERAL "pending", whatever its strategy -- the stories a phase declared a
    verification for and nobody has judged. Two boundaries make it usable as a
    completed-gate input rather than a tripwire. It is scoped to the object
    branch, so a story with NO verification object never enters: the partition
    counts what was declared and not looked at, never what was never declared,
    and the other reading would fail every legacy phase whose stories predate
    the field. And it matches on the literal alone, via the same `jq_equal`
    the strategy test uses, so no non-string shape can drift in through a
    default.

    The malformed partition reuses `_verification_migrated`'s own predicate
    (`isinstance(verification, str)`) rather than restating it, so the two
    cannot drift apart again: `repairable` is exactly the set
    normalize-verification rewrites (a bare string, the empty string
    included), `unrepairable` is everything else the old scan flagged -- a
    number, an array, a boolean. The UNION of the two, in document order, is
    exactly the id list the old `type != "object"` scan produced; only the
    split is new.

    `discriminating` is the fourth key and the only one that judges the
    EVIDENCE a finished run left behind, rather than the declaration it
    started from. It partitions the COMPLETED stories -- and only those --
    into `checked` (a verification whose recorded count of discriminating
    verify segments is at least 1), `blind` (a recorded count of exactly 0)
    and `unrecorded` (no usable count at all, see `_report_discriminating`),
    plus a `fraction` of checked over checked-plus-blind. Scope is
    `roadmap.py:_completed_story_ids`' and the argument is that function's,
    not restated here: a verification judges work that was DONE, and
    `cascade-skip` writes `status: "skipped"` without touching `verification`,
    so an unscoped partition would count stories nobody could have verified.
    Note where the status test has to live for that to hold -- outside the
    `type == "object"` arm below, because a completed story with NO
    verification is precisely the case `unrecorded` exists to name.

    `skipped` is the fifth key, and unlike the four above it is not a
    partition of anything -- it is a flat list of `{id, reason}`, one entry
    per COMPLETED story whose `verification.status` is the literal
    "skipped". Its scope is the identical completed-only boundary
    `discriminating` draws two paragraphs up, and for the identical reason:
    a verification judges work that was DONE, and a story `cascade-skip`
    marked `status: "skipped"` (never touching `verification`) has no
    verdict to report here. The read that decides membership is computed
    once, in a single `is_completed` local the loop below shares with the
    `discriminating` partition immediately after it, rather than asked
    twice of the same field. specFlow:Gap3 and CriticalQ1 are why this key
    exists at all: the operator chose "skipped, with a reason" over the
    silent blanket-pass a completion report used to give a story nobody
    actually verified, and `skipped` is what lets the completion report and
    the phase handoff say WHY a verdict was short-circuited instead of
    staying quiet about it. `reason` is `_report_skip_reason`'s answer, and
    it is `None` -- never a fallback string this layer invents -- for a
    legacy skip that predates `skipReason` (the specFlow:Gap2/Gap3-era
    shape written before this field existed): the same honest-null
    discipline `_report_discriminating`'s own docstring states for its
    `None`, because fabricating a reason here would be exactly the
    fabricated evidence this whole report exists to refuse.

    `unrecorded` and `blind` are different answers and conflating them would
    be worse than the silence this key replaces. `blind` says we looked and
    found nothing that discriminated; `unrecorded` says nothing was ever
    written down. A legacy tasks file -- every story completed, no evidence
    anywhere -- must not report a confident zero for exactly the runs issue
    #136 calls unreadable. That is also why `unrecorded` stays OUT of
    `fraction`'s denominator: a run with no evidence at all has no fraction,
    so it answers `None`, while a run that recorded honest zeros answers `0`.
    Those two numbers are what make this the first pipeline metric that MOVES
    when verification actually improves.

    `verdicts` is the sixth key, and it is a DISTRIBUTION rather than a
    partition of ids: one count per `VERIFICATION_STATUSES` literal, plus
    `other`, over exactly the population `pending` above already reads from
    -- a completed story (the same `is_completed` local the `skipped` and
    `discriminating` scopes already share) whose verification is an object.
    Where `pending` answers "how many are still unjudged" and `skipped`
    answers "which ones were short-circuited and why", `verdicts` answers the
    whole question at once: how many completed-and-declared stories landed on
    each of the judged states. A completed story whose `verification.status`
    is a non-string, or a string outside `VERIFICATION_STATUSES`, still counts
    -- under `other` -- rather than being silently dropped or aborting the
    report; a document a future change adds a fifth status literal to degrades
    to a visible `other` count instead of a `KeyError`. A completed story with
    no verification object at all (the `unrecorded` case above) never reaches
    this count either, the identical object-only boundary `pending` draws for
    the identical reason: a distribution over declarations nobody made would
    answer a question nobody asked.

    AND THE NUMBER STILL READS HIGH -- a ceiling on what was verified, never a
    measurement of it. The count originates in `verify-probe`'s
    `discriminates`, and `probe_verify` carries only assignments and `cd` into
    each assertion's isolated shell, so a verify whose fixture is built by
    anything that mutates the SHELL -- a subshell, a function definition, a
    `set -o` -- has the segments after it measured against state that was never
    reproduced, and a segment failing for that reason alone is scored
    `discriminates: true`. Three phase-2 executors hit this; the gap is written
    up in
    `.aimi/known-gaps/2026-09-04-p2-verify-probe-tem-uma-terceira-cegueira.md`.

    TWO CORRECTIONS TO THAT RECORD, BOTH MEASURED. It names `mkdir` and
    `printf > file` among the causes and they are NOT: every segment runs as a
    real subprocess in the same directory, so a fixture built on DISK persists
    and the assertions after it read it back -- see `probe_verify`'s own
    docstring, which carries the measurement. And the shell-VARIABLE half of
    the gap is closed: a segment reading a variable no carried assignment
    provides is now scored `discriminates: None`, which is neither the `true`
    the executor counts into this number nor the `false` it reports as an
    assertion that already passes. What remains open is the rest of shell
    state, so read the number with that narrower caveat rather than fixing the
    probe from here.
    """
    visual = []
    pending = []
    skipped = []
    repairable = []
    unrepairable = []
    checked = []
    blind = []
    unrecorded = []
    # One count per VERIFICATION_STATUSES literal, plus the catch-all `other`
    # -- see verdicts' own docstring paragraph above for its scope.
    verdicts = {status: 0 for status in VERIFICATION_STATUSES}
    verdicts["other"] = 0
    for story in _stories(doc):
        story_id = jq_index(story, "id", STORY)
        verification = jq_index(story, "verification", STORY)
        vtype = jq_type(verification)
        # Read once, shared by the `skipped` membership test below and by
        # the `discriminating` partition a few lines down -- the same field
        # asked twice is the drift this hoist exists to close.
        is_completed = jq_equal(jq_index(story, "status", STORY), "completed")
        if vtype == "object":
            status = _report_status(verification)
            if jq_equal(status, "pending"):
                pending.append(story_id)
            if jq_equal(status, "skipped") and is_completed:
                skipped.append({"id": story_id, "reason": _report_skip_reason(verification)})
            if is_completed:
                if status in VERIFICATION_STATUSES:
                    verdicts[status] += 1
                else:
                    verdicts["other"] += 1
            strategy = jq_index(verification, "strategy", STORY + ".verification")
            if jq_equal(strategy, "visual"):
                visual.append(
                    {
                        "id": story_id,
                        "project": _report_project(story),
                        "url": _report_url(verification),
                        "status": status,
                    }
                )
        elif vtype != "null":
            (repairable if vtype == "string" else unrepairable).append(story_id)
        # Outside the arm above on purpose: a completed story whose
        # verification is absent or null never reaches it, and that story is
        # exactly what `unrecorded` is for.
        if is_completed:
            count = _report_discriminating(verification, vtype)
            if count is None:
                unrecorded.append(story_id)
            elif count >= 1:
                checked.append(story_id)
            else:
                blind.append(story_id)
    denominator = len(checked) + len(blind)
    return {
        "visual": visual,
        "pending": pending,
        "skipped": skipped,
        "malformed": {"repairable": repairable, "unrepairable": unrepairable},
        "discriminating": {
            "checked": checked,
            "blind": blind,
            "unrecorded": unrecorded,
            "fraction": len(checked) / denominator if denominator else None,
        },
        "verdicts": verdicts,
    }


PROJECT_PATTERN = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$")


def _project_traversal_shaped(value):
    """bash's `case "$X" in /*|..|../*|*/..|*/../*)`, ported arm for arm: a
    leading slash, the bare string "..", a leading "../", a trailing "/..",
    or "/../" anywhere in the middle. Exactly the two-guard pair
    commands/execute.md Step 0.9 and commands/plan.md Phase 3e both apply to
    the same field today, kept byte-identical so a diff of the two still
    means something."""
    return (
        value.startswith("/")
        or value == ".."
        or value.startswith("../")
        or value.endswith("/..")
        or "/../" in value
    )


def _invalid_project(value):
    """True unless `value` is the root group's own routing key (".", always
    exempt) or passes both guards above: not traversal-shaped, and every
    character inside `^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$`."""
    if value == ".":
        return False
    return _project_traversal_shaped(value) or not PROJECT_PATTERN.match(value)


def project_groups(doc):
    """The END STATE five command-layer sites (execute.md's Derive
    Participating Project Groups, Phase Container Dev Server Bootstrap,
    Procedure/verify-creates, Mark Phase Completed, Offer a Pull Request) used
    to compute inline -- `jq -r '.userStories[] | (.project // ".")'` piped
    through `grep -v '^$' | sort -u`, then a bash fallback to `.` when that
    came back empty -- plus the answer a sixth site, the Unsupported
    Combination Guard, asked as a SEPARATE question: how many stories carry a
    project at all. One call now answers both, because the group list alone
    cannot: a story authored with `project: "."` and one with no `project`
    field both collapse into the same "." group, and only the first should
    count toward `projectStoryCount`.

    `.project` is normalized through `_report_project` first -- the same
    array-valued-project collapse `verification_report` (US-003) already
    applies to the same field, made to agree rather than reinvented. That
    normalization reaches `projectStoryCount` too, not only the group list:
    a non-string `.project` (an array, a number, an object) is treated as no
    project throughout this verb, a deliberate, stated divergence from the
    guard's old raw `(.project // null) != null` -- which counted a
    non-null NON-STRING project too. This verb never lets one through to a
    filesystem join in the first place, so there is nothing left for that
    raw check to catch that normalization has not already caught.

    Every distinct group other than "." is then validated against
    `_invalid_project` -- the same two-guard pair `commands/execute.md` Step
    0.9 and `commands/plan.md` Phase 3e already apply to `SPLIT_PROJECT`, now
    applied here to the FIVE sites that used to skip it entirely. Every
    offender is collected, not just the first, mirroring plan.md's own
    "report every offending value and STOP" gate; MalformedTasks carries all
    of them in one message rather than aborting at the first.

    A document with no `userStories` key raises MalformedTasks via `_stories`
    -- the same abort the five grouping sites' own strict `.userStories[]`
    already produced (recorded as site-013's `userstories-absent` case,
    exit 5, "Cannot iterate over null"), and deliberately NOT the guard's old
    `.userStories[]?`, which answered a silent 0 for that same document
    (site-007, same fixture, exit 0). One call now answers both questions, so
    it keeps the STRICTER of the two: a malformed document must refuse, not
    silently agree with the guard that nothing here carries a project.
    """
    stories = _stories(doc)
    projects = [_report_project(story) for story in stories]
    raw_groups = [jq_alternative(project, ".") for project in projects]
    project_story_count = len([project for project in projects if isinstance(project, str)])
    groups = sorted({group for group in raw_groups if group != ""})
    if not groups:
        groups = ["."]
    offenders = [group for group in groups if _invalid_project(group)]
    if offenders:
        raise MalformedTasks(
            "invalid project "
            + ", ".join('"' + offender + '"' for offender in offenders)
        )
    return {"groups": groups, "projectStoryCount": project_story_count}


def op_project_groups(argv):
    """The verb five command-layer grouping sites and one routability guard
    replace, in `execute.md` -- see `project_groups`'s own docstring for the
    shape and the deliberate tightening it introduces. Same explicit-path
    convention `verification-report` established: the caller always names a
    tasks file explicitly (the phase, split-member or main tasks file), never
    the session-bound one, so aimi-cli.sh's wrapper is what falls back to
    `get_tasks_file` when the flag is omitted."""
    path = _flag(argv, "--tasks-file")
    if not path:
        die("Usage: tasks.py project-groups --tasks-file <path>")
    for doc in read_docs(path, "project-groups"):
        _emit(project_groups(doc))
    return 0


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


def op_verification_report(argv):
    """The verb ten command-layer jq programs replace. Unlike `status`, the
    caller names a tasks file explicitly rather than the session-bound one --
    the phase, split and main-tasks files this answers for are never the file
    `get_tasks_file` would resolve. aimi-cli.sh's wrapper is what falls back
    to `get_tasks_file` when the caller omits `--tasks-file`; this op always
    receives an explicit path, same as `status` and `metadata` above."""
    path = _flag(argv, "--tasks-file")
    if not path:
        die("Usage: tasks.py verification-report --tasks-file <path>")
    for doc in read_docs(path, "verification-report"):
        _emit(verification_report(doc))
    return 0


def op_count_pending(argv):
    path = _flag(argv, "--tasks-file")
    if not path:
        die("Usage: tasks.py count-pending --tasks-file <path>")
    for doc in read_docs(path, "count-pending"):
        _emit(count_with_status(_stories(doc), "pending"))
    return 0


def op_run_verdict(argv):
    path = _flag(argv, "--tasks-file")
    if not path:
        die("Usage: tasks.py run-verdict --tasks-file <path>")
    for doc in read_docs(path, "run-verdict"):
        _emit(run_verdict(doc))
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


def _emit_echoed(verdicts):
    """bash's `echo "$(jq …)"`, which is not the same as letting jq print.

    Command substitution strips EVERY trailing newline and `echo` puts exactly
    one back, so a stream of two verdicts prints as two objects with one newline
    at the end -- and a stream of NONE prints a single blank line rather than
    nothing at all. doc-vazio records that blank line, and reproducing it is
    what keeps an empty tasks file looking to a caller exactly as it did.
    """
    rendered = "".join(
        json.dumps(jq_numbers(verdict), indent=2, ensure_ascii=False) + "\n"
        for verdict in verdicts
    )
    sys.stdout.write(rendered.rstrip("\n") + "\n")


def op_validate_deps(argv):
    """The verdict, then bash's own re-read of it to decide the exit status.

    `is_valid=$(echo "$errors" | jq -r '.valid')` collected ONE line per
    document and compared the lot against the four characters `true`, so a file
    holding two valid documents exits 1 -- two lines never equal one word.
    Recorded as dois-documentos-validos-deps, and reproduced rather than tidied:
    a caller branching on `$?` sees today what it saw before.
    """
    path = _flag(argv, "--tasks-file")
    if not path:
        die("Usage: tasks.py validate-deps --tasks-file <path>")
    verdicts = [validate_deps(doc) for doc in read_docs(path, "validate-deps")]
    _emit_echoed(verdicts)
    valid_lines = "\n".join("true" if v["valid"] else "false" for v in verdicts)
    return 0 if valid_lines == "true" else 1


def op_validate_stories(argv):
    """Same verdict shape, a different exit rule, and both are bash's.

    The status came from `echo "$result" | jq -e '.valid == false'`, and `-e`
    reports on the LAST value a program produced -- so over two documents only
    the second one's verdict decides, and over ZERO values jq exits 0, which
    inverts into a refusal here. doc-vazio-stories records the exit 1 an empty
    tasks file earns.
    """
    path = _flag(argv, "--tasks-file")
    if not path:
        die("Usage: tasks.py validate-stories --tasks-file <path>")
    verdicts = [validate_stories(doc) for doc in read_docs(path, "validate-stories")]
    _emit_echoed(verdicts)
    if not verdicts or not verdicts[-1]["valid"]:
        return 1
    return 0


def op_validate_ids(argv):
    """ONE verdict over the whole stream, unlike its three siblings.

    The ids were pooled by a single `jq -r` before bash ever looked at them, so
    two concatenated documents produce one count and one error list rather than
    one verdict each.
    """
    path = _flag(argv, "--tasks-file")
    if not path:
        die("Usage: tasks.py validate-ids --tasks-file <path>")
    verdict, status = validate_ids(read_docs(path, "validate-ids"))
    _emit(verdict)
    return status


def op_validate_waves(argv):
    """ALWAYS 0. Not an oversight to tidy up on the way past.

    cmd_validate_waves' bash body ended at its jq call -- no `return 1`, unlike
    all three of its siblings -- so an invalid verdict has always exited 0 and
    the verdict has always lived in `.valid`. part1-core asserts the exit status
    against a wave-mismatch fixture so the omission cannot be quietly "fixed"
    into a regression for a caller that branches on `$?`.
    """
    path = _flag(argv, "--tasks-file")
    if not path:
        die("Usage: tasks.py validate-waves --tasks-file <path>")
    for doc in read_docs(path, "validate-waves"):
        _emit(validate_waves(doc))
    return 0


def op_validate_wave_contention(argv):
    """One verdict per document, and -- unlike its `validate-waves` neighbour
    -- a real exit status: return 1 when ANY verdict is invalid, 0 otherwise.

    A new verb inherits no legacy contract, so it takes the shape the other
    three real validators already have rather than copying `validate-waves`'
    preserved jq accident, or `op_validate_deps`' `valid_lines == "true"`
    quirk, or `op_validate_stories`' last-document-wins rule -- there is no
    caller of THIS verb to keep compatible with a jq body that no longer
    exists.
    """
    path = _flag(argv, "--tasks-file")
    if not path:
        die("Usage: tasks.py validate-wave-contention --tasks-file <path>")
    verdicts = [wave_contention(doc) for doc in read_docs(path, "validate-wave-contention")]
    for verdict in verdicts:
        _emit(verdict)
    return 0 if all(v["valid"] for v in verdicts) else 1


def op_validate_tasks(argv):
    """The fifteen rules, one crossing, no lock -- and the errors array built
    the way bash built it.

    `printf '%s\\n' "${errors[@]}" | jq -R . | jq -s .` fed jq LINES, so an
    error message carrying a newline became several array entries rather than
    one with an escape in it. A multi-line endpoint source is how that is
    reached and bs-endpoint-source-objeto records the three entries it yields.

    --project-root is a flag rather than a lookup because PROJECT_ROOT is
    bash's: find_aimi_root exports it and validate_path_in_project gates the
    tasks file against it before this is called. The spec paths cannot get the
    same treatment there -- they are read out of metadata.designBundle, which
    only exists on this side of the crossing.
    """
    path = _flag(argv, "--tasks-file")
    project_root = _flag(argv, "--project-root")
    if not path or not project_root:
        die("Usage: tasks.py validate-tasks --tasks-file <path> --project-root <path>")

    docs = read_docs(path, "validate-tasks")
    # ONE read of the metadata, which is the whole point. The empty-stream row
    # is what `if [ -n "$_vt_meta" ]` left every variable holding.
    fields = (
        validate_tasks_metadata(docs[0]) if docs else dict.fromkeys(VALIDATE_METADATA_FIELDS, "")
    )

    # R1 -- the schemaVersion gate. Below 3.3, one line on stderr and exit 0.
    if sort_v_first(fields["schema_version"], "3.3") != "3.3":
        sys.stderr.write(
            "skipping citation validation (schemaVersion " + fields["schema_version"]
            + " pre-dates citation enforcement)\n"
        )
        return 0

    def warn(message):
        sys.stderr.write(message + "\n")

    errors = validate_tasks(docs, path, project_root, fields, warn)
    if not errors:
        sys.stdout.write('{"valid": true, "errors": []}\n')
        return 0

    lines = []
    for error in errors:
        lines.extend(error.split("\n"))
    rendered = json.dumps(lines, indent=2, ensure_ascii=False)
    sys.stdout.write('{"valid": false, "errors": ' + rendered + "}\n")
    return 1


# The `metadata` keys this payload's ONE consumer actually reads. DERIVED BY
# MEASUREMENT, NOT FROM THE PROSE -- skills/story-executor/SKILL.md describes
# fields in running text that it never reads, so the list below comes from the
# reads themselves:
#
#     grep -rhoE 'metadata\.[a-zA-Z]+' \
#         plugins/aimi-engineering/skills/story-executor/ | sort -u
#
# On 28 September 2026, over SKILL.md and both files under references/, that
# printed five distinct matches -- metadata.designBundle (2 occurrences),
# metadata.designTokens (1), metadata.prototypePaths (10) and
# metadata.prototypeDropped (3) -- and, once added, metadata.prototypeSuperseded --
# plus one metadata.baseRef that names a
# DIFFERENT document's field entirely (step 1.5's own prose about a verify
# resolving baseRef from the full tasks file it reads directly, never from
# this payload) and is excluded from the tuple below for that reason. Re-run
# it rather than trusting this comment; a key that gains a reader has to gain
# a line here in the same commit, or the reader silently gets null.
#
# The story-executor skill is the whole consumer list, and that is measured too:
# commands/execute.md and commands/next.md read metadata from the tasks FILE
# through other verbs, never out of this payload.
#
# WHAT THIS DROPS IS THE POINT. metadata.decisions is the largest block a plan
# writes -- one object per resolved question, each carrying the question's own
# prose -- and nothing in the executor has ever read it, so it travelled in
# every spawn of every story for nothing.
#
# metadata.prototypeSuperseded joined the tuple with the same measured read:
# the executor checks it beside each prototypeDropped check (reading the
# superseded entry NEXT TO the prototype). It is a RECORD of a decision, and
# the key is deliberately absent from archive-task's cleanup tuple -- its
# `path` always names an entry of metadata.prototypePaths, which archive-task
# already confines and removes.
STORY_CONTEXT_METADATA_KEYS = (
    "designBundle",
    "designTokens",
    "prototypePaths",
    "prototypeDropped",
    "prototypeSuperseded",
)


def projected_metadata(metadata):
    """`.metadata` narrowed to STORY_CONTEXT_METADATA_KEYS, in the document's
    own key order.

    PRESENCE decides, not truthiness. A key the document carries as null is
    projected as null, because `designBundle: null` and no designBundle at all
    are different documents and bundle-null records the first of them. A key the
    document does not carry stays absent: emitting it as null would hand every
    consumer a key to test for and would make the payload claim the document
    said something it did not.

    A document with no metadata at all is unchanged -- `null` in, `null` out,
    the same answer metadata-ausente and metadata-null already record. Anything
    else that is neither dict nor None is returned as it arrived rather than
    refused here: design_context has already indexed `.metadata` by the time
    this runs, so a metadata that is a string aborted there (metadata-string),
    and inventing a second refusal for an unreachable shape would be a new rule
    wearing a projection's clothes.

    A caller that reads a key no longer projected gets jq's null, not an error:
    `.metadata.maxConcurrency` on `{}` is null exactly as it is on a document
    with no metadata, which is what keeps this narrowing from breaking a reader
    nobody has found yet.
    """
    if not isinstance(metadata, dict):
        return metadata
    return {
        key: value
        for key, value in metadata.items()
        if key in STORY_CONTEXT_METADATA_KEYS
    }


def op_get_story_context(argv):
    """One crossing, no lock, and the assembly order bash ran in.

    MEASURED, NOT ESTIMATED. 20 calls per sample after two discarded warm-ups,
    four samples of each build, alternating, both builds run from the same
    directory on the same host (Linux 6.8.0 x86_64, 16 cores) against the same
    fixture -- one story declaring five skills, a brainstorm with a Design
    Decisions section, a full designBundle:

        pre-port   medians 445.2 / 446.0 / 448.7 / 464.2 ms -> 447.4 ms
        post-port  medians 141.3 / 142.9 / 143.7 / 143.8 ms -> 143.3 ms
        ratio 3.1x

    Whole-CLI wall time, deliberately: bash startup, find_aimi_root's `git
    rev-parse`, get_tasks_file, validate_story_exists' own jq and python3's
    interpreter start are all still in both numbers, because all of them are
    what the agent actually waits for. The arithmetic that motivated this slice
    (13 jq startups at ~16.4 ms against one Python crossing at ~36 ms, about 6x)
    was about the FUNCTION; 3.1x is what the caller gets once the four gates
    that did not move are paid for too.

    --skills-base-dir and --project-root arrive as flags because both are
    bash's: _resolve_skills_base_dir globs the Claude Code plugin cache or reads
    $AIMI_PLUGIN_DIR (host detection this file has no business repeating), and
    PROJECT_ROOT is find_aimi_root's export. An empty --skills-base-dir means
    bash could not resolve one, and the answer to that is an empty skills array,
    silently -- the same answer the pre-port loop gave.

    The order is not cosmetic: skills first, then the brainstorm, then the
    bundle. Each of those stages can meet a document shape jq aborted on, and
    which one aborts first is what a caller sees -- metadata-string is recorded
    with the BRAINSTORM read's message because the skills read never touches
    `.metadata`, and bundle-string with the bundle's for the same reason.

    A pure reader: no lock, no temp file, nothing opened for writing. Every
    file it does open -- a SKILL.md, a brainstorm, and (since US-003 wired
    spec_sections() in) up to two spec files named by metadata.designBundle --
    is read-only and named by the document, which is why they are opened here
    rather than in bash.
    """
    path = _flag(argv, "--tasks-file")
    story_id = _flag(argv, "--story-id")
    project_root = _flag(argv, "--project-root")
    skills_base_dir = _flag(argv, "--skills-base-dir")
    if not path or story_id is None or not project_root or skills_base_dir is None:
        die(
            "Usage: tasks.py get-story-context --tasks-file <path> --story-id <id> "
            "--project-root <path> --skills-base-dir <path>"
        )

    docs = read_docs(path, "get-story-context")

    def warn(message):
        sys.stderr.write(message + "\n")

    skills, skills_dropped = skills_payload(
        declared_skill_names(docs, story_id), skills_base_dir, warn
    )
    context, spec_dropped = design_context(docs, project_root, warn)
    dropped = skills_dropped + spec_dropped

    # `--slurpfile tf` then `$tf[0]`: the story and the metadata come from the
    # FIRST document alone, however many the file holds. `select` is a filter
    # over a stream rather than a lookup, so a duplicated id emits the whole
    # payload twice -- id-duplicado records both objects.
    first = docs[0] if docs else None
    for story in stories_with_id(first, story_id):
        _emit(
            {
                "story": story,
                "metadata": projected_metadata(jq_index(first, "metadata")),
                "skills": skills,
                "designContext": context,
                "dropped": dropped,
            }
        )
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


def _evidence_object(raw, verb):
    """--evidence's text, deserialized ONCE, and refused unless it is an object.

    The field exists to be READ BACK -- the phase's own coverage fraction counts
    `verification.evidence.discriminating` as an int -- so a payload that is not
    an object is refused here, loudly and before any write, rather than stored
    and silently skipped by whoever reads it next. Refusing at exit 1 is the
    same policy jq_setpath already applies to a verification that is not an
    object: say no, write nothing.
    """
    try:
        value = json.loads(raw)
    except ValueError:
        die("Error: " + verb + ": --evidence is not valid JSON")
    if not isinstance(value, dict):
        die(
            "Error: " + verb + ": --evidence must be a JSON object, got "
            + _json_type(value)
        )
    return value


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
                + (" [--evidence <json>]" if status == "completed" else "")
            )
        patch = {"status": status}
        if status == "failed":
            # jq's `--arg notes "$notes"`: always a string, "" when the caller
            # gave none, and it lands beside status in one merge.
            patch["notes"] = _flag(argv, "--notes") or ""
        # The evidence does NOT travel in the patch. `patch` goes through
        # jq_add_object, a top-level `. + {…}`, so a {"verification": {…}} entry
        # would REPLACE the whole verification object and take strategy, status,
        # url and expect with it. It is assigned deep instead, below, by the same
        # jq_setpath writer update-field uses -- and parsed here, before the
        # document is read, so a payload that is not an object refuses without
        # touching the file.
        evidence = None
        if status == "completed":
            raw = _flag(argv, "--evidence")
            # An empty --evidence is an absent one, the same rule bash applies
            # on its side when it decides whether to build the flag at all.
            if raw:
                evidence = _evidence_object(raw, verb)
        docs = read_docs(path, verb)
        for doc in docs:
            mark_stories(doc, story_id, patch)
            if evidence is not None:
                assign_field(doc, story_id, ["verification", "evidence"], evidence)
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
    # The value-set guard on the two verification leaves -- exact string
    # equality on the WHOLE dotted path, checked before any document is read,
    # so `verification` alone (the golden update-field-sobrescreve-objeto
    # case, which replaces the whole object with the string "manual") is
    # untouched and update-field stays a general nested writer everywhere
    # else. Reads VERIFICATION_STATUSES/STRATEGIES rather than a second
    # literal list, per the cross-story contract.
    if field_path == "verification.status" and value not in VERIFICATION_STATUSES:
        die(
            "Error: update-field: verification.status " + jq_quoted(value)
            + " is not one of: " + ", ".join(VERIFICATION_STATUSES)
        )
    if field_path == "verification.strategy" and value not in VERIFICATION_STRATEGIES:
        die(
            "Error: update-field: verification.strategy " + jq_quoted(value)
            + " is not one of: " + ", ".join(VERIFICATION_STRATEGIES)
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


def op_set_execution_mode(argv):
    """The phase guard, the write and the echo-back, in one crossing.

    This verb crossed into Python ZERO times before: the guard was a jq read
    taken OUTSIDE the lock the write then happened under, and the write was a
    second jq into a bash mktemp file. That is the two-crossing shape, spelled
    in jq -- which is exactly why a check that counted crossings into Python
    never saw it. No race was reachable (nothing writes metadata.phase at
    runtime; /aimi:plan sets it once, when it generates the whole file), so
    what moves here is the shape, not a lost update.

    The echo-back goes through _emit_compact and NOT _emit: it was a printf in
    aimi-cli.sh, never a jq program, so it never had jq's two-space indent, and
    part1 compares the whole line.
    """
    path = _flag(argv, "--tasks-file")
    mode = _flag(argv, "--mode")
    if not path or not mode:
        die("Usage: tasks.py set-execution-mode --tasks-file <path> --mode <container|inline>")
    # The mode itself is NOT re-checked here. aimi-cli.sh refuses anything but
    # container/inline before this process starts -- that refusal needs no
    # document, so it belongs in bash ahead of the lock, and duplicating it
    # would give one rule two homes.
    docs = read_docs(path, "set-execution-mode")
    # The guard, reproduced over the STREAM because that is what it read.
    # `has_phase=$(jq -r '…' "$f")` captured ONE LINE PER DOCUMENT and compared
    # the whole capture against "true", so a file holding two concatenated
    # documents never refused, and an empty one -- yielding no line at all --
    # did not either. Same comparison, against the same joined text. `// null`
    # is jq's alternative, so a `phase: false` took the fallback and read as
    # absent; jq_alternative keeps that.
    verdicts = [
        "true"
        if jq_alternative(jq_index(jq_index(doc, "metadata"), "phase", ".metadata"), None)
        is not None
        else "false"
        for doc in docs
    ]
    if "\n".join(verdicts) == "true":
        die(
            "Error: Cannot set metadata.execution on a phase-scoped tasks file "
            "(metadata.phase is present): " + path
        )
    docs = [jq_setpath(doc, ["metadata", "execution"], mode, "") for doc in docs]
    write_docs_atomically(path, docs)
    _emit_compact({"execution": mode})
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


def op_remove_story(argv):
    """remove-story: withdraw a pending, dependency-free story and record why.

    The one deliberate exception to the mark-* wrapper shape it is otherwise
    modelled on: every mark-* verb has aimi-cli.sh call validate_story_exists
    BEFORE the lock, but this op decides every refusal itself, inside the
    single crossing -- not-found, not-pending, has-dependents, last-story,
    missing/empty --reason, in that fixed order. A caller targeting a
    nonexistent id must see "not found" rather than a later-stage message,
    which is why the order matters and is not incidental.

    metadata.decisions has no other Python writer anywhere in this file --
    every existing entry is written command-side, at plan time. This is the
    first, and its shape is authored fresh from the schema documented in the
    top-level CLAUDE.md's Tasks File Schema section, not ported from a jq
    program that no longer exists.
    """
    path = _flag(argv, "--tasks-file")
    story_id = _flag(argv, "--story-id")
    reason = _flag(argv, "--reason")
    if not path or story_id is None:
        die(
            "Usage: tasks.py remove-story --tasks-file <path> --story-id <id> "
            "--reason <text>"
        )
    docs = read_docs(path, "remove-story")

    # The first document (in stream order) that carries the id, mirroring how
    # op_validate_story_exists answers "found" across the whole stream. A
    # tasks file is one document in practice; this is well-defined either way.
    target_doc = None
    story = None
    for doc in docs:
        matches = stories_with_id(doc, story_id)
        if matches:
            target_doc = doc
            story = matches[0]
            break
    if target_doc is None:
        die("Error: remove-story: story " + story_id + " not found in " + path)

    status = jq_index(story, "status", STORY)
    if status != "pending":
        die(
            "Error: remove-story: story " + story_id + " is not pending "
            "(status: " + jq_tostring(status) + ")"
        )

    # _depends_on_any is the same predicate cascade_skip's closure uses --
    # reused rather than restated, including how it walks a malformed
    # dependsOn the same way jq_iterate does everywhere else in this file.
    dependents = sorted(
        jq_index(other, "id", STORY)
        for other in _stories(target_doc)
        if jq_index(other, "id", STORY) != story_id and _depends_on_any(other, [story_id])
    )
    if dependents:
        die(
            "Error: remove-story: story " + story_id + " has dependents: "
            + ", ".join(dependents)
        )

    if len(_stories(target_doc)) == 1:
        # Same jq_alternative(jq_index(...), None) shape op_set_execution_mode
        # already uses to read metadata.phase's presence.
        phase = jq_alternative(
            jq_index(jq_index(target_doc, "metadata"), "phase", ".metadata"), None
        )
        if phase is not None:
            die(
                "Error: remove-story: story " + story_id + " is the only story "
                "in " + path + " -- cancel the phase with roadmap-set-status "
                "--status cancelled instead"
            )
        die(
            "Error: remove-story: story " + story_id + " is the only story "
            "in " + path + " -- use archive-task instead"
        )

    if not reason or not reason.strip():
        die("Error: remove-story: --reason is required")

    remaining = [s for s in _stories(target_doc) if jq_index(s, "id", STORY) != story_id]
    target_doc["userStories"] = remaining

    metadata = target_doc.get("metadata")
    if not isinstance(metadata, dict):
        metadata = {}
        target_doc["metadata"] = metadata
    decisions = metadata.get("decisions")
    if not isinstance(decisions, list):
        decisions = []
        metadata["decisions"] = decisions

    sanitized_reason = rm_sanitize(reason, 2000)
    title = jq_index(story, "title", STORY)
    sanitized_title = rm_sanitize(title, 2000) if isinstance(title, str) else title
    decisions.append(
        {
            "anchor": "removeStory:" + story_id,
            "source": "removeStory",
            "text": sanitized_title,
            "resolution": (
                "removed: " + sanitized_reason + " ("
                + time.strftime("%Y-%m-%d", time.gmtime()) + ")"
            ),
        }
    )

    write_docs_atomically(path, docs)
    _emit({"id": story_id, "removed": True, "remaining": len(remaining)})
    return 0


def op_set_verification(argv):
    """set-verification: record an explicit verification verdict, never a raw
    update-field write.

    Modeled on op_remove_story rather than on _mark_op: every refusal is
    decided here, inside the single crossing, in this fixed order -- status
    outside the allowed set (which excludes "pending" -- recording a verdict
    is the opposite of "nobody looked yet"), a --reason mismatched to the
    status (missing for skipped, present for passed/failed), not found, and
    "no verification object to update" for a story whose own verification
    field is absent or not an object. The first two need no document at all
    and are checked before read_docs; the last two do, and are checked after.

    Mirrors op_update_field's own shape for a multi-document stream and a
    duplicated id: _selected_slots is walked over EVERY doc, so every
    matching story is updated (mark_stories/assign_field's "every match, not
    the first" semantics), "not found" fires only when no doc has the id at
    all, and the verification-object check runs over every match BEFORE any
    write, so a duplicate id where only one copy lacks a verification object
    still refuses and writes nothing rather than partially updating the
    other.
    """
    path = _flag(argv, "--tasks-file")
    story_id = _flag(argv, "--story-id")
    status = _flag(argv, "--status")
    reason = _flag(argv, "--reason")
    if not path or story_id is None or not status:
        die(
            "Usage: tasks.py set-verification --tasks-file <path> --story-id <id> "
            "--status <passed|failed|skipped> [--reason <text>]"
        )
    if status not in _SET_VERIFICATION_STATUSES:
        die(
            "Error: set-verification: status " + jq_quoted(status)
            + " is not one of: " + ", ".join(_SET_VERIFICATION_STATUSES)
        )
    if status == "skipped":
        if not reason or not reason.strip():
            die("Error: set-verification: --reason is required when status is skipped")
    elif reason:
        die(
            "Error: set-verification: --reason is only accepted when status is "
            "skipped (status: " + status + ")"
        )

    docs = read_docs(path, "set-verification")
    matches = []
    for doc in docs:
        container, selected = _selected_slots(doc, story_id)
        for key in selected:
            matches.append((container, key))
    if not matches:
        die("Error: set-verification: story " + story_id + " not found in " + path)

    for container, key in matches:
        verification = jq_index(container[key], "verification", STORY)
        if not isinstance(verification, dict):
            die(
                "Error: set-verification: story " + story_id + " has no verification "
                "object to update"
            )

    for container, key in matches:
        container[key] = write_verification_verdict(container[key], status, reason)

    write_docs_atomically(path, docs)
    for doc in docs:
        for payload in field_payload(doc, story_id, "verification"):
            _emit(payload)
    return 0


def op_acknowledge_smell(argv):
    """acknowledge-smell: record a reasoned acknowledgement on a
    metadata.smellWarnings entry, matched by storyId + type (never by index).

    Every refusal is decided here, inside the single crossing, in this fixed
    order: --reason missing or blank, then no matching entry. The wrapper has
    already refused a malformed id and agent mode before the lock.

    Every matching entry is acknowledged (a story can carry two entries of one
    type). An entry already acknowledged with the literal true and the same
    sanitized reason is a no-op: nothing is written and the first call's
    acknowledgedAt survives. `acknowledged` is read with `is True`, the same
    literal-only discipline the completed gate applies.
    """
    path = _flag(argv, "--tasks-file")
    story_id = _flag(argv, "--story-id")
    smell_type = _flag(argv, "--type")
    reason = _flag(argv, "--reason")
    if not path or story_id is None or not smell_type:
        die(
            "Usage: tasks.py acknowledge-smell --tasks-file <path> --story-id <id> "
            "--type <smell-type> --reason <text>"
        )
    if not reason or not reason.strip():
        die("Error: acknowledge-smell: --reason is required")
    clean_reason = rm_sanitize(reason, SMELL_ACKNOWLEDGE_REASON_MAXLEN)

    docs = read_docs(path, "acknowledge-smell")
    matches = []
    for doc in docs:
        metadata = doc.get("metadata") if isinstance(doc, dict) else None
        warnings = metadata.get("smellWarnings") if isinstance(metadata, dict) else None
        if not isinstance(warnings, list):
            continue
        for entry in warnings:
            if (
                isinstance(entry, dict)
                and entry.get("storyId") == story_id
                and entry.get("type") == smell_type
            ):
                matches.append(entry)
    if not matches:
        die(
            "Error: acknowledge-smell: no smellWarnings entry for story " + story_id
            + " of type " + smell_type + " in " + path
        )

    changed = False
    for entry in matches:
        if entry.get("acknowledged") is True and entry.get("acknowledgedReason") == clean_reason:
            continue
        entry["acknowledged"] = True
        entry["acknowledgedReason"] = clean_reason
        entry["acknowledgedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        changed = True

    if changed:
        write_docs_atomically(path, docs)
    _emit(matches[0])
    return 0


def _evidence_phase_members(path, docs):
    """The tasks file paths whose completed stories make up THIS file's
    phase: itself, plus the siblings a well-formed `metadata.splitGroup`
    names (resolved by basename in this file's own directory, so a
    traversal-shaped sibling never escapes it), or the counterpart of a
    legacy -frontend-/-backend-tasks.json pair. Mirrors the member discipline
    `roadmap._completed_gate_resolve_members` applies to the same phase, so
    the count recorded here is the count the gate measures against."""
    members = [path]
    directory = os.path.dirname(path) or "."
    first = docs[0] if docs and isinstance(docs[0], dict) else None
    if _completed_gate_has_marker(first):
        for sibling in first["metadata"]["splitGroup"].get("siblings") or []:
            if not isinstance(sibling, str):
                continue
            candidate = os.path.join(directory, os.path.basename(sibling))
            if os.path.isfile(candidate) and candidate not in members:
                members.append(candidate)
        return members
    base = os.path.basename(path)
    for suffix, other in (("-frontend-tasks.json", "-backend-tasks.json"),
                          ("-backend-tasks.json", "-frontend-tasks.json")):
        if base.endswith(suffix):
            candidate = os.path.join(directory, base[: -len(suffix)] + other)
            if os.path.isfile(candidate):
                members.append(candidate)
            break
    return members


def op_acknowledge_evidence(argv):
    """acknowledge-evidence: record, on this tasks file's metadata, that a
    human saw a phase whose completed stories prove nothing discriminating and
    chose to let it close -- `metadata.evidenceAcknowledged = {reason,
    acknowledgedAt, completed}`.

    `completed` is the PHASE-AGGREGATE completed-story count (this file plus
    every split sibling), because that is the number the completed gate
    compares it against; the verb writes only into the one file it is given,
    and the gate honors an acknowledgement found in ANY member. The
    acknowledgement lapses, by the gate's own comparison, the moment that
    count changes.

    Refusals, decided here inside the single crossing: --reason missing or
    blank. The wrapper has already refused agent mode before the lock.
    A repeat call with the same sanitized reason and the same completed count
    is a no-op that leaves the first acknowledgedAt alone; a different reason
    or count replaces the whole record.
    """
    path = _flag(argv, "--tasks-file")
    reason = _flag(argv, "--reason")
    if not path:
        die("Usage: tasks.py acknowledge-evidence --tasks-file <path> --reason <text>")
    if not reason or not reason.strip():
        die("Error: acknowledge-evidence: --reason is required")
    clean_reason = rm_sanitize(reason, EVIDENCE_ACKNOWLEDGE_REASON_MAXLEN)
    if not clean_reason.strip():
        die("Error: acknowledge-evidence: --reason is required")

    docs = read_docs(path, "acknowledge-evidence")
    # The first document's metadata object; one is created when the document
    # has none, a metadata that is some other shape is refused rather than
    # overwritten.
    target = None
    first = docs[0] if docs else None
    if isinstance(first, dict):
        if first.get("metadata") is None:
            first["metadata"] = {}
        if isinstance(first["metadata"], dict):
            target = first["metadata"]
    if target is None:
        die("Error: acknowledge-evidence: no metadata object in " + path)

    completed = 0
    for member in _evidence_phase_members(path, docs):
        if member == path:
            member_docs = docs
        else:
            try:
                member_docs = load_docs(member)
            except (OSError, ValueError):
                continue
        completed += sum(len(_completed_story_ids(doc)) for doc in member_docs)

    existing = target.get("evidenceAcknowledged")
    if (
        isinstance(existing, dict)
        and existing.get("reason") == clean_reason
        and existing.get("completed") == completed
        and not isinstance(existing.get("completed"), bool)
        and isinstance(existing.get("acknowledgedAt"), str)
    ):
        _emit(existing)
        return 0

    record = {
        "reason": clean_reason,
        "acknowledgedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "completed": completed,
    }
    target["evidenceAcknowledged"] = record
    write_docs_atomically(path, docs)
    _emit(record)
    return 0


# skipReason text for judge-verification's "no usable exit" outcome. Two
# literal strings, not one templated by a boolean, because the two name
# different facts: the first says a check was declared and ran somewhere the
# executor's own evidence never reached this document, the second says no
# check was ever declared at all. Module-level constants so op_judge_
# verification and its own pytest coverage read the identical text rather
# than one recomputing what the other already asserts.
JUDGE_VERIFICATION_NO_EVIDENCE_REASON = (
    "implementation.verify was declared but the executor recorded no verify evidence"
)
JUDGE_VERIFICATION_NO_VERIFY_REASON = "no implementation.verify was declared, so no check ran"


def _judge_verification_verdict(story):
    """Decide judge-verification's outcome for one story.

    Returns `(None, reason)` when nothing should be written, and `(status,
    reason)` when a verdict should be written -- `status` is one of "passed",
    "failed" or "skipped", and `reason` is the skipReason text for "skipped"
    and `None` for "passed"/"failed" (write_verification_verdict ignores
    `reason` for every other status, so `None` here is never rendered).

    Checked in this order, each assuming the ones before it already passed:

      1. `verification` is not an object at all -- nothing to judge.
      2. `verification.strategy` is "visual" -- judged by execute.md's own
         visual writers (outline:04), never by this op.
      3. `verification.status` is not the literal "pending" -- already
         judged, by this op or by set-verification, and a second verdict
         here would overwrite a real one with a stale re-derivation.
      4. Otherwise: `.verification.evidence.exit` decides. A usable integer
         gives "passed" (0) or "failed" (anything else); no usable integer
         gives "skipped", with the reason picked by whether
         `story.implementation.verify` is a non-empty string -- the same
         evidence-shape test `_evidence_exit` already applies to the exit
         code, but the story's OWN implementation.verify, not its evidence,
         decides which skipReason applies.
    """
    verification = jq_index(story, "verification", STORY)
    vtype = jq_type(verification)
    if vtype != "object":
        return None, "no verification object declared"
    if jq_equal(jq_index(verification, "strategy", STORY + ".verification"), "visual"):
        return None, (
            "verification.strategy is visual -- judged by execute.md's own visual writers"
        )
    status = _report_status(verification)
    if status != "pending":
        return None, "verification.status is already " + jq_quoted(status) + ", not pending"
    exit_code = _evidence_exit(verification, vtype)
    if exit_code is not None:
        return ("passed" if exit_code == 0 else "failed"), None
    implementation = jq_index(story, "implementation", STORY)
    verify_cmd = jq_index(implementation, "verify", STORY + ".implementation")
    if isinstance(verify_cmd, str) and verify_cmd:
        reason = JUDGE_VERIFICATION_NO_EVIDENCE_REASON
    else:
        reason = JUDGE_VERIFICATION_NO_VERIFY_REASON
    return "skipped", reason


def op_judge_verification(argv):
    """judge-verification: derive a verdict from the verify evidence
    mark-complete already persisted, instead of stamping "passed" blind.

    Replaces execute.md's old blanket rewrite (`elif ... status == "pending":
    update-field ... verification.status passed`), which recorded a passing
    verdict whether or not the story's own check ever ran. This op writes a
    verdict only when there is honest evidence to derive one from -- see
    `_judge_verification_verdict` for the four-way decision.

    Every writing case goes through write_verification_verdict, the SAME
    mutation point op_set_verification above uses, so an evidence-derived
    verdict and an operator-typed one can never disagree about how a verdict
    lands on disk -- only about how it is derived.

    cmd_judge_verification already ran validate_story_exists before the lock
    (cmd_update_field's own shape, not op_set_verification's), so a missing
    id is bash's refusal and this op never dies on "not found" -- it reports
    a `judged: false` no-op instead, the same as every other reason nothing
    was written. The one case that reaches this without a prior bash check is
    the race where the story is removed between that check and this crossing;
    treating it as an ordinary no-op rather than a die() is deliberate,
    because the alternative is a second document read outside the lock.

    Mirrors op_set_verification's "every match, not the first" semantics for
    a duplicated id: each matching slot is judged independently, only the
    slots that get a real verdict are written, and one result object is
    emitted per match -- so a duplicate id where one copy is already judged
    and the other is still pending reports one `judged: true` and one
    `judged: false` line rather than picking one arbitrarily.
    """
    path = _flag(argv, "--tasks-file")
    story_id = _flag(argv, "--story-id")
    if not path or story_id is None:
        die("Usage: tasks.py judge-verification --tasks-file <path> --story-id <id>")

    docs = read_docs(path, "judge-verification")
    matches = []
    for doc in docs:
        container, selected = _selected_slots(doc, story_id)
        for key in selected:
            matches.append((container, key))

    if not matches:
        _emit({"id": story_id, "judged": False, "reason": "story " + story_id + " not found"})
        return 0

    results = []
    changed = False
    for container, key in matches:
        status, reason = _judge_verification_verdict(container[key])
        if status is None:
            results.append({"id": story_id, "judged": False, "reason": reason})
            continue
        container[key] = write_verification_verdict(container[key], status, reason)
        changed = True
        results.append(
            {"id": story_id, "judged": True, "verification": container[key]["verification"]}
        )

    if changed:
        write_docs_atomically(path, docs)
    for result in results:
        _emit(result)
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


# ---------------------------------------------------------------------------
# archive-task -- the one verb here that moves and deletes a user's files
# ---------------------------------------------------------------------------


def _basename(path):
    """basename(1), which strips trailing slashes before taking the last
    component. os.path.basename does not, and bash ran the command."""
    stripped = path.rstrip("/")
    return os.path.basename(stripped) if stripped else path


def joined_document_path(project_root, given):
    """`[ "${p#/}" = "$p" ]` -- a relative path is joined to PROJECT_ROOT, an
    absolute one is taken as it stands.

    Plain concatenation with one "/", exactly as bash wrote it, because this
    string is what `rm` was handed and therefore what `rm`'s own message
    quoted. Normalizing it here would change a diagnostic a user has seen for
    as long as the verb has existed.
    """
    return given if given.startswith("/") else project_root + "/" + given


def require_in_project(project_root, target):
    """validate_path_in_project, ported whole -- message, layout and exit
    status included.

    IT LIVES HERE FOR THE REASON confined_spec_path does. These paths come out
    of metadata.brainstormPath, metadata.researchPaths[] and
    metadata.prototypePaths[], so they exist only after the crossing; sending
    them back to bash to be checked would mean reading the document a second
    time, which is the shape this port exists to remove. The <path> ARGUMENT
    stays bash's: cmd_archive_task still calls validate_path_in_project on it
    before python3 is started at all, so the CLI-supplied path is refused
    without this file ever being reached.

    Three arms, all of them bash's. An existing target resolves through
    realpath, so a symlink pointing out of the tree is caught by its TARGET. A
    missing one resolves through its parent plus the basename. And when the
    parent is missing too, the unresolved string stands -- which means
    "$PROJECT_ROOT/../fora/x" is ACCEPTED as long as ../fora was never
    created, because the string still starts with the root. That last arm is a
    hole, it is reproduced rather than closed, and the corpus pins both sides
    of it: archive-research-traversal is refused and
    archive-research-fora-inexistente is not, over the same path.
    """
    if os.path.exists(target):
        resolved = os.path.realpath(target)
    else:
        parent = os.path.dirname(target)
        resolved = (
            os.path.realpath(parent) + "/" + _basename(target)
            if os.path.exists(parent)
            else target
        )
    if resolved == project_root or resolved.startswith(project_root + "/"):
        return
    sys.stderr.write("Error: Path escapes project root — access denied\n")
    sys.stderr.write("  Path:         " + resolved + "\n")
    sys.stderr.write("  Project root: " + project_root + "\n")
    sys.exit(1)


def archive_move(archive_dir, src):
    """bash's nested _archive_move: the destination, the -N suffix, and mv.

    `${basename%%.*}` splits on the FIRST dot, so the extension a collision
    keeps is everything from that dot onward. corpus.v2-tasks.json becomes
    corpus-2.v2-tasks.json rather than corpus.v2-tasks-2.json, and a companion
    x.json.lock keeps ".json.lock". Reproduced rather than tidied: the archive
    directory is a place people browse, and changing the rule would rename the
    NEXT collision beside files already named the old way.

    The lock's suffix is computed by a separate call to this function, so a
    task that lands on -2 and a lock that finds its own slot free are only
    paired by coincidence. That is bash's arithmetic too, and
    archive-colisao-com-lock records where it happens to agree.
    """
    name = _basename(src)
    dest = os.path.join(archive_dir, name)
    if not os.path.exists(dest):
        return _move(src, dest)
    stem = name.split(".", 1)[0]
    ext = name[len(stem):]
    number = 2
    while True:
        dest = os.path.join(archive_dir, stem + "-" + str(number) + ext)
        if not os.path.exists(dest):
            return _move(src, dest)
        number += 1


def _move(src, dest):
    """`mv`. shutil.move because mv crosses filesystems and os.rename does not
    -- a brainstorm can live anywhere under the project root. dest is known
    not to exist, so shutil's move-INTO-a-directory special case is
    unreachable."""
    try:
        shutil.move(src, dest)
    except OSError as err:
        die("mv: cannot move '" + src + "' to '" + dest + "': " + _reason(err))
    return dest


def _rm_f(path):
    """`rm -f`, and DELIBERATELY not one step further.

    os.unlink and nothing else: no shutil.rmtree, no os.removedirs, no
    recursion of any kind. A directory named in researchPaths ends the run
    here the way `rm -f` ended it -- GNU rm's own line, rebuilt from the errno
    so the wording a user has seen does not move under them -- with the task
    file already in the archive and the directory untouched.

    Turning a non-recursive delete into a recursive one while nobody was
    looking is the worst outcome this port could have. The guard is that this
    function is four lines long and every delete in the file goes through it.
    """
    try:
        os.unlink(path)
    except OSError as err:
        die("rm: cannot remove '" + path + "': " + _reason(err))


def _reason(err):
    return os.strerror(err.errno) if err.errno else str(err)


def _metadata(doc):
    metadata = doc.get("metadata") if isinstance(doc, dict) else None
    return metadata if isinstance(metadata, dict) else {}


def document_path_lines(docs, key):
    """`jq -r '.metadata.<key>[]? // empty'`, as bash's `read -r` loop saw it.

    Three properties come from the pipeline rather than from the values, and
    all three are observable. `[]?` swallows a field that is not an array, so
    a researchPaths holding a string yields no paths instead of an error
    (archive-research-nao-lista). `// empty` drops null and false. And the
    loop read LINES, so a value carrying a newline arrives as two paths and an
    empty one is skipped by the loop's own `[ -z ] && continue`.
    """
    lines = []
    for doc in docs:
        values = _metadata(doc).get(key)
        if not isinstance(values, list):
            continue
        for value in values:
            if value is None or value is False:
                continue
            lines.extend(jq_raw(value).split("\n"))
    return [line for line in lines if line]


def document_scalar(docs, key):
    """`jq -r '.metadata.<key> // empty'` over the whole stream -- one line per
    document, joined, which is the single string bash's `$(...)` captured."""
    lines = []
    for doc in docs:
        value = _metadata(doc).get(key)
        if value is None or value is False:
            continue
        lines.append(jq_raw(value))
    return "\n".join(lines)


def op_archive_task(argv):
    """Move the task file (and its lock, and its brainstorm) to .aimi/archive/,
    delete the research and prototype files it names, and say what happened.

    ONE CROSSING, AND NO LOCK -- because cmd_archive_task never took one. THE
    LOCK IS MOVED RATHER THAN HELD, and that is preserved here on purpose
    rather than inherited by accident. `<tasks>.lock` is relocated into the
    archive directory alongside the document; a writer that is holding flock
    on that inode keeps holding it while a writer arriving a moment later
    opens `<tasks>.lock` at the ORIGINAL path, creates it fresh, and acquires
    an uncontended lock on a different inode. The two then have no mutual
    exclusion at all. The fix is deliberately out of scope for this slice:
    everything this port is worth rests on demonstrating that the one verb
    that deletes files changed nothing, and folding a concurrency fix into the
    same diff would destroy that proof exactly where it matters most. It is
    deferred to its own labelled behaviour-change commit, whose bar is a test
    that fails against the behaviour recorded in archive-lock-acompanha.

    The order is bash's and every step of it is observable: refuse a
    non-terminal document, make the archive directory, move the task, move the
    lock, move the brainstorm, delete the research paths, delete the prototype
    paths, print. Everything after the first move happens with the document
    already gone from .aimi/tasks/, which is why an escaping researchPath
    refuses with a side effect already committed -- recorded, not hidden, in
    the corpus `tree` of every escape case.

    The lock move is guarded by `[ -f ]`, so a companion lock that is a
    DIRECTORY is left where it is rather than moved -- archive-lock-e-diretorio
    ends with the document archived and the directory still in .aimi/tasks/.
    (That sentence lives here rather than beside the code because
    test_tasks_py_takes_no_lock_of_its_own scans the executable text for a lock
    and cannot tell an explanation from an implementation.)
    """
    path = _flag(argv, "--tasks-file")
    project_root = _flag(argv, "--project-root")
    archive_dir = _flag(argv, "--archive-dir")
    if not path or not project_root or not archive_dir:
        die(
            "Usage: tasks.py archive-task --tasks-file <path> "
            "--project-root <path> --archive-dir <path>"
        )

    docs = read_docs(path, "archive-task")
    counts = [
        len(
            [
                story
                for story in _stories(doc)
                if jq_index(story, "status", ".userStories[]") not in ("completed", "skipped")
            ]
        )
        for doc in docs
    ]
    # bash tested ONE string holding jq's whole output -- one count per
    # document -- so both arms below are string arms rather than numeric ones.
    # An empty tasks file yields no counts and is refused (for having
    # non-terminal stories, which is the wrong sentence for the input and is
    # the behaviour: archive-arquivo-vazio). A stream of two or more documents
    # yields a value `[ ... -ne 0 ]` cannot compare; it reported "integer
    # expression expected", returned 2, and an `if` read that as false, so the
    # archive went ahead whatever the later documents said. Reproduced with a
    # branch rather than an error, and pinned by
    # archive-dois-documentos-um-aberto, which archives an in_progress story.
    if not counts or (len(counts) == 1 and counts[0] != 0):
        sys.stderr.write("Error: Task file has non-terminal stories — cannot archive\n")
        return 1

    os.makedirs(archive_dir, exist_ok=True)
    archived_task = archive_move(archive_dir, path)
    lock = path + ".lock"
    if os.path.isfile(lock):
        archive_move(archive_dir, lock)

    archived_brainstorm = ""
    brainstorm = document_scalar(docs, "brainstormPath")
    if brainstorm:
        target = joined_document_path(project_root, brainstorm)
        # CONFINED ONLY WHEN IT EXISTS, and that asymmetry against the two
        # loops below is bash's own call-site ordering rather than an
        # oversight of this port: an escaping brainstormPath naming nothing is
        # skipped in silence (archive-brainstorm-fora-inexistente) where an
        # escaping researchPath is refused before anyone asks whether it is
        # there.
        if os.path.exists(target):
            require_in_project(project_root, target)
            archived_brainstorm = archive_move(archive_dir, target)

    cleaned = {}
    for key in ("researchPaths", "prototypePaths"):
        count = 0
        for given in document_path_lines(docs, key):
            target = joined_document_path(project_root, given)
            # CONFINED BEFORE THE EXISTENCE CHECK, so a path that escapes is
            # refused whether or not it is there.
            require_in_project(project_root, target)
            if os.path.exists(target):
                _rm_f(target)
                count += 1
        cleaned[key] = count

    _emit(
        {
            "archived": {
                "task": archived_task,
                "brainstorm": archived_brainstorm or None,
                "researchCleaned": cleaned["researchPaths"],
                "prototypeCleaned": cleaned["prototypePaths"],
            }
        }
    )
    return 0


# ---------------------------------------------------------------------------
# The four readers the 1.123.0 port left standing
#
# init-session's three metadata reads, get-branch's fallback, research-gc's
# walk over every tasks file, and the predicate behind list-archivable. The
# last two were named in no prior decision at all; the first two were left
# because init-session's neighbourhood also holds the ONE thing that must never
# cross -- see cmd_init_session in aimi-cli.sh, and the module docstring above.
# ---------------------------------------------------------------------------


def document_line(docs, *segments):
    """`jq -r '.a.b'` over the whole STREAM -- one line per document, joined,
    which is the single string bash's `$(...)` captured.

    NOT document_scalar, which archive-task uses and which carries `// empty`.
    Neither read below was written with it, and the difference is visible: `jq
    -r` prints the four-letter word `null` for an absent branchName, bash
    stored the word, and the charset gate then ACCEPTED it as a legal branch
    name. Borrowing a helper that maps null to "" would repair that on the way
    past -- see _comment_session_doc (1), where it is recorded rather than
    fixed, from four different documents that reach it.
    """
    lines = []
    for doc in docs:
        value, owner = doc, ""
        for segment in segments:
            value = jq_index(value, segment, owner)
            owner = owner + "." + segment
        lines.append(jq_raw(value))
    return "\n".join(lines)


def op_init_session(argv):
    """The THREE DOCUMENT READS of cmd_init_session, and the gate between them.

    WHAT IS NOT HERE IS THE POINT. cmd_init_session also resolves its OWN
    script path and persists it, as session state and in the global cache
    every later $AIMI_CLI resolution reads. Inside this file `$0` is tasks.py,
    so porting that would persist a Python module's path and the next session
    would load a .py as a shell script -- long after the test run that passed.
    It stays in bash permanently. The seam is marked there, and the module
    docstring above names the key and the function in the one place a scan for
    them is allowed to find them: test_tasks_py_never_names_the_cli_path_cache
    reads every line below it.

    THE CHARSET GATE CROSSED WITH THE READS, and it had to. bash tested the
    value it got back from jq, and for a non-string branchName that value is
    whatever `jq -r` PRINTED -- an array comes out over four lines and the
    refusal quotes all four, indentation included. One crossing cannot hand a
    multi-line value back to a shell variable and still emit its own JSON in
    the same stream, so the gate went where the raw value already is. Regex,
    message and exit status are bash's to the byte, and it fires exactly where
    bash fired it: after the branchName read, before the other two reads, and
    before bash writes .aimi/current-branch. That ordering is not a claim --
    session_doc_cases records the whole of .aimi/ after every run, and every
    refused case has the two writes above the seam already done and no
    current-branch file at all.

    What the gate guarantees on the way out is what lets bash have the value at
    all: a branch that passes matches ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$, so it holds
    no newline, no quote and no brace. It is emitted as the first line and the
    session object follows; bash splits on that first newline and cannot be
    fooled, because a value that could hide a newline never gets here.
    """
    path = _flag(argv, "--tasks-file")
    if not path:
        die("Usage: tasks.py init-session --tasks-file <path>")
    docs = read_docs(path, "init-session")

    branch = document_line(docs, "metadata", "branchName")
    if not BRANCH_NAME.fullmatch(branch):
        # bash's own line, to the byte, on stderr at exit 1.
        sys.stderr.write("Error: Invalid branch name: " + branch + "\n")
        return 1

    # EXACTLY ONE DOCUMENT IS LEFT HERE, and the gate is what proves it: zero
    # documents join to "" and one alphanumeric is required, two or more join
    # with a newline the charset cannot hold. So the counts below need no
    # stream arm -- unlike archive-task's, which has no gate in front of it and
    # records what `[` did when handed two numbers.
    pending = count_with_status(_stories(docs[0]), "pending")
    version = document_line(docs, "schemaVersion")

    sys.stdout.write(branch + "\n")
    _emit({"tasks": path, "branch": branch, "pending": pending, "schemaVersion": version})
    return 0


def op_get_branch(argv):
    """cmd_get_branch's FALLBACK, which is all that ever read the document.

    The `read_state "current-branch"` fast path stays in bash and still returns
    without opening anything: gb-estado-presente-sem-documento answers from
    state with no tasks file on disk at all.

    No gate here, deliberately -- cmd_get_branch never had one, and
    gb-branch-hostil records it echoing a name init-session refuses.
    """
    path = _flag(argv, "--tasks-file")
    if not path:
        die("Usage: tasks.py get-branch --tasks-file <path>")
    docs = read_docs(path, "get-branch")
    sys.stdout.write(document_line(docs, "metadata", "branchName") + "\n")
    return 0


def op_archivable_file_is_terminal(argv):
    """`_archivable_file_is_terminal`, the predicate behind list-archivable.

    NOT a verb -- the second op here named after the bash FUNCTION it replaces,
    for validate-story-exists' reason: `grep _archivable_file_is_terminal` has
    to find both ends of it.

    THE NON-EMPTY CLAUSE IS ITS OWN, AND MUST STAY ITS OWN. This rule and
    op_archive_task's disagree: a document whose userStories is [] is REFUSED
    here and ARCHIVED there, because archive-task's inline copy never had the
    total-count test. That disagreement predates every port -- archive_cases
    pins the archiving side with archive-userstories-vazio and
    _comment_archive (4) names it, session_doc_cases pins the refusing side
    with la-zero-historias -- and it is preserved, not reconciled. The two
    predicates therefore share no helper: factoring the common half out is the
    one edit that would quietly make them agree. Reconciling them, in either
    direction, is a separate commit with its own tests and its own changelog
    line.

    RETURN-CODE-ONLY, and the answer is a word rather than an exit status
    because die() already owns 1. `true` or `false` on stdout, exit 0; bash
    compares the word and treats anything else -- including this file refusing
    a document it cannot read -- as false.
    """
    path = _flag(argv, "--tasks-file")
    if not path:
        die("Usage: tasks.py archivable-file-is-terminal --tasks-file <path>")
    docs = read_docs(path, "archivable-file-is-terminal")

    # `[.userStories[] | select(.status != "completed" and .status != "skipped")] | length`,
    # once per document, exactly as jq printed it.
    counts = [
        len(
            [
                story
                for story in _stories(doc)
                if jq_index(story, "status", ".userStories[]") not in ("completed", "skipped")
            ]
        )
        for doc in docs
    ]
    # bash tested ONE string holding jq's whole output, so both arms are string
    # arms. No output at all -- an empty tasks file -- is `[ -z ]` and refuses.
    # Two or more documents produce a value `[ ... -ne 0 ]` cannot compare: it
    # said "integer expression expected", returned 2, and the `&&` never fired,
    # so the test was simply SKIPPED. la-dois-documentos records a file
    # reported archivable although its second document holds a pending story.
    if not counts:
        return _archivable_verdict(False)
    if len(counts) == 1 and counts[0] != 0:
        return _archivable_verdict(False)

    # `.userStories | length`, the clause op_archive_task does not have.
    totals = [jq_length(jq_index(doc, "userStories"), ".userStories") for doc in docs]
    if not totals:
        return _archivable_verdict(False)
    if len(totals) == 1 and totals[0] == 0:
        return _archivable_verdict(False)
    return _archivable_verdict(True)


def _archivable_verdict(value):
    sys.stdout.write("true\n" if value else "false\n")
    return 0


def research_path_lines(paths):
    """`for f in .aimi/tasks/*.json; do jq -r '.metadata.researchPaths[]? // empty' "$f"; done`,
    as the `while read` loop that consumed it saw the bytes.

    THE PATHS ARRIVE ALREADY GLOBBED, by the shell, in the shell's own order.
    That is not laziness: which file is read FIRST decides what survives an
    abort, and a glob re-run here would sort by code point where bash sorted by
    the caller's collation.

    IT STOPS, IT DOES NOT SKIP, and that is the whole reason this reads a
    stream. The loop ran under `set -euo pipefail` inside a process
    substitution, so the FIRST jq that aborted ended the entire loop -- every
    later tasks file contributed nothing, and the research those files name was
    then collected as orphaned. rgc-malformado-antes-de-um-bom deletes a live
    research file for the syntax error in an unrelated document;
    rgc-malformado-depois-de-um-bom is the same two files in the other order
    and keeps it. Recorded and reproduced, not repaired: this commit is the one
    that has to prove it changed nothing, and a fix here would be invisible
    inside it.

    Three properties come from the pipeline rather than from the values. `[]?`
    swallows a researchPaths that cannot be iterated, so a string or a null
    yields nothing instead of aborting -- but the `.metadata` index in front of
    it is NOT guarded, so a metadata that is a string aborts the whole walk.
    `// empty` drops null and false and nothing else. And `jq -r` pretty-prints
    every non-string, so an object or an array becomes several lines, each one
    read as a path; rgc-entrada-objeto names a live file inside an object and
    deletes it anyway.
    """
    lines = []
    for path in paths:
        if not os.path.isfile(path):
            continue  # `[ -f "$f" ] || continue`, and the unmatched glob itself
        try:
            for doc in streamed_docs(path):
                values = jq_index(jq_index(doc, "metadata"), "researchPaths", ".metadata")
                try:
                    items = jq_iterate(values, ".metadata.researchPaths")
                except MalformedTasks:
                    continue  # `[]?`
                for value in items:
                    if value is None or value is False:
                        continue  # `// empty`
                    lines.extend(jq_raw(value).split("\n"))
        except (OSError, UnicodeDecodeError, ValueError, MalformedTasks):
            return lines
    return lines


def op_research_paths(argv):
    """One crossing for the whole `.aimi/tasks` directory, where there was one
    jq per file. Every path bash's glob produced is an argument.

    Prints one line per path, empty lines included: the read loop skipped them
    with its own `[ -z ]` and an entry carrying a newline arrived as two paths,
    so the byte stream is the contract rather than the list.
    """
    for line in research_path_lines(argv):
        sys.stdout.write(line + "\n")
    return 0


# ---------------------------------------------------------------------------
# verify-probe -- vacuity at the ASSERTION level, not at the script's
# ---------------------------------------------------------------------------
#
# The story-executor already runs a story's implementation.verify once before
# implementing anything, and warns when that pre-run exits ZERO: a check that
# passes before the work proves nothing about the work. That warning is at the
# granularity of the SCRIPT. Under `set -e` a verify stops at its first failing
# assertion, so every assertion after it never ran at all, and one that would
# have passed vacuously is invisible. The case this was built from had four
# assertions of which two already passed -- one a guardrail by design, one dead
# weight -- and the script still exited non-zero on the second, so the
# script-level pre-run would have said nothing.
#
# This verb answers the other question: which INDIVIDUAL assertions already
# pass. It decomposes the verify, runs each piece on its own, and reports the
# exit status of each. `discriminates` is false for exactly the pieces that
# already pass -- the ones a reader should look at.
#
# ONE MEASUREMENT IS NOT ENOUGH, EITHER. `discriminates` computed from a
# single run cannot tell "the work is not done yet" from "this assertion can
# never pass" -- a segment that is non-zero here is non-zero for either
# reason, and the story that motivated this verb spent three fifteen-minute
# suite runs re-testing a check of the second kind because nothing told them
# apart. The fix is not to guess from the segment's TEXT -- it is to use the
# second measurement the story-executor already takes: it runs the verify
# once before implementing anything and once after. `--previous-file` accepts
# the FIRST run's own JSON array (this verb's own prior output, written
# somewhere the caller can hand back), and a segment whose exit is non-zero
# in BOTH the recorded previous run and this one is named `unsatisfiable` --
# possibly a broken harness rather than unfinished work, with a `note`
# pointing at that. Without `--previous-file`, or with a segment the file
# does not mention, `unsatisfiable` is `false`: failing once is exactly what
# unfinished work looks like, and only two failures in a row rules it out.
# `discriminates` itself is unchanged by any of this -- see _match_previous.

# The keywords that open and close a compound command. While one is open no
# separator inside it splits, so an `if ... ; then ... ; fi` stays ONE segment
# and runs as the unit its author wrote. Splitting it would hand bash the
# fragment `if cmd; then`, which is a syntax error -- reported as exit 2, so it
# could never be mistaken for dead weight, but noise all the same.
_VERIFY_OPENERS = ("if", "for", "while", "until", "case", "select")
_VERIFY_CLOSERS = ("fi", "done", "esac")

# `NAME=`, `NAME[i]=` and `NAME+=`, anchored: what makes a word an assignment
# rather than a command.
_VERIFY_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=")

# The words that may precede an assignment and still leave it an assignment.
_VERIFY_DECLARATORS = ("export", "local", "declare", "readonly", "typeset")

# A NAME as `$NAME` and `${NAME}` spell it, matched from a position rather than
# anchored, so it can be run against the character after a `$`.
_VERIFY_NAME_AT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")

# The same NAME as a whole word, tolerating the `;` a word carries when the
# scanner cut on blanks alone -- `for f in a; do` yields the word `f`, but
# `while read -r line; do` yields `line;`.
_VERIFY_BOUND_NAME = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*);?$")

# The builtins whose whole job is to MOVE the shell. Only `cd` appears in the
# corpus this parser was cut against -- 11 of the 258 verifies under this
# plugin's own .aimi/ carry one and none carries a pushd, measured 2026-09-04 --
# and the dirstack pair is listed anyway, because unlike the parser's other
# rules this one is not descriptive. A word missing from here is a directory
# change the probe fails to replicate, and that failure is silent and lands in
# the caller's tree. Two strings buy the whole family.
_VERIFY_CHDIR = ("cd", "pushd", "popd")

# A verify is allowed to be a whole test suite, so this default is generous.
# It is what `probe_verify` applies when its caller names no `timeout`, and it
# is PER SEGMENT rather than over the whole probe.
#
# THE VERDICT A TIMEOUT GETS WAS REVERSED, AND THE OLD REASONING IS KEPT HERE
# RATHER THAN DELETED, BECAUSE IT WAS SOUND WHEN IT WAS WRITTEN. It said: a
# segment that outlives this is reported at 124 -- `timeout`'s own status --
# which reads as discriminating, the safe direction, since a probe must never
# invent dead weight. That was the best answer AVAILABLE while `discriminates`
# had two values: between `true` and `false`, only `false` tells a reader to
# stop looking, so `true` was the wrong answer that costs least. US-001 added
# the third value, and a third option does not merely widen the choice here --
# it changes which answer is best. A TIMEOUT MEASURED NOTHING, so `None` is
# both honest and safe at once, and safe-but-wrong is no longer the best on
# offer. A timed-out segment now carries `discriminates: None` and `exit:
# None`, the same shape as a segment whose shell state the prelude never
# reproduced, for the same reason: neither of them ran.
#
# WHICH CEILING ACTUALLY BIT -- measured 2026-09-07, because the record that
# asked for this fix and this constant disagreed, and the two imply different
# fixes. `.aimi/known-gaps/2026-09-03-US-004-verify-probe-cost.md` says eight
# stories blew a FIVE-minute ceiling; this constant is 600 seconds. The
# five-minute one is not this constant, and it is not the plugin's either --
# there is no 300-second ceiling anywhere under `scripts/`, `hooks/`,
# `commands/` or `skills/`. It is the HARNESS's wall clock around the whole
# verb, and since this ceiling is per segment the two never meet: what blew
# was the SUM of the segments while every individual one finished. This
# plugin's own recorded probe output says so directly -- every suite segment
# in `.aimi/tasks/verify-probe-US-00{1,2}.json` carries `exit: 0`, so each RAN
# TO COMPLETION under this ceiling. Timed on this tree:
# `test-command-blocks.sh` 4s, `test-command-size.sh` 1s,
# `pytest scripts/tests/` 435s, `test-aimi-cli.sh` 292s -- every one
# of them under 600 and the last two each a large share of five minutes on
# their own. The single `exit: 124` in the corpus
# (`verify-probe-US-003.json`) is this ceiling firing on an ACCIDENT rather
# than on a suite: a bare `import` line cut out of a Python heredoc, which
# bash resolved to ImageMagick's blocking screen-capture `import`.
#
# WHAT THAT MEASUREMENT DECIDED: lowering this number would not have helped,
# which is why it did not move. A per-segment cap cannot bound a sum of
# segments none of which reaches it. What bounds the sum is running fewer of
# them -- `skip_matching` -- and a cap the CALLER picks for its own budget,
# which is why `timeout` became a parameter while this default stayed 600.
_VERIFY_TIMEOUT = 600

# The name of the environment variable that says "a verify-probe is already
# running underneath you". `probe_verify` sets it before it runs a single
# segment; `op_verify_probe` refuses when it is already there.
#
# THE ENVIRONMENT IS THE CHANNEL BECAUSE THE SUBPROCESS BOUNDARY IS THE PROBLEM.
# `verify-probe <id>` RUNS that story's verify segments, so a verify that names
# the verb re-enters it -- measured on a throwaway fixture at 127 re-entries in
# 25 seconds before the outer call hit its own ceiling at 124. Every re-entry
# crosses a `subprocess.run`, and the environment is the only state that
# crosses with it: an in-process flag would be reset by the fresh interpreter
# each segment starts.
#
# A NAME, NOT AN ID, AND THAT IS THE WHOLE DESIGN. Comparing the requested
# story id against the running one closes self-reference and nothing else, and
# the record this fix answers --
# `.aimi/known-gaps/2026-09-07-plan-141-verify-probe-nao-pode-apontar-para-si.md`
# -- names the MUTUAL case in the same breath: story A's verify probes B, whose
# verify probes A. Two ids, neither equal to the other, and the loop is
# identical. A marker that says only "some probe is running" catches both,
# because both are the same fact.
VERIFY_PROBE_ACTIVE_ENV = "AIMI_VERIFY_PROBE_ACTIVE"

# What the refusal says. A message that reported only "failed" would send the
# reader looking for a broken assertion, when what happened is that the verify
# being probed names the probe -- so it names the recursion, and it names the
# two ways out rather than leaving the reader to find them.
_VERIFY_PROBE_REENTRY = (
    "Error: verify-probe: refusing to run inside another verify-probe.\n"
    "  " + VERIFY_PROBE_ACTIVE_ENV + " is already set, which means the verify "
    "being probed calls this verb back -- directly, or through a second story "
    "whose own verify probes the first. Running the segments again would "
    "recurse instead of answering.\n"
    "  Two ways out: probe from a verify that does not itself call "
    "verify-probe (a sibling story's, or a throwaway fixture's), or call "
    "probe_verify() in tasks.py directly, which is not guarded."
)

# probe-plan's refusal is the same sentence with the verb's own name, so the
# two exits are stated once (above) and cannot drift apart.
_PROBE_PLAN_REENTRY = _VERIFY_PROBE_REENTRY.replace(
    "verify-probe: refusing to run inside another verify-probe",
    "probe-plan: refusing to run inside another probe",
    1,
)

# What probe-plan does with a segment that passes at baseRef and is not marked
# as a guard rail. "report" lists it; "refuse" is the only other valid value.
# A later outline entry decides the final value; callers read it from the
# `policy` key of the probed:true payload and never parse prose for it.
PROBE_PLAN_NONDISCRIMINATING_POLICY = "report"

# Segments probe-plan does not run unless --run-suites is given: a pytest run
# naming neither `-k` nor a `::` node selector, and any test-*.sh suite
# script. probe_verify tests it only against segments that survived its own
# `||`, `cd` and assignment branches, so it can never drop a context segment.
_PROBE_PLAN_SUITE_PATTERN = (
    r"(?s)(?:^(?!.*(?:\s-k\s|::)).*\bpytest\b|\btest-[A-Za-z0-9_.-]+\.sh\b)"
)

# What the refusal says when `implementation.verify` is PRESENT and is not a
# string. Same shape as the constant above and for the same reason: the
# message is the only place that states the whole problem, so it names the
# type it found, says why there is no honest reading of it, and names the two
# ways out.
#
# WHY THIS REFUSES RATHER THAN JOINING THE LINES. The 2026-09-07 census over
# every tasks document in `.aimi/` found 292 non-empty verifies and exactly
# two written as a list -- and the two are not the same kind of list. One is a
# list of COMMANDS; the other is a list of checks in PROSE ("Hand-trace three
# scenarios through the rewritten condition..."). Joining with newlines would
# hand those sentences to bash, bash would reject them, and the probe would
# report `discriminates: true` -- a confident verdict about something that was
# never a script. Nothing in the document tells the two lists apart, so the
# probe cannot choose between them, and of the three answers available --
# silence, a guess, a refusal -- only the refusal is honest.
_VERIFY_PROBE_NOT_A_STRING = (
    "Error: verify-probe: implementation.verify is %s, not a string.\n"
    "  A verify is the script this verb takes apart, and only a string is a "
    "script. Reading this value as one would mean guessing: joining a list of "
    "lines hands prose to bash as though it were commands, and the empty "
    "array reports silence as a clean bill of health.\n"
    "  Two ways out: make implementation.verify a single string -- joining "
    "the lines yourself when they really are a script -- or remove the field "
    "when there is no command to run, which still probes to the empty array, "
    "on purpose."
)


def _verify_probe_type_name(value):
    """What the refusal above calls the value it found.

    Four names, because four shapes reach it: a string is the shape the field
    is for, and a `verify` that is JSON null is indistinguishable from an
    absent one once `jq_index` has run, so null is never refused either.

    Neither `jq_type` nor roadmap.py's `_json_type` is used here, and they
    spell the first of the four `array` and `an array`. Nothing compares this
    string -- it is prose inside a refusal, not a value inside a rule -- and
    `a list` is the word the sentence beside it already uses.
    """
    if isinstance(value, bool):
        return "a boolean"
    if isinstance(value, (int, float)):
        return "a number"
    if isinstance(value, list):
        return "a list"
    return "an object"


def _verify_at_word_start(buf):
    """True when the next character begins a WORD rather than continuing one.

    Reads backwards over blanks in what has been accumulated so far. It is what
    tells `{` the group opener from the `{` of `${VAR}`, `#` the comment from
    the `#` of `${x#y}`, and the keyword `if` from the tail of `notif`.
    """
    i = len(buf) - 1
    while i >= 0 and buf[i] in " \t":
        i -= 1
    return i < 0 or buf[i] in ";&|(){}\n<>"


def _verify_heredoc_opener(text, i):
    """The `<<WORD` / `<<-WORD` starting at `i`, as `(delimiter, strip_tabs,
    quoted, end)`, or None when what is there is not a heredoc redirect at all.

    Only the SHAPE is decided here: `<<`, an optional `-`, optional blanks and
    then a word, whose quotes are removed the way bash removes them -- `<<'X'`,
    `<<"X"` and `<<\\X` all name the delimiter `X`.

    `quoted` IS REPORTED because this is the only place that can report it.
    Quote removal destroys the evidence: after it, `<<'X'` and `<<X` are the
    same three characters, and yet the first suppresses every expansion in the
    body and the second performs them. verify_segments does not care -- a body
    stays inside its segment either way -- but verify_reads does, so the fact
    is carried out of here rather than re-derived by a second parse that would
    have to repeat this word scan to find where the quotes were.

    Whether the position even admits a redirect -- not inside quotes, not
    inside `$(( ))` where `<<` is a left shift -- is still the caller's to
    know, because the caller is the only thing that tracks it.
    """
    n = len(text)
    j = i + 2
    strip_tabs = False
    quoted = False
    if j < n and text[j] == "-":
        strip_tabs = True
        j += 1
    while j < n and text[j] in " \t":
        j += 1
    delimiter = []
    while j < n:
        ch = text[j]
        if ch in " \t\n;&|<>()":
            break
        if ch in ("'", '"'):
            close = text.find(ch, j + 1)
            if close == -1:
                return None
            # ANY quoting anywhere in the word suppresses the body's
            # expansions -- `<<F'I'M` as much as `<<'FIM'` -- which is why this
            # is a flag raised by the scan rather than a look at text[i + 2].
            quoted = True
            delimiter.append(text[j + 1 : close])
            j = close + 1
            continue
        if ch == "\\" and j + 1 < n:
            quoted = True
            delimiter.append(text[j + 1])
            j += 2
            continue
        delimiter.append(ch)
        j += 1
    word = "".join(delimiter)
    if not word:
        return None
    return word, strip_tabs, quoted, j


def _verify_take_heredoc_bodies(text, i, heredocs, buf):
    """Every pending heredoc body from `i`, appended to `buf` verbatim, and the
    index just past the last terminator consumed.

    IN ORDER, because `cmd <<A <<B` reads A's body first and then B's. Each one
    ends at a line equal to its own delimiter -- with leading TABS, and never
    spaces, stripped first for the `<<-` form, which is the one detail that
    fails loudly rather than quietly when it is wrong: a terminator that never
    matches swallows the rest of the script. An unterminated heredoc takes
    everything that is left, which is what bash does with one too.
    """
    n = len(text)
    while heredocs:
        delimiter, strip_tabs = heredocs.pop(0)
        while i < n:
            end = text.find("\n", i)
            stop = n if end == -1 else end + 1
            line = text[i:stop]
            buf.append(line)
            i = stop
            candidate = line[:-1] if line.endswith("\n") else line
            if strip_tabs:
                candidate = candidate.lstrip("\t")
            if candidate == delimiter:
                break
    return i


def verify_segments(text):
    """A verify script cut into its top-level segments, each paired with the
    separator that INTRODUCED it -- "" for the first and for anything after a
    `;` or a newline, "&&", or "||".

    Cuts on `;`, `&&`, `||` and newline, and on nothing else -- a pipeline is
    ONE command and `|` never splits. A separator inside single quotes, double
    quotes, a `$(...)` or backtick substitution, a `{ ...; }` group, a `(...)`
    subshell or a compound command is not a separator at all. Comments are
    dropped whole, so a `#` line never becomes a segment that trivially passes.

    A HEREDOC IS THE ONE SHAPE WHOSE CONTENT IS NOT SHELL AT ALL, and it is
    tracked here beside those quoting states rather than left to them. `cmd
    <<DELIM` -- in every form bash accepts, `<<'X'`, `<<"X"`, `<<X` and the
    tab-stripping `<<-X` -- keeps every line up to and INCLUDING its terminator
    inside the segment that opened it, and the terminator is never a segment of
    its own. The body is Python, or SQL, or a patch, and each newline and `;`
    in it would otherwise cut it into fragments handed to a shell as if they
    were commands. That is not a cosmetic miscount: `_VERIFY_TIMEOUT`'s note
    records where it already led -- a bare `import` line cut out of a Python
    heredoc, which bash resolved to ImageMagick's blocking screen-capture
    `import`. The `<<` of an arithmetic `$(( a << b ))` is a left shift and is
    deliberately NOT one, which is the single position this scanner has to
    tell apart, and the only reason it tracks arithmetic at all.

    THE SEPARATOR IS CARRIED because `||` means something the other three do
    not: what follows it is the failure branch of the segment before it, which
    is why probe_verify neither runs nor reports one. See its docstring.

    IT IS A SCANNER, NOT AN EVALUATOR. Nothing here is expanded and nothing is
    handed to `eval` to be split; the quoting state is tracked character by
    character, which is the only way a separator inside a quoted string can be
    told from one between two commands without running the string first.

    A STATE LEFT UNTERMINATED AT END-OF-TEXT -- an unbalanced `'`, `"`,
    backtick, `(`, `{` or compound (`if`/`for`/`while`/`case`/...) -- makes
    `top` false for the REST of the text, so every `;`, newline, `&&` and
    `||` after the point it opened is absorbed into the text still being
    scanned rather than treated as a separator. This function still returns
    whatever that fuses into, unchanged, because it answers "what are the
    segments" and a fused blob is still segments; `verify_unterminated`
    below answers the other question -- was this text a well-formed script at
    all -- and `_probe_verify_segments` is the caller that acts on it.
    """
    return _verify_scan(text)[0]


def _verify_scan(text):
    """The body `verify_segments` used to be, returning `(segments, residual)`
    instead of `segments` alone. `residual` is the name of whichever quoting
    or grouping state is still open when the scan reaches end-of-text, or
    `None` when the text closed everything it opened -- see
    `verify_unterminated`, the public wrapper around the second half of this
    pair.

    DEFINED AFTER `verify_segments` ON PURPOSE, not before it despite being
    the callee: `test_nothing_in_the_decomposition_reaches_eval` slices the
    module's source between the `verify_segments` definition and the
    `op_verify_probe` one (found by searching for each one's own `"def "`
    prefix) and asserts no `eval` appears in that slice. Hoisting this
    function above `verify_segments` would move the scanner body out of the
    slice the guard reads, shrinking its coverage to nothing while leaving
    the guard itself green. Keeping the leading-underscore helper below its
    public wrapper is the file's exception to its own habit of defining
    helpers first, and it exists for that one reason.
    """
    segments = []
    buf = []
    pending = [""]
    quote = None
    backtick = False
    parens = 0
    braces = 0
    keywords = 0
    # Delimiters whose bodies have been announced but not yet read, in the
    # order bash reads them, and the paren depths at which an arithmetic
    # context opened. The second exists only to answer the `<<` question.
    heredocs = []
    arith = []
    i = 0
    n = len(text)

    def flush(next_separator=""):
        raw = "".join(buf).strip()
        del buf[:]
        if raw:
            segments.append((pending[0], raw))
        pending[0] = next_separator if raw else pending[0]

    while i < n:
        ch = text[i]

        if quote is not None:
            buf.append(ch)
            if quote == '"' and ch == "\\" and i + 1 < n:
                buf.append(text[i + 1])
                i += 2
                continue
            if ch == quote:
                quote = None
            i += 1
            continue

        if ch == "\\" and i + 1 < n:
            # Backslash-newline is a line continuation: it JOINS two lines, so
            # taking both characters here is what stops the newline splitting.
            buf.append(ch)
            buf.append(text[i + 1])
            i += 2
            continue

        if ch in ("'", '"'):
            quote = ch
            buf.append(ch)
            i += 1
            continue

        if ch == "`":
            backtick = not backtick
            buf.append(ch)
            i += 1
            continue

        if ch == "#" and not backtick and _verify_at_word_start(buf):
            while i < n and text[i] != "\n":
                i += 1
            continue

        if text.startswith("$((", i) or text.startswith("((", i):
            # Arithmetic, remembered as the DEPTH it opened at rather than as
            # a flag, so nesting closes in the right order. Nothing else
            # consults it: `((` and `$((` already balanced through the two
            # branches below, and this one exists so that the `<<` of a left
            # shift is not read as a heredoc.
            opener = "$((" if ch == "$" else "(("
            arith.append(parens)
            parens += 2
            buf.append(opener)
            i += len(opener)
            continue

        if text.startswith("$(", i):
            parens += 1
            buf.append("$(")
            i += 2
            continue

        if ch == "(":
            parens += 1
            buf.append(ch)
            i += 1
            continue

        if ch == ")":
            if parens:
                parens -= 1
            while arith and parens <= arith[-1]:
                arith.pop()
            buf.append(ch)
            i += 1
            continue

        if ch == "{" and _verify_at_word_start(buf):
            braces += 1
            buf.append(ch)
            i += 1
            continue

        if ch == "}" and _verify_at_word_start(buf):
            if braces:
                braces -= 1
            buf.append(ch)
            i += 1
            continue

        if text.startswith("<<<", i) and not arith:
            # A here-STRING: one line, no body, no terminator. Taken WHOLE
            # rather than left to fall through a character at a time, because
            # the `<<` starting at its second character would then be read as
            # a heredoc opening on the here-string's own operand -- which
            # swallows the rest of the script as that heredoc's body.
            buf.append("<<<")
            i += 3
            continue

        if text.startswith("<<", i) and not arith:
            # The redirect itself is appended here; the body waits for the
            # newline that ends the command, because that is where bash starts
            # reading it -- `cat <<X > out.txt` and `cat <<A <<B` both keep
            # announcing on this line.
            opened = _verify_heredoc_opener(text, i)
            if opened is not None:
                # The quoting is unpacked and dropped: a body belongs to the
                # segment that opened it whether or not bash expands it, and
                # this scanner has no other question to ask of it.
                delimiter, strip_tabs, _quoted, j = opened
                heredocs.append((delimiter, strip_tabs))
                buf.append(text[i:j])
                i = j
                continue

        if (ch.isalpha() or ch == "_") and _verify_at_word_start(buf):
            j = i
            while j < n and (text[j].isalnum() or text[j] == "_"):
                j += 1
            word = text[i:j]
            if word in _VERIFY_OPENERS:
                keywords += 1
            elif word in _VERIFY_CLOSERS and keywords:
                keywords -= 1
            buf.append(word)
            i = j
            continue

        top = quote is None and not backtick and not parens and not braces and not keywords

        if text.startswith("&&", i) or text.startswith("||", i):
            if top and not heredocs:
                flush(text[i : i + 2])
            else:
                buf.append(text[i : i + 2])
            i += 2
            continue

        if ch == "\n" and heredocs:
            # The bodies belong to the command that announced them, so they
            # are taken BEFORE this newline is allowed to cut anything.
            buf.append(ch)
            i = _verify_take_heredoc_bodies(text, i + 1, heredocs, buf)
            if top:
                flush()
            continue

        if ch == ";" or ch == "\n":
            if top and not heredocs:
                flush()
            else:
                # `cat <<X; echo` -- the body is still unread, and cutting here
                # would leave it in the NEXT segment. Neither half would run.
                buf.append(ch)
            i += 1
            continue

        buf.append(ch)
        i += 1

    flush()

    # RESIDUAL, computed once after the final flush, from the states this
    # scan already tracks -- nothing new is measured here, only read back.
    # The order below is a REPORTING choice, not a claim about nesting: a
    # single quote wins over every other state, because while `quote == "'"`
    # bash is not looking at `(`, `{` or a keyword at all -- literally
    # nothing inside single quotes is special, so nothing else could have
    # opened after it in a text bash would actually read. `heredocs` is
    # deliberately NOT consulted here: `bash -n` accepts an unterminated
    # heredoc (with a warning) and RUNS it, where every other state named
    # below is a hard syntax error bash refuses outright -- see
    # `verify_unterminated` for the measurement that draws that line.
    if quote == "'":
        residual = "single-quote"
    elif quote == '"':
        residual = "double-quote"
    elif backtick:
        residual = "backtick"
    elif parens:
        residual = "paren"
    elif braces:
        residual = "brace"
    elif keywords:
        residual = "compound"
    else:
        residual = None

    return segments, residual


def verify_unterminated(text):
    """The name of the quoting or grouping state still open when `text` ends,
    or `None` when everything `text` opened was also closed.

    THE SIX STATES THIS NAMES ARE EVERY WAY `_verify_scan`'s `top` test can be
    left permanently false: an unbalanced `'` (`single-quote`), `"`
    (`double-quote`), backtick (`backtick`), an unclosed `(` or `$(` (`paren`),
    an unclosed `{ ... }` group (`brace`), or an unclosed compound command --
    `if`, `for`, `while`, `until`, `case`, `select` without its matching `fi`/
    `done`/`esac` (`compound`). Once any one of them opens and never closes,
    every `;`, newline, `&&` and `||` after that point stops separating
    anything, and `verify_segments` silently fuses the rest of the text into
    the segment that was open when it happened -- three assertions can vanish
    behind one invented one this way, and the invented one still gets a
    verdict from `probe_verify` unless this function is consulted first.

    AN UNTERMINATED HEREDOC IS DELIBERATELY EXCLUDED, on a measured rather
    than a stylistic line: `bash -n` refuses the whole file for all six states
    named above (`syntax error: unexpected end of file` or the equivalent),
    and ACCEPTS an unterminated heredoc at exit 0, with only a warning,
    running it. So "would bash refuse to parse this script" is the line drawn
    here, and it is a measured one: a heredoc falls on the side that runs.
    `verify_segments`'s own docstring already documents taking an
    unterminated heredoc body whole as matching bash, and the closed sibling
    defect at `.aimi/known-gaps/2026-09-07-US-002-heredoc-citado-verdicto-retido.md`
    depends on that staying true -- re-flagging a heredoc here would undo it.

    NO POSITION IS REPORTED, only the state's name. A correct line or column
    for a nested `(`/`{`/compound would need a stack of opening offsets, which
    this report does not carry -- the caller already has the full text in
    `probe_verify`'s `segment` field, and a name is enough to know what to
    look for in it.
    """
    return _verify_scan(text)[1]


def verify_words(segment):
    """One segment's words, split on unquoted blanks and nothing else.

    Same scanner discipline as verify_segments and for the same reason: this is
    what tells `PROBE=$(cmd a b)` -- one word -- from `FOO=bar cmd`, two.
    """
    words = []
    buf = []
    quote = None
    backtick = False
    depth = 0
    i = 0
    n = len(segment)
    while i < n:
        ch = segment[i]
        if quote is not None:
            buf.append(ch)
            if quote == '"' and ch == "\\" and i + 1 < n:
                buf.append(segment[i + 1])
                i += 2
                continue
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch == "\\" and i + 1 < n:
            buf.append(ch)
            buf.append(segment[i + 1])
            i += 2
            continue
        if ch in ("'", '"'):
            quote = ch
            buf.append(ch)
            i += 1
            continue
        if ch == "`":
            backtick = not backtick
            buf.append(ch)
            i += 1
            continue
        if ch == "(":
            depth += 1
            buf.append(ch)
            i += 1
            continue
        if ch == ")":
            if depth:
                depth -= 1
            buf.append(ch)
            i += 1
            continue
        if ch in " \t\n" and not depth and not backtick:
            if buf:
                words.append("".join(buf))
                del buf[:]
            i += 1
            continue
        buf.append(ch)
        i += 1
    if buf:
        words.append("".join(buf))
    return words


# ---------------------------------------------------------------------------
# What a multi-line verify can hide (R23, issue #167)
#
# Two predicates over the same decomposition verify_segments, verify_words and
# verify_changes_directory already give the probe. Both are SCANNERS: nothing
# is expanded or run, and a path is looked at only through confined_spec_path.
# They sit inside the region the guard test for the scanner slices, so no code
# line in them may contain that guard's forbidden word.
# ---------------------------------------------------------------------------

# grep options that take a value, short (one letter each) and long.
_VERIFY_GREP_SHORT_VALUE = "efmABCD"
_VERIFY_GREP_LONG_VALUE = (
    "regexp", "file", "max-count", "after-context", "before-context", "context",
    "devices", "label", "binary-files", "exclude", "exclude-from", "exclude-dir",
    "include", "group-separator",
)
_VERIFY_GREP_NAMES = ("grep", "egrep", "fgrep")

# A redirection word: an optional fd, then an operator. The second pattern is
# the operator ALONE, whose target is the next word.
_VERIFY_REDIRECT = re.compile(r"^(\d*|&)(>>?|<<<|<|>&|<&)")
_VERIFY_REDIRECT_BARE = re.compile(r"^(\d*|&)(>>?|<<<|<|>&|<&)$")


def _verify_errexit_change(segment):
    """What a `set` segment does to errexit: True (enables it), False (turns it
    off) or None (not a `set`, or one that leaves it alone). The last mention
    in the segment wins, as it does in a shell."""
    words = verify_words(segment)
    if not words or words[0] != "set":
        return None
    state = None
    i = 1
    while i < len(words):
        word = words[i]
        i += 1
        if word == "--":
            break
        if len(word) < 2 or word[0] not in "-+":
            continue
        switch_on = word[0] == "-"
        for letter in word[1:]:
            if letter == "e":
                state = switch_on
            elif letter == "o" and i < len(words) and words[i][:1] not in ("-", "+"):
                if words[i] == "errexit":
                    state = switch_on
                i += 1
    return state


def _verify_snippet(segment):
    squeezed = " ".join(segment.split())
    return squeezed if len(squeezed) <= 60 else squeezed[:57] + "..."


def verify_composition_findings(text):
    """Findings for a multi-line verify whose failing line can go unnoticed.

    A verify is run as one script and its exit status is the status of its LAST
    command, so a failing line in the middle is swallowed unless the script
    stops there: a leading `set -e` (or `-o errexit`) does it, and so does
    chaining every later line with `&&` or `||`. Returns a list of finding
    strings, empty when clean -- at most one, since one story's verify is one
    script. `[]` for non-string input, for text with no newline once stripped,
    for a single segment, and for text verify_unterminated reports as not
    parsing at all (its segments are then fused and say nothing reliable).
    """
    if not isinstance(text, str) or "\n" not in text.strip():
        return []
    if verify_unterminated(text):
        return []
    segments = verify_segments(text)
    if len(segments) < 2:
        return []
    unchained = [item for item in segments[1:] if item[0] not in ("&&", "||")]
    if not unchained:
        return []

    prefix = "is multi-line and can swallow a failing line: "
    guarded = _verify_errexit_change(segments[0][1]) is True
    if guarded:
        for _sep, segment in segments[1:]:
            if _verify_errexit_change(segment) is False:
                return [
                    prefix + "errexit is switched off by \""
                    + _verify_snippet(segment)
                    + "\", so a later line can fail unnoticed"
                ]
        return []
    return [
        prefix + "no leading set -e and \"" + _verify_snippet(unchained[0][1])
        + "\" is not chained with && -- only the last line's exit status counts;"
        " start with set -e or chain the lines with &&"
    ]


def _verify_pipe_stages(words):
    """The words of one segment regrouped by pipeline stage: split on an
    unquoted `|` (or `|&`), including one glued to a neighbour. A `|` inside
    quotes, `$(...)`, `(...)` or backticks belongs to its word."""
    stages = [[]]
    for word in words:
        piece = []
        quote = None
        depth = 0
        tick = False
        i = 0
        n = len(word)
        while i < n:
            ch = word[i]
            if quote is not None:
                piece.append(ch)
                if quote == '"' and ch == "\\" and i + 1 < n:
                    piece.append(word[i + 1])
                    i += 2
                    continue
                if ch == quote:
                    quote = None
            elif ch == "\\" and i + 1 < n:
                piece.append(ch)
                piece.append(word[i + 1])
                i += 2
                continue
            elif ch in ("'", '"'):
                quote = ch
                piece.append(ch)
            elif ch == "`":
                tick = not tick
                piece.append(ch)
            elif ch == "(":
                depth += 1
                piece.append(ch)
            elif ch == ")":
                depth = depth - 1 if depth else 0
                piece.append(ch)
            elif ch == "|" and not depth and not tick:
                if piece:
                    stages[-1].append("".join(piece))
                    piece = []
                stages.append([])
                if i + 1 < n and word[i + 1] == "&":
                    i += 1
            else:
                piece.append(ch)
            i += 1
        if piece:
            stages[-1].append("".join(piece))
    return stages


def _verify_substitutions(segment):
    """The text inside each OUTERMOST `$(...)` of a segment (not `$((...))`,
    and not one inside single quotes). A nested one is the inner text's own to
    report when that text is scanned in turn."""
    found = []
    quote = None
    i = 0
    n = len(segment)
    while i < n:
        ch = segment[i]
        if quote == "'":
            if ch == "'":
                quote = None
            i += 1
            continue
        if ch == "\\" and i + 1 < n:
            i += 2
            continue
        if ch == "'" and quote is None:
            quote = "'"
            i += 1
            continue
        if ch == '"':
            quote = None if quote == '"' else '"'
            i += 1
            continue
        if segment.startswith("$(", i) and not segment.startswith("$((", i):
            j = i + 2
            depth = 1
            inner_quote = None
            while j < n and depth:
                c = segment[j]
                if inner_quote:
                    if c == "\\" and inner_quote == '"' and j + 1 < n:
                        j += 2
                        continue
                    if c == inner_quote:
                        inner_quote = None
                elif c == "\\" and j + 1 < n:
                    j += 2
                    continue
                elif c in ("'", '"'):
                    inner_quote = c
                elif c == "(":
                    depth += 1
                elif c == ")":
                    depth -= 1
                j += 1
            found.append(segment[i + 2:j - 1] if depth == 0 else segment[i + 2:])
            i = j
            continue
        i += 1
    return found


def _verify_literal_operand(word):
    """A word's text when it is a plain literal, `None` when the shell would
    expand it into something this scanner cannot name: a variable, a command
    substitution, a glob, brace expansion, a leading `~`, a redirection."""
    out = []
    quote = None
    i = 0
    n = len(word)
    while i < n:
        ch = word[i]
        if quote == "'":
            if ch == "'":
                quote = None
            else:
                out.append(ch)
        elif quote == '"':
            if ch == '"':
                quote = None
            elif ch in "$`":
                return None
            elif ch == "\\" and i + 1 < n:
                out.append(word[i + 1])
                i += 1
            else:
                out.append(ch)
        elif ch in ("'", '"'):
            quote = ch
        elif ch == "\\" and i + 1 < n:
            out.append(word[i + 1])
            i += 1
        elif ch in "$`*?[{}()<>&;" or (ch == "~" and i == 0):
            return None
        else:
            out.append(ch)
        i += 1
    return None if quote else "".join(out)


def _verify_grep_operands(stage):
    """The file operands of one pipeline stage when it is a `grep` that would
    search a path WITHOUT recursing, `[]` for anything else.

    Options are parsed rather than guessed at: a short cluster is read letter
    by letter, stopping at the first one that takes a value (`-e`, `-f`, `-m`,
    `-A`, `-B`, `-C`, `-D`; the value is the rest of the cluster or the next
    word); a long option that takes a value consumes the next word unless it
    carries `=`; `--` ends the options. `-e`/`-f`/`--regexp`/`--file` supply the
    pattern, otherwise the first non-option word IS the pattern and is not a
    file. Any of `-r`, `-R`, `--recursive`, `--dereference-recursive`, `-d` or
    `--directories` means the author already chose what to do with a directory,
    so the stage reports nothing. A heredoc ends the stage: its body is stdin.
    """
    words = list(stage)
    while words and (words[0] == "!" or _VERIFY_ASSIGN.match(words[0])):
        words.pop(0)
    if not words or words[0] not in _VERIFY_GREP_NAMES:
        return []
    operands = []
    pattern_given = False
    options_done = False
    i = 1
    while i < len(words):
        word = words[i]
        i += 1
        if word.startswith("<<") and not word.startswith("<<<"):
            break
        if _VERIFY_REDIRECT.match(word):
            if _VERIFY_REDIRECT_BARE.match(word):
                i += 1
            continue
        if options_done or word == "-" or not word.startswith("-"):
            operands.append(word)
            continue
        if word == "--":
            options_done = True
            continue
        if word.startswith("--"):
            name, has_value, _value = word[2:].partition("=")
            if name in ("recursive", "dereference-recursive", "directories"):
                return []
            if name in ("regexp", "file"):
                pattern_given = True
            if name in _VERIFY_GREP_LONG_VALUE and not has_value:
                i += 1
            continue
        letters = word[1:]
        for index, letter in enumerate(letters):
            if letter in "rRd":
                return []
            if letter in _VERIFY_GREP_SHORT_VALUE:
                if letter in "ef":
                    pattern_given = True
                if index + 1 >= len(letters):
                    i += 1
                break
    if not pattern_given and operands:
        operands = operands[1:]
    return operands


def verify_grep_directory_findings(text, base_dir, _depth=0):
    """One finding per literal relative `grep` operand that is an existing
    directory, when that grep carries no option saying what to do with one.

    `grep needle dir` does not search `dir`: it says "Is a directory" and exits
    2, and a verify written `! grep -q needle dir` reads that 2 as success, so
    the assertion passes whatever `dir` holds. Looks through a leading `!`,
    leading `VAR=` words, every pipeline stage and every `$(...)`
    substitution (depth capped at 3), and stops at the first segment that
    changes directory, because after it `base_dir` is no longer where the
    script stands. Never reads the pattern as a file, and ignores stdin, globs,
    variable operands, absolute paths and anything that escapes `base_dir`.
    The only filesystem question asked is one `confined_spec_path` has already
    answered `inside` for.
    """
    if not isinstance(text, str) or not isinstance(base_dir, str):
        return []
    if _depth == 0 and verify_unterminated(text):
        return []
    findings = []
    for _sep, segment in verify_segments(text):
        if verify_changes_directory(segment):
            break
        for stage in _verify_pipe_stages(verify_words(segment)):
            for operand in _verify_grep_operands(stage):
                literal = _verify_literal_operand(operand)
                if not literal or literal.startswith("/"):
                    continue
                path, inside = confined_spec_path(base_dir, literal)
                if inside and os.path.isdir(path):
                    findings.append(
                        "greps a directory without -r: "
                        + " ".join(literal.split())
                        + " -- grep exits 2 on a directory, which a leading ! reads"
                        " as success; add -r or name the files"
                    )
        if _depth < 3:
            for inner in _verify_substitutions(segment):
                findings.extend(
                    verify_grep_directory_findings(inner, base_dir, _depth + 1)
                )
    return findings


def verify_reads(segment):
    """The variable names a segment EXPANDS: every `$NAME` and `${NAME}` in it.

    Same scanner discipline as verify_segments and verify_words, and here it is
    the whole point: a `$` inside single quotes is not an expansion at all, so
    `CMD='s_clean=x'` READS nothing and assigns `CMD`, while the `case "$s_clean"`
    after it reads `s_clean`. Getting that backwards in either direction is the
    defect this function exists to make visible, so quoting is tracked character
    by character rather than guessed at with a regex over the raw text.

    POSITIONAL AND SPECIAL PARAMETERS ARE NOT NAMES and never appear here.
    `$?`, `$$`, `$!`, `$#`, `$@`, `$*`, `$-`, `$_` and `$1`..`$9` are given by
    the shell itself; reporting them as state the prelude failed to reproduce
    would put a null verdict on every segment that reads an exit status, which
    is noise where an answer belongs.

    IT SEES `$NAME` AND `${NAME}` AND DELIBERATELY NOTHING ELSE. A bare name
    inside `$(( ))` arithmetic is a read this misses, and a name bound by a
    function definition or a shell option set with `set -o` is out of scope by
    the same decision. Widening it is a separate change with its own corpus
    measurement behind it; what is here is what the corpus of real verifies
    actually carries.

    A HEREDOC BODY IS SCANNED ONLY WHERE BASH WOULD EXPAND IT, and which half
    that is comes from the delimiter. Of the four forms, `<<'X'` and `<<"X"`
    -- and the escaped `<<\\X`, the same rule said a third way -- SUPPRESS
    expansion: bash hands the body to the command byte for byte, so a `$VAR`
    in it is not a read at all, and reporting one withholds a verdict the
    shell would never have withheld. `<<X` and the tab-stripping `<<-X` leave
    the delimiter BARE and do expand, so their bodies keep being scanned
    exactly like the rest of the segment -- a name read there is genuinely
    unresolved and stays visible. Only the BODY is skipped, never the line
    that announces it: `python3 - "$ARG" <<'FIM'` still reads `ARG`. Bodies
    are taken in the order bash reads them, which is what `cmd <<'A' <<B`
    needs -- A's has to be stepped over before B's can be reached at all.
    """
    names = set()
    quote = None
    # Delimiters announced but not yet read, in the order bash reads them, each
    # carrying whether its quoting suppresses the body's expansions.
    heredocs = []
    i = 0
    n = len(segment)
    while i < n:
        ch = segment[i]
        if quote == "'":
            if ch == "'":
                quote = None
            i += 1
            continue
        if ch == "\\":
            i += 2
            continue
        if ch == "'" and quote is None:
            quote = "'"
            i += 1
            continue
        if ch == '"':
            quote = None if quote == '"' else '"'
            i += 1
            continue
        if quote is None and segment.startswith("<<<", i):
            # A here-STRING: one line, no body, no terminator. Taken whole so
            # the `<<` at its second character is not read as an opening whose
            # body would then swallow the rest of the segment.
            i += 3
            continue
        if quote is None and segment.startswith("<<", i):
            # Arithmetic is NOT tracked here, unlike in verify_segments, and
            # the asymmetry is safe rather than sloppy: the `<<` of `$(( a <<
            # b ))` can only ever yield a BARE delimiter, a bare body is
            # scanned rather than skipped, and so every name past a left shift
            # is still found -- by the recursive call below instead of by this
            # loop. Nothing is lost, which is the only reason the second
            # arithmetic tracker is not here.
            opened = _verify_heredoc_opener(segment, i)
            if opened is not None:
                delimiter, strip_tabs, quoted, j = opened
                heredocs.append((delimiter, strip_tabs, quoted))
                i = j
                continue
        if ch == "\n" and heredocs:
            # The bodies start at the newline that ends the command, and each
            # is consumed whole even when it is not scanned -- stepping over a
            # quoted body is how the next delimiter's body is reached.
            i += 1
            while heredocs:
                delimiter, strip_tabs, quoted = heredocs.pop(0)
                body = []
                i = _verify_take_heredoc_bodies(
                    segment, i, [(delimiter, strip_tabs)], body
                )
                if not quoted:
                    names |= verify_reads("".join(body))
            continue
        if ch != "$":
            i += 1
            continue
        j = i + 1
        if j < n and segment[j] == "(":
            # A command substitution or arithmetic. Step over the `$` only --
            # what is inside is scanned by this same loop, so a `$VAR` nested
            # in it is still counted.
            i = j
            continue
        if j < n and segment[j] == "{":
            j += 1
            # `${#VAR}` is VAR's length and `${!VAR}` is an indirect read of
            # it; both READ VAR, so the sigil is stepped over rather than
            # ending the parse.
            while j < n and segment[j] in "#!":
                j += 1
        match = _VERIFY_NAME_AT.match(segment, j)
        if match and match.group(0) != "_":
            names.add(match.group(0))
            i = match.end()
            continue
        i = j + 1
    return names


def verify_assigns(segment):
    """The variable names a segment BINDS, the other half of what verify_reads
    asks about.

    Every word that is an assignment binds its own name -- `S=x`, `arr[0]=x`,
    `x+=1`, and the same behind any of the declarators. `for NAME in ...` and
    `read NAME` bind too, and they are here for a reason worth stating: those
    two bind INSIDE the segment that then reads them, so a `for f in a b; do
    echo "$f"; done` provides its own `$f` and must keep its ordinary verdict.
    Leaving them out would turn every loop in every verify into a null.

    Kept apart from verify_asserts_nothing for the same reason
    verify_changes_directory is: that one asks whether a segment could be an
    assertion at all, this one asks what state it leaves behind for the
    segments after it.
    """
    words = verify_words(segment)
    names = set()
    for index, word in enumerate(words):
        if _VERIFY_ASSIGN.match(word):
            names.add(re.split(r"[\[+=]", word, 1)[0])
            continue
        if word == "for" and index + 1 < len(words):
            bound = _VERIFY_BOUND_NAME.match(words[index + 1])
            if bound:
                names.add(bound.group(1))
            continue
        if word == "read":
            for follower in words[index + 1:]:
                if follower.startswith("-"):
                    continue
                bound = _VERIFY_BOUND_NAME.match(follower)
                if not bound:
                    break
                names.add(bound.group(1))
                if follower.endswith(";"):
                    break
    return names


def verify_asserts_nothing(segment):
    """True for a segment that cannot be an assertion: a `set` builtin, or a
    plain variable assignment.

    Both are real parts of a verify and neither claims anything about the tree,
    so reporting either as an assertion that "already passes" would be noise --
    and the assignments are worse than noise, because they always pass.
    """
    words = verify_words(segment)
    if not words:
        return True
    if words[0] == "set":
        return True
    if words[0] in _VERIFY_DECLARATORS:
        return all(w.startswith("-") or _VERIFY_ASSIGN.match(w) for w in words[1:])
    return len(words) == 1 and bool(_VERIFY_ASSIGN.match(words[0]))


def verify_changes_directory(segment):
    """True for a segment whose whole job is to move the shell.

    Kept apart from verify_asserts_nothing, which answers a different question.
    That one asks whether a segment could be an assertion at all, and a `cd`
    could be -- `cd build` fails when the directory is not there. This one asks
    whether running the segment leaves the NEXT one somewhere else, which is
    the property the prelude has to reproduce.
    """
    words = verify_words(segment)
    return bool(words) and words[0] in _VERIFY_CHDIR


# THE FOUR MECHANISMS THAT CARRY ONE SHELL INTO THE NEXT, in the order a
# `source` of the file has to replay them: `declare -f` for the function
# definitions, `declare -p` for the variables, `set +o` for the options and
# `printf %q` for the working directory, all written to ONE sourceable file.
# There is no fifth: `shopt` options, traps and the dirstack are not carried,
# and the four were round-tripped through a fresh `bash -c` before this shape
# was written rather than after.
#
# THE ORDER IS LOAD-BEARING AND IT IS NOT COSMETIC. `set +o` comes after both
# `declare`s because a snapshot taken from a shell that ran `set -e` carries
# `set -o errexit`, and a snapshot that enabled it FIRST would abort its own
# replay on the first line bash refuses. Those refusals are ordinary rather
# than a defect: `BASHOPTS`, `BASH_VERSINFO`, `EUID`, `PPID`, `SHELLOPTS` and
# `UID` are readonly and `declare -p` dumps them like everything else, so
# every replay prints six "readonly variable" complaints to a stderr the probe
# already discards. Putting the options last is what keeps them harmless. `cd`
# is last of all, so the directory is the last thing established before the
# segment runs.
#
# `|| :` ON EACH `declare` IS THE SAME SENTENCE READ BACKWARDS: this dump runs
# inside the EXIT trap of a shell that may have errexit ON, and `declare -f`
# in a shell that defined no function exits 1 -- which is the commonest verify
# there is. Without it the snapshot would truncate at its own first line.
_VERIFY_SNAPSHOT_VAR = "__aimi_probe_snapshot"

_VERIFY_SNAPSHOT_TRAP = (
    "trap '__aimi_probe_rc=$?; "
    "{ declare -f || :; declare -p || :; set +o; "
    'printf "cd %q\\n" "$PWD"; } >"$' + _VERIFY_SNAPSHOT_VAR + '" 2>/dev/null; '
    "exit $__aimi_probe_rc' EXIT"
)

# WHY A TRAP RATHER THAN THREE LINES APPENDED AFTER THE SEGMENT. The segment is
# arbitrary shell and it has to be the LAST thing in the script: US-001 made a
# heredoc travel with the command that opened it, so a segment can end inside
# `PY` with no terminator after it, and anything appended below would land in
# the heredoc body instead of in the shell. An EXIT trap is set BEFORE the
# segment and still runs after it -- including when errexit or the segment's
# own `exit` ends the shell early, which is exactly when the state that
# preceded the failure is still worth carrying.
#
# THE EXPLICIT `exit $__aimi_probe_rc` IS REDUNDANCY, AND IT IS KEPT KNOWING
# THAT. Measured on this bash: a trap that runs commands and does not exit
# leaves the shell's status alone (`trap "true; false" EXIT; exit 7` still
# exits 7), so the dump could not have clobbered the verdict on its own. What
# the line buys is that the guarantee is stated in the code rather than known
# about bash -- the status the trap captured on its first line is the one that
# leaves this shell, and it is the only number every verdict below is computed
# from.

# WHAT A FAILED `cd` COSTS EVERY SEGMENT AFTER IT. Before the snapshot existed
# the prelude carried `cd X || exit 1`, so every later assertion aborted at the
# shell's own failure status. That guarantee is worth keeping byte for byte: a
# `cd` that failed and then let everything after it run in the CALLER's tree is
# this verb manufacturing the defect it exists to find, and quietly. So a
# failed directory change is remembered and every script built afterwards opens
# with this line, which exits before the segment is reached -- the same answer
# the old prelude gave, reported at the same status.
_VERIFY_SNAPSHOT_ABORT = "exit 1"


def _probe_segment_script(segment, snapshot, restore, aborted):
    """The script one segment runs: restore, arm the dump, then the segment.

    `restore` is False for the very first segment of a verify -- there is no
    state yet -- and `aborted` is True once a `cd` has failed, which wins over
    it: nothing is restored and nothing is run. The restore carries
    `2>/dev/null` of its own so the readonly-variable complaints the replay
    always prints cannot be mistaken for the segment's own stderr by a caller
    that stops discarding it.

    ONE FILE, READ THEN OVERWRITTEN, and the order is what makes that safe:
    the `.` finishes long before the EXIT trap fires, so the dump lands on a
    file nothing is still reading. A second file swapped in by `os.replace`
    would buy protection against a dump that dies half-written, and would cost
    this module a second path of its own -- see `_probe_verify_segments` for
    why the one it already has is written down as a widening.
    """
    lines = []
    if aborted:
        lines.append(_VERIFY_SNAPSHOT_ABORT)
    elif restore:
        lines.append(". %s 2>/dev/null" % shlex.quote(snapshot))
    lines.append("%s=%s" % (_VERIFY_SNAPSHOT_VAR, shlex.quote(snapshot)))
    lines.append(_VERIFY_SNAPSHOT_TRAP)
    lines.append(segment)
    return "\n".join(lines)


def probe_verify(text, cwd, skip_matching=None, timeout=None):
    """Every assertion in `text`, run on its own in `cwd`, with its exit status.

    EVERY SEGMENT RUNS ONCE, IN ORDER, AND THE SHELL IT LEAVES BEHIND IS
    CARRIED INTO THE NEXT ONE. A verify names its own paths -- `S=path/to/
    SKILL.md`, then `grep -q x "$S"` -- so an assertion run with no context
    would see an empty `$S`, fail for that reason alone, and be reported as
    discriminating when it is the very thing this verb exists to expose. What
    stops that is a SNAPSHOT: after each segment the shell writes its
    functions, variables, options and working directory to one sourceable
    file, and the next segment sources it before running. Four mechanisms,
    listed at `_VERIFY_SNAPSHOT_TRAP`, and no fifth.

    THE COUNT OF RUNS DOES NOT RISE -- IT FALLS. Each segment is executed
    exactly once, where the carried-prelude shape this replaces re-ran every
    assignment once per assertion after it. `W=$(mktemp -d)` used to hand each
    assertion a DIFFERENT directory; now it makes one, and `cd "$W"` moves
    into the one that exists.

    WHAT IS NOT CARRIED IS THE THING THE REAL SCRIPT USES TO STOP: no earlier
    assertion's exit status reaches the next segment as `$?`, and each segment
    is measured on its own status alone. `set -e` is a shell OPTION and IS
    carried -- it is state a real run would have -- but it can only ever end
    the one segment that fails, never the run: the next segment starts in its
    own process from the snapshot. That is the whole point of taking the verify
    apart, and it is why an assertion hidden behind an earlier failure still
    gets a verdict here.

    THE WORKING DIRECTORY IS THE STATE WITH THE MOST AT STAKE. An assignment is
    carried so an assertion is not measured against an empty variable; a `cd`
    is carried so an assertion is not measured against -- and not WRITTEN INTO
    -- the wrong tree. Without it, `cd "$W"` ran as a segment of its own and
    changed nothing that outlived it, so a `mkdir -p out` two segments later
    landed in `cwd`: the story executor's own worktree, which is where step 1.5
    probes from. The probe was manufacturing the class of defect it exists to
    find. A `cd` that FAILS aborts everything after it instead, at the shell's
    own failure status, which reads as discriminating -- the safe direction,
    the one the timeout used to take, since a probe must never invent dead
    weight. See `_VERIFY_SNAPSHOT_ABORT` for how.

    REFUSING A VERIFY THAT CONTAINS A `cd` WOULD CLOSE THAT TOO, AND IS WORSE.
    The verifies that cd are the elaborate ones: the verify that builds a
    throwaway repo under `mktemp -d`, cds into it and asserts against it is
    exactly the verify whose assertions are worth taking apart, and the story
    that closed this carried one itself. A refusal still has to answer
    something, and the only honest thing it can answer is the empty array --
    which is indistinguishable from "every assertion here discriminates", so
    the executor would print a clean all-clear for the verifies least likely to
    deserve one. Carrying the `cd` keeps the answer; refusing would trade a
    wrong directory for a wrong answer.

    A SEGMENT THAT ESTABLISHES CONTEXT IS RUN AND NOT REPORTED. An assignment,
    a `cd` and a bare `set` claim nothing about the tree -- and the assignments
    are worse than noise in a list of assertions that already pass, because
    they always pass. They still run, because running them is what puts their
    state in the snapshot.

    Output is discarded. What the caller gets is the status, because that is
    what `discriminates` is computed from and a probe that echoed a whole test
    suite's output would bury its own answer.

    THE OPERAND AFTER `||` IS NOT AN ASSERTION and is neither run nor reported.
    `grep -q X f || { echo FAIL; exit 1; }` is one check with a failure branch,
    not two checks: the branch runs only when the check has already failed, its
    own exit status says nothing about the tree, and running it on its own is
    the one decomposition here with teeth -- `[ -d x ] || mkdir x` would create
    a directory the real script never would. The operand after `&&` is the
    opposite case and IS run: it is a further assertion, reached only because
    the one before it passed.

    THE DISK WAS NEVER THE PROBLEM AND STILL IS NOT. Every segment runs as a
    REAL SUBPROCESS in the same directory, so everything it writes to the DISK
    outlives it and the segments after it read it back: `mkdir -p fx`, then
    `printf x > fx/a.txt`, then `grep -q x fx/a.txt` passes here, measured
    rather than reasoned about. The record in
    `.aimi/known-gaps/2026-09-04-p2-verify-probe-tem-uma-terceira-cegueira.md`
    says a `mkdir`/`printf >` fixture leaves every downstream assertion running
    against an EMPTY TREE, and that half of it is wrong; the correction is
    written down here because this docstring is where the next reader of this
    function looks, and a known-gap file is not.

    DISK EFFECTS ARE ALSO THE STATE NOTHING HERE CAN UNDO, and that is by
    design rather than by omission. A segment that deletes a file has deleted
    it for every segment after it, exactly as in a real run; no snapshot
    reverses that, and none should.

    A SEGMENT WHOSE READS THE PROBE CANNOT ACCOUNT FOR GETS NO VERDICT. Its
    entry carries `discriminates: None` and an `unresolvedState` naming the
    variables, and the segment is NOT RUN: an exit status measured in a world
    that never existed is not evidence, and reporting a verdict computed from
    it is worse than reporting none. Both directions the missing state produces
    are wrong, and they are not equally wrong:

      - the assertion that FAILS without it reads as spuriously DISCRIMINATING,
        an exemplary check that is nothing of the sort; and
      - the assertion that PASSES without it reads as spurious DEAD WEIGHT.

    The second is the dangerous one, because "already passes before the work"
    is what tells a reader to STOP LOOKING -- so a check that in truth guards
    the story gets crossed off the list by the tool that was supposed to find
    it. `None` is the third answer that keeps both out of the list: it says
    "cannot tell", which is the only true thing available about a run that did
    not happen.

    THAT CHECK IS STATIC AND DELIBERATELY CONSERVATIVE, AND IT IS NOW WIDER
    THAN WHAT THE SNAPSHOT ACTUALLY MISSES. A name counts as available when the
    inherited environment holds it, when a carried assignment segment binds it,
    or when the segment binds it itself; a name an `eval`, a subshell or a
    function set is not counted even though the snapshot taken after that
    segment very often carries the value. Reading the answer back out of the
    snapshot instead would make the verdict depend on which segments happened
    to run -- a name set inside a segment that was skipped, timed out or was
    itself withheld is genuinely absent -- so the gate answers the question it
    can answer everywhere: can the probe PROVE this segment's reads were
    reproduced. A `None` given where a real verdict was available costs a
    reader one look; a real verdict given where the state was missing is the
    defect this whole third answer exists to prevent.

    WHAT THE SNAPSHOT CLOSED, NAMED SO THE NEXT READER DOES NOT RE-DERIVE IT.
    A function an earlier segment defined is present, so a call to it reports
    the function's own status instead of 127 -- the same non-zero for a
    different reason, which is why the fix is asserted on the exit code and not
    on `discriminates`. A shell option an earlier segment set is present too,
    and that one flips the verdict outright: `false | true` under a carried
    `set -o pipefail` exits 1 and discriminates, where without the option it
    exits 0 and reads as dead weight. That direction -- a real check reported
    as already passing -- is the dangerous one, and it is the reason this was
    worth doing.

    TWO WAYS TO NOT RUN A SEGMENT ON PURPOSE, AND BOTH ANSWER `None`.
    `skip_matching` is a regular expression: a segment it matches is NOT run,
    stays in the report, and carries `discriminates: None` with
    `skipped: True`. `timeout` is the per-segment ceiling: a segment that
    outlives it carries `discriminates: None` with `timedOut: True` and the
    cap that was applied. Both default to today's behaviour -- nothing
    skipped, and `_VERIFY_TIMEOUT` -- because a caller passing neither must
    get exactly the answer it got before either existed.

    THEY ARE THE PARAGRAPH ABOVE RESTATED: a segment that did not run cannot
    be reported as though it had. Skipping is the deliberate case and timing
    out the accidental one, and until now they landed on OPPOSITE answers --
    a skipped segment did not exist at all, and a timed-out one was reported
    at status 124, which reads as a verdict. Routing both to `None` is what
    makes the report honest. Dropping a skipped segment instead would be its
    own lie in the other direction: it would make "the caller declined to
    measure this" indistinguishable from "no such segment is in the verify".
    Neither advances the snapshot, for the reason that answers them both:
    a segment that did not run set nothing for the ones after it.

    WHAT `skip_matching` CANNOT REACH IS THE CONTEXT SEGMENTS, and that is
    load-bearing rather than incidental. The pattern is tested only against
    segments that have already survived the `||`, the `cd` and the assignment
    branches, so a regex broad enough to match a `cd` or an assignment still
    leaves it RUN and its state carried. A skip that could drop a `cd` would
    move every later segment into the caller's own tree -- precisely the defect
    the snapshot exists to prevent -- and would do it at the request of someone
    who only meant to save time.

    A THIRD WAY TO NOT RUN A SEGMENT IS NEITHER DELIBERATE NOR ACCIDENTAL, IT
    IS STRUCTURAL: `text` itself can leave a quote, a backtick or a grouping
    UNTERMINATED at end-of-text, which means bash would refuse to parse it as
    a script at all (`verify_unterminated` names the measurement). That is
    checked before any segment runs, and on a hit this whole function returns
    ONE entry for the whole text -- `discriminates: None`, carrying
    `unterminated` instead of `skipped` or `timedOut` -- rather than running
    whatever `verify_segments` fused the remaining text into. The fused blob
    IS runnable bash-wise in the narrow sense that `subprocess.run` will start
    it, and it fails -- but that failure is bash refusing to parse a script
    that was never well-formed, not a verdict about any assertion the story's
    verify actually names, and publishing it as one is the exact
    "already passes before the work" reading this whole function exists to
    prevent, pointed the other, more dangerous direction: a syntax error
    dressed up as an exemplary discriminating check.

    THIS IS A MITIGATION AND NOT A CURE, and saying so is part of the fix.
    `.aimi/known-gaps/2026-09-03-US-004-verify-probe-cost.md` records that
    probing a verify which ends in a suite costs that suite's whole run time
    once per story. `skip_matching` gives the caller a way to AVOID that cost;
    it does not remove it, and nothing here makes probing a segment cheaper.
    The record was itself written because a tool sold as a cheap warning
    turned out to cost a second full run, so a fix that overstated itself
    would repeat the defect. The pivot that would actually close it -- reusing
    the single pre-run the story executor already performs, so a segment that
    has already run is never re-run -- changes the contract between the
    executor and this verb and is deliberately left to its own story.
    """
    # THE RE-ENTRANCY MARKER GOES IN FIRST, before `assigned` is seeded, and
    # the order is load-bearing rather than tidy. It is put into THIS process's
    # own `os.environ` because that is the environment `subprocess.run` hands
    # every segment below -- one channel, so a nested `verify-probe` inside a
    # segment sees it and refuses. Seeding `assigned` from `os.environ` after
    # the write is what makes the marker a name the probe PROVIDES: set it
    # afterwards and a segment reading `$AIMI_VERIFY_PROBE_ACTIVE` would be
    # judged missing its shell state, reported `discriminates: None` and never
    # run at all -- the guard would be invisible to the only assertion that can
    # see it. Restored on the way out so a second call in the same process (the
    # tests, and any caller driving this function directly) is not itself read
    # as a nested one.
    previous_marker = os.environ.get(VERIFY_PROBE_ACTIVE_ENV)
    os.environ[VERIFY_PROBE_ACTIVE_ENV] = "1"
    try:
        return _probe_verify_segments(text, cwd, skip_matching, timeout)
    finally:
        if previous_marker is None:
            os.environ.pop(VERIFY_PROBE_ACTIVE_ENV, None)
        else:
            os.environ[VERIFY_PROBE_ACTIVE_ENV] = previous_marker


def _probe_verify_segments(text, cwd, skip_matching=None, timeout=None):
    """`probe_verify`'s loop, split out so the marker above owns one try/finally
    rather than wrapping a hundred lines of body. See that function's docstring
    for every rule this implements; nothing is decided here."""
    # THE UNTERMINATED CHECK RUNS FIRST -- before `re.compile`, before
    # `tempfile.mkstemp`, before the loop below ever starts. `text` left a
    # quote or a grouping open at end-of-text is not a script with weak
    # assertions in it; it is not a script bash will parse at all (see
    # `verify_unterminated`'s own docstring for the `bash -n` measurement
    # this is drawn on), so nothing here is going to run, and no scratch
    # file is created for a run that never happens.
    unterminated = verify_unterminated(text)
    if unterminated is not None:
        return [
            {
                "segment": text.strip(),
                "exit": None,
                "discriminates": None,
                "unterminated": unterminated,
            }
        ]

    results = []
    # Compiled once for the whole run rather than once per segment. A pattern
    # that does not compile raises HERE -- inside `probe_verify`'s
    # try/finally, so the re-entrancy marker is still restored on the way out.
    # The CLI never reaches this raise: `op_verify_probe` refuses a bad regex
    # by hand, so a mistyped flag gets a message rather than a traceback.
    skip_pattern = re.compile(skip_matching) if skip_matching else None
    # `None` means "the caller named no ceiling", which is not the same as a
    # caller naming zero -- so the default is resolved by an `is None` test
    # and never by truthiness.
    limit = _VERIFY_TIMEOUT if timeout is None else timeout
    # The state a segment can be PROVEN to have: what a carried assignment
    # binds, seeded with the environment this process already holds --
    # `subprocess.run` hands that same environment to every segment, so `$HOME`
    # and an exported `$TASKS_FILE_PATH` are resolved, not missing. It is not
    # read back out of the snapshot; probe_verify's docstring says why.
    assigned = set(os.environ)
    # THE ONE PATH THIS MODULE NAMES RATHER THAN RECEIVES, and it is written
    # down as the widening it is. Everything else here is rooted in an argument
    # bash resolved; this is a scratch file in $TMPDIR, created by this
    # function and unlinked by it, never under PROJECT_ROOT and never shown to
    # a caller.
    #
    # `mkstemp` RATHER THAN A NAME BUILT FROM A PID OR A STORY ID, for two
    # reasons that both bite. This function runs nested against itself -- the
    # verify of the story that wrote it calls `probe_verify()` from inside a
    # `python3` heredoc, which is a segment of an outer probe -- so two live
    # invocations share a machine and a $TMPDIR, and a fixed name would have
    # them writing each other's shell state. And the file holds `declare -p` of
    # a whole environment: mkstemp's 0600 is what keeps a token that arrived in
    # $GH_TOKEN out of a world-readable temp file.
    snapshot_handle, snapshot = tempfile.mkstemp(prefix="aimi-verify-probe-")
    os.close(snapshot_handle)
    # Set once a `cd` has failed and never cleared -- see _VERIFY_SNAPSHOT_ABORT.
    # `carry` only READS it, so the loop below can rebind it without `nonlocal`.
    aborted = False

    def carry(segment):
        """Run `segment` against the accumulated state, and accumulate its own.

        Returns `(status, timed_out)`. An empty snapshot means nothing has been
        carried yet; a snapshot the segment did not overwrite -- because it
        replaced the EXIT trap, or because the restore itself aborted -- leaves
        the previous state in place rather than clearing it, since state that
        was already proven is better than none.
        """
        script = _probe_segment_script(
            segment, snapshot, os.path.getsize(snapshot) > 0, aborted
        )
        try:
            completed = subprocess.run(
                ["bash", "-c", script],
                cwd=cwd,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=limit,
            )
            return completed.returncode, False
        except subprocess.TimeoutExpired:
            return None, True
        except OSError:
            return 127, False  # no bash, or no such cwd

    try:
        for separator, segment in verify_segments(text):
            if separator == "||":
                continue
            if verify_changes_directory(segment):
                status, timed_out = carry(segment)
                if timed_out or status != 0:
                    aborted = True
                continue
            if verify_asserts_nothing(segment):
                carry(segment)
                words = verify_words(segment)
                if words and words[0] != "set":
                    assigned |= verify_assigns(segment)
                continue
            # THE SKIP IS TESTED HERE AND NOWHERE EARLIER -- after `||`, after
            # the `cd` and after the assignments -- so the pattern can only
            # ever reach a segment that would otherwise have been RUN and
            # REPORTED. See probe_verify's docstring for why a skip able to
            # reach a context segment would be a defect rather than a feature.
            #
            # It is also tested BEFORE the missing-state check below. Both
            # answer `None`, but for different reasons, and only one of them is
            # true here: the caller said do not run this. Naming an
            # `unresolvedState` on a segment nobody was going to run would
            # report the wrong cause.
            if skip_pattern is not None and skip_pattern.search(segment):
                results.append(
                    {
                        "segment": segment,
                        "exit": None,
                        "discriminates": None,
                        "skipped": True,
                    }
                )
                continue
            # The segment's own bindings count as provided: `for f in a b; do
            # echo "$f"; done` reads a name it binds itself, one segment, no
            # carried assignment needed. The shape this whole branch exists for
            # is the other one -- an `eval "$CMD"`, a subshell or a function
            # call setting a variable the NEXT segment reads.
            missing = sorted(verify_reads(segment) - assigned - verify_assigns(segment))
            if missing:
                results.append(
                    {
                        "segment": segment,
                        "exit": None,
                        "discriminates": None,
                        "unresolvedState": missing,
                    }
                )
                continue
            status, timed_out = carry(segment)
            if timed_out:
                # NOT a verdict, and no longer 124. A run that was cut off
                # measured nothing, so it gets the third answer rather than the
                # least-bad of two wrong ones -- see _VERIFY_TIMEOUT for what
                # changed and why the old reasoning was right until it wasn't.
                # `timeoutSeconds` is carried because a bare `timedOut: true`
                # would send its reader into this file to find out what cap it
                # missed, and the cap is the caller's to choose.
                results.append(
                    {
                        "segment": segment,
                        "exit": None,
                        "discriminates": None,
                        "timedOut": True,
                        "timeoutSeconds": limit,
                    }
                )
                continue
            results.append(
                {"segment": segment, "exit": status, "discriminates": status != 0}
            )
    finally:
        os.unlink(snapshot)
    return results


def _read_previous_probe(path):
    """The prior run's own probe output, tolerated rather than required.

    `path` is `None` when the caller passed no `--previous-file` at all --
    the ordinary shape of a story's FIRST probe call, before any second run
    exists to compare against. A path that is set but unreadable or not a
    JSON array degrades the same way: this comparison is a diagnostic layered
    on top of `discriminates`, never a gate, so a bad `--previous-file` must
    never be why the probe itself fails.
    """
    if not path:
        return None
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, UnicodeDecodeError, ValueError):
        return None
    return data if isinstance(data, list) else None


# The phrase named in the acceptance criteria: a segment failing both runs
# points at the HARNESS, not at unfinished work, because unfinished work
# fails once and a broken check fails no matter how much gets written.
_UNSATISFIABLE_NOTE = (
    "fails before and after the change -- check the harness, not the code"
)


def _match_previous(previous, current):
    """Attach `unsatisfiable` to every entry of `current`, comparing each
    against the matching entry of a PRIOR run recorded before this story's
    own work landed.

    Matched by SEGMENT TEXT rather than by position: `implementation.verify`
    is the same script on both calls, so an untouched segment is byte-for-byte
    identical across the two runs even though its exit status may change once
    the story's own code exists. A segment repeated verbatim within one verify
    is paired positionally against its own repeats in `previous` -- first
    occurrence with first, second with second -- since nothing else tells two
    identical segments apart.

    `unsatisfiable` is `true` for exactly the entries this verb exists to
    name: non-zero THIS run and non-zero the PREVIOUS run for the same
    segment. Every other entry -- no `previous` at all, no matching segment,
    or a previous exit of zero -- gets `false`, because a single failure is
    what a story not yet implemented looks like, and only two failures in a
    row for the same segment rules that reading out. `discriminates` is never
    touched here: it was already computed from THIS run alone, and a segment
    that passes now stays `discriminates: false` whatever `previous` says.
    """
    pending = {}
    for entry in previous or []:
        pending.setdefault(entry.get("segment"), []).append(entry.get("exit"))
    for entry in current:
        queue = pending.get(entry["segment"])
        previous_exit = queue.pop(0) if queue else None
        # `None` on either side is "not measured", never "failed": a segment
        # this run declined to run for want of its shell state has no status
        # to compare, and calling it unsatisfiable would put back the
        # confident verdict the null was introduced to withhold.
        failed_both = entry["exit"] not in (None, 0) and previous_exit not in (None, 0)
        entry["unsatisfiable"] = failed_both
        if failed_both:
            entry["note"] = _UNSATISFIABLE_NOTE
    return current


def verify_text_for_story(path, story_id):
    """The verify SCRIPT `story_id` carries, or `""` when it carries none.

    Split out of `op_verify_probe` because the two lines that did this inline
    gave a non-string `verify` and an ABSENT one the same empty string, and
    the empty string probes to the empty array at exit 0 -- so a `verify`
    written as a JSON list arrived at the executor's step 1.5 as "no segment
    fails to discriminate". That is silence reaching a reader as a clean bill
    of health, which is the one answer a probe must never give.

    THE WALK IS UNCHANGED, deliberately: every document in the stream, every
    story matching the id inside it, the first match carrying a non-empty
    string wins, and a match whose verify is an empty string keeps the search
    going. A tasks file may hold the same id twice -- `stories_with_id`
    returns a list for exactly that reason -- so which of them answers is a
    rule, not an accident, and it is preserved here byte for byte.

    WHAT IS NEW is the refusal in the middle of that walk. The first matched
    story whose `verify` is present and is not a string stops it, before any
    segment runs and before a caller can read an empty array as a verdict.
    `jq_index` cannot tell `verify: null` from a missing `verify` key, so JSON
    null stays on the absent side of that line and still resolves to `""` --
    unchanged, and the one shape of "present" this cannot see.

    Callable directly, and that matters: `verify-probe` refuses to re-enter
    itself, so a verify that wants to exercise this decision has to reach it
    from Python rather than by naming the verb.
    """
    for doc in read_docs(path, "verify-probe"):
        for story in stories_with_id(doc, story_id):
            implementation = jq_index(story, "implementation", STORY)
            verify = jq_index(implementation, "verify", STORY + ".implementation")
            if verify is None:
                continue
            if not isinstance(verify, str):
                die(_VERIFY_PROBE_NOT_A_STRING % _verify_probe_type_name(verify))
            if verify.strip():
                return verify
    return ""


def guard_rails_for_story(path, story_id):
    """The implementation.guardRails list of the story `verify_text_for_story`
    would read, or `[]`. Same walk: the first matching story carrying a
    non-empty string verify wins. A malformed value is an empty list here --
    validate-stories is the place that refuses it."""
    for doc in read_docs(path, "verify-probe"):
        for story in stories_with_id(doc, story_id):
            implementation = jq_index(story, "implementation", STORY)
            verify = jq_index(implementation, "verify", STORY + ".implementation")
            if isinstance(verify, str) and verify.strip():
                rails = jq_index(implementation, "guardRails", STORY + ".implementation")
                return [r for r in rails if isinstance(r, str)] if isinstance(rails, list) else []
    return []


def op_verify_probe(argv):
    """The story bash already proved exists -- validate_story_id and
    validate_story_exists both ran before this process started.

    An absent or empty verify is an EMPTY ARRAY at exit 0, never a refusal:
    `implementation` is optional in schema v3.3 and a story is allowed to carry
    no verify at all. That is the same treatment the executor's step 1.5 gives
    the absent case, and a caller that has to tell "no verify" from "the verb
    broke" would just reimplement the check it delegated.

    A verify that is PRESENT and not a string gets the opposite answer, and
    the asymmetry is the point rather than an inconsistency:
    `verify_text_for_story` refuses by name at exit 1, naming the type it
    found. The empty array means "this story has nothing to check"; a story
    carrying a `verify` has something to check, and answering it with the
    shape reserved for the absent case would report silence as a clean bill of
    health. JSON null stays on the absent side, since nothing downstream of
    `jq_index` can tell it from a missing key.

    THE RE-ENTRANCY GUARD IS THE FIRST STATEMENT, before the flags are read and
    long before the tasks file is opened. A refusal that had already parsed
    arguments and read a document would cost the same work as the recursion it
    prevents, one level at a time; refusing at entry costs one interpreter
    start and cannot half-run.

    THE GUARD IS ON THE VERB, NOT ON `probe_verify`, and the asymmetry is
    deliberate rather than an omission. `probe_verify` is the escape hatch the
    refusal message points at -- a caller that genuinely wants to decompose a
    verify from inside another probe can still do it in Python, where no
    subprocess is spawned and so nothing recurses. What loops is the verb
    reaching the shell and the shell reaching the verb, so the verb is what
    refuses.

    `--skip-matching <regex>` IS EXPOSED AND `timeout` IS NOT, deliberately.
    The skip is the one of the two that a caller can decide from OUTSIDE a
    run: it names segments already known to be expensive -- a verify ending in
    a suite -- and the answer it buys is the same on every host. A per-segment
    ceiling is a budget, and this verb has no way to know the caller's. The
    parameter is there for a caller driving `probe_verify` in Python, which is
    the same escape hatch the re-entrancy refusal points at.

    THE VERB WRITES THE ARTIFACT IT ALREADY READS, and closing that asymmetry
    is what moved the naming rule out of prose. This verb has always read a
    prior run's array through `--previous-file` and never written one; the
    executor's skill told an AGENT to redirect stdout to a name blind to which
    PLAN the story came from. Story ids restart at US-001 in every plan and
    `.aimi/tasks/` is shared, so a new plan's US-002 overwrote the previous
    plan's -- a rule living only in prose that no test could reach. The name is
    derived here instead, from the `--tasks-file` stem, which is dated and
    slugged and therefore already unique per plan.

    THE WRITE IS UNCONDITIONAL, not behind a flag. A flag would hand the caller
    back exactly the decision this takes away from it -- whether the artifact
    exists at all -- and the artifact's only consumer is this same verb on the
    next run, where a `--previous-file` naming a file the previous run declined
    to write degrades silently to `None` and leaves the cycle open with nobody
    told.

    EVERY ENTRY CARRIES `guardRail` (true/false), set after `_match_previous`
    from the story's `implementation.guardRails`; `probe_verify` itself still
    returns entries without the key.

    `--previous-file` PRESENT MEANS `-post.json`, and it has to: writing the
    recomparison to the same path would overwrite the artifact it just read,
    destroying the comparison in the act of making it. It also puts under a
    rule the ad-hoc `-post` an executor once invented by hand.

    STDOUT DOES NOT CHANGE SHAPE; the path goes to stderr. stdout has readers:
    the executor's step 1.5 counts the array's segments and
    `_read_previous_probe` returns `None` for any JSON that is not a list, so
    an object `{path, results}` would break the second one in silence. The
    write goes BETWEEN `_match_previous` and `_emit` so the bytes on disk are
    the same array stdout gets, `unsatisfiable` already attached --
    `write_docs_atomically` applies `jq_numbers` and ends with a newline
    exactly as `_emit` does, so there is no second format to keep in step.

    IT REUSES THE MODULE'S ONE ATOMIC WRITER rather than opening a file of its
    own: no new `open(`, no second `NamedTemporaryFile(`, no fourth
    `os.unlink(`. What it does add is four os.path calls -- dirname, basename,
    splitext and join -- which is why the structural ratchet's counter moved
    and nothing else in it did.
    """
    if os.environ.get(VERIFY_PROBE_ACTIVE_ENV):
        die(_VERIFY_PROBE_REENTRY)
    path = _flag(argv, "--tasks-file")
    story_id = _flag(argv, "--story-id")
    cwd = _flag(argv, "--cwd")
    previous_file = _flag(argv, "--previous-file")
    skip_matching = _flag(argv, "--skip-matching")
    if not path or story_id is None:
        die(
            "Usage: tasks.py verify-probe --tasks-file <path> --story-id <id> "
            "[--cwd <dir>] [--previous-file <path>] [--skip-matching <regex>]"
        )
    # The regex is validated HERE rather than left to `re.compile` inside the
    # probe, because this is the argument-handling half of the verb: a caller
    # who mistyped a pattern is owed the same one-line refusal every other bad
    # flag gets. A traceback out of a tool whose whole job is to emit warnings
    # would read as the tool being broken.
    if skip_matching is not None:
        try:
            re.compile(skip_matching)
        except re.error as err:
            die(
                "Error: verify-probe: --skip-matching is not a valid regular "
                "expression: %s" % err
            )
    text = verify_text_for_story(path, story_id)
    results = probe_verify(text, cwd or os.getcwd(), skip_matching=skip_matching)
    _match_previous(_read_previous_probe(previous_file), results)
    # `guardRail` is added HERE and not in probe_verify: the label is the
    # story's own declaration, read from the document, while probe_verify
    # measures a script it was handed. Present on every entry, true only for
    # an entry whose segment text a guardRails label names exactly.
    rails = set(guard_rails_for_story(path, story_id))
    for entry in results:
        entry["guardRail"] = entry["segment"] in rails
    # The artifact lands in the TASKS FILE'S OWN directory, and the argument
    # for that used to live in the skill prose that composed the name:
    # `find_aimi_root` stops at the first `.aimi/` it finds walking up from the
    # cwd, so an artifact written into a fresh one inside the worktree would
    # relocate PROJECT_ROOT there and make every later CLI call naming an
    # absolute path outside the worktree refuse. The STEM keys the name to the
    # plan: story ids restart at US-001 in every plan while `.aimi/tasks/` is
    # shared, so a new plan's US-002 landed on top of the previous plan's. The
    # stem is already dated and slugged, so keying by it invents no identifier.
    stem = os.path.splitext(os.path.basename(path))[0]
    artifact = os.path.join(
        os.path.dirname(path) or ".",
        "verify-probe-%s-%s%s"
        % (stem, story_id, "-post.json" if previous_file else ".json"),
    )
    # A failed write is ONE line and exit 0, with the array still on stdout:
    # the probe is a diagnostic and this skill's own step says its
    # unavailability never fails a story, so a write that killed the verb
    # would invert that.
    try:
        write_docs_atomically(artifact, [results])
    except OSError as err:
        sys.stderr.write("verify-probe: could not write %s: %s\n" % (artifact, err))
    else:
        sys.stderr.write("verify-probe: wrote %s\n" % artifact)
    _emit(results)
    return 0


_GIT_ENV_DROPPED = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE")


def _probe_plan_git(args, cwd):
    """`git <args>` in `cwd` as (returncode, stdout, stderr), or None when git
    cannot be run at all (not installed, or `cwd` is gone). The three variables
    that pin git to one repository are removed from the environment it gets, so
    a caller running inside a hook probes the repository `cwd` names."""
    env = {k: v for k, v in os.environ.items() if k not in _GIT_ENV_DROPPED}
    try:
        proc = subprocess.run(
            ["git"] + list(args), cwd=cwd, env=env, capture_output=True, text=True
        )
    except OSError:
        return None
    return proc.returncode, proc.stdout, proc.stderr


def _probe_plan_not_probed(ref, reason):
    """The answer for a baseRef that cannot be probed. The result arrays are
    OMITTED, not empty: no reader can mistake emptiness for a clean bill."""
    return {"baseRef": ref, "probed": False, "reason": reason}


def _probe_plan_why(entry):
    """Why a probe entry carries no verdict, named by its own cause."""
    if entry.get("skipped"):
        return (
            "skipped as a full-suite segment; pass --run-suites to measure it"
        )
    if entry.get("timedOut"):
        return "timed out before a verdict"
    if entry.get("unresolvedState"):
        return "reads shell state nothing provides: %s" % ", ".join(
            str(name) for name in entry["unresolvedState"]
        )
    if entry.get("unterminated"):
        return "the verify is unterminated (%s), so it would not run as written" % (
            entry["unterminated"],
        )
    return "no verdict could be reached"


def _probe_plan_stories(docs, path, git_tree, sha, prefix, skip_matching):
    """The per-story loop. Returns (stories, unlabelled, unmeasured)."""
    stories_out, unlabelled, unmeasured = [], [], []
    for doc in docs:
        if not isinstance(doc, dict) or not isinstance(doc.get("userStories"), list):
            continue
        for story in doc["userStories"]:
            if not isinstance(story, dict):
                continue
            sid = story.get("id")
            implementation = story.get("implementation")
            verify = implementation.get("verify") if isinstance(implementation, dict) else None
            if verify is None or (isinstance(verify, str) and not verify.strip()):
                stories_out.append({"id": sid, "segments": []})
                continue
            if not isinstance(verify, str):
                stories_out.append({"id": sid, "segments": []})
                unmeasured.append({
                    "id": sid, "segment": None,
                    "why": "implementation.verify is %s, not a string"
                    % _verify_probe_type_name(verify),
                })
                continue
            project = _report_project(story)
            if project is not None and _invalid_project(project):
                stories_out.append({"id": sid, "segments": []})
                unmeasured.append({
                    "id": sid, "segment": None,
                    "why": "project %r is not a routable project path" % project,
                })
                continue
            rel = prefix + (project if project not in (None, ".") else "")
            probe_dir = rel.rstrip("/")
            if probe_dir:
                found = _probe_plan_git(["cat-file", "-e", sha + ":" + probe_dir], git_tree)
                if found is None or found[0] != 0:
                    stories_out.append({"id": sid, "segments": []})
                    unmeasured.append({
                        "id": sid, "segment": None,
                        "why": "project directory %s does not exist at the base commit" % probe_dir,
                    })
                    continue
            results = probe_verify(
                verify, git_tree + "/" + rel, skip_matching=skip_matching
            )
            rails = set(guard_rails_for_story(path, sid)) if isinstance(sid, str) else set()
            for entry in results:
                entry["guardRail"] = entry["segment"] in rails
                if entry["discriminates"] is False and not entry["guardRail"]:
                    unlabelled.append({"id": sid, "segment": entry["segment"]})
                elif entry["discriminates"] is None:
                    unmeasured.append({
                        "id": sid, "segment": entry["segment"],
                        "why": _probe_plan_why(entry),
                    })
            stories_out.append({"id": sid, "segments": results})
    return stories_out, unlabelled, unmeasured


def op_probe_plan(argv):
    """Every story's verify, run at the tasks file's own `metadata.baseRef` in
    ONE throwaway detached worktree, so a segment that already passes before
    any story is built is named before the plan reaches /aimi:execute.

    THE RE-ENTRANCY GUARD IS THE FIRST STATEMENT, for the reason
    `op_verify_probe` gives: this verb runs verify segments, so a verify that
    calls it back would recurse.

    `probed` IS DECIDED BEFORE ANYTHING IS CREATED. Every baseRef that cannot be
    used (absent, option-shaped, no git, not a repository, an unknown commit, a
    scratch directory inside the repository, a failed `worktree add`) answers
    `{baseRef, probed: false, reason}` at exit 0 with the result arrays
    OMITTED -- emptiness must never read as a clean bill of health.

    THE TREE LIVES UNDER A `TemporaryDirectory` OUTSIDE THE REPOSITORY and is
    removed with `git worktree remove --force` then `git worktree prune` in a
    `finally`, so the caller's `git worktree list` is unchanged on every exit
    path. The base tree carries no gitignored state: a segment that fails there
    only because the tree is unprepared reads as discriminating, the safe
    direction. This verb REPORTS; the refuse-or-report decision is `policy`.
    """
    if os.environ.get(VERIFY_PROBE_ACTIVE_ENV):
        die(_PROBE_PLAN_REENTRY)
    path = _flag(argv, "--tasks-file")
    cwd = _flag(argv, "--cwd") or os.getcwd()
    ref = _flag(argv, "--ref")
    run_suites = "--run-suites" in argv
    if not path:
        die(
            "Usage: tasks.py probe-plan --tasks-file <path> [--cwd <dir>] "
            "[--ref <sha>] [--run-suites]"
        )
    docs = read_docs(path, "probe-plan")
    if not ref:
        ref = None
        for doc in docs:
            meta = doc.get("metadata") if isinstance(doc, dict) else None
            candidate = meta.get("baseRef") if isinstance(meta, dict) else None
            if isinstance(candidate, str) and candidate.strip():
                ref = candidate
                break
    if ref is None:
        _emit(_probe_plan_not_probed(None, "metadata.baseRef is absent and no --ref was given"))
        return 0
    if ref.startswith("-"):
        _emit(_probe_plan_not_probed(ref, "the ref begins with '-' and is not a commit name"))
        return 0
    top = _probe_plan_git(["rev-parse", "--show-toplevel"], cwd)
    if top is None:
        _emit(_probe_plan_not_probed(ref, "git is not installed or cannot run here"))
        return 0
    if top[0] != 0:
        grouped = _probe_plan_project_groups(
            docs, path, ref, cwd, None if run_suites else _PROBE_PLAN_SUITE_PATTERN
        )
        if grouped is None:
            _emit(_probe_plan_not_probed(ref, "the invocation directory is not inside a git repository"))
        else:
            _emit(grouped)
        return 0
    toplevel = top[1].strip()
    outcome = _probe_plan_in_repo(
        docs, path, ref, toplevel, cwd, None if run_suites else _PROBE_PLAN_SUITE_PATTERN
    )
    if outcome[0] == "not-probed":
        _emit(_probe_plan_not_probed(ref, outcome[1]))
        return 0
    _emit(_probe_plan_payload(ref, outcome[1], outcome[2], outcome[3]))
    return 0


def _probe_plan_payload(ref, stories_out, unlabelled, unmeasured):
    return {
        "baseRef": ref,
        "probed": True,
        "policy": PROBE_PLAN_NONDISCRIMINATING_POLICY,
        "stories": stories_out,
        "unlabelledNonDiscriminating": unlabelled,
        "unmeasured": unmeasured,
    }


def _probe_plan_in_repo(docs, path, ref, toplevel, cwd, skip_matching):
    """The resolve-ref / worktree-add / per-story sequence against ONE
    repository. `toplevel` is its root and `cwd` a directory inside it whose
    prefix the stories' own relative paths hang from. Returns
    ("not-probed", reason) or ("ok", stories, unlabelled, unmeasured); the
    throwaway worktree is gone on every path out."""
    resolved = _probe_plan_git(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], toplevel)
    if resolved is None or resolved[0] != 0 or not resolved[1].strip():
        return ("not-probed", "the ref does not resolve to a commit in this repository")
    sha = resolved[1].strip()
    shown = _probe_plan_git(["rev-parse", "--show-prefix"], cwd)
    prefix = shown[1].strip() if shown is not None and shown[0] == 0 else ""
    with tempfile.TemporaryDirectory(prefix="aimi-probe-plan-") as scratch:
        scratch_real = os.path.realpath(scratch)
        top_real = os.path.realpath(toplevel)
        if scratch_real == top_real or scratch_real.startswith(top_real + "/"):
            return ("not-probed", "the temporary directory would land inside the repository")
        git_tree = scratch_real + "/tree"
        added = _probe_plan_git(["worktree", "add", "--detach", git_tree, sha], toplevel)
        if added is None or added[0] != 0:
            _probe_plan_git(["worktree", "prune"], toplevel)
            detail = (added[2].strip().splitlines() or ["no output"])[0] if added else "git cannot run"
            return ("not-probed", "git worktree add failed: " + detail)
        try:
            stories_out, unlabelled, unmeasured = _probe_plan_stories(
                docs, path, git_tree, sha, prefix, skip_matching,
            )
        finally:
            removed = _probe_plan_git(["worktree", "remove", "--force", git_tree], toplevel)
            _probe_plan_git(["worktree", "prune"], toplevel)
            if removed is None or removed[0] != 0:
                sys.stderr.write("probe-plan: could not remove the temporary worktree %s\n" % git_tree)
    return ("ok", stories_out, unlabelled, unmeasured)


def _probe_plan_project_groups(docs, path, ref, cwd, skip_matching):
    """The invocation directory is not inside a git repository, which is the
    multi-repo layout: AIMI_ROOT is a plain parent holding one repository per
    project. Each story's own `project` names the repository it is probed in,
    so the stories are grouped by it and each group goes through the same
    sequence a single repository does, at the file's own `ref`.

    The `project` is document-sourced, so its directory is confined to
    PROJECT_ROOT by `confined_spec_path` (never a fresh check); one that
    escapes, does not exist or is not a repository leaves its stories
    `unmeasured` by name, and the other groups are still probed. Returns None
    when no group could be resolved (the caller then answers `probed: false`
    exactly as before), else the same payload a single repository gives."""
    project_root = os.environ.get("PROJECT_ROOT") or cwd
    entries = []  # (project key or None, story)
    for doc in docs:
        if not isinstance(doc, dict) or not isinstance(doc.get("userStories"), list):
            continue
        for story in doc["userStories"]:
            if isinstance(story, dict):
                project = _report_project(story)
                entries.append((project if project is not None else ".", story))
    results = [None] * len(entries)  # per story: (stories_entry, [unlabelled], [unmeasured])
    order = []
    for index, (project, _) in enumerate(entries):
        if project not in order:
            order.append(project)
    resolved_any = False

    def _declined(index, story, why):
        sid = story.get("id")
        implementation = story.get("implementation")
        verify = implementation.get("verify") if isinstance(implementation, dict) else None
        unmeasured = []
        if verify is not None and not (isinstance(verify, str) and not verify.strip()):
            unmeasured.append({"id": sid, "segment": None, "why": why})
        results[index] = ({"id": sid, "segments": []}, [], unmeasured)

    for project in order:
        members = [i for i, (key, _) in enumerate(entries) if key == project]
        reason = None
        group_dir = None
        if project == ".":
            reason = "project . is the invocation directory, which is not inside a git repository"
        elif _invalid_project(project):
            reason = "project %r is not a routable project path" % project
        else:
            group_dir, inside = confined_spec_path(project_root, project)
            if not inside:
                reason = "project %s escapes the project root" % project
        toplevel = None
        if reason is None:
            top = _probe_plan_git(["rev-parse", "--show-toplevel"], group_dir)
            if top is None:
                # git could not even start in it: the directory is not there
                # (or is not a directory), git itself having run above.
                reason = "project %s: the directory does not exist" % project
            elif top[0] != 0:
                reason = "project %s is not a git repository" % project
            else:
                toplevel = top[1].strip()
        if reason is None:
            # The group's stories lose their own `project`: the repository is
            # already the group, so the per-story path logic must not add it
            # to the prefix a second time.
            stripped = [
                {k: v for k, v in entries[i][1].items() if k != "project"}
                for i in members
            ]
            outcome = _probe_plan_in_repo(
                [{"userStories": stripped}], path, ref, toplevel, group_dir, skip_matching
            )
            if outcome[0] == "not-probed":
                reason = "project %s could not be probed: %s" % (project, outcome[1])
        if reason is not None:
            for i in members:
                _declined(i, entries[i][1], reason)
            continue
        resolved_any = True
        _, stories_out, unlabelled, unmeasured = outcome
        # every dict story yields exactly one stories entry, in order; the
        # unlabelled/unmeasured lists are attributed to a story by its id.
        for position, i in enumerate(members):
            sid = entries[i][1].get("id")
            results[i] = (
                stories_out[position],
                [u for u in unlabelled if u["id"] == sid and position == _first_with_id(entries, members, sid)],
                [u for u in unmeasured if u["id"] == sid and position == _first_with_id(entries, members, sid)],
            )
    if not resolved_any:
        return None
    stories_out, unlabelled, unmeasured = [], [], []
    for entry, rows_u, rows_m in results:
        stories_out.append(entry)
        unlabelled.extend(rows_u)
        unmeasured.extend(rows_m)
    return _probe_plan_payload(ref, stories_out, unlabelled, unmeasured)


def _first_with_id(entries, members, sid):
    """Position within `members` of the first story carrying `sid`, so a
    duplicated id's rows are attributed once rather than once per twin."""
    for position, i in enumerate(members):
        if entries[i][1].get("id") == sid:
            return position
    return -1


# ---------------------------------------------------------------------------
# list-known-gaps -- the corpus the executors write and no plan has ever read
# ---------------------------------------------------------------------------
#
# Every executor that hits a planning defect writes it to .aimi/known-gaps/ and
# nothing downstream reads it back, so the same defect is rediscovered a few
# weeks later by the next plan. This verb is the reader half.
#
# THE PARSER OWES ITS SHAPE TO THE CORPUS, not to a format anyone declared.
# The 32 files measured on 2026-09-03 carried no frontmatter at all -- which is
# why aimi-learnings-researcher, grep-first on frontmatter fields, could not see
# them -- and their bodies come in three forms: lines prefixed `KNOWN-GAP:`,
# lines prefixed `KNOWN-GAP (US-NNN):`, and bare prose carrying no prefix at all
# (20 of the 32 files). The bare-prose files are gaps too. A parser that
# recognised only the prefixed form would silently drop two thirds of the
# corpus, which is the same class of defect this verb exists to close, so EVERY
# file yields at least one entry -- the verify counts the files on disk at run
# time and asserts exactly that.
#
# A `feature:` frontmatter key is read as of 2026-09-04, and it is the one part
# of this format that was declared rather than measured. See `gap_frontmatter`
# for why the file name could not carry that job alone, and
# `known_gap_entries` for the precedence order it sits at the top of.

# `YYYY-MM-DD`, then an optional `US-NNN`, then an optional slug:
# 2026-07-26-US-001.md, 2026-08-04-US-006-roadmap-amend-no-git-trace.md and
# 2026-08-04-verify-creates-excludes-miss-this-repo.md (no story id at all) are
# all real names in the corpus and all three have to parse.
_GAP_FILENAME = re.compile(
    r"^(?P<date>\d{4}-\d{2}-\d{2})"
    r"(?:-(?P<story>US-\d+))?"
    r"(?:-(?P<slug>.+))?"
    r"\.md$"
)

# The two prefix shapes, as one pattern. The leading `[-*+]` allowance is for a
# gap written as a markdown bullet: none in the corpus today, and cheap enough
# that the first one costs nothing.
_GAP_PREFIX = re.compile(
    r"^\s*(?:[-*+]\s+)?KNOWN-GAP\s*(?:\(\s*(?P<story>[^)]*?)\s*\))?\s*:\s?"
)

_GAP_STORY_ID = re.compile(r"^US-\d+$")

# A dated tasks file: `2026-08-08-identity-contract-tasks.json` names both its
# date and its feature, so the index below never has to open it.
_TASKS_FILENAME = re.compile(
    r"^(?P<date>\d{4}-\d{2}-\d{2})-(?P<feature>.+)-tasks\.json$"
)

# `forge-abstraction-phase-1.2-tasks.json` is one phase of the
# `forge-abstraction` feature, not a feature called `forge-abstraction-phase-1.2`.
_TASKS_PHASE_SUFFIX = re.compile(r"-phase-[0-9][0-9.]*$")

_TASKS_SUFFIX = "-tasks.json"

_ISO_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def _created_at(path):
    """metadata.createdAt of a tasks file, or None for anything unreadable.

    SILENT on every failure, deliberately: this runs over whatever happens to
    sit in .aimi/archive/, a directory nothing validates, and one malformed
    document there must not take down a verb whose whole job is to avoid
    dropping things. A file it cannot read costs one unresolved feature, which
    the entry already has a representation for.
    """
    try:
        with open(path, "r", encoding="utf-8") as handle:
            doc = json.JSONDecoder().raw_decode(handle.read().lstrip())[0]
    except (OSError, ValueError):
        return None
    metadata = doc.get("metadata") if isinstance(doc, dict) else None
    created = metadata.get("createdAt") if isinstance(metadata, dict) else None
    if isinstance(created, str) and _ISO_DATE.match(created[:10]):
        return created[:10]
    return None


# `.aimi/tasks/` is two directories deep at its deepest -- a phase file lives at
# `<feature>/<phase-dir>/<feature>-phase-N-tasks.json` and a flat file sits at
# the top -- and `.aimi/archive/` is flat. Nothing below is scanned.
_TASKS_SCAN_DEPTH = 2


def _listdir(path):
    """sorted(os.listdir), and an EMPTY list for anything unreadable.

    Same silence _created_at keeps, for the same reason: this walks whatever
    happens to be in .aimi/, and a directory it cannot read costs one
    unresolved feature rather than a dead verb.
    """
    try:
        return sorted(os.listdir(path))
    except OSError:
        return []


def _tasks_documents(base):
    """(feature-from-directory or None, file name, path) for every tasks file
    at most _TASKS_SCAN_DEPTH directories under `base`.

    DELIBERATELY NOT os.walk. This file bans every recursive traversal helper
    by name -- test_the_archive_verb_owns_no_recursive_delete_anywhere_in_the_file
    -- because an unbounded walk is what a recursive delete needs, and the one
    verb here that can destroy a user's files sits in the same module. The ban
    is worth more than the four lines it costs to read the two shapes the
    layout actually has.

    The feature carried down is the FIRST directory below `base`, so a phase
    file two levels deep still answers `pipeline-audit` rather than the phase
    directory it sits in.
    """
    frontier = [(base, None, 0)]
    while frontier:
        directory, feature, depth = frontier.pop(0)
        for name in _listdir(directory):
            full = os.path.join(directory, name)
            if os.path.isdir(full):
                if depth < _TASKS_SCAN_DEPTH:
                    frontier.append((full, feature or name, depth + 1))
            elif name.endswith(_TASKS_SUFFIX):
                yield feature, name, full


def tasks_feature_scan(aimi_dir):
    """(date -> feature for the dates that carry exactly one, every feature
    name that exists).

    ONE walk answers both questions because both are asked of the same two
    directories, and the walk OPENS tasks documents to read `metadata.createdAt`
    for the ones whose name carries no date. Asking twice would pay the cost of
    the whole verb twice.

    Both `.aimi/tasks` and `.aimi/archive` are read, because a gap written in
    July belongs to a feature whose tasks file was archived weeks ago: an index
    over the live directory alone would resolve almost nothing.

    A date that carries TWO features resolves to nothing rather than to a
    guess. Picking one would attribute a gap to a feature it was never about,
    and a wrong `feature` is worse than a null one -- the null is visible to the
    reader and to the --feature filter, the wrong one is not.

    THE NAME SET IS THE WIDER OF THE TWO, deliberately. It answers one question
    and only one: does a feature by this name exist? A feature whose every date
    was ambiguous never reaches the index and is still a feature that exists, so
    the set is built before the ambiguity rule discards anything. A directory
    directly under `.aimi/tasks/` counts on its own terms too -- someone created
    it -- even in the window before it holds a tasks document.
    """
    seen = {}
    names = set()
    tasks_dir = os.path.join(aimi_dir, "tasks")
    for base in (tasks_dir, os.path.join(aimi_dir, "archive")):
        for feature, name, full in _tasks_documents(base):
            matched = _TASKS_FILENAME.match(name)
            date = matched.group("date") if matched else None
            if feature is None:
                # A phase layout puts the feature in the directory name; a flat
                # one puts it in the file name.
                feature = (
                    matched.group("feature")
                    if matched
                    else _TASKS_PHASE_SUFFIX.sub("", name[: -len(_TASKS_SUFFIX)])
                )
            names.add(feature)
            if date is None:
                date = _created_at(full)
            if date:
                seen.setdefault(date, set()).add(feature)
    for name in _listdir(tasks_dir):
        if os.path.isdir(os.path.join(tasks_dir, name)):
            names.add(name)
    index = {
        date: features.pop() for date, features in seen.items() if len(features) == 1
    }
    return index, names


# One frontmatter line. Deliberately not a YAML parser: the block this reads
# holds scalar keys and nothing else, and pulling in a dependency to read three
# lines would make a verb that must never fail depend on one being installed.
_GAP_FRONTMATTER_LINE = re.compile(
    r"^(?P<key>[A-Za-z][A-Za-z0-9_-]*)\s*:\s*(?P<value>.*)$"
)


def gap_frontmatter(body):
    """(declared keys, the body below the block) for a leading `---` fence.

    THIS IS THE ONE PART OF THE FORMAT THAT WAS DECLARED RATHER THAN MEASURED,
    and the reason is that the file NAME cannot carry it. Deriving the feature
    from `<date>-US-NNN-<slug>.md` reads the slug as a feature, and the slug is
    where an author puts a description: `--feature pipeline-audit` returned 10
    entries of 95 at the close of phase 2 and 10 of 118 when this was written
    on 2026-09-04, because the files that mattered were named `...-phase2.md`,
    `...-golden-compara-stderr.md`, `...-worktree-nasceu-de-main.md`. None of
    those is a feature. The corpus grows, so take the number again rather than
    quoting either of these; what does not change is the 10.

    A stricter naming rule cannot fix it either -- that name admits exactly ONE
    file per story, date and feature, and the corpus already holds two US-004
    files written on the same day. Renaming them to carry the feature collides
    and loses one. So the feature is declared inside the file, where two files
    may declare the same one.

    The match is deliberately narrow. The block must open on the VERY FIRST
    line, close on a later `---`, and every line between the two must be blank
    or `key: value`. Anything else is returned untouched as body: a gap file is
    the only copy of the record it holds, and mis-reading prose as metadata
    would delete evidence to gain a guess. An unterminated fence is prose too.

    A `KNOWN-GAP` line inside the fence disqualifies the whole block for the
    same reason, and it needs its own clause because `KNOWN-GAP: text` IS a
    `key: value` pair by the shape rule above. It is the one pair that can
    never be metadata: consuming it would drop the record itself.
    """
    lines = body.split("\n")
    if not lines or lines[0].strip() != "---":
        return {}, body
    fields = {}
    for position in range(1, len(lines)):
        line = lines[position]
        if line.strip() == "---":
            return fields, "\n".join(lines[position + 1:])
        if not line.strip():
            continue
        if _GAP_PREFIX.match(line):
            return {}, body
        matched = _GAP_FRONTMATTER_LINE.match(line)
        if not matched:
            return {}, body
        value = matched.group("value").strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1].strip()
        fields[matched.group("key")] = value
    return {}, body


def gap_blocks(body):
    """One file's body cut into (storyId-or-None, text) entries.

    A `KNOWN-GAP` line opens a block and every line after it joins that block
    until the next one opens, so a gap hard-wrapped across five lines stays one
    entry. Text is kept VERBATIM below the prefix -- these bodies carry tables,
    code fences and indented lists, and re-flowing them would damage the only
    copy of a record that exists nowhere else.

    Anything standing BEFORE the first `KNOWN-GAP` line becomes its own entry.
    No file in the corpus has such a preamble today; the rule is here so the
    first one that does is not dropped, which is the whole failure mode.

    A body with no prefix anywhere is one entry -- that is the bare-prose form,
    two thirds of the corpus. An empty file is still one entry, because the
    per-file floor is what the verify measures.
    """
    preamble = []
    blocks = []
    for line in body.split("\n"):
        matched = _GAP_PREFIX.match(line)
        if matched:
            story = matched.group("story")
            blocks.append(
                (
                    story if story and _GAP_STORY_ID.match(story) else None,
                    [line[matched.end():]],
                )
            )
        elif blocks:
            blocks[-1][1].append(line)
        else:
            preamble.append(line)

    entries = []
    if "".join(preamble).strip():
        entries.append((None, "\n".join(preamble).strip()))
    for story, lines in blocks:
        entries.append((story, "\n".join(lines).strip()))
    return entries or [(None, body.strip())]


def known_gap_entries(aimi_dir, feature=None, since=None):
    """Every gap in .aimi/known-gaps/, oldest file first.

    `feature` resolves in three steps, and the order is the whole point:

    1. The file's own `feature:` frontmatter key. A gap that DECLARES its
       feature is believed over anything derived, even when the two disagree --
       a name is a guess and a declaration is not.
    2. The file name's own slug, AND ONLY WHEN A FEATURE BY THAT NAME EXISTS.
       The fallback is not deprecated -- 49 of the files on disk carry no
       frontmatter, none of them will retroactively gain one, and a fallback
       that stopped answering for them would drop the corpus this verb was
       built to stop dropping. What it stopped doing is INVENTING. The slug is
       where an author puts a description, so an unchecked slug produced a
       feature that had never existed: measured on 2026-09-04 against 114
       entries, the LARGEST feature in the corpus was `phase2`, 30 entries, out
       of files named `2026-09-03-US-001-phase2.md`, and no feature by that
       name was ever planned. Sixteen distinct names were reported that day and
       twelve of them were invented this way; only four were features.
    3. The tasks file planned on the same date.

    A file that resolves to none of the three enters the result with a NULL
    feature rather than being discarded -- discarding it would repeat the
    defect this verb exists to fix, and step 1 does not revoke that rule.
    A rejected slug falls to step 3 rather than to null, which is where the 30
    `phase2` entries went: their date resolves to `pipeline-audit`, the feature
    they were always about.

    `--feature` MATCHES THE NULLS TOO, and that is a filter rule rather than an
    attribution one. An entry with no feature is not an entry of some other
    feature -- it is one whose feature is unknown, and a planning defect with no
    owner is still a defect the plan being written can repeat. Eighteen of the
    114 were invisible to every `--feature` call for that reason. An entry that
    DID resolve, to some other real feature, stays out: this widens the filter
    onto the unattributed, never onto the attributed-elsewhere.

    `--since` is still exact and still drops an entry whose date is null: an
    entry with no date cannot answer "on or after", and inventing an answer for
    it is the guess this parser refuses everywhere else. The two filters differ
    because their nulls do: a null date cannot be compared, a null feature can
    be reported.

    `retired` and `supersededBy` read the same `declared` frontmatter dict
    `feature` already reads, with the same `or None` rule for an empty value.
    Retirement is a property of the FILE, not of one block inside it -- so
    every entry `gap_blocks` cuts a single file into inherits the same
    pair. A `supersededBy` with no `retired` is not a retirement -- a pointer to
    what replaced a gap nobody marked as gone would hand the reader a
    superseder for a gap that is still live, so the pointer is read only when
    the reason is present, and both come back null otherwise.
    """
    gaps_dir = os.path.join(aimi_dir, "known-gaps")
    try:
        names = sorted(name for name in os.listdir(gaps_dir) if name.endswith(".md"))
    except OSError:
        return []

    scan = None
    entries = []
    for name in names:
        matched = _GAP_FILENAME.match(name)
        date = matched.group("date") if matched else None
        file_story = matched.group("story") if matched else None
        full = os.path.join(gaps_dir, name)
        try:
            with open(full, "r", encoding="utf-8") as handle:
                body = handle.read()
        except OSError:
            body = ""
        # The read moved ABOVE the feature resolution when frontmatter became
        # the first source: the declaration lives in the file, so the file has
        # to be open before the question can be answered. The body handed to
        # gap_blocks is what remains BELOW the fence -- a frontmatter block left
        # in place would surface as a preamble entry of its own, which is the
        # bare-prose rule doing exactly the right thing to the wrong input.
        declared, body = gap_frontmatter(body)
        entry_feature = declared.get("feature") or None
        entry_retired = declared.get("retired") or None
        entry_superseded_by = (declared.get("supersededBy") or None) if entry_retired else None
        slug = matched.group("slug") if matched else None
        if entry_feature is None and (slug is not None or date is not None):
            if scan is None:
                # Built at most once per run, and only when some file actually
                # has a question for it: the walk opens tasks documents, and a
                # file naming neither a slug nor a date has nothing to ask.
                scan = tasks_feature_scan(aimi_dir)
            index, known = scan
            # A slug is believed only when it names a feature that exists. It
            # is the one source here an AUTHOR types freehand, so it is the one
            # that can name something that never existed.
            entry_feature = slug if slug in known else None
            if entry_feature is None and date is not None:
                entry_feature = index.get(date)
        for story, text in gap_blocks(body):
            entries.append(
                {
                    "date": date,
                    "storyId": story or file_story,
                    "feature": entry_feature,
                    "text": text,
                    "file": name,
                    "retired": entry_retired,
                    "supersededBy": entry_superseded_by,
                }
            )

    if feature is not None:
        entries = [entry for entry in entries if entry["feature"] in (feature, None)]
    if since is not None:
        entries = [
            entry
            for entry in entries
            if entry["date"] is not None and entry["date"] >= since
        ]
    return entries


def op_list_known_gaps(argv):
    """A JSON array, EMPTY when the directory is absent -- never a refusal.

    A repository that has never recorded a gap is the normal early state, and
    /aimi:plan reads this on every run: a non-zero exit there would turn "no
    gaps yet" into a planning failure.
    """
    aimi_dir = _flag(argv, "--aimi-dir")
    if not aimi_dir:
        die("Usage: tasks.py list-known-gaps --aimi-dir <path> [--feature <f>] [--since <YYYY-MM-DD>]")
    _emit(
        known_gap_entries(aimi_dir, _flag(argv, "--feature"), _flag(argv, "--since"))
    )
    return 0


def op_design_decisions(argv):
    """`{"decisions": "..."}` for a brainstorm file named by --brainstorm-path,
    reusing the same design_decisions() extractor design_context() calls for
    the story EXECUTOR's own metadata.brainstormPath read.

    --brainstorm-path already crossed aimi-cli.sh's validate_path_in_project
    by the time this runs -- confinement of a CLI-ARGUMENT path is that
    function's job, not this op's (see the top-level CLAUDE.md's "Path
    confinement is split on a real boundary" section). Nothing here re-checks
    it, the same way design_context() never re-checks the confinement its own
    caller already applied to a --tasks-file.

    Degrades to an empty string, never a refusal, when the file is missing or
    unreadable -- mirroring design_context()'s own degrade for the identical
    reason: a brainstorm with no Design Decisions section is a normal outcome,
    not a planning failure.
    """
    brainstorm_path = _flag(argv, "--brainstorm-path")
    if not brainstorm_path:
        die("Usage: tasks.py design-decisions --brainstorm-path <path>")
    decisions = ""
    if os.path.isfile(brainstorm_path):
        with open(brainstorm_path, "rb") as handle:
            decisions = design_decisions(handle.read())
    _emit({"decisions": decisions})
    return 0


def op_spec_derivation(argv):
    """The validated, relabeled, rendered form of a research agent's
    entity/endpoint findings, read from the file named by --input.

    --input already crossed aimi-cli.sh's validate_path_in_project by the time
    this runs -- confinement of a CLI-ARGUMENT path is that function's job, the
    same split op_design_decisions documents. Nothing here re-checks it.
    """
    input_path = _flag(argv, "--input")
    if not input_path:
        die("Usage: tasks.py spec-derivation --input <path>")
    try:
        with open(input_path, "rb") as handle:
            payload = json.loads(handle.read())
    except OSError as err:
        die("Error: spec-derivation: cannot read input: %s" % err.strerror)
    except ValueError as err:
        die("Error: spec-derivation: input is not valid JSON: %s" % err)
    try:
        result = derive_spec_records(payload)
    except ValueError as err:
        die("Error: spec-derivation: " + str(err))
    _emit(result)
    return 0


def op_structural_vocabulary(argv):
    """The structural-vocabulary measurement of the tasks file named by
    --tasks-file against every --spec and --prototype text (both repeatable).

    Every path already crossed aimi-cli.sh's validate_path_in_project by the
    time this runs -- confinement of a CLI-ARGUMENT path is that function's
    job, the same split op_design_decisions documents. Nothing here re-checks
    it. Advisory only: a consumer decides what to do with the answer.
    """
    tasks_path = _flag(argv, "--tasks-file")
    if not tasks_path:
        die("Usage: tasks.py structural-vocabulary --tasks-file <path> [--spec <path>]... [--prototype <path>]...")
    docs = read_docs(tasks_path, "structural-vocabulary")
    stories = []
    for doc in docs:
        if isinstance(doc, dict) and isinstance(doc.get("userStories"), list):
            stories.extend(doc["userStories"])
    texts = []
    for index, arg in enumerate(argv):
        if arg in ("--spec", "--prototype") and index + 1 < len(argv):
            source_path = argv[index + 1]
            try:
                with open(source_path, "rb") as handle:
                    texts.append(handle.read().decode("utf-8", "replace"))
            except OSError as err:
                die("Error: structural-vocabulary: cannot read %s %s: %s"
                    % (arg[2:], source_path, err.strerror))
    _emit(measure_structural_vocabulary(stories, texts))
    return 0


_OPS = {
    "status": op_status,
    "metadata": op_metadata,
    "verification-report": op_verification_report,
    "project-groups": op_project_groups,
    "get-story": op_get_story,
    "get-story-context": op_get_story_context,
    "current-story": op_current_story,
    "get-state": op_get_state,
    "count-pending": op_count_pending,
    "run-verdict": op_run_verdict,
    "list-ready": op_list_ready,
    "next-story": op_next_story,
    "validate-deps": op_validate_deps,
    "validate-stories": op_validate_stories,
    "validate-ids": op_validate_ids,
    "validate-waves": op_validate_waves,
    "validate-wave-contention": op_validate_wave_contention,
    "validate-tasks": op_validate_tasks,
    "validate-story-exists": op_validate_story_exists,
    "mark-complete": _mark_op("mark-complete"),
    "mark-failed": _mark_op("mark-failed"),
    "mark-in-progress": _mark_op("mark-in-progress"),
    "mark-skipped": _mark_op("mark-skipped"),
    "update-field": op_update_field,
    "set-execution-mode": op_set_execution_mode,
    "normalize-status": _normalize_op("normalize-status", normalize_status),
    "normalize-verification": _normalize_op("normalize-verification", normalize_verification),
    "normalize-waves": _normalize_op("normalize-waves", normalize_waves),
    "cascade-skip": op_cascade_skip,
    "remove-story": op_remove_story,
    "set-verification": op_set_verification,
    "acknowledge-smell": op_acknowledge_smell,
    "acknowledge-evidence": op_acknowledge_evidence,
    "judge-verification": op_judge_verification,
    "reset-orphaned": op_reset_orphaned,
    "gate-pass": _gate_op("gate-pass", "passed"),
    "gate-fail": _gate_op("gate-fail", "failed"),
    "archive-task": op_archive_task,
    "init-session": op_init_session,
    "get-branch": op_get_branch,
    "verify-probe": op_verify_probe,
    "probe-plan": op_probe_plan,
    "list-known-gaps": op_list_known_gaps,
    "design-decisions": op_design_decisions,
    "spec-derivation": op_spec_derivation,
    "structural-vocabulary": op_structural_vocabulary,
    "research-paths": op_research_paths,
    "archivable-file-is-terminal": op_archivable_file_is_terminal,
}

# No _VERB_FOR_OP table, unlike roadmap.py: every op here is named after the
# aimi-cli.sh verb that calls it, so a diagnostic already names a command the
# reader can run. Keep it that way -- a rename on one side needs the other.
# Three entries are not verbs and each names the bash thing it replaces instead,
# for the same reason: a grep has to find both ends. validate-story-exists and
# archivable-file-is-terminal name FUNCTIONS, one of which still has a bash copy
# beside it. research-paths names the referenced-set half of research-gc, which
# is the only half that crossed -- the mtime sweep and the brainstorm frontmatter
# parser are still bash's, and calling this op `research-gc` would promise a verb
# it does not implement.


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
