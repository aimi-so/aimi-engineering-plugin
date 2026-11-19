"""Tests for `audit-open` and the Open Audit Findings step of /aimi:execute.

The verb is run through the tree's own aimi-cli.sh against throwaway `.aimi/`
roots, so flag handling, path confinement and the crossing into tasks.py are
measured together. The wiring cases read the command text the way a run does.
"""

import json
import os
import re
import subprocess
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[1]
CLI = SCRIPTS / "aimi-cli.sh"
COMMANDS = SCRIPTS.parent / "commands"
EXECUTE = COMMANDS / "execute.md"
REFS = COMMANDS / "references" / "execute"
STEP = REFS / "step-1-audit-open.md"

HEADING = "Open Audit Findings"


def _cli(root, *args):
    return subprocess.run(["bash", str(CLI), *args], cwd=root, capture_output=True, text=True,
                          timeout=60, env=dict(os.environ))


def _tasks(root, metadata=None, name="t-tasks.json"):
    path = root / ".aimi" / "tasks" / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"schemaVersion": "3.3", "metadata": metadata or {"branchName": "b"},
                                "userStories": []}), encoding="utf-8")
    return path


@pytest.fixture
def root(tmp_path):
    (tmp_path / ".aimi" / "tasks").mkdir(parents=True)
    return tmp_path


def test_absent_key_answers_count_zero(root):
    path = _tasks(root)
    result = _cli(root, "audit-open", "--tasks-file", str(path))
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == {"count": 0, "findings": []}


def test_two_findings_are_listed_in_order(root):
    findings = [
        {"message": "second story names a missing file", "stories": ["02"]},
        {"message": "drift between the two", "stories": ["01", "_audit"]},
    ]
    path = _tasks(root, {"branchName": "b", "auditOpen": findings})
    result = _cli(root, "audit-open", "--tasks-file", str(path))
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == {"count": 2, "findings": findings}


@pytest.mark.parametrize("value", ["a string", {"message": "m", "stories": ["01"]}, 3])
def test_a_non_array_value_is_refused_naming_the_file(root, value):
    path = _tasks(root, {"branchName": "b", "auditOpen": value})
    result = _cli(root, "audit-open", "--tasks-file", str(path))
    assert result.returncode == 1
    assert str(path) in result.stderr
    assert result.stdout == ""


def test_a_malformed_entry_is_refused_naming_the_file(root):
    path = _tasks(root, {"branchName": "b", "auditOpen": [{"message": "m"}]})
    result = _cli(root, "audit-open", "--tasks-file", str(path))
    assert result.returncode == 1
    assert str(path) in result.stderr


def test_a_tasks_file_outside_the_project_is_refused(root, tmp_path_factory):
    outside = tmp_path_factory.mktemp("outside") / "t-tasks.json"
    outside.write_text(json.dumps({"metadata": {}}), encoding="utf-8")
    result = _cli(root, "audit-open", "--tasks-file", str(outside))
    assert result.returncode != 0
    assert result.stdout == ""


def test_the_document_is_byte_identical_after_a_call(root):
    path = _tasks(root, {"branchName": "b", "auditOpen": [{"message": "m", "stories": ["01"]}]})
    before = path.read_bytes()
    assert _cli(root, "audit-open", "--tasks-file", str(path)).returncode == 0
    assert path.read_bytes() == before


def _router():
    return EXECUTE.read_text(encoding="utf-8")


def _entry():
    text = _router()
    start = text.index("## %s\n" % HEADING)
    end = text.index("\n## ", start + 1)
    return text[start:end]


def test_router_entry_has_applies_when_and_read_lines():
    entry = _entry()
    assert re.search(r"^Applies when: .*\bnot a spawned split task\b", entry, re.M)
    assert ("Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/"
            "step-1-audit-open.md in full.") in entry
    assert STEP.is_file()
    assert _router().index("## %s\n" % HEADING) < _router().index("## Step 0.9: Multi-File Auto-Detection")


def test_both_spawned_tasks_rows_skip_the_entry():
    rows = [line for line in _router().splitlines() if line.startswith("| flat-split-child")
            or line.startswith("| phase-split-sub-orchestrator")]
    assert len(rows) == 2
    for row in rows:
        cells = [c.strip() for c in row.split("|")[1:-1]]
        assert HEADING in cells[3].split("; ")
        assert HEADING not in cells[2].split("; ")


def test_the_two_step_files_point_at_the_entry():
    for name in ("step-1-initialize-session.md", "step-0-9-split-flow.md"):
        assert "**%s**" % HEADING in (REFS / name).read_text(encoding="utf-8"), name


def test_the_step_file_names_the_verb_the_mode_probe_and_the_question():
    text = STEP.read_text(encoding="utf-8")
    assert "audit-open" in text
    assert "detect-interactivity" in text
    assert "AskUserQuestion" in text
    assert "Run anyway" in text and "Stop" in text


def test_nothing_reads_audit_open_with_jq():
    files = [EXECUTE, *sorted(REFS.glob("*.md"))]
    for path in files:
        for line in path.read_text(encoding="utf-8").splitlines():
            assert not ("jq" in line and "auditOpen" in line), "%s: %s" % (path, line)
