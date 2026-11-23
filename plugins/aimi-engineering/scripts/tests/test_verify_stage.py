"""verify-stage-declared: does a project declare stage-aware verification?

The declaration is what lets /aimi:execute keep a project's end-to-end checks
out of parallel worktrees and run them once, after the wave's merge. A typo in
it must be refused, never read as "not declared".
"""

import json
import os
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
CLI = os.path.join(SCRIPTS, "aimi-cli.sh")
sys.path.insert(0, SCRIPTS)

import verify_stage as VS  # noqa: E402


def _config(tmp_path, value):
    os.makedirs(tmp_path / ".aimi", exist_ok=True)
    path = tmp_path / ".aimi" / "config.json"
    path.write_text(value if isinstance(value, str) else json.dumps(value), encoding="utf-8")
    return str(path)


def _cli(tmp_path, *args):
    return subprocess.run(
        ["bash", CLI, "verify-stage-declared", *args],
        cwd=str(tmp_path), capture_output=True, text=True, timeout=60,
    )


def test_absence_at_every_level_answers_false(tmp_path):
    assert VS.load_declaration(str(tmp_path / "absent.json"), ".") is False
    assert VS.load_declaration(_config(tmp_path, {}), ".") is False
    assert VS.load_declaration(_config(tmp_path, {"verifyStage": {}}), ".") is False
    assert VS.load_declaration(_config(tmp_path, {"verifyStage": {"api": True}}), ".") is False


def test_a_declared_project_answers_its_own_value_and_no_other_key_does(tmp_path):
    config = _config(tmp_path, {"verifyStage": {".": True, "web": False}, "bookkeeping": {"x": 1}})
    assert VS.load_declaration(config, ".") is True
    assert VS.load_declaration(config, "web") is False


@pytest.mark.parametrize(
    "doc",
    [
        "{not json",
        "[]",
        {"verifyStage": []},
        {"verifyStage": True},
        {"verifyStage": {".": "true"}},
        {"verifyStage": {".": 1}},
        {"verifyStage": {".": None}},
        {"verifyStage": {".": {"stage": "worktree"}}},
    ],
)
def test_a_malformed_declaration_is_refused_and_never_read_as_undeclared(tmp_path, doc):
    with pytest.raises(VS.VerifyStageError):
        VS.load_declaration(_config(tmp_path, doc), ".")


def test_an_unrelated_projects_malformed_value_does_not_refuse_this_one(tmp_path):
    config = _config(tmp_path, {"verifyStage": {".": True, "web": "yes"}})
    assert VS.load_declaration(config, ".") is True


def test_the_verb_prints_one_json_line_and_defaults_to_the_root_key(tmp_path):
    _config(tmp_path, {"verifyStage": {".": True}})
    bare = _cli(tmp_path)
    assert bare.returncode == 0, bare.stderr
    assert json.loads(bare.stdout) == {"project": ".", "staged": True}
    other = _cli(tmp_path, "--project", "web")
    assert json.loads(other.stdout) == {"project": "web", "staged": False}


def test_the_verb_answers_false_with_no_config_at_all(tmp_path):
    os.makedirs(tmp_path / ".aimi")
    proc = _cli(tmp_path)
    assert proc.returncode == 0, proc.stderr
    assert json.loads(proc.stdout) == {"project": ".", "staged": False}


def test_the_verb_refuses_a_malformed_declaration_with_an_empty_stdout(tmp_path):
    _config(tmp_path, {"verifyStage": {".": "yes"}})
    proc = _cli(tmp_path)
    assert proc.returncode == 1
    assert proc.stdout == ""
    assert "verify-stage-declared" in proc.stderr and "not true or false" in proc.stderr


def test_the_verb_refuses_an_unknown_flag(tmp_path):
    os.makedirs(tmp_path / ".aimi")
    proc = _cli(tmp_path, "--stage", "worktree")
    assert proc.returncode == 1
    assert "Usage: aimi-cli.sh verify-stage-declared" in proc.stderr


def test_the_reader_writes_nothing(tmp_path):
    config = _config(tmp_path, {"verifyStage": {".": True}})
    before = open(config, "rb").read()
    _cli(tmp_path)
    assert open(config, "rb").read() == before
    assert sorted(os.listdir(tmp_path / ".aimi")) == ["config.json"]


# ---------------------------------------------------------------- wiring pins

PLUGIN = os.path.dirname(SCRIPTS)
EXEC = os.path.join(PLUGIN, "commands", "references", "execute")


def _text(*parts):
    with open(os.path.join(*parts), encoding="utf-8") as handle:
        return handle.read()


def test_the_wave_loop_hands_the_stage_only_to_a_declared_group():
    step4 = _text(EXEC, "step-4-wave-execution-loop.md")
    line = next(l for l in step4.splitlines() if "VERIFY_STAGE = worktree" in l)
    assert "only when" in line
    assert "verify-stage-declared --project" in step4


def test_the_worker_exports_the_stage_it_was_handed_and_never_invents_one():
    brief = _text(PLUGIN, "skills", "story-executor", "SKILL.md")
    assert "| `VERIFY_STAGE` |" in brief
    assert "export `AIMI_VERIFY_STAGE` with that value" in brief
    assert "leave the variable unset and never invent" in brief


def test_the_integrated_check_exports_merged_and_is_never_skipped_for_a_declared_project():
    recon = _text(EXEC, "wave-reconcile.md")
    assert "export AIMI_VERIFY_STAGE=merged" in recon
    skip = recon[recon.index("## Skip rule"):recon.index("## Select the union")]
    assert skip.index("verify-stage-declared") < skip.index("status = skipped")
    assert "if staged is false and tree_head == tree_story" in skip
    assert "a non-zero exit reads as staged" in skip
