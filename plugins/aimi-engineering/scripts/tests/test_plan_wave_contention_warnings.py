"""Tests for the wave-contention step of /aimi:plan Phase 4.5 (US-003).

The marked `phase45-wave-contention` block of
commands/references/plan/phase-45-validation.md is extracted and run under bash
and zsh. Most cases point $AIMI_CLI at a stub that answers
`validate-wave-contention` from a canned stdout and exit status; the stub never
reads a tasks file. One case runs the aimi-cli.sh of the tree under test (never
the cli-path cache) over a throwaway root that holds its own `.aimi/tasks/`.
The text cases pin the remedy paragraph and the size ceiling.
"""

import json
import os
import re
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
PHASE = ROOT / "commands" / "references" / "plan" / "phase-45-validation.md"
TEXT = PHASE.read_text(encoding="utf-8")
CLI = ROOT / "scripts" / "aimi-cli.sh"
SHELLS = [s for s in ("bash", "zsh") if shutil.which(s)]
NAME = "phase45-wave-contention"
PREFIX = "  wave-contention warning: "
FILE = "/x/t.json"


def block(text, name=NAME):
    lines = text.splitlines()
    begin = [i for i, l in enumerate(lines) if l.strip() == "# %s:begin" % name]
    end = [i for i, l in enumerate(lines) if l.strip() == "# %s:end" % name]
    assert len(begin) == 1 and len(end) == 1 and begin[0] < end[0]
    return "\n".join(lines[begin[0] + 1 : end[0]]) + "\n"


def make_stub(tmp, stdout, code):
    out = tmp / "answer.out"
    out.write_text(stdout, encoding="utf-8")
    stub = tmp / "stub-cli.sh"
    stub.write_text(
        "#!/bin/sh\n"
        'echo "$*" >> "%s"\n' % (tmp / "cli.log")
        + 'case "$1" in\n'
        '  validate-wave-contention) cat "%s"; exit %d ;;\n' % (out, code)
        + "  *) exit 9 ;; esac\n",
        encoding="utf-8",
    )
    stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
    return stub


def run_block(tmp, shell, cli, cwd=None):
    script = tmp / "block.sh"
    script.write_text(
        "AIMI_CLI=%s\nVALIDATE_FILE=%s\n" % (cli, FILE) + block(TEXT) + 'echo CONTINUED\n',
        encoding="utf-8",
    )
    return subprocess.run(
        [shutil.which(shell), str(script)], capture_output=True, text=True,
        cwd=str(cwd) if cwd else None, timeout=120,
    )


def verdict(errors=(), warnings=None):
    v = {"valid": not errors, "errors": list(errors)}
    if warnings is not None:
        v["warnings"] = list(warnings)
    return json.dumps(v, indent=2) + "\n"


WARN = "Wave contention warning: wave 1 path a.ts shared by 2 stories with disjoint symbols: US-001, US-002"
SYMBOL_ERR = "Wave contention: wave 2 path b.ts symbol f claimed by US-003, US-004"
FILE_ERR = "Wave contention: wave 1 path a.ts claimed by US-001, US-002"


@pytest.mark.parametrize("shell", SHELLS)
def test_wave_contention_block_prints_each_warning_and_continues(tmp_path, shell):
    other = "Wave contention warning: wave 3 path c.ts shared by 2 stories with disjoint symbols: US-005, US-006"
    stub = make_stub(tmp_path, verdict(warnings=[WARN, other]), 0)
    r = run_block(tmp_path, shell, stub)
    assert r.returncode == 0, r.stderr
    assert r.stdout.splitlines() == [PREFIX + WARN, PREFIX + other, "CONTINUED"]
    assert r.stderr == ""


@pytest.mark.parametrize("shell", SHELLS)
def test_wave_contention_block_without_warnings_key_prints_nothing_new(tmp_path, shell):
    stub = make_stub(tmp_path, verdict(), 0)
    r = run_block(tmp_path, shell, stub)
    assert r.returncode == 0 and r.stdout == "CONTINUED\n" and r.stderr == ""


@pytest.mark.parametrize("shell", SHELLS)
def test_wave_contention_block_empty_warnings_array_prints_nothing(tmp_path, shell):
    stub = make_stub(tmp_path, verdict(warnings=[]), 0)
    r = run_block(tmp_path, shell, stub)
    assert r.returncode == 0 and r.stdout == "CONTINUED\n"


@pytest.mark.parametrize("shell", SHELLS)
def test_wave_contention_block_refusal_prints_errors_then_rejection_and_exits_one(tmp_path, shell):
    stub = make_stub(tmp_path, verdict(errors=[SYMBOL_ERR, FILE_ERR]), 1)
    r = run_block(tmp_path, shell, stub)
    assert r.returncode == 1
    assert r.stderr.splitlines() == [SYMBOL_ERR, FILE_ERR, "validate-wave-contention rejected " + FILE]
    assert "CONTINUED" not in r.stdout and r.stdout == ""


@pytest.mark.parametrize("shell", SHELLS)
def test_wave_contention_block_refusal_with_warnings_prints_no_warning_line(tmp_path, shell):
    stub = make_stub(tmp_path, verdict(errors=[FILE_ERR], warnings=[WARN]), 1)
    r = run_block(tmp_path, shell, stub)
    assert r.returncode == 1 and r.stdout == ""
    assert r.stderr.splitlines()[-1] == "validate-wave-contention rejected " + FILE


@pytest.mark.parametrize("shell", SHELLS)
def test_wave_contention_block_sanitizes_backtick_command_substitution_newline_and_length(tmp_path, shell):
    dirty = "path `rm -rf x` and $(id)\nsecond\rthird " + "z" * 300
    stub = make_stub(tmp_path, verdict(warnings=[dirty]), 0)
    r = run_block(tmp_path, shell, stub)
    assert r.returncode == 0
    lines = r.stdout.splitlines()
    assert lines[-1] == "CONTINUED" and len(lines) == 2
    text = lines[0][len(PREFIX):]
    assert lines[0].startswith(PREFIX)
    assert "`" not in text and "$(" not in text and "\r" not in text
    assert text.startswith("path rm -rf x and id) second third ")
    assert len(text) == 200

    err = make_stub(tmp_path, verdict(errors=["bad `x` $(y)\nz"]), 1)
    r = run_block(tmp_path, shell, err)
    assert r.returncode == 1
    assert r.stderr.splitlines() == ["bad x y) z", "validate-wave-contention rejected " + FILE]


@pytest.mark.parametrize("shell", SHELLS)
def test_wave_contention_block_empty_payload_exit_zero_continues_and_exit_one_rejects(tmp_path, shell):
    r = run_block(tmp_path, shell, make_stub(tmp_path, "", 0))
    assert r.returncode == 0 and r.stdout == "CONTINUED\n" and r.stderr == ""
    r = run_block(tmp_path, shell, make_stub(tmp_path, "", 1))
    assert r.returncode == 1 and r.stderr == "validate-wave-contention rejected %s\n" % FILE


@pytest.mark.parametrize("shell", SHELLS)
def test_wave_contention_block_slurps_one_verdict_per_document(tmp_path, shell):
    two = verdict(warnings=[WARN]) + verdict(warnings=["second doc"])
    r = run_block(tmp_path, shell, make_stub(tmp_path, two, 0))
    assert r.stdout.splitlines() == [PREFIX + WARN, PREFIX + "second doc", "CONTINUED"]
    two_bad = verdict(errors=[FILE_ERR]) + verdict(errors=[SYMBOL_ERR])
    r = run_block(tmp_path, shell, make_stub(tmp_path, two_bad, 1))
    assert r.stderr.splitlines()[:2] == [FILE_ERR, SYMBOL_ERR]


def _story(story_id, symbols):
    return {
        "id": story_id, "title": "Story " + story_id, "description": "As a user, I want " + story_id + ".",
        "acceptanceCriteria": ["Typecheck passes"], "status": "pending", "priority": 1, "dependsOn": [],
        "implementation": {"files": ["a.ts"], "approach": "a", "verify": "true", "symbols": {"a.ts": symbols}},
    }


def _real_root(tmp, stories):
    root = Path(os.path.realpath(str(tmp)))
    tasks = root / ".aimi" / "tasks"
    tasks.mkdir(parents=True)
    doc = {
        "schemaVersion": "3.3",
        "metadata": {"title": "ref: waves", "type": "ref", "branchName": "ref/waves", "createdAt": "2020-01-01", "planPath": None},
        "userStories": stories,
    }
    (tasks / "2020-01-01-warnings-tasks.json").write_text(json.dumps(doc), encoding="utf-8")
    return root


@pytest.mark.parametrize("shell", SHELLS)
def test_wave_contention_block_real_cli_disjoint_symbols_print_the_warning_and_continue(tmp_path, shell):
    root = _real_root(tmp_path / shell, [_story("US-001", {"edits": ["f"]}), _story("US-002", {"creates": ["g"]})])
    r = run_block(tmp_path, shell, CLI, cwd=root)
    assert r.returncode == 0, r.stderr
    assert r.stdout.splitlines() == [
        PREFIX + "Wave contention warning: wave 1 path a.ts shared by 2 stories with disjoint symbols: US-001, US-002",
        "CONTINUED",
    ]


@pytest.mark.parametrize("shell", SHELLS)
def test_wave_contention_block_real_cli_shared_symbol_is_refused(tmp_path, shell):
    root = _real_root(tmp_path / shell, [_story("US-001", {"edits": ["f"]}), _story("US-002", {"edits": ["f"]})])
    r = run_block(tmp_path, shell, CLI, cwd=root)
    assert r.returncode == 1 and "CONTINUED" not in r.stdout
    assert r.stderr.splitlines() == [
        "Wave contention: wave 1 path a.ts symbol f claimed by US-001, US-002",
        "validate-wave-contention rejected " + FILE,
    ]


def _remedy():
    start = TEXT.index("**`validate-wave-contention` is read from `$?`")
    end = TEXT.index("**If any validation fails")
    return TEXT[start:end]


def test_wave_contention_block_sits_in_the_loop_between_validate_tasks_and_validate_waves():
    assert TEXT.index("$AIMI_CLI validate-tasks") < TEXT.index("# %s:begin" % NAME)
    assert TEXT.index("# %s:end" % NAME) < TEXT.index("WAVES_JSON=$($AIMI_CLI validate-waves)")
    assert "validate-wave-contention || exit 1" not in TEXT


def test_wave_contention_block_shape():
    b = block(TEXT)
    assert b.count("validate-wave-contention") >= 2
    assert "jq -r -s" in b and not re.search(r"jq[^|\n]*<\s*\S", b)
    for step in ('gsub("[\\\\n\\\\r]"; " ")', 'gsub("`"; "")', 'gsub("\\\\$\\\\("; "")', ".[0:200]"):
        assert step in b


def test_wave_contention_remedy_covers_the_three_outcomes():
    p = _remedy()
    assert "Wave contention: wave N path P symbol S claimed by" in p and "`dependsOn` edge" in p
    assert "a real collision" in p
    assert "narrowing `implementation.files`" in p
    assert "`implementation.symbols` entry for P on EVERY claimant" in p
    assert "a missing, empty or malformed entry counts as none and keeps the refusal" in p
    assert "exits 0 and needs no fix" in p
    assert "`EXPECTED_ASSERTIONS`" in p and "left undeclared" in p
    assert "Only stories of the same project are compared" in p
    assert "`wave-verify-commands`" in p and "wave-reconcile.md" in p


def test_wave_contention_remedy_never_offers_normalize_waves():
    assert "normalize-waves" not in _remedy()


def test_wave_contention_phase_file_stays_under_the_shared_ceiling():
    assert len(TEXT.encode("utf-8")) <= 16384
