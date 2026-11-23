"""patch-metadata: merge a few metadata keys into a tasks file without
rewriting the file by hand.

/aimi:plan Phase 4 used to tell the planner to rewrite the whole tasks.json
with the Write tool, which meant re-emitting every story the merge had just
validated. These tests drive the verb through aimi-cli.sh, because the path
confinement and the lock live in the wrapper.
"""

import json
import os
import subprocess

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
CLI = os.path.join(os.path.dirname(HERE), "aimi-cli.sh")

STORY = {"id": "US-001", "title": "A", "status": "pending", "dependsOn": []}


def _doc(**metadata):
    base = {"title": "feat: merged tasks", "branchName": "feat/merged"}
    base.update(metadata)
    return {"schemaVersion": "3.3", "metadata": base, "userStories": [dict(STORY)]}


@pytest.fixture
def project(tmp_path):
    os.makedirs(tmp_path / ".aimi" / "tasks")
    return tmp_path


def _write(project, name, value):
    path = project / ".aimi" / name
    path.write_text(value if isinstance(value, str) else json.dumps(value), encoding="utf-8")
    return ".aimi/" + name


def _patch(project, doc, patch, tasks="tasks/x-tasks.json", patch_arg=None, remove=()):
    tasks_rel = _write(project, tasks, doc)
    args = ["bash", CLI, "patch-metadata", "--tasks-file", tasks_rel]
    if patch_arg is None and patch is not None:
        patch_arg = _write(project, "patch.json", patch)
    if patch_arg is not None:
        args += ["--from", patch_arg]
    for key in remove:
        args += ["--remove", key]
    proc = subprocess.run(args, cwd=str(project), capture_output=True, text=True, timeout=120)
    return proc, (project / tasks_rel).read_text(encoding="utf-8")


def test_each_patch_key_replaces_its_metadata_value_and_stories_are_untouched(project):
    proc, text = _patch(
        project, _doc(), {"title": "feat: Add a thing", "branchName": "feat/add-a-thing", "issues": [3, 7]}
    )
    assert proc.returncode == 0, proc.stderr
    assert json.loads(proc.stdout) == {
        "patched": ["title", "branchName", "issues"], "unchanged": [], "removed": [],
    }
    doc = json.loads(text)
    assert doc["metadata"] == {"title": "feat: Add a thing", "branchName": "feat/add-a-thing", "issues": [3, 7]}
    assert doc["userStories"] == [STORY]
    assert doc["schemaVersion"] == "3.3"


def test_a_nested_value_is_replaced_whole_and_a_null_is_written_as_null(project):
    before = _doc(designBundle={"businessSpec": "a.md", "designSpec": "b.md"})
    proc, text = _patch(project, before, {"designBundle": {"businessSpec": "c.md"}, "planPath": None})
    assert proc.returncode == 0, proc.stderr
    metadata = json.loads(text)["metadata"]
    assert metadata["designBundle"] == {"businessSpec": "c.md"}
    assert "planPath" in metadata and metadata["planPath"] is None


def test_a_patch_that_changes_nothing_writes_nothing(project):
    doc = _doc(baseRef="a" * 40)
    raw = json.dumps(doc)  # one line: any rewrite would re-indent it
    proc, text = _patch(project, raw, {"title": "feat: merged tasks", "baseRef": "a" * 40})
    assert proc.returncode == 0, proc.stderr
    assert json.loads(proc.stdout) == {"patched": [], "unchanged": ["title", "baseRef"], "removed": []}
    assert text == raw


def test_true_and_one_are_different_values(project):
    proc, text = _patch(project, _doc(flag=1), {"flag": True})
    assert proc.returncode == 0, proc.stderr
    assert json.loads(proc.stdout)["patched"] == ["flag"]
    assert json.loads(text)["metadata"]["flag"] is True


@pytest.mark.parametrize("key", ["baseRef", "pluginVersion", "roadmapPath", "phase"])
def test_a_prefilled_key_is_set_when_absent_kept_when_equal_and_refused_when_different(project, key):
    absent, _ = _patch(project, _doc(), {key: "one"})
    assert absent.returncode == 0, absent.stderr
    assert json.loads(absent.stdout)["patched"] == [key]

    equal, _ = _patch(project, _doc(**{key: "one"}), {key: "one"})
    assert equal.returncode == 0, equal.stderr
    assert json.loads(equal.stdout)["unchanged"] == [key]

    raw = json.dumps(_doc(**{key: "one"}))
    different, text = _patch(project, raw, {key: "two", "title": "feat: Other"})
    assert different.returncode == 1
    assert key in different.stderr and "never overwritten" in different.stderr
    assert text == raw  # the title in the same patch was not written either

    removal, text = _patch(project, raw, None, remove=[key])
    assert removal.returncode == 1
    assert key in removal.stderr and "never overwritten" in removal.stderr
    assert text == raw


@pytest.mark.parametrize("branch", ["feat/a b", "-leading", "feat/x;rm", "", 7, None])
def test_a_branch_name_outside_the_pattern_is_refused_before_any_write(project, branch):
    raw = json.dumps(_doc())
    proc, text = _patch(project, raw, {"branchName": branch, "title": "feat: Other"})
    assert proc.returncode == 1
    assert "branchName" in proc.stderr
    assert text == raw


@pytest.mark.parametrize(
    "patch, needle",
    [
        ("{not json", "malformed JSON in patch file"),
        ("[1, 2]", "must hold one JSON object"),
        ('"text"', "must hold one JSON object"),
        ("{}", "holds no key"),
    ],
)
def test_a_patch_that_is_not_a_non_empty_object_is_refused(project, patch, needle):
    raw = json.dumps(_doc())
    proc, text = _patch(project, raw, patch)
    assert proc.returncode == 1
    assert needle in proc.stderr
    assert text == raw


@pytest.mark.parametrize(
    "doc, needle",
    [
        ({"userStories": []}, "no metadata object"),
        ({"metadata": [], "userStories": []}, "no metadata object"),
        ("[]", "exactly one JSON object"),
        (json.dumps(_doc()) + "\n" + json.dumps(_doc()), "exactly one JSON object"),
    ],
)
def test_a_tasks_file_without_one_metadata_object_is_refused(project, doc, needle):
    proc, _ = _patch(project, doc, {"title": "feat: Other"})
    assert proc.returncode == 1
    assert needle in proc.stderr


def test_a_patch_path_outside_the_project_is_refused_before_python_starts(project, tmp_path_factory):
    outside = tmp_path_factory.mktemp("outside") / "patch.json"
    outside.write_text('{"title": "feat: Other"}', encoding="utf-8")
    raw = json.dumps(_doc())
    proc, text = _patch(project, raw, None, patch_arg=str(outside))
    assert proc.returncode == 1
    assert "escapes project root" in proc.stderr
    assert text == raw


def test_a_missing_patch_file_and_a_missing_flag_are_refused(project):
    proc, _ = _patch(project, _doc(), None, patch_arg=".aimi/absent.json")
    assert proc.returncode == 1
    assert "patch file does not exist" in proc.stderr

    bare = subprocess.run(
        ["bash", CLI, "patch-metadata", "--from", ".aimi/absent.json"],
        cwd=str(project), capture_output=True, text=True, timeout=120,
    )
    assert bare.returncode == 1
    assert "Usage: aimi-cli.sh patch-metadata" in bare.stderr


def test_remove_deletes_a_key_alone_or_beside_a_patch_and_an_absent_key_is_not_an_error(project):
    doc = _doc(usageSurfaces=[{"kind": "web", "stories": ["US-001"], "url": "/"}])
    proc, text = _patch(project, doc, None, remove=["usageSurfaces", "neverThere", "usageSurfaces"])
    assert proc.returncode == 0, proc.stderr
    assert json.loads(proc.stdout) == {"patched": [], "unchanged": [], "removed": ["usageSurfaces"]}
    assert "usageSurfaces" not in json.loads(text)["metadata"]

    proc, text = _patch(project, doc, {"title": "feat: Other"}, remove=["usageSurfaces"])
    assert proc.returncode == 0, proc.stderr
    assert json.loads(proc.stdout) == {"patched": ["title"], "unchanged": [], "removed": ["usageSurfaces"]}
    assert json.loads(text)["metadata"] == {"title": "feat: Other", "branchName": "feat/merged"}


def test_removing_only_absent_keys_writes_nothing(project):
    raw = json.dumps(_doc())
    proc, text = _patch(project, raw, None, remove=["usageSurfaces"])
    assert proc.returncode == 0, proc.stderr
    assert json.loads(proc.stdout)["removed"] == []
    assert text == raw


def test_a_key_both_patched_and_removed_is_refused(project):
    raw = json.dumps(_doc())
    proc, text = _patch(project, raw, {"issues": [1]}, remove=["issues"])
    assert proc.returncode == 1
    assert "both patched and removed" in proc.stderr
    assert text == raw


def test_neither_a_patch_nor_a_removal_is_a_usage_error(project):
    proc, _ = _patch(project, _doc(), None)
    assert proc.returncode == 1
    assert "Usage: aimi-cli.sh patch-metadata" in proc.stderr
