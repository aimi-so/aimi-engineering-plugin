#!/usr/bin/env python3
"""models.json document logic for aimi-cli.sh -- the four READER verbs.

WHY THIS FILE EXISTS, AND WHAT IT IS ALLOWED TO DO
==================================================

One module per document, the split roadmap.py and tasks.py already made. This
one is `~/.config/aimi/models.json`, which is neither of theirs: it is GLOBAL
rather than per-project, it carries its own schemaVersion 2.0 and its own
host-keyed shape, and its verbs have a never-fail contract no tasks verb has --
`resolve-models` prints valid JSON and returns 0 on every failure path there
is. Folding it into tasks.py, already 3400 lines about a per-project file,
would blur the one thing that file's name currently tells a reader.

aimi-cli.sh keeps the shell-shaped work: flag parsing, `_aimi_config_dir` and
`_aimi_models_config_path`, the `opencode` binary probe, the `stat` mtime read
and the models-oc-cache-<mtime>.txt read/write, the per-host prompt marker, and
the python3 check itself. This file owns what a verb then computes over the
document it was handed on stdin. These are readers: one crossing per
invocation, no lock, nothing here opens models.json and nothing here writes a
file.

WHAT THE PORT COLLAPSED
-----------------------

The verb it exists for is `cmd_resolve_models`, whose comment claimed a single
jq pass and whose body then made THREE jq calls over the same in-memory value:
one tagged every invalid entry by prefixing the literal "INVALID\\t" onto the
model id, one stripped the tag back off to build the clean result, and one
re-read the tagged value to emit the warnings through a `while IFS=$'\\t' read
-r _cat _val` loop. The delimiter existed for exactly one reason -- a value
crossing a process boundary is a string, and a string needs a separator. It had
already been changed once, from "=" to tab, after a model id containing "="
truncated a message; the comment recording that change is gone with the rest.

In Python the config is parsed once and the three questions are three
expressions over one list of (category, model, valid) tuples. There is no
delimiter, so no id can collide with one -- including the id beginning with
"INVALID\\t" that would have been silently rewritten to "inherit".

WHERE jq AND PYTHON PART COMPANY
--------------------------------

jq reads a STREAM of values rather than one document, `//` fires on false as
well as null, `==` is typed, and it aborts with its own status on a shape it
cannot handle. Each is reproduced deliberately below -- parse_stream,
read_categories, jq_equal, and JqAbort -- and the two places fidelity costs
something are recorded case by case in tests/golden_from_jq.json's
`models_read_cases`, whose `_comment_models_read` names all twelve findings.

ONE THING THIS FILE DOES NOT DO: extract jq_numbers. tasks.py's import comment
says the jq-semantics helpers should follow sanitize.py into a module of their
own once a THIRD module needs them, and this is that third module. Doing it
here would rewrite two other files inside a commit whose whole claim is that
nothing moved; it is a commit of its own, exactly as sanitize.py was.
"""

import json
import sys

# The jq semantics prior slices already solved, imported from whichever module
# owns each one rather than copied. jq_index is `.key` including its null-
# indexes-to-null rule and its abort on anything else; jq_index_in is `index`
# over an array; jq_equal is jq's TYPED `==`, which is why a schemaVersion
# written as the number 2.0 is rejected where the string "2.0" is accepted;
# jq_numbers is jq's number rendering, which prints 1e3 as 1000; _emit_compact
# is one JSON value with no spaces at all, which is what these two verbs print.
from roadmap import jq_numbers
from tasks import (
    MalformedTasks,
    _emit_compact,
    jq_equal,
    jq_index,
    jq_index_in,
    jq_tostring,
)

# The five categories, in the order the resolution jq built them, which is the
# order their warnings come out in.
CATEGORIES = ("research", "review", "design", "workflow", "executor")

# The v1.0 rejection, in Portuguese, ONE literal emitted at BOTH of its sites.
# It was written twice in aimi-cli.sh -- once in resolve-models, once in
# get-current-models -- and the two copies are what the byte-for-byte contract
# was about. The bytes are unchanged at both sites; only the second copy is
# gone. `/aimi:setup-models` matches on "schema 1.0".
SCHEMA_OBSOLETO = "schema 1.0 obsoleto — re-rode aimi-cli detect-models"

# POSIX [:space:] in the C locale, which is what BOTH trims agreed on: bash's
# ${var#${var%%[![:space:]]*}} idiom in _normalize_model_id, and the
# sub("^[[:space:]]+";"")/sub("[[:space:]]+$";"") pair the tagging jq applied to
# the candidate. Python's bare .strip() also eats U+00A0 and friends, which
# neither of them did.
_SPACE = " \t\n\r\f\v"


class JqAbort(Exception):
    """Where jq stopped evaluating and took its exit status with it.

    ONE shape reaches it now: `has("models")` on a document that is not an
    object, which aimi-cli.sh caught in `|| _schema_ok="reject"` and turned
    into the v1.0 rejection -- so a bare string, a number or a null document is
    reported as an obsolete schema. schema_rejected catches it there.

    The second shape was "INVALID\\t" + a non-string, which nothing caught at
    all: that jq call's stderr went to /dev/null and its assignment was bare,
    so `set -euo pipefail` killed the shell with jq's own status and both
    streams empty. That was D1. The port reproduced it and the commit after
    repaired it -- validate refuses a non-string the way it refuses every other
    unusable value -- so normalize's raise is now a contract about ITS input
    rather than a path any config can reach.
    """


def parse_stream(text):
    """Every JSON value in the text, in order -- jq reads a STREAM, not one.

    A models.json holding two concatenated documents runs the verb twice and
    prints two lines (rm-dois-documentos-cc), and a whitespace-only file yields
    ZERO values, which is the "empty result" branch. Raises ValueError on the
    first thing that is not a value, which is where jq's parse error was.

    Not tasks.load_docs: that one takes a PATH and owns the read. Here the
    config arrives on stdin because aimi-cli.sh has already read it to decide
    whether it was empty, and reading it a second time is the shape this port
    exists to remove.
    """
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


def normalize(value):
    """One model id, trimmed at the ENDS only -- never internally.

    'son net' must stay 'son net' and be refused, not repaired into the valid
    alias 'sonnet'. Raises JqAbort for anything that is not a string, which is
    where jq's sub() aborted -- kept as a contract about this function's input
    rather than as a live path, since validate now refuses a non-string before
    reaching here.
    """
    if not isinstance(value, str):
        raise JqAbort("cannot trim " + type(value).__name__)
    return value.strip(_SPACE)


def schema_verdict(doc):
    """jq's `if (has("models") or (.schemaVersion // "") != "2.0")`.

    `has` answers only for an object, so a bare string, a number or a null
    document aborts here rather than being judged -- and the abort is what
    aimi-cli.sh turned into the rejection.
    """
    if not isinstance(doc, dict):
        raise JqAbort("has() on " + type(doc).__name__)
    if "models" in doc:
        return "reject"
    version = doc.get("schemaVersion")
    if version is None or version is False:
        version = ""
    return "ok" if jq_equal(version, "2.0") else "reject"


def schema_rejected(docs):
    """The verdict aimi-cli.sh compared against the literal string "reject".

    It compared jq's WHOLE output, so a two-document file whose first half is
    v1.0 answers "reject\\nok" and is not rejected at all. Reproduced rather
    than tidied: it is the same stream rule as everything else here.
    """
    try:
        verdicts = [schema_verdict(doc) for doc in docs]
    except JqAbort:
        return True
    return "\n".join(verdicts) == "reject"


def read_categories(doc, host):
    """`.categories[$host][$cat] // null`, then "" -> null, for all five.

    Three jq rules, all load-bearing and all recorded in the corpus: indexing
    null yields null (an absent `categories` key gives five nulls, not an
    error), indexing anything else ABORTS (`categories` as a string is the only
    way to reach the "malformed JSON" message), and `//` fires on false as well
    as null, so `false` reads as unset where `0` does not.
    """
    categories = jq_index(doc, "categories", "")
    table = jq_index(categories, host, ".categories")
    values = {}
    for category in CATEGORIES:
        value = jq_index(table, category, ".categories[" + host + "]")
        if value is None or value is False or jq_equal(value, ""):
            value = None
        values[category] = value
    return values


def valid_set(raw):
    """The host's valid ids, normalized and de-blanked -- jq's $valid_list.

    aimi-cli.sh's _host_valid_models has already normalized every entry; doing
    it again here is not a second rule, it is the same one applied to the other
    side of the membership question, which is what stops a padded entry on
    either side from deciding the answer. An EMPTY set means "no valid set
    available" (no `opencode` binary, or one that printed nothing) and the
    caller skips validation entirely -- the fail-safe that keeps a configured
    value usable rather than refusing it against a set nobody could produce.
    """
    return [entry for entry in (line.strip(_SPACE) for line in raw.split("\n")) if entry]


def validate(values, valid, verb, host_name, host_qualifier):
    """The three questions the INVALID-tab scaffolding used to carry as a string.

    One pass over (category, model) yields all three answers at once: what the
    clean result is, which entries were invalid, and what to warn about. The
    empty id and the literal `inherit` are accepted silently -- an id that is
    all whitespace normalizes to "" and lands there, which is why it degrades
    without a warning.
    """
    resolved = {}
    warnings = []
    for category, value in values.items():
        # A NON-STRING IS AN INVALID ID, NOT AN EMERGENCY. This is the D1
        # repair: `true`, `5`, `{}` and `["opus"]` used to reach the tag
        # concatenation, which is a type error on a non-string, and take the
        # whole shell down with jq's exit 5 and both streams empty --
        # contradicting the one thing this verb promises. It is refused the
        # way every other unusable value is refused, and rendered the way jq
        # rendered a non-string in a message: its compact JSON form.
        if not isinstance(value, str):
            resolved[category] = "inherit"
            warnings.append(_not_valid(jq_tostring(value), verb, host_name,
                                       host_qualifier, category))
            continue
        model = normalize(value)
        if model == "" or model == "inherit":
            resolved[category] = "inherit"
        elif jq_index_in(valid, model) is not None:
            resolved[category] = model
        else:
            resolved[category] = "inherit"
            warnings.append(_not_valid(model, verb, host_name, host_qualifier, category))
    return resolved, warnings


def _not_valid(model, verb, host_name, host_qualifier, category):
    """The refusal line, in ONE place, whatever made the value unusable.

    Its wording and its stream are contract -- part2 matches it literally and
    /aimi:setup-models' operator reads it -- so the repair that added a second
    caller made it a function rather than a second copy.
    """
    return ("Warning: " + verb + ": model '" + model + "' is not valid for "
            + host_name + " host (" + host_qualifier + "category: " + category
            + "), falling back to inherit")


def warn(line):
    sys.stderr.write(line + "\n")


def emit_fallback(fallback):
    """The literal aimi-cli.sh owns, printed back verbatim.

    It is passed in rather than spelled here because bash needs it anyway --
    for the missing file, the empty file and the python3-absent degrade, none
    of which reach this file -- and one literal cannot disagree with itself.
    """
    sys.stdout.write(fallback + "\n")
    return 0


def read_or_fall_back(verb, host, config_file, fallback):
    """The read both reader verbs make, and the two refusals both of them share.

    resolve-models and get-current-models differ in exactly two places -- what
    an unset category becomes, and whether the empty stream warns -- and in
    nothing else. Everything up to that point is one rule with one set of
    messages, so it is written once: parse the stream, judge the schema, index
    the five categories per document. Returns the per-document category maps,
    or None having already printed the branch's warning AND the fallback,
    which is what makes the caller's `return 0` correct.
    """
    try:
        docs = parse_stream(sys.stdin.read())
    except ValueError:
        docs = None
    if docs is None or schema_rejected(docs):
        warn("Warning: " + verb + ": " + SCHEMA_OBSOLETO)
        emit_fallback(fallback)
        return None

    # MalformedTasks alone, because jq_index is the only thing that can stop
    # this read and that is what it raises. The verdict above is where a
    # JqAbort comes from, and schema_rejected has already caught it.
    try:
        return [read_categories(doc, host) for doc in docs]
    except MalformedTasks:
        warn("Warning: " + verb + ": models config file is malformed JSON or "
             "failed to parse: " + config_file)
        emit_fallback(fallback)
        return None


# ---------------------------------------------------------------------------
# The verbs
# ---------------------------------------------------------------------------


def op_resolve(argv):
    """resolve-models: five categories to concrete ids, or to `inherit`.

    Never fails, with nothing left to qualify that: every branch below prints
    valid JSON and returns 0. The one input that used to contradict it -- a
    non-string category value, D1 -- is refused in validate now rather than
    aborting the shell at exit 5 with both streams empty.
    """
    verb = "resolve-models"
    config_file = _flag(argv, "--config-file") or ""
    fallback = _flag(argv, "--fallback") or ""
    host = _flag(argv, "--host") or ""
    host_name = _flag(argv, "--host-name") or ""
    host_qualifier = _flag(argv, "--host-qualifier") or ""
    valid = valid_set(_flag(argv, "--valid") or "")

    values = read_or_fall_back(verb, host, config_file, fallback)
    if values is None:
        return 0

    if not values:
        warn("Warning: " + verb + ": empty result from models config: " + config_file)
        return emit_fallback(fallback)

    # Nothing is printed until every document has been answered, because the
    # jq this replaces built its whole tagged value in a command substitution
    # before the shell printed anything -- so a document that aborts takes the
    # output of the ones before it with it.
    results = []
    warnings = []
    for entry in values:
        if not valid:
            results.append({c: ("inherit" if v is None else v) for c, v in entry.items()})
            continue
        resolved, lines = validate(
            {c: ("inherit" if v is None else v) for c, v in entry.items()},
            valid, verb, host_name, host_qualifier,
        )
        results.append(resolved)
        warnings.extend(lines)

    for line in warnings:
        warn(line)
    for result in results:
        _emit_compact(jq_numbers(result))
    return 0


def op_current(argv):
    """get-current-models: the same read, with JSON null where resolve says
    "inherit".

    The asymmetry is deliberate and must not be unified: /aimi:setup-models has
    to tell "not configured" apart from a literal `inherit` override, and only
    null says the first. This verb does not validate at all, so a value
    resolve-models would refuse comes straight back -- a non-string included,
    which is why D1 never reached this side of the file.
    """
    verb = "get-current-models"
    config_file = _flag(argv, "--config-file") or ""
    fallback = _flag(argv, "--fallback") or ""
    host = _flag(argv, "--host") or ""

    values = read_or_fall_back(verb, host, config_file, fallback)
    if values is None:
        return 0

    # The empty stream lands here SILENTLY, where resolve-models warns. The two
    # verbs' last-resort branches differ by exactly one line to stderr and both
    # are contract; gcm-so-espacos-cc and rm-so-espacos-cc are the same input.
    if not values:
        return emit_fallback(fallback)

    for entry in values:
        _emit_compact(jq_numbers(entry))
    return 0


def op_prompt_check(argv):
    """models-prompt-check: `skip` or `prompt`, and nothing else.

    aimi-cli.sh has already answered the two file questions (no config, or an
    empty one, both `prompt`) and has already looked for the per-host marker;
    what is left is the document's own half.
    """
    host = _flag(argv, "--host") or ""
    marker = (_flag(argv, "--marker") or "0") == "1"

    try:
        docs = parse_stream(sys.stdin.read())
    except ValueError:
        docs = None
    if docs is None or schema_rejected(docs):
        sys.stdout.write("prompt\n")
        return 0

    # jq's own answer was compared against the literal "true", so a
    # two-document file answers "true\ntrue" and falls through to the marker --
    # mpc-dois-documentos-cc, where one of those documents alone says skip.
    try:
        answers = ["true" if _host_configured(doc, host) else "false" for doc in docs]
        configured = "\n".join(answers) == "true"
    except MalformedTasks:
        # aimi-cli.sh's `|| _has_config="false"`, which then falls through to
        # the marker rather than to `skip` -- mpc-categories-string-cc.
        configured = False

    if configured or marker:
        sys.stdout.write("skip\n")
    else:
        sys.stdout.write("prompt\n")
    return 0


def _host_configured(doc, host):
    """jq's `(.categories[$host] // {}) as $h | [...] | map(select(...)) | length > 0`.

    Same `//` asymmetry as read_categories, and it is visible: a category set
    to 0 counts as configured (mpc-valor-zero-cc answers skip) and one set to
    false does not (mpc-valor-false-cc answers prompt).
    """
    categories = jq_index(doc, "categories", "")
    table = jq_index(categories, host, ".categories")
    if table is None or table is False:
        table = {}
    for category in CATEGORIES:
        value = jq_index(table, category, ".categories[" + host + "]")
        if value is None or value is False:
            continue
        if jq_equal(value, ""):
            continue
        return True
    return False


def op_list(argv):
    """list-models: the host's model list, as a JSON array.

    `jq -R . | jq -s .` and nothing more -- the ids arrive already normalized
    from _host_valid_models, which is what makes every id the picker OFFERS an
    id resolve-models ACCEPTS. Only the OpenCode branch gets here: Claude Code's
    answer is a constant and aimi-cli.sh prints it without crossing at all.
    """
    lines = sys.stdin.read().split("\n")
    # `jq -R` reads LINES, so a trailing newline is a terminator and not an
    # empty entry -- but an empty line in the MIDDLE is one, which is what the
    # normalization upstream exists to have already removed.
    if lines and lines[-1] == "":
        lines.pop()
    json.dump(lines, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

_OPS = {
    "resolve": op_resolve,
    "current": op_current,
    "prompt-check": op_prompt_check,
    "list": op_list,
}


def _flag(argv, name):
    if name in argv:
        index = argv.index(name)
        if index + 1 < len(argv):
            return argv[index + 1]
    return None


def main(argv):
    """No arm here catches JqAbort, and that is the D1 repair's other half.

    The port kept one, mapping it to jq's exit 5 with both streams empty. There
    is no longer anything to map: the only value that reached it is refused in
    validate now, and every other JqAbort is caught where it is raised --
    schema_rejected's, which is the v1.0 rejection. An arm that cannot fire is
    a place a later regression could hide quietly at exit 5, which is the exact
    failure this pair of commits is about.
    """
    if len(argv) < 2 or argv[1] not in _OPS:
        sys.stderr.write("Usage: models.py <" + "|".join(sorted(_OPS)) + "> [flags]\n")
        return 2
    return _OPS[argv[1]](argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
