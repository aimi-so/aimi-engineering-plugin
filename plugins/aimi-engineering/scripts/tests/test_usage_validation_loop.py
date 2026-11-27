"""Tests for the usage validation loop reference.

`commands/references/execute/usage-validation-loop.md` carries two marked bash
blocks, `usage-loop-verdict` and `usage-loop-fix-worktree`. Each is extracted
between its `# <name>:begin` / `# <name>:end` lines and run under bash and zsh
against a stub CLI and a stub worktree manager that log their arguments. The
text cases pin the rest of the file and its wiring in execute.md.
"""

import json
import os
import re
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

import execute_text

ROOT = Path(__file__).resolve().parents[2]
LOOP = ROOT / "commands" / "references" / "execute" / "usage-validation-loop.md"
TEXT = LOOP.read_text(encoding="utf-8")
SHELLS = [s for s in ("bash", "zsh") if shutil.which(s)]


def extract_block(name):
    lines = TEXT.splitlines()
    begin = [i for i, l in enumerate(lines) if l.strip() == "# %s:begin" % name]
    end = [i for i, l in enumerate(lines) if l.strip() == "# %s:end" % name]
    assert len(begin) == 1 and len(end) == 1 and begin[0] < end[0]
    return "\n".join(lines[begin[0] + 1 : end[0]]) + "\n"


def _exe(path, body):
    path.write_text("#!/bin/sh\n" + body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


ANSWER = {
    "outcome": "fails",
    "reason": "1 blocking bug(s)",
    "counts": {"planned": 2, "executed": 2, "blocked": 0, "exploratoryActions": 5},
    "bugs": [{"key": "CH-US-001:2:H1", "origin": "charter"}],
    "decisions": [{"key": "CH-US-001:3:H4"}, {"key": "CH-US-002:1:H2"}],
    "unmapped": [{"key": "EX-1:1:F"}],
}


def run_verdict(tmp_path, shell, phase_mode, accepted="", reproduced="", review="", verdict_exit=0):
    log = tmp_path / "cli.log"
    (tmp_path / "answer.json").write_text(json.dumps(ANSWER), encoding="utf-8")
    cli = tmp_path / "stub-cli.sh"
    _exe(
        cli,
        'echo "$*" >> "%s"\n'
        'case "$1" in\n'
        '  write-review) cat >/dev/null; echo \'{"review": ".aimi/reviews/x.md"}\' ;;\n'
        '  usage-validation-verdict) cat >/dev/null; [ %d -eq 0 ] || exit 1; cat "%s" ;;\n'
        "  *) exit 9 ;;\nesac\n" % (log, verdict_exit, tmp_path / "answer.json"),
    )
    script = tmp_path / "block.sh"
    script.write_text(
        'AIMI_CLI="%s"\n' % cli
        + 'USAGE_ROUND="1"\nUSAGE_REQUIRED_FILE="/p/required.json"\nUSAGE_EVIDENCE_DIR="/p/ev"\n'
        + 'USAGE_PHASE_MODE="%s"\nUSAGE_FEATURE="feat"\nUSAGE_PHASE_ID="2"\nUSAGE_REVIEW="%s"\n' % (phase_mode, review)
        + 'USAGE_TASKS_FILE="/p/.aimi/tasks/run-tasks.json"\n'
        + "USAGE_ACCEPTED=$(cat <<'E1'\n%s\nE1\n)\n" % accepted
        + "USAGE_REPRODUCED=$(cat <<'E2'\n%s\nE2\n)\n" % reproduced
        + "USAGE_MESSAGE=$(cat <<'E3'\nraw validator message\nE3\n)\n"
        + extract_block("usage-loop-verdict"),
        encoding="utf-8",
    )
    out = subprocess.run([shutil.which(shell), str(script)], capture_output=True, text=True, timeout=60).stdout
    calls = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
    return out, calls


@pytest.mark.parametrize("shell", SHELLS)
def test_verdict_block_phase_mode_prints_the_round_line_and_uses_repeatable_flags(tmp_path, shell):
    out, calls = run_verdict(tmp_path, shell, "true", accepted="A:1:H1\nB:2:H2", reproduced="C:3:H3")
    assert calls[0] == "write-review --feature feat --phase 2 --kind usage-validation-r1"
    assert calls[1] == ("usage-validation-verdict --required-file /p/required.json --evidence-dir /p/ev "
                        "--accepted A:1:H1 --accepted B:2:H2 --reproduced C:3:H3")
    assert ("usage-loop-round: round=1 outcome=fails planned=2 executed=2 blocked=0 exploratory=5 "
            "bugs=1 decisions=2 unmapped=1 review=.aimi/reviews/x.md") in out.splitlines()
    assert any(l.startswith("usage-loop-answer: {") for l in out.splitlines())


@pytest.mark.parametrize("shell", SHELLS)
def test_verdict_block_flat_mode_has_no_feature_or_phase(tmp_path, shell):
    _, calls = run_verdict(tmp_path, shell, "false")
    # The run's own tasks file names the review, never the shared current-tasks
    # pointer another session under the same .aimi/ may have moved.
    assert calls[0] == "write-review --kind usage-validation-r1 --tasks-file /p/.aimi/tasks/run-tasks.json"
    assert "--accepted" not in calls[1] and "--reproduced" not in calls[1]


@pytest.mark.parametrize("shell", SHELLS)
def test_verdict_block_reuses_a_known_review_and_writes_nothing(tmp_path, shell):
    out, calls = run_verdict(tmp_path, shell, "true", review=".aimi/reviews/first.md")
    assert not any(c.startswith("write-review") for c in calls)
    assert "review=.aimi/reviews/first.md" in out


@pytest.mark.parametrize("shell", SHELLS)
def test_verdict_block_a_refusing_verb_is_tooling_failed_never_pass(tmp_path, shell):
    out, _ = run_verdict(tmp_path, shell, "false", verdict_exit=1)
    assert "usage-loop-round: round=1 outcome=tooling-failed planned=0" in out


def run_fix(tmp_path, shell, create_out):
    root = tmp_path / "root"
    root.mkdir(exist_ok=True)
    log = tmp_path / "mgr.log"
    (tmp_path / "create.out").write_text(create_out, encoding="utf-8")
    (tmp_path / "list.out").write_text(
        "Available worktrees:\n\n  feat/run-US-001 → branch: x\n"
        "\033[0;32m✓ feat/run-usagefix-r1\033[0m (current) → branch: y\n  other → branch: z\n",
        encoding="utf-8",
    )
    mgr = tmp_path / "mgr.sh"
    _exe(
        mgr,
        'echo "$*" >> "%s"\n'
        'case "$1" in\n  list) cat "%s" ;;\n  create) cat "%s" ;;\n  remove) ;;\n  *) exit 9 ;;\nesac\n'
        % (log, tmp_path / "list.out", tmp_path / "create.out"),
    )
    script = tmp_path / "fix.sh"
    script.write_text(
        'WORKTREE_MGR="%s"\nUSAGE_EXEC_ROOT="%s"\nUSAGE_EXEC_BRANCH="feat/run"\nUSAGE_ROUND="2"\n' % (mgr, root)
        + extract_block("usage-loop-fix-worktree"),
        encoding="utf-8",
    )
    out = subprocess.run([shutil.which(shell), str(script)], capture_output=True, text=True, timeout=60).stdout
    return out, log.read_text(encoding="utf-8").splitlines()


@pytest.mark.parametrize("shell", SHELLS)
def test_fix_block_sweeps_leftovers_then_creates_from_the_run_branch(tmp_path, shell):
    out, calls = run_fix(tmp_path, shell, "noise\nWORKTREE_PATH=/w/a\nWORKTREE_BASE=abc123\nWORKTREE_PATH=/w/b\n")
    assert calls == ["list", "remove feat/run-usagefix-r1", "create feat/run-usagefix-r2 --from feat/run"]
    assert out.strip() == "usage-loop-fix-worktree: name=feat/run-usagefix-r2 path=/w/b base=abc123"


@pytest.mark.parametrize("shell", SHELLS)
@pytest.mark.parametrize("create_out", ["WORKTREE_PATH=/w/a\n", "WORKTREE_BASE=abc\n", ""])
def test_fix_block_an_absent_sentinel_fixes_nothing(tmp_path, shell, create_out):
    out, _ = run_fix(tmp_path, shell, create_out)
    assert out.startswith("usage-loop-fix-worktree: absent")


# --- text and wiring ------------------------------------------------------------


def test_usage_loop_header_anchor_and_inputs():
    assert TEXT.splitlines()[2].startswith("> Loaded by `commands/execute.md`")
    assert "Artifact Language Rule" in TEXT.splitlines()[3] and "user-communication.md" in TEXT
    for needle in ("agent-browser:<name>", "SESSION_NAME", "aimi-usage-<run key>", "`--restart`",
                   "FEATURE", "PHASE_ID", "PHASE_MODE", "EXEC_ROOT[group_key]", "EXEC_BRANCH[group_key]",
                   "every web charter is reported blocked", "unable-to-evaluate"):
        assert needle in TEXT, needle


def test_usage_loop_result_lines():
    assert re.search(r"usage-loop: outcome=<pass\|fails\|tooling-failed\|unable-to-evaluate> rounds=<n> "
                     r"fixed=<n> accepted=<n> open=<n> unmapped=<n> review=<path>", TEXT)
    assert "usage-loop-findings:" in TEXT and "usage-loop-reason:" in TEXT
    assert "usage-validation-stale:" in TEXT and "usage-loop-reported:" in TEXT and "usage-loop-unmapped:" in TEXT


def test_usage_loop_triage_decisions_and_agent_mode():
    for needle in ("`origin` is `charter`", "severity 3 or 4", "--reproduced", "never asked again",
                   "Use **AskUserQuestion**", "Leave failing", "agent-mode: usage-decision auto-left-failing"):
        assert needle in TEXT, needle


def test_usage_loop_fix_round_rules():
    for needle in ("-usagefix-r", "WORKTREE_PATH", "WORKTREE_BASE", "merge-all", "--into", "At most two",
                   "One commit per fixed finding", "never amend, rebase or rewrite",
                   "AGENT_MODELS.executor", "AGENT_MODELS.review", "mktemp -d", "usage-evidence:"):
        assert needle in TEXT, needle


def test_usage_loop_effort_pairing():
    lines = TEXT.splitlines()
    for i, line in enumerate(lines):
        if "AGENT_MODELS" in line:
            if line.strip().startswith("model:"):
                assert lines[i + 1].strip().startswith("effort: <AGENT_EFFORTS."), i
            else:
                assert "AGENT_EFFORTS" in line, i


def test_usage_loop_blocks_resolve_cli_with_the_hook_line_and_never_read_a_file_with_jq():
    cat_line = ('AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null '
                '|| cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)')
    assert cat_line in TEXT
    for m in re.finditer(r"jq [^\n|]*", TEXT):
        assert "<" not in m.group(0).split("'")[-1]


def test_usage_loop_router_entry_and_spawned_task_rows():
    router = (ROOT / "commands" / "execute.md").read_text(encoding="utf-8")
    assert router.count("references/execute/usage-validation-loop.md") == 1
    env = router.index("## Usage Validation Environment")
    loop = router.index("## Usage Validation Loop")
    assert env < loop < router.index("## Step 0.9")
    assert "SPAWNED_SPLIT_TASK" in router[loop : router.index("## Step 0.9")]
    rows = {l.split("|")[1].strip(): l.split("|") for l in router.splitlines() if l.startswith("| flat-split-child")
            or l.startswith("| phase-split-sub-orchestrator")}
    assert "Usage Validation Loop" in rows["flat-split-child"][3]
    assert "Usage Validation Loop" in rows["phase-split-sub-orchestrator"][4]
    assert "usage-validation-loop.md" in execute_text.execute_text()


def test_usage_loop_finalize_no_longer_claims_the_last_commit():
    text = (ROOT / "commands" / "references" / "execute" / "step-4-finalize.md").read_text(encoding="utf-8")
    assert "the branch's last commit" not in text
    assert "usage-validation fix commits may follow it" in text and "`FINALIZE_COMMIT` still names the one sha" in text


def test_usage_loop_is_listed_as_a_conditional_read():
    src = (ROOT / "scripts" / "tests" / "measure_execute_reads.py").read_text(encoding="utf-8")
    assert '"usage-validation-loop.md": FLAT,' in src
