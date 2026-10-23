"""Tests for scripts/outline_contract.py, the module behind `validate-outline`.

What is worth pinning here is the contract, not the happy path: that the report
shape is stable, that every error code is reachable and names its token, that an
invalid outline prints the object and still exits 1 while an unreadable
argument prints nothing on stdout, and that importing the module stays out of
the tasks -> story_merge -> audit_patches chain.
"""

import json
import os
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
sys.path.insert(0, SCRIPTS)

import outline_contract as OC  # noqa: E402

CLI = os.path.join(SCRIPTS, "aimi-cli.sh")
MODULE = os.path.join(SCRIPTS, "outline_contract.py")

ALL_CODES = {
    "bad-idx", "duplicate-idx", "bad-contract", "bad-token", "duplicate-produces",
    "unproduced-consume", "self-consume", "external-also-produced", "cycle",
}


def entry(idx, produces=None, consumes=None, **extra):
    doc = {"idx": idx, "title": "T" + idx, "summary": "s"}
    if produces is not None:
        doc["produces"] = produces
    if consumes is not None:
        doc["consumes"] = consumes
    doc.update(extra)
    return doc


def codes(report):
    return [e["code"] for e in report["errors"]]


def run_module(args, cwd=None):
    return subprocess.run(
        [sys.executable, MODULE] + args, capture_output=True, text=True, cwd=cwd
    )


# --- shape and waves ---------------------------------------------------------


def test_report_shape_and_layering():
    report = OC.validate_outline([
        entry("01", produces=["sym:foo"]),
        entry("02", produces=["path:src/b.py"], consumes=["sym:foo"]),
        entry("03", consumes=["sym:foo", "path:src/b.py"]),
    ])
    assert set(report) == {"valid", "errors", "waves", "edges", "counts"}
    assert report["valid"] is True
    assert report["errors"] == []
    assert report["waves"] == [["01"], ["02"], ["03"]]
    assert report["edges"] == [
        {"from": "01", "to": "02", "name": "sym:foo"},
        {"from": "01", "to": "03", "name": "sym:foo"},
        {"from": "02", "to": "03", "name": "path:src/b.py"},
    ]
    assert report["counts"] == {
        "01": {"produces": 1, "consumes": 0},
        "02": {"produces": 1, "consumes": 1},
        "03": {"produces": 0, "consumes": 2},
    }


def test_waves_are_sorted_by_idx_and_independent_entries_share_a_wave():
    report = OC.validate_outline([
        entry("03", consumes=["sym:a"]),
        entry("02"),
        entry("01", produces=["sym:a"]),
    ])
    assert report["waves"] == [["01", "02"], ["03"]]


def test_edges_are_sorted_and_deduplicated():
    report = OC.validate_outline([
        entry("02", produces=["sym:b"]),
        entry("01", produces=["sym:a"]),
        entry("03", consumes=["sym:b", "sym:a", "sym:a"]),
    ])
    assert [(e["from"], e["name"]) for e in report["edges"]] == [("01", "sym:a"), ("02", "sym:b")]


def test_outline_without_any_contract_keys_is_one_wave():
    report = OC.validate_outline([entry("02"), entry("01"), entry("03")])
    assert report["valid"] is True
    assert report["waves"] == [["01", "02", "03"]]
    assert report["edges"] == []
    assert report["counts"]["01"] == {"produces": 0, "consumes": 0}


def test_ext_consume_needs_no_producer_and_adds_no_edge():
    report = OC.validate_outline([entry("01", consumes=["ext:path:src/old.py"])])
    assert report["valid"] is True
    assert report["edges"] == []
    assert report["waves"] == [["01"]]


def test_all_four_kinds_are_accepted():
    report = OC.validate_outline([
        entry("01", produces=["sym:Foo", "path:a/b.py", "cli:validate-outline", "http:GET /api/x"]),
        entry("02", consumes=["sym:Foo", "http:GET /api/x"]),
    ])
    assert report["valid"] is True, report["errors"]


# --- token grammar -----------------------------------------------------------


@pytest.mark.parametrize("token, code", [
    ("foo", "bad-token"),
    ("fn:foo", "bad-token"),
    ("sym:", "bad-token"),
    ("", "bad-token"),
    (7, "bad-token"),
    ("ext:sym:foo", "bad-token"),          # ext: is consumes-only
    ("sym:has space", "bad-contract"),
    ("cli:two words", "bad-contract"),
    ("path:/abs/file.py", "bad-contract"),
    ("path:a/../b.py", "bad-contract"),
    ("path:..", "bad-contract"),
    ("http:/api/x", "bad-contract"),        # no method
    ("http:GET  /api/x", "bad-contract"),   # two spaces
    ("http:FETCH /api/x", "bad-contract"),
    ("http:GET /a b", "bad-contract"),
])
def test_bad_produce_tokens(token, code):
    report = OC.validate_outline([entry("01", produces=[token])])
    assert report["valid"] is False
    assert codes(report) == [code]
    if isinstance(token, str) and token:
        assert token in report["errors"][0]["message"]


def test_name_is_judged_by_roadmaps_identity_reasons():
    import roadmap
    name = "a" * (roadmap.CONTRACT_MAXLEN + 1)
    assert roadmap._identity_reasons(name, "")
    report = OC.validate_outline([entry("01", produces=["sym:" + name])])
    assert codes(report) == ["bad-contract"]


def test_ext_marker_is_rejected_in_produces_only():
    produces = OC.validate_outline([entry("01", produces=["ext:sym:foo"])])
    consumes = OC.validate_outline([entry("01", consumes=["ext:sym:foo"])])
    assert codes(produces) == ["bad-token"]
    assert consumes["valid"] is True


def test_non_array_contract_value_is_bad_contract():
    report = OC.validate_outline([entry("01", produces="sym:foo")])
    assert codes(report) == ["bad-contract"]


# --- error codes -------------------------------------------------------------


def test_bad_and_duplicate_idx():
    report = OC.validate_outline([entry("1"), entry("02"), entry("02"), {"idx": 3}, "nope"])
    assert codes(report) == ["bad-idx", "duplicate-idx", "bad-idx", "bad-idx"]
    assert report["valid"] is False
    assert report["waves"] == []


def test_duplicate_produces_across_entries_and_within_one():
    across = OC.validate_outline([entry("01", produces=["sym:a"]), entry("02", produces=["sym:a"])])
    within = OC.validate_outline([entry("01", produces=["sym:a", "sym:a"])])
    assert codes(across) == ["duplicate-produces"]
    assert codes(within) == ["duplicate-produces"]
    assert "sym:a" in across["errors"][0]["message"]


def test_unproduced_consume_names_the_token():
    report = OC.validate_outline([entry("01", consumes=["sym:ghost"])])
    assert codes(report) == ["unproduced-consume"]
    assert report["errors"][0]["idx"] == "01"
    assert "sym:ghost" in report["errors"][0]["message"]


def test_self_consume():
    report = OC.validate_outline([entry("01", produces=["sym:a"], consumes=["sym:a"])])
    assert codes(report) == ["self-consume"]
    assert report["edges"] == []


def test_external_also_produced():
    report = OC.validate_outline([
        entry("01", produces=["sym:a"]),
        entry("02", consumes=["ext:sym:a"]),
    ])
    assert codes(report) == ["external-also-produced"]
    assert report["errors"][0]["idx"] == "02"


def test_cycle_reports_a_concrete_idx_path():
    report = OC.validate_outline([
        entry("01", produces=["sym:a"], consumes=["sym:c"]),
        entry("02", produces=["sym:b"], consumes=["sym:a"]),
        entry("03", produces=["sym:c"], consumes=["sym:b"]),
        entry("04"),
    ])
    assert codes(report) == ["cycle"]
    message = report["errors"][0]["message"]
    assert "01 -> 02 -> 03 -> 01" in message
    assert "04" not in message
    assert report["waves"] == []


def test_every_documented_code_is_reachable():
    seen = set()
    for outline in (
        [entry("x")],
        [entry("01"), entry("01")],
        [entry("01", produces=["sym:a b"])],
        [entry("01", produces=["nope"])],
        [entry("01", produces=["sym:a"]), entry("02", produces=["sym:a"])],
        [entry("01", consumes=["sym:a"])],
        [entry("01", produces=["sym:a"], consumes=["sym:a"])],
        [entry("01", produces=["sym:a"]), entry("02", consumes=["ext:sym:a"])],
        [entry("01", produces=["sym:a"], consumes=["sym:b"]), entry("02", produces=["sym:b"], consumes=["sym:a"])],
    ):
        seen.update(codes(OC.validate_outline(outline)))
    assert seen == ALL_CODES


# --- entry point -------------------------------------------------------------


def write(tmp_path, doc, name="outline.json"):
    path = tmp_path / name
    path.write_text(doc if isinstance(doc, str) else json.dumps(doc), encoding="utf-8")
    return str(path)


def test_main_valid_prints_object_and_exits_0(tmp_path):
    path = write(tmp_path, [entry("01", produces=["sym:a"]), entry("02", consumes=["sym:a"])])
    result = run_module(["--outline", path])
    assert result.returncode == 0
    assert json.loads(result.stdout)["waves"] == [["01"], ["02"]]
    assert result.stderr == ""


def test_main_invalid_prints_object_and_exits_1(tmp_path):
    path = write(tmp_path, [entry("01", consumes=["sym:ghost"])])
    result = run_module(["--outline", path])
    assert result.returncode == 1
    report = json.loads(result.stdout)
    assert report["valid"] is False and report["waves"] == []
    assert report["errors"][0]["code"] == "unproduced-consume"


@pytest.mark.parametrize("make_args", [
    lambda tmp: [],
    lambda tmp: ["--outline"],
    lambda tmp: ["--outline", str(tmp / "absent.json")],
    lambda tmp: ["--outline", write(tmp, "{not json")],
    lambda tmp: ["--outline", write(tmp, {"idx": "01"}, "obj.json")],
    lambda tmp: ["--bogus", "x"],
])
def test_main_refusals_are_stderr_only(tmp_path, make_args):
    result = run_module(make_args(tmp_path))
    assert result.returncode == 1
    assert result.stdout == ""
    assert result.stderr.startswith("Error: validate-outline: ")


def test_importing_the_module_loads_none_of_the_heavy_chain():
    code = (
        "import sys; sys.path.insert(0, %r); import outline_contract; "
        "bad = [m for m in ('tasks', 'story_merge', 'audit_patches') if m in sys.modules]; "
        "print(','.join(bad)); sys.exit(1 if bad else 0)" % SCRIPTS
    )
    result = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
    assert result.returncode == 0, "imported: " + result.stdout


# --- CLI wiring --------------------------------------------------------------


def test_cli_routes_the_verb_and_lists_it_in_help(tmp_path):
    path = write(tmp_path, [entry("01")])
    env = dict(os.environ)
    ran = subprocess.run([CLI, "validate-outline", "--outline", path],
                         capture_output=True, text=True, env=env, cwd=str(tmp_path))
    # The tmp dir is outside any project root, so confinement may refuse it; the
    # point here is only that the verb is dispatched and never "unknown command".
    assert "Unknown command" not in ran.stderr and "unknown command" not in ran.stderr.lower()
    helped = subprocess.run([CLI, "help"], capture_output=True, text=True, env=env)
    assert "validate-outline --outline <path>" in helped.stdout
