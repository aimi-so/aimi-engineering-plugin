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
import shutil
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
from roadmap import TERMINAL_STORY_STATUSES, _json_type, jq_numbers, jq_sort_key

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

# The prompt-injection screen, written out THREE times in the jq -- once for a
# title, once for a description, once per tasks[] entry. One constant here for
# the same reason clamp_max_concurrency is one function: three copies of a
# security rule are three chances to fix two of them.
SUSPICIOUS = (
    "ignore previous"
    "|(^|\\s)[^a-zA-Z0-9]*system\\s*:"
    "|(^|\\s)[^a-zA-Z0-9]*#{1,6}\\s*INSTRUCTIONS\\b"
    "|INSTRUCTIONS\\s*:"
    "|```"
    "|\\$\\("
)

# aimi-cli.sh's `[[ "$id" =~ ^US-[0-9]{3}[a-z]?$ ]]`, verbatim. The optional
# lowercase suffix is the contract; see the note above before "fixing" it.
STORY_ID_PATTERN = "^US-[0-9]{3}[a-z]?$"

VALID_SKILL = "^[a-zA-Z0-9][a-zA-Z0-9_-]*$"
VALID_PROJECT = "^[a-zA-Z0-9_.][a-zA-Z0-9_./@-]*$"
PATH_COMPONENT = ("\\.\\.", "/", "[\\$`;|&]")
GATE_KEYS = ("type", "status", "prompt")


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
            story_id + ": gate: gates field is invalid; use singular gate (see plan.md L687-692)"
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
    if not jq_has(story, "status", STORY):
        errors.append(
            story_id + ": missing required field: status — run normalize-status to fix"
        )
    return errors


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
    """The wave assignment, exactly as the jq's nested reduce built it.

    n outer passes over the stories still unassigned; a story with no
    dependencies lands in wave 0, one whose dependencies are ALL already
    assigned lands one above their max, and one whose dependencies are not
    lands nowhere this pass. A story inside a cycle is therefore never assigned
    at all -- which is why validate-waves reports nothing for a cyclic file
    (wave-ciclo) and why a dangling dependsOn hides every wave error in its
    story (dep-pendurada). Both are recorded passes, not oversights: reporting
    them is validate-deps' job.
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
                current[story_id] = 0
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

    Returns b"" for a section that is not there, which the callers read as "not
    found" -- the same conflation `[ -z "$subsection_body" ]` made, so a section
    that exists but holds only blank lines is reported as missing too.
    """
    heading_matches = re.compile(
        rb"^(?:\xc2\xa7" + _AWK_SPACE + rb"*)?" + section + rb"(?:" + _AWK_SPACE + rb"|\Z)"
    )
    heading_anywhere = re.compile(
        rb"\xc2\xa7" + _AWK_SPACE + rb"*" + section + rb"(?:" + _AWK_SPACE + rb"|\Z)"
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
BRANCH_NAME = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9/_-]*")
URL_CHARSET = r"^[A-Za-z0-9/][A-Za-z0-9:/?#@!&*+,._~%=-]*$"
SOURCE_CITATION = re.compile(r"^BusinessSpec § [0-9]+(\.[0-9]+)? L[0-9]+$")
SOURCE_SECTION = re.compile(r"§ [0-9]+(\.[0-9]+)?")

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


def _endpoints(doc):
    backend = jq_index(jq_index(doc, "metadata", ""), "backendSpec", ".metadata")
    endpoints = jq_index(backend, "endpoints", ".metadata.backendSpec")
    if jq_type(endpoints) != "array":
        return None
    return endpoints


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
# THREE RULES CHANGED HERE ON PURPOSE, and the golden file's
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
#
# Everything else is the bash reproduced, aborts included, and the abort classes
# are named in the golden comment rather than reproduced: there is no shell
# pipeline left to raise SIGPIPE and no `set -e` to trip.

SKILLS_CAP = 102400

# `head -c 65536` on the decisions pipeline. Bytes, like the cap above, and for
# a stronger reason: head counts bytes and never had a locale to depend on.
DECISIONS_CAP = 65536

DECISIONS_HEADING = b"## Design Decisions"

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
            dropped.append({"name": name, "bytes": size, "reason": "oversized"})
            continue
        kept.append(({"name": name, "path": relative, "content": content}, size))

    aggregate = sum(size for _, size in kept)
    while aggregate > SKILLS_CAP and kept:
        entry, size = kept.pop()
        warn("skill " + entry["name"] + " dropped — aggregate skills context exceeded 100KB")
        dropped.append({"name": entry["name"], "bytes": size, "reason": "aggregate"})
        aggregate -= size

    return [entry for entry, _ in kept], dropped


def design_decisions(brainstorm_bytes):
    """The awk/sed/awk/sed/head pipeline, in one pass over the file's bytes.

    From `## Design Decisions` (a PREFIX match, so a heading with a suffix opens
    the section too -- brainstorm-heading-sufixado) to the next `## ` heading or
    end of file. A deeper `### ` heading stays inside. A SECOND
    `## Design Decisions` does not close the section: awk tested that rule
    first and `next`ed past the closing rule, so the two sections merge, which
    brainstorm-secao-duplicada records.

    Bytes throughout, like validate-tasks' subsection scanner and for the same
    reason: awk, sed and `head -c` all counted them.

    The blank-line SQUEEZE is not implemented and its absence is the port being
    honest. `awk 'NF || prev_nf'` collapsed runs of blank lines to one, and the
    `sed '/^$/d'` immediately after it then deleted the survivor too -- the
    composition drops every blank line, and writing the squeeze out would be
    dead code pretending to be a rule.
    """
    lines = brainstorm_bytes.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()

    collected = []
    in_section = False
    for line in lines:
        if line.startswith(DECISIONS_HEADING):
            in_section = True
            continue
        if in_section and line.startswith(b"## "):
            break
        if in_section:
            # `sed 's/^[[:space:]]*//;s/[[:space:]]*$//'`, over a record that can
            # hold no newline.
            stripped = line.strip(b" \t\v\f\r")
            if stripped:
                collected.append(stripped)

    stream = b"".join(line + b"\n" for line in collected)
    return stream[:DECISIONS_CAP].rstrip(b"\n").decode("utf-8", "replace")


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


def design_context(docs, project_root):
    """`{decisions, bundleGuidance}`, both always present and both always
    strings -- never null, never absent. The story-executor prompt interpolates
    them directly, so an absent key and an empty one are not the same thing to
    the only consumer there is.

    The brainstorm path is NOT confined to the project root, and that is the
    pre-port rule reproduced rather than an oversight: an absolute
    `metadata.brainstormPath` is used as given and a relative one is joined onto
    PROJECT_ROOT with no traversal check. validate-tasks' spec paths were
    confined in their own commit, with their own diff; doing the same here on
    the way past would hide a rule change inside a port.
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
    return {"decisions": decisions, "bundleGuidance": bundle_guidance(docs)}


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


def verification_report(doc):
    """One document read answering the three questions ten separate jq
    programs used to open the tasks file for: which stories carry a visual
    verification strategy (each with its own already-normalized `project` and
    `url`, see `_report_project`/`_report_url` above), and how the old
    `type != "object"` malformed scan partitions into the shapes
    normalize-verification actually repairs and the shapes it does not.

    The `visual` list is exactly the old `select(.verification | type ==
    "object" and .strategy == "visual")` scan, order preserved -- a caller
    filtering it by `project`, taking its length, or reading its first entry
    is projecting from ONE read rather than opening a second one.

    The malformed partition reuses `_verification_migrated`'s own predicate
    (`isinstance(verification, str)`) rather than restating it, so the two
    cannot drift apart again: `repairable` is exactly the set
    normalize-verification rewrites (a bare string, the empty string
    included), `unrepairable` is everything else the old scan flagged -- a
    number, an array, a boolean. The UNION of the two, in document order, is
    exactly the id list the old `type != "object"` scan produced; only the
    split is new.
    """
    visual = []
    repairable = []
    unrepairable = []
    for story in _stories(doc):
        story_id = jq_index(story, "id", STORY)
        verification = jq_index(story, "verification", STORY)
        vtype = jq_type(verification)
        if vtype == "object":
            strategy = jq_index(verification, "strategy", STORY + ".verification")
            if jq_equal(strategy, "visual"):
                visual.append(
                    {
                        "id": story_id,
                        "project": _report_project(story),
                        "url": _report_url(verification),
                    }
                )
        elif vtype != "null":
            (repairable if vtype == "string" else unrepairable).append(story_id)
    return {
        "visual": visual,
        "malformed": {"repairable": repairable, "unrepairable": unrepairable},
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

    A pure reader: no lock, no temp file, nothing opened for writing. The two
    files it does open -- a SKILL.md and a brainstorm -- are read-only and are
    named by the document, which is why they are opened here rather than in
    bash.
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

    skills, dropped = skills_payload(
        declared_skill_names(docs, story_id), skills_base_dir, warn
    )
    context = design_context(docs, project_root)

    # `--slurpfile tf` then `$tf[0]`: the story and the metadata come from the
    # FIRST document alone, however many the file holds. `select` is a filter
    # over a stream rather than a lookup, so a duplicated id emits the whole
    # payload twice -- id-duplicado records both objects.
    first = docs[0] if docs else None
    for story in stories_with_id(first, story_id):
        _emit(
            {
                "story": story,
                "metadata": jq_index(first, "metadata"),
                "skills": skills,
                "designContext": context,
                "skillsDropped": dropped,
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
    "list-ready": op_list_ready,
    "next-story": op_next_story,
    "validate-deps": op_validate_deps,
    "validate-stories": op_validate_stories,
    "validate-ids": op_validate_ids,
    "validate-waves": op_validate_waves,
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
    "cascade-skip": op_cascade_skip,
    "reset-orphaned": op_reset_orphaned,
    "gate-pass": _gate_op("gate-pass", "passed"),
    "gate-fail": _gate_op("gate-fail", "failed"),
    "archive-task": op_archive_task,
    "init-session": op_init_session,
    "get-branch": op_get_branch,
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
