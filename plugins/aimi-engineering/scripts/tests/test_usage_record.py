"""Tests for scripts/usage_record.py, the one copy of the usage-validation record
rule both writers share: roadmap.py's record-usage-validation (a phase) and
tasks.py's usage-validation-record (a flat run).

The module is exercised directly here; the two writers' CLI-level behaviour is
pinned in test_roadmap.py and test_tasks.py.
"""

import ast
import json
import os
import re
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import usage_record as U  # noqa: E402

P = "Error: some-verb: "


def _refusal(capsys, fn, *args):
    with pytest.raises(SystemExit) as exc:
        fn(*args)
    assert exc.value.code == 1
    return capsys.readouterr().err


def test_vocabulary_and_caps():
    assert U.STATUSES == ("passed", "failing", "skipped")
    assert U.KINDS == ("not-applicable", "unable-to-evaluate", "disabled-by-operator")
    assert U.FINDING_STATUSES == ("open", "fixed", "accepted")
    assert (U.REASON_MAXLEN, U.FINDING_REASON_MAXLEN, U.FINDINGS_MAX) == (2000, 500, 200)
    assert U.FINDING_KEY.match("CH-US-001:2:H1") and not U.FINDING_KEY.match("-bad")


@pytest.mark.parametrize("argv,message", [
    ([], "--status must be one of passed|failing|skipped, got: "),
    (["--status", "nope"], "--status must be one of passed|failing|skipped, got: nope"),
    (["--status", "passed", "--kind", "not-applicable"], "--kind is only allowed with --status skipped"),
    (["--status", "skipped"], "--kind is required with --status skipped"),
    (["--status", "skipped", "--kind", "bad", "--reason", "r"],
     "--kind must be one of not-applicable|unable-to-evaluate|disabled-by-operator, got: bad"),
    (["--status", "failing"], "--reason is required with --status failing"),
    (["--status", "skipped", "--kind", "not-applicable", "--reason", "  "], "--reason is required with --status skipped"),
    (["--status", "passed", "--rounds", "x"], "--rounds must be a non-negative integer, got: x"),
    (["--status", "passed", "--rounds"], "--rounds must be a non-negative integer, got: "),
    (["--status", "passed", "--findings-json", "{bad"], "--findings-json is not valid JSON"),
    (["--status", "passed", "--findings-json", "[]"], "--findings-json must be a JSON object"),
    (["--status", "passed", "--findings-json", '{"-bad":{"status":"open"}}'], "--findings-json key is not allowed: -bad"),
    (["--status", "passed", "--findings-json", '{"k":{"status":"x"}}'],
     "--findings-json entry 'k' needs a status of open|fixed|accepted"),
    (["--status", "passed", "--findings-json", '{"k":{"status":"open","reason":3}}'],
     "--findings-json reason of 'k' must be a string"),
    (["--status", "passed", "--findings-json", '{"k":{"status":"accepted"}}'],
     "--findings-json entry 'k' is accepted and needs a reason"),
])
def test_parse_request_refusals_carry_the_callers_prefix(capsys, argv, message):
    assert _refusal(capsys, U.parse_request, argv, P) == P + message + "\n"


def test_parse_request_defaults_and_sanitizing():
    req = U.parse_request(["--status", "passed"], P)
    assert req == {"status": "passed", "kind": None, "reason": "", "review": None, "rounds": 0, "findings": {}}
    req = U.parse_request(["--status", "failing", "--reason", "a" * 3000, "--rounds", "2", "--review", "r.md"], P)
    assert len(req["reason"]) <= U.REASON_MAXLEN and req["rounds"] == 2 and req["review"] == "r.md"


def test_build_record_shape_and_key_order():
    _, rec = U.build_record(U.parse_request(["--status", "passed"], P), None)
    assert list(rec) == ["status", "rounds", "recordedAt"]
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", rec["recordedAt"])
    req = U.parse_request(["--status", "skipped", "--kind", "not-applicable", "--reason", "no ui",
                           "--review", "r.md", "--rounds", "1",
                           "--findings-json", '{"a:1:H1":{"status":"open"}}'], P)
    _, rec = U.build_record(req, None)
    assert list(rec) == ["status", "kind", "reason", "review", "rounds", "findings", "recordedAt"]


def test_build_record_carries_only_unrestated_accepted_findings_and_caps():
    previous = {"status": "failing", "reason": "r", "findings": {
        "a": {"status": "accepted", "reason": "known"}, "b": {"status": "open"}, "c": {"status": "fixed"}}}
    req = U.parse_request(["--status", "passed", "--findings-json", '{"d":{"status":"open"}}'], P)
    assert list(U.build_record(req, previous)[1]["findings"]) == ["d", "a"]
    restated = U.parse_request(["--status", "passed", "--findings-json", '{"a":{"status":"fixed"}}'], P)
    assert U.build_record(restated, previous)[1]["findings"] == {"a": {"status": "fixed"}}
    many = json.dumps({"k%d" % i: {"status": "open"} for i in range(250)})
    assert len(U.build_record(U.parse_request(["--status", "passed", "--findings-json", many], P), None)[1]["findings"]) == 200


def test_build_record_tolerates_malformed_previous_records():
    req = U.parse_request(["--status", "passed"], P)
    for previous in ("x", [], {"findings": "x"}, {"findings": {"a": "x"}}):
        assert "findings" not in U.build_record(req, previous)[1]


def test_module_imports_only_the_standard_library_and_sanitize():
    tree = ast.parse((SCRIPTS / "usage_record.py").read_text(encoding="utf-8"))
    names = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names |= {a.name.split(".")[0] for a in node.names}
        elif isinstance(node, ast.ImportFrom):
            names.add(node.module.split(".")[0])
    assert names <= {"json", "re", "sys", "time", "sanitize"}, names


@pytest.mark.parametrize("module", ["roadmap.py", "tasks.py"])
def test_neither_writer_keeps_a_copy_of_the_rule(module):
    text = (SCRIPTS / module).read_text(encoding="utf-8")
    assert "USAGE_VALIDATION_" not in text
    assert "def _usage_validation_findings" not in text
    assert "usage_record.parse_request(" in text and "usage_record.build_record(" in text


FAILING = {"status": "failing", "reason": "open bug", "rounds": 1, "findings": {"a": {"status": "accepted", "reason": "k"}}}


def test_an_unable_to_evaluate_skip_keeps_a_stored_failing_record():
    req = U.parse_request(["--status", "skipped", "--kind", "unable-to-evaluate", "--reason", "env down"], P)
    assert U.build_record(req, FAILING) == ("keep", FAILING)
    assert U.kept_answer(FAILING, req) == {
        "kept": "failing",
        "requested": {"status": "skipped", "kind": "unable-to-evaluate", "reason": "env down"},
        "usageValidation": FAILING,
    }


@pytest.mark.parametrize("argv", [
    ["--status", "passed"],
    ["--status", "failing", "--reason", "new"],
    ["--status", "skipped", "--kind", "disabled-by-operator", "--reason", "decided"],
    ["--status", "skipped", "--kind", "not-applicable", "--reason", "nothing to use"],
])
def test_a_judged_or_chosen_verdict_overwrites_a_stored_failing_record(argv):
    action, rec = U.build_record(U.parse_request(argv, P), FAILING)
    assert action == "write" and rec["status"] == argv[1]
    assert rec["findings"]["a"]["status"] == "accepted"


@pytest.mark.parametrize("previous", [None, {"status": "passed"}, {"status": "skipped", "kind": "not-applicable"}, "x"])
def test_an_unable_to_evaluate_skip_overwrites_anything_but_failing(previous):
    req = U.parse_request(["--status", "skipped", "--kind", "unable-to-evaluate", "--reason", "env down"], P)
    action, rec = U.build_record(req, previous)
    assert action == "write" and rec["kind"] == "unable-to-evaluate"
