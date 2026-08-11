"""Tests for scripts/tasks.py.

THE GOLDEN FILE IS THE POINT OF THIS SUITE, same as it is for test_roadmap.py
and test_story_merge.py.

`golden_from_jq.json`'s `tasks_read_cases` was captured by running the jq
implementations that used to live in aimi-cli.sh over 151 adversarial cases,
BEFORE they were deleted. Like the story-merge capture it records each case's
INPUT, so every one of them is replayable: test_the_port_reproduces_the_jq
below re-runs the whole corpus through the CLI and compares every field. That
test is the evidence the port changed nothing, and it is why the rest of this
file can stay short -- it asserts the properties a reader would otherwise have
to reconstruct from 151 recordings by eye.

It must never be regenerated from tasks.py. If a case here goes red, either the
port drifted or a rule genuinely changed; in the second case the golden file
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


def test_get_story_is_the_verb_the_bash_gate_kept_identical():
    """validate_story_exists stayed in bash, so get-story refuses a broken
    userStories with its OWN message where the other four hit jq's engine. All
    five of its us-* cases are outside the divergence table on purpose."""
    for label in _labels("get-story-us-"):
        assert label not in KNOWN_DIVERGENCES, label
        assert CASES[label]["exit"] == 1
        assert "not found in" in CASES[label]["stderr"]


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


def test_tasks_py_opens_nothing_for_writing_and_takes_no_lock():
    """Six read-only verbs. The one open() in the file is read mode, the only
    writes go to the two standard streams, and none of the machinery every
    writer in roadmap.py and story_merge.py needs is here."""
    body = _body()
    assert body.count("open(") == 1
    assert 'open(path, "r", encoding="utf-8")' in body
    assert set(re.findall(r"([\w.]+)\.write\(", body)) == {"sys.stdout", "sys.stderr"}
    for forbidden in ("flock", "tempfile", "os.replace", "os.rename", "os.remove", "mkdir"):
        assert forbidden not in body, "tasks.py must not " + forbidden


def test_every_op_is_named_after_the_verb_that_calls_it():
    """roadmap.py needed a _VERB_FOR_OP table because its op names drifted from
    its verb names, and a diagnostic then quoted a command nobody could run.
    Keeping the names equal is what makes that table unnecessary here."""
    assert set(T._OPS) == {
        "status",
        "metadata",
        "get-story",
        "current-story",
        "get-state",
        "count-pending",
    }


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
