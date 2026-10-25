"""Tests for the guard-rail and path findings in validate-staging and story-merge.

Two rules live in tasks.py (guard_rail_findings, implementation_path_findings)
and are judged nowhere else. This module pins the two places story_merge.py
applies them: `validate-staging`, which feeds the expander's retry loop with a
report keyed by staged idx, and the `story-merge` refusal, which stops an audit
patch from reintroducing the shape after that check ran.

Both verbs are driven through the real aimi-cli.sh in a throwaway project under
pytest's tmp_path, without importing helpers from test_story_merge.py. The
golden file is read here and never written; the counter test is the measured
statement that no recorded staged story is newly refused.
"""

import ast
import json
import os
import subprocess
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import story_merge as SM  # noqa: E402
import tasks as T  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
CLI = os.path.join(SCRIPTS, "aimi-cli.sh")
GOLDEN_PATH = os.path.join(HERE, "golden_from_jq.json")

# Issue 169: a guard rail naming one line inside a function body of the verify.
FUNCTION_VERIFY = (
    "set -e\n"
    "M=/tmp/x\n"
    "file_ok() {\n"
    '  test -f "$M/$1"\n'
    '  grep -q ok "$M/$1"\n'
    "}\n"
    "file_ok a"
)
INNER_LINE = '  grep -q ok "$M/$1"'
# Issue 168: a files entry that leaves the repository.
ESCAPING_FILE = "../.aimi/research/x.md"
SWALLOWING_VERIFY = "true\nfalse\ntrue\n"


def story(title, verify="tsc --noEmit", files=None, rails=None, outputs=None, deps=None):
    implementation = {
        "files": ["src/x.ts"] if files is None else files,
        "approach": "Implement it",
        "verify": verify,
    }
    if rails is not None:
        implementation["guardRails"] = rails
    if outputs is not None:
        implementation["outputs"] = outputs
    return {
        "title": title,
        "description": "As a user, I want " + title + " so that it works.",
        "acceptanceCriteria": ["Typecheck passes"],
        "priority": 1,
        "status": "pending",
        "dependsOn": list(deps or []),
        "notes": "",
        "implementation": implementation,
    }


def audit_sidecar(files):
    idx = sorted(
        n[:2]
        for n in files
        if len(n) > 3 and n[:2].isdigit() and n[2] == "-" and not n.endswith("-outline.json")
    )
    return {"patches": [], "unresolved": [], "auditedIdx": idx}


def stage(tmp_path, files, audit=False):
    files = dict(files)
    if audit and len(files) >= 2 and "audit-result.json" not in files:
        files["audit-result.json"] = audit_sidecar(files)
    directory = os.path.join(str(tmp_path), ".aimi", "stg")
    os.makedirs(directory, exist_ok=True)
    os.makedirs(os.path.join(str(tmp_path), ".aimi", "tasks"), exist_ok=True)
    for name, value in files.items():
        with open(os.path.join(directory, name), "w", encoding="utf-8") as handle:
            handle.write(value if isinstance(value, str) else json.dumps(value))
    return directory


def run(tmp_path, verb, args):
    return subprocess.run(
        ["bash", CLI, verb] + args,
        cwd=str(tmp_path),
        capture_output=True,
        text=True,
        timeout=120,
    )


def validate_staging(tmp_path, extra=None):
    return run(tmp_path, "validate-staging", ["--staging-dir", ".aimi/stg"] + (extra or []))


def merge(tmp_path, extra=None):
    return run(
        tmp_path,
        "story-merge",
        ["--staging-dir", ".aimi/stg", "--output", ".aimi/tasks/out-tasks.json"] + (extra or []),
    )


def snapshot(directory):
    out = {}
    for root, _, names in os.walk(directory):
        for name in names:
            path = os.path.join(root, name)
            with open(path, "rb") as handle:
                out[os.path.relpath(path, directory)] = handle.read()
    return out


# ---------------------------------------------------------------------------
# validate-staging
# ---------------------------------------------------------------------------


def test_validate_staging_reports_the_issue_169_rail_by_idx(tmp_path):
    stage(tmp_path, {"01-a.json": story("A", FUNCTION_VERIFY, rails=[INNER_LINE])})
    proc = validate_staging(tmp_path)
    assert proc.returncode == 1, proc.stderr
    report = json.loads(proc.stdout)
    assert list(report) == ["01"]
    assert len(report["01"]) == 1
    finding = report["01"][0]
    assert "implementation.guardRails[0]" in finding
    assert "List the whole function definition as the rail, or its top-level call line" in finding


def test_validate_staging_reports_the_issue_168_path_by_idx(tmp_path):
    stage(tmp_path, {"01-a.json": story("A", files=[ESCAPING_FILE])})
    proc = validate_staging(tmp_path)
    assert proc.returncode == 1, proc.stderr
    report = json.loads(proc.stdout)
    assert list(report) == ["01"]
    finding = report["01"][0]
    assert "implementation.files[0]" in finding
    assert "implementation.outputs" in finding


def test_validate_staging_reports_both_repros_each_under_its_own_idx(tmp_path):
    stage(
        tmp_path,
        {
            "01-a.json": story("A", FUNCTION_VERIFY, rails=[INNER_LINE]),
            "02-b.json": story("B", files=[ESCAPING_FILE]),
            "03-c.json": story("C"),
        },
    )
    proc = validate_staging(tmp_path)
    assert proc.returncode == 1, proc.stderr
    assert sorted(json.loads(proc.stdout)) == ["01", "02"]


def test_validate_staging_is_clean_for_stories_with_whole_segment_rails_and_good_paths(tmp_path):
    stage(
        tmp_path,
        {
            "01-a.json": story(
                "A", FUNCTION_VERIFY, files=["src/a.ts"], rails=["file_ok a"],
                outputs=[".aimi/research/x.md"],
            ),
            "02-b.json": story("B"),
            "outline.json": [],
        },
    )
    proc = validate_staging(tmp_path)
    assert proc.returncode == 0, proc.stderr
    assert json.loads(proc.stdout) == {}


def test_validate_staging_still_skips_an_unreadable_staged_file(tmp_path):
    stage(
        tmp_path,
        {"01-a.json": "{not json", "02-b.json": story("B", files=[ESCAPING_FILE])},
    )
    proc = validate_staging(tmp_path)
    assert proc.returncode == 1, proc.stderr
    assert list(json.loads(proc.stdout)) == ["02"]


def test_findings_within_one_idx_are_ordered_verify_rail_path_edge(tmp_path):
    verify = "M=/tmp/x\nf() {\n  false\n  grep -q ok x\n}\nf\ntrue\n"
    bad = story(
        "B", verify, files=[ESCAPING_FILE], rails=["  grep -q ok x"], deps=[]
    )
    outline = [
        {"idx": "01", "title": "A", "summary": "s", "produces": ["sym:foo"]},
        {"idx": "02", "title": "B", "summary": "s", "consumes": ["sym:foo"]},
    ]
    stage(tmp_path, {"01-a.json": story("A"), "02-b.json": bad, "outline.json": outline})
    proc = validate_staging(tmp_path, ["--outline", ".aimi/stg/outline.json"])
    assert proc.returncode == 1, proc.stderr
    findings = json.loads(proc.stdout)["02"]
    assert len(findings) == 4, findings
    assert "swallow a failing line" in findings[0]
    assert "implementation.guardRails[0]" in findings[1]
    assert "implementation.files[0]" in findings[2]
    assert "outline:01" in findings[3]


def test_findings_never_carry_a_backtick_or_a_dollar_open_paren(tmp_path):
    inner = "  echo `date` $(id) done"
    verify = "set -e\nf() {\n" + inner + "\n  true\n}\nf"
    hostile = story(
        "A", verify, files=["../`x`$(id).md"], rails=[inner.strip()]
    )
    findings = SM.rail_and_path_findings(hostile)
    assert len(findings) == 2
    for finding in findings:
        assert "`" not in finding and "$(" not in finding
        assert len(finding) <= SM._FINDING_MAXLEN
    stage(tmp_path, {"01-a.json": hostile})
    proc = validate_staging(tmp_path)
    assert proc.returncode == 1
    assert "`" not in proc.stdout and "$(" not in proc.stdout


def test_a_long_finding_is_cut_at_the_finding_cap():
    long_file = "../" + "a" * 900 + ".md"
    findings = SM.rail_and_path_findings(story("A", files=[long_file]))
    assert findings and all(len(f) <= SM._FINDING_MAXLEN for f in findings)


# ---------------------------------------------------------------------------
# story-merge
# ---------------------------------------------------------------------------

REFUSING_SHAPES = {
    "rail": lambda: story("B", FUNCTION_VERIFY, rails=[INNER_LINE]),
    "escaping-file": lambda: story("B", files=[ESCAPING_FILE]),
    "absolute-file": lambda: story("B", files=["/etc/passwd"]),
    "whitespace-file": lambda: story("B", files=["src/a b.ts"]),
    "dot-segment-file": lambda: story("B", files=["src/./a.ts"]),
    "malformed-outputs": lambda: story("B", outputs=["not-under-aimi.md"]),
}


@pytest.mark.parametrize("shape", sorted(REFUSING_SHAPES))
def test_merge_refuses_each_shape_naming_story_idx_and_field(tmp_path, shape):
    stage(
        tmp_path,
        {"01-a.json": story("A"), "02-b.json": REFUSING_SHAPES[shape]()},
        audit=True,
    )
    before = snapshot(os.path.join(str(tmp_path), ".aimi", "stg"))
    proc = merge(tmp_path)
    assert proc.returncode == 1, proc.stderr
    lines = proc.stderr.splitlines()
    assert lines[0].startswith("Error: story-merge:"), proc.stderr
    assert len(lines) >= 2
    detail = lines[1:]
    assert all("Story US-002 (staged 02):" in line for line in detail), proc.stderr
    assert "US-001" not in proc.stderr
    assert any("implementation." in line for line in detail)
    assert not os.path.exists(os.path.join(str(tmp_path), ".aimi", "tasks", "out-tasks.json"))
    assert snapshot(os.path.join(str(tmp_path), ".aimi", "stg")) == before


def test_merge_emits_one_line_per_finding(tmp_path):
    bad = story("B", FUNCTION_VERIFY, files=[ESCAPING_FILE], rails=[INNER_LINE])
    stage(tmp_path, {"01-a.json": story("A"), "02-b.json": bad}, audit=True)
    proc = merge(tmp_path)
    assert proc.returncode == 1
    lines = proc.stderr.splitlines()
    assert len(lines) == 3
    assert "implementation.guardRails[0]" in lines[1]
    assert "implementation.files[0]" in lines[2]


def test_merge_stderr_is_identical_with_and_without_agent_mode(tmp_path):
    stage(tmp_path, {"01-a.json": story("A", files=[ESCAPING_FILE])})
    plain = merge(tmp_path)
    agent = merge(tmp_path, ["--agent-mode"])
    assert plain.returncode == 1 and agent.returncode == 1
    assert plain.stderr == agent.stderr
    assert "US-001" in agent.stderr
    assert not os.path.exists(os.path.join(str(tmp_path), ".aimi", "tasks", "out-tasks.json"))


def test_merge_leaves_clean_stories_merging_as_before(tmp_path):
    stage(
        tmp_path,
        {
            "01-a.json": story("A", FUNCTION_VERIFY, rails=["file_ok a"]),
            "02-b.json": story("B", outputs=[".aimi/research/x.md"]),
        },
        audit=True,
    )
    proc = merge(tmp_path)
    assert proc.returncode == 0, proc.stderr
    with open(os.path.join(str(tmp_path), ".aimi", "tasks", "out-tasks.json"), encoding="utf-8") as h:
        doc = json.load(h)
    assert [s["id"] for s in doc["userStories"]] == ["US-001", "US-002"]


def test_the_verify_refusal_still_comes_first_and_keeps_its_message(tmp_path):
    both = story("A", SWALLOWING_VERIFY, files=[ESCAPING_FILE])
    stage(tmp_path, {"01-a.json": both})
    proc = merge(tmp_path)
    assert proc.returncode == 1
    first = proc.stderr.splitlines()[0]
    assert first == (
        "Error: story-merge: implementation.verify would swallow a failing line"
        " (start it with set -e or chain its lines with &&):"
    )
    assert "implementation.files" not in proc.stderr


def test_the_refusal_reads_staged_input_only_so_a_tasks_file_on_disk_is_untouched(tmp_path):
    existing = story("Old", files=[ESCAPING_FILE])
    existing["id"] = "US-001"
    on_disk = os.path.join(str(tmp_path), ".aimi", "tasks")
    os.makedirs(on_disk, exist_ok=True)
    path = os.path.join(on_disk, "old-tasks.json")
    text = json.dumps({"schemaVersion": "3.3", "userStories": [existing]})
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    stage(tmp_path, {"01-a.json": story("A")})
    proc = merge(tmp_path)
    assert proc.returncode == 0, proc.stderr
    with open(path, encoding="utf-8") as handle:
        assert handle.read() == text


# ---------------------------------------------------------------------------
# The two rules are not restated, and the import is lazy
# ---------------------------------------------------------------------------


def test_the_helper_imports_tasks_lazily_and_restates_no_rule():
    with open(os.path.join(SCRIPTS, "story_merge.py"), encoding="utf-8") as handle:
        source = handle.read()
    tree = ast.parse(source)
    top_level = [
        node.module for node in tree.body if isinstance(node, ast.ImportFrom) and node.module
    ]
    assert "tasks" not in top_level
    func = next(
        node
        for node in tree.body
        if isinstance(node, ast.FunctionDef) and node.name == "rail_and_path_findings"
    )
    imported = [
        alias.name
        for node in ast.walk(func)
        if isinstance(node, ast.ImportFrom) and node.module == "tasks"
        for alias in node.names
    ]
    assert sorted(imported) == ["guard_rail_findings", "implementation_path_findings"]
    for restated in ("PATH_REASON_", "_GUARD_RAIL_REMEDY", "FILES_ESCAPE_REMEDY"):
        assert restated not in source


def test_validate_staging_and_the_refusal_read_one_helper():
    with open(os.path.join(SCRIPTS, "story_merge.py"), encoding="utf-8") as handle:
        tree = ast.parse(handle.read())

    def calls(name):
        func = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == name)
        return {
            n.func.id for n in ast.walk(func) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)
        }

    assert "rail_and_path_findings" in calls("validate_staging")
    assert "rail_and_path_findings" in calls("rail_and_path_refusal_lines")
    assert "verify_refusal_lines" in calls("main")
    assert "rail_and_path_refusal_lines" in calls("main")


def test_the_new_builder_leaves_verify_refusal_lines_alone():
    out = SM.verify_refusal_lines(
        [dict(story("A", SWALLOWING_VERIFY), id="US-001", _stagedIdx="01")]
    )
    assert len(out) == 1
    assert out[0].startswith("  Story US-001 (staged 01): implementation.verify ")


# ---------------------------------------------------------------------------
# The golden corpus is not newly refused
# ---------------------------------------------------------------------------


def _staged_entries():
    with open(GOLDEN_PATH, encoding="utf-8") as handle:
        golden = json.load(handle)
    entries = []
    for case in golden["story_merge_cases"]:
        for name, content in (case["input"] or {}).items():
            if not name.endswith(".json") or name.endswith("outline.json"):
                continue
            try:
                value = json.loads(content)
            except ValueError:
                continue
            for entry in value if isinstance(value, list) else [value]:
                if isinstance(entry, dict):
                    entries.append(entry)
    return entries


def _count_flagged(entries):
    rails = refused = 0
    for entry in entries:
        rails += len(T.guard_rail_findings(entry))
        refused += len(T.implementation_path_findings(entry))
    return rails, refused


def test_no_golden_staged_entry_is_newly_refused():
    entries = _staged_entries()
    assert len(entries) > 100  # a counter over nothing would also read zero
    assert _count_flagged(entries) == (0, 0)


def test_the_golden_counter_detects_a_planted_bad_rail_and_file():
    entries = [json.loads(json.dumps(e)) for e in _staged_entries()]
    planted = 0
    for entry in entries:
        implementation = entry.get("implementation")
        if isinstance(implementation, dict) and isinstance(implementation.get("files"), list):
            implementation["files"].append("../escape.md")
            planted += 1
    assert planted > 0
    entries.append(story("Planted", FUNCTION_VERIFY, rails=[INNER_LINE]))
    rails, refused = _count_flagged(entries)
    assert rails >= 1
    assert refused >= planted
