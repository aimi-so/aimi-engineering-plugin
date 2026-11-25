"""Tests for the required implementation.symbols declaration and the symbol-produces smell.

Two behaviours of story_merge.py, both driven through the real aimi-cli.sh in a
throwaway project under pytest's tmp_path:

* a staged story that declares no `implementation.symbols` (no key, or null) is
  always a `validate-staging` finding, and a `story-merge --require-symbols`
  refusal that writes nothing. Both read one per-story function.
* `story-merge --outline <path>` compares each declared story's created names
  with the `sym:`/`cli:` names its outline entry produces and records an
  advisory `symbol-produces` smell. It never refuses.

The golden file is not read or written here; the flag being opt-in is what keeps
the recorded story_merge cases replaying unchanged.
"""

import ast
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import story_merge as SM  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
CLI = os.path.join(SCRIPTS, "aimi-cli.sh")

OUT = ".aimi/tasks/out-tasks.json"


def story(title, symbols="__absent__", files=None):
    implementation = {
        "files": ["src/x.ts"] if files is None else files,
        "approach": "Implement it",
        "verify": "tsc --noEmit",
    }
    if symbols != "__absent__":
        implementation["symbols"] = symbols
    return {
        "title": title,
        "description": "As a user, I want " + title + " so that it works.",
        "acceptanceCriteria": ["Typecheck passes"],
        "priority": 1,
        "status": "pending",
        "dependsOn": [],
        "notes": "",
        "implementation": implementation,
    }


def outline_entry(idx, produces=None):
    entry = {"idx": idx, "title": "Entry " + idx}
    if produces is not None:
        entry["produces"] = produces
    return entry


def stage(tmp_path, files, outline=None):
    root = str(tmp_path)
    files = dict(files)
    numbered = sorted(n[:2] for n in files if n[:2].isdigit())
    if len(numbered) >= 2 and "audit-result.json" not in files:
        files["audit-result.json"] = {"patches": [], "unresolved": [], "auditedIdx": numbered}
    staging = os.path.join(root, ".aimi", "stg")
    os.makedirs(staging, exist_ok=True)
    os.makedirs(os.path.join(root, ".aimi", "tasks"), exist_ok=True)
    for name, value in files.items():
        with open(os.path.join(staging, name), "w", encoding="utf-8") as handle:
            handle.write(value if isinstance(value, str) else json.dumps(value))
    if outline is not None:
        with open(os.path.join(root, ".aimi", "outline.json"), "w", encoding="utf-8") as handle:
            json.dump(outline, handle)


def run(tmp_path, verb, args):
    return subprocess.run(
        ["bash", CLI, verb] + args,
        cwd=str(tmp_path),
        capture_output=True,
        text=True,
        timeout=120,
    )


def validate_staging(tmp_path):
    return run(tmp_path, "validate-staging", ["--staging-dir", ".aimi/stg"])


def merge(tmp_path, args=None):
    proc = run(
        tmp_path,
        "story-merge",
        ["--staging-dir", ".aimi/stg", "--output", OUT] + (args or []),
    )
    written = os.path.join(str(tmp_path), OUT)
    doc = None
    if os.path.isfile(written):
        with open(written, encoding="utf-8") as handle:
            doc = json.load(handle)
    return proc, doc


def smells(doc, kind="symbol-produces"):
    found = (doc.get("metadata") or {}).get("smellWarnings") or []
    return [entry for entry in found if entry.get("type") == kind]


# ---------------------------------------------------------------------------
# validate-staging: always on
# ---------------------------------------------------------------------------


def test_validate_staging_reports_a_missing_key_by_idx(tmp_path):
    stage(tmp_path, {"01-a.json": story("A"), "02-b.json": story("B", {})})
    proc = validate_staging(tmp_path)
    assert proc.returncode == 1, proc.stdout + proc.stderr
    report = json.loads(proc.stdout)
    assert list(report) == ["01"]
    assert len(report["01"]) == 1
    finding = report["01"][0]
    assert "implementation.symbols" in finding
    assert "{}" in finding and "no file has a nameable symbol" in finding


def test_validate_staging_reports_a_null_key(tmp_path):
    stage(tmp_path, {"01-a.json": story("A", None)})
    proc = validate_staging(tmp_path)
    assert proc.returncode == 1, proc.stdout + proc.stderr
    findings = json.loads(proc.stdout)["01"]
    assert any(
        "implementation.symbols is missing" in f and "{}" in f for f in findings
    ), findings


def test_validate_staging_passes_an_empty_map_and_a_well_formed_map(tmp_path):
    stage(
        tmp_path,
        {
            "01-a.json": story("A", {}),
            "02-b.json": story("B", {"src/x.ts": {"creates": ["parse"], "edits": ["Foo.bar"]}}),
        },
    )
    proc = validate_staging(tmp_path)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert json.loads(proc.stdout) == {}


def test_validate_staging_has_no_flag_for_the_rule(tmp_path):
    # The check is always on: the verb takes no flag that could turn it off.
    stage(tmp_path, {"01-a.json": story("A")})
    proc = run(tmp_path, "validate-staging", ["--staging-dir", ".aimi/stg", "--require-symbols"])
    assert proc.returncode == 1
    assert "unknown flag" in proc.stderr or "usage" in proc.stderr


# ---------------------------------------------------------------------------
# story-merge --require-symbols: opt-in refusal
# ---------------------------------------------------------------------------


def test_require_symbols_refuses_naming_story_and_idx_and_writes_nothing(tmp_path):
    stage(tmp_path, {"01-a.json": story("A", {}), "02-b.json": story("B")})
    proc, doc = merge(tmp_path, ["--require-symbols"])
    assert proc.returncode == 1 and doc is None
    assert "Story US-002 (staged 02): implementation.symbols is missing" in proc.stderr
    assert "US-001" not in proc.stderr
    assert "{} when no file has a nameable symbol" in proc.stderr
    assert not os.path.exists(os.path.join(str(tmp_path), OUT))
    assert os.path.isdir(os.path.join(str(tmp_path), ".aimi", "stg"))


def test_require_symbols_refuses_a_null_key(tmp_path):
    stage(tmp_path, {"01-a.json": story("A", None)})
    proc, doc = merge(tmp_path, ["--require-symbols"])
    assert proc.returncode == 1 and doc is None
    assert "Story US-001 (staged 01)" in proc.stderr


def test_the_same_stories_merge_without_the_flag(tmp_path):
    stage(tmp_path, {"01-a.json": story("A"), "02-b.json": story("B", {})})
    proc, doc = merge(tmp_path)
    assert proc.returncode == 0, proc.stderr
    assert len(doc["userStories"]) == 2


def test_require_symbols_merges_declared_stories(tmp_path):
    stage(tmp_path, {"01-a.json": story("A", {}), "02-b.json": story("B", {"src/x.ts": {"creates": ["f"]}})})
    proc, doc = merge(tmp_path, ["--require-symbols"])
    assert proc.returncode == 0, proc.stderr
    assert len(doc["userStories"]) == 2


def test_validate_staging_and_the_refusal_read_one_function():
    def calls(name):
        tree = ast.parse(open(SM.__file__, encoding="utf-8").read())
        func = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == name)
        return {
            n.func.id
            for n in ast.walk(func)
            if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)
        }

    assert "symbol_declaration_missing_findings" in calls("validate_staging")
    assert "symbol_declaration_missing_findings" in calls("symbol_declaration_refusal_lines")


# ---------------------------------------------------------------------------
# story-merge --outline: the advisory symbol-produces smell
# ---------------------------------------------------------------------------


def one_story_merge(tmp_path, symbols, produces, extra=None, with_outline=True):
    stage(
        tmp_path,
        {"01-a.json": story("A", symbols)},
        outline=[outline_entry("01", produces)],
    )
    args = ["--outline", ".aimi/outline.json"] if with_outline else []
    return merge(tmp_path, args + (extra or []))


def test_a_created_symbol_the_outline_never_names_is_unproduced(tmp_path):
    proc, doc = one_story_merge(
        tmp_path,
        {"src/x.ts": {"creates": ["parse", "helper"]}},
        ["sym:parse"],
    )
    assert proc.returncode == 0, proc.stderr
    (entry,) = smells(doc)
    assert entry["storyId"] == "US-001"
    assert entry["unproduced"] == ["helper"]
    assert entry["uncreated"] == []
    assert entry["message"]
    assert "symbol-produces smell" in proc.stderr and "helper" in proc.stderr


def test_a_sym_produces_token_nothing_creates_is_uncreated(tmp_path):
    proc, doc = one_story_merge(
        tmp_path,
        {"src/x.ts": {"creates": ["parse"]}},
        ["sym:parse", "sym:render"],
    )
    assert proc.returncode == 0, proc.stderr
    (entry,) = smells(doc)
    assert entry["unproduced"] == []
    assert entry["uncreated"] == ["render"]


def test_a_cli_token_is_matched_by_a_created_name_of_the_same_text(tmp_path):
    proc, doc = one_story_merge(tmp_path, {"src/x.ts": {"creates": ["x"]}}, ["cli:x"])
    assert proc.returncode == 0, proc.stderr
    assert smells(doc) == []


def test_a_cli_token_is_never_uncreated_and_does_not_match_another_name(tmp_path):
    proc, doc = one_story_merge(tmp_path, {"src/x.ts": {"creates": ["y"]}}, ["cli:x"])
    assert proc.returncode == 0, proc.stderr
    (entry,) = smells(doc)
    assert entry["unproduced"] == ["y"]
    assert entry["uncreated"] == []


def test_matching_is_exact_and_case_sensitive(tmp_path):
    proc, doc = one_story_merge(
        tmp_path, {"src/x.ts": {"creates": ["Parse"]}}, ["sym:parse"]
    )
    (entry,) = smells(doc)
    assert entry["unproduced"] == ["Parse"]
    assert entry["uncreated"] == ["parse"]


def test_edits_are_never_created_and_never_unproduced(tmp_path):
    proc, doc = one_story_merge(
        tmp_path,
        {"src/x.ts": {"creates": ["parse"], "edits": ["Foo.bar"]}},
        ["sym:parse"],
    )
    assert smells(doc) == []


def test_nothing_is_recorded_without_outline(tmp_path):
    proc, doc = one_story_merge(
        tmp_path,
        {"src/x.ts": {"creates": ["helper"]}},
        ["sym:other"],
        with_outline=False,
    )
    assert proc.returncode == 0, proc.stderr
    assert smells(doc) == []
    assert "symbol-produces" not in proc.stderr


def test_nothing_is_recorded_for_an_undeclared_story(tmp_path):
    proc, doc = one_story_merge(tmp_path, "__absent__", ["sym:render"])
    assert proc.returncode == 0, proc.stderr
    assert smells(doc) == []


def test_nothing_is_recorded_for_a_malformed_declaration(tmp_path):
    proc, doc = one_story_merge(
        tmp_path, {"src/other.ts": {"creates": ["helper"]}}, ["sym:render"]
    )
    # The rails gate refuses the malformed map first; no smell can have been written.
    assert proc.returncode == 1 and doc is None


def test_an_outline_without_a_matching_entry_records_nothing(tmp_path):
    stage(
        tmp_path,
        {"01-a.json": story("A", {"src/x.ts": {"creates": ["helper"]}})},
        outline=[outline_entry("07", ["sym:other"])],
    )
    proc, doc = merge(tmp_path, ["--outline", ".aimi/outline.json"])
    assert proc.returncode == 0, proc.stderr
    assert smells(doc) == []


def test_the_smell_is_keyed_by_staged_idx_not_by_position(tmp_path):
    # Staged 02 and 05 merge as US-001 and US-002; the outline is read by idx.
    stage(
        tmp_path,
        {
            "02-a.json": story("A", {"src/x.ts": {"creates": ["alpha"]}}),
            "05-b.json": story("B", {"src/x.ts": {"creates": ["beta", "extra"]}}),
        },
        outline=[
            outline_entry("02", ["sym:alpha"]),
            outline_entry("05", ["sym:beta"]),
        ],
    )
    proc, doc = merge(tmp_path, ["--outline", ".aimi/outline.json"])
    assert proc.returncode == 0, proc.stderr
    (entry,) = smells(doc)
    assert entry["storyId"] == "US-002"
    assert entry["unproduced"] == ["extra"]


def test_the_smell_is_not_one_of_the_advisory_story_smells(tmp_path):
    stories = [{"id": "US-001", "title": "A", "implementation": {}}]
    assert all(entry["type"] != "symbol-produces" for entry in SM.advisory_story_smells(stories))


def test_an_escaping_outline_path_is_refused_before_python_starts(tmp_path):
    stage(tmp_path, {"01-a.json": story("A", {})})
    proc, doc = merge(tmp_path, ["--outline", "/tmp/outline.json"])
    assert proc.returncode == 1 and doc is None
    assert "escapes project root" in proc.stderr


def test_an_unreadable_outline_is_refused_and_writes_nothing(tmp_path):
    stage(tmp_path, {"01-a.json": story("A", {})})
    proc, doc = merge(tmp_path, ["--outline", ".aimi/missing.json"])
    assert proc.returncode == 1 and doc is None
    assert "--outline is not readable JSON" in proc.stderr


def test_help_lists_both_flags_under_story_merge():
    proc = subprocess.run(["bash", CLI, "help"], capture_output=True, text=True, timeout=60)
    start = proc.stdout.index("    story-merge --staging-dir")
    block = proc.stdout[start : start + 6000]
    assert "--require-symbols" in block and "--outline <path>" in block
