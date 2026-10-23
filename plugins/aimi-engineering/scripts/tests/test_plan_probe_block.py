"""Tests for plan Phase 4.5 Step 3 -- the probe-plan block.

The block is extracted from the plan text (plan_text.py) between its `phase45-probe-plan:begin` /
`phase45-probe-plan:end` marker lines and run against a stub $AIMI_CLI that
answers `probe-plan` with a canned payload, under bash and under zsh. The
stub never calls the real probe.
"""

import json
import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

from plan_text import plan_text

ROOT = Path(__file__).resolve().parents[2]
SKILL = ROOT / "skills" / "story-executor" / "SKILL.md"
# plan.md is a router; the probe-plan block and the Phase 4.5 prose live in
# commands/references/plan/. plan_text() is the whole of /aimi:plan.
PLAN_TEXT = plan_text()

SHELLS = [s for s in ("bash", "zsh") if shutil.which(s)]

REAL_UNLABELLED = {"id": "US-002", "segment": "test -f src/guard.py"}
SKIPPED_SUITE = {
    "id": "US-001",
    "segment": "python3 -m pytest tests -q",
    "why": "skipped: matches the full-suite pattern",
}


def _payload(unlabelled=(), unmeasured=(SKIPPED_SUITE,), policy="report"):
    return {
        "baseRef": "abc1234",
        "probed": True,
        "policy": policy,
        "stories": [{"id": "US-001", "segments": []}],
        "unlabelledNonDiscriminating": list(unlabelled),
        "unmeasured": list(unmeasured),
    }


def extract_block():
    lines = PLAN_TEXT.splitlines()
    begin = [i for i, l in enumerate(lines) if l.strip() == "# phase45-probe-plan:begin"]
    end = [i for i, l in enumerate(lines) if l.strip() == "# phase45-probe-plan:end"]
    assert len(begin) == 1 and len(end) == 1 and begin[0] < end[0]
    return "\n".join(lines[begin[0] + 1 : end[0]]) + "\n"


def run_block(tmp_path, shell, answers, files=None, path_env=None):
    """answers: {basename: ('json', obj) | ('raw', text) | ('exit', code)}."""
    files = files or list(answers)
    stub = tmp_path / "stub-cli.sh"
    cases = []
    for name, (kind, val) in answers.items():
        if kind == "json":
            (tmp_path / (name + ".out")).write_text(json.dumps(val), encoding="utf-8")
            cases.append('%s) cat "%s"; exit 0 ;;' % (name, tmp_path / (name + ".out")))
        elif kind == "raw":
            (tmp_path / (name + ".out")).write_text(val, encoding="utf-8")
            cases.append('%s) cat "%s"; exit 0 ;;' % (name, tmp_path / (name + ".out")))
        else:
            cases.append("%s) exit %d ;;" % (name, val))
    stub.write_text(
        "#!/bin/sh\n"
        '[ "$1" = "probe-plan" ] || exit 9\n'
        'f=$(basename "$3")\n'
        'case "$f" in\n' + "\n".join(cases) + "\n*) exit 7 ;; esac\n",
        encoding="utf-8",
    )
    stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
    cfg = tmp_path / "cfg"
    cfg.mkdir(exist_ok=True)
    (cfg / "cli-path").write_text(str(stub), encoding="utf-8")
    merge = json.dumps([{"path": str(tmp_path / f)} for f in files])
    script = tmp_path / "block.sh"
    script.write_text(
        'MERGE_RETURN=\'%s\'\n' % merge
        + 'AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-$HOME/.config/aimi}/cli-path")\n'
        + 'VALIDATE_FILES=$(printf \'%s\' "$MERGE_RETURN" | jq -r \'.[].path\')\n'
        + extract_block(),
        encoding="utf-8",
    )
    env = dict(os.environ, AIMI_CONFIG_DIR=str(cfg))
    if path_env is not None:
        env["PATH"] = path_env
    shell_path = shutil.which(shell)
    return subprocess.run(
        [shell_path, str(script)], capture_output=True, text=True, env=env, timeout=60
    ).stdout


@pytest.mark.parametrize("shell", SHELLS)
def test_clean_fixture_prints_no_unlabelled_line_and_counts_one_unmeasured(tmp_path, shell):
    out = run_block(tmp_path, shell, {"a.json": ("json", _payload())})
    assert "unlabelled non-discriminating:" not in out
    assert "unmeasured: US-001: python3 -m pytest tests -q" in out
    assert "skipped: matches the full-suite pattern" in out
    assert out.rstrip().endswith(
        "Verify probe: 0 unlabelled non-discriminating, 1 unmeasured, 0 not probed"
    )


@pytest.mark.parametrize("shell", SHELLS)
def test_twin_with_one_label_removed_prints_exactly_one_unlabelled_line(tmp_path, shell):
    out = run_block(
        tmp_path, shell, {"a.json": ("json", _payload(unlabelled=[REAL_UNLABELLED]))}
    )
    hits = [l for l in out.splitlines() if "unlabelled non-discriminating:" in l]
    assert hits == ["  unlabelled non-discriminating: US-002: test -f src/guard.py"]
    assert out.rstrip().endswith(
        "Verify probe: 1 unlabelled non-discriminating, 1 unmeasured, 0 not probed"
    )


@pytest.mark.parametrize("shell", SHELLS)
@pytest.mark.parametrize(
    "answer",
    [
        ("exit", 1),
        ("raw", ""),
        ("raw", "not json at all"),
        ("raw", '{"probed": "yes"}'),
        ("raw", "[1, 2]"),
        ("json", {"baseRef": "x", "probed": False, "reason": "the ref does not resolve"}),
    ],
)
def test_unusable_answer_is_not_probed_never_zero_findings(tmp_path, shell, answer):
    out = run_block(
        tmp_path,
        shell,
        {"a.json": answer, "b.json": ("json", _payload(unlabelled=[REAL_UNLABELLED]))},
    )
    assert "  not probed: " in out and "a.json" in out
    # the loop still visited the second file
    assert "unlabelled non-discriminating: US-002" in out
    assert out.rstrip().endswith(
        "Verify probe: 1 unlabelled non-discriminating, 1 unmeasured, 1 not probed"
    )


@pytest.mark.parametrize("shell", SHELLS)
def test_probed_false_prints_its_reason(tmp_path, shell):
    out = run_block(
        tmp_path,
        shell,
        {"a.json": ("json", {"baseRef": "x", "probed": False, "reason": "shallow clone"})},
    )
    assert "not probed: " in out and "— shallow clone" in out
    assert out.rstrip().endswith(
        "Verify probe: 0 unlabelled non-discriminating, 0 unmeasured, 1 not probed"
    )


@pytest.mark.parametrize("shell", SHELLS)
def test_hostile_text_is_sanitized_and_truncated(tmp_path, shell):
    hostile = "a`b $(rm -rf x)" + "x" * 300 + "\nforged line\r"
    out = run_block(
        tmp_path,
        shell,
        {"a.json": ("json", _payload(unlabelled=[{"id": "US-009", "segment": hostile}]))},
    )
    line = [l for l in out.splitlines() if "unlabelled non-discriminating:" in l][0]
    seg = line.split("US-009: ", 1)[1]
    assert "`" not in seg and "$(" not in seg
    assert len(seg) <= 200
    assert "forged line" not in out.replace(seg, "")


@pytest.mark.parametrize("shell", SHELLS)
@pytest.mark.parametrize(
    "policy,expected",
    [("refuse", "refuse"), ("report", "report"), ("other", "report"), (None, "report")],
)
def test_policy_is_read_from_the_payload(tmp_path, shell, policy, expected):
    payload = _payload()
    if policy is None:
        del payload["policy"]
    else:
        payload["policy"] = policy
    out = run_block(tmp_path, shell, {"a.json": ("json", payload)})
    lines = out.rstrip().splitlines()
    assert lines[-2] == "Verify probe policy: " + expected
    assert lines[-1].startswith("Verify probe: ")


@pytest.mark.parametrize("shell", SHELLS)
def test_missing_python3_counts_every_file_not_probed(tmp_path, shell):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    for tool in ("jq", "cat", "basename"):
        found = shutil.which(tool)
        assert found
        (bindir / tool).symlink_to(found)
    out = run_block(
        tmp_path,
        shell,
        {"a.json": ("json", _payload()), "b.json": ("json", _payload())},
        path_env=str(bindir),
    )
    assert out.count("python3 is not installed") == 2
    assert out.rstrip().endswith(
        "Verify probe: 0 unlabelled non-discriminating, 0 unmeasured, 2 not probed"
    )


def test_block_keeps_the_validator_resolution_lines_byte_identical():
    guard = (
        '""' if False else
        ': "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"'
    )
    resolve = (
        'AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" '
        '2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)'
    )
    marker = PLAN_TEXT.index("# phase45-probe-plan:begin")
    head = PLAN_TEXT[PLAN_TEXT.rindex("```bash", 0, marker) : marker]
    assert resolve in head and guard in head
    assert "$MERGE_RETURN" in head and "VALIDATE_FILES=" in head
    assert "$AIMI_CLI " not in extract_block()  # always quoted, never composed


def test_block_adds_no_jq_that_opens_a_file():
    for line in extract_block().splitlines():
        if "jq " in line:
            assert "printf" in line or "<<<" in line, line


def test_prose_cites_policy_and_wires_step_five_and_error_rows():
    assert "commands/references/verify-probe-policy.md" in PLAN_TEXT
    assert "Verify probe policy: report|refuse" in PLAN_TEXT
    assert "Verify probe: [N] unlabelled non-discriminating, [M] unmeasured, [K] not probed" in PLAN_TEXT
    assert "**Verify probe line:**" in PLAN_TEXT
    assert PLAN_TEXT.count("| Phase 4.5 |") >= 4
    assert "INTERACTIVE_MODE=agent" in PLAN_TEXT
    assert "A refusal never deletes a written tasks file" in PLAN_TEXT


def test_guardrails_mentioned_in_the_three_plan_places_and_the_skill():
    assert PLAN_TEXT.count("guardRails") >= 3
    assert "'guardRails': [" in PLAN_TEXT
    assert '"guardRails": [' in PLAN_TEXT
    assert "implementation.guardRails" in PLAN_TEXT
    skill = SKILL.read_text(encoding="utf-8")
    assert "implementation.guardRails" in skill
    assert "WARNING and NEVER a block" in skill


def test_failure_row_no_longer_anticipates_non_git_root():
    rows = [l for l in PLAN_TEXT.splitlines() if l.startswith("| Phase 4.5 |") and "baseRef" in l]
    assert len(rows) == 1
    assert "`AIMI_ROOT` not a git repository" not in rows[0]
    assert "non-git parent" in PLAN_TEXT and "in the project repository its stories name" in PLAN_TEXT
