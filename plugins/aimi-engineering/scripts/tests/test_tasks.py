"""Tests for scripts/tasks.py.

THE GOLDEN FILE IS THE POINT OF THIS SUITE, same as it is for test_roadmap.py
and test_story_merge.py.

`golden_from_jq.json` holds six blocks for this module, each captured by
running the jq implementations that used to live in aimi-cli.sh, BEFORE they
were deleted: `tasks_read_cases` (151 cases, the six read verbs),
`tasks_ready_cases` (128, list-ready and next-story), `tasks_write_cases`
(91, the seven locked writers), `tasks_validate_cases` (328 -- 82
adversarial documents through all four validators), `validate_tasks_cases`
(121, validate-tasks alone -- fifteen rules, and the only verb that reads files
other than tasks.json) and `story_context_cases` (57, get-story-context). Like
the story-merge capture all six record each case's INPUT, so every one is
replayable: test_the_port_reproduces_the_jq,
test_the_ready_port_reproduces_the_jq, test_the_write_port_reproduces_the_jq,
test_the_validate_port_reproduces_the_jq,
test_the_validate_tasks_port_reproduces_the_jq and
test_the_story_context_port_reproduces_the_jq re-run the whole corpus through
the CLI and compare every field. Those six tests are the evidence the port
changed nothing, and they are why the rest of this file can stay short -- it
asserts the properties a reader would otherwise have to reconstruct from 876
recordings by eye.

`story_context_cases` IS THE ONE BLOCK THAT PROVES LESS THAN THE OTHERS, and it
says so here rather than being quoted as if it proved the same. The five before
it recorded jq PROGRAMS; get-story-context's logic was bash arrays and a shell
loop, so the recording pins the payload's SHAPE -- which keys, in which order,
holding what when a skill is missing or empty or oversized -- and the
hand-written tests beside it carry the fidelity argument. It is also the one
block whose port changed rules on purpose: three of them, named in
CONTEXT_DECISIONS and asserted in full, kept deliberately apart from the six
engine aborts in CONTEXT_ABORTS because a decision is not an excuse. Its
comparison strips one key (`skillsDropped`) from the actual stdout before
comparing, and everything else still has to match the recording byte for byte.

A FOURTH rule then changed and it is the only one that MOVED this block rather
than being absorbed by a table or a strip: `metadata` is now projected onto the
keys with a measured reader (tasks.py's STORY_CONTEXT_METADATA_KEYS) instead of
copied whole, so 43 of the 45 non-empty recordings lost the keys nothing reads.
They were not recaptured and not regenerated: each recorded payload was
re-parsed, its metadata narrowed by the new rule and the rest re-rendered by the
same writer, after that writer was shown to reproduce all 45 byte for byte
first. `_comment_story_context` states it beside what it cost, and the
assertions live under "DECISION 4" below -- including the one the corpus cannot
make, because no fixture in it ever carried a `metadata.decisions`.

`validate_tasks_cases` carries two fields the others have no use for: `files`,
the spec fixtures written inside the project root, and `outside`, the ones
written one directory ABOVE it. The second exists for two recordings alone, and
they are the point of it -- a designSpec of `../fora/...` comes back valid
because the file outside the root was opened and read.

The write block compares two fields the read blocks have no use for: `file`,
the WHOLE resulting tasks.json, and `tree`, the whole .aimi listing. For a
writer that is the contract -- a refusal that wrote something anyway, or a temp
file nobody removed, has nowhere to hide in a comparison that reads the
document back.

None must ever be regenerated from tasks.py. If a case here goes red, either
the port drifted or a rule genuinely changed; in the second case the golden file
changes in the same commit as the rule, with the reason in the message.
"""

import json
import os
import re
import subprocess
import sys
import time

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import tasks as T  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
CLI = os.path.join(SCRIPTS, "aimi-cli.sh")

with open(os.path.join(HERE, "golden_from_jq.json"), encoding="utf-8") as _handle:
    GOLDEN = json.load(_handle)

CASES = {c["label"]: c for c in GOLDEN["tasks_read_cases"]}
READY = {c["label"]: c for c in GOLDEN["tasks_ready_cases"]}
WRITE = {c["label"]: c for c in GOLDEN["tasks_write_cases"]}
VALIDATE = {c["label"]: c for c in GOLDEN["tasks_validate_cases"]}
VALIDATE_TASKS = {c["label"]: c for c in GOLDEN["validate_tasks_cases"]}
CONTEXT = {c["label"]: c for c in GOLDEN["story_context_cases"]}


def _labels(*prefixes):
    return [label for label in CASES if label.startswith(prefixes)]


# The 37 cases the capture's own comment names, grouped the way it groups them.
# jq aborted mid-expression in every one, so the recording is of an ENGINE
# message and an engine exit status (5 for a runtime error, 4 for a parse
# error), not of a rule anyone wrote. Reproducing them would mean synthesizing
# an engine error on purpose. Everything NOT in this table must match byte for
# byte, and test_each_excused_case_still_refuses below keeps the excuse honest:
# an excused case may change its wording, never its refusal.
KNOWN_DIVERGENCES = {}
for _label in _labels("status-us-", "counts-us-", "count-pending-us-", "current-story-us-"):
    if not _label.endswith("-vazio"):  # userStories: [] is legal and matches
        KNOWN_DIVERGENCES[_label] = "jq aborted iterating a userStories that is not a list"
for _label in ("meta-string", "meta-array", "meta-numero", "status-meta-string"):
    KNOWN_DIVERGENCES[_label] = "jq aborted indexing a metadata that is not an object"
for _label in _labels("doc-json-array-", "doc-json-numero-", "doc-json-string-"):
    KNOWN_DIVERGENCES[_label] = "jq aborted indexing a document that is not an object"
for _label in ("doc-json-null-status", "doc-json-null-count"):
    KNOWN_DIVERGENCES[_label] = "jq aborted iterating .userStories of a null document"
for _label in ("doc-json-dois-valores-status", "doc-json-dois-valores-count"):
    KNOWN_DIVERGENCES[_label] = "jq aborted once per document and reported both"
for _label in _labels("doc-json-malformado-"):
    KNOWN_DIVERGENCES[_label] = "jq's own parse error, at its own exit 4"
KNOWN_DIVERGENCES["historia-nao-objeto"] = "jq aborted indexing a story that is a string"


# ---------------------------------------------------------------------------
# The port is faithful: the whole corpus, replayed
# ---------------------------------------------------------------------------


def _replay(case, tmp_path):
    """Rebuild the case's project root, run the CLI, and normalize as the capture did."""
    root = os.path.realpath(str(tmp_path))
    tasks_dir = os.path.join(root, ".aimi", "tasks")
    os.makedirs(tasks_dir, exist_ok=True)
    given = case["input"]
    if given["tasks_file"]:
        target = os.path.join(tasks_dir, given["tasks_file"])
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "w", encoding="utf-8") as handle:
            handle.write(given["tasks"])
    for key, value in given["state"].items():
        with open(os.path.join(root, ".aimi", key), "w", encoding="utf-8") as handle:
            handle.write(value + "\n")

    proc = subprocess.run(
        ["bash", CLI] + case["args"], cwd=root, capture_output=True, text=True, timeout=120
    )

    state_after = {}
    aimi = os.path.join(root, ".aimi")
    for name in sorted(os.listdir(aimi)):
        path = os.path.join(aimi, name)
        if os.path.isfile(path):
            with open(path, encoding="utf-8", errors="replace") as handle:
                state_after[name] = handle.read().replace(root, "/TMP")

    return {
        "exit": proc.returncode,
        "stdout": proc.stdout.replace(root, "/TMP"),
        "stderr": proc.stderr.replace(root, "/TMP"),
        "state_after": state_after,
    }


@pytest.mark.parametrize("label", sorted(CASES), ids=sorted(CASES))
def test_the_port_reproduces_the_jq(label, tmp_path):
    case = CASES[label]
    actual = _replay(case, tmp_path)
    if label in KNOWN_DIVERGENCES:
        pytest.skip(KNOWN_DIVERGENCES[label])
    for field in ("exit", "stdout", "stderr", "state_after"):
        assert actual[field] == case[field], label + " . " + field


def test_the_divergence_table_names_only_cases_that_exist():
    """A label that stops existing must not sit here quietly excusing nothing."""
    assert set(KNOWN_DIVERGENCES) <= set(CASES)
    assert len(KNOWN_DIVERGENCES) == 37, "the capture's comment names 37; keep the two in step"


@pytest.mark.parametrize("label", sorted(KNOWN_DIVERGENCES), ids=sorted(KNOWN_DIVERGENCES))
def test_each_excused_case_still_refuses(label, tmp_path):
    """The excuse is only good while the recording still shows an engine abort
    AND the port still refuses.

    Every one of these was recorded with jq's own message on stderr at jq's own
    exit status. If a future capture edit makes one an ordinary refusal, it
    stops belonging in the table. And an excused case must not become a case
    that quietly SUCCEEDS: the wording is allowed to move, the refusal is not.
    """
    recorded = CASES[label]["stderr"]
    assert recorded.startswith(("jq:", "parse error:")), label
    assert CASES[label]["exit"] in (4, 5), label

    actual = _replay(CASES[label], tmp_path)
    assert actual["exit"] != 0, label + ": an excused case still has to refuse"
    assert actual["stdout"] == "", label + ": a refusal writes nothing to stdout"
    assert actual["stderr"].startswith("Error: "), label
    assert actual["state_after"] == CASES[label]["state_after"], label


# ---------------------------------------------------------------------------
# list-ready, next-story: the same evidence, for the predicate
# ---------------------------------------------------------------------------

# The 37 cases `_comment_tasks_ready` names, grouped by the shape jq aborted on.
# Every one of them is an ENGINE message, and they split by verb rather than by
# input: list-ready surfaced jq's abort as its own exit status, while next-story
# swallowed it and answered null, so the -next half of each pair diverges on
# stderr ALONE. test_each_excused_ready_case_keeps_its_answer below asserts that
# split instead of describing it.
READY_DIVERGENCES = {}
_ABORTING = (
    ("depende-string", "jq aborted iterating a dependsOn that is a string"),
    ("depende-numero", "jq aborted iterating a dependsOn that is a number"),
    ("depende-true", "jq aborted taking the length of a boolean dependsOn"),
    ("gate-string", "jq aborted indexing a gate that is a string"),
    ("dep-gate-string", "jq aborted indexing a dependency's gate that is a string"),
    ("historia-string", "jq aborted indexing a story that is a string"),
    ("us-ausente", "jq aborted iterating a userStories that is absent"),
    ("us-null", "jq aborted iterating a userStories that is null"),
    ("us-string", "jq aborted iterating a userStories that is a string"),
    ("doc-null", "jq aborted iterating .userStories of a null document"),
    ("doc-array", "jq aborted indexing a document that is an array"),
    ("doc-malformado", "jq's own parse error, at its own exit 4"),
)
for _stem, _why in _ABORTING:
    for _suffix in ("-ready", "-brief", "-next"):
        READY_DIVERGENCES[_stem + _suffix] = _why
# Its own class: nothing aborted, jq was simply handed an empty filename after
# get_tasks_file had already refused, and complained a second time about it.
READY_DIVERGENCES["sem-arquivo-next"] = (
    "jq's extra complaint about the empty filename it was handed"
)


@pytest.mark.parametrize("label", sorted(READY), ids=sorted(READY))
def test_the_ready_port_reproduces_the_jq(label, tmp_path):
    case = READY[label]
    actual = _replay(case, tmp_path)
    if label in READY_DIVERGENCES:
        pytest.skip(READY_DIVERGENCES[label])
    for field in ("exit", "stdout", "stderr", "state_after"):
        assert actual[field] == case[field], label + " . " + field


def test_the_ready_divergence_table_names_only_cases_that_exist():
    assert set(READY_DIVERGENCES) <= set(READY)
    assert len(READY_DIVERGENCES) == 37, "the capture's comment names 37; keep the two in step"


@pytest.mark.parametrize("label", sorted(READY_DIVERGENCES), ids=sorted(READY_DIVERGENCES))
def test_each_excused_ready_case_keeps_its_answer(label, tmp_path):
    """An excused case may lose the engine's WORDING. It may not lose its answer.

    list-ready refused and still refuses, writing nothing to stdout. next-story
    answered null at exit 0 and still does, down to the state file it cleared --
    which is the half that matters, because /aimi:next reads that null as "all
    stories complete" and stops, so a slice that turned it into a non-zero exit
    would turn a clean stop into a failure.
    """
    recorded = READY[label]
    actual = _replay(recorded, tmp_path)
    assert actual["stderr"] != recorded["stderr"], label + ": excused for a difference it lacks"

    if label.endswith("-next"):
        for field in ("exit", "stdout", "state_after"):
            assert actual[field] == recorded[field], label + " . " + field
        assert actual["stdout"] == "null\n", label
        return

    assert recorded["stderr"].startswith(("jq:", "parse error:")), label
    assert recorded["exit"] in (4, 5), label
    assert actual["exit"] != 0, label + ": an excused case still has to refuse"
    assert actual["stdout"] == "", label + ": a refusal writes nothing to stdout"
    assert actual["stderr"].startswith("Error: "), label
    assert actual["state_after"] == recorded["state_after"], label


def _ready_ids(label):
    """The ids the RECORDING lists as ready. Read off the capture, never
    recomputed -- an anti-vacuum check that asked tasks.py what it thinks would
    be satisfied by any answer it gave."""
    return [story["id"] for story in json.loads(READY[label]["stdout"])]


def _next_id(label):
    chosen = json.loads(READY[label]["stdout"])
    return None if chosen is None else chosen["id"]


def test_the_ready_corpus_exercises_every_case_it_claims_to():
    """Eight buckets, each read out of the recording. A corpus missing any one
    of them would let the replay above pass on nothing -- the comparison is
    only worth what the inputs cover."""
    # 1. a plainly ready story
    assert _ready_ids("pronta-ready") == ["US-001"]
    # 2. a story held by its OWN pending decision gate, with the near misses
    #    that must NOT be held: a decision gate already passed or failed, and a
    #    pending action or verify gate on the story itself.
    assert _ready_ids("gate-decisao-ready") == ["US-00" + n for n in "2345678"]
    # 3. a dependency carrying a pending ACTION gate
    assert _ready_ids("dep-gate-acao-ready") == ["US-004"]
    # 4. a dependency that is not completed and not skipped
    assert _ready_ids("dep-status-ready") == ["US-001", "US-009", "US-010", "US-011"]
    # 5. a dangling dependsOn id, and the ORDER that decides what it does
    assert "US-001" in _ready_ids("dep-pendurada-ready")
    assert _ready_ids("dep-pendurada-antes-ready") == ["US-002", "US-005"]
    # 6. a null priority and an absent one, both ahead of every number
    assert _next_id("prioridade-nula-next") == "US-002"
    assert _next_id("prioridade-ausente-next") == "US-001"
    # 7. a priority tie, broken by tasks.json file order
    assert _ready_ids("empate-ready") == ["US-007", "US-003", "US-009", "US-002"]
    assert _next_id("empate-next") == "US-007"
    # 8. an empty result, from both directions
    assert _ready_ids("vazio-lista-ready") == []
    assert _ready_ids("vazio-nada-pendente-ready") == []
    assert _next_id("vazio-lista-next") is None


def test_the_brief_projection_is_six_keys_whatever_the_story_carries():
    """jq's `{id, title, ...}` emits a key holding null for a field the story
    does not have, so a story with no project and no gate still yields six.
    part1-core asserts the count against the CLI; this asserts it against the
    recording, which is where it was true first."""
    brief = json.loads(READY["pronta-sem-campos-brief"]["stdout"])
    assert [list(row) for row in brief] == [list(T.BRIEF_KEYS)]
    assert brief[0]["project"] is None and brief[0]["gate"] is None
    # and the raw dependsOn, null and all -- the `// []` belongs to the
    # predicate, not to this projection
    assert brief[0]["dependsOn"] is None
    assert json.loads(READY["dep-pendurada-brief"]["stdout"])[0]["dependsOn"] == ["US-999"]


def test_a_dangling_dependency_ends_the_walk_rather_than_merely_not_blocking():
    """THE trap. jq's `all` stops at the first element whose condition selected
    nothing and answers true, so ["US-999", "US-001"] is ready while
    ["US-001", "US-999"] -- same two ids, other order -- is not. A port that
    treated a dangling id as "not blocking" would agree on the first and be
    wrong on the second, dropping a story from a wave that runs today."""
    stories = [
        {"id": "US-001", "status": "pending"},
        {"id": "US-002", "status": "pending", "dependsOn": ["US-999", "US-001"]},
        {"id": "US-003", "status": "pending", "dependsOn": ["US-001", "US-999"]},
    ]
    assert T.is_ready(stories[1], stories) is True
    assert T.is_ready(stories[2], stories) is False
    # and the same rule inside jq_all_over itself, away from the tasks schema
    assert T.jq_all_over(["x", "y"], lambda e: [] if e == "x" else [False]) is True
    assert T.jq_all_over(["y", "x"], lambda e: [] if e == "x" else [False]) is False


def test_every_match_of_a_duplicated_dependency_id_is_checked():
    """`select(.id == $dep_id)` is a filter over a stream, so a tasks file
    carrying an id twice yields two outputs for one dependsOn entry, and either
    of them can block."""
    stories = [
        {"id": "US-001", "status": "completed"},
        {"id": "US-001", "status": "completed", "gate": {"type": "action", "status": "pending"}},
        {"id": "US-002", "status": "pending", "dependsOn": ["US-001"]},
    ]
    assert T.is_ready(stories[2], stories) is False


def test_a_number_and_an_empty_string_have_length_zero_the_way_jq_said_they_did():
    """`.dependsOn // []` leaves 0, "" and {} alone -- none of them is null or
    false -- and all three then have length 0, which short-circuits the whole
    dependency walk. Recorded as depende-formas, where every one of them is a
    story the pre-port CLI listed as ready."""
    assert T.jq_length(0, ".x") == 0
    assert T.jq_length("", ".x") == 0
    assert T.jq_length({}, ".x") == 0
    assert T.jq_length(-3, ".x") == 3
    with pytest.raises(T.MalformedTasks):
        T.jq_length(True, ".x")
    ready = _ready_ids("depende-formas-ready")
    assert ready == ["US-00" + n for n in "1234678"]


def test_the_order_next_story_picks_is_jqs_total_order_and_a_stable_sort():
    """null < false < true < numbers < strings < arrays < objects, and ties keep
    file order. Both halves are recorded; this states them as one table so a
    reader does not have to reconstruct it from six recordings."""
    assert _next_id("ordem-booleana-next") == "US-003"   # false, below 0 and true
    assert _next_id("ordem-numero-next") == "US-003"     # true, below every number
    assert _next_id("ordem-string-next") == "US-002"     # "alta", below an array
    assert _next_id("ordem-array-next") == "US-002"      # [1], below an object
    assert _next_id("ordem-negativa-next") == "US-003"   # -1
    assert _next_id("ordem-float-next") == "US-002"      # 1.0, and printed as 1
    assert '"priority": 1\n' in READY["ordem-float-next"]["stdout"]


VALIDATE_TWINS = ["valida-ausente", "valida-us-string", "valida-doc-malformado"]


@pytest.mark.parametrize("label", VALIDATE_TWINS, ids=VALIDATE_TWINS)
def test_both_validate_story_exists_print_the_same_bytes(label, tmp_path):
    """The one rule this port writes TWICE, and the only reason that is allowed
    is that both copies say the same thing.

    Ten bash call sites outlive the slice that ported list-ready, so the bash
    function stays; a verb already on the Python side needs the same gate
    without going back. A drift of one byte here would surface three slices
    later as a test failure with no obvious cause, so it is asserted against
    the RECORDED jq bytes -- not merely between the two current copies, either
    of which could have moved together.
    """
    recorded = READY[label]
    root = os.path.realpath(str(tmp_path))
    tasks_dir = os.path.join(root, ".aimi", "tasks")
    os.makedirs(tasks_dir, exist_ok=True)
    target = os.path.join(tasks_dir, recorded["input"]["tasks_file"])
    with open(target, "w", encoding="utf-8") as handle:
        handle.write(recorded["input"]["tasks"])

    story_id = recorded["args"][1]
    twin = subprocess.run(
        [sys.executable, os.path.join(SCRIPTS, "tasks.py"), "validate-story-exists",
         "--tasks-file", target, "--story-id", story_id],
        capture_output=True, text=True,
    )
    bash = _replay(recorded, tmp_path)

    expected = "Error: Story " + story_id + " not found in /TMP/.aimi/tasks/" \
        + recorded["input"]["tasks_file"] + "\n"
    assert recorded["stderr"] == expected, "the recorded jq bytes"
    assert bash["stderr"] == expected, "the bash gate, which this slice keeps"
    assert twin.stderr.replace(root, "/TMP") == expected, "the Python twin"
    assert recorded["exit"] == bash["exit"] == twin.returncode == 1
    assert twin.stdout == ""


def test_the_twin_stays_quiet_when_the_story_is_there(tmp_path):
    """A gate that refused EVERYTHING would pass the test above and break every
    caller, so the passing side is asserted too -- silent, at exit 0, on the
    same corpus file."""
    recorded = READY["valida-existe"]
    assert recorded["exit"] == 0, "the bash side, recorded"
    target = os.path.join(str(tmp_path), recorded["input"]["tasks_file"])
    with open(target, "w", encoding="utf-8") as handle:
        handle.write(recorded["input"]["tasks"])
    twin = subprocess.run(
        [sys.executable, os.path.join(SCRIPTS, "tasks.py"), "validate-story-exists",
         "--tasks-file", target, "--story-id", "US-001"],
        capture_output=True, text=True,
    )
    assert (twin.returncode, twin.stdout, twin.stderr) == (0, "", "")


def test_get_story_is_the_verb_the_bash_gate_kept_identical():
    """validate_story_exists stayed in bash, so get-story refuses a broken
    userStories with its OWN message where the other four hit jq's engine. All
    five of its us-* cases are outside the divergence table on purpose."""
    for label in _labels("get-story-us-"):
        assert label not in KNOWN_DIVERGENCES, label
        assert CASES[label]["exit"] == 1
        assert "not found in" in CASES[label]["stderr"]


# ---------------------------------------------------------------------------
# The seven locked writers: the same evidence, plus the document they left
# ---------------------------------------------------------------------------

WRITE_FIELDS = ("exit", "stdout", "stderr", "file", "tree", "state_after")

_TEMP_SUFFIX = re.compile(r"^(?P<stem>.*-tasks\.json)\.[A-Za-z0-9]{6}$")
_BASH_LINE = re.compile(r"(aimi-cli\.sh): line \d+:")


def _replay_write(case, tmp_path):
    """Like _replay, and separate from it on purpose.

    Two of these cases hand the verb a .lock that is a DIRECTORY, so bash's own
    `200>` redirect fails and reports the offending line of aimi-cli.sh. That
    message carries an absolute path and a line number, neither of which is a
    property of the verb -- the capture normalized both and so does this. The
    read blocks never produce either, and rewriting their helper to handle
    something they cannot emit would only put a comparison of 279 passing cases
    at risk.
    """
    root = os.path.realpath(str(tmp_path))
    given = case["input"]
    os.makedirs(os.path.join(root, ".aimi", "tasks"), exist_ok=True)
    for extra in given["dirs"]:
        os.makedirs(os.path.join(root, extra), exist_ok=True)
    target = None
    if given["tasks_file"]:
        target = os.path.join(root, ".aimi", "tasks", given["tasks_file"])
        with open(target, "w", encoding="utf-8") as handle:
            handle.write(given["tasks"])
    for key, value in given["state"].items():
        with open(os.path.join(root, ".aimi", key), "w", encoding="utf-8") as handle:
            handle.write(value + "\n")

    proc = subprocess.run(
        ["bash", CLI] + case["args"], cwd=root, capture_output=True, text=True, timeout=120
    )

    def normalize(text):
        text = text.replace(root, "/TMP").replace(CLI, "/CLI/aimi-cli.sh")
        return _BASH_LINE.sub(r"\1: line <N>:", text)

    contents = None
    if target and os.path.isfile(target):
        with open(target, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
        try:
            contents = json.loads(text)
        except ValueError:
            contents = text.replace(root, "/TMP")

    aimi = os.path.join(root, ".aimi")
    state_after = {}
    for name in sorted(os.listdir(aimi)):
        path = os.path.join(aimi, name)
        if os.path.isfile(path):
            with open(path, encoding="utf-8", errors="replace") as handle:
                state_after[name] = handle.read().replace(root, "/TMP")

    tree = []
    for dirpath, dirnames, filenames in os.walk(aimi):
        dirnames.sort()
        for name in sorted(dirnames):
            tree.append(os.path.relpath(os.path.join(dirpath, name), root) + "/")
        for name in sorted(filenames):
            rel = os.path.relpath(os.path.join(dirpath, name), root)
            match = _TEMP_SUFFIX.match(rel)
            tree.append(match.group("stem") + ".XXXXXX" if match else rel)

    return {
        "exit": proc.returncode,
        "stdout": normalize(proc.stdout),
        "stderr": normalize(proc.stderr),
        "file": contents,
        "tree": sorted(tree),
        "state_after": state_after,
    }


# The 8 cases `_comment_tasks_write` names, in the two classes it groups them
# by. Neither class is a rule anyone wrote: one is jq's engine message at jq's
# own exit status, the other is a temp file the pre-port bash created and, under
# `set -euo pipefail`, aborted before removing. Every field NOT listed here must
# match byte for byte, which is why the excuse is per-field rather than
# per-case: an excused case still has to agree about the document it left.
WRITE_DIVERGENCES = {}
for _label in (
    "mark-complete-lock-inutilizavel",
    "update-field-lock-inutilizavel",
    "normalize-status-lock-inutilizavel",
):
    WRITE_DIVERGENCES[_label] = ("tree",)
for _label in (
    "update-field-intermediario-nao-objeto",
    "normalize-status-historia-string",
    "normalize-status-sem-userstories",
    "normalize-verification-historia-string",
    "normalize-verification-sem-userstories",
):
    WRITE_DIVERGENCES[_label] = ("exit", "stderr", "tree")


@pytest.mark.parametrize("label", sorted(WRITE), ids=sorted(WRITE))
def test_the_write_port_reproduces_the_jq(label, tmp_path):
    case = WRITE[label]
    actual = _replay_write(case, tmp_path)
    excused = WRITE_DIVERGENCES.get(label, ())
    for field in WRITE_FIELDS:
        if field in excused:
            continue
        assert actual[field] == case[field], label + " . " + field


def test_the_write_divergence_table_names_only_cases_that_exist():
    assert set(WRITE_DIVERGENCES) <= set(WRITE)
    assert len(WRITE_DIVERGENCES) == 8, "the capture's comment names 8; keep the two in step"


@pytest.mark.parametrize("label", sorted(WRITE_DIVERGENCES), ids=sorted(WRITE_DIVERGENCES))
def test_each_excused_write_case_still_refuses_and_writes_nothing(label, tmp_path):
    """An excused case may lose jq's wording, its exit status and its litter.
    It may not gain a side effect.

    All eight are refusals, and what makes them safe to excuse is that the
    document survives them untouched -- which is compared above, because `file`
    is never in the excused list for any of them.
    """
    recorded = WRITE[label]
    assert recorded["exit"] != 0, label
    assert recorded["stdout"] == "", label
    actual = _replay_write(recorded, tmp_path)
    assert actual["exit"] != 0, label + ": an excused case still has to refuse"
    assert actual["stdout"] == "", label + ": a refusal writes nothing to stdout"
    assert actual["file"] == recorded["file"], label + ": and leaves the document alone"


def test_no_ported_case_leaves_a_temp_file_behind(tmp_path):
    """The property the tree field exists for, on every path the corpus walks.

    jq's own recording fails this in the five aborts and the three unusable
    locks -- bash had already run `mktemp` and `set -e` ended the script before
    the `rm -f`. tasks.py owns the temp file now and unlinks it inside its own
    `except`, so the answer is uniform: success, refusal or mid-write failure,
    nothing named `<tasks>.XXXXXX` is left in the directory.
    """
    leaked = []
    for label, case in sorted(WRITE.items()):
        if not any(entry.endswith(".XXXXXX") for entry in case["tree"]):
            continue
        actual = _replay_write(case, tmp_path / label.replace("/", "_"))
        leaked += [label for entry in actual["tree"] if entry.endswith(".XXXXXX")]
    assert leaked == []
    # and the recording really did carry them, so the check above is not vacuous
    assert sum(
        any(e.endswith(".XXXXXX") for e in c["tree"]) for c in WRITE.values()
    ) == len(WRITE_DIVERGENCES)


def test_the_write_corpus_exercises_every_case_it_claims_to():
    """Seven buckets, each read off the RECORDING rather than recomputed. A
    corpus missing any one of them would let the replay above pass on nothing."""
    # 1. a successful mark, and the state files that go with it
    assert WRITE["mark-complete-sucesso"]["file"]["userStories"][0]["status"] == "completed"
    assert WRITE["mark-complete-sucesso"]["state_after"]["last-result"] == "success\n"
    # 2. a mark on a story that is not there: the message, and NO side effect
    refused = WRITE["mark-complete-inexistente"]
    assert refused["stderr"].endswith("Error: Story US-999 not found in /TMP/.aimi/tasks/"
                                      "2020-01-01-corpus-tasks.json\n")
    assert refused["file"] == json.loads(refused["input"]["tasks"])
    assert refused["state_after"] == {} and refused["tree"] == [
        ".aimi/tasks/",
        ".aimi/tasks/2020-01-01-corpus-tasks.json",
    ]
    # 3. a mark on a story ALREADY in that status: a no-op that still reports
    for verb, status in T.MARK_STATUS.items():
        case = WRITE[verb + "-ja-nesse-status"]
        assert case["exit"] == 0 and case["file"]["userStories"][0]["status"] == status
    # 4. normalize-status where stories lack the field, plus the shapes `//`
    #    does and does not replace
    healed = WRITE["normalize-status-sucesso"]["file"]["userStories"]
    assert [s.get("status") for s in healed] == ["pending", "completed", "pending", "pending", ""]
    assert json.loads(WRITE["normalize-status-sucesso"]["stdout"]) == {"normalized": 5}
    # 5. normalize-verification against the string-typed shape it exists to migrate
    migrated = WRITE["normalize-verification-formas"]["file"]["userStories"]
    assert migrated[0]["verification"] == {
        "strategy": "manual",
        "status": "pending",
        "url": None,
        "expect": None,
    }
    assert migrated[4]["verification"]["strategy"] == "", "the empty string migrates too"
    assert migrated[2]["verification"] is None and "verification" not in migrated[1]
    assert [migrated[5]["verification"], migrated[6]["verification"]] == [5, []]
    # 6. each normalizer over an already-normalized file: unchanged, still counted
    for label in ("normalize-status-ja-normalizado", "normalize-verification-ja-normalizado"):
        assert WRITE[label]["file"] == json.loads(WRITE[label]["input"]["tasks"])
    assert json.loads(WRITE["normalize-status-ja-normalizado"]["stdout"]) == {"normalized": 2}
    assert json.loads(WRITE["normalize-verification-ja-normalizado"]["stdout"]) == {"normalized": 1}
    # 7. update-field's four jq semantics, each its own recorded case
    assert json.loads(WRITE["update-field-valor-numerico-fica-string"]["stdout"])["priority"] == "3"
    assert WRITE["update-field-cria-intermediarios"]["file"]["userStories"][0]["novo"] == {
        "ramo": {"folha": "valor"}
    }
    assert WRITE["update-field-intermediario-nao-objeto"]["exit"] != 0
    assert WRITE["update-field-caminho-jq"]["stderr"].startswith("Error: Invalid field path: ")


def test_the_field_path_refusal_is_the_gate_outline_01_put_in_bash():
    """01's message, byte for byte, and still coming from bash: tasks.py never
    sees a path that failed it, and does not re-validate the ones that pass --
    there is no jq program left to inject into."""
    expected = (
        "Error: Invalid field path: %s (expected dotted identifiers, "
        "e.g. verification.status)\n"
    )
    for label, given in (
        ("update-field-caminho-jq", "verification.status) | .metadata"),
        ("update-field-caminho-traversal", "../notes"),
        ("update-field-caminho-espaco", "a b"),
        ("update-field-caminho-indice", "acceptanceCriteria[0]"),
    ):
        assert WRITE[label]["stderr"] == expected % given, label
        assert WRITE[label]["exit"] == 1 and WRITE[label]["stdout"] == ""
    body = _body()
    assert "Invalid field path" not in body, "the refusal has exactly one home, and it is bash"


def test_the_payload_emits_null_for_a_top_level_key_the_story_does_not_have():
    """jq's `{id, <top>}` shorthand, which the echo-back could not actually
    reach: with `set -euo pipefail` a failed write ended the script before the
    second jq ran, so every RECORDED payload names a key the assignment had just
    created. The branch is still in the projection, and this is what it does."""
    doc = {"userStories": [{"id": "US-001"}]}
    assert T.field_payload(doc, "US-001", "verification") == [
        {"id": "US-001", "verification": None}
    ]


def test_a_dotted_assignment_builds_its_intermediates_and_refuses_to_walk_a_string():
    """Both halves of jq_setpath, away from the corpus: null and absent
    intermediates are created as objects, a non-object one is a refusal that
    returns no document at all -- so nothing half-assigned can reach the write.
    """
    assert T.jq_setpath({"id": "US-001"}, ["a", "b"], "v", T.STORY) == {
        "id": "US-001",
        "a": {"b": "v"},
    }
    assert T.jq_setpath({"a": None}, ["a", "b"], "v", T.STORY) == {"a": {"b": "v"}}
    assert T.jq_setpath(None, ["a"], "v", T.STORY) == {"a": "v"}
    with pytest.raises(T.MalformedTasks):
        T.jq_setpath({"a": "texto"}, ["a", "b"], "v", T.STORY)
    # an existing key keeps its position; a new one is appended
    assert list(T.jq_setpath({"a": 1, "b": 2}, ["a"], "v", T.STORY)) == ["a", "b"]
    assert list(T.jq_setpath({"a": 1}, ["z"], "v", T.STORY)) == ["a", "z"]


def test_map_yields_an_array_whatever_userstories_was():
    """jq's `map` over an object gives a LIST, so both normalizers turn a
    userStories object into an array while the mark-* verbs -- which update
    through a path expression, not map -- leave it an object. Both shapes are
    recorded; this is the rule they come from."""
    assert WRITE["normalize-status-us-objeto"]["file"]["userStories"] == [
        {"id": "US-001", "title": "Story 1", "status": "pending"},
        {"id": "US-002", "title": "Story 2", "status": "pending"},
    ]
    assert isinstance(WRITE["mark-complete-us-objeto"]["file"]["userStories"], dict)


def test_every_match_of_a_duplicated_story_id_is_written_and_echoed():
    """`(.userStories[] | select(.id == $id)) |= f` is a filter over a stream,
    not a lookup: a tasks file carrying the same id twice had BOTH stories
    marked, and update-field printed its payload twice."""
    marked = WRITE["mark-complete-id-duplicado"]["file"]["userStories"]
    assert [s["status"] for s in marked] == ["completed", "pending", "completed"]
    assert WRITE["update-field-id-duplicado"]["stdout"].count('"id": "US-001"') == 2


def test_the_writer_gives_every_document_in_the_file_back():
    """jq read a STREAM and wrote one, so a tasks file holding two concatenated
    documents came back with both of them rewritten. It is why the writer here
    is write_docs_atomically and not roadmap.py's single-value one."""
    written = WRITE["mark-complete-dois-documentos"]["file"]
    assert isinstance(written, str), "two documents do not parse as one"
    assert written.count('"status": "completed"') == 4, "US-001 and US-002, twice over"


def test_a_number_written_back_is_rendered_the_way_jq_rendered_it():
    """The corpus carries `"priority": 3.0`, and every verb that rewrites the
    file printed it as 3. Python would write 3.0 without jq_numbers, and the
    difference would land in a file /aimi:execute reads after every story."""
    assert WRITE["mark-complete-sucesso"]["file"]["userStories"][2]["priority"] == 3
    assert '"priority": 3.0' not in json.dumps(WRITE["normalize-status-corpus"]["file"])


# ---------------------------------------------------------------------------
# The four validators: a verdict and an exit status, over an adversarial corpus
# ---------------------------------------------------------------------------

# The 39 cases `_comment_tasks_validate` names, in the ten groups the engine's
# own messages fall into. Every one is jq aborting mid-expression, so what was
# recorded is an ENGINE message at an engine exit status (5 runtime, 4 parse),
# not a rule anyone wrote. Everything NOT in this table must match byte for byte.
VALIDATE_DIVERGENCES = {}
for _verb in ("deps", "stories", "ids", "waves"):
    for _stem in ("sem-userstories", "us-null", "us-string"):
        VALIDATE_DIVERGENCES[_stem + "-" + _verb] = (
            "jq aborted iterating a userStories that is absent, null or a string"
        )
    VALIDATE_DIVERGENCES["doc-array-" + _verb] = "jq aborted indexing a document that is an array"
    VALIDATE_DIVERGENCES["doc-malformado-" + _verb] = "jq's own parse error, at its own exit 4"
for _label in ("sem-criterios-stories", "criterios-null-stories"):
    VALIDATE_DIVERGENCES[_label] = "jq aborted iterating an acceptanceCriteria that is not a list"
for _label in ("deps-numero-deps", "deps-numero-waves"):
    VALIDATE_DIVERGENCES[_label] = "jq aborted iterating a dependsOn that is a number"
for _label in ("historia-string-deps", "historia-string-ids", "historia-string-waves"):
    VALIDATE_DIVERGENCES[_label] = "jq aborted indexing a story that is a string"
for _label in ("historia-string-stories", "gate-nao-objeto-stories"):
    VALIDATE_DIVERGENCES[_label] = "jq aborted asking whether a string has a key"
for _label in (
    "historia-null-stories", "titulo-null-stories",
    "projeto-numero-stories", "skills-elemento-numero-stories",
):
    VALIDATE_DIVERGENCES[_label] = "jq aborted matching a value that is not a string"
# validate-waves' alone: it builds `{(.id): ...}` before anything else runs, so
# an id that cannot be an object key kills that verb where the other three answer.
for _label in (
    "historia-null-waves", "id-ausente-waves", "id-numero-waves", "id-array-waves",
):
    VALIDATE_DIVERGENCES[_label] = "jq aborted using an id that is not a string as an object key"
for _label in ("deps-heterogeneo-waves", "deps-array-elemento-waves"):
    VALIDATE_DIVERGENCES[_label] = "jq aborted asking whether an object has a non-string key"


@pytest.mark.parametrize("label", sorted(VALIDATE), ids=sorted(VALIDATE))
def test_the_validate_port_reproduces_the_jq(label, tmp_path):
    case = VALIDATE[label]
    actual = _replay(case, tmp_path)
    if label in VALIDATE_DIVERGENCES:
        pytest.skip(VALIDATE_DIVERGENCES[label])
    for field in ("exit", "stdout", "stderr", "state_after"):
        assert actual[field] == case[field], label + " . " + field


def test_the_validate_divergence_table_names_only_cases_that_exist():
    assert set(VALIDATE_DIVERGENCES) <= set(VALIDATE)
    assert len(VALIDATE_DIVERGENCES) == 39, "the capture's comment names 39; keep the two in step"


@pytest.mark.parametrize(
    "label", sorted(VALIDATE_DIVERGENCES), ids=sorted(VALIDATE_DIVERGENCES)
)
def test_each_excused_validate_case_still_refuses(label, tmp_path):
    """The excuse buys the engine's wording and its exit number. Nothing else.

    All 39 are refusals that wrote nothing to stdout, and an excused case must
    not become one that quietly answers: a validator that started printing
    `{valid: true}` for a document jq refused would hand /aimi:plan a pass it
    never earned.
    """
    recorded = VALIDATE[label]
    assert recorded["stderr"].startswith(("jq:", "parse error:")), label
    assert recorded["exit"] in (4, 5), label
    assert recorded["stdout"] == "", label

    actual = _replay(recorded, tmp_path)
    assert actual["exit"] != 0, label + ": an excused case still has to refuse"
    assert actual["stdout"] == "", label + ": a refusal writes nothing to stdout"
    assert actual["stderr"].startswith("Error: "), label
    assert actual["state_after"] == recorded["state_after"], label


def _verdict(label):
    """The verdict the RECORDING holds. Read off the capture, never recomputed --
    an anti-vacuum check that asked tasks.py what it thinks would be satisfied by
    any answer it gave."""
    return json.loads(VALIDATE[label]["stdout"])


def _errors(label):
    return _verdict(label)["errors"]


def test_no_validator_writes_anything_on_any_path_the_corpus_walks():
    """The property this block exists for, over all 328 recordings at once.

    These four take no lock, and the only thing that makes that safe is that
    they write nothing at all. `state_after` is empty in every case -- pass,
    refusal and engine abort alike -- so a validator that grew a cache, a temp
    file or a state write would fail here rather than in whatever ran next.
    """
    assert len(VALIDATE) == 328
    assert all(case["state_after"] == {} for case in VALIDATE.values())
    body = _code()
    for op in ("op_validate_deps", "op_validate_stories", "op_validate_ids", "op_validate_waves"):
        assert op in body
        assert "write_docs_atomically" not in body.split("def " + op, 1)[1].split("\ndef ", 1)[0]


def test_the_validate_corpus_exercises_every_error_class_each_verb_can_emit():
    """Eleven buckets, each read off the RECORDING. A corpus that only ever
    passed would let the replay above pass on nothing, and these four verbs
    exist precisely to fail on bad input."""
    # 1. validate-deps: a dangling reference, a self-reference, a cycle
    assert _errors("dep-pendurada-deps") == [
        "Missing ID: US-001 depends on US-999 which does not exist"
    ]
    assert _errors("auto-referencia-deps") == [
        "Self-reference: US-001 depends on itself",
        "Circular dependency: US-001 is part of a dependency cycle",
    ]
    assert _errors("ciclo-deps") == [
        "Circular dependency: US-001 is part of a dependency cycle",
        "Circular dependency: US-002 is part of a dependency cycle",
    ]
    # 2. validate-ids: a malformed id, in file order, with the documented wording
    assert _errors("id-malformado-ids") == [
        "Invalid story ID: " + bad + " (expected US-NNN)"
        for bad in ("us-002", "US-3", "US-0001", "US-001A", "US-001 ")
    ]
    # 3. validate-waves: a stale wave, and an absent one. Both fixtures store the
    #    OLD 0-based waves throughout, so under the 1-based convention their root
    #    is reported as well -- the SECOND line of each is the class this bucket
    #    is for, and the first is the convention correction showing its work.
    assert _errors("wave-lacuna-waves") == [
        "Wave mismatch: US-001 stored=0 computed=1",
        "Wave mismatch: US-002 stored=5 computed=2",
    ]
    assert _errors("wave-ausente-waves") == [
        "Wave mismatch: US-001 stored=0 computed=1",
        "Wave mismatch: US-002 stored=null computed=2",
    ]
    # 4. a story missing a required field
    assert _errors("sem-status-stories") == [
        "US-001: missing required field: status — run normalize-status to fix"
    ]
    # 5. skills over 10 entries, and 6. an explicitly empty skills array, which is legal
    assert _errors("skills-excede-stories") == ["US-001: skills array exceeds 10 entries"]
    assert _verdict("skills-vazio-stories")["valid"] is True
    # 7. the plural `gates` field -- and NO quotes around either word, because the
    #    jq lived in a bash single-quoted string and the ones the author typed
    #    closed and reopened it. This is the string /aimi:plan matches on.
    assert _errors("gates-plural-stories") == [
        "US-001: gate: gates field is invalid; use singular gate (see plan.md L687-692)"
    ]
    # 8. a gate object missing each of type, status and prompt IN TURN
    for key in ("type", "status", "prompt"):
        assert _errors("gate-sem-" + key + "-stories") == [
            "US-001: gate: missing required field " + key
        ]
    assert _errors("gate-sem-nada-stories") == [
        "US-001: gate: missing required field " + key for key in ("type", "status", "prompt")
    ]
    # 9. a bare-string verification, em dash and all
    assert _errors("verificacao-string-stories") == [
        "US-001: verification must be an object {strategy, status, url, expect}; "
        "found bare string — run normalize-verification to fix"
    ]
    # 10. every remaining validate-stories string, one document each, so no rule
    #     in that verb rests on the replay alone
    for label, expected in (
        ("titulo-longo", "title exceeds 200 chars"),
        ("descricao-longa", "description exceeds 500 chars"),
        ("criterio-longo", "acceptance criterion exceeds 5000 chars"),
        ("titulo-suspeito", "title contains suspicious content"),
        ("descricao-suspeita", "description contains suspicious content"),
        ("projeto-absoluto", "project must not be an absolute path"),
        ("projeto-traversal", "project must not contain path traversal (..)"),
        ("projeto-metachar", "project contains shell metacharacters"),
        ("projeto-invalido", "project contains invalid characters"),
        ("skills-nao-array", "skills must be an array"),
        ("skills-duplicado", "skills contains duplicate entry a"),
        ("tasks-nao-array", "tasks must be an array"),
        ("tasks-vazio", "tasks must be omitted when empty"),
        ("tasks-excede", "tasks array exceeds 50 entries"),
        ("tasks-longo", "tasks[] entry exceeds 5000 chars"),
        ("tasks-suspeito", "tasks[] entry contains suspicious content"),
    ):
        assert _errors(label + "-stories") == ["US-001: " + expected], label
    assert _errors("skills-caminho-stories") == [
        "US-001: skills[a/b] contains invalid characters",
        "US-001: skills[a/b] must not contain path components",
    ]
    assert _errors("tasks-elemento-nao-string-stories") == [
        "US-001: tasks[] element must be a string"
    ] * 2
    # 11. and a PASS for each of the four, so none of them is merely a refuser.
    #     `limpo` stores the OLD 0-based 0/1/2, so it is the three siblings that
    #     still pass it; validate-waves' pass is now the case the capture named
    #     for the disagreement itself -- wave-um-em-vez-de-zero stores 1 on a
    #     root, which is exactly what the writer produces.
    for verb in ("deps", "stories", "ids"):
        assert _verdict("limpo-" + verb)["valid"] is True
        assert VALIDATE["limpo-" + verb]["exit"] == 0
    assert _verdict("wave-um-em-vez-de-zero-waves") == {"valid": True, "errors": []}
    assert VALIDATE["wave-um-em-vez-de-zero-waves"]["exit"] == 0
    assert _verdict("limpo-waves")["valid"] is False, "0/1/2 is the old convention"


def _story(project=None, verify=None):
    story = {
        "id": "US-001",
        "title": "t",
        "description": "d",
        "acceptanceCriteria": ["x"],
        "status": "pending",
        "priority": 1,
        "dependsOn": [],
        "wave": 0,
    }
    if project is not None:
        story["project"] = project
    if verify is not None:
        story["implementation"] = {"verify": verify}
    return story


def test_validate_ids_keeps_its_asymmetric_shape_and_its_accepted_suffix():
    """THE two traps of the verb that had zero assertions before outline:02.

    The pass branch carries `count` and no `errors`; the failure branch carries
    `errors` and no `count`. And the regex accepts a lowercase suffix while the
    message says `(expected US-NNN)` -- the regex is the contract and the
    message describes the common case, so neither may move to agree with the
    other: /aimi:plan matches on that wording.
    """
    passed = _verdict("id-sufixo-ids")
    assert passed == {"valid": True, "count": 3} and "errors" not in passed
    assert VALIDATE["id-sufixo-ids"]["exit"] == 0, "US-001a and US-012a are ACCEPTED"
    failed = _verdict("id-malformado-ids")
    assert set(failed) == {"valid", "errors"} and "count" not in failed
    assert VALIDATE["id-malformado-ids"]["exit"] == 1
    # an empty userStories still answers with a count, not with an error list
    assert _verdict("vazio-ids") == {"valid": True, "count": 0}
    # and a story with no id reaches the regex as the four characters `null`,
    # because `jq -r` rendered it that way before bash ever saw it
    assert _errors("id-ausente-ids") == ["Invalid story ID: null (expected US-NNN)"]
    assert T.STORY_ID_PATTERN == "^US-[0-9]{3}[a-z]?$", "the bash regex, verbatim"


def test_validate_waves_exits_zero_even_when_the_verdict_is_invalid():
    """The one sibling with no `return 1`, pinned so it cannot be tidied.

    cmd_validate_waves' bash body ended at its jq call, so the verdict has
    always lived in `.valid` and never in `$?`. A caller branching on the exit
    status sees a pass today; "fixing" that would break it silently.
    """
    for label in ("wave-lacuna-waves", "wave-ausente-waves", "wave-string-waves",
                  "wave-true-waves", "wave-false-waves"):
        assert _verdict(label)["valid"] is False, label
        assert VALIDATE[label]["exit"] == 0, label + ": an invalid verdict still exits 0"
    # and its three siblings do the opposite, so the asymmetry is deliberate
    for label in ("ciclo-deps", "sem-status-stories", "id-malformado-ids"):
        assert VALIDATE[label]["exit"] == 1, label


def test_a_duplicated_story_id_is_flagged_by_none_of_the_four():
    """Recorded as the deliberate pass it is, not as an oversight.

    validate-ids checks FORMAT and validate-deps checks REFERENCES; neither
    looks for a repeated id, and validate-stories and validate-waves have no
    opinion either. Pinning the pass means a later change that starts flagging
    it shows up as a golden diff rather than as a silent contract change.
    """
    for verb in ("deps", "stories", "ids"):
        assert _verdict("id-duplicado-" + verb)["valid"] is True, verb
        assert VALIDATE["id-duplicado-" + verb]["exit"] == 0, verb
    assert _verdict("id-duplicado-ids")["count"] == 2, "both copies are counted"
    # validate-waves has no opinion on the duplication either. Its fixture stores
    # the old 0-based wave, so what it reports is the SAME wave mismatch twice,
    # once per copy -- not a word about the id being repeated, which is the
    # property this test is about.
    assert _errors("id-duplicado-waves") == ["Wave mismatch: US-001 stored=0 computed=1"] * 2
    assert VALIDATE["id-duplicado-waves"]["exit"] == 0


def test_a_cycle_and_a_dangling_id_hide_their_story_from_validate_waves():
    """Two more recorded passes that read like misses and are the contract.

    A story the wave walk never places has a computed wave of null, and both
    arms of the select require a non-null one -- so neither the cyclic story nor
    the one with the dangling dependsOn is ever reported here. Reporting them is
    validate-deps' job, and it does.

    The property is per-STORY, and the 1-based correction is what made that
    visible: wave-ciclo places NO story, so its whole document still passes,
    while dep-pendurada holds a second story -- a root storing the old 0-based
    0 -- which is now reported. US-001, the one with the dangling reference, is
    still absent from the list, and that absence is the assertion.
    """
    assert _verdict("wave-ciclo-waves") == {"valid": True, "errors": []}
    assert _errors("dep-pendurada-waves") == ["Wave mismatch: US-002 stored=0 computed=1"]
    assert not any("US-001" in error for error in _errors("dep-pendurada-waves"))
    assert _verdict("wave-ciclo-deps")["valid"] is False
    assert _verdict("dep-pendurada-deps")["valid"] is False


# ---------------------------------------------------------------------------
# The wave convention itself: 1-based, and the same 1-based as the writer's
# ---------------------------------------------------------------------------
#
# The recordings above pin the MESSAGES. These pin the RULE, against documents
# written here rather than replayed, because the corpus was captured while the
# validator still seeded roots at 0 and no recording in it can state what the
# convention ought to be. They discriminate, and that is checked rather than
# claimed: with the seed flipped back to 0 in a throwaway copy of scripts/, ALL
# SIX of them fail. None of them passes by accident.


def _waves_doc(stories):
    return json.dumps(
        {
            "schemaVersion": "3.3",
            "metadata": {
                "title": "ref: waves",
                "type": "ref",
                "branchName": "ref/waves",
                "createdAt": "2020-01-01",
                "planPath": None,
            },
            "userStories": stories,
        },
        indent=2,
    ) + "\n"


def _wave_story(story_id, depends_on, wave="omit"):
    story = {
        "id": story_id,
        "title": "Story " + story_id,
        "description": "As a user, I want " + story_id + ".",
        "acceptanceCriteria": ["Typecheck passes"],
        "status": "pending",
        "priority": 1,
        "dependsOn": depends_on,
    }
    if wave != "omit":
        story["wave"] = wave
    return story


def _run_validate_waves(tmp_path, stories):
    """One live validate-waves over a document written for the occasion."""
    root = os.path.realpath(str(tmp_path))
    tasks_dir = os.path.join(root, ".aimi", "tasks")
    os.makedirs(tasks_dir, exist_ok=True)
    with open(os.path.join(tasks_dir, "2020-01-01-waves-tasks.json"), "w", encoding="utf-8") as fh:
        fh.write(_waves_doc(stories))
    proc = subprocess.run(
        ["bash", CLI, "validate-waves"], cwd=root, capture_output=True, text=True, timeout=120
    )
    return proc, json.loads(proc.stdout)


def test_computed_waves_numbers_roots_from_one_and_climbs_from_there():
    """The rule this story corrected, stated three ways.

    A story with no dependencies is wave 1, never 0; everyone else is one above
    the max of its dependencies. tasks.py used to seed roots at 0 while
    story_merge.py -- the WRITER -- seeded them at 1, so validate-waves reported
    a mismatch on every story of every file the writer produced.
    """
    roots_only = [_wave_story("US-00" + str(n), []) for n in (1, 2, 3)]
    assert T.computed_waves(roots_only) == {"US-001": 1, "US-002": 1, "US-003": 1}

    chain = [
        _wave_story("US-001", []),
        _wave_story("US-002", ["US-001"]),
        _wave_story("US-003", ["US-002"]),
    ]
    assert T.computed_waves(chain) == {"US-001": 1, "US-002": 2, "US-003": 3}

    diamond = [
        _wave_story("US-001", []),
        _wave_story("US-002", ["US-001"]),
        _wave_story("US-003", ["US-001"]),
        _wave_story("US-004", ["US-002", "US-003"]),
    ]
    assert T.computed_waves(diamond) == {
        "US-001": 1, "US-002": 2, "US-003": 2, "US-004": 3
    }


def test_the_validator_and_the_writer_now_number_the_same_document_alike():
    """The defect was a disagreement between two components, so this is the
    assertion that closes it: story_merge.compute_waves WRITES the field and
    tasks.py's computed_waves CHECKS it, and they must agree on every shape --
    a root, a chain, a diamond and a fan-out at once."""
    import story_merge as SM

    shapes = [
        ("US-001", []), ("US-002", ["US-001"]), ("US-003", ["US-001"]),
        ("US-004", ["US-002", "US-003"]), ("US-005", []), ("US-006", ["US-004"]),
    ]
    written = [{"id": sid, "dependsOn": deps} for sid, deps in shapes]
    SM.compute_waves(written)
    assert T.computed_waves([_wave_story(sid, deps) for sid, deps in shapes]) == {
        story["id"]: story["wave"] for story in written
    }


def test_a_story_the_walk_never_reaches_is_still_skipped_entirely(tmp_path):
    """The predicate's shape, unchanged by the reseeding.

    Neither story in a cycle is ever assigned, so neither can be reported; the
    story with the dangling dependsOn is not assigned either, while the root
    beside it is. What survives the correction is that an UNREACHED story
    contributes nothing at all -- not a `stored=X computed=null` line.
    """
    cycle = [_wave_story("US-001", ["US-002"]), _wave_story("US-002", ["US-001"])]
    assert T.computed_waves(cycle) == {}
    proc, verdict = _run_validate_waves(tmp_path, cycle)
    assert verdict == {"valid": True, "errors": []} and proc.returncode == 0

    dangling = [_wave_story("US-001", ["US-999"], 7), _wave_story("US-002", [], 1)]
    assert T.computed_waves(dangling) == {"US-002": 1}
    _, verdict = _run_validate_waves(tmp_path, dangling)
    assert verdict == {"valid": True, "errors": []}, "US-001's stored 7 is not reported"


def test_a_document_with_no_wave_field_at_all_is_reported_against_its_computed_one(tmp_path):
    """An absent stored wave still reads as null and is still a mismatch.

    This is the other half of the predicate the correction had to leave alone:
    the story is skipped only when the WALK never reached it, never because the
    document happens to carry no wave.
    """
    stories = [_wave_story("US-001", []), _wave_story("US-002", ["US-001"])]
    assert all("wave" not in story for story in stories)
    proc, verdict = _run_validate_waves(tmp_path, stories)
    assert verdict == {
        "valid": False,
        "errors": [
            "Wave mismatch: US-001 stored=null computed=1",
            "Wave mismatch: US-002 stored=null computed=2",
        ],
    }
    assert proc.returncode == 0


def test_validate_waves_still_exits_zero_on_a_live_invalid_verdict(tmp_path):
    """Pinned against a document written now, not only against the recordings.

    op_validate_waves has no `return 1` and must not grow one: the verdict lives
    in `.valid` and a caller branching on `$?` sees a pass today. A document
    carrying the OLD 0-based waves is the sharpest fixture for it, because it is
    exactly what this change made invalid.
    """
    old_convention = [_wave_story("US-001", [], 0), _wave_story("US-002", ["US-001"], 1)]
    proc, verdict = _run_validate_waves(tmp_path, old_convention)
    assert verdict["valid"] is False and verdict["errors"], "0/1 is the old convention"
    assert proc.returncode == 0, "an invalid verdict still exits 0"
    assert proc.stderr == ""

    writer_convention = [_wave_story("US-001", [], 1), _wave_story("US-002", ["US-001"], 2)]
    proc, verdict = _run_validate_waves(tmp_path, writer_convention)
    assert verdict == {"valid": True, "errors": []} and proc.returncode == 0


def test_a_boolean_wave_is_a_mismatch_against_a_computed_one(tmp_path):
    """What wave-true-waves used to prove and cannot any more.

    Its US-002 now computes 2, and Python's own `2 == True` is False, so the
    recording stopped discriminating. Against a ROOT the computed wave is 1 and
    Python's `1 == True` is True -- so only jq's type-aware `==` reports this,
    and this is the fixture that catches a jq_equal replaced by `==`.
    """
    assert (1 == True) is True, "the trap this test exists for"
    _, verdict = _run_validate_waves(tmp_path, [_wave_story("US-001", [], True)])
    assert verdict == {
        "valid": False,
        "errors": ["Wave mismatch: US-001 stored=true computed=1"],
    }


def test_the_places_a_naive_python_would_have_diverged_from_jq():
    """Four rules that are not Python's, each with the recorded case behind it."""
    # `unique` inside validate-deps' cycle reduce, over a heterogeneous dependsOn.
    # Python's own sorted() raises here; jq_sort_key is why this one does not.
    with pytest.raises(TypeError):
        sorted([None, 3, "US-001"])
    assert T.jq_unique([None, 3, "US-001", 3]) == [None, 3, "US-001"]
    assert _errors("deps-heterogeneo-deps") == [
        "Missing ID: US-002 depends on null which does not exist",
        "Missing ID: US-002 depends on 3 which does not exist",
    ]
    # `==` puts a boolean and a number in different types, so `wave: true` is a
    # mismatch against a computed 1 where Python's `1 == True` would hide it.
    # THE RECORDING NO LONGER PROVES THAT ON ITS OWN: US-002 computes 2 under the
    # 1-based convention and Python's own `2 == True` is False too, so the case
    # stopped discriminating when the convention moved. It still pins the
    # message; test_a_boolean_wave_is_a_mismatch_against_a_computed_one below is
    # what pins the rule against a live root, and the two unit assertions here
    # pin jq_equal itself.
    assert (1 == True) is True and T.jq_equal(1, True) is False
    assert T.jq_equal(1, 1.0) is True and T.jq_equal([1], [True]) is False
    assert _errors("wave-true-waves") == [
        "Wave mismatch: US-001 stored=0 computed=1",
        "Wave mismatch: US-002 stored=true computed=2",
    ]
    # `index` searches for a contiguous SUBSEQUENCE when the needle is an array,
    # so a dependsOn holding ["US-001"] resolves rather than dangling.
    assert T.jq_index_in(["US-001", "US-002"], ["US-001"]) == 0
    assert T.jq_index_in(["US-001", ["US-002"]], ["US-002"]) is None
    assert T.jq_index_in(["US-001"], []) is None
    assert _verdict("deps-array-elemento-deps")["valid"] is True
    # `jq -r` unquotes a string and pretty-prints everything else, and bash read
    # that output a LINE at a time -- so one array id is four malformed ids, one
    # id holding a newline is two well-formed ones, and an empty id is neither.
    assert T.jq_raw("US-001") == "US-001" and T.jq_raw([1, 2]) == "[\n  1,\n  2\n]"
    assert _errors("id-array-ids") == [
        "Invalid story ID: " + line + " (expected US-NNN)"
        for line in ("[", "  1,", "  2", "]")
    ]
    assert _verdict("id-newline-ids") == {"valid": True, "count": 2}
    assert _verdict("id-vazio-ids") == {"valid": True, "count": 1}, "the empty id is not counted"


def test_an_empty_file_and_a_two_document_file_answer_the_way_bash_made_them():
    """Two whole-file behaviours the `echo` around the jq owned, not the rule.

    Command substitution strips every trailing newline and `echo` puts one back,
    so a stream of no verdicts prints a BLANK LINE; and the exit status came
    from re-reading that text, so two valid documents give validate-deps two
    lines of `true` that never equal the one word it compared against.
    """
    for label in ("doc-vazio-deps", "doc-vazio-stories"):
        assert VALIDATE[label]["stdout"] == "\n" and VALIDATE[label]["exit"] == 1, label
    assert _verdict("doc-vazio-ids") == {"valid": True, "count": 0}
    assert VALIDATE["doc-vazio-waves"]["stdout"] == "" and VALIDATE["doc-vazio-waves"]["exit"] == 0

    assert VALIDATE["dois-documentos-validos-deps"]["stdout"].count('"valid": true') == 2
    assert VALIDATE["dois-documentos-validos-deps"]["exit"] == 1, "two lines never equal `true`"
    assert VALIDATE["dois-documentos-validos-stories"]["exit"] == 0, "`jq -e` read the LAST one"
    # validate-ids pooled BOTH documents' ids into one verdict rather than two
    assert _errors("dois-documentos-ids") == ["Invalid story ID: us-002 (expected US-NNN)"]


def test_the_suspicious_content_screen_has_one_definition_for_its_three_call_sites():
    """The jq wrote this regex out three times -- title, description, tasks[] --
    and three copies of a prompt-injection screen are three chances to fix two of
    them. The same collapse clamp_max_concurrency got, for the same reason."""
    source = _source()
    assert len(re.findall(r"^SUSPICIOUS = \($", source, re.M)) == 1
    assert source.count("SUSPICIOUS") == 4, "one definition plus three call sites"
    for label in ("titulo-suspeito", "descricao-suspeita", "tasks-suspeito"):
        assert _verdict(label + "-stories")["valid"] is False, label


# ---------------------------------------------------------------------------
# validate-tasks: fifteen rules, and the scaffolding that did not survive
# ---------------------------------------------------------------------------

# The 6 cases `_comment_validate_tasks` names. Five are jq aborting with its own
# message swallowed by the `2>/dev/null` on the assignment that ran it, so the
# recording holds an engine exit status and an EMPTY stderr. The sixth is not jq
# at all -- it is bash's `[` refusing a two-line number, quoting a line of
# aimi-cli.sh that no longer exists.
VALIDATE_TASKS_DIVERGENCES = {
    "ds-ac-null": "jq aborted running to_entries on a null acceptanceCriteria",
    "aborta-antes-das-regras-finais": "jq aborted before the later rules were reached",
    "historias-ausente": "jq aborted iterating a userStories that is absent",
    "metadata-string": "jq aborted indexing a metadata that is a string",
    "json-malformado": "jq's own parse error, at its own exit 4",
    "dois-documentos-endpoints": "bash's own complaint about a two-line endpoint count",
}

# The ONE deliberate behaviour change, kept apart from the six engine-message
# excuses above because it is nothing like them. These two recordings show the
# jq READING a spec file one directory outside the project root and reporting
# on its contents; the commit that added confined_spec_path refuses that path
# instead. The recordings are not regenerated -- they are what the jq did, and
# that is the finding. test_a_spec_path_outside_the_project_root_is_refused
# asserts the new answer in full, so neither case is merely skipped.
CONFINEMENT_DIVERGENCES = {
    "ds-caminho-para-fora": "confined: a designSpec above the project root is now refused",
    "bs-caminho-para-fora": "confined: a businessSpec above the project root is now refused",
}


def _replay_validate(case, tmp_path):
    """Like _replay, plus the two things only this verb has: spec fixtures on
    disk, and fixtures OUTSIDE the project root.

    The root is a subdirectory of tmp_path rather than tmp_path itself so that
    `../fora/...` has somewhere real to land -- which is what makes the two
    path-traversal recordings mean anything.
    """
    parent = os.path.realpath(str(tmp_path))
    root = os.path.join(parent, "proj")
    tasks_dir = os.path.join(root, ".aimi", "tasks")
    os.makedirs(tasks_dir, exist_ok=True)
    given = case["input"]
    with open(os.path.join(tasks_dir, given["tasks_file"]), "w", encoding="utf-8") as handle:
        handle.write(given["tasks"])
    for base, files in ((root, given["files"]), (parent, given["outside"])):
        for relative, content in files.items():
            target = os.path.join(base, relative)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "w", encoding="utf-8") as handle:
                handle.write(content)
    for key, value in given["state"].items():
        with open(os.path.join(root, ".aimi", key), "w", encoding="utf-8") as handle:
            handle.write(value + "\n")

    proc = subprocess.run(
        ["bash", CLI] + case["args"], cwd=root, capture_output=True, text=True, timeout=120
    )

    state_after = {}
    aimi = os.path.join(root, ".aimi")
    for name in sorted(os.listdir(aimi)):
        path = os.path.join(aimi, name)
        if os.path.isfile(path):
            with open(path, encoding="utf-8", errors="replace") as handle:
                state_after[name] = _normalize(handle.read(), root, parent)

    return {
        "exit": proc.returncode,
        "stdout": _normalize(proc.stdout, root, parent),
        "stderr": _normalize(proc.stderr, root, parent),
        "state_after": state_after,
    }


def _normalize(text, root, parent):
    return text.replace(root, "/TMP").replace(parent, "/OUT").replace(CLI, "/CLI/aimi-cli.sh")


@pytest.mark.parametrize("label", sorted(VALIDATE_TASKS), ids=sorted(VALIDATE_TASKS))
def test_the_validate_tasks_port_reproduces_the_jq(label, tmp_path):
    case = VALIDATE_TASKS[label]
    actual = _replay_validate(case, tmp_path)
    if label in VALIDATE_TASKS_DIVERGENCES:
        pytest.skip(VALIDATE_TASKS_DIVERGENCES[label])
    if label in CONFINEMENT_DIVERGENCES:
        pytest.skip(CONFINEMENT_DIVERGENCES[label])
    for field in ("exit", "stdout", "stderr", "state_after"):
        assert actual[field] == case[field], label + " . " + field


def test_the_validate_tasks_divergence_table_names_only_cases_that_exist():
    assert set(VALIDATE_TASKS_DIVERGENCES) <= set(VALIDATE_TASKS)
    assert len(VALIDATE_TASKS_DIVERGENCES) == 6, "the capture's comment names 6; keep the two in step"
    assert set(CONFINEMENT_DIVERGENCES) <= set(VALIDATE_TASKS)
    assert not set(CONFINEMENT_DIVERGENCES) & set(VALIDATE_TASKS_DIVERGENCES), (
        "a deliberate rule change is not an engine-message excuse; keep the two tables apart"
    )


@pytest.mark.parametrize(
    "label", sorted(VALIDATE_TASKS_DIVERGENCES), ids=sorted(VALIDATE_TASKS_DIVERGENCES)
)
def test_each_excused_validate_tasks_case_keeps_its_answer(label, tmp_path):
    """The excuse buys the engine's wording and its number. Never its verdict.

    The five jq aborts refused and still refuse, writing nothing to stdout. The
    bash one did NOT refuse -- it printed a complaint and carried on to a valid
    verdict -- so what it has to keep is that verdict, which is the half a
    caller branching on `$?` can see.
    """
    recorded = VALIDATE_TASKS[label]
    actual = _replay_validate(recorded, tmp_path)
    assert actual["stdout"] == recorded["stdout"], label + ": the verdict may not move"
    assert actual["state_after"] == recorded["state_after"], label

    if label == "dois-documentos-endpoints":
        assert recorded["exit"] == 0 and actual["exit"] == 0, label
        assert recorded["stderr"].startswith("/CLI/aimi-cli.sh: line "), label
        assert actual["stderr"] == "", label
        return

    assert recorded["stderr"] == "", label + ": jq's message went to /dev/null"
    assert recorded["exit"] in (4, 5), label
    assert actual["exit"] != 0, label + ": an excused case still has to refuse"
    assert actual["stdout"] == "", label + ": a refusal writes nothing to stdout"
    assert actual["stderr"].startswith("Error: validate-tasks: "), label


def _vt(label):
    """The verdict the RECORDING holds, never one recomputed from tasks.py."""
    return json.loads(VALIDATE_TASKS[label]["stdout"])


def _vt_errors(label):
    return _vt(label)["errors"]


def test_validate_tasks_writes_nothing_on_any_path_the_corpus_walks():
    """A pure reader, over all 121 recordings at once.

    It takes no lock, and the only thing that makes that safe is that it writes
    nothing at all -- so `state_after` is empty in every case, pass, refusal and
    engine abort alike. The wrapper is asserted to make ONE crossing and to hold
    no lock in test_every_locked_tasks_verb_crosses_into_python_exactly_once,
    which lists the locked verbs exhaustively and does not list this one.
    """
    assert len(VALIDATE_TASKS) == 121
    assert all(case["state_after"] == {} for case in VALIDATE_TASKS.values())
    body = _code().split("def op_validate_tasks", 1)[1].split("\ndef ", 1)[0]
    assert "write_docs_atomically" not in body and "_lock" not in body


def test_every_one_of_the_fifteen_rules_has_a_case_that_trips_it_and_one_that_does_not():
    """THE anti-vacuum check, and it matters more here than anywhere: a corpus
    that only ever passed would let the 121-case replay above pass on nothing.
    Every verdict below is read off the recording."""
    valid = lambda label: _vt(label)["valid"]  # noqa: E731

    # R1 -- the schemaVersion gate. Both sides of 3.3, and the skip is a STDERR
    # line at exit 0 rather than a verdict at all.
    assert VALIDATE_TASKS["schema-32-pula"]["exit"] == 0
    assert VALIDATE_TASKS["schema-32-pula"]["stdout"] == ""
    assert "pre-dates citation enforcement" in VALIDATE_TASKS["schema-32-pula"]["stderr"]
    assert VALIDATE_TASKS["schema-34-nao-pula"]["stderr"] == "" and not valid("schema-34-nao-pula")

    # R2 -- the DesignSpec gate. Each of the four ways it stays shut leaves a
    # MISSING spec file unreported, which is the only way to see a gate close.
    for label in (
        "ds-gate-sem-prototipos", "ds-gate-prototipos-ausente",
        "ds-gate-prototipos-nao-array", "ds-gate-sem-designspec", "ds-gate-designspec-vazio",
    ):
        assert valid(label), label
    # R3 -- and open, with the file gone
    assert _vt_errors("ds-arquivo-ausente")[0].endswith(
        "DesignSpec file not found: specs/NaoExiste.md"
    )
    assert valid("ds-arquivo-presente")

    # R4 -- the citation walk, both ways, including the boundary in both
    # directions: a deeper subsection is INSIDE the cited one, a sibling is not.
    assert valid("ds-citacao-ok") and valid("ds-citacao-unicode")
    assert valid("ds-citacao-subsecao-mais-profunda")
    assert not valid("ds-citacao-fronteira") and not valid("ds-citacao-parafrase")
    assert not valid("ds-citacao-secao-ausente")
    assert _vt_errors("ds-ac-segundo-indice") == [
        "/TMP/.aimi/tasks/2020-01-01-corpus-tasks.json: US-001 AC[1]: "
        'missing DesignSpec citation for "Some daqui" in section § 2.1'
    ]
    assert valid("ds-nao-visual"), "a non-visual story's citation is not checked"

    # R5 -- the BusinessSpec gate, shut three ways and open on a STRING "true"
    for label in (
        "bs-gate-frontendonly-falso", "bs-gate-frontendonly-ausente",
        "bs-gate-frontendonly-numero", "bs-gate-sem-businessspec",
    ):
        assert valid(label), label
    assert _vt_errors("bs-gate-frontendonly-string") == [
        "/TMP/.aimi/tasks/2020-01-01-corpus-tasks.json: "
        "backendSpec.endpoints[0]: missing source field"
    ]
    # R6
    assert _vt_errors("bs-arquivo-ausente")[0].endswith("BusinessSpec file not found: specs/Nada.md")

    # R7 -- a source that is absent, null, empty or false is all one message
    for label in (
        "bs-endpoint-sem-source", "bs-endpoint-source-null",
        "bs-endpoint-source-vazia", "bs-endpoint-source-falsa",
    ):
        assert _vt_errors(label)[0].endswith("backendSpec.endpoints[0]: missing source field"), label

    # R8 -- derived: warns and SKIPS, which is why its invented field survives
    assert valid("bs-endpoint-derived")
    assert VALIDATE_TASKS["bs-endpoint-derived"]["stderr"].endswith(
        "backendSpec.endpoints[0]: derived source — manual review required\n"
    )

    # R9 -- the literal source format, with and without a minor section number
    assert not valid("bs-endpoint-malformado") and not valid("bs-endpoint-source-numero")
    assert valid("bs-endpoint-secao-sem-ponto")

    # R10 -- a field-level source warns, errors, and selects the FIELD's section
    assert valid("bs-campo-source-derived")
    assert "derived source" in VALIDATE_TASKS["bs-campo-source-derived"]["stderr"]
    assert not valid("bs-campo-source-malformada")
    assert valid("bs-campo-source-secao-propria"), "the field's own § is the one looked up"
    assert not valid("bs-campo-source-secao-propria-errada")

    # R11 -- a field with no source of its own, against the endpoint's section
    assert valid("bs-campo-sem-source-ok") and not valid("bs-campo-inventado")

    # R12/R13 -- the enum and the exclusivity, each alone and both together
    assert all(valid(label) for label in ("exec-container", "exec-inline", "exec-ausente"))
    assert not valid("exec-invalido") and valid("fase-sozinha")
    assert len(_vt_errors("exec-fase-conflito")) == 1
    assert len(_vt_errors("exec-fase-invalido-duplo")) == 2

    # R14 -- branchName, including the two ways an ABSENT one still fails
    assert valid("branch-com-barra") and not valid("branch-invalido")
    assert _vt_errors("branch-ausente") == _vt_errors("branch-vazio") == _vt_errors("branch-null")

    # R15 -- the url charset, and the four shapes that are ignored rather than judged
    assert valid("url-ok") and valid("url-charset-limite") and not valid("url-invalida")
    for label in ("url-null", "url-vazia", "url-numero", "url-sem-verificacao"):
        assert valid(label), label
    assert len(_vt_errors("url-duas-ruins")) == 2


def _replay_line_anchor(criterion, tmp_path):
    """One story, one criterion, through the real CLI.

    Built here rather than read out of the golden because R16 is the one rule in
    validate_tasks bash never ran -- there is no jq recording of it to replay,
    and adding one to `validate_tasks_cases` would be recording the Python,
    which is the one thing that file must never hold. schemaVersion 3.3 is
    load-bearing: R1 returns before validate_tasks on anything older, so the
    warning would never fire and the test would pass on nothing.
    """
    document = {
        "schemaVersion": "3.3",
        "metadata": {"branchName": "ref/corpus", "maxConcurrency": 1},
        "userStories": [
            {
                "id": "US-001",
                "title": "Story US-001",
                "description": "As a user, I want US-001.",
                "acceptanceCriteria": [criterion],
                "status": "pending",
                "priority": 1,
                "dependsOn": [],
                "wave": 0,
            }
        ],
    }
    case = {
        "args": ["validate-tasks"],
        "input": {
            "tasks_file": "2020-01-01-corpus-tasks.json",
            "tasks": json.dumps(document, ensure_ascii=False) + "\n",
            "files": {},
            "outside": {},
            "state": {},
        },
    }
    return _replay_validate(case, tmp_path)


def test_a_line_numbered_anchor_in_an_acceptance_criterion_warns_exactly_once(tmp_path):
    """R16's warning half, and the channel it uses is the assertion.

    It names the anchor, and it reaches `warn` rather than `errors`: the verdict
    stays valid and the exit status stays 0. That is the whole point of the rule
    living in validate_tasks -- a line number is fragile, not invalid, and an
    error here would refuse plans that pass today.
    """
    actual = _replay_line_anchor("o bloco em commands/execute.md:2766 precisa mudar", tmp_path)
    assert actual["exit"] == 0
    assert actual["stdout"] == '{"valid": true, "errors": []}\n'
    assert actual["stderr"].count("\n") == 1, "exactly one warning line, per story"
    assert actual["stderr"] == (
        "/TMP/.aimi/tasks/2020-01-01-corpus-tasks.json: US-001: "
        "acceptanceCriteria cites a line number: commands/execute.md:2766"
        " — the tree moves and the anchor does not\n"
    )


def test_a_designspec_citation_is_the_one_anchor_that_does_not_warn(tmp_path):
    """The exclusion, asserted from both sides so it cannot pass vacuously.

    LINE_ANCHOR on its own DOES fire on this string -- the first assertion says
    so -- and the rule still emits nothing, because R2/R3/R4 already validate a
    citation by its literal against its section and bind the `L(...)` capture to
    a `_line_number` nothing reads. Warning here would be warning about the one
    anchor in the file that is checked by content.
    """
    citation = '"o alvo em commands/execute.md:2766" (DesignSpec § 2.1 L2766)'
    assert T.LINE_ANCHOR.search(citation), "a matcher without the exclusion fires on it"
    actual = _replay_line_anchor(citation, tmp_path)
    assert actual["exit"] == 0
    assert actual["stdout"] == '{"valid": true, "errors": []}\n'
    assert actual["stderr"] == ""


_ABSENT = object()


def _replay_implementation(implementation, tmp_path, files=None):
    """One story through the real CLI, carrying `implementation` as given.

    R17's own replay, built here for the reason _replay_line_anchor is built
    here: bash never ran this rule either, so there is no jq recording to
    replay, and adding one to `validate_tasks_cases` would be recording the
    Python. schemaVersion 3.3 is load-bearing for the same reason too -- R1
    returns before validate_tasks on anything older, so the warning would never
    fire and the test would pass on nothing.

    THESE THREE CASES ARE THE ONLY COVERAGE R17 HAS, and that is a measured
    claim rather than a cautious one: not one of the 121 recordings in
    `validate_tasks_cases` carries an `implementation` object at all, so the
    corpus cannot reach this rule even once. `_ABSENT` is a sentinel because
    `None` is a value the schema allows and the absent case has to be distinct
    from it. `files` seeds real files under PROJECT_ROOT, which is how a case
    says "this directory exists" -- the rule asks about the PARENT, so a
    fixture only ever has to create a sibling of the path under test.
    """
    story = {
        "id": "US-001",
        "title": "Story US-001",
        "description": "As a user, I want US-001.",
        "acceptanceCriteria": ["um criterio sem ancora nenhuma"],
        "status": "pending",
        "priority": 1,
        "dependsOn": [],
        "wave": 0,
    }
    if implementation is not _ABSENT:
        story["implementation"] = implementation
    document = {
        "schemaVersion": "3.3",
        "metadata": {"branchName": "ref/corpus", "maxConcurrency": 1},
        "userStories": [story],
    }
    case = {
        "args": ["validate-tasks"],
        "input": {
            "tasks_file": "2020-01-01-corpus-tasks.json",
            "tasks": json.dumps(document, ensure_ascii=False) + "\n",
            "files": files or {},
            "outside": {},
            "state": {},
        },
    }
    return _replay_validate(case, tmp_path)


def test_a_story_with_no_implementation_reaches_r17_and_says_nothing(tmp_path):
    """`implementation` is optional in schema v3.3, so absent is not a finding.

    The story still reaches the rule -- R17 iterates every story unconditionally
    and it is the jq_type guard, not a pre-filter, that ends this one. Silence
    on both channels is the assertion, because a warning here would fire on the
    majority of every tasks file the plugin has ever written.
    """
    actual = _replay_implementation(_ABSENT, tmp_path)
    assert actual["exit"] == 0
    assert actual["stdout"] == '{"valid": true, "errors": []}\n'
    assert actual["stderr"] == ""


def test_an_implementation_that_is_a_string_is_stopped_by_the_type_guard(tmp_path):
    """The guard's own test, and it is shown to be load-bearing, not assumed.

    The second assertion is the point: reading `.files` off this same scalar
    WITHOUT the guard raises, and MalformedTasks out of validate_tasks is an
    abort of the whole run -- exit 1 on a document that is merely unusual. That
    is the regression the comment beside .project in validate_stories records,
    reproduced here against the real function rather than restated in prose.
    """
    scalar = "isto e uma string, nao um objeto"
    actual = _replay_implementation(scalar, tmp_path)
    assert actual["exit"] == 0
    assert actual["stdout"] == '{"valid": true, "errors": []}\n'
    assert actual["stderr"] == ""
    with pytest.raises(T.MalformedTasks):
        T.jq_index(scalar, "files", ".userStories[].implementation")


def test_implementation_files_naming_a_missing_directory_warns_and_stays_valid(tmp_path):
    """R17's warning half, plus the half that keeps it from passing on nothing.

    The same story shape is run twice and only the path changes: `src/` exists
    because the fixture seeded a sibling into it, `nao/existe/` does not. One
    warns, one is silent, so the rule is shown to discriminate rather than to
    fire on every path it is handed.

    The FILE is missing in both runs. That is the rule's whole design -- a story
    that creates `src/novo.py` is the ordinary case, and checking the file
    instead of its parent would refuse every scaffolding story in the corpus.

    The verdict stays `valid` and the exit stays 0: this reaches `warn`, never
    `errors`, because a plan may legitimately describe a directory it is about
    to create and refusing that would be worse than not checking at all.
    """
    seeded = {"src/existente.py": "# um vizinho, so para criar src/\n"}

    quiet = _replay_implementation(
        {"files": ["src/novo.py"], "approach": "a", "verify": "true"}, tmp_path, seeded
    )
    assert quiet["exit"] == 0
    assert quiet["stderr"] == "", "the file is absent too -- only the parent is checked"

    loud = _replay_implementation(
        {"files": ["nao/existe/de/jeito/nenhum/x.py"], "approach": "a", "verify": "true"},
        tmp_path,
        seeded,
    )
    assert loud["exit"] == 0
    assert loud["stdout"] == '{"valid": true, "errors": []}\n', "a warning, never an error"
    assert loud["stderr"].count("\n") == 1, "exactly one warning line, per story"
    assert loud["stderr"] == (
        "/TMP/.aimi/tasks/2020-01-01-corpus-tasks.json: US-001: "
        "implementation.files names a directory that does not exist: "
        "nao/existe/de/jeito/nenhum/x.py"
        " — the file may be new, the directory it lands in may not\n"
    )


def test_plan_md_s_two_response_shape_examples_come_out_the_way_plan_md_says():
    """commands/plan.md § "responseShape contract (frontend-only mode)" prints
    one ACCEPTED example and one REJECTED one. Both are in the corpus, and the
    rejection is the half /aimi:plan's frontend-only mode depends on."""
    accepted = json.loads(VALIDATE_TASKS["bs-plan-chave-plana"]["input"]["tasks"])
    shape = accepted["metadata"]["backendSpec"]["endpoints"][0]["responseShape"]
    assert shape == {
        "portfolio": {
            "type": "{ totalUsinas: number; totalKWp: number }",
            "source": "BusinessSpec § 5.3 L145",
        }
    }
    assert _vt("bs-plan-chave-plana")["valid"] is True

    rejected = json.loads(VALIDATE_TASKS["bs-plan-chave-pontilhada"]["input"]["tasks"])
    assert list(rejected["metadata"]["backendSpec"]["endpoints"][0]["responseShape"]) == [
        "portfolio.totalUsinas"
    ]
    assert _vt_errors("bs-plan-chave-pontilhada") == [
        "/TMP/.aimi/tasks/2020-01-01-corpus-tasks.json: "
        "backendSpec.endpoints[0].responseShape.portfolio.totalUsinas: "
        "field name not found in BusinessSpec § 5.3"
    ]


def test_a_dotted_key_is_refused_even_when_both_halves_are_in_the_subsection():
    """The rejection has to be fixed-string containment and nothing cleverer.

    The subsection bs-plan-chave-pontilhada cites names `portfolio`,
    `totalUsinas` and `totalKWp` -- separately, in one sentence. A lookup that
    split on '.', walked a path, or built a regex out of the key would find
    both halves and PASS, and plan.md's flat-key contract would stop being one.
    """
    subsection = VALIDATE_TASKS["bs-plan-chave-pontilhada"]["input"]["files"]["specs/BusinessSpec.md"]
    assert "portfolio" in subsection and "totalUsinas" in subsection
    assert "portfolio.totalUsinas" not in subsection
    assert _vt("bs-plan-chave-pontilhada")["valid"] is False

    # and directly against the rule, away from the corpus plumbing
    body = b"## 5.3 Portfolio\n\nO resumo carrega portfolio com totalUsinas.\n"
    assert T.subsection_body(body, b"5.3", normalize=False).find(b"portfolio") >= 0
    assert b"portfolio.totalUsinas" not in T.subsection_body(body, b"5.3", normalize=False)
    source = _source()
    lookup = source.split("def spec_contains", 1)[1].split("\ndef ", 1)[0]
    assert '.split(".")' not in lookup and "re.compile" not in lookup


def test_the_two_traversal_recordings_show_a_file_outside_the_root_being_read():
    """What the jq did, which is the finding the confinement answers.

    Each of these names a spec one directory ABOVE the project root and the
    RECORDING comes back valid -- and it can only come back valid if that file
    was opened, since the literal and the field name appear nowhere inside the
    root. That is the read primitive, stated as evidence rather than as a worry,
    and it is why the recordings are kept rather than regenerated.
    """
    for label, needle in (
        ("ds-caminho-para-fora", "Segredo de fora do projeto"),
        ("bs-caminho-para-fora", "portfolioDeFora"),
    ):
        given = VALIDATE_TASKS[label]["input"]
        assert any(name.startswith("../") for name in _spec_names(given["tasks"])), label
        assert any(needle in content for content in given["outside"].values()), label
        assert all(needle not in content for content in given["files"].values()), label
        assert _vt(label)["valid"] is True, label

    # the other half already held: an absolute path is CONCATENATED onto the
    # root, so it lands nowhere and is reported missing rather than read.
    assert _vt_errors("ds-caminho-absoluto-para-fora") == [
        "/TMP/.aimi/tasks/2020-01-01-corpus-tasks.json: DesignSpec file not found: /etc/hostname"
    ]


@pytest.mark.parametrize(
    "label,field",
    [("ds-caminho-para-fora", "DesignSpec"), ("bs-caminho-para-fora", "BusinessSpec")],
)
def test_a_spec_path_outside_the_project_root_is_refused(label, field, tmp_path):
    """The deliberate change, asserted in full rather than skipped.

    Both cases now come back invalid with ONE error naming the offending path
    and nothing else -- not a "file not found", which would be a lie about a
    file that exists, and not a citation verdict, which would mean it had been
    read. The file outside the root is left on disk by the fixture and is never
    opened, so nothing about its contents can reach stdout.
    """
    case = VALIDATE_TASKS[label]
    actual = _replay_validate(case, tmp_path)
    relative = [name for name in _spec_names(case["input"]["tasks"]) if name.startswith("../")]
    assert actual["exit"] == 1
    assert json.loads(actual["stdout"]) == {
        "valid": False,
        "errors": [
            "/TMP/.aimi/tasks/2020-01-01-corpus-tasks.json: "
            + field + " path escapes the project root: " + relative[0]
        ],
    }
    for content in case["input"]["outside"].values():
        for word in content.split():
            assert word not in actual["stdout"] or word in relative[0], word


def test_confinement_still_lets_an_ordinary_relative_spec_through(tmp_path):
    """A guard that refused everything would pass the test above and break every
    real tasks file. The whole corpus is the counterweight -- every other spec
    path in it is relative, inside the root, and still read -- and these are the
    rows that say so directly."""
    parent = os.path.realpath(str(tmp_path))
    root = os.path.join(parent, "proj")
    os.makedirs(os.path.join(root, "specs"))
    os.makedirs(os.path.join(parent, "fora"))
    for target in (
        os.path.join(root, "specs", "DesignSpec.md"),
        os.path.join(parent, "fora", "Segredo.md"),
    ):
        with open(target, "w", encoding="utf-8") as handle:
            handle.write("# spec\n")
    for accepted in ("specs/DesignSpec.md", "./specs/DesignSpec.md", "a/../specs/DesignSpec.md"):
        assert confined(accepted, root) is True, accepted
    # Refused whenever the target or its parent is really there -- which is
    # exactly when a read could have succeeded.
    for refused in ("../fora/Segredo.md", "../fora/naoexiste.md", "specs/../../fora/Segredo.md"):
        assert confined(refused, root) is False, refused
    # An absolute value is concatenated, not joined, so it stays inside and is
    # simply not found -- unchanged by the confinement, and ds-caminho-absoluto-
    # para-fora is still the recording that says so.
    assert confined("/etc/hostname", root) is True
    assert _vt_errors("ds-caminho-absoluto-para-fora")[0].endswith("not found: /etc/hostname")


def test_a_path_whose_parent_does_not_exist_falls_back_the_way_bash_does():
    """validate_path_in_project resolves the PARENT when the target is missing,
    and the raw string when the parent is missing too -- at which point
    `$PROJECT_ROOT/../x` still matches its `"$PROJECT_ROOT"/*` glob. That
    fallback is reproduced rather than tightened, and it costs nothing: a path
    whose parent does not exist names no file, so there is nothing to open. The
    read this commit closes needs the file to BE there, and `exists` then
    resolves the `..` before the comparison is made.
    """
    assert confined("../fora/x.md", "/no/such/project") is True, "bash's own fallback"
    assert not os.path.exists("/no/such/project/../fora/x.md"), "and it names nothing"


def confined(relative, root):
    return T.confined_spec_path(root, relative)[1]


def test_a_symlink_out_of_the_tree_is_caught_too(tmp_path):
    """`realpath` resolves links, so a spec path that is inside the root only
    until the kernel follows it is refused as well. The bash rule this
    reproduces (validate_path_in_project) resolves the same way, and a
    confinement that compared strings would miss this entirely."""
    root = os.path.realpath(str(tmp_path / "proj"))
    os.makedirs(os.path.join(root, "specs"))
    outside = str(tmp_path / "outside.md")
    with open(outside, "w", encoding="utf-8") as handle:
        handle.write("# outside\n")
    os.symlink(outside, os.path.join(root, "specs", "link.md"))

    assert confined("specs/link.md", root) is False
    with open(os.path.join(root, "specs", "real.md"), "w", encoding="utf-8") as handle:
        handle.write("# inside\n")
    assert confined("specs/real.md", root) is True
    # and a path that does not exist at all is resolved through its parent, so
    # it is still reported as missing rather than as an escape
    assert confined("specs/gone.md", root) is True


def _spec_names(tasks_text):
    bundle = json.loads(tasks_text)["metadata"].get("designBundle", {})
    return [value for value in bundle.values() if isinstance(value, str)]


def test_the_three_pieces_of_scaffolding_are_gone_from_the_shell():
    """THE reviewable evidence that the port bought something.

    cmd_validate_tasks carried ~30 lines defending a `\\037` delimiter, a
    never-`// empty` rule and a `_vt_probe` sentinel -- all three existing only
    because reading one document eight times cost eight jq startups. This
    asserts they left the tree, and that what replaced them is one metadata read
    in Python rather than a second copy of the same idea somewhere else.

    Retargeted rather than deleted: the grep that used to find this machinery in
    aimi-cli.sh now finds the function that made it unnecessary.
    """
    with open(CLI, encoding="utf-8") as handle:
        shell = handle.read()
    for token in ("_vt_probe", "_vt_meta", "\\037", "@tsv"):
        assert token not in shell, token + " survives in aimi-cli.sh"
    assert "_validate_designspec_citation" not in shell
    assert "_validate_businessspec_field" not in shell

    source = _source()
    assert len(re.findall(r"^def validate_tasks_metadata\(", source, re.M)) == 1
    # ONE scanner for both specs, where bash had the awk program twice.
    assert len(re.findall(r"^def subsection_body\(", source, re.M)) == 1
    assert source.count("subsection_body(") == 2, "one def plus the single call site"

    wrapper = dict(_wrappers())["cmd_validate_tasks"]
    assert wrapper.count(_TASKS_CROSSING) == 1
    assert "_lock" not in wrapper and "jq " not in wrapper


def test_the_version_gate_is_sort_v_and_not_an_approximation_of_it():
    """R1 is `sort -V | head -n1`, so it accepts what filevercmp accepts rather
    than what semver would. The reconstruction was fuzzed against the real
    `sort -V` over 5540 comparisons with zero mismatches; these are the rows
    that decide whether a tasks file is validated at all."""
    assert T.sort_v_first("3.3", "3.3") == "3.3"
    assert T.sort_v_first("3.4", "3.3") == "3.3"
    assert T.sort_v_first("3.10", "3.3") == "3.3"
    assert T.sort_v_first("10.0", "3.3") == "3.3"
    assert T.sort_v_first("3.2", "3.3") == "3.2"
    assert T.sort_v_first("3.03", "3.3") == "3.03"
    assert T.sort_v_first("0", "3.3") == "0"
    assert T.sort_v_first("", "3.3") == ""
    # and the row that looks like a defect: letters sort ABOVE digits, so a
    # schemaVersion of "abc" is validated rather than skipped. schema-lixo.
    assert T.sort_v_first("abc", "3.3") == "3.3"
    assert _vt("schema-lixo")["valid"] is False


def test_the_tab_collapse_the_unit_separator_existed_to_prevent_is_still_live_in_both_scans():
    """The metadata read got `\\037` and the two scans never did, so both still
    hand bash a row that loses its leading empty field.

    Reproduced rather than fixed: a visual story with an empty id has its
    citation silently unchecked, and a story with a null id reports its URL in
    the id position and an empty url. Which of the two readings the author meant
    is a decision, and a decision is not a port.
    """
    assert T._read_ifs_whitespace("\t0\ttexto", 3) == ["0", "texto", ""]
    assert T._read_ifs_whitespace("US-001\t0\ttexto", 3) == ["US-001", "0", "texto"]
    assert T._read_ifs_whitespace("US-001\t\ttexto", 3) == ["US-001", "texto", ""]
    assert T._read_ifs_whitespace("a\tb\tc\td", 3) == ["a", "b", "c\td"]
    assert _vt("ds-id-vazio")["valid"] is True, "the citation was never checked"
    assert _vt_errors("url-id-nulo") == [
        "/TMP/.aimi/tasks/2020-01-01-corpus-tasks.json: "
        'http://x/`a` verification.url "" contains characters outside the allowed charset'
    ]


def test_a_multi_line_error_becomes_several_entries_because_jq_r_read_lines():
    """`printf '%s\\n' "${errors[@]}" | jq -R . | jq -s .` fed jq LINES, so a
    message carrying a newline came back as several array entries rather than
    one string with an escape in it. An endpoint whose source is an object is
    how that is reached: `jq -r` pretty-prints it over three lines."""
    assert _vt_errors("bs-endpoint-source-objeto") == [
        "/TMP/.aimi/tasks/2020-01-01-corpus-tasks.json: "
        'backendSpec.endpoints[0]: malformed source "{',
        '  "cite": "BusinessSpec § 5.3 L7"',
        "}\" (expected 'BusinessSpec § N[.N] L<line>' or 'derived: ...')",
    ]


def test_the_subsection_scanner_keeps_the_asymmetry_between_the_two_specs():
    """One function where bash had the awk program twice -- and the difference
    that was NOT in the awk stays: the DesignSpec side normalizes curly quotes,
    em-dashes, NBSP and HTML entities on both sides, the BusinessSpec side does
    not. Normalizing the field-name lookup too would change which responseShape
    keys validate, which is a rule change wearing a tidy-up's clothes."""
    spec = "## 3.1 T\n\nCurly: “Aspas”, travessao — assim e &amp; entidade.\n".encode("utf-8")
    assert b'"Aspas"' in T.subsection_body(spec, b"3.1", normalize=True)
    assert b'"Aspas"' not in T.subsection_body(spec, b"3.1", normalize=False)
    # the sed chain ran every -e over the same pattern space in turn, so a
    # doubly-encoded entity is decoded twice
    assert T._normalize_text(b"&amp;nbsp;") == b" "
    assert _vt("ds-citacao-unicode")["valid"] is True


# ---------------------------------------------------------------------------
# get-story-context: the payload every spawned executor reads, shape and all
# ---------------------------------------------------------------------------

# The run-length collapse the capture applied, reproduced here so both sides of
# every comparison go through it. A 100KB skill of one repeated letter pins
# nothing the marker does not, and recording it verbatim would have added most
# of a megabyte to the golden file.
_RUN = re.compile(r"(.)\1{255,}", re.S)

# The one key the payload gained. It is stripped from the ACTUAL stdout before
# the corpus comparison, so everything else -- key order, indentation, the
# trailing newline -- still has to match the recording byte for byte rather
# than merely parse to the same object.
_DROPPED_KEY = re.compile(r',\n  "skillsDropped": (?:\[\]|\[\n(?:.|\n)*?\n  \])\n\}', re.S)


def _rle(text):
    return _RUN.sub(lambda m: "<<" + m.group(1) + "*" + str(len(m.group(0))) + ">>", text)


def _without_dropped(text):
    return _DROPPED_KEY.sub("\n}", text)


def _replay_context(case, tmp_path):
    """Rebuild the case's root -- tasks file, skills tree, brainstorm, state --
    and run the CLI the way the capture ran it.

    `plugin_dir` is how a fixture reaches _resolve_skills_base_dir at all:
    CLAUDECODE unset plus AIMI_PLUGIN_DIR pointing at the root makes
    <root>/skills the base directory. `env` carries LC_ALL for the two multibyte
    twins, and nothing else.
    """
    root = os.path.realpath(str(tmp_path))
    given = case["input"]
    tasks_dir = os.path.join(root, ".aimi", "tasks")
    os.makedirs(tasks_dir, exist_ok=True)
    if given["tasks_file"]:
        target = os.path.join(tasks_dir, given["tasks_file"])
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "w", encoding="utf-8") as handle:
            handle.write(given["tasks"].replace("/ABS/", root + "/"))
    for relative, content in given["files"].items():
        path = os.path.join(root, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content)
    for relative, spec in given["repeat"].items():
        path = os.path.join(root, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write((spec[2] if len(spec) > 2 else "") + spec[0] * spec[1])
    for key, value in given["state"].items():
        with open(os.path.join(root, ".aimi", key), "w", encoding="utf-8") as handle:
            handle.write(value + "\n")

    env = dict(os.environ)
    env.pop("CLAUDECODE", None)
    env.pop("AIMI_PLUGIN_DIR", None)
    if given["plugin_dir"]:
        env["AIMI_PLUGIN_DIR"] = root
    env.update(given["env"])

    proc = subprocess.run(
        ["bash", CLI] + case["args"], cwd=root, capture_output=True, text=True,
        timeout=300, env=env,
    )

    state_after = {}
    aimi = os.path.join(root, ".aimi")
    for name in sorted(os.listdir(aimi)):
        path = os.path.join(aimi, name)
        if os.path.isfile(path):
            with open(path, encoding="utf-8", errors="replace") as handle:
                state_after[name] = handle.read().replace(root, "/TMP")

    def norm(text):
        return _rle(text.replace(root, "/TMP").replace(CLI, "/CLI/aimi-cli.sh"))

    return {
        "exit": proc.returncode,
        "stdout": norm(proc.stdout),
        "stderr": norm(proc.stderr),
        "state_after": state_after,
    }


# The 6 aborts `_comment_story_context` names. Not one of them is a rule anyone
# wrote: three are jq's own message at jq's own exit status, two are `set -e`
# reacting to `((expr))` returning 1 for a zero result, and one is SIGPIPE
# promoted by `pipefail`. There is no shell pipeline left to abort and no jq
# left to complain, so none of them is reproducible on purpose.
CONTEXT_ABORTS = {
    "skill-vazio": "set -e killed the verb when the running byte total was still 0",
    "skill-so-newlines": "set -e killed the verb when the running byte total was still 0",
    "brainstorm-truncagem-64k": "head -c closed the pipe and pipefail promoted SIGPIPE",
    "bundle-string": "jq aborted indexing a designBundle that is a string",
    "metadata-string": "jq aborted indexing a metadata that is a string",
    "arquivo-vazio": "jq aborted iterating .userStories of a null document",
}

# KEPT SEPARATE FROM THE TABLE ABOVE, deliberately and for the same reason
# CONFINEMENT_DIVERGENCES is: a rule that changed on purpose is not an excuse,
# and filing it beside six engine messages would let it read like one. Each of
# these three is asserted in full below rather than skipped.
CONTEXT_DECISIONS = {
    "cap-multibyte-c": "the cap counts bytes; under LC_ALL=C it already did",
    "cap-multibyte-c-utf-8": "the cap counts bytes; under LC_ALL=C.UTF-8 it counted characters",
    "cap-gigante-primeiro": "an individually oversized skill no longer drains its siblings",
}


@pytest.mark.parametrize("label", sorted(CONTEXT), ids=sorted(CONTEXT))
def test_the_story_context_port_reproduces_the_jq(label, tmp_path):
    case = CONTEXT[label]
    actual = _replay_context(case, tmp_path)
    if label in CONTEXT_ABORTS:
        pytest.skip(CONTEXT_ABORTS[label])
    if label in CONTEXT_DECISIONS:
        pytest.skip(CONTEXT_DECISIONS[label])
    for field in ("exit", "stderr", "state_after"):
        assert actual[field] == case[field], label + " . " + field
    assert _without_dropped(actual["stdout"]) == case["stdout"], label + " . stdout"


def test_the_story_context_tables_name_only_cases_that_exist():
    assert set(CONTEXT_ABORTS) <= set(CONTEXT)
    assert set(CONTEXT_DECISIONS) <= set(CONTEXT)
    assert not set(CONTEXT_ABORTS) & set(CONTEXT_DECISIONS)
    assert len(CONTEXT) == 57
    assert len(CONTEXT_ABORTS) + len(CONTEXT_DECISIONS) == 9, "48 of 57 match; keep this in step"


def test_get_story_context_writes_nothing_on_any_path_the_corpus_walks():
    """A pure reader, over all 57 recordings at once, and the wrapper to match.

    It takes no lock and it writes nothing at all -- pass, refusal and engine
    abort alike -- so a port that started writing a temp file would have nowhere
    to hide. The wrapper is asserted to make ONE crossing and to hold no lock in
    test_every_locked_tasks_verb_crosses_into_python_exactly_once, which lists
    the locked verbs exhaustively and does not list this one.
    """
    assert all(case["state_after"] == {} for case in CONTEXT.values())
    body = _code().split("def op_get_story_context", 1)[1].split("\ndef ", 1)[0]
    assert "write_docs_atomically" not in body and "_lock" not in body


@pytest.mark.parametrize("label", sorted(CONTEXT_ABORTS), ids=sorted(CONTEXT_ABORTS))
def test_each_excused_story_context_case_aborted_and_now_answers_instead(label, tmp_path):
    """The excuse is only good while the RECORDING still shows an abort.

    Every one of these six was recorded with no payload at all -- an engine
    message at an engine exit status, or the shell dying quietly. If a future
    capture edit turns one into an ordinary answer, it stops belonging in the
    table, and this is what notices. The other half is that an excused case must
    not merely stop failing: each one is asserted to produce a SPECIFIC answer
    now, because "the port does something different here" is not a statement
    anyone can review.

    They split three and three, and the split is the finding. bundle-string,
    metadata-string and arquivo-vazio were jq refusing, and the port refuses
    too. skill-vazio, skill-so-newlines and brainstorm-truncagem-64k were the
    SHELL dying on a payload that was perfectly well-formed -- an empty
    SKILL.md, a long Design Decisions section -- and those now succeed, which is
    the bug fix that falls out of there being no shell pipeline left to kill.
    """
    assert CONTEXT[label]["exit"] != 0, label + ": the recording has to show an abort"
    assert CONTEXT[label]["stdout"] == "", label + ": an abort produced no payload"

    actual = _replay_context(CONTEXT[label], tmp_path)
    if label in ("bundle-string", "metadata-string", "arquivo-vazio"):
        assert actual["exit"] == 1, label
        assert actual["stdout"] == "", label + ": a refusal writes nothing to stdout"
        assert actual["stderr"].startswith("Error: get-story-context: "), label
        return

    assert actual["exit"] == 0, label + ": the shell that killed this is gone"
    payload = json.loads(actual["stdout"])
    if label == "brainstorm-truncagem-64k":
        assert payload["designContext"]["decisions"] == "<<d*65536>>", "truncated, not fatal"
    else:
        assert [skill["content"] for skill in payload["skills"]][0] == "", "empty, not fatal"
        assert payload["skillsDropped"] == []


def test_no_jq_survives_in_the_wrapper_and_it_crosses_once():
    """AC1's mechanical half: 13 jq invocations on a five-skill story became 0.

    Counting `jq` in the function body is the check a reviewer can actually run,
    and it is what stops one creeping back the next time a field is added to the
    payload -- a second reader of this document would put the two implementations
    of one rule back beside each other, which is the whole thing the port
    removed.
    """
    body = dict(_wrappers())["cmd_get_story_context"]
    assert "jq " not in body and "jq(" not in body
    assert body.count(_TASKS_CROSSING) == 1
    assert "_lock" not in body, "a reader takes no lock"
    # The five lines bash keeps, and why each one is bash's: the argument, its
    # format, which file is current, whether the story is in it, and which host
    # this is. Nothing here reads the document.
    for kept in ("validate_story_id", "get_tasks_file", "validate_story_exists",
                 "_resolve_skills_base_dir", "check_python3"):
        assert kept in body, kept


def _context_stdout(label, tmp_path):
    actual = _replay_context(CONTEXT[label], tmp_path)
    assert actual["exit"] == 0, label
    return actual, json.loads(actual["stdout"])


def test_the_payload_carries_five_keys_in_the_order_a_consumer_reads_them(tmp_path):
    """The shape IS the contract here: this payload is parsed by an agent, not
    by a caller who can read a diff. skillsDropped is appended LAST so the four
    keys that were always there keep their positions."""
    _, payload = _context_stdout("skills-tres", tmp_path)
    assert list(payload) == ["story", "metadata", "skills", "designContext", "skillsDropped"]
    assert [list(skill) for skill in payload["skills"]] == [["name", "path", "content"]] * 3
    assert list(payload["designContext"]) == ["decisions", "bundleGuidance"]
    assert [skill["name"] for skill in payload["skills"]] == ["alpha", "beta", "gama"]


def test_skills_dropped_is_present_and_empty_when_nothing_was_dropped(tmp_path):
    """`[]` rather than an absent key, on every path -- including the ones with
    no skills at all. A consumer that has to test for presence before reading is
    a consumer that will forget to."""
    for label in ("sem-skills", "skills-vazio", "skills-tres", "skill-ausente",
                  "skills-base-nao-resolvida", "cap-fronteira-exata"):
        _, payload = _context_stdout(label, tmp_path / label)
        assert payload["skillsDropped"] == [], label

    # and the recordings prove the key is genuinely NEW rather than renamed:
    # nothing in the pre-port corpus ever printed it.
    assert not any("skillsDropped" in case["stdout"] for case in CONTEXT.values())


def test_the_only_added_key_is_the_one_the_comparison_strips(tmp_path):
    """The corpus comparison removes skillsDropped textually, which is only
    honest if removing it leaves the recording exactly. Asserted once, in full,
    against a case that drops nothing."""
    actual, _ = _context_stdout("skills-tres", tmp_path)
    assert actual["stdout"].endswith(',\n  "skillsDropped": []\n}\n')
    assert _without_dropped(actual["stdout"]) == CONTEXT["skills-tres"]["stdout"]


# ---------------------------------------------------------------------------
# DECISION 4: metadata is projected, not copied whole
# ---------------------------------------------------------------------------
#
# The corpus MOVED for this rule -- 43 of its 45 non-empty recordings lost the
# metadata keys nothing reads -- and `_comment_story_context` says how. What the
# corpus cannot say is the thing that motivated the change: no fixture in it has
# ever carried a `metadata.decisions`, so the assertion that discriminates is
# hand-written here, against a document written for it.


def _synthetic_context_case(metadata):
    """One story and the given metadata, in the shape _replay_context rebuilds.

    Reuses the replay machinery rather than a second runner, so these tests go
    through the same bash wrapper, the same crossing and the same argv the 57
    recordings do -- the projection is asserted on the payload a story executor
    would actually receive, not on projected_metadata() called directly.
    """
    document = {
        "schemaVersion": "3.3",
        "metadata": metadata,
        "userStories": [{
            "id": "US-001", "title": "Story US-001",
            "description": "As a user, I want US-001.",
            "acceptanceCriteria": ["Typecheck passes"], "status": "pending",
            "priority": 1, "dependsOn": [], "wave": 0,
        }],
    }
    return {
        "args": ["get-story-context", "US-001"],
        "input": {
            "tasks_file": "2020-01-01-corpus-tasks.json",
            "tasks": json.dumps(document, indent=2) + "\n",
            "files": {}, "repeat": {}, "state": {}, "plugin_dir": True, "env": {},
        },
    }


def _projected(metadata, tmp_path):
    actual = _replay_context(_synthetic_context_case(metadata), tmp_path)
    assert actual["exit"] == 0, actual["stderr"]
    return json.loads(actual["stdout"])["metadata"]


def test_decisions_stops_travelling_and_a_key_with_a_reader_survives(tmp_path):
    """DECISION 4, and the one assertion that discriminates this story's change.

    metadata.decisions is the largest block a plan writes -- one object per
    resolved question, carrying that question's own prose -- and it was copied
    into the first payload of every spawned story executor, none of which has
    ever read it. prototypePaths sits in the same object and IS read, nine times
    in SKILL.md, so a projection that dropped both would be a regression wearing
    this story's name: both halves are asserted here, on one document.
    """
    metadata = _projected({
        "branchName": "x/y",
        "maxConcurrency": 3,
        "decisions": [{"anchor": "a", "source": "b", "text": "c", "resolution": "d"}],
        "prototypePaths": ["p.html"],
    }, tmp_path)
    assert "decisions" not in metadata, "the block that motivated the projection"
    assert metadata["prototypePaths"] == ["p.html"], "a key WITH a reader survives"
    assert metadata == {"prototypePaths": ["p.html"]}


def test_the_projection_keeps_the_documents_own_key_order(tmp_path):
    """Payload SHAPE is the contract here (this is parsed by an agent), and the
    three keys are projected in the order the DOCUMENT wrote them, not in the
    order the constant lists them."""
    metadata = _projected({
        "prototypePaths": ["p.html"],
        "branchName": "x/y",
        "designTokens": {"color": "#fff"},
        "decisions": [],
        "designBundle": {"root": ".aimi/design/b"},
    }, tmp_path)
    assert list(metadata) == ["prototypePaths", "designTokens", "designBundle"]


def test_a_key_the_document_omits_does_not_become_null(tmp_path):
    """PRESENCE, not truthiness, in both directions.

    A projected key the document never wrote is absent, because inventing it as
    null would make the payload claim the document said something it did not --
    and a consumer that has to tell "absent" from "null" is one that will get it
    wrong. A projected key the document wrote AS null survives as null, for the
    same reason read the other way: `designBundle: null` is a real value, and
    bundle-null records a document that carries it.
    """
    assert _projected({"prototypePaths": ["p.html"]}, tmp_path / "one") == {
        "prototypePaths": ["p.html"]
    }
    assert _projected({"designBundle": None}, tmp_path / "two") == {"designBundle": None}


def test_a_document_with_no_metadata_answers_exactly_what_it_did_before(tmp_path):
    """`null`, not `{}` and not an omitted key -- unchanged by the projection.

    metadata-ausente and metadata-null are the two recordings the move did NOT
    touch, and the reason is a contract rather than an accident: a document that
    carries no metadata says nothing, which is not the same statement as "every
    projected key was missing". Both are replayed here so the pair is asserted
    rather than inferred from the diff.
    """
    for label in ("metadata-ausente", "metadata-null"):
        _, payload = _context_stdout(label, tmp_path / label)
        assert payload["metadata"] is None, label
        assert '"metadata": null' in CONTEXT[label]["stdout"], label + ": recorded too"

    # And the key a caller still reaches for is jq's null either way, which is
    # what keeps the narrowing from breaking a reader nobody has found yet.
    assert _projected({"maxConcurrency": 3}, tmp_path / "narrowed") == {}


def test_the_projected_set_is_named_once_and_decisions_is_not_in_it():
    """The constant is the single place the set is written down.

    The grep that produced it lives in the comment beside it in tasks.py rather
    than in an assertion here, deliberately: skills/story-executor/SKILL.md is
    owned by another story in this same wave, and a test that grepped a file
    being edited beside it would go red for a reason that has nothing to do with
    this rule. Re-run the grep the comment records when a reader is added.
    """
    assert T.STORY_CONTEXT_METADATA_KEYS == (
        "designBundle", "designTokens", "prototypePaths"
    )
    assert "decisions" not in T.STORY_CONTEXT_METADATA_KEYS


def test_the_moved_recordings_carry_no_key_the_projection_would_drop():
    """The corpus's own half of decision 4, over all 45 non-empty recordings.

    The move was mechanical -- each recorded payload re-parsed, its metadata
    narrowed, the rest re-rendered byte for byte -- so the property to check
    afterwards is that nothing survived it that the live rule would remove. A
    recording that still carried `branchName` would mean the replay test is
    comparing the new code against a recording of the old rule.
    """
    seen = 0
    for case in CONTEXT.values():
        for payload in _payloads(case["stdout"]):
            metadata = payload["metadata"]
            if metadata is None:
                continue
            assert set(metadata) <= set(T.STORY_CONTEXT_METADATA_KEYS), case["label"]
            seen += 1
    assert seen, "the corpus has payloads with a metadata object"


def _payloads(stdout):
    """The recorded stdout's JSON values -- id-duplicado holds two."""
    decoder = json.JSONDecoder()
    index, values = 0, []
    while True:
        while index < len(stdout) and stdout[index] in " \n\t\r":
            index += 1
        if index >= len(stdout):
            return values
        value, index = decoder.raw_decode(stdout, index)
        values.append(value)


def test_the_byte_cap_answers_the_same_under_both_locales(tmp_path):
    """DECISION 1, asserted from both sides.

    One 34200-character body of em-dashes is 102600 bytes. `${#skill_content}`
    read the first number under LC_ALL=C.UTF-8 and the second under LC_ALL=C, so
    the same skill set was hydrated on one host and evicted on another -- and
    the SKILL.md files in this repo are full of em-dashes and arrows, which is
    what made it reachable rather than theoretical. The recordings disagree; the
    port does not.
    """
    assert CONTEXT["cap-multibyte-c"]["exit"] == 1, "pre-port: drained, then aborted"
    assert CONTEXT["cap-multibyte-c"]["stdout"] == ""
    assert json.loads(CONTEXT["cap-multibyte-c-utf-8"]["stdout"])["skills"][0]["name"] == "mb"

    answers = {}
    for label in ("cap-multibyte-c", "cap-multibyte-c-utf-8"):
        actual, payload = _context_stdout(label, tmp_path / label)
        answers[label] = actual["stdout"]
        assert [skill["name"] for skill in payload["skills"]] == ["pequeno"]
        assert payload["skillsDropped"] == [
            {"name": "mb", "bytes": 102600, "reason": "oversized"}
        ]
        assert "102600 bytes exceeds the 100KB skills cap" in actual["stderr"]
    assert answers["cap-multibyte-c"] == answers["cap-multibyte-c-utf-8"]

    # The unit under the verb, without a process: len() counts characters and is
    # the reading that was NOT kept.
    body = "—" * 34200
    assert len(body) == 34200 and len(body.encode("utf-8")) == 102600
    assert T.SKILLS_CAP == 102400


def test_an_oversized_skill_is_dropped_without_draining_its_siblings(tmp_path):
    """DECISION 2. [oversized, small, small] used to lose everything.

    The pre-port loop popped from the END until the aggregate fit, so the two
    legitimate skills went first and the oversized one last -- and the verb then
    died at the zero total, so the agent received no payload at all. Declaration
    order is priority order only if the entry that cannot fit is removed before
    the loop that trims the rest.
    """
    assert CONTEXT["cap-gigante-primeiro"]["exit"] == 1, "pre-port: drained, then aborted"
    assert CONTEXT["cap-gigante-primeiro"]["stderr"].count("dropped") == 3

    actual, payload = _context_stdout("cap-gigante-primeiro", tmp_path)
    assert [skill["name"] for skill in payload["skills"]] == ["alpha", "beta"]
    assert payload["skillsDropped"] == [
        {"name": "gigante", "bytes": 102401, "reason": "oversized"}
    ]
    assert actual["stderr"] == (
        "skill gigante dropped — 102401 bytes exceeds the 100KB skills cap on its own\n"
    )


def test_the_aggregate_cap_and_its_boundary_are_untouched(tmp_path):
    """The half that did NOT change, checked rather than assumed -- three
    recordings that still match byte for byte, including the wording of the
    warning the bash suite greps for and the `>` that makes exactly 102400 fit.
    """
    assert CONTEXT["cap-fronteira-exata"]["stderr"] == ""
    assert CONTEXT["cap-fronteira-mais-um"]["stderr"] == (
        "skill beta dropped — aggregate skills context exceeded 100KB\n"
    )
    _, exact = _context_stdout("cap-fronteira-exata", tmp_path / "exata")
    assert [skill["name"] for skill in exact["skills"]] == ["alpha", "beta"]
    actual, over = _context_stdout("cap-fronteira-mais-um", tmp_path / "mais-um")
    assert [skill["name"] for skill in over["skills"]] == ["alpha"]
    assert over["skillsDropped"] == [{"name": "beta", "bytes": 51201, "reason": "aggregate"}]
    assert actual["stderr"] == CONTEXT["cap-fronteira-mais-um"]["stderr"]


def test_eight_skills_are_read_once_each_and_assembled_in_declaration_order(tmp_path):
    """The quadratic's own case, run rather than described.

    Eight bodies in, eight entries out, in the order the story declared them,
    each file opened exactly once. The pre-port loop produced the same eight
    entries -- which is exactly why this cannot be an output comparison and why
    the structural assertion below it exists.
    """
    base = tmp_path / "skills"
    names = ["um", "dois", "tres", "quatro", "cinco", "seis", "sete", "oito"]
    for name in names:
        (base / name).mkdir(parents=True)
        (base / name / "SKILL.md").write_text("corpo de " + name + "\n", encoding="utf-8")

    warnings = []
    entries, dropped = T.skills_payload(names, str(base), warnings.append)
    assert [entry["name"] for entry in entries] == names
    assert [entry["path"] for entry in entries] == [
        "skills/" + name + "/SKILL.md" for name in names
    ]
    assert [entry["content"] for entry in entries] == ["corpo de " + name for name in names]
    assert dropped == [] and warnings == []


def test_the_skills_array_is_serialized_once_rather_than_once_per_skill():
    """The quadratic, asserted structurally because it cannot be asserted from
    the outside: the payload of an N-skill story looks identical either way.

    The pre-port loop fed the whole accumulated array back through
    `jq -n --argjson existing "$skills_json"` on every iteration, so N skills
    serialized N(N+1)/2 bodies. Here a body is appended to a list once and the
    list reaches JSON exactly once, in the single _emit at the end of the verb.
    """
    payload = _code().split("def skills_payload", 1)[1].split("\ndef ", 1)[0]
    assert "json.dumps" not in payload and "_emit" not in payload
    assert payload.count("kept.append(") == 1
    op = _code().split("def op_get_story_context", 1)[1].split("\ndef ", 1)[0]
    assert op.count("_emit(") == 1


def test_the_decisions_scanner_is_the_awk_pipeline_and_truncates_at_65536():
    """The unit, over the shapes the corpus records: a `### ` heading stays
    inside the section, a `## ` heading closes it, a second `## Design Decisions`
    does NOT (awk tested that rule first and skipped the closing one), the match
    is a PREFIX so a suffixed heading opens the section, blank lines go, and the
    truncation counts bytes because `head -c` did."""
    assert T.design_decisions(b"## Design Decisions\num\n### Sub\ndois\n## Fim\ntres\n") == (
        "um\n### Sub\ndois"
    )
    assert T.design_decisions(b"## Design Decisions e mais\num\n") == "um"
    assert T.design_decisions(b"## Design Decisions\num\n## Design Decisions\ndois\n") == "um\ndois"
    assert T.design_decisions(b"## Outra\num\n") == ""
    assert T.design_decisions(b"## Design Decisions\n\n  recuada  \n\n\nfim\n") == "recuada\nfim"
    assert T.design_decisions(b"## Design Decisions\n" + b"d" * 70000) == "d" * 65536
    assert T.DECISIONS_CAP == 65536


def test_the_tag_breakout_escape_is_the_seds_two_rules_in_the_seds_order(tmp_path):
    """Both forms, and the order between them. Reversed, the opening rule would
    consume the `<` of `</required_skills` and leave `&lt;/…` behind unescaped --
    which is a tag breakout that reads as if it had been handled."""
    _, payload = _context_stdout("skill-tag-breakout", tmp_path)
    assert payload["skills"][0]["content"] == (
        "before &lt;required_skills> middle &lt;/required_skills> after\n"
        "&lt;required_skills\n&lt;/required_skills"
    )
    assert T.TAG_BREAKOUT[0][0] == "</required_skills"


def test_the_declared_list_is_read_the_way_jq_r_and_mapfile_read_it():
    """The unit for the shapes `jq -r '.[]' 2>/dev/null | mapfile -t` flattened.

    A string or a number yields NOTHING and no complaint, an object yields its
    VALUES, and a non-string element is PRETTY-printed over as many lines as it
    takes -- each of which mapfile then treats as a skill name of its own.
    """
    def named(skills):
        return T.declared_skill_names([{"userStories": [{"id": "US-001", "skills": skills}]}],
                                      "US-001")

    assert named(["alpha", "beta"]) == ["alpha", "beta"]
    assert named("alpha") == []
    assert named(7) == []
    assert named(None) == []
    assert named({"k": "alpha"}) == ["alpha"]
    assert named([["alpha"]]) == ["[", '  "alpha"', "]"]
    assert named(["a\nb"]) == ["a", "b"]
    # A story with no skills key at all is `// []`, and a MISSING story is no
    # stream to iterate rather than an error.
    assert T.declared_skill_names([{"userStories": [{"id": "US-001"}]}], "US-001") == []
    assert T.declared_skill_names([{"userStories": []}], "US-001") == []


# ---------------------------------------------------------------------------
# archive-task: the same evidence, over a filesystem instead of a document
# ---------------------------------------------------------------------------

ARCHIVE = {c["label"]: c for c in GOLDEN["archive_cases"]}

# Six fields, and `tree` is the load-bearing one. For a verb that moves and
# deletes, a comparison of stdout and an exit code would pass just as happily
# while the task file was being removed instead of relocated, and a refusal
# that had already deleted something would look identical to one that had not.
ARCHIVE_FIELDS = ("exit", "stdout", "stderr", "file", "tree", "outside_after")


def _archive_listing(top, root, base, skip=None):
    """The capture's own listing, rebuilt: directories with a trailing slash,
    symlinks as `path -> target`, everything relative to `top` and sorted."""
    entries = []
    for dirpath, dirnames, filenames in os.walk(top, followlinks=False):
        dirnames.sort()
        for name in list(dirnames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, top)
            if skip and (rel == skip or rel.startswith(skip + os.sep)):
                dirnames.remove(name)
                continue
            if os.path.islink(full):
                dirnames.remove(name)
                entries.append(rel + " -> " + _archive_norm(os.readlink(full), root, base))
            else:
                entries.append(rel + "/")
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, top)
            if skip and rel.startswith(skip + os.sep):
                continue
            if os.path.islink(full):
                entries.append(rel + " -> " + _archive_norm(os.readlink(full), root, base))
            else:
                entries.append(rel)
    return sorted(entries)


def _archive_norm(text, root, base):
    text = text.replace(root, "/TMP").replace(base, "/OUTSIDE").replace(CLI, "/CLI/aimi-cli.sh")
    return _BASH_LINE.sub(r"\1: line <N>:", text)


def _replay_archive(case, tmp_path):
    """Rebuild the case's WHOLE base directory -- the project root and the
    fixtures beside it -- run the CLI, and read the filesystem back.

    Separate from _replay_write because the unit under test is not the
    document: `proj/` is the project root, `fora/` sits outside it, /TMP and
    /OUTSIDE stand for the two on the way in and on the way out, and what is
    compared afterwards is every path under both.
    """
    base = os.path.realpath(str(tmp_path))
    root = os.path.join(base, "proj")
    given = case["input"]

    def sub(text):
        return text.replace("/TMP", root).replace("/OUTSIDE", base)

    os.makedirs(os.path.join(root, ".aimi", "tasks"), exist_ok=True)
    for rel, text in sorted(given["outside"].items()):
        full = os.path.join(base, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as handle:
            handle.write(sub(text))
    target = None
    if given["tasks_file"]:
        target = os.path.join(root, ".aimi", "tasks", given["tasks_file"])
        with open(target, "w", encoding="utf-8") as handle:
            handle.write(sub(given["tasks"]))
    for rel, text in sorted(given["files"].items()):
        full = os.path.join(root, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as handle:
            handle.write(sub(text))
    for rel in given["dirs"]:
        os.makedirs(os.path.join(root, rel), exist_ok=True)
    for rel, dest in sorted(given["symlinks"].items()):
        full = os.path.join(root, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        os.symlink(sub(dest), full)

    proc = subprocess.run(
        ["bash", CLI] + [sub(a) for a in case["args"]],
        cwd=root, capture_output=True, text=True, timeout=120,
    )

    contents = None
    if target and os.path.isfile(target):
        with open(target, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
        try:
            contents = json.loads(text)
        except ValueError:
            contents = _archive_norm(text, root, base)

    outside_after = {}
    for rel in _archive_listing(base, root, base, skip="proj"):
        full = os.path.join(base, rel)
        if os.path.isfile(full) and not os.path.islink(full):
            with open(full, encoding="utf-8", errors="replace") as handle:
                outside_after[rel] = _archive_norm(handle.read(), root, base)
        else:
            outside_after[rel] = None

    return {
        "exit": proc.returncode,
        "stdout": _archive_norm(proc.stdout, root, base),
        "stderr": _archive_norm(proc.stderr, root, base),
        "file": contents,
        "tree": _archive_listing(root, root, base),
        "outside_after": outside_after,
    }


# The 5 cases `_comment_archive` names, per field, in two classes. Neither is a
# rule anyone wrote. (1) jq aborted and `set -euo pipefail` took the script
# down with it, at jq's own exit status and with jq's message swallowed by the
# 2>/dev/null on the assignment that ran it -- so the recording is of an ENGINE
# abort with EMPTY stderr, and the port refuses at 1 with a message naming the
# file. (2) bash's `[` was handed one count per document and could not compare
# them; the port branches instead, so it archives the same file in silence.
# Every field NOT listed here must match byte for byte -- `file`, `tree` and
# `outside_after` are excused for nothing, which is what keeps the excuse from
# covering a side effect.
ARCHIVE_DIVERGENCES = {
    "archive-sem-userstories": ("exit", "stderr"),
    "archive-userstories-nao-lista": ("exit", "stderr"),
    "archive-json-malformado": ("exit", "stderr"),
    "archive-dois-documentos": ("stderr",),
    "archive-dois-documentos-um-aberto": ("stderr",),
}


@pytest.mark.parametrize("label", sorted(ARCHIVE), ids=sorted(ARCHIVE))
def test_the_archive_port_reproduces_the_bash(label, tmp_path):
    case = ARCHIVE[label]
    actual = _replay_archive(case, tmp_path)
    excused = ARCHIVE_DIVERGENCES.get(label, ())
    for field in ARCHIVE_FIELDS:
        if field in excused:
            continue
        assert actual[field] == case[field], label + " . " + field


def test_every_archive_record_carries_all_seven_fields():
    """`tree` is why this block exists, so a record that lost it would quietly
    turn the replay above into a comparison of stdout."""
    for label, case in sorted(ARCHIVE.items()):
        for field in ("label", "verb", "exit", "stdout", "stderr", "file", "tree"):
            assert field in case, label + " is missing " + field
        assert isinstance(case["tree"], list) and case["tree"], label
    assert len(ARCHIVE) == 41


def test_the_archive_divergence_table_names_only_cases_that_exist():
    assert set(ARCHIVE_DIVERGENCES) <= set(ARCHIVE)
    assert len(ARCHIVE_DIVERGENCES) == 5, "the capture's comment names 5; keep the two in step"


@pytest.mark.parametrize("label", sorted(ARCHIVE_DIVERGENCES), ids=sorted(ARCHIVE_DIVERGENCES))
def test_each_excused_archive_case_keeps_its_side_effects(label, tmp_path):
    """An excused case may lose the engine's wording and its exit status. It
    may not gain -- or lose -- a single file.

    The three aborts recorded EMPTY stderr at jq's own status and still have to
    refuse. The two stream cases recorded bash's complaint at exit 0 and still
    have to archive. Either way `tree`, `file` and `outside_after` are compared
    in the replay above, so the excuse can never cover a side effect.
    """
    recorded = ARCHIVE[label]
    actual = _replay_archive(recorded, tmp_path)
    assert actual["tree"] == recorded["tree"], label
    if label.startswith("archive-dois-documentos"):
        assert recorded["stderr"].startswith("/CLI/aimi-cli.sh: line <N>: [:"), label
        assert recorded["exit"] == 0 and actual["exit"] == 0, label
        assert actual["stderr"] == "", label + ": the complaint had no rule behind it"
        return
    assert recorded["stderr"] == "" and recorded["exit"] in (4, 5), label
    assert actual["exit"] != 0, label + ": an excused case still has to refuse"
    assert actual["stdout"] == "", label + ": a refusal writes nothing to stdout"
    assert actual["stderr"].startswith("Error: archive-task: "), label


def test_the_archive_corpus_exercises_every_case_it_claims_to():
    """Nine buckets, every verdict read off the RECORDING rather than
    recomputed. A corpus that only ever archived successfully would let the
    41-case replay above pass on nothing."""
    archived = lambda label: json.loads(ARCHIVE[label]["stdout"])["archived"]  # noqa: E731

    # 1. an archive that happens, and the file that is no longer where it was
    assert archived("archive-sucesso")["task"] == "/TMP/.aimi/archive/" \
        "2020-01-01-corpus-tasks.json"
    assert ARCHIVE["archive-sucesso"]["file"] is None
    assert ".aimi/tasks/2020-01-01-corpus-tasks.json" not in ARCHIVE["archive-sucesso"]["tree"]
    # 2. one refused for a story that is not terminal, with NOTHING touched
    refused = ARCHIVE["archive-nao-terminal"]
    assert refused["exit"] == 1 and refused["file"] == json.loads(refused["input"]["tasks"])
    assert refused["stderr"] == "Error: Task file has non-terminal stories — cannot archive\n"
    assert ".aimi/tasks/2020-01-01-corpus-tasks.json" in refused["tree"]
    # 3. a researchPath naming a file that is not there: skipped, and NOT counted
    assert archived("archive-research-ausente")["researchCleaned"] == 1
    assert archived("archive-research-e-prototype") == {
        "task": "/TMP/.aimi/archive/2020-01-01-corpus-tasks.json",
        "brainstorm": None, "researchCleaned": 2, "prototypeCleaned": 1,
    }
    # 4. a researchPath outside the project: refused, and the target still there
    escape = ARCHIVE["archive-research-absoluto-fora"]
    assert escape["exit"] == 1
    assert escape["stderr"].startswith("Error: Path escapes project root")
    assert escape["outside_after"]["fora/absoluto.md"] == "alvo absoluto\n"
    # ... AFTER the task file has already moved. A refusal with a side effect.
    assert ".aimi/archive/2020-01-01-corpus-tasks.json" in escape["tree"]
    # 5. the -N suffix, twice over, and its split on the FIRST dot
    assert archived("archive-colisao")["task"].endswith("2020-01-01-corpus-tasks-2.json")
    assert archived("archive-colisao-multipla")["task"].endswith("2020-01-01-corpus-tasks-3.json")
    assert archived("archive-colisao-ponto-precoce")["task"].endswith("corpus-2.v2-tasks.json")
    # 6. the companion lock, which the archive directory ends up holding
    assert ".aimi/archive/2020-01-01-corpus-tasks.json.lock" in ARCHIVE[
        "archive-lock-acompanha"]["tree"]
    assert ".aimi/tasks/2020-01-01-corpus-tasks.json.lock" not in ARCHIVE[
        "archive-lock-acompanha"]["tree"]
    # 7. .aimi/archive that did not exist, made on the way past
    assert ".aimi/archive/" in ARCHIVE["archive-sem-diretorio-archive"]["tree"]
    # 8. a directory named as a file to delete: refused, contents intact
    directory = ARCHIVE["archive-research-diretorio"]
    assert directory["exit"] == 1
    assert directory["stderr"] == (
        "rm: cannot remove '/TMP/.aimi/research/pasta': Is a directory\n"
    )
    assert ".aimi/research/pasta/sub/dentro-2.md" in directory["tree"]
    # 9. userStories: [] -- archived here, and NOT listed by list-archivable
    assert ARCHIVE["archive-userstories-vazio"]["exit"] == 0


# --- the deletion tests: own fixture tree, decoys, survivors as a SET -------

_ESCAPES = {
    # label -> the metadata value, and the fixture that makes it reachable
    "absoluto": "/OUTSIDE/fora/alvo.md",
    "traversal": "../fora/alvo.md",
    "symlink": ".aimi/research/link.md",
}


def _escape_tree(tmp_path, key, field):
    """One project root with three decoys and one escaping path, built here
    rather than borrowed, because what these assert is what SURVIVED."""
    base = os.path.realpath(str(tmp_path))
    root = os.path.join(base, "proj")
    os.makedirs(os.path.join(root, ".aimi", "tasks"))
    os.makedirs(os.path.join(root, ".aimi", "research"))
    os.makedirs(os.path.join(base, "fora"))
    with open(os.path.join(base, "fora", "alvo.md"), "w", encoding="utf-8") as handle:
        handle.write("o alvo, intocado\n")
    for rel, text in (
        (".aimi/research/nao-listado.md", "decoy\n"),
        (".aimi/archive/ja-arquivado.md", "decoy\n"),
        ("fora-do-aimi.txt", "decoy\n"),
    ):
        full = os.path.join(root, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as handle:
            handle.write(text)
    if key == "symlink":
        os.symlink(os.path.join(base, "fora", "alvo.md"),
                   os.path.join(root, ".aimi", "research", "link.md"))
    tasks = os.path.join(root, ".aimi", "tasks", "t-tasks.json")
    with open(tasks, "w", encoding="utf-8") as handle:
        json.dump({
            "schemaVersion": "3.3",
            "metadata": {"title": "t", field: [_ESCAPES[key].replace("/OUTSIDE", base)]},
            "userStories": [{"id": "US-001", "status": "completed"}],
        }, handle)
    with open(tasks + ".lock", "w", encoding="utf-8") as handle:
        handle.write("")
    proc = subprocess.run(["bash", CLI, "archive-task", ".aimi/tasks/t-tasks.json"],
                          cwd=root, capture_output=True, text=True, timeout=120)
    return base, root, proc


@pytest.mark.parametrize("key", sorted(_ESCAPES), ids=sorted(_ESCAPES))
@pytest.mark.parametrize("field", ("researchPaths", "prototypePaths"))
def test_an_escaping_document_path_is_refused_and_its_target_survives(key, field, tmp_path):
    """Three ways out of the project root, through both fields that delete.

    An absolute path outside it, a ../ traversal, and a symlink living INSIDE
    the project whose target resolves outside it -- the last is why the check
    has to realpath rather than string-match, and why it is asserted here
    rather than assumed from the other two.

    Each also pins the exact partial state the refusal leaves behind. The
    confinement runs after the task file and its lock have already moved, so
    the refusal HAS a side effect; a test that only checked the message would
    hide it.
    """
    base, root, proc = _escape_tree(tmp_path, key, field)
    assert proc.returncode == 1
    assert proc.stdout == ""
    assert proc.stderr.startswith("Error: Path escapes project root — access denied\n")
    assert proc.stderr.rstrip().endswith("Project root: " + root)
    # the target is still there, byte for byte
    with open(os.path.join(base, "fora", "alvo.md"), encoding="utf-8") as handle:
        assert handle.read() == "o alvo, intocado\n"
    # and the partial state is exactly this -- set equality, decoys included
    assert set(_archive_listing(root, root, base)) == {
        ".aimi/",
        ".aimi/archive/",
        ".aimi/archive/ja-arquivado.md",
        ".aimi/archive/t-tasks.json",
        ".aimi/archive/t-tasks.json.lock",
        ".aimi/research/",
        ".aimi/research/nao-listado.md",
        ".aimi/tasks/",
        "fora-do-aimi.txt",
    } | ({".aimi/research/link.md -> /OUTSIDE/fora/alvo.md"} if key == "symlink" else set())


def test_a_directory_named_as_a_file_to_delete_is_refused_and_keeps_its_contents(tmp_path):
    """THE worst thing this port could have done, asserted rather than trusted.

    `rm -f` refuses a directory and `set -e` ended the run there. If the port
    had reached for shutil.rmtree the verb would have succeeded and taken a
    whole tree with it, and every other assertion in this file would still
    pass. So the survivors are compared as a SET, and the set includes two
    files nested inside the directory.
    """
    base = os.path.realpath(str(tmp_path))
    root = os.path.join(base, "proj")
    os.makedirs(os.path.join(root, ".aimi", "tasks"))
    os.makedirs(os.path.join(root, ".aimi", "research", "pasta", "sub"))
    for rel, text in (
        (".aimi/research/pasta/dentro-1.md", "sobrevive 1\n"),
        (".aimi/research/pasta/sub/dentro-2.md", "sobrevive 2\n"),
        (".aimi/research/nao-listado.md", "decoy\n"),
        (".aimi/archive/ja-arquivado.md", "decoy\n"),
        ("fora-do-aimi.txt", "decoy\n"),
    ):
        full = os.path.join(root, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as handle:
            handle.write(text)
    tasks = os.path.join(root, ".aimi", "tasks", "t-tasks.json")
    with open(tasks, "w", encoding="utf-8") as handle:
        json.dump({
            "schemaVersion": "3.3",
            "metadata": {"title": "t", "researchPaths": [".aimi/research/pasta"]},
            "userStories": [{"id": "US-001", "status": "completed"}],
        }, handle)

    proc = subprocess.run(["bash", CLI, "archive-task", ".aimi/tasks/t-tasks.json"],
                          cwd=root, capture_output=True, text=True, timeout=120)
    assert proc.returncode == 1
    assert proc.stderr == (
        "rm: cannot remove '" + root + "/.aimi/research/pasta': Is a directory\n"
    )
    assert set(_archive_listing(root, root, base)) == {
        ".aimi/",
        ".aimi/archive/",
        ".aimi/archive/ja-arquivado.md",
        ".aimi/archive/t-tasks.json",
        ".aimi/research/",
        ".aimi/research/nao-listado.md",
        ".aimi/research/pasta/",
        ".aimi/research/pasta/dentro-1.md",
        ".aimi/research/pasta/sub/",
        ".aimi/research/pasta/sub/dentro-2.md",
        ".aimi/tasks/",
        "fora-do-aimi.txt",
    }


def test_the_archive_verb_owns_no_recursive_delete_anywhere_in_the_file():
    """The structural half of the test above: `rm -f` is one syscall and stays
    one. A future edit that reached for a recursive helper would be caught
    here even if it never ran against a directory in any fixture."""
    code = _code()
    for forbidden in ("rmtree", "removedirs", "os.walk", "shutil.rmtree"):
        assert forbidden not in code, forbidden + " has no business in tasks.py"
    body = _code().split("def _rm_f", 1)[1].split("\ndef ", 1)[0]
    assert body.count("os.unlink") == 1 and "shutil" not in body


def test_archive_task_crosses_into_python_once_and_keeps_the_argument_gate_in_bash():
    """The split the port is built on, asserted on both sides.

    Bash keeps validate_path_in_project over the <path> ARGUMENT -- it exists
    before the document is read, so an escaping argument is refused without
    python3 starting at all. tasks.py owns the paths that only exist after the
    crossing. One crossing, and no lock, because cmd_archive_task never took
    one; the lock it MOVES is the defect the docstring names and the follow-up
    owns.
    """
    body = dict(_wrappers())["cmd_archive_task"]
    assert body.count(_TASKS_CROSSING) == 1
    assert "validate_path_in_project" in body
    assert body.index("validate_path_in_project") < body.index(_TASKS_CROSSING)
    assert "_lock " not in body and "jq " not in body
    # and the ported half names the rule it reproduces rather than reinventing
    assert "def require_in_project" in _source()


# ---------------------------------------------------------------------------
# The clamp: ONE function, jq's whole value space
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "raw,clamped",
    [
        (None, 20),          # absent and null both arrive here as None
        (False, 20),         # jq's `//` fires on false as well as null
        (True, 20),          # jq orders booleans BELOW numbers, so true <= 0
        (0, 20),
        (0.0, 20),
        (-1, 20),
        (-0.5, 20),
        (1, 1),
        (4, 4),
        (20.0, 20),          # an integral float renders as 20, never 20.0
        (20.5, 20.5),
        (999999, 999999),
        ("muitos", "muitos"),      # strings order ABOVE numbers: passes through
        ([1, 2], [1, 2]),          # so do arrays
        ({"n": 3}, {"n": 3}),      # and objects
    ],
)
def test_the_clamp_reproduces_jq_over_the_whole_value_space(raw, clamped):
    assert T.clamp_max_concurrency(raw) == clamped


def test_an_integral_float_renders_as_an_int_and_not_merely_compares_equal():
    """20.0 == 20 in Python, so equality alone would pass while the CLI printed
    20.0. The type is the assertion."""
    assert isinstance(T.clamp_max_concurrency(20.0), int)
    assert json.dumps(T.clamp_max_concurrency(20.0)) == "20"


def test_a_non_number_passes_through_where_a_naive_comparison_would_raise():
    """`"muitos" <= 0` is a TypeError in Python and simply false in jq. This is
    the exact class roadmap.py's jq_sort_key exists for, and the reason the
    clamp is a function rather than an inline expression."""
    with pytest.raises(TypeError):
        assert "muitos" <= 0
    assert T.clamp_max_concurrency("muitos") == "muitos"


def _source():
    with open(os.path.join(SCRIPTS, "tasks.py"), encoding="utf-8") as handle:
        return handle.read()


def _body():
    """tasks.py past its module docstring. The docstring NAMES the things the
    code must not do -- `flock`, `cli-path` -- so scanning the whole file would
    make the explanation trip its own guard."""
    return _source().split('"""', 2)[2]


def _code():
    """_body with every FUNCTION docstring gone too.

    The same guard-tripping problem one level down: op_get_state explains that
    .aimi/state/ carries its own .state.lock, and a scan for `.lock` that could
    not tell an explanation from an implementation would force the explanation
    out of the file. Only the executable text is scanned for the forbidden
    machinery."""
    return re.sub(r'"""(?:.|\n)*?"""', "", _body())


def test_the_clamp_has_exactly_one_definition_and_all_three_call_sites_use_it():
    """The three jq copies collapsed into one function. Two status branches and
    metadata_view call it; nothing else may re-express the default."""
    source = _source()
    assert len(re.findall(r"^def clamp_max_concurrency\(", source, re.M)) == 1
    assert source.count("clamp_max_concurrency(") == 3, "one def plus two call sites"
    assert len(re.findall(r"^DEFAULT_MAX_CONCURRENCY = ", source, re.M)) == 1


# ---------------------------------------------------------------------------
# The boundary: no lock, no write, no self-resolution
# ---------------------------------------------------------------------------


def test_tasks_py_never_names_the_cli_path_cache():
    """cmd_init_session runs `resolve_path "$0"` and writes the result to both
    .aimi/state/cli-path and ~/.config/aimi/cli-path. Inside tasks.py `$0` is
    the .py file, so a port of it would make every later $AIMI_CLI resolution
    load a Python module as a shell script -- on the NEXT session, long after
    the test run that passed. The bash suite pins this too; this end catches it
    without spawning a shell."""
    body = _body()
    assert "cli-path" not in body
    assert "resolve_path" not in body


def test_tasks_py_takes_no_lock_of_its_own():
    """THE boundary the seven writers had to respect to be portable at all.

    `_lock` stays in aimi-cli.sh with both of its strategies -- `flock -x 200`
    and the `mkdir` spinlock with its stale-lock break -- and every op here runs
    inside a subshell that already holds it. A second lock implementation would
    be the duplication this port exists to remove, and a Python `flock` on a
    host that fell back to the spinlock would not even be the same lock.

    archive-task moved two words off the forbidden list and onto a counted one,
    so the guard narrowed rather than weakened. `makedirs` is now legal exactly
    once, for .aimi/archive, which `mkdir -p` made in bash; `.lock` is legal
    exactly once, naming the companion file the verb MOVES rather than one it
    acquires. Both are pinned by their whole line below, so a second use has to
    change this test. The spinlock's own shape -- a lock path built by
    suffixing another path, then `os.mkdir` on it -- is still caught outright.
    """
    code = _code()
    for forbidden in ("flock", "fcntl", "lockf", "os.mkdir"):
        assert forbidden not in code, "tasks.py must not " + forbidden
    assert [line.strip() for line in code.splitlines() if "makedirs" in line] == [
        "os.makedirs(archive_dir, exist_ok=True)"
    ]
    assert [line.strip() for line in code.splitlines() if ".lock" in line] == [
        'lock = path + ".lock"'
    ]


def test_the_only_file_tasks_py_writes_is_the_one_it_was_handed(tmp_path):
    """One writer, and the writer is atomic.

    open() appears six times and ALL SIX are read mode. The second arrived
    with validate-tasks, the one verb that reads a file other than the tasks
    file -- the DesignSpec or BusinessSpec named in metadata.designBundle,
    discovered after the crossing and therefore unreachable from bash's own
    confinement. The third and fourth arrived with get-story-context for the
    same reason: a SKILL.md under the skills base directory bash resolved, and
    the brainstorm named by metadata.brainstormPath. Each is read-only and each
    is scoped to its own call site, which is what this asserts: a SEVENTH open,
    or any of these six in a writing mode, is a new capability and has to be
    argued for rather than appear.

    The fifth and sixth arrived TOGETHER with list-known-gaps, and they are the
    first two that open a file this module was not handed a path to: a gap file
    the verb found by listing .aimi/known-gaps/, and a tasks document it found
    listing .aimi/tasks and .aimi/archive to resolve that gap's feature. Both
    are reads, both fail silently to a null answer rather than to a refusal,
    and both are bounded -- the listing that produces them stops two
    directories down and never uses a recursive traversal helper, because the
    test above bans every one of them by name and that ban is worth more than
    the four lines it costs to avoid.

    The single BYTE-writing path is write_docs_atomically, a NamedTemporaryFile
    in the TARGET's own directory followed by os.replace -- never a
    truncate-and-write, which is the one failure that could leave /aimi:execute
    reading half a tasks.json. And nothing here goes near .aimi/state/: those
    files have their own lock and their own confinement in bash, and the mark-*
    verbs still write them there.

    archive-task added the only writes here that put no bytes anywhere: one
    move and one delete. Both are counted rather than merely allowed, because
    this is the one verb that can destroy a user's files -- a second
    shutil.move, a third os.unlink or a second os.makedirs is a new capability
    in it and has to change this test to arrive.
    """
    code = _code()
    assert code.count("open(") == 6
    assert 'open(path, "r", encoding="utf-8")' in code
    assert 'open(spec_path, "rb")' in code
    assert 'open(path, "r", encoding="utf-8", errors="replace")' in code
    assert 'open(path, "rb")' in code
    assert 'open(full, "r", encoding="utf-8")' in code
    assert len(re.findall(r'open\([^)]*"[rw]b?"', code)) == 6
    assert not re.search(r'open\([^)]*"[wax]', code), "every open here is a read"
    assert len(re.findall(r"^def write_docs_atomically\(", code, re.M)) == 1
    assert code.count("os.replace(") == 1 and code.count("NamedTemporaryFile(") == 1
    assert code.count("os.unlink(") == 2, "the temp file, and _rm_f's single delete"
    assert set(re.findall(r"([\w.]+)\.write\(", code)) == {
        "sys.stdout",
        "sys.stderr",
        "handle",
    }
    # The two writes that move bytes instead of producing them, each exactly
    # once and each pinned to its whole line.
    assert [line.strip() for line in code.splitlines() if "shutil." in line] == [
        "shutil.move(src, dest)"
    ]
    assert [line.strip() for line in code.splitlines() if "os.unlink(" in line] == [
        "os.unlink(handle.name)",
        "os.unlink(path)",
    ]
    # Thirty-seven os.path calls, and the module still names no path of its own
    # -- not .aimi/state/, not a lock, not a sibling file. Two live in
    # write_docs_atomically, two are validate-tasks' isfile() per spec, eight
    # are confined_spec_path resolving and comparing, three arrived with
    # get-story-context (two isfile() probes for a skill -- the bare directory,
    # then OpenCode's aimi- prefixed one -- and one for the brainstorm), and
    # thirteen with archive-task: five in require_in_project, which is
    # validate_path_in_project's three arms ported whole, four in archive_move
    # probing for a free destination, three in the op itself and one in the
    # basename(1) twin. The twenty-ninth is research_path_lines' isfile(), which
    # is `[ -f "$f" ] || continue` and does double duty as the guard against an
    # unmatched glob arriving as its own literal. Every path any of them touches
    # arrived as an argument or was concatenated onto one that did -- the skills
    # base directory, PROJECT_ROOT, the archive directory and the tasks-file
    # list are all bash's answers, handed in as flags or as arguments.
    #
    # The next six arrived with list-known-gaps and they are the first that
    # name a DIRECTORY of their own: "known-gaps", "tasks" and "archive", each
    # joined onto the --aimi-dir bash handed in, plus one join and one isdir()
    # in the bounded listing that walks them. That is a real widening and it is
    # written down rather than absorbed: the rule those three still keep is the
    # one this comment is about -- no path is named that is not rooted in an
    # argument -- and what changed is that a leaf name below one now is. A
    # SEVENTH such name, or any of these three moving off --aimi-dir, is the
    # thing to argue about.
    #
    # The last two arrived with R17 and they name NOTHING of their own: a
    # dirname() and an isdir() over whatever confined_spec_path already
    # resolved, which is PROJECT_ROOT concatenated with a string the document
    # supplied. So the count moves while the rule this comment is about does
    # not -- R17 reads a directory the tasks file named, never one tasks.py
    # chose. It is also the second isdir() in the module, and the first that
    # asks whether a path the plan CITES is real rather than whether one the
    # CLI walks is.
    assert code.count("os.path.") == 37
    assert code.count("os.path.isfile(") == 7
    assert code.count("os.path.isdir(") == 2
    confinement = code.split("def confined_spec_path", 1)[1].split("\ndef ", 1)[0]
    assert confinement.count("os.path.") == 8
    archive_confinement = code.split("def require_in_project", 1)[1].split("\ndef ", 1)[0]
    assert archive_confinement.count("os.path.") == 5

    # and the atomicity is real, not merely spelled: the target is replaced by
    # a file that was complete before it had the target's name.
    target = tmp_path / "x-tasks.json"
    target.write_text('{"userStories": []}\n', encoding="utf-8")
    T.write_docs_atomically(str(target), [{"userStories": [{"id": "US-001"}]}])
    assert json.loads(target.read_text(encoding="utf-8"))["userStories"][0]["id"] == "US-001"
    assert sorted(os.listdir(str(tmp_path))) == ["x-tasks.json"]

    class Unserializable:
        pass

    with pytest.raises(TypeError):
        T.write_docs_atomically(str(target), [{"bad": Unserializable()}])
    assert sorted(os.listdir(str(tmp_path))) == ["x-tasks.json"], "no temp file survives a failure"
    assert json.loads(target.read_text(encoding="utf-8"))["userStories"][0]["id"] == "US-001"


_WRAPPER = re.compile(r"^(cmd_\w+)\(\) \{\n(.*?)^\}$", re.M | re.S)
_TASKS_CROSSING = 'python3 "$(_aimi_tasks_py)"'
_ROADMAP_CROSSING = 'python3 "$(_aimi_roadmap_py)"'
# The lock a tasks.json verb takes, and the ONLY thing the check below selects
# on. See _locked_tasks_wrappers for why the crossing cannot be part of it.
_TASKS_LOCK = '_lock "${tasks_file}.lock"'


def _wrappers():
    with open(CLI, encoding="utf-8") as handle:
        return _WRAPPER.findall(handle.read())


def _locked_tasks_wrappers(wrappers):
    """Every wrapper that takes the tasks-file lock -- crossing or no crossing.

    The filter used to read `"_lock " in body and _TASKS_CROSSING in body`, and
    that second conjunct was a hole exactly one verb wide: a locked tasks
    wrapper making ZERO crossings was discarded HERE, before the exhaustive set
    comparison below could notice it was missing. cmd_set_execution_mode sat in
    it for as long as it existed -- reading its phase guard with jq outside the
    lock, writing with a second jq inside it, and satisfying a check that
    counted python3 calls by making none.

    Counting crossings only in the wrappers that already call python3 cannot
    catch the wrapper that calls none, so the selection is the LOCK. Every
    wrapper that serializes on a tasks file is answerable to the invariant,
    whatever it happens to serialize.
    """
    return {name: body for name, body in wrappers if _TASKS_LOCK in body}


def _assert_one_crossing_inside_the_lock(name, body):
    """The invariant itself, applied to one wrapper.

    Zero and more-than-one get their own message because they are different
    defects: zero is a verb that reached Python not at all and is doing its own
    document work in bash, more than one is a verb whose read and its write are
    separated by the lock. A shared message would report each as the other's
    diagnosis.
    """
    crossings = body.count(_TASKS_CROSSING)
    assert crossings != 0, name + " takes the tasks lock and never crosses into Python"
    assert crossings == 1, name + " crosses more than once"
    assert body.index('_lock "') < body.index(_TASKS_CROSSING), name
    assert body.index(_TASKS_CROSSING) < body.index('200>"'), name


def test_every_locked_tasks_verb_crosses_into_python_exactly_once():
    """THE structural invariant, and the reason it is worth having.

    "Did concurrency change?" is a question a reviewer cannot answer by reading
    a diff. "How many times does this wrapper call python3?" is one they can,
    and the two are the same question: a verb that crosses once, inside the
    lock, has nowhere left to put an unlocked read. cascade-skip, gate-pass,
    gate-fail and reset-orphaned each crossed twice or three times with the
    lock around only one of them, and each lost a race because of it.

    More than one crossing in a tasks verb is the defect, not a style choice.
    The two roadmap verbs that legitimately cross twice are asserted here by
    name so the exception list cannot grow quietly: a payload arrives on their
    stdin and can be refused without reading roadmap.json at all, so refusing
    inside the lock would create the feature directory as a side effect of
    saying no. No tasks verb takes a stdin payload, so none of them qualifies.

    Readers are exempt from the lock half and not from the counting half:
    cmd_list_ready names the module in each of two mutually exclusive branches,
    which is one crossing per invocation. The check below is scoped to the
    wrappers that take the lock, where "per invocation" and "per body" agree.

    Selection is by the LOCK alone. It used to require a crossing to be present
    before it would count crossings, which let cmd_set_execution_mode through
    for making none -- see _locked_tasks_wrappers, and see the test below it
    for the demonstration that the widened filter actually bites.
    """
    wrappers = _wrappers()
    locked = _locked_tasks_wrappers(wrappers)
    assert set(locked) == {
        "cmd_mark_in_progress",
        "cmd_mark_complete",
        "cmd_mark_failed",
        "cmd_mark_skipped",
        "cmd_update_field",
        "cmd_set_execution_mode",
        "cmd_normalize_status",
        "cmd_normalize_verification",
        "cmd_cascade_skip",
        "cmd_reset_orphaned",
        "cmd_gate_pass",
        "cmd_gate_fail",
    }
    for name, body in sorted(locked.items()):
        _assert_one_crossing_inside_the_lock(name, body)

    two_crossings = [
        name for name, body in wrappers if body.count(_ROADMAP_CROSSING) > 1
    ]
    assert two_crossings == ["cmd_roadmap_init", "cmd_roadmap_amend_phase"]

    # And the branch exemption is exactly one wrapper wide, named here so a
    # second one cannot arrive by claiming to be a branch.
    branched = [name for name, body in wrappers if body.count(_TASKS_CROSSING) > 1]
    assert branched == ["cmd_list_ready"]
    assert "_lock " not in dict(wrappers)["cmd_list_ready"]


# cmd_set_execution_mode exactly as it stood before this check was widened:
# the jq phase guard read outside the lock, the jq assignment into a bash
# mktemp file inside it, and not one crossing into Python anywhere. Kept
# verbatim rather than paraphrased, because the point of the test below is that
# THIS body used to pass.
_ZERO_CROSSING_WRAPPER = r"""  local mode="$1"
  local tasks_file

  if [ "$mode" != "container" ] && [ "$mode" != "inline" ]; then
    echo "Error: Invalid execution mode: $mode (expected container or inline)" >&2
    exit 1
  fi

  tasks_file=$(get_tasks_file)

  local has_phase
  has_phase=$(jq -r 'if (.metadata.phase // null) != null then "true" else "false" end' "$tasks_file")
  if [ "$has_phase" = "true" ]; then
    echo "Error: Cannot set metadata.execution on a phase-scoped tasks file (metadata.phase is present): $tasks_file" >&2
    exit 1
  fi

  local tmp_file
  tmp_file=$(mktemp "${tasks_file}.XXXXXX")
  (
    _lock "${tasks_file}.lock"
    jq --arg mode "$mode" \
      '.metadata.execution = $mode' \
      "$tasks_file" > "$tmp_file" && mv "$tmp_file" "$tasks_file"
  ) 200>"${tasks_file}.lock"
  rm -f "$tmp_file" 2>/dev/null

  printf '{"execution":"%s"}\n' "$mode"
"""


def test_the_widened_check_rejects_a_locked_tasks_verb_that_never_crosses():
    """The hole, and the proof that it is shut.

    A test that only passes says nothing about what it was written to catch, so
    the pre-change wrapper is replayed through the check as a fixture. Three
    things are asserted about it, in the order they went wrong:

      * the OLD filter dropped it -- `_lock` and a crossing, conjoined, and it
        had only the first, so the exhaustive set below never got a vote;
      * the NEW filter keeps it, because the lock alone selects;
      * and the check then FAILS it, naming zero crossings rather than the
        more-than-one diagnosis that belongs to a different defect.
    """
    pre_change = [("cmd_set_execution_mode", _ZERO_CROSSING_WRAPPER)]

    assert _TASKS_CROSSING not in _ZERO_CROSSING_WRAPPER
    assert not [
        name
        for name, body in pre_change
        if "_lock " in body and _TASKS_CROSSING in body
    ], "the old filter discarded it, which is how it hid"
    assert set(_locked_tasks_wrappers(pre_change)) == {"cmd_set_execution_mode"}

    with pytest.raises(AssertionError) as zero:
        _assert_one_crossing_inside_the_lock(
            "cmd_set_execution_mode", _ZERO_CROSSING_WRAPPER
        )
    assert "never crosses into Python" in str(zero.value)

    # And the other failure mode still reports itself, so neither one can be
    # read as the other. This body crosses twice, with the lock around the
    # second only -- the shape cascade-skip and the two gates each lost a race
    # to before they were moved.
    twice = (
        '  tasks_file=$(get_tasks_file)\n'
        '  python3 "$(_aimi_tasks_py)" status --tasks-file "$tasks_file"\n'
        '  (\n'
        '    _lock "${tasks_file}.lock"\n'
        '    python3 "$(_aimi_tasks_py)" mark-complete --tasks-file "$tasks_file"\n'
        '  ) 200>"${tasks_file}.lock"\n'
    )
    assert set(_locked_tasks_wrappers([("cmd_twice", twice)])) == {"cmd_twice"}
    with pytest.raises(AssertionError) as more:
        _assert_one_crossing_inside_the_lock("cmd_twice", twice)
    assert "crosses more than once" in str(more.value)


# ---------------------------------------------------------------------------
# verification-report -- one read answering ten command-layer jq programs
# ---------------------------------------------------------------------------
#
# There is no dedicated golden block for this verb: it never existed as a jq
# program of its own inside aimi-cli.sh, so there is no "port reproduces jq"
# corpus to replay. What IS recorded, in command_block_jq_cases (story 01),
# is what the TEN command-layer sites this verb replaces answered before the
# replacement -- captured by running their own jq programs against a
# 26-fixture corpus. The tests below are proven against THAT recording,
# per this story's own AC: never against a fresh reading of execute.md or of
# this file.

_CB_SITES = {s["id"]: s for s in GOLDEN["command_block_jq_sites"]}
_CB_CASES = {}
for _case in GOLDEN["command_block_jq_cases"]:
    _CB_CASES.setdefault(_case["site"], {})[_case["fixture"]] = _case

# site-001 (VISUAL_STORIES, Step 0.7) and site-002 (MALFORMED_VERIF, Step 0.7)
# both run over every one of the 26 fixtures, so either one names the full set.
_CB_FIXTURES = sorted(_CB_CASES["site-001"])


@pytest.mark.parametrize("fixture", _CB_FIXTURES)
def test_verification_report_matches_story_01s_visual_and_malformed_counts(fixture):
    """`len(.visual)` and the malformed partition's total, against every one
    of the 26 fixtures site-001 (`[.userStories[] | select(.verification |
    type == "object" and .strategy == "visual")] | length`) and site-002
    (`[.userStories[] | select(.verification != null and (.verification |
    type != "object"))] | length`) were recorded against.

    `malformed-document` is excluded: it is unparseable JSON, refused before
    `verification_report` is even reached (read_docs' own job, same as every
    other verb) -- there is no doc to build. `userstories-absent` is the one
    fixture where jq itself aborted (`.userStories[]` cannot iterate over a
    missing key, recorded as exit 5); this verb raises the same MalformedTasks
    every other reader already raises for it, checked separately below.
    """
    if fixture == "malformed-document":
        pytest.skip("unparseable JSON -- read_docs' refusal, not this verb's")
    visual_case = _CB_CASES["site-001"][fixture]
    malformed_case = _CB_CASES["site-002"][fixture]
    doc = json.loads(visual_case["input"])
    if fixture == "userstories-absent":
        with pytest.raises(T.MalformedTasks):
            T.verification_report(doc)
        assert visual_case["exit"] != 0 and malformed_case["exit"] != 0
        return
    report = T.verification_report(doc)
    assert str(len(report["visual"])) == visual_case["stdout"].strip()
    total_malformed = len(report["malformed"]["repairable"]) + len(
        report["malformed"]["unrepairable"]
    )
    assert str(total_malformed) == malformed_case["stdout"].strip()


def test_verification_report_url_matches_story_01s_object_fixtures():
    """site-023's FIRST_VISUAL, narrowed to the one field every per-story url
    site actually reads off it. The two object fixtures are the ones with a
    visual story at all; every other fixture's `.visual` is empty."""
    with_url = json.loads(_CB_CASES["site-023"]["verification-object-with-url"]["input"])
    no_url = json.loads(_CB_CASES["site-023"]["verification-object-no-url"]["input"])
    assert T.verification_report(with_url)["visual"] == [
        {
            "id": "US-001",
            "project": None,
            "url": "http://localhost:4000/y",
            "status": "pending",
        }
    ]
    assert T.verification_report(no_url)["visual"] == [
        {"id": "US-001", "project": None, "url": "", "status": "pending"}
    ]


def test_verification_report_partitions_malformed_by_repairability():
    """`normalize-verification-formas` (tasks_write_cases) already carries
    every shape the malformed scan cares about: a bare string, an absent
    field, null, a well-formed object, the EMPTY string, a number and an
    array. Reused rather than re-authored, per this story's own instruction
    to prove against what story 01 (and, for this one shape, the
    normalize-verification corpus already landed) recorded.

    `_verification_migrated` migrates US-001 (string) and US-005 (empty
    string) and leaves the rest untouched (WRITE["normalize-verification-
    -formas"] proves that above) -- this partition has to agree BY
    CONSTRUCTION, because it reuses the same `isinstance(..., str)` test.
    """
    doc = json.loads(WRITE["normalize-verification-formas"]["input"]["tasks"])
    report = T.verification_report(doc)
    assert report["malformed"]["repairable"] == ["US-001", "US-005"]
    assert report["malformed"]["unrepairable"] == ["US-006", "US-007"]
    # US-002 (absent), US-003 (null) and US-004 (a well-formed object) are
    # malformed under NEITHER half -- the union is exactly today's four ids,
    # not all seven stories in the file.
    union = set(report["malformed"]["repairable"] + report["malformed"]["unrepairable"])
    assert union == {"US-001", "US-005", "US-006", "US-007"}
    assert report["visual"] == [], "none of these seven declare strategy: visual"


def test_verification_report_treats_a_boolean_verification_as_unrepairable():
    """The malformed scan's own set is `verification != null and (type !=
    "object")` -- string, number, array OR boolean. The write corpus has no
    boolean case (normalize-verification-formas' seven shapes do not include
    one), so this is asserted directly rather than reused."""
    doc = {"userStories": [{"id": "US-001", "verification": True}]}
    report = T.verification_report(doc)
    assert report["malformed"] == {"repairable": [], "unrepairable": ["US-001"]}


def test_verification_report_closes_the_array_valued_project_hazard():
    """VISUAL_GROUP_KEYS (site-021) fed `.project` straight to `jq -r`: an
    ARRAY-valued project pretty-printed across several lines and turned one
    story into several bogus group keys downstream -- the defect this story's
    notes name as already measured elsewhere as four errors from one story.

    Deliberate divergence, not a preserved hazard: this verb collapses any
    non-string `.project` to `None` at its one source, so every caller's own
    `// "DEFAULT"` (or `// "."`) fires on exactly the shapes that used to
    explode, and a downstream `unique` sees ONE value, not several.
    """
    doc = {
        "userStories": [
            {
                "id": "US-001",
                "project": ["apps/web", "apps/api"],
                "verification": {"strategy": "visual", "status": "pending"},
            }
        ]
    }
    report = T.verification_report(doc)
    assert report["visual"] == [
        {"id": "US-001", "project": None, "url": "", "status": "pending"}
    ]


def test_verification_report_closes_the_non_string_url_hazard():
    """The three per-story url sites guarded with `// empty`, which jq fires
    on null and false alone -- an ARRAY-valued `.verification.url` sailed
    through unrewritten and would have reached `$WORKTREE_MGR serve url` as
    `jq -r`'s multi-line pretty-print of it. Same divergence as the project
    hazard above, applied to url: any non-string collapses to the empty
    string every caller already treats as "no url"."""
    doc = {
        "userStories": [
            {
                "id": "US-001",
                "verification": {
                    "strategy": "visual",
                    "status": "pending",
                    "url": ["http://a", "http://b"],
                },
            }
        ]
    }
    report = T.verification_report(doc)
    assert report["visual"] == [
        {"id": "US-001", "project": None, "url": "", "status": "pending"}
    ]


def test_verification_report_passes_a_string_project_through_unchanged():
    """The divergence above is scoped to non-string shapes only -- a real
    project string is exactly what the per-group filter sites match on, and
    has to survive untouched."""
    doc = {
        "userStories": [
            {
                "id": "US-001",
                "project": "apps/web",
                "verification": {"strategy": "visual", "status": "pending", "url": "http://x/y"},
            }
        ]
    }
    report = T.verification_report(doc)
    assert report["visual"] == [
        {
            "id": "US-001",
            "project": "apps/web",
            "url": "http://x/y",
            "status": "pending",
        }
    ]


def test_verification_report_ignores_a_well_formed_non_visual_object():
    """`.strategy != "visual"` on an otherwise well-formed verification object
    is neither visual NOR malformed -- the object-typed branch of the old
    scan's `type == "object"` guard, which this partition never reaches."""
    doc = {
        "userStories": [
            {"id": "US-001", "verification": {"strategy": "manual", "status": "pending"}}
        ]
    }
    report = T.verification_report(doc)
    assert report == {
        "visual": [],
        # non-visual, but its verification WAS declared and nobody looked at
        # it -- the pending partition is scoped by status, never by strategy.
        "pending": ["US-001"],
        "malformed": {"repairable": [], "unrepairable": []},
    }


def test_pending_names_every_declared_status_whatever_the_strategy():
    """The partition is scoped by `.verification.status`, not by strategy: a
    test story and a visual story left at "pending" both enter, in document
    order, and a story someone HAS judged -- passed, failed, skipped -- does
    not. There is no recorded jq site to replay this against; no command-layer
    program ever asked this question, which is why the completed gate had
    nothing to read."""
    doc = {
        "userStories": [
            {"id": "US-001", "verification": {"strategy": "test", "status": "pending"}},
            {"id": "US-002", "verification": {"strategy": "visual", "status": "pending"}},
            {"id": "US-003", "verification": {"strategy": "test", "status": "passed"}},
            {"id": "US-004", "verification": {"strategy": "visual", "status": "failed"}},
            {"id": "US-005", "verification": {"strategy": "test", "status": "skipped"}},
        ]
    }
    assert T.verification_report(doc)["pending"] == ["US-001", "US-002"]


def test_pending_excludes_a_story_that_declared_no_verification_at_all():
    """The boundary the partition exists inside: absent and null verifications
    are NOT pending. They are the shape every legacy phase is made of -- the
    stories written before the field existed -- and counting them would fail
    each of those phases at its completed gate for a verification nobody ever
    promised. Only the object branch is reached; `_status_defaulted`'s
    `//= "pending"` is about a STORY's own status and has no counterpart here.
    """
    doc = {
        "userStories": [
            {"id": "US-001"},
            {"id": "US-002", "verification": None},
            {"id": "US-003", "verification": {"strategy": "test", "status": "pending"}},
        ]
    }
    assert T.verification_report(doc)["pending"] == ["US-003"]


def test_pending_matches_the_literal_and_never_a_near_miss():
    """`jq_equal(status, "pending")` -- the same total-order comparison the
    strategy test uses, so a boolean, a number or an array named where a
    status belongs is not "pending" by Python's own looser rules either. The
    malformed partition never sees these: the verification itself is a
    well-formed object, only its `status` is not a string."""
    doc = {
        "userStories": [
            {"id": "US-001", "verification": {"strategy": "test", "status": "Pending"}},
            {"id": "US-002", "verification": {"strategy": "test", "status": ["pending"]}},
            {"id": "US-003", "verification": {"strategy": "test", "status": True}},
            {"id": "US-004", "verification": {"strategy": "test", "status": ""}},
            {"id": "US-005", "verification": {"strategy": "test"}},
        ]
    }
    report = T.verification_report(doc)
    assert report["pending"] == []
    assert report["malformed"] == {"repairable": [], "unrepairable": []}


def test_a_visual_entrys_status_reports_what_was_declared_and_collapses_the_rest():
    """The field a caller wanting "did the visual check pass?" used to reopen
    the file for. A string passes through (`passed` here, and the empty string
    survives as itself); every other shape -- absent, null, an array --
    collapses to `None`, the same divergence `_report_project` makes, so no
    entry can claim a status the `pending` list refuses to count."""
    doc = {
        "userStories": [
            {"id": "US-001", "verification": {"strategy": "visual", "status": "passed"}},
            {"id": "US-002", "verification": {"strategy": "visual", "status": ""}},
            {"id": "US-003", "verification": {"strategy": "visual"}},
            {"id": "US-004", "verification": {"strategy": "visual", "status": None}},
            {"id": "US-005", "verification": {"strategy": "visual", "status": ["a"]}},
        ]
    }
    assert [entry["status"] for entry in T.verification_report(doc)["visual"]] == [
        "passed",
        "",
        None,
        None,
        None,
    ]


@pytest.mark.parametrize("fixture", _CB_FIXTURES)
def test_pending_stays_inside_the_object_branch_across_story_01s_corpus(fixture):
    """The two new partitions read against every fixture story 01 recorded,
    rather than against hand-written documents alone: whatever a fixture
    holds, a `pending` id always belongs to a story whose verification is an
    OBJECT carrying the literal, and never to one of the malformed ids the
    same run reports. Nothing here regenerates a recording -- the corpus is
    read for its INPUTS, and the verdict is this verb's own."""
    if fixture == "malformed-document":
        pytest.skip("unparseable JSON -- read_docs' refusal, not this verb's")
    doc = json.loads(_CB_CASES["site-001"][fixture]["input"])
    if fixture == "userstories-absent":
        with pytest.raises(T.MalformedTasks):
            T.verification_report(doc)
        return
    report = T.verification_report(doc)
    by_id = {story.get("id"): story for story in doc["userStories"]}
    for story_id in report["pending"]:
        verification = by_id[story_id]["verification"]
        assert isinstance(verification, dict)
        assert verification.get("status") == "pending"
    malformed = set(report["malformed"]["repairable"] + report["malformed"]["unrepairable"])
    assert malformed.isdisjoint(report["pending"])


# ---------------------------------------------------------------------------
# project_groups -- proven against story 01's own recorded corpus
# (golden_from_jq.json's command_block_jq_cases, site-013 and site-007) below,
# then against the deliberate divergences this verb introduces on top of it.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "fixture,groups",
    [
        ("no-metadata", ["apps/api", "apps/web"]),
        ("stories-with-project", ["."] + ["apps/api", "apps/web"]),
        ("stories-without-project", ["."]),
        ("all-completed", ["."]),
        ("splitgroup-present-siblings-populated", ["apps/api", "apps/web"]),
    ],
)
def test_project_groups_matches_story_01s_recorded_group_lists(fixture, groups):
    """Replays site-013's own recorded `input` (Derive Participating Project
    Groups, execute.md) -- the group list this verb must reproduce is the
    BLOCK's end state (sorted, unique, blank-dropped, "." for a groupless
    file), not the raw jq stream site-013 recorded, which never sorted or
    deduped. `stories-with-project` is the one fixture whose raw jq output
    (`apps/api\\napps/web\\n.`) already contains three DISTINCT values, so its
    expected groups are the full sorted-unique set of all three."""
    case = _CB_CASES["site-013"][fixture]
    doc = json.loads(case["input"])
    result = T.project_groups(doc)
    assert result["groups"] == sorted(set(groups))


def test_project_groups_userstories_absent_refuses_like_the_grouping_sites_did():
    """site-013's `.userStories[]` (strict) errored on this fixture (exit 5,
    "Cannot iterate over null"); site-007's guard `.userStories[]?` (lenient)
    answered a silent 0 on the SAME fixture. One verb now answers both
    questions, and this asserts it keeps the STRICTER of the two: a malformed
    document must refuse, not silently agree with the guard."""
    case = _CB_CASES["site-013"]["userstories-absent"]
    doc = json.loads(case["input"])
    assert case["stderr"].startswith("jq: error") and "Cannot iterate over null" in case["stderr"]
    with pytest.raises(T.MalformedTasks):
        T.project_groups(doc)


def test_project_groups_userstories_empty_answers_the_dot_group_and_zero_count():
    """site-013 itself printed nothing for `userStories: []` (its `stdout` is
    empty) -- the "." fallback is bash's `[ -n ... ] || X="."` line, which this
    verb must reproduce since the whole block's end state is the contract, not
    the raw jq stream."""
    case = _CB_CASES["site-013"]["userstories-empty"]
    doc = json.loads(case["input"])
    assert case["stdout"] == ""
    assert T.project_groups(doc) == {"groups": ["."], "projectStoryCount": 0}


def test_project_groups_distinguishes_a_literal_dot_project_from_no_project():
    """The routability guard's own reason for existing: a story authored with
    `project: "."` and a project-less story both collapse into the same "."
    group, but only the first should count toward `projectStoryCount` -- the
    guard's `(.project // null) != null` question. Story 01's own
    `stories-with-project` fixture carries exactly this pair (a `.` project
    alongside two named ones), so this reuses it rather than inventing a
    second fixture."""
    case = _CB_CASES["site-013"]["stories-with-project"]
    doc = json.loads(case["input"])
    result = T.project_groups(doc)
    assert result == {"groups": [".", "apps/api", "apps/web"], "projectStoryCount": 3}


def test_project_groups_refuses_every_offending_value_not_just_the_first():
    """plan.md's own Phase 3e gate reports every offending value before
    stopping ('On failure: report every offending value and STOP'); this verb
    keeps that property rather than aborting at the first bad group."""
    doc = {
        "userStories": [
            {"id": "US-001", "project": "../escape"},
            {"id": "US-002", "project": "/etc/passwd"},
            {"id": "US-003", "project": "apps/web"},
        ]
    }
    with pytest.raises(T.MalformedTasks) as excinfo:
        T.project_groups(doc)
    assert '"../escape"' in str(excinfo.value)
    assert '"/etc/passwd"' in str(excinfo.value)
    assert "apps/web" not in str(excinfo.value)


def test_project_groups_dot_is_always_exempt_from_validation():
    doc = {"userStories": [{"id": "US-001"}]}
    assert T.project_groups(doc) == {"groups": ["."], "projectStoryCount": 0}


def test_project_groups_collapses_a_non_string_project_like_verification_report_does():
    """Deliberate agreement with US-003's own choice for the same field
    (`_report_project`), not a fresh decision: an array-valued `.project`
    collapses to "no project" for BOTH halves of this verb's answer -- the
    group list (closing the same jq -r multi-line-pretty-print hazard
    verification_report already closed) and `projectStoryCount` (which the
    guard's old raw `!= null` check would have counted, since a non-null
    array is not null -- a stated divergence, not an oversight)."""
    doc = {
        "userStories": [
            {"id": "US-001", "project": ["apps/web", "apps/api"]},
            {"id": "US-002", "project": "apps/api"},
        ]
    }
    result = T.project_groups(doc)
    assert result == {"groups": [".", "apps/api"], "projectStoryCount": 1}


def test_every_op_is_named_after_the_verb_that_calls_it():
    """roadmap.py needed a _VERB_FOR_OP table because its op names drifted from
    its verb names, and a diagnostic then quoted a command nobody could run.
    Keeping the names equal is what makes that table unnecessary here.

    THREE entries are not verbs and each names the bash thing it replaces
    instead. validate-story-exists and archivable-file-is-terminal name
    FUNCTIONS, so a grep finds both ends -- validate_story_exists still has a
    bash copy beside it. research-paths names the referenced-set half of
    research-gc, which is the only half that crossed: the mtime sweep and the
    brainstorm frontmatter parser are still bash's, and calling the op
    `research-gc` would promise a verb it does not implement."""
    assert set(T._OPS) == {
        "status",
        "metadata",
        "verification-report",
        "verify-probe",
        "list-known-gaps",
        "project-groups",
        "get-story",
        "get-story-context",
        "current-story",
        "get-state",
        "count-pending",
        "list-ready",
        "next-story",
        "validate-deps",
        "validate-stories",
        "validate-ids",
        "validate-waves",
        "validate-tasks",
        "validate-story-exists",
        "mark-complete",
        "mark-failed",
        "mark-in-progress",
        "mark-skipped",
        "update-field",
        "set-execution-mode",
        "normalize-status",
        "normalize-verification",
        "cascade-skip",
        "reset-orphaned",
        "archive-task",
        "gate-pass",
        "gate-fail",
        "init-session",
        "get-branch",
        "research-paths",
        "archivable-file-is-terminal",
    }
    # The four mark-* ops are one implementation built four times rather than
    # four near-copies of one jq program, which is what they were.
    assert set(T.MARK_STATUS) == {
        "mark-complete",
        "mark-failed",
        "mark-in-progress",
        "mark-skipped",
    }
    assert len(re.findall(r"^def _mark_op\(", _source(), re.M)) == 1


def test_an_unknown_op_is_refused_with_a_usage_line_and_exit_2():
    proc = subprocess.run(
        [sys.executable, os.path.join(SCRIPTS, "tasks.py"), "no-such-op"],
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 2
    assert proc.stdout == ""
    assert proc.stderr.startswith("Usage: tasks.py <")


# ---------------------------------------------------------------------------
# The jq semantics the six verbs stand on
# ---------------------------------------------------------------------------


def test_indexing_null_yields_null_because_that_is_what_makes_a_bare_document_work():
    """`.metadata.title` on a document with no metadata is null in jq, not an
    abort. Drop this and status starts refusing files it accepted for years."""
    assert T.jq_index(None, "title") is None
    assert T.status_view({"userStories": []}, True)["title"] is None
    with pytest.raises(T.MalformedTasks):
        T.jq_index("nope", "title")


def test_iterating_an_object_yields_its_values():
    """jq's `.[]` over an object is legal, which is why `userStories: {}` gets
    as far as the per-story rules instead of being refused up front."""
    assert T.jq_iterate({"a": 1, "b": 2}, ".x") == [1, 2]
    assert T.jq_iterate([1], ".x") == [1]
    with pytest.raises(T.MalformedTasks):
        T.jq_iterate(None, ".userStories")


def test_the_alternative_fires_only_on_null_and_false():
    """0, "" , [] and {} are all truthy in jq, so `.dependsOn // []` leaves an
    empty string alone and `.maxConcurrency // 20` leaves a 0 for the clamp."""
    assert T.jq_alternative(None, "alt") == "alt"
    assert T.jq_alternative(False, "alt") == "alt"
    for kept in (0, "", [], {}, True):
        assert T.jq_alternative(kept, "alt") == kept


def test_a_null_story_is_a_row_of_nulls_and_a_string_story_is_a_refusal():
    """Recorded as historia-null and historia-nao-objeto. The first is not a
    divergence and the second is, and the difference is jq's, not ours."""
    assert T.story_row(None) == {
        "id": None,
        "title": None,
        "status": None,
        "dependsOn": [],
        "priority": None,
        "notes": None,
    }
    with pytest.raises(T.MalformedTasks):
        T.story_row("solta")


def test_metadata_absent_builds_the_object_rather_than_printing_null():
    """jq's `.metadata | .maxConcurrency = ...` assigns onto null and BUILDS an
    object, so a caller reading .maxConcurrency off `metadata` gets a number
    whatever the file looked like."""
    assert T.metadata_view({}) == {"maxConcurrency": 20}
    assert T.metadata_view({"metadata": None}) == {"maxConcurrency": 20}


def test_the_clamped_key_keeps_its_position_and_a_new_one_is_appended():
    """jq's `.k = v` leaves an existing key where it was and appends a new one.
    A diff of two `metadata` outputs stops being readable otherwise."""
    ordered = T.metadata_view({"metadata": {"a": 1, "maxConcurrency": 0, "z": 2}})
    assert list(ordered) == ["a", "maxConcurrency", "z"]
    assert ordered["maxConcurrency"] == 20
    appended = T.metadata_view({"metadata": {"a": 1, "z": 2}})
    assert list(appended) == ["a", "z", "maxConcurrency"]


def test_the_status_projection_keeps_jqs_key_order():
    view = T.status_view({"schemaVersion": "3.3", "userStories": [{"id": "US-001"}]}, False)
    assert list(view) == [
        "schemaVersion",
        "title",
        "branch",
        "maxConcurrency",
        "pending",
        "in_progress",
        "completed",
        "failed",
        "skipped",
        "total",
        "userStories",
    ]
    assert list(T.status_view({"userStories": []}, True))[-1] == "total"


def test_counts_only_omits_exactly_one_key_and_changes_nothing_else():
    """The two jq programs were identical for ten of their eleven lines and
    keeping them identical was nobody's job. Now it is structural."""
    doc = {"schemaVersion": "3.3", "metadata": {"title": "t"}, "userStories": [{"id": "US-001"}]}
    full = T.status_view(doc, False)
    counts = T.status_view(doc, True)
    assert set(full) - set(counts) == {"userStories"}
    assert {k: v for k, v in full.items() if k != "userStories"} == counts


def test_a_duplicated_story_id_still_returns_both_objects():
    """Recorded as get-id-duplicado and cur-duplicado. jq's `select` is a
    filter over a stream, not a lookup, and a tasks file carrying the same id
    twice printed both objects."""
    doc = {"userStories": [{"id": "US-001", "n": 1}, {"id": "US-001", "n": 2}]}
    assert [s["n"] for s in T.stories_with_id(doc, "US-001")] == [1, 2]
    assert T.stories_with_id(doc, "US-002") == []


def test_the_document_is_read_as_a_stream_so_empty_prints_nothing(tmp_path):
    """jq read zero values out of an empty file and exited 0, and two
    concatenated documents ran the verb twice. Both preserved -- the first is a
    silent hole a truncated write falls into, ranked and not fixed in a port."""
    empty = tmp_path / "empty.json"
    empty.write_text("", encoding="utf-8")
    assert T.read_docs(str(empty), "status") == []
    two = tmp_path / "two.json"
    two.write_text('{"a":1}\n{"a":2}\n', encoding="utf-8")
    assert T.read_docs(str(two), "status") == [{"a": 1}, {"a": 2}]
    assert CASES["doc-json-vazio-status"]["exit"] == 0
    assert CASES["doc-json-vazio-status"]["stdout"] == ""
    assert CASES["doc-json-dois-valores-metadata"]["stdout"].count("maxConcurrency") == 2


def test_get_state_maps_empty_to_null_and_never_opens_a_path():
    """The four values arrive as flags because .aimi/state/ has its own lock and
    its own confinement in read_state. An absent flag is an unset state file."""
    assert T._state_or_null("") is None
    assert T._state_or_null(None) is None
    assert T._state_or_null("x") == "x"
    assert json.loads(CASES["estado-tudo-vazio"]["stdout"]) == {
        "tasks": None,
        "branch": None,
        "story": None,
        "last": None,
    }


# ---------------------------------------------------------------------------
# init-session, get-branch, research-gc and the archivable predicate:
# the four readers the 1.123.0 port left standing
# ---------------------------------------------------------------------------

SESSION = {c["label"]: c for c in GOLDEN["session_doc_cases"]}
RESEARCH = {c["label"]: c for c in GOLDEN["research_gc_cases"]}


def _executable(text):
    """ONE function with its PROSE removed -- its docstring for Python, its `#`
    lines for bash.

    _code() above does the same for the whole of tasks.py and takes no
    argument; this is the per-function form, and the shell wrappers need it
    too. Same reason either way: these wrappers EXPLAIN what they replaced, so
    "one jq startup per file" is a sentence about a deletion, and a grep that
    could not tell it from a surviving call would force every explanation out
    of the files to keep the suite green.
    """
    text = re.sub(r'^ *"""(?:.|\n)*?"""\n', "", text, flags=re.M)
    return "\n".join(
        line for line in text.split("\n") if not line.lstrip().startswith("#")
    )

SESSION_FIELDS = ("exit", "stdout", "stderr", "state_after")
# `tree` is the load-bearing one here for the same reason it is in the archive
# block: research-gc deletes files, and its stdout is a COUNT. A comparison of
# stdout alone would pass while the wrong file was being removed.
RESEARCH_FIELDS = ("exit", "stdout", "stderr", "tree", "outside_after")


def _isolated_env(base):
    """Every path the CLI could reach outside the fixture, pointed back into it.

    init-session calls write_global_cli_cache, so a case that leaked
    AIMI_CONFIG_DIR would rewrite the developer's own ~/.config/aimi/cli-path
    while the suite ran. HOME is the fixture too, because find_aimi_root stops
    walking up there.
    """
    env = dict(os.environ)
    for name in ("AIMI_PLUGIN_DIR", "CLAUDECODE"):
        env.pop(name, None)
    env["HOME"] = base
    env["AIMI_CONFIG_DIR"] = os.path.join(base, "cfg")
    env["XDG_CONFIG_HOME"] = os.path.join(base, ".config")
    env["CLAUDE_CONFIG_DIR"] = os.path.join(base, ".claude")
    env["LC_ALL"] = "C"
    return env


def _replay_session(case, tmp_path):
    """Rebuild the project root, run the CLI, read .aimi/ back."""
    base = os.path.realpath(str(tmp_path))
    root = os.path.join(base, "proj")
    given = case["input"]

    def sub(text):
        return text.replace("/TMP", root).replace("/OUTSIDE", base)

    os.makedirs(os.path.join(root, ".aimi", "tasks"), exist_ok=True)
    for rel, text in sorted(given["files"].items()):
        full = os.path.join(root, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as handle:
            handle.write(sub(text))
    for key, value in sorted(given["state"].items()):
        with open(os.path.join(root, ".aimi", key), "w", encoding="utf-8") as handle:
            handle.write(sub(value) + "\n")

    proc = subprocess.run(
        ["bash", CLI] + [sub(a) for a in case["args"]],
        cwd=root, capture_output=True, text=True, timeout=120, env=_isolated_env(base),
    )

    state_after = {}
    aimi = os.path.join(root, ".aimi")
    for name in sorted(os.listdir(aimi)):
        full = os.path.join(aimi, name)
        if os.path.isfile(full):
            with open(full, encoding="utf-8", errors="replace") as handle:
                state_after[name] = _archive_norm(handle.read(), root, base)

    return {
        "exit": proc.returncode,
        "stdout": _archive_norm(proc.stdout, root, base),
        "stderr": _archive_norm(proc.stderr, root, base),
        "state_after": state_after,
    }


def _replay_gc(case, tmp_path):
    """Same rebuild as the archive block's, plus the one thing research-gc
    needs and no other verb does: an mtime per fixture, in days, so the 30-day
    threshold is decided by the case and not by the clock."""
    base = os.path.realpath(str(tmp_path))
    root = os.path.join(base, "proj")
    given = case["input"]

    def sub(text):
        return text.replace("/TMP", root).replace("/OUTSIDE", base)

    os.makedirs(os.path.join(root, ".aimi"), exist_ok=True)
    for rel, text in sorted(given["outside"].items()):
        full = os.path.join(base, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as handle:
            handle.write(sub(text))
    for rel in given["dirs"]:
        os.makedirs(os.path.join(root, rel), exist_ok=True)
    for rel, text in sorted(given["files"].items()):
        full = os.path.join(root, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as handle:
            handle.write(sub(text))
    now = int(time.time())
    for rel, days in sorted(given["ages"].items()):
        stamp = now - days * 86400
        os.utime(os.path.join(root, rel), (stamp, stamp))

    proc = subprocess.run(
        ["bash", CLI] + [sub(a) for a in case["args"]],
        cwd=root, capture_output=True, text=True, timeout=120, env=_isolated_env(base),
    )

    outside_after = {}
    for rel in _archive_listing(base, root, base, skip="proj"):
        full = os.path.join(base, rel)
        if os.path.isfile(full) and not os.path.islink(full):
            with open(full, encoding="utf-8", errors="replace") as handle:
                outside_after[rel] = _archive_norm(handle.read(), root, base)
        else:
            outside_after[rel] = None

    return {
        "exit": proc.returncode,
        "stdout": _archive_norm(proc.stdout, root, base),
        "stderr": _archive_norm(proc.stderr, root, base),
        "tree": _archive_listing(root, root, base),
        "outside_after": outside_after,
    }


# The 8 cases that could not survive the crossing, per field, in three classes
# -- and RESEARCH has none at all, which is the headline: all 37 recordings of
# a verb that deletes files match byte for byte, `tree` and `outside_after`
# included.
#
# (A) THE ENGINE'S OWN STATUS AND MESSAGE. jq aborted and `set -euo pipefail`
#     took the script down at jq's exit 4 or 5; tasks.py refuses at 1 with a
#     line naming the verb and the file. Recorded rather than reproduced, as
#     every block before this one did with its engine aborts.
# (B) THE STATE ONE READ AHEAD. The three is-userstories cases aborted at the
#     SECOND jq, after the first had already gated and bash had already written
#     .aimi/current-branch. Three reads at one crossing cannot fail one at a
#     time, so the refusal now lands before that write: a failed init-session
#     leaves no current-branch behind instead of a stale one. Strictly less
#     state after a failure, on a document jq itself refused to read, and it is
#     the only field in either block that moved.
# (C) BASH'S COMPLAINT ABOUT ITS OWN COMPARISON. `[` was handed one count per
#     document, said "integer expression expected" twice and returned 2 twice,
#     which the `&&`s read as false twice. The port branches on the counts
#     instead, so la-dois-documentos is still reported ARCHIVABLE -- stdout
#     matches -- with nothing on stderr.
SESSION_DIVERGENCES = {
    "is-malformado": ("exit", "stderr"),
    "is-metadata-string": ("exit", "stderr"),
    "gb-malformado": ("exit", "stderr"),
    "gb-metadata-string": ("exit", "stderr"),
    "is-userstories-ausente": ("exit", "stderr", "state_after"),
    "is-userstories-nao-lista": ("exit", "stderr", "state_after"),
    "is-userstories-null": ("exit", "stderr", "state_after"),
    "la-dois-documentos": ("stderr",),
}


@pytest.mark.parametrize("label", sorted(SESSION), ids=sorted(SESSION))
def test_the_session_port_reproduces_the_jq(label, tmp_path):
    case = SESSION[label]
    actual = _replay_session(case, tmp_path)
    excused = SESSION_DIVERGENCES.get(label, ())
    for field in SESSION_FIELDS:
        if field in excused:
            continue
        assert actual[field] == case[field], label + " . " + field


@pytest.mark.parametrize("label", sorted(RESEARCH), ids=sorted(RESEARCH))
def test_the_research_gc_port_reproduces_the_bash(label, tmp_path):
    """No divergence table, and that is the claim: a verb that deletes a user's
    files reproduces all five fields in all 37 recordings."""
    case = RESEARCH[label]
    actual = _replay_gc(case, tmp_path)
    for field in RESEARCH_FIELDS:
        assert actual[field] == case[field], label + " . " + field


def test_the_session_divergence_table_names_only_cases_that_exist():
    assert set(SESSION_DIVERGENCES) <= set(SESSION)
    assert len(SESSION_DIVERGENCES) == 8, "the comment above names 8; keep the two in step"


@pytest.mark.parametrize(
    "label", sorted(SESSION_DIVERGENCES), ids=sorted(SESSION_DIVERGENCES)
)
def test_each_excused_session_case_keeps_its_answer(label, tmp_path):
    """An excused case may lose the engine's wording and its exit status. It may
    not change its mind.

    The seven aborts still refuse and still write nothing to stdout. The one
    `[` complaint still ARCHIVES -- the verdict la-dois-documentos records is
    the defect being preserved, not the message that accompanied it.
    """
    recorded = SESSION[label]
    actual = _replay_session(recorded, tmp_path)
    if label == "la-dois-documentos":
        assert recorded["stderr"].count("integer expression expected") == 2
        assert actual["stdout"] == recorded["stdout"], "still archivable"
        assert actual["stderr"] == "", "the complaint had no rule behind it"
        assert actual["state_after"] == recorded["state_after"]
        return
    assert recorded["stderr"].startswith(("jq:", "parse error:")), label
    assert recorded["exit"] in (4, 5), label
    assert actual["exit"] == 1, label
    assert actual["stdout"] == "", label + ": a refusal writes nothing to stdout"
    assert actual["stderr"].startswith("Error: "), label
    # (B): the only state that may differ is current-branch, and only by being
    # ABSENT. Nothing else in .aimi/ moved, and no case gained a file.
    lost = set(recorded["state_after"]) - set(actual["state_after"])
    assert lost <= {"current-branch"}, label
    assert not set(actual["state_after"]) - set(recorded["state_after"]), label
    for key in actual["state_after"]:
        assert actual["state_after"][key] == recorded["state_after"][key], label + " . " + key


def test_the_two_archivable_predicates_still_disagree_and_share_no_helper():
    """THE DISAGREEMENT THIS PORT HAD TO PRESERVE.

    _archivable_file_is_terminal requires userStories to be NON-EMPTY;
    cmd_archive_task's inline copy of the same rule never did, and now neither
    does op_archive_task. So `userStories: []` is REFUSED by list-archivable
    and ARCHIVED by archive-task -- one rule, two implementations, already
    disagreeing before any port. Both sides are recorded, from two different
    blocks captured a commit apart, and both still hold.

    A shared helper is the single most likely way this reconciles by accident,
    so the two ops are asserted to have none: the total-count clause appears in
    exactly one of them, and neither calls the other. Story 09 moves
    cmd_list_archivable, the predicate's only caller -- it must CONSUME the
    predicate rather than re-derive the non-empty clause, or the disagreement
    dies there instead.
    """
    assert SESSION["la-zero-historias"]["stdout"] == "[]\n"
    assert ARCHIVE["archive-userstories-vazio"]["exit"] == 0
    assert ARCHIVE["archive-userstories-vazio"]["file"] is None

    source = _source()

    def body(name):
        """One top-level def, up to whatever comes next at column 0."""
        return re.search(
            r"^def " + name + r"\(.*?(?=^(?:def |_OPS|# -))", source, re.M | re.S
        ).group(0)

    predicate = _executable(body("op_archivable_file_is_terminal"))
    archive = _executable(body("op_archive_task"))
    # The clause that separates them, in one of the two and not the other.
    assert 'jq_length(jq_index(doc, "userStories")' in predicate
    assert "jq_length" not in archive
    # And neither reaches into the other for the half they DO share.
    assert "op_archive_task" not in predicate
    assert "archivable" not in archive
    assert len(re.findall(r"^def _archivable_verdict\(", source, re.M)) == 1


def test_init_session_keeps_its_gate_and_never_ports_the_self_resolution():
    """The gate crossed WITH the reads it sits between, and nothing else did.

    tasks.py holds one branchName charset pattern, and op_init_session tests
    the raw value against it before it reads pending or schemaVersion -- so a
    refusal happens before bash is handed anything. What did NOT cross is the
    line above it: `resolve_path "$0"` and the two cli-path writes are still
    executed in bash, because inside tasks.py `$0` is the .py file.
    """
    source = _source()
    assert len(re.findall(r"^BRANCH_NAME = ", source, re.M)) == 1
    session = _executable(re.search(
        r"^def op_init_session\(.*?(?=^(?:def |_OPS|# -))", source, re.M | re.S
    ).group(0))
    assert "BRANCH_NAME.fullmatch(branch)" in session
    assert 'sys.stderr.write("Error: Invalid branch name: " + branch' in session
    # ordering, read off the source: the gate is above both later reads
    assert session.index("BRANCH_NAME.fullmatch") < session.index("count_with_status")
    assert session.index("BRANCH_NAME.fullmatch") < session.index('"schemaVersion"')

    with open(CLI, encoding="utf-8") as handle:
        shell = handle.read()
    assert shell.count('write_state "cli-path" "$self_path"') == 1
    assert shell.count('write_global_cli_cache "$self_path"') == 1
    body = _executable(dict(_wrappers())["cmd_init_session"])
    assert body.count(_TASKS_CROSSING) == 1
    assert "jq " not in body
    # and the gate's refusal still precedes the state write, from bash's side:
    # a refused run never reaches write_state at all, because the crossing above
    # it exits non-zero.
    assert body.index(_TASKS_CROSSING) < body.index('write_state "current-branch"')


def test_research_gc_crosses_once_and_the_glob_stays_in_the_shell():
    """Which file is read FIRST decides what survives an abort, so the glob is
    not re-run in Python: bash expands it and hands the paths over as arguments,
    in the shell's own collation order.

    The stop-rather-than-skip rule is the one this pins hardest. `set -euo
    pipefail` ended the whole for-loop at the first jq that aborted, so a
    malformed tasks file silently emptied the referenced set for every file
    after it -- and the research those files name was then collected.
    """
    body = _executable(dict(_wrappers())["cmd_research_gc"])
    assert body.count(_TASKS_CROSSING) == 1
    assert "jq " not in body
    assert '"$tasks_dir"/*.json' in body
    # check_python3 OUTSIDE the process substitution: an interpreter that could
    # not start inside it would leave the referenced set empty and the sweep
    # would then delete every live research file.
    assert body.index("check_python3") < body.index(_TASKS_CROSSING)
    assert "check_python3" not in body.split("< <(")[1]

    same = RESEARCH["rgc-malformado-antes-de-um-bom"]
    other = RESEARCH["rgc-malformado-depois-de-um-bom"]
    assert ".aimi/research/vivo.md" not in same["tree"], "the truncation, preserved"
    assert ".aimi/research/vivo.md" in other["tree"], "same two files, other order"
    # and a stream that fails halfway still yields what jq had already printed
    assert ".aimi/research/vivo.md" in RESEARCH[
        "rgc-dois-documentos-segundo-malformado"]["tree"]


def test_the_research_corpus_exercises_every_case_it_claims_to():
    """Ten buckets, every verdict read off the RECORDING. A corpus where
    nothing was ever deleted would let the 37-case replay pass on nothing."""
    def survivors(label):
        return {t.split("/")[-1] for t in RESEARCH[label]["tree"]
                if t.startswith(".aimi/research/") and not t.endswith("/")}

    # 1. the ordinary run: the referenced file stays, the old orphan goes, the
    #    young orphan stays
    assert survivors("rgc-referencia-simples") == {"vivo.md", "orfao-novo.md"}
    assert RESEARCH["rgc-referencia-simples"]["stdout"] == (
        "Cleaned 1 orphaned research files (>30 days)\n"
    )
    # 2. silence when nothing goes
    assert RESEARCH["rgc-tudo-recente"]["stdout"] == ""
    assert survivors("rgc-tudo-recente") == {"vivo.md", "orfao-velho.md", "orfao-novo.md"}
    # 3. the threshold, from both sides
    assert survivors("rgc-limite-29-e-31-dias") == {"vinte-e-nove.md"}
    # 4. an absolute researchPath protects nothing
    assert "vivo.md" not in survivors("rgc-caminho-absoluto")
    # 5. a non-string entry protects nothing either
    assert "vivo.md" not in survivors("rgc-entrada-objeto")
    assert "vivo.md" not in survivors("rgc-entrada-array")
    # 6. ./ is stripped, an embedded newline yields a second usable path
    assert "vivo.md" in survivors("rgc-prefixo-ponto-barra")
    assert "vivo.md" in survivors("rgc-entrada-com-newline")
    # 7. both brainstorm sources still protect
    assert "vivo.md" in survivors("rgc-brainstorm-researchpaths")
    assert "vivo.md" in survivors("rgc-brainstorm-foundation")
    # 8. nested research is never globbed and so is never collected
    assert "aninhado.md" in survivors("rgc-research-em-subdiretorio")
    # 9. nothing outside .aimi/research is ever touched, even when named
    assert RESEARCH["rgc-caminho-fora-do-projeto"]["outside_after"] == {
        "fora/": None, "fora/segredo.md": "one directory above the project root\n"
    }
    # 10. the shapes that abort the walk, and the shapes that merely say nothing
    for label in ("rgc-tasks-malformado", "rgc-metadata-string", "rgc-doc-array"):
        assert "vivo.md" not in survivors(label), label
    for label in ("rgc-metadata-null", "rgc-doc-null", "rgc-researchpaths-null"):
        assert RESEARCH[label]["exit"] == 0, label


def test_get_branch_reads_the_document_only_when_the_state_is_empty():
    """The fast path is the common one -- /aimi:execute calls this per story --
    and it must not gain a python3 startup."""
    body = _executable(dict(_wrappers())["cmd_get_branch"])
    assert body.count(_TASKS_CROSSING) == 1
    assert "jq " not in body
    assert body.index('read_state "current-branch"') < body.index(_TASKS_CROSSING)
    assert body.index('if [ -z "$branch" ]') < body.index("get_tasks_file")
    # recorded from the other side: answered from state with NO tasks file at all
    assert SESSION["gb-estado-presente-sem-documento"]["stdout"] == "do-estado\n"
    assert SESSION["gb-estado-presente-sem-documento"]["input"]["files"] == {}
    # and get-branch has no gate: it echoes a name init-session refuses
    assert SESSION["gb-branch-hostil"]["stdout"] == "main; rm -rf /\n"
    assert SESSION["is-branch-hostil"]["exit"] == 1


def test_a_missing_branchname_is_still_the_word_null():
    """`jq -r` printed `null` for an absent branchName and the charset gate
    accepted it, so init-session reports and stores a branch literally called
    null. document_line reproduces it rather than mapping null to "" -- which
    is exactly why it is not document_scalar, the archive helper that carries
    `// empty`."""
    for label in ("is-branch-ausente", "is-branch-null-explicito",
                  "is-metadata-ausente", "is-metadata-null"):
        assert json.loads(SESSION[label]["stdout"])["branch"] == "null", label
        assert SESSION[label]["state_after"]["current-branch"] == "null\n", label
    assert T.document_line([{"metadata": {}}], "metadata", "branchName") == "null"
    assert T.document_scalar([{"metadata": {}}], "branchName") == ""


# ---------------------------------------------------------------------------
# verify-probe: which of a verify's assertions already passed
# ---------------------------------------------------------------------------
#
# NO GOLDEN BLOCK, and there could not be one: this verb had no jq predecessor
# to capture, so nothing here is evidence that a port changed nothing. What it
# asserts instead is the two properties the verb exists for -- that a segment
# which already passes is reported as not discriminating, and that a separator
# inside a quoted string is not a separator -- plus the two the decomposition
# must never violate, which are that nothing is eval'd and that a failure
# branch is never run.


def _probe(tmp_path, verify, files=(), cwd=None):
    """A one-story project whose story carries `verify`, probed through the CLI.

    `files` are created relative to the project root before the run, and `cwd`
    names the directory to invoke from -- the two things the probe's answer
    depends on besides the verify text itself.
    """
    base = os.path.realpath(str(tmp_path))
    root = os.path.join(base, "proj")
    os.makedirs(os.path.join(root, ".aimi", "tasks"), exist_ok=True)
    for name in files:
        target = os.path.join(root, name)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "w", encoding="utf-8") as handle:
            handle.write("marker\n")
    story = {
        "id": "US-001",
        "title": "s",
        "description": "d",
        "acceptanceCriteria": ["x"],
        "priority": 1,
        "status": "pending",
        "dependsOn": [],
    }
    if verify is not None:
        story["implementation"] = {"verify": verify}
    document = {
        "schemaVersion": "3.3",
        "metadata": {"title": "t", "branchName": "b"},
        "userStories": [story],
    }
    tasks_file = os.path.join(root, ".aimi", "tasks", "p-tasks.json")
    with open(tasks_file, "w", encoding="utf-8") as handle:
        json.dump(document, handle)
    proc = subprocess.run(
        ["bash", CLI, "verify-probe", "US-001", "--tasks-file", tasks_file],
        cwd=os.path.join(root, cwd) if cwd else root,
        env=_isolated_env(base),
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert proc.returncode == 0, proc.stderr
    return root, json.loads(proc.stdout)


def test_an_absent_or_empty_verify_probes_to_an_empty_array(tmp_path):
    """`implementation` is optional in schema v3.3 and a story is allowed to
    carry no verify. Three shapes of nothing, one answer, and never a refusal --
    a caller that had to tell "no verify" from "the verb broke" would end up
    reimplementing the check it delegated."""
    for verify in (None, "", "   \n\n  "):
        _, probed = _probe(tmp_path, verify)
        assert probed == [], repr(verify)


def test_three_segments_where_only_the_first_already_passes(tmp_path):
    """The shape of the case this verb was built from: a verify whose first
    assertion holds before a line is written and whose remaining two do not.

    The script as a whole FAILS here, which is exactly why the pre-run at the
    script level says nothing -- and under `set -e` it would stop at the second
    segment, so the third never runs at all.
    """
    _, probed = _probe(
        tmp_path,
        "set -euo pipefail\n"
        "test -f ja-existe.txt\n"
        "test -f ainda-nao.txt\n"
        "grep -q 'ainda-nao' ja-existe.txt\n",
        files=("ja-existe.txt",),
    )
    assert [entry["segment"] for entry in probed] == [
        "test -f ja-existe.txt",
        "test -f ainda-nao.txt",
        "grep -q 'ainda-nao' ja-existe.txt",
    ]
    assert [entry["discriminates"] for entry in probed] == [False, True, True]
    assert len([e for e in probed if not e["discriminates"]]) == 1
    assert probed[0]["exit"] == 0 and probed[1]["exit"] != 0


def test_a_separator_inside_quotes_does_not_split_a_segment():
    """The whole reason this is a scanner and not a `split`. Every one of these
    holds a `;`, an `&&` or a `||` that belongs to the STRING, and a naive cut
    would hand bash four fragments none of which parse."""
    for text in (
        "echo 'a;b && c || d'",
        'echo "a;b && c || d"',
        "grep -q 'x;y' file.txt",
        "awk '/a/{print;exit} /b/{next}' file.txt",
        "echo $(printf 'a;b')",
        "echo `printf 'a;b'`",
    ):
        assert [s for _, s in T.verify_segments(text)] == [text], text


def test_a_group_a_subshell_and_a_compound_command_each_stay_one_segment():
    """`{ ...; }`, `( ...; )` and `if ...; then ...; fi` are single commands, so
    cutting inside one produces a fragment that is a syntax error rather than an
    assertion. `${VAR}` and `${x#y}` must not be mistaken for the first of
    those, which is why the brace and the `#` are only special at word start."""
    for text in (
        "{ echo a; echo b; }",
        "( cd x; echo b )",
        "if test -f a; then echo yes; fi",
        "for f in a b; do echo $f; done",
        'echo "${VAR}" && echo "${x#y}"',
    ):
        segments = [s for _, s in T.verify_segments(text)]
        assert segments == [text] or segments == text.split(" && "), text


def test_comments_and_set_lines_and_assignments_are_never_reported(tmp_path):
    """AC: a segment that is only `set -e` or an assignment does not appear.

    A comment does not either -- it would otherwise become a segment that runs
    as `# ...`, exits 0, and is reported as an assertion that already passes,
    which is the exact false positive this verb exists to avoid producing.
    """
    _, probed = _probe(
        tmp_path,
        "set -euo pipefail\n"
        "# a comment holding a ; and an && and a ||\n"
        "F=existe.txt\n"
        "export G=existe.txt\n"
        "test -f \"$F\"\n",
        files=("existe.txt",),
    )
    assert [entry["segment"] for entry in probed] == ['test -f "$F"']
    assert probed[0]["discriminates"] is False, "the assignment was carried, not lost"


def test_an_assignment_is_carried_into_every_assertion_after_it(tmp_path):
    """Without the prelude this is the failure mode that would make the verb
    useless on real verifies: `S=<path>` then `grep -q x "$S"` would run with an
    empty `$S`, fail for that reason alone, and be reported as discriminating --
    hiding the very assertion the story wants surfaced."""
    _, probed = _probe(
        tmp_path,
        'S=doc.md\ngrep -q marker "$S"\ngrep -q ausente "$S"\n',
        files=("doc.md",),
    )
    assert [entry["exit"] for entry in probed] == [0, 1]
    assert [entry["discriminates"] for entry in probed] == [False, True]


def test_the_operand_after_a_double_pipe_is_neither_run_nor_reported(tmp_path):
    """`check || { echo FAIL; exit 1; }` is ONE assertion with a failure branch.

    The branch runs only when the check has already failed, so its exit status
    says nothing about the tree -- and running it standalone is the one
    decomposition here with teeth. `|| mkdir` proves it by consequence rather
    than by opinion: the directory must not exist afterwards.
    """
    root, probed = _probe(
        tmp_path,
        "test -f existe.txt || { echo 'FAIL; really'; exit 1; }\n"
        "test -d criado || mkdir criado\n",
        files=("existe.txt",),
    )
    assert [entry["segment"] for entry in probed] == [
        "test -f existe.txt",
        "test -d criado",
    ]
    assert not os.path.exists(os.path.join(root, "criado")), "a failure branch ran"


def test_the_operand_after_a_double_ampersand_is_a_further_assertion():
    """The opposite case, and the reason the separator is carried at all rather
    than `||` simply being dropped from the cut list: what follows `&&` is
    reached only because the thing before it passed, so it IS an assertion."""
    parsed = T.verify_segments("test -f a && test -f b")
    assert parsed == [("", "test -f a"), ("&&", "test -f b")]
    assert T.verify_segments("test -f a || test -f b") == [
        ("", "test -f a"),
        ("||", "test -f b"),
    ]


def test_the_segments_run_where_the_CALLER_stood_not_at_the_project_root(tmp_path):
    """find_aimi_root cds to the root holding .aimi/ before any verb runs, and
    probing there would measure the main checkout while the executor's own
    verify measures the worktree it cd'd into at step 0c. A probe that reports
    on a different tree than the check it is probing is worse than no probe."""
    _, from_root = _probe(tmp_path, "test -f so-aqui.txt\n", files=("sub/so-aqui.txt",))
    assert from_root[0]["discriminates"] is True
    _, from_sub = _probe(
        tmp_path, "test -f so-aqui.txt\n", files=("sub/so-aqui.txt",), cwd="sub"
    )
    assert from_sub[0]["discriminates"] is False


def test_the_probe_wrapper_crosses_once_takes_no_lock_and_runs_the_same_gates():
    """Bash keeps the argument, its format, which file is current and whether
    the story is in it -- and adds exactly one thing, the caller's directory.
    Nothing here reads the document, and a reader takes no lock."""
    body = _executable(dict(_wrappers())["cmd_verify_probe"])
    assert "jq " not in body and "jq(" not in body
    assert body.count(_TASKS_CROSSING) == 1
    assert "_lock" not in body, "a reader takes no lock"
    for kept in ("validate_story_id", "validate_path_in_project", "get_tasks_file",
                 "validate_story_exists", "check_python3"):
        assert kept in body, kept
    assert 'AIMI_INVOCATION_DIR:-$PWD' in body


def test_nothing_in_the_decomposition_reaches_eval():
    """AC: the parser respects quotes rather than asking a shell to split for
    it. `eval` on a verify string would run the whole script the probe is
    supposed to be taking apart -- once per segment."""
    source = "\n".join(
        line
        for line in _code().split("\n")
        if not line.lstrip().startswith("#")
    )
    start = source.index("def verify_segments")
    end = source.index("def op_verify_probe")
    assert "eval" not in source[start:end]


# ---------------------------------------------------------------------------
# list-known-gaps: the corpus every executor writes and no plan has read
# ---------------------------------------------------------------------------
#
# NO GOLDEN BLOCK, for verify-probe's reason: there was no jq predecessor to
# capture. What these assert instead is the one property the verb exists for --
# that NOTHING is dropped. Every other rule here is downstream of it: the three
# body shapes all parse because a parser that knew only the prefixed form would
# lose two thirds of the real corpus, and an unresolved feature is null rather
# than a discarded file for the same reason.


def _gaps(tmp_path, gaps, tasks=(), archive=(), flags=()):
    """A project whose .aimi/ holds `gaps` (name -> body) and the tasks
    documents the feature index resolves a date from.

    `tasks` and `archive` are (relative path, document) pairs written under
    .aimi/tasks/ and .aimi/archive/ -- both are walked, because a gap written
    in July belongs to a feature whose tasks file was archived weeks ago.
    """
    base = os.path.realpath(str(tmp_path))
    root = os.path.join(base, "proj")
    gaps_dir = os.path.join(root, ".aimi", "known-gaps")
    os.makedirs(gaps_dir, exist_ok=True)
    for name, body in gaps.items():
        with open(os.path.join(gaps_dir, name), "w", encoding="utf-8") as handle:
            handle.write(body)
    for where, entries in ((("tasks",), tasks), (("archive",), archive)):
        for relative, document in entries:
            target = os.path.join(root, ".aimi", *where, relative)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "w", encoding="utf-8") as handle:
                json.dump(document, handle)
    proc = subprocess.run(
        ["bash", CLI, "list-known-gaps", *flags],
        cwd=root,
        env=_isolated_env(base),
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert proc.returncode == 0, proc.stderr
    return json.loads(proc.stdout)


_THREE_SHAPES = {
    "2026-07-30-US-003.md": "KNOWN-GAP: bash -c wrapping\nKNOWN-GAP: subshells\n",
    "2026-08-16-US-001.md": 'KNOWN-GAP (US-003): "Typecheck passes" has no counterpart here.\n',
    "2026-07-26-US-001.md": "Both gaps the worker reported were already addressed.\n",
}


def test_all_three_body_shapes_parse_and_no_file_yields_nothing(tmp_path):
    """The corpus has no frontmatter anywhere -- which is why the frontmatter-
    first learnings researcher cannot see it -- and comes in three forms:
    `KNOWN-GAP:`, `KNOWN-GAP (US-NNN):`, and bare prose with no prefix at all.

    Twenty of the thirty-two real files are the bare form. Recognising only the
    prefixed one would silently drop two thirds of the corpus, which is the very
    defect this verb exists to close, so the floor asserted here is the one the
    story's own verify measures against the directory: at least one entry per
    file."""
    entries = _gaps(tmp_path, _THREE_SHAPES)
    assert {entry["file"] for entry in entries} == set(_THREE_SHAPES)
    assert len(entries) >= len(_THREE_SHAPES)
    texts = {entry["file"]: entry["text"] for entry in entries if entry["file"] != "2026-07-30-US-003.md"}
    assert texts["2026-08-16-US-001.md"] == '"Typecheck passes" has no counterpart here.'
    assert texts["2026-07-26-US-001.md"].startswith("Both gaps the worker reported")
    assert [e["text"] for e in entries if e["file"] == "2026-07-30-US-003.md"] == [
        "bash -c wrapping",
        "subshells",
    ]


def test_a_hard_wrapped_gap_stays_one_entry_and_keeps_its_lines(tmp_path):
    """A KNOWN-GAP line opens a block and everything after it joins that block
    until the next one opens. The bodies carry tables, fences and indented
    lists, so the text is kept verbatim below the prefix rather than re-flowed:
    this file is the only copy of the record that exists."""
    body = (
        "KNOWN-GAP (US-004): adding a verb to tasks.py means registering it in\n"
        "test_every_op_is_named_after_the_verb_that_calls_it.\n"
        "\n"
        "    indented evidence\n"
        "KNOWN-GAP (US-004): two executors died on an API server error.\n"
    )
    entries = _gaps(tmp_path, {"2026-09-03-US-004.md": body})
    assert len(entries) == 2
    assert entries[0]["text"].split("\n") == [
        "adding a verb to tasks.py means registering it in",
        "test_every_op_is_named_after_the_verb_that_calls_it.",
        "",
        "    indented evidence",
    ]
    assert entries[1]["text"] == "two executors died on an API server error."


def test_prose_before_the_first_prefix_is_an_entry_rather_than_a_loss(tmp_path):
    """No file in the corpus has such a preamble today. The rule is here so the
    first one that does is not dropped -- dropping it is the failure mode."""
    entries = _gaps(
        tmp_path,
        {"2026-08-07-US-003.md": "context nobody prefixed\nKNOWN-GAP: the prefixed one\n"},
    )
    assert [entry["text"] for entry in entries] == [
        "context nobody prefixed",
        "the prefixed one",
    ]


def test_the_parenthetical_story_id_wins_over_the_file_name(tmp_path):
    """2026-08-16-US-001.md really does carry gaps about US-002 and US-003: the
    US-001 executor recorded what it found about its siblings. The
    parenthetical is the more specific attribution for that entry, and the file
    name is the fallback for a line that carries none."""
    entries = _gaps(
        tmp_path,
        {
            "2026-08-16-US-001.md": (
                "KNOWN-GAP: mine\n"
                "KNOWN-GAP (US-002): my sibling's\n"
                "KNOWN-GAP (not-a-story): malformed, so the file name stands\n"
            )
        },
    )
    assert [entry["storyId"] for entry in entries] == ["US-001", "US-002", "US-001"]


def test_the_feature_comes_from_the_file_names_own_slug_when_it_has_one(tmp_path):
    """Both real slug shapes: one with a story id before it, one with no story
    id at all. The second resolves storyId to null and is still an entry."""
    entries = _gaps(
        tmp_path,
        {
            "2026-08-04-US-006-roadmap-amend-no-git-trace.md": "a\n",
            "2026-08-04-verify-creates-excludes-miss-this-repo.md": "b\n",
        },
    )
    resolved = {entry["file"]: (entry["storyId"], entry["feature"]) for entry in entries}
    assert resolved["2026-08-04-US-006-roadmap-amend-no-git-trace.md"] == (
        "US-006",
        "roadmap-amend-no-git-trace",
    )
    assert resolved["2026-08-04-verify-creates-excludes-miss-this-repo.md"] == (
        None,
        "verify-creates-excludes-miss-this-repo",
    )


def _dated(created_at):
    return {"schemaVersion": "3.3", "metadata": {"title": "t", "createdAt": created_at}}


def test_the_feature_comes_from_the_tasks_file_planned_on_the_same_date(tmp_path):
    """Two sources, because the corpus needs both: a flat archived file names
    its date and feature in its own name, and a phase-layout file names neither
    -- its feature is the directory under tasks/ and its date is
    metadata.createdAt."""
    entries = _gaps(
        tmp_path,
        {"2026-08-08-US-002.md": "a\n", "2026-09-03-US-004.md": "b\n"},
        tasks=[
            (
                os.path.join("pipeline-audit", "phase-1-x", "pipeline-audit-phase-1-tasks.json"),
                _dated("2026-09-03"),
            )
        ],
        archive=[("2026-08-08-identity-contract-tasks.json", _dated("2026-08-08"))],
    )
    resolved = {entry["file"]: entry["feature"] for entry in entries}
    assert resolved["2026-08-08-US-002.md"] == "identity-contract"
    assert resolved["2026-09-03-US-004.md"] == "pipeline-audit"


def test_a_feature_that_does_not_resolve_is_null_rather_than_a_dropped_file(tmp_path):
    """Two ways to fail to resolve, one answer. A date nothing was planned on,
    and a date carrying TWO features -- where picking one would attribute a gap
    to a feature it was never about. Neither drops the file: discarding it is
    the defect this verb was built to fix."""
    entries = _gaps(
        tmp_path,
        {"2026-07-26-US-001.md": "ambiguous\n", "2026-08-16-US-001.md": "nothing planned\n"},
        archive=[
            ("2026-07-26-comunicacao-simples-tasks.json", _dated("2026-07-26")),
            ("2026-07-26-open-pr-base-branch-detection-tasks.json", _dated("2026-07-26")),
        ],
    )
    assert [entry["feature"] for entry in entries] == [None, None]
    assert {entry["file"] for entry in entries} == {
        "2026-07-26-US-001.md",
        "2026-08-16-US-001.md",
    }


def test_the_feature_filter_is_exact_and_leaves_the_unresolved_out(tmp_path):
    """--feature is what plan.md Phase 1.7b passes to scope the block to the
    feature being planned. An entry whose feature is null is not a member of
    any feature, so it is not a member of this one either."""
    gaps = {"2026-09-03-US-004.md": "belongs\n", "2026-08-16-US-001.md": "unresolved\n"}
    tasks = [
        (
            os.path.join("pipeline-audit", "phase-1-x", "pipeline-audit-phase-1-tasks.json"),
            _dated("2026-09-03"),
        )
    ]
    scoped = _gaps(tmp_path, gaps, tasks=tasks, flags=("--feature", "pipeline-audit"))
    assert [entry["file"] for entry in scoped] == ["2026-09-03-US-004.md"]
    assert _gaps(tmp_path, gaps, tasks=tasks, flags=("--feature", "nao-existe")) == []
    assert len(_gaps(tmp_path, gaps, tasks=tasks)) == 2


def test_since_is_inclusive_and_an_entry_with_no_date_cannot_answer_it(tmp_path):
    """A file whose name carries no date has no date to compare, and inventing
    one for it is the guess this parser refuses everywhere else."""
    gaps = {
        "2026-07-30-US-003.md": "old\n",
        "2026-08-16-US-001.md": "on the boundary\n",
        "sem-data.md": "undated\n",
    }
    assert len(_gaps(tmp_path, gaps)) == 3
    since = _gaps(tmp_path, gaps, flags=("--since", "2026-08-16"))
    assert [entry["file"] for entry in since] == ["2026-08-16-US-001.md"]


def test_an_absent_directory_is_an_empty_array_and_never_a_refusal(tmp_path):
    """A repository that has never recorded a gap is the normal early state,
    and /aimi:plan reads this on every run: a non-zero exit here would turn "no
    gaps yet" into a planning failure."""
    assert _gaps(tmp_path, {}) == []


def test_only_md_files_are_gaps(tmp_path):
    """.aimi/known-gaps/ also holds two *.pre.json roadmap snapshots, saved
    beside the record that explains them. They are evidence, not gaps."""
    entries = _gaps(
        tmp_path,
        {
            "2026-08-04-US-006-roadmap-amend-no-git-trace.md": "the record\n",
            "2026-08-04-US-006-roadmap.pre.json": '{"phases": []}\n',
        },
    )
    assert [entry["file"] for entry in entries] == [
        "2026-08-04-US-006-roadmap-amend-no-git-trace.md"
    ]


def test_the_known_gaps_wrapper_crosses_once_takes_no_lock_and_opens_no_file():
    """Bash keeps the flags and adds AIMI_DIR, find_aimi_root's own export.

    NO validate_path_in_project, and that is the rule rather than an omission:
    it governs a path arriving as an ARGUMENT, and this verb takes none --
    --feature and --since are filter strings. A fresh path check here would be
    the third confinement authority root CLAUDE.md forbids."""
    body = _executable(dict(_wrappers())["cmd_list_known_gaps"])
    assert "jq " not in body and "jq(" not in body
    assert body.count(_TASKS_CROSSING) == 1
    assert "_lock" not in body, "a reader takes no lock"
    assert "check_python3" in body
    assert '--aimi-dir "$AIMI_DIR"' in body
