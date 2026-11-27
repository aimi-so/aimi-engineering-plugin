"""Tests for the staging-contention verb and story_merge.staging_contention.

The verb runs tasks.wave_symbol_contention over the staged `NN-*.json` files and
prints the pairs the wave check would refuse to run together, so the cross-story
auditor serializes exactly those instead of re-deriving the shared-path rule.
Every case builds a throwaway project under pytest's tmp_path with the project
as cwd (the staging directory sits under its `.aimi/`), and drives the real
aimi-cli.sh; the Python function is exercised directly for the refusals.
"""

import ast
import json
import os
import subprocess
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import story_merge as SM  # noqa: E402
from audit_patches import AuditRefusal  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
CLI = os.path.join(SCRIPTS, "aimi-cli.sh")
STG = ".aimi/stg"


def story(files, symbols=None, deps=None, project=None):
    implementation = {"files": list(files), "approach": "Do it", "verify": "true"}
    if symbols is not None:
        implementation["symbols"] = symbols
    value = {
        "title": "Story",
        "description": "As a user, I want it so that it works.",
        "acceptanceCriteria": ["Typecheck passes"],
        "priority": 1,
        "status": "pending",
        "dependsOn": deps or [],
        "implementation": implementation,
    }
    if project is not None:
        value["project"] = project
    return value


def stage(tmp_path, files, config=None):
    root = str(tmp_path)
    staging = os.path.join(root, ".aimi", "stg")
    os.makedirs(staging, exist_ok=True)
    for name, value in files.items():
        with open(os.path.join(staging, name), "w", encoding="utf-8") as handle:
            handle.write(value if isinstance(value, str) else json.dumps(value))
    if config is not None:
        with open(os.path.join(root, ".aimi", "config.json"), "w", encoding="utf-8") as handle:
            handle.write(config if isinstance(config, str) else json.dumps(config))


def run(tmp_path, args=None):
    return subprocess.run(
        ["bash", CLI, "staging-contention"] + (["--staging-dir", STG] if args is None else args),
        cwd=str(tmp_path),
        capture_output=True,
        text=True,
        timeout=120,
    )


def pairs_of(proc):
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.count("\n") == 1 and proc.stdout.endswith("\n")
    assert " " not in proc.stdout
    return json.loads(proc.stdout)["pairs"]


def test_staging_contention_a_whole_file_claim_gives_a_pair_with_a_null_symbol(tmp_path):
    stage(tmp_path, {"01-a.json": story(["src/x.ts"]), "02-b.json": story(["src/x.ts"])})
    proc = run(tmp_path)
    assert proc.stdout == (
        '{"pairs":[{"wave":1,"path":"src/x.ts","symbol":null,'
        '"stories":["outline:01","outline:02"]}]}\n'
    )
    assert proc.returncode == 0


def test_staging_contention_a_shared_symbol_gives_a_pair_with_that_symbol(tmp_path):
    shared = {"src/x.ts": {"creates": ["alpha", "beta"]}}
    other = {"src/x.ts": {"edits": ["beta", "gamma"]}}
    stage(
        tmp_path,
        {"01-a.json": story(["src/x.ts"], shared), "02-b.json": story(["src/x.ts"], other)},
    )
    assert pairs_of(run(tmp_path)) == [
        {"wave": 1, "path": "src/x.ts", "symbol": "beta", "stories": ["outline:01", "outline:02"]}
    ]


def test_staging_contention_a_shared_file_with_disjoint_symbols_is_a_warning_and_no_pair(tmp_path):
    stage(
        tmp_path,
        {
            "01-a.json": story(["src/x.ts"], {"src/x.ts": {"creates": ["alpha"]}}),
            "02-b.json": story(["src/x.ts"], {"src/x.ts": {"creates": ["beta"]}}),
        },
    )
    proc = run(tmp_path)
    assert proc.stdout == '{"pairs":[]}\n'
    assert proc.returncode == 0


def test_staging_contention_no_contention_is_an_empty_list_at_exit_zero(tmp_path):
    stage(tmp_path, {"01-a.json": story(["a.ts"]), "02-b.json": story(["b.ts"])})
    proc = run(tmp_path)
    assert (proc.stdout, proc.returncode) == ('{"pairs":[]}\n', 0)


def test_staging_contention_three_claimants_give_one_pair_per_two_lower_index_first(tmp_path):
    stage(
        tmp_path,
        {
            "03-c.json": story(["src/x.ts"]),
            "01-a.json": story(["src/x.ts"]),
            "02-b.json": story(["src/x.ts"]),
        },
    )
    assert [p["stories"] for p in pairs_of(run(tmp_path))] == [
        ["outline:01", "outline:02"],
        ["outline:01", "outline:03"],
        ["outline:02", "outline:03"],
    ]


def test_staging_contention_pairs_follow_the_findings_order_wave_then_path(tmp_path):
    stage(
        tmp_path,
        {
            "01-a.json": story(["z.ts", "m.ts"]),
            "02-b.json": story(["m.ts", "z.ts"]),
            "03-c.json": story(["z.ts"], deps=["outline:01"]),
            "04-d.json": story(["z.ts"], deps=["outline:02"]),
        },
    )
    got = [(p["wave"], p["path"], p["stories"]) for p in pairs_of(run(tmp_path))]
    assert got == [
        (1, "z.ts", ["outline:01", "outline:02"]),
        (1, "m.ts", ["outline:01", "outline:02"]),
        (2, "z.ts", ["outline:03", "outline:04"]),
    ]


def test_staging_contention_a_dependency_puts_two_stories_in_different_waves(tmp_path):
    stage(
        tmp_path,
        {
            "01-a.json": story(["src/x.ts"]),
            "02-b.json": story(["src/x.ts"], deps=["outline:01"]),
        },
    )
    assert pairs_of(run(tmp_path)) == []


def test_staging_contention_a_token_with_no_staged_file_is_dropped(tmp_path):
    # outline:09 has no staged file, an "US-001" and a non-string token are no
    # outline token: all dropped, so the story is a root and shares wave 1.
    stage(
        tmp_path,
        {
            "01-a.json": story(["src/x.ts"]),
            "02-b.json": story(["src/x.ts"], deps=["outline:09", "US-001", 7, "outline:1"]),
        },
    )
    assert [p["stories"] for p in pairs_of(run(tmp_path))] == [["outline:01", "outline:02"]]


def test_staging_contention_a_story_in_a_cycle_has_no_wave_and_is_skipped(tmp_path):
    stage(
        tmp_path,
        {
            "01-a.json": story(["src/x.ts"], deps=["outline:02"]),
            "02-b.json": story(["src/x.ts"], deps=["outline:01"]),
            "03-c.json": story(["src/x.ts"]),
            "04-d.json": story(["src/x.ts"]),
        },
    )
    assert [p["stories"] for p in pairs_of(run(tmp_path))] == [["outline:03", "outline:04"]]


def test_staging_contention_two_projects_listing_one_path_do_not_contend(tmp_path):
    stage(
        tmp_path,
        {
            "01-a.json": story(["src/x.ts"], project="web"),
            "02-b.json": story(["src/x.ts"], project="api"),
        },
    )
    assert pairs_of(run(tmp_path)) == []


def test_staging_contention_a_declared_bookkeeping_path_yields_no_pair(tmp_path):
    config = {"bookkeeping": {".": {"CHANGELOG.md": {"rule": "union-lines"}}}}
    stage(
        tmp_path,
        {
            "01-a.json": story(["CHANGELOG.md", "a.ts"]),
            "02-b.json": story(["CHANGELOG.md", "a.ts"]),
        },
        config,
    )
    assert [p["path"] for p in pairs_of(run(tmp_path))] == ["a.ts"]


def test_staging_contention_the_same_path_without_a_declaration_is_a_pair(tmp_path):
    stage(tmp_path, {"01-a.json": story(["CHANGELOG.md"]), "02-b.json": story(["CHANGELOG.md"])})
    assert [p["path"] for p in pairs_of(run(tmp_path))] == ["CHANGELOG.md"]


@pytest.mark.parametrize(
    "config",
    ["{not json", json.dumps({"bookkeeping": {".": {"A": {"rule": "nope"}}}})],
)
def test_staging_contention_a_broken_bookkeeping_declaration_refuses_at_exit_one(tmp_path, config):
    stage(tmp_path, {"01-a.json": story(["a.ts"]), "02-b.json": story(["a.ts"])}, config)
    proc = run(tmp_path)
    assert proc.returncode == 1
    assert proc.stdout == ""
    assert "config.json" in proc.stderr


def test_staging_contention_a_file_that_is_not_an_object_is_skipped(tmp_path):
    stage(
        tmp_path,
        {
            "01-a.json": story(["src/x.ts"]),
            "02-b.json": [story(["src/x.ts"])],
            "03-c.json": "{broken",
            "04-d.json": story(["src/x.ts"]),
        },
    )
    assert [p["stories"] for p in pairs_of(run(tmp_path))] == [["outline:01", "outline:04"]]


def test_staging_contention_an_empty_directory_prints_no_pairs(tmp_path):
    stage(tmp_path, {})
    proc = run(tmp_path)
    assert (proc.stdout, proc.returncode) == ('{"pairs":[]}\n', 0)


def test_staging_contention_two_files_sharing_an_idx_refuse_naming_the_file(tmp_path):
    stage(tmp_path, {"01-a.json": story(["a.ts"]), "01-b.json": story(["a.ts"])})
    proc = run(tmp_path)
    assert proc.returncode == 1
    assert proc.stdout == ""
    assert "01-a.json" in proc.stderr and "01-b.json" in proc.stderr


def test_staging_contention_a_sidecar_is_not_a_staged_story(tmp_path):
    stage(
        tmp_path,
        {
            "01-a.json": story(["src/x.ts"]),
            "02-outline.json": story(["src/x.ts"]),
            "audit-result.json": {"patches": []},
        },
    )
    assert pairs_of(run(tmp_path)) == []


# --- the wrapper -------------------------------------------------------------


def test_staging_contention_wrapper_refuses_a_missing_staging_dir_flag(tmp_path):
    stage(tmp_path, {})
    proc = run(tmp_path, [])
    assert proc.returncode == 1
    assert "usage: aimi-cli.sh staging-contention" in proc.stderr


def test_staging_contention_wrapper_refuses_a_flag_without_a_value(tmp_path):
    stage(tmp_path, {})
    proc = run(tmp_path, ["--staging-dir"])
    assert proc.returncode == 1
    assert "usage: aimi-cli.sh staging-contention" in proc.stderr


def test_staging_contention_wrapper_refuses_an_unknown_flag(tmp_path):
    stage(tmp_path, {})
    proc = run(tmp_path, ["--staging-dir", STG, "--outline", "x"])
    assert proc.returncode == 1
    assert "usage: aimi-cli.sh staging-contention" in proc.stderr
    assert proc.stdout == ""


def test_staging_contention_wrapper_refuses_a_missing_directory(tmp_path):
    stage(tmp_path, {})
    proc = run(tmp_path, ["--staging-dir", ".aimi/nowhere"])
    assert proc.returncode == 1
    assert "does not exist" in proc.stderr


def test_staging_contention_wrapper_confines_the_staging_dir(tmp_path):
    stage(tmp_path, {})
    outside = tmp_path.parent / (tmp_path.name + "-outside")
    outside.mkdir()
    proc = run(tmp_path, ["--staging-dir", str(outside)])
    assert proc.returncode == 1
    assert proc.stdout == ""


def test_staging_contention_the_wrapper_calls_check_python3_and_crosses_once():
    with open(CLI, encoding="utf-8") as handle:
        text = handle.read()
    start = text.index("cmd_staging_contention() {")
    body = text[start : text.index("\n}\n", start)]
    assert body.count("check_python3") == 1
    assert body.count("story_merge.py") == 1
    assert body.index("validate_path_in_project") < body.index("check_python3")


def test_staging_contention_help_lists_the_verb():
    proc = subprocess.run(["bash", CLI, "help"], capture_output=True, text=True, timeout=60)
    assert "staging-contention --staging-dir <dir>" in proc.stdout


# --- the function ------------------------------------------------------------


def test_staging_contention_function_returns_pairs_and_raises_on_a_duplicate_idx(tmp_path):
    stage(tmp_path, {"01-a.json": story(["a.ts"]), "02-b.json": story(["a.ts"])})
    root = str(tmp_path)
    got = SM.staging_contention(os.path.join(root, ".aimi", "stg"), root)
    assert got == [{"wave": 1, "path": "a.ts", "symbol": None, "stories": ["outline:01", "outline:02"]}]
    stage(tmp_path, {"01-z.json": story(["a.ts"])})
    with pytest.raises(AuditRefusal):
        SM.staging_contention(os.path.join(root, ".aimi", "stg"), root)


def test_staging_contention_reads_findings_and_never_calls_wave_contention():
    with open(os.path.join(SCRIPTS, "story_merge.py"), encoding="utf-8") as handle:
        tree = ast.parse(handle.read())
    function = next(
        node for node in tree.body
        if isinstance(node, ast.FunctionDef) and node.name == "staging_contention"
    )
    names = {n.id for n in ast.walk(function) if isinstance(n, ast.Name)}
    names |= {n.attr for n in ast.walk(function) if isinstance(n, ast.Attribute)}
    assert "wave_symbol_contention" in names and "computed_waves" in names
    assert "wave_contention" not in names
