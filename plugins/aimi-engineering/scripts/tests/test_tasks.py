"""Tests for scripts/tasks.py.

THE GOLDEN FILE IS THE POINT OF THIS SUITE, same as it is for test_roadmap.py
and test_story_merge.py.

`golden_from_jq.json` holds three blocks for this module, each captured by
running the jq implementations that used to live in aimi-cli.sh, BEFORE they
were deleted: `tasks_read_cases` (151 cases, the six read verbs),
`tasks_ready_cases` (128, list-ready and next-story) and `tasks_write_cases`
(91, the seven locked writers). Like the story-merge capture all three record
each case's INPUT, so every one is replayable: test_the_port_reproduces_the_jq,
test_the_ready_port_reproduces_the_jq and test_the_write_port_reproduces_the_jq
re-run the whole corpus through the CLI and compare every field. Those three
tests are the evidence the port changed nothing, and they are why the rest of
this file can stay short -- it asserts the properties a reader would otherwise
have to reconstruct from 370 recordings by eye.

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
    """
    code = _code()
    for forbidden in ("flock", "fcntl", "lockf", "os.mkdir", "makedirs", ".lock"):
        assert forbidden not in code, "tasks.py must not " + forbidden


def test_the_only_file_tasks_py_writes_is_the_one_it_was_handed(tmp_path):
    """One reader, one writer, and the writer is atomic.

    open() appears once and in read mode; the single write path is
    write_docs_atomically, which is a NamedTemporaryFile in the TARGET's own
    directory followed by os.replace -- never a truncate-and-write, which is the
    one failure that could leave /aimi:execute reading half a tasks.json. And
    nothing here goes near .aimi/state/: those files have their own lock and
    their own confinement in bash, and the mark-* verbs still write them there.
    """
    code = _code()
    assert code.count("open(") == 1
    assert 'open(path, "r", encoding="utf-8")' in code
    assert len(re.findall(r"^def write_docs_atomically\(", code, re.M)) == 1
    assert code.count("os.replace(") == 1 and code.count("NamedTemporaryFile(") == 1
    assert "os.unlink(" in code, "the temp file goes away on the failing path too"
    assert set(re.findall(r"([\w.]+)\.write\(", code)) == {
        "sys.stdout",
        "sys.stderr",
        "handle",
    }
    # Two os.path calls, both inside write_docs_atomically, so the module names
    # no path of its own -- not .aimi/state/, not a lock, not a sibling file.
    assert code.count("os.path.") == 2

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


def _wrappers():
    with open(CLI, encoding="utf-8") as handle:
        return _WRAPPER.findall(handle.read())


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
    """
    wrappers = _wrappers()
    locked = {
        name: body
        for name, body in wrappers
        if "_lock " in body and _TASKS_CROSSING in body
    }
    assert set(locked) == {
        "cmd_mark_in_progress",
        "cmd_mark_complete",
        "cmd_mark_failed",
        "cmd_mark_skipped",
        "cmd_update_field",
        "cmd_normalize_status",
        "cmd_normalize_verification",
        "cmd_cascade_skip",
        "cmd_reset_orphaned",
        "cmd_gate_pass",
        "cmd_gate_fail",
    }
    for name, body in sorted(locked.items()):
        assert body.count(_TASKS_CROSSING) == 1, name + " crosses more than once"
        assert body.index('_lock "') < body.index(_TASKS_CROSSING), name
        assert body.index(_TASKS_CROSSING) < body.index('200>"'), name

    two_crossings = [
        name for name, body in wrappers if body.count(_ROADMAP_CROSSING) > 1
    ]
    assert two_crossings == ["cmd_roadmap_init", "cmd_roadmap_amend_phase"]

    # And the branch exemption is exactly one wrapper wide, named here so a
    # second one cannot arrive by claiming to be a branch.
    branched = [name for name, body in wrappers if body.count(_TASKS_CROSSING) > 1]
    assert branched == ["cmd_list_ready"]
    assert "_lock " not in dict(wrappers)["cmd_list_ready"]


def test_every_op_is_named_after_the_verb_that_calls_it():
    """roadmap.py needed a _VERB_FOR_OP table because its op names drifted from
    its verb names, and a diagnostic then quoted a command nobody could run.
    Keeping the names equal is what makes that table unnecessary here.

    validate-story-exists is the one entry that is not a verb: it names the
    bash FUNCTION it twins, so `grep validate_story_exists` finds both copies
    while both exist."""
    assert set(T._OPS) == {
        "status",
        "metadata",
        "get-story",
        "current-story",
        "get-state",
        "count-pending",
        "list-ready",
        "next-story",
        "validate-story-exists",
        "mark-complete",
        "mark-failed",
        "mark-in-progress",
        "mark-skipped",
        "update-field",
        "normalize-status",
        "normalize-verification",
        "cascade-skip",
        "reset-orphaned",
        "gate-pass",
        "gate-fail",
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
