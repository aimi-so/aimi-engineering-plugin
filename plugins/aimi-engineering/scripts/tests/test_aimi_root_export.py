"""AIMI_ROOT is exported to every story verify, in the executor and in plan-time probes.

A story verify that reads "$AIMI_ROOT/.aimi/..." must resolve the directory
holding `.aimi/` the same way in a pre-run, a post-change run, a `verify-probe`
run and a `probe-plan` run. The executor exports the value /aimi:execute handed
it; the two probes export the root `aimi-cli.sh` resolved. These cases cover the
Python half (`probe_verify`'s `aimi_root`), both CLI verbs run from a nested
directory with no `.aimi/` of its own, and the structural presence of the field
in the two `<task_pointer>` templates and in execute.md's spawn fields.
"""

import json
import os
import re
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
PLUGIN = os.path.dirname(SCRIPTS)
sys.path.insert(0, SCRIPTS)

import tasks as T  # noqa: E402

CLI = os.path.join(SCRIPTS, "aimi-cli.sh")
SKILL = os.path.join(PLUGIN, "skills", "story-executor", "SKILL.md")
EXECUTE = os.path.join(PLUGIN, "commands", "execute.md")

ROOT_SEGMENT = 'test -d "$AIMI_ROOT/.aimi"'


@pytest.fixture(autouse=True)
def _no_probe_marker(monkeypatch):
    # This module is itself a segment of US-007's verify, which the executor
    # runs inside a verify-probe; inherited, the marker would make every case
    # here read as a nested call.
    monkeypatch.delenv(T.VERIFY_PROBE_ACTIVE_ENV, raising=False)


def _root(tmp_path):
    root = os.path.join(os.path.realpath(str(tmp_path)), "outer")
    os.makedirs(os.path.join(root, ".aimi", "tasks"))
    return root


# ---------------------------------------------------------------------------
# probe_verify
# ---------------------------------------------------------------------------


def test_segment_passes_only_with_the_value_exported(tmp_path, monkeypatch):
    monkeypatch.delenv(T.AIMI_ROOT_ENV, raising=False)
    root = _root(tmp_path)
    nested = os.path.join(root, "sub")
    os.makedirs(nested)
    (entry,) = T.probe_verify(ROOT_SEGMENT, nested, aimi_root=root)
    assert entry["exit"] == 0 and entry["discriminates"] is False
    # the same segment, same directory, with a root that has no .aimi/
    (entry,) = T.probe_verify(ROOT_SEGMENT, nested, aimi_root=nested)
    assert entry["exit"] != 0 and entry["discriminates"] is True


def test_a_missing_value_is_reported_as_unresolved_state(tmp_path, monkeypatch):
    monkeypatch.delenv(T.AIMI_ROOT_ENV, raising=False)
    root = _root(tmp_path)
    (entry,) = T.probe_verify(ROOT_SEGMENT, root)
    assert entry["discriminates"] is None and entry["exit"] is None
    assert T.AIMI_ROOT_ENV in entry["unresolvedState"]


def test_a_stale_caller_value_is_overwritten(tmp_path, monkeypatch):
    root = _root(tmp_path)
    monkeypatch.setenv(T.AIMI_ROOT_ENV, os.path.join(root, "does-not-exist"))
    (entry,) = T.probe_verify(ROOT_SEGMENT, root, aimi_root=root)
    assert entry["exit"] == 0


def test_the_environment_is_restored_afterwards(tmp_path, monkeypatch):
    root = _root(tmp_path)
    monkeypatch.delenv(T.AIMI_ROOT_ENV, raising=False)
    T.probe_verify(ROOT_SEGMENT, root, aimi_root=root)
    assert T.AIMI_ROOT_ENV not in os.environ
    monkeypatch.setenv(T.AIMI_ROOT_ENV, "/prior/value")
    T.probe_verify(ROOT_SEGMENT, root, aimi_root=root)
    assert os.environ[T.AIMI_ROOT_ENV] == "/prior/value"
    assert T.VERIFY_PROBE_ACTIVE_ENV not in os.environ


def test_with_no_root_given_the_callers_environment_is_what_a_segment_sees(tmp_path, monkeypatch):
    root = _root(tmp_path)
    monkeypatch.setenv(T.AIMI_ROOT_ENV, root)
    (entry,) = T.probe_verify(ROOT_SEGMENT, root)
    assert entry["exit"] == 0
    assert os.environ[T.AIMI_ROOT_ENV] == root


@pytest.mark.parametrize("verb", ["verify-probe", "probe-plan"])
def test_a_non_absolute_root_is_refused(verb, capsys):
    op = T.op_verify_probe if verb == "verify-probe" else T.op_probe_plan
    with pytest.raises(SystemExit) as raised:
        op(["--tasks-file", "x.json", "--story-id", "US-001", "--aimi-root", "relative/dir"])
    assert raised.value.code not in (0, None)
    assert "--aimi-root must be an absolute path" in capsys.readouterr().err


# ---------------------------------------------------------------------------
# the CLI verbs, run from a nested directory with no .aimi/ of its own
# ---------------------------------------------------------------------------


def _env(base):
    env = dict(os.environ)
    for name in ("AIMI_PLUGIN_DIR", "CLAUDECODE", "AIMI_ROOT", T.VERIFY_PROBE_ACTIVE_ENV):
        env.pop(name, None)
    env["HOME"] = base
    env["AIMI_CONFIG_DIR"] = os.path.join(base, "cfg")
    env["XDG_CONFIG_HOME"] = os.path.join(base, ".config")
    env["CLAUDE_CONFIG_DIR"] = os.path.join(base, ".claude")
    return env


def _git(cwd, *args):
    env = dict(os.environ)
    for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
        env.pop(name, None)
    return subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@example.com",
         "-c", "commit.gpgsign=false"] + list(args),
        cwd=cwd, env=env, capture_output=True, text=True, check=True,
    ).stdout.strip()


def _write_tasks(root, verify, extra_story=None, base_ref=None):
    story = {
        "id": "US-001", "title": "s", "description": "d", "acceptanceCriteria": ["x"],
        "priority": 1, "status": "pending", "dependsOn": [],
        "implementation": {"verify": verify},
    }
    story.update(extra_story or {})
    meta = {"title": "t", "branchName": "b"}
    if base_ref:
        meta["baseRef"] = base_ref
    path = os.path.join(root, ".aimi", "tasks", "p-tasks.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump({"schemaVersion": "3.3", "metadata": meta, "userStories": [story]}, handle)
    return path


def test_verify_probe_from_a_nested_directory_hands_the_outer_root_to_a_segment(tmp_path):
    root = _root(tmp_path)
    nested = os.path.join(root, "deep", "er")
    os.makedirs(nested)
    tasks_file = _write_tasks(root, ROOT_SEGMENT + "\ntest \"$AIMI_ROOT\" = '%s'\n" % root)
    proc = subprocess.run(
        ["bash", CLI, "verify-probe", "US-001", "--tasks-file", tasks_file],
        cwd=nested, env=_env(os.path.dirname(root)), capture_output=True, text=True, timeout=120,
    )
    assert proc.returncode == 0, proc.stderr
    entries = json.loads(proc.stdout)
    assert len(entries) == 2
    # exit 0 and not None: the value arrived and was not reported as missing state
    assert [e["exit"] for e in entries] == [0, 0]
    assert [e["discriminates"] for e in entries] == [False, False]


def test_probe_plan_from_a_nested_directory_hands_the_outer_root_to_a_segment(tmp_path):
    root = _root(tmp_path)
    nested = os.path.join(root, "pkg")
    os.makedirs(nested)
    with open(os.path.join(nested, "keep.txt"), "w", encoding="utf-8") as handle:
        handle.write("x\n")
    _git(root, "init", "-q")
    _git(root, "add", "pkg/keep.txt")
    _git(root, "commit", "-q", "-m", "first")
    base = _git(root, "rev-parse", "HEAD")
    tasks_file = _write_tasks(root, ROOT_SEGMENT, base_ref=base)
    proc = subprocess.run(
        ["bash", CLI, "probe-plan", "--tasks-file", tasks_file],
        cwd=nested, env=_env(os.path.dirname(root)), capture_output=True, text=True, timeout=120,
    )
    assert proc.returncode == 0, proc.stderr
    out = json.loads(proc.stdout)
    assert out["probed"] is True, out
    (entry,) = out["stories"][0]["segments"]
    # the throwaway base tree has no .aimi/, so only the exported root passes it
    assert entry["exit"] == 0 and entry["discriminates"] is False


def test_probe_plan_in_a_multi_repo_group_hands_the_outer_root_to_a_segment(tmp_path):
    parent = os.path.join(os.path.realpath(str(tmp_path)), "multi")
    os.makedirs(os.path.join(parent, ".aimi", "tasks"))
    child = os.path.join(parent, "a")
    os.makedirs(child)
    with open(os.path.join(child, "README"), "w", encoding="utf-8") as handle:
        handle.write("a\n")
    _git(child, "init", "-q")
    _git(child, "add", "README")
    _git(child, "commit", "-q", "-m", "first")
    base = _git(child, "rev-parse", "HEAD")
    tasks_file = _write_tasks(parent, ROOT_SEGMENT, extra_story={"project": "a"}, base_ref=base)
    nested = os.path.join(parent, "scratch")
    os.makedirs(nested)
    env = _env(os.path.dirname(parent))
    env["GIT_CEILING_DIRECTORIES"] = os.path.dirname(parent)
    proc = subprocess.run(
        ["bash", CLI, "probe-plan", "--tasks-file", tasks_file],
        cwd=nested, env=env, capture_output=True, text=True, timeout=120,
    )
    assert proc.returncode == 0, proc.stderr
    out = json.loads(proc.stdout)
    assert out["probed"] is True, out
    (entry,) = out["stories"][0]["segments"]
    assert entry["exit"] == 0 and entry["discriminates"] is False


# ---------------------------------------------------------------------------
# structural: the templates and the spawn fields carry the field
# ---------------------------------------------------------------------------


def _read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def _task_pointers(text):
    return re.findall(r"<task_pointer>(.*?)</task_pointer>", text, flags=re.S)


def test_both_task_pointer_templates_carry_the_aimi_root_line_beside_tasks_file_path():
    pointers = _task_pointers(_read(SKILL))
    assert len(pointers) == 2
    for block in pointers:
        assert re.search(
            r"TASKS_FILE_PATH: \[TASKS_FILE_PATH\]\nAIMI_ROOT: \[AIMI_ROOT\]\n", block
        ), block[:300]


def test_the_skill_names_aimi_root_in_both_verify_exports_and_keeps_the_boundary_rule():
    text = _read(SKILL)
    assert text.count("`TASKS_FILE_PATH` and `AIMI_ROOT`") >= 4
    assert "Never use `../` traversal to escape the project boundary" in text
    assert "implementation.outputs" in text
    assert "never stage or commit it" in text


def test_execute_spawn_fields_list_aimi_root_directly_after_tasks_file_path():
    text = _read(EXECUTE)
    start = text.index("- TASKS_FILE_PATH = WAVE_TASKS_FILE")
    scratch = text.index("- SCRATCH_PREFIX = PLAN_DISC", start)
    window = text[start:scratch]
    assert "- AIMI_ROOT = " in window
    assert "never re-derived inside a worktree" in window
    assert text.count("- AIMI_ROOT = ") == 1
