"""Tests for the Flat Usage Validation step reference.

`commands/references/execute/step-4-usage-validation.md` carries three marked
bash blocks, `usage-flat-required`, `usage-flat-skip` and `usage-flat-record`.
Each is extracted between its `# <name>:begin` / `# <name>:end` lines and run
under bash and zsh against a stub CLI that logs its arguments. Every flag the
blocks pass is compared with `aimi-cli.sh help` of the tree under test.
"""

import json
import re
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / "scripts" / "aimi-cli.sh"
STEP = ROOT / "commands" / "references" / "execute" / "step-4-usage-validation.md"
TEXT = STEP.read_text(encoding="utf-8")
ROUTER = (ROOT / "commands" / "execute.md").read_text(encoding="utf-8")
SHELLS = [s for s in ("bash", "zsh") if shutil.which(s)]
TF = "/x/plan-tasks.json"


def extract_block(name):
    lines = TEXT.splitlines()
    begin = [i for i, l in enumerate(lines) if l.strip() == "# %s:begin" % name]
    end = [i for i, l in enumerate(lines) if l.strip() == "# %s:end" % name]
    assert len(begin) == 1 and len(end) == 1 and begin[0] < end[0]
    return "\n".join(lines[begin[0] + 1 : end[0]]) + "\n"


def _exe(path, body):
    path.write_text("#!/bin/sh\n" + body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def run_block(tmp_path, shell, name, preamble, answers):
    """answers: {verb: (exit, stdout)}; any other verb exits 9."""
    log = tmp_path / "cli.log"
    (tmp_path / ".aimi").mkdir(exist_ok=True)
    cases = ""
    for verb, (code, out) in answers.items():
        (tmp_path / ("ans-" + verb)).write_text(out, encoding="utf-8")
        cases += '  %s) cat "%s"; exit %d ;;\n' % (verb, tmp_path / ("ans-" + verb), code)
    cli = tmp_path / "stub-cli.sh"
    _exe(cli, 'echo "$*" >> "%s"\ncase "$1" in\n%s  *) exit 9 ;;\nesac\n' % (log, cases))
    script = tmp_path / "block.sh"
    script.write_text('AIMI_CLI="%s"\nAIMI_ROOT="%s"\nRUN_TASKS_FILE="%s"\n' % (cli, tmp_path, TF) + preamble + extract_block(name), encoding="utf-8")
    proc = subprocess.run([shutil.which(shell), str(script)], capture_output=True, text=True, timeout=60)
    calls = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
    return proc, calls


def answer(**over):
    base = {"required": True, "skipKind": None, "reason": "ok", "surfaceSource": "declared", "askUndeclared": False,
            "members": 1, "projects": ["."], "charters": [{"id": "CH-US-001"}, {"id": "CH-US-002"}]}
    base.update(over)
    return json.dumps(base)


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_flat_required_owed_saves_the_answer_and_prints_one_line(tmp_path, shell):
    proc, calls = run_block(tmp_path, shell, "usage-flat-required", "",
                            {"usage-validation-required": (0, answer(members=2, projects=["api", "web"]))})
    assert calls == ["usage-validation-required --tasks-file " + TF]
    lines = proc.stdout.splitlines()
    assert lines[0] == ("usage-validation-required: required=true skipKind=none surfaceSource=declared "
                        "members=2 projects=api,web charters=2")
    saved = [l.split(": ", 1)[1] for l in lines if l.startswith("usage-validation-answer: ")]
    assert len(saved) == 1 and Path(saved[0]).parent == tmp_path / ".aimi"
    assert json.loads(Path(saved[0]).read_text())["required"] is True


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_flat_required_not_owed_saves_nothing_and_prints_the_skip(tmp_path, shell):
    ans = answer(required=False, skipKind="not-applicable", reason="nothing to use", surfaceSource="none", askUndeclared=True)
    proc, calls = run_block(tmp_path, shell, "usage-flat-required", "", {"usage-validation-required": (0, ans)})
    assert "usage-validation-skip: kind=not-applicable ask=true reason=nothing to use" in proc.stdout
    assert list((tmp_path / ".aimi").iterdir()) == []


@pytest.mark.parametrize("shell", SHELLS)
@pytest.mark.parametrize("code,out", [(1, ""), (0, ""), (0, '{"required": "yes"}'), (0, "not json")])
def test_usage_flat_required_tooling_failed_prints_an_unable_to_evaluate_skip(tmp_path, shell, code, out):
    proc, calls = run_block(tmp_path, shell, "usage-flat-required", "", {"usage-validation-required": (code, out)})
    assert proc.returncode == 0
    assert "usage-validation-skip: kind=unable-to-evaluate ask=false reason=usage-validation-required:" in proc.stdout
    assert calls == ["usage-validation-required --tasks-file " + TF]
    assert list((tmp_path / ".aimi").iterdir()) == []


def skip_preamble(kind, reason, stored="none"):
    return 'USAGE_STORED_STATUS="%s"\nUSAGE_KIND="%s"\nUSAGE_REASON=$(cat <<\'E1\'\n%s\nE1\n)\n' % (stored, kind, reason)


@pytest.mark.parametrize("shell", SHELLS)
@pytest.mark.parametrize("kind", ["not-applicable", "unable-to-evaluate", "disabled-by-operator"])
def test_usage_flat_skip_records_the_answers_own_kind(tmp_path, shell, kind):
    proc, calls = run_block(tmp_path, shell, "usage-flat-skip", skip_preamble(kind, "some $reason here"),
                            {"usage-validation-record": (0, "{}")})
    assert calls == ["usage-validation-record --tasks-file %s --status skipped --kind %s --reason some $reason here" % (TF, kind)]
    assert proc.stdout == "usage-validation: skipped (%s) — some $reason here\n" % kind


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_flat_skip_a_refused_record_is_tooling_failed(tmp_path, shell):
    proc, calls = run_block(tmp_path, shell, "usage-flat-skip", skip_preamble("not-applicable", "r"),
                            {"usage-validation-record": (1, "")})
    assert proc.stdout == "usage-validation: tooling-failed\n"


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_flat_skip_unable_keeps_a_stored_failing_record(tmp_path, shell):
    proc, calls = run_block(tmp_path, shell, "usage-flat-skip", skip_preamble("unable-to-evaluate", "env: down", "failing"),
                            {"usage-validation-record": (0, "{}")})
    assert calls == []
    assert proc.stdout == "usage-validation: failing — re-validation could not run (env: down)\n"


@pytest.mark.parametrize("shell", SHELLS)
@pytest.mark.parametrize("kind", ["not-applicable", "disabled-by-operator"])
def test_usage_flat_skip_a_chosen_skip_replaces_a_stored_failing_record(tmp_path, shell, kind):
    proc, calls = run_block(tmp_path, shell, "usage-flat-skip", skip_preamble(kind, "r", "failing"),
                            {"usage-validation-record": (0, "{}")})
    assert len(calls) == 1 and "--kind " + kind in calls[0]


def record_preamble(line, findings="{}", reason="", stored="none", env="ready", env_reason="", stale=""):
    pre = 'USAGE_STORED_STATUS="%s"\nUSAGE_ENV_OUTCOME="%s"\nUSAGE_ENV_REASON="%s"\nUSAGE_STALE_LINE="%s"\n' % (stored, env, env_reason, stale)
    pre += 'USAGE_LOOP_LINE="%s"\n' % line
    pre += "USAGE_LOOP_FINDINGS=$(cat <<'E1'\n%s\nE1\n)\n" % findings
    pre += "USAGE_LOOP_REASON=$(cat <<'E2'\n%s\nE2\n)\n" % reason
    return pre


def loop_line(outcome, rounds=1, review=".aimi/reviews/r.md"):
    return "usage-loop: outcome=%s rounds=%s fixed=1 accepted=2 open=0 unmapped=0 review=%s" % (outcome, rounds, review)


OK = {"usage-validation-record": (0, "{}")}
FINDINGS = '{"CH-US-001:2:H1": {"status": "accepted", "reason": "known"}}'


def with_review(tmp_path):
    (tmp_path / ".aimi" / "reviews").mkdir(parents=True)
    (tmp_path / ".aimi" / "reviews" / "r.md").write_text("x")


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_flat_record_pass_passes_rounds_findings_and_an_existing_review(tmp_path, shell):
    with_review(tmp_path)
    proc, calls = run_block(tmp_path, shell, "usage-flat-record", record_preamble(loop_line("pass"), FINDINGS), OK)
    assert calls == ["usage-validation-record --tasks-file %s --status passed --rounds 1 "
                     "--findings-json %s --review .aimi/reviews/r.md" % (TF, FINDINGS)]
    assert proc.stdout == "usage-validation: passed — 1 fix round(s), 2 accepted\n"


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_flat_record_pass_omits_empty_findings_and_a_missing_review(tmp_path, shell):
    proc, calls = run_block(tmp_path, shell, "usage-flat-record", record_preamble(loop_line("pass", 0)), OK)
    assert calls == ["usage-validation-record --tasks-file %s --status passed --rounds 0" % TF]


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_flat_record_fails_records_failing_with_the_loops_reason(tmp_path, shell):
    with_review(tmp_path)
    proc, calls = run_block(tmp_path, shell, "usage-flat-record",
                            record_preamble(loop_line("fails", 2), FINDINGS, "1 blocking bug(s) left open"), OK)
    assert calls == ["usage-validation-record --tasks-file %s --status failing --reason 1 blocking bug(s) left open "
                     "--rounds 2 --findings-json %s --review .aimi/reviews/r.md" % (TF, FINDINGS)]
    assert proc.stdout == "usage-validation: failing — 1 blocking bug(s) left open\n"


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_flat_record_unable_to_evaluate_is_a_skip_with_the_loops_reason(tmp_path, shell):
    proc, calls = run_block(tmp_path, shell, "usage-flat-record",
                            record_preamble(loop_line("unable-to-evaluate", 0), "{}", "no browser"), OK)
    assert calls == ["usage-validation-record --tasks-file %s --status skipped --kind unable-to-evaluate --reason loop: no browser" % TF]


@pytest.mark.parametrize("shell", SHELLS)
@pytest.mark.parametrize("outcome", ["tooling-failed", "banana", ""])
def test_usage_flat_record_any_other_outcome_is_an_unable_skip(tmp_path, shell, outcome):
    proc, calls = run_block(tmp_path, shell, "usage-flat-record", record_preamble(loop_line(outcome), "{}", "why"), OK)
    assert len(calls) == 1 and "--status skipped --kind unable-to-evaluate --reason loop: why" in calls[0]


@pytest.mark.parametrize("shell", SHELLS)
@pytest.mark.parametrize("env", ["unable-to-evaluate", "tooling-failed"])
def test_usage_flat_record_a_failed_environment_is_an_unable_skip_without_a_loop(tmp_path, shell, env):
    proc, calls = run_block(tmp_path, shell, "usage-flat-record", record_preamble("", env=env, env_reason="bring-up: busy"), OK)
    assert calls == ["usage-validation-record --tasks-file %s --status skipped --kind unable-to-evaluate --reason environment: bring-up: busy" % TF]


@pytest.mark.parametrize("shell", SHELLS)
@pytest.mark.parametrize("outcome", ["unable-to-evaluate", "tooling-failed", "banana"])
def test_usage_flat_record_a_stored_failing_record_survives_an_unable_end(tmp_path, shell, outcome):
    proc, calls = run_block(tmp_path, shell, "usage-flat-record", record_preamble(loop_line(outcome), "{}", "x", stored="failing"), OK)
    assert calls == []
    assert proc.stdout.startswith("usage-validation: failing — re-validation could not run (")


@pytest.mark.parametrize("shell", SHELLS)
@pytest.mark.parametrize("outcome", ["pass", "fails"])
def test_usage_flat_record_a_judged_verdict_replaces_a_stored_failing_record(tmp_path, shell, outcome):
    proc, calls = run_block(tmp_path, shell, "usage-flat-record", record_preamble(loop_line(outcome), "{}", "r", stored="failing"), OK)
    assert len(calls) == 1


@pytest.mark.parametrize("shell", SHELLS)
@pytest.mark.parametrize("outcome", ["pass", "fails", "unable-to-evaluate"])
def test_usage_flat_record_a_refused_record_is_tooling_failed(tmp_path, shell, outcome):
    proc, calls = run_block(tmp_path, shell, "usage-flat-record", record_preamble(loop_line(outcome), "{}", "why"),
                            {"usage-validation-record": (1, "")})
    assert proc.stdout == "usage-validation: tooling-failed\n"


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_flat_record_prints_the_stale_line_after_the_status_line(tmp_path, shell):
    proc, calls = run_block(tmp_path, shell, "usage-flat-record", record_preamble(loop_line("pass", 0), stale="usage-validation-stale: x"), OK)
    assert proc.stdout.splitlines()[-1] == "usage-validation-stale: x"


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_flat_record_reads_the_line_by_field_name(tmp_path, shell):
    line = "usage-loop: review= open=0 rounds=2 outcome=pass accepted=1 fixed=0 unmapped=0"
    proc, calls = run_block(tmp_path, shell, "usage-flat-record", record_preamble(line), OK)
    assert calls == ["usage-validation-record --tasks-file %s --status passed --rounds 2" % TF]


def _help_flags(verb):
    text = subprocess.run(["bash", str(CLI), "help"], capture_output=True, text=True, timeout=60).stdout
    lines = [l for l in text.splitlines() if l.startswith("    " + verb + " ")]
    assert lines, verb
    return set(re.findall(r"--[a-z][a-z-]*", lines[0]))


@pytest.mark.parametrize("verb", ["usage-validation-required", "usage-validation-record", "metadata"])
def test_usage_flat_every_flag_passed_is_one_the_cli_help_lists(verb):
    help_flags = _help_flags(verb)
    used = set()
    for line in TEXT.splitlines():
        if verb in line and '"$AIMI_CLI"' in line:
            used |= set(re.findall(r"--[a-z][a-z-]*", line))
    assert used, verb
    assert used <= help_flags, (verb, used - help_flags)


def test_usage_flat_header_anchor_and_size():
    assert TEXT.startswith("# Execute: Step 4: Flat Usage Validation\n")
    assert "> Loaded by `commands/execute.md` when its `Applies when:` condition holds." in TEXT
    assert "user-communication.md" in TEXT.split("### Flat Usage Validation Step")[0]
    assert "### Flat Usage Validation Step" in TEXT
    assert len(TEXT.encode("utf-8")) <= 16384


def test_usage_flat_boundaries():
    assert "step-5-completion" in TEXT.split("#### Never")[1] and "Never edit" in TEXT
    assert "usage-validation-environment.md" not in TEXT and "usage-validation-loop.md" not in TEXT
    assert "Usage Validation Environment" in TEXT and "Usage Validation Loop" in TEXT
    assert "project-groups" in TEXT
    assert "Tear Down on every end except the loop's `fails`" in TEXT
    assert "status=failing" in TEXT and "USAGE_RESTART" in TEXT and "PHASE_MODE=false" in TEXT


def test_usage_flat_undeclared_surface_question():
    assert "askUndeclared" in TEXT and "Use **AskUserQuestion**" in TEXT
    assert "agent-mode: usage-surface auto-recorded not-applicable" in TEXT
    assert "no overwrite" in TEXT and "never asked about" in TEXT


def test_usage_flat_blocks_resolve_cli_with_the_hook_line_and_never_open_a_file_with_jq():
    line = ('AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || '
            'cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)')
    blocks = re.findall(r"```bash\n(.*?)```", TEXT, re.S)
    assert len(blocks) == 4
    for block in blocks:
        assert block.splitlines()[0] == line
        assert re.search(r"jq [^|\n]*\.json", block) is None
    assert "set --" in extract_block("usage-flat-record")


def test_usage_flat_router_entry_wiring_and_spawned_rows():
    assert ROUTER.count("references/execute/step-4-usage-validation.md") == 1
    entry_at = ROUTER.index("### Flat Usage Validation Step")
    assert ROUTER.index("### Finalize Step") < entry_at < ROUTER.index("## Console Error Attribution")
    entry = ROUTER[entry_at : ROUTER.index("## Console Error Attribution")]
    assert "Applies when:" in entry and "PHASE_MODE" in entry and "SPAWNED_SPLIT_TASK" in entry
    assert "Re-validate" in ROUTER.split("## Step 3: Check for Pending Stories")[1].split("Covers:")[1].split("\n")[0]
    rows = {l.split("|")[1].strip(): l for l in ROUTER.splitlines() if l.startswith("| flat-split-child") or l.startswith("| phase-split-sub-orchestrator")}
    flat = rows["flat-split-child"].split("|")
    phase = rows["phase-split-sub-orchestrator"].split("|")
    assert "Flat Usage Validation Step" in flat[3] and "Flat Usage Validation Step" in phase[4]
    measure = (ROOT / "scripts" / "tests" / "measure_execute_reads.py").read_text(encoding="utf-8")
    assert '"step-4-usage-validation.md": FLAT,' in measure
    assert '"usage-validation-environment.md": FLAT,' in measure and '"usage-validation-loop.md": FLAT,' in measure


def test_usage_flat_step_3_re_validate_branch():
    step3 = (ROOT / "commands" / "references" / "execute" / "step-3-check-pending.md").read_text(encoding="utf-8")
    assert 'elif [ "$PHASE_MODE" != "true" ]' in step3 and "USAGE_STORED=failing" in step3
    assert "Re-validate branch" in step3 and "counts as the Re-verify block" in step3
