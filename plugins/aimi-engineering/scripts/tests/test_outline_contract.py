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


# --- outline_shift -----------------------------------------------------------


def oe(idx, title, produces=None, consumes=None):
    return entry(idx, produces=produces, consumes=consumes, title=title)


def stage(run, idx, slug, **story):
    doc = {"title": slug, "dependsOn": []}
    doc.update(story)
    path = run / (idx + "-" + slug + ".json")
    path.write_text(json.dumps(doc), encoding="utf-8")
    return path


def shift(tmp_path, old, new, run=None):
    """Run `--shift` on outline lists; returns (CompletedProcess, run dir)."""
    run = run or (tmp_path / "run")
    run.mkdir(exist_ok=True)
    old_path = write(tmp_path, old, "old.json")
    new_path = write(tmp_path, new, "new.json")
    result = run_module(["--shift", "--staging-dir", str(run), "--old", old_path, "--new", new_path])
    return result, run


def report_of(result):
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def tree(run):
    return {p.name: p.read_bytes() for p in sorted(run.iterdir())}


def test_outline_shift_pure_shift_renames_and_rewrites_without_reexpansion(tmp_path):
    run = tmp_path / "run"
    run.mkdir()
    stage(run, "01", "alpha")
    stage(run, "02", "beta", dependsOn=["outline:01"])
    stage(run, "03", "gamma", dependsOn=["outline:02"], notes="wire after outline:02")
    (run / "audit-result.json").write_text('{"auditedIdx":["01","02","03"]}')
    # A new entry goes first, so every existing entry moves down one place.
    old = [oe("01", "Alpha"), oe("02", "Beta"), oe("03", "Gamma")]
    new = [oe("01", "Fresh"), oe("02", "Alpha"), oe("03", "Beta"), oe("04", "Gamma")]
    report = report_of(shift(tmp_path, old, new, run)[0])
    assert set(report) == {"renamed", "removed", "reexpand", "expand", "auditInvalidated"}
    assert report["renamed"] == [
        {"from": "01", "to": "02", "file": "02-alpha.json"},
        {"from": "02", "to": "03", "file": "03-beta.json"},
        {"from": "03", "to": "04", "file": "04-gamma.json"},
    ]
    assert report["removed"] == [] and report["reexpand"] == []
    assert report["expand"] == ["01"]
    assert report["auditInvalidated"] is True
    assert sorted(p.name for p in run.iterdir()) == ["02-alpha.json", "03-beta.json", "04-gamma.json"]
    assert json.loads((run / "03-beta.json").read_text())["dependsOn"] == ["outline:02"]
    gamma = json.loads((run / "04-gamma.json").read_text())
    assert gamma["dependsOn"] == ["outline:03"] and gamma["notes"] == "wire after outline:03"


def test_outline_shift_chained_shifts_never_collide(tmp_path):
    run = tmp_path / "run"
    run.mkdir()
    # Same slug everywhere, so a naive in-place rename would overwrite a sibling.
    stage(run, "01", "story", marker="one", dependsOn=["outline:02"])
    stage(run, "02", "story2", marker="two", dependsOn=["outline:01", "outline:02"])
    old = [oe("01", "One"), oe("02", "Two")]
    new = [oe("01", "New"), oe("02", "One"), oe("03", "Two")]
    report_of(shift(tmp_path, old, new, run)[0])
    assert json.loads((run / "02-story.json").read_text())["dependsOn"] == ["outline:03"]
    assert json.loads((run / "03-story2.json").read_text())["dependsOn"] == ["outline:02", "outline:03"]
    assert not (run / "01-story.json").exists()


def test_outline_shift_tokens_match_exactly_two_digits_and_skip_removed_entries(tmp_path):
    run = tmp_path / "run"
    run.mkdir()
    stage(run, "02", "kept", notes="see outline:02, outline:020, outline:2 and outline:03 and outline:99",
          dependsOn=["outline:02"])
    old = [oe("01", "Gone"), oe("02", "Kept"), oe("03", "Other")]
    new = [oe("01", "Kept"), oe("02", "Other")]
    report = report_of(shift(tmp_path, old, new, run)[0])
    story = json.loads((run / "01-kept.json").read_text())
    # outline:02 is the entry's own old idx; outline:020 / outline:2 are not tokens;
    # outline:03 moves to 02; outline:99 names nothing and stays.
    assert story["notes"] == "see outline:01, outline:020, outline:2 and outline:02 and outline:99"
    assert story["dependsOn"] == ["outline:01"]
    assert report["removed"] == ["01"]


def test_outline_shift_reexpand_lists_a_kept_story_citing_a_removed_entry(tmp_path):
    run = tmp_path / "run"
    run.mkdir()
    stage(run, "01", "alpha")
    stage(run, "02", "beta", dependsOn=["outline:01"])
    stage(run, "03", "gamma", description="builds on outline:01")
    stage(run, "04", "delta", dependsOn=["outline:02"])
    old = [oe("01", "Alpha"), oe("02", "Beta"), oe("03", "Gamma"), oe("04", "Delta")]
    new = [oe("01", "Beta"), oe("02", "Gamma"), oe("03", "Delta")]
    report = report_of(shift(tmp_path, old, new, run)[0])
    assert report["removed"] == ["01"]
    assert [r["idx"] for r in report["reexpand"]] == ["01", "02"]
    assert all("removed entry 01" in r["reason"] for r in report["reexpand"])
    # The removed entry's own file is gone and the dependent that never cited it is not listed.
    assert sorted(p.name for p in run.iterdir()) == ["01-beta.json", "02-gamma.json", "03-delta.json"]


def test_outline_shift_reexpand_lists_a_kept_entry_whose_own_contract_changed(tmp_path):
    run = tmp_path / "run"
    run.mkdir()
    stage(run, "01", "alpha")
    stage(run, "02", "beta")
    old = [oe("01", "Alpha", produces=["sym:a"]), oe("02", "Beta")]
    new = [oe("01", "Alpha", produces=["sym:a", "sym:b"]), oe("02", "Beta")]
    report = report_of(shift(tmp_path, old, new, run)[0])
    assert [r["idx"] for r in report["reexpand"]] == ["01"]
    assert "produces/consumes changed" in report["reexpand"][0]["reason"]
    assert report["renamed"] == [] and report["auditInvalidated"] is True


def test_outline_shift_reexpand_lists_a_consumer_of_a_producer_that_changed_or_left(tmp_path):
    run = tmp_path / "run"
    run.mkdir()
    for idx, slug in (("01", "p1"), ("02", "p2"), ("03", "c1"), ("04", "c2"), ("05", "c3")):
        stage(run, idx, slug)
    old = [
        oe("01", "P1", produces=["sym:x"]),
        oe("02", "P2", produces=["sym:y"]),
        oe("03", "C1", consumes=["sym:x"]),
        oe("04", "C2", consumes=["sym:y"]),
        oe("05", "C3", consumes=["ext:sym:z"]),
    ]
    new = [
        oe("01", "P1", produces=["sym:x", "sym:x2"]),   # produces changed
        oe("03", "C1", consumes=["sym:x"]),
        oe("04", "C2", consumes=["sym:y"]),             # P2 removed
        oe("05", "C3", consumes=["ext:sym:z"]),
    ]
    report = report_of(shift(tmp_path, old, new, run)[0])
    listed = {r["idx"]: r["reason"] for r in report["reexpand"]}
    # New numbering: P1 01, C1 03, C2 04, C3 05.
    assert set(listed) == {"01", "03", "04"}
    assert "produces/consumes changed" in listed["01"]
    assert "sym:x" in listed["03"] and "whose produces changed" in listed["03"]
    assert "sym:y" in listed["04"] and "removed entry 02" in listed["04"]
    assert "05" not in listed   # the ext: consumer is unaffected


def test_outline_shift_ext_consume_never_matches_a_producer(tmp_path):
    run = tmp_path / "run"
    run.mkdir()
    stage(run, "01", "p")
    stage(run, "02", "c")
    old = [oe("01", "P", produces=["sym:x"]), oe("02", "C", consumes=["ext:sym:x"])]
    new = [oe("01", "P", produces=["sym:x", "sym:more"]), oe("02", "C", consumes=["ext:sym:x"])]
    report = report_of(shift(tmp_path, old, new, run)[0])
    assert [r["idx"] for r in report["reexpand"]] == ["01"]


def test_outline_shift_expand_lists_new_idx_without_a_staged_file(tmp_path):
    run = tmp_path / "run"
    run.mkdir()
    stage(run, "01", "alpha")   # 02 never expanded (it failed earlier)
    old = [oe("01", "Alpha"), oe("02", "Beta")]
    new = [oe("01", "Alpha"), oe("02", "Beta"), oe("03", "Gamma")]
    report = report_of(shift(tmp_path, old, new, run)[0])
    assert report["expand"] == ["02", "03"]
    assert report["reexpand"] == [] and report["renamed"] == []


def test_outline_shift_removed_entry_deletes_its_staged_file(tmp_path):
    run = tmp_path / "run"
    run.mkdir()
    stage(run, "01", "alpha")
    stage(run, "02", "beta")
    old = [oe("01", "Alpha"), oe("02", "Beta")]
    new = [oe("01", "Beta")]
    report = report_of(shift(tmp_path, old, new, run)[0])
    assert report["removed"] == ["01"]
    assert report["renamed"] == [{"from": "02", "to": "01", "file": "01-beta.json"}]
    assert sorted(p.name for p in run.iterdir()) == ["01-beta.json"]


def stamp(run, name, digest="a" * 64):
    path = run / (name + ".validated")
    path.write_text(digest + "\n", encoding="utf-8")
    return path


def test_outline_shift_stamp_is_renamed_together_with_its_story_file(tmp_path):
    run = tmp_path / "run"
    run.mkdir()
    stage(run, "01", "alpha")
    stage(run, "02", "beta")
    stamp(run, "01-alpha.json", "1" * 64)
    stamp(run, "02-beta.json", "2" * 64)
    old = [oe("01", "Alpha"), oe("02", "Beta")]
    new = [oe("01", "Fresh"), oe("02", "Alpha"), oe("03", "Beta")]
    report = report_of(shift(tmp_path, old, new, run)[0])
    assert report["renamed"] == [
        {"from": "01", "to": "02", "file": "02-alpha.json"},
        {"from": "02", "to": "03", "file": "03-beta.json"},
    ]
    assert sorted(p.name for p in run.iterdir()) == [
        "02-alpha.json", "02-alpha.json.validated", "03-beta.json", "03-beta.json.validated",
    ]
    assert (run / "02-alpha.json.validated").read_text() == "1" * 64 + "\n"
    assert (run / "03-beta.json.validated").read_text() == "2" * 64 + "\n"


def test_outline_shift_stamp_is_deleted_together_with_a_removed_story_file(tmp_path):
    run = tmp_path / "run"
    run.mkdir()
    stage(run, "01", "alpha")
    stage(run, "02", "beta")
    stamp(run, "01-alpha.json")
    stamp(run, "02-beta.json", "b" * 64)
    old = [oe("01", "Alpha"), oe("02", "Beta")]
    new = [oe("01", "Beta")]
    report = report_of(shift(tmp_path, old, new, run)[0])
    assert report["removed"] == ["01"]
    assert sorted(p.name for p in run.iterdir()) == ["01-beta.json", "01-beta.json.validated"]
    assert (run / "01-beta.json.validated").read_text() == "b" * 64 + "\n"


def test_outline_shift_stamp_beside_a_story_that_stays_put_is_left_alone(tmp_path):
    run = tmp_path / "run"
    run.mkdir()
    stage(run, "01", "alpha")
    stamp(run, "01-alpha.json")
    outline = [oe("01", "Alpha")]
    before = tree(run)
    report_of(shift(tmp_path, outline, outline, run)[0])
    assert tree(run) == before


def test_outline_shift_stamp_is_never_read_as_a_staged_story(tmp_path):
    run = tmp_path / "run"
    run.mkdir()
    stage(run, "01", "alpha")
    stamp(run, "01-alpha.json")
    outline = [oe("01", "Alpha")]
    # A staged-index collision or an unmatched idx would refuse; neither happens.
    assert report_of(shift(tmp_path, outline, outline, run)[0])["auditInvalidated"] is False


def test_outline_shift_leaves_no_orphaned_stamp(tmp_path):
    run = tmp_path / "run"
    run.mkdir()
    stage(run, "01", "alpha")
    stage(run, "02", "beta")
    stage(run, "03", "gamma")
    for name in ("01-alpha.json", "02-beta.json", "03-gamma.json"):
        stamp(run, name)
    old = [oe("01", "Alpha"), oe("02", "Beta"), oe("03", "Gamma")]
    new = [oe("01", "Gamma"), oe("02", "Alpha")]
    report_of(shift(tmp_path, old, new, run)[0])
    names = sorted(p.name for p in run.iterdir())
    stories = [n for n in names if n.endswith(".json")]
    assert stories == ["01-gamma.json", "02-alpha.json"]
    assert [n for n in names if n.endswith(".validated")] == [n + ".validated" for n in stories]


def test_outline_shift_unchanged_outline_leaves_the_audit_and_reports_nothing(tmp_path):
    run = tmp_path / "run"
    run.mkdir()
    stage(run, "01", "alpha")
    stage(run, "02", "beta", dependsOn=["outline:01"])
    (run / "audit-result.json").write_text('{"auditedIdx":["01","02"]}')
    outline = [oe("01", "Alpha", produces=["sym:a"]), oe("02", "Beta", consumes=["sym:a"])]
    before = tree(run)
    report = report_of(shift(tmp_path, outline, outline, run)[0])
    assert report == {"renamed": [], "removed": [], "reexpand": [], "expand": [], "auditInvalidated": False}
    assert tree(run) == before


def test_outline_shift_deletes_the_stale_audit_when_anything_changed(tmp_path):
    run = tmp_path / "run"
    run.mkdir()
    stage(run, "01", "alpha")
    (run / "audit-result.json").write_text('{"auditedIdx":["01"]}')
    old = [oe("01", "Alpha")]
    new = [oe("01", "Alpha"), oe("02", "Beta")]
    report = report_of(shift(tmp_path, old, new, run)[0])
    assert report["auditInvalidated"] is True and report["expand"] == ["02"]
    assert not (run / "audit-result.json").exists()


@pytest.mark.parametrize("setup", ["stray", "duplicate", "unreadable"])
def test_outline_shift_refuses_and_changes_nothing(tmp_path, setup):
    run = tmp_path / "run"
    run.mkdir()
    stage(run, "01", "alpha")
    stage(run, "02", "beta")
    (run / "audit-result.json").write_text('{"auditedIdx":["01","02"]}')
    if setup == "stray":
        stage(run, "07", "stray")
        needle = "07-stray.json"
    elif setup == "duplicate":
        stage(run, "02", "twin")
        needle = "02-"
    else:
        (run / "02-beta.json").write_text("{not json")
        needle = "02-beta.json"
    old = [oe("01", "Alpha"), oe("02", "Beta")]
    new = [oe("01", "Beta")]
    before = tree(run)
    result, _ = shift(tmp_path, old, new, run)
    assert result.returncode == 1
    assert result.stdout == ""
    assert result.stderr.startswith("Error: outline-shift: ") and needle in result.stderr
    assert tree(run) == before


@pytest.mark.parametrize("make_args", [
    lambda tmp, run: ["--shift", "--old", "o", "--new", "n"],
    lambda tmp, run: ["--shift", "--staging-dir", str(run), "--new", write(tmp, [], "n.json")],
    lambda tmp, run: ["--shift", "--staging-dir", str(run), "--old", write(tmp, [], "o.json")],
    lambda tmp, run: ["--shift", "--staging-dir", str(run / "absent"), "--old", "o", "--new", "n"],
    lambda tmp, run: ["--shift", "--staging-dir", str(run), "--old", str(tmp / "nope.json"), "--new", write(tmp, [], "n.json")],
    lambda tmp, run: ["--shift", "--staging-dir", str(run), "--old", write(tmp, {"a": 1}, "o.json"), "--new", write(tmp, [], "n.json")],
    lambda tmp, run: ["--shift", "--bogus", "x"],
])
def test_outline_shift_argument_refusals_are_stderr_only(tmp_path, make_args):
    run = tmp_path / "run"
    run.mkdir()
    result = run_module(make_args(tmp_path, run))
    assert result.returncode == 1 and result.stdout == ""
    assert result.stderr.startswith("Error: outline-shift: ")


def test_outline_shift_uses_rename_and_never_the_write_path_for_staged_files():
    source = open(MODULE, encoding="utf-8").read()
    start = source.index("def apply_shift")
    body = source[start:source.index("def shift_main")]
    assert "os.rename" in body and "os.replace" in body
    assert "open(path" not in body and 'open(os.path.join(staging_dir' not in body


def test_outline_shift_cli_confines_every_path_before_python_starts(tmp_path):
    project = tmp_path / "proj"
    run = project / ".aimi" / ".tasks-staging" / "r"
    run.mkdir(parents=True)
    stage(run, "01", "alpha")
    old = write(project, [oe("01", "Alpha")], "old.json")
    new = write(project, [oe("01", "Alpha"), oe("02", "Beta")], "new.json")
    ok = subprocess.run([CLI, "outline-shift", "--staging-dir", str(run), "--old", old, "--new", new],
                        capture_output=True, text=True, cwd=str(project))
    assert ok.returncode == 0, ok.stderr
    assert json.loads(ok.stdout)["expand"] == ["02"]
    outside = str(tmp_path / "elsewhere")
    os.makedirs(outside)
    for args in (
        ["--staging-dir", outside, "--old", old, "--new", new],
        ["--staging-dir", str(run), "--old", os.path.join(outside, "o.json"), "--new", new],
        ["--staging-dir", str(run), "--old", old, "--new", os.path.join(outside, "n.json")],
    ):
        refused = subprocess.run([CLI, "outline-shift"] + args, capture_output=True, text=True, cwd=str(project))
        assert refused.returncode == 1 and "escapes project root" in refused.stderr
    helped = subprocess.run([CLI, "help"], capture_output=True, text=True, cwd=str(project))
    assert "outline-shift --staging-dir <dir> --old <path> --new <path>" in helped.stdout
