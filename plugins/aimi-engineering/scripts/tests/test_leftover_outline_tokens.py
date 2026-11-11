"""An `outline:` reference that survives into a tasks file (GitHub issue #183).

`outline:NN` is a staging-only reference: story-merge rewrites it to US-NNN. Two
checks keep one from reaching an executor. validate-staging reports the forms the
merge's remap leaves as text (`outline:7`, `outline:007`) while the expander can
still be re-spawned, and rule R26 of validate-tasks refuses any `outline:` plus
digits left in a story, whatever wrote it. The merge-side half, the remap now
covering title, description and verification.expect, is in test_story_merge.py.
"""

import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import story_merge as SM  # noqa: E402
import tasks as T  # noqa: E402

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(SCRIPTS, "aimi-cli.sh")


def _story(**fields):
    story = {
        "title": "Story",
        "description": "As a user, I want it.",
        "acceptanceCriteria": ["Typecheck passes"],
        "priority": 1,
        "status": "pending",
        "dependsOn": [],
        "notes": "",
        "implementation": {"files": ["src/x.ts"], "approach": "Implement it", "verify": "tsc --noEmit"},
    }
    story.update(fields)
    return story


# --- validate-staging -------------------------------------------------------


def test_staging_reports_one_digit_and_three_digit_tokens_per_field():
    story = _story(
        notes="see outline:7, then outline:007 and outline:7 again",
        tasks=["wire outline:7"],
    )
    findings = SM.malformed_outline_token_findings(story)
    assert len(findings) == 3, findings
    assert findings[0].startswith("notes: outline:7 is not an outline reference")
    assert findings[1].startswith("notes: outline:007 ")
    assert findings[2].startswith("tasks: outline:7 ")


def test_staging_accepts_two_digit_tokens_and_the_decision_anchor():
    story = _story(notes="after outline:02, decided as outline:edit:03", dependsOn=["outline:01"])
    assert SM.malformed_outline_token_findings(story) == []


def test_staging_reads_dependsOn_and_skips_working_keys():
    story = _story(dependsOn=["outline:1"])
    story["_stagedIdx"] = "outline:9"
    story["referenceInventory"] = ["outline:9"]
    findings = SM.malformed_outline_token_findings(story)
    assert findings == [
        "dependsOn: outline:1 is not an outline reference; write outline:NN"
        " with the two-digit idx of the staged file it names"
    ]


def test_validate_staging_cli_keys_the_finding_by_staged_idx(tmp_path):
    directory = os.path.join(str(tmp_path), ".aimi", "stg")
    os.makedirs(directory)
    for name, story in (
        ("01-a.json", _story(notes="built on outline:2")),
        ("02-b.json", _story(notes="built on outline:01")),
    ):
        with open(os.path.join(directory, name), "w", encoding="utf-8") as handle:
            json.dump(story, handle)
    proc = subprocess.run(
        ["bash", CLI, "validate-staging", "--staging-dir", ".aimi/stg"],
        cwd=str(tmp_path), capture_output=True, text=True, timeout=120,
    )
    assert proc.returncode == 1, proc.stderr
    report = json.loads(proc.stdout)
    assert list(report) == ["01"]
    assert report["01"] == [
        "notes: outline:2 is not an outline reference; write outline:NN"
        " with the two-digit idx of the staged file it names"
    ]


# --- validate-tasks R26 -------------------------------------------------------


def test_the_shared_walk_yields_field_and_token_in_order_and_honours_skip():
    story = {
        "id": "US-001",
        "notes": "see outline:03 and outline:03 and outline:edit:02",
        "implementation": {"approach": "after outline:7"},
        "gate": {"options": ["outline:04", "no"]},
        "dependsOn": ["outline:05"],
        "_stagedIdx": "outline:09",
    }
    assert list(SM.outline_tokens_in(story)) == [
        ("notes", "outline:03"),
        ("notes", "outline:03"),
        ("implementation.approach", "outline:7"),
        ("gate.options", "outline:04"),
        ("dependsOn", "outline:05"),
    ]
    assert ("dependsOn", "outline:05") not in list(SM.outline_tokens_in(story, skip=("dependsOn",)))


def test_tasks_r26_uses_the_shared_walk():
    assert T.outline_tokens_in is SM.outline_tokens_in


def _validate_tasks(tmp_path, stories):
    root = os.path.join(os.path.realpath(str(tmp_path)), "proj")
    tasks_dir = os.path.join(root, ".aimi", "tasks")
    os.makedirs(tasks_dir)
    document = {
        "schemaVersion": "3.3",
        "metadata": {"branchName": "fix/outline", "maxConcurrency": 1},
        "userStories": stories,
    }
    with open(os.path.join(tasks_dir, "2020-01-01-outline-tasks.json"), "w", encoding="utf-8") as handle:
        handle.write(json.dumps(document) + "\n")
    proc = subprocess.run(
        ["bash", CLI, "validate-tasks"], cwd=root, capture_output=True, text=True, timeout=120
    )
    return proc.returncode, proc.stdout, proc.stderr


def _task(number, **fields):
    story = {
        "id": "US-%03d" % number,
        "title": "Story %d" % number,
        "description": "As a user, I want %d." % number,
        "acceptanceCriteria": ["um criterio sem ancora nenhuma"],
        "status": "pending",
        "priority": number,
        "dependsOn": [],
        "wave": 0,
    }
    story.update(fields)
    return story


def test_r26_a_leftover_token_in_notes_is_an_error_naming_story_field_and_token(tmp_path):
    code, out, err = _validate_tasks(
        tmp_path, [_task(1), _task(2, notes="[audit-deferred: resolved at plan review] see outline:01, outline:01")]
    )
    assert code == 1, err
    verdict = json.loads(out)
    assert verdict["valid"] is False
    assert len(verdict["errors"]) == 1
    error = verdict["errors"][0]
    assert error.endswith(
        ": US-002: notes still carries outline:01, a staging reference story-merge did not"
        " resolve; replace it with the US-NNN id of the story it names"
    )


def test_r26_is_silent_for_story_ids_and_the_decision_anchor(tmp_path):
    code, out, err = _validate_tasks(
        tmp_path, [_task(1), _task(2, notes="after US-001, decided as outline:edit:02")]
    )
    verdict = json.loads(out)
    assert not [e for e in verdict["errors"] if "outline:" in e], verdict
