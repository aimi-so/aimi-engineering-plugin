"""Tests for the Phase Usage Validation step reference.

`commands/references/execute/phase-completion-usage-validation.md` carries three
marked bash blocks, `usage-phase-required`, `usage-phase-skip` and
`usage-phase-record`. Each is extracted between its `# <name>:begin` /
`# <name>:end` lines and run under bash and zsh against a stub CLI that logs its
arguments. Every flag the blocks pass is compared with `aimi-cli.sh help` of the
tree under test. The text cases pin the rest of the file and its wiring.
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
STEP = ROOT / "commands" / "references" / "execute" / "phase-completion-usage-validation.md"
TEXT = STEP.read_text(encoding="utf-8")
ROUTER = (ROOT / "commands" / "execute.md").read_text(encoding="utf-8")
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


def run_block(tmp_path, shell, name, preamble, answers):
    """answers: {verb: (exit, stdout)}; any other verb exits 9."""
    log = tmp_path / "cli.log"
    (tmp_path / ".aimi").mkdir(exist_ok=True)
    cases = ""
    for verb, (code, out) in answers.items():
        (tmp_path / ("ans-" + verb)).write_text(out, encoding="utf-8")
        cases += "  %s) cat \"%s\"; exit %d ;;\n" % (verb, tmp_path / ("ans-" + verb), code)
    cli = tmp_path / "stub-cli.sh"
    _exe(cli, 'echo "$*" >> "%s"\ncase "$1" in\n%s  *) exit 9 ;;\nesac\n' % (log, cases))
    script = tmp_path / "block.sh"
    script.write_text('AIMI_CLI="%s"\nAIMI_ROOT="%s"\n' % (cli, tmp_path) + preamble + extract_block(name), encoding="utf-8")
    proc = subprocess.run([shutil.which(shell), str(script)], capture_output=True, text=True, timeout=60)
    calls = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
    return proc, calls


def answer(**over):
    base = {"required": True, "skipKind": None, "reason": "ok", "surfaceSource": "declared", "askUndeclared": False,
            "members": 1, "projects": ["."], "charters": [{"id": "CH-US-001"}, {"id": "CH-US-002"}]}
    base.update(over)
    return json.dumps(base)


REQ = 'FEATURE="feat"\nPHASE_ID="2.1"\n'


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_phase_required_owed_saves_the_answer_and_prints_one_line(tmp_path, shell):
    proc, calls = run_block(tmp_path, shell, "usage-phase-required", REQ,
                            {"usage-validation-required": (0, answer(members=2, projects=["api", "web"]))})
    assert calls == ["usage-validation-required --feature feat --phase 2.1"]
    lines = proc.stdout.splitlines()
    assert lines[0] == ("usage-validation-required: required=true skipKind=none surfaceSource=declared "
                        "members=2 projects=api,web charters=2")
    saved = [l.split(": ", 1)[1] for l in lines if l.startswith("usage-validation-answer: ")]
    assert len(saved) == 1 and Path(saved[0]).parent == tmp_path / ".aimi"
    assert json.loads(Path(saved[0]).read_text())["required"] is True


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_phase_required_not_owed_saves_nothing_and_prints_the_skip(tmp_path, shell):
    ans = answer(required=False, skipKind="not-applicable", reason="nothing to use", surfaceSource="none", askUndeclared=True)
    proc, calls = run_block(tmp_path, shell, "usage-phase-required", REQ, {"usage-validation-required": (0, ans)})
    assert "required=false skipKind=not-applicable surfaceSource=none" in proc.stdout
    assert "usage-validation-skip: kind=not-applicable ask=true reason=nothing to use" in proc.stdout
    assert list((tmp_path / ".aimi").iterdir()) == []


@pytest.mark.parametrize("shell", SHELLS)
@pytest.mark.parametrize("code,out", [(1, ""), (0, ""), (0, '{"required": "yes"}'), (0, "not json")])
def test_usage_phase_required_tooling_failed_releases_the_claim(tmp_path, shell, code, out):
    proc, calls = run_block(tmp_path, shell, "usage-phase-required", REQ,
                            {"usage-validation-required": (code, out), "roadmap-release-claim": (0, "")})
    assert proc.returncode == 1
    assert "usage-validation: tooling-failed" in proc.stdout
    assert calls[-1] == "roadmap-release-claim --feature feat --phase 2.1"
    assert not any(c.startswith("roadmap-record") or c.startswith("roadmap-set-status") for c in calls)
    assert list((tmp_path / ".aimi").iterdir()) == []


def skip_preamble(kind, reason):
    return REQ + 'USAGE_KIND="%s"\nUSAGE_REASON=$(cat <<\'E1\'\n%s\nE1\n)\n' % (kind, reason)


@pytest.mark.parametrize("shell", SHELLS)
@pytest.mark.parametrize("kind", ["not-applicable", "unable-to-evaluate", "disabled-by-operator"])
def test_usage_phase_skip_records_the_answers_own_kind(tmp_path, shell, kind):
    proc, calls = run_block(tmp_path, shell, "usage-phase-skip", skip_preamble(kind, "some $reason here"),
                            {"roadmap-record-usage-validation": (0, "{}")})
    assert calls == ["roadmap-record-usage-validation --feature feat --phase 2.1 --status skipped --kind %s --reason some $reason here" % kind]
    assert proc.stdout == "usage-validation: skipped (%s) — some $reason here\n" % kind


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_phase_skip_a_refused_record_is_tooling_failed(tmp_path, shell):
    proc, calls = run_block(tmp_path, shell, "usage-phase-skip", skip_preamble("not-applicable", "r"),
                            {"roadmap-record-usage-validation": (1, ""), "roadmap-release-claim": (0, "")})
    assert proc.returncode == 1 and "usage-validation: tooling-failed" in proc.stdout
    assert calls[-1] == "roadmap-release-claim --feature feat --phase 2.1"


KEPT = '{"kept": "failing", "usageValidation": {"status": "failing", "reason": "old"}}'


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_phase_skip_a_kept_answer_fails_the_phase_and_releases(tmp_path, shell):
    """An unable-to-evaluate skip over a stored failing record: the writer keeps
    the record and answers `kept`; the block never prints a skipped line, sets
    verification_failed and releases the claim, so no handoff follows."""
    proc, calls = run_block(tmp_path, shell, "usage-phase-skip", skip_preamble("unable-to-evaluate", "no recipe"),
                            {"roadmap-record-usage-validation": (0, KEPT), "roadmap-set-status": (0, ""),
                             "roadmap-release-claim": (0, "")})
    assert proc.returncode == 0
    assert calls == [
        "roadmap-record-usage-validation --feature feat --phase 2.1 --status skipped --kind unable-to-evaluate --reason no recipe",
        "roadmap-set-status --feature feat --phase 2.1 --status verification_failed",
        "roadmap-release-claim --feature feat --phase 2.1",
    ]
    assert proc.stdout == "usage-validation: failing — re-validation could not run (no recipe)\n"


def record_preamble(line, findings="{}", reason="", review_exists=False, tmp_path=None):
    pre = REQ + 'USAGE_LOOP_LINE="%s"\n' % line
    pre += "USAGE_LOOP_FINDINGS=$(cat <<'E1'\n%s\nE1\n)\n" % findings
    pre += "USAGE_LOOP_REASON=$(cat <<'E2'\n%s\nE2\n)\n" % reason
    return pre


def loop_line(outcome, rounds=1, review=".aimi/reviews/r.md", extra=""):
    return ("usage-loop: outcome=%s rounds=%s fixed=1 accepted=2 open=0 unmapped=0 review=%s" % (outcome, rounds, review))


OK = {"roadmap-record-usage-validation": (0, "{}"), "roadmap-set-status": (0, ""), "roadmap-release-claim": (0, "")}
FINDINGS = '{"CH-US-001:2:H1": {"status": "accepted", "reason": "known"}}'


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_phase_record_pass_passes_rounds_findings_and_an_existing_review(tmp_path, shell):
    (tmp_path / ".aimi" / "reviews").mkdir(parents=True)
    (tmp_path / ".aimi" / "reviews" / "r.md").write_text("x")
    proc, calls = run_block(tmp_path, shell, "usage-phase-record", record_preamble(loop_line("pass"), FINDINGS), OK)
    assert calls == ["roadmap-record-usage-validation --feature feat --phase 2.1 --status passed --rounds 1 "
                     "--findings-json %s --review .aimi/reviews/r.md" % FINDINGS]
    assert proc.stdout == "usage-validation: passed — 1 fix round(s), 2 accepted\n"


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_phase_record_pass_omits_empty_findings_and_a_missing_review(tmp_path, shell):
    proc, calls = run_block(tmp_path, shell, "usage-phase-record", record_preamble(loop_line("pass", 0)), OK)
    assert calls == ["roadmap-record-usage-validation --feature feat --phase 2.1 --status passed --rounds 0"]


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_phase_record_fails_records_failing_then_status_then_releases(tmp_path, shell):
    (tmp_path / ".aimi" / "reviews").mkdir(parents=True)
    (tmp_path / ".aimi" / "reviews" / "r.md").write_text("x")
    proc, calls = run_block(tmp_path, shell, "usage-phase-record",
                            record_preamble(loop_line("fails", 2), FINDINGS, "1 blocking bug(s) left open"), OK)
    assert calls == [
        "roadmap-record-usage-validation --feature feat --phase 2.1 --status failing --reason 1 blocking bug(s) left open "
        "--rounds 2 --findings-json %s --review .aimi/reviews/r.md" % FINDINGS,
        "roadmap-set-status --feature feat --phase 2.1 --status verification_failed",
        "roadmap-release-claim --feature feat --phase 2.1",
    ]
    assert "usage-validation-verdict: failing review=.aimi/reviews/r.md" in proc.stdout


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_phase_record_unable_to_evaluate_is_a_skip_with_the_loops_reason(tmp_path, shell):
    proc, calls = run_block(tmp_path, shell, "usage-phase-record",
                            record_preamble(loop_line("unable-to-evaluate", 0), "{}", "no browser"), OK)
    assert calls == ["roadmap-record-usage-validation --feature feat --phase 2.1 --status skipped "
                     "--kind unable-to-evaluate --reason no browser --rounds 0"]
    assert proc.stdout == "usage-validation: skipped (unable-to-evaluate) — no browser\n"


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_phase_record_a_kept_answer_fails_the_phase_and_releases(tmp_path, shell):
    answers = dict(OK)
    answers["roadmap-record-usage-validation"] = (0, KEPT)
    proc, calls = run_block(tmp_path, shell, "usage-phase-record",
                            record_preamble(loop_line("unable-to-evaluate", 0), "{}", "no browser"), answers)
    assert proc.returncode == 0
    assert calls == [
        "roadmap-record-usage-validation --feature feat --phase 2.1 --status skipped "
        "--kind unable-to-evaluate --reason no browser --rounds 0",
        "roadmap-set-status --feature feat --phase 2.1 --status verification_failed",
        "roadmap-release-claim --feature feat --phase 2.1",
    ]
    assert proc.stdout == "usage-validation: failing — re-validation could not run (no browser)\n"
    assert "skipped" not in proc.stdout


@pytest.mark.parametrize("shell", SHELLS)
@pytest.mark.parametrize("outcome", ["tooling-failed", "banana", ""])
def test_usage_phase_record_any_other_outcome_records_nothing_and_releases(tmp_path, shell, outcome):
    proc, calls = run_block(tmp_path, shell, "usage-phase-record", record_preamble(loop_line(outcome)), OK)
    assert calls == ["roadmap-release-claim --feature feat --phase 2.1"]
    assert "usage-validation: tooling-failed" in proc.stdout and proc.returncode == 1


@pytest.mark.parametrize("shell", SHELLS)
@pytest.mark.parametrize("outcome", ["pass", "fails", "unable-to-evaluate"])
def test_usage_phase_record_a_refused_record_is_tooling_failed_never_recorded(tmp_path, shell, outcome):
    answers = dict(OK)
    answers["roadmap-record-usage-validation"] = (1, "")
    proc, calls = run_block(tmp_path, shell, "usage-phase-record", record_preamble(loop_line(outcome), "{}", "why"), answers)
    assert proc.returncode == 1 and "usage-validation: tooling-failed" in proc.stdout
    assert calls[-1] == "roadmap-release-claim --feature feat --phase 2.1"
    assert not any(c.startswith("roadmap-set-status") for c in calls)


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_phase_record_reads_the_line_by_field_name(tmp_path, shell):
    line = "usage-loop: review= open=0 rounds=2 outcome=pass accepted=1 fixed=0 unmapped=0"
    proc, calls = run_block(tmp_path, shell, "usage-phase-record", record_preamble(line), OK)
    assert calls == ["roadmap-record-usage-validation --feature feat --phase 2.1 --status passed --rounds 2"]


def _help_flags(verb):
    text = subprocess.run(["bash", str(CLI), "help"], capture_output=True, text=True, timeout=60).stdout
    lines = [l for l in text.splitlines() if l.startswith("    " + verb + " --")]
    assert lines, verb
    return set(re.findall(r"--[a-z][a-z-]*", lines[0]))


@pytest.mark.parametrize("verb", ["usage-validation-required", "roadmap-record-usage-validation", "roadmap-set-status",
                                  "roadmap-release-claim", "roadmap-get"])
def test_usage_phase_every_flag_passed_is_one_the_cli_help_lists(verb):
    help_flags = _help_flags(verb)
    used = set()
    for line in TEXT.splitlines():
        if verb in line and ('"$AIMI_CLI"' in line):
            used |= set(re.findall(r"--[a-z][a-z-]*", line))
    assert used, verb
    assert used <= help_flags, (verb, used - help_flags)


def test_usage_phase_header_anchor_and_size():
    assert TEXT.startswith("# Execute: Phase Completion: Phase Usage Validation\n")
    assert "> Loaded by `commands/execute.md` when its `Applies when:` condition holds." in TEXT
    assert "user-communication.md" in TEXT.split("### Phase Usage Validation")[0]
    assert "### Phase Usage Validation" in TEXT
    assert len(TEXT.encode("utf-8")) <= 16384


def test_usage_phase_never_writes_the_handoff_or_completes():
    assert "roadmap-write-handoff" not in TEXT and "--status completed" not in TEXT
    assert "Never write `handoff.md`" in TEXT
    assert "usage-validation-environment.md" not in TEXT and "usage-validation-loop.md" not in TEXT
    assert "Usage Validation Environment" in TEXT and "Usage Validation Loop" in TEXT
    assert "project-groups" in TEXT.split("#### Never")[1]
    assert "PHASE_SPLIT_MODE" not in TEXT.split("#### Never")[0].replace("never reads `PHASE_SPLIT_MODE`", "")


def test_usage_phase_run_key_restart_and_teardown_rules():
    assert "tr . -" in TEXT and "-phase-" in TEXT
    assert "status=failing" in TEXT and "USAGE_RESTART" in TEXT
    assert "PHASE_BRANCH" in TEXT and "Tear Down on every outcome except `fails`" in TEXT
    assert "usage-env: tooling-failed" in TEXT or "`tooling-failed` is handled as the loop's `tooling-failed`" in TEXT


def test_usage_phase_undeclared_surface_question():
    assert "askUndeclared" in TEXT and "Use **AskUserQuestion**" in TEXT
    assert "agent-mode: usage-surface auto-recorded not-applicable" in TEXT
    assert "no overwrite" in TEXT and "never asked about" in TEXT


def test_usage_phase_blocks_resolve_cli_with_the_hook_line_and_never_open_a_file_with_jq():
    line = ('AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || '
            'cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)')
    blocks = re.findall(r"```bash\n(.*?)```", TEXT, re.S)
    assert len(blocks) == 4
    for block in blocks:
        assert block.splitlines()[0] == line
        assert re.search(r"jq [^|\n]*\.json", block) is None
        assert "jq -r" not in block.split("\n")[1]
    assert "set --" in extract_block("usage-phase-record")


def test_usage_phase_router_entry_wiring_and_spawned_rows():
    assert ROUTER.count("references/execute/phase-completion-usage-validation.md") == 1
    gate = ROUTER.index("### Phase Visual Gate")
    usage = ROUTER.index("### Phase Usage Validation")
    assert gate < usage < ROUTER.index("### Write Handoff")
    entry = ROUTER[usage : ROUTER.index("### Write Handoff")]
    assert "Applies when:" in entry and "PHASE_MODE" in entry and "SPAWNED_SPLIT_TASK" in entry and "Covers:" in entry
    assert "the six" in ROUTER and "the five Phase Completion" not in ROUTER
    rows = [l for l in ROUTER.splitlines() if l.startswith("| flat-split-child") or l.startswith("| phase-split-sub-orchestrator")]
    assert len(rows) == 2 and all("Phase Visual Gate; Phase Usage Validation; Write Handoff" in r for r in rows)
    measure = (ROOT / "scripts" / "tests" / "measure_execute_reads.py").read_text(encoding="utf-8")
    assert '"phase-completion-usage-validation.md": PHASES,' in measure


def test_usage_phase_visual_gate_falls_through_to_the_usage_step():
    gate = (ROOT / "commands" / "references" / "execute" / "phase-completion-visual-gate.md").read_text(encoding="utf-8")
    assert gate.count("Phase Usage Validation") == 4
    assert len(gate.encode("utf-8")) <= 16384


def test_usage_phase_handoff_carries_the_two_locked_lines():
    text = (ROOT / "commands" / "references" / "execute" / "phase-completion-handoff-and-mark.md").read_text(encoding="utf-8")
    assert "`usage-validation: <status> — <reason>`" in text and "usage-validation-stale:" in text
    assert "**Eleven tokens in this payload are locked tokens" in text and "Nine tokens" not in text


WTM = ROOT / "skills" / "git-worktree" / "scripts" / "worktree-manager.sh"


def _git(cwd, *args):
    return subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True, timeout=60)


def _phase_container_repo(tmp_path, branch="feat/pb"):
    """A throwaway repository whose PHASE_BRANCH is checked out in its phase
    container, `<toplevel>/.worktrees/<branch>`, the way Step 1.7 leaves it."""
    repo = tmp_path / "repo"
    repo.mkdir()
    for args in (("init", "-q", "-b", "main"), ("config", "user.email", "t@example.com"),
                 ("config", "user.name", "t"), ("config", "commit.gpgsign", "false")):
        assert _git(repo, *args).returncode == 0
    (repo / ".gitignore").write_text(".worktrees/\n.aimi/\n", encoding="utf-8")
    (repo / "a.txt").write_text("a\n", encoding="utf-8")
    assert _git(repo, "add", ".").returncode == 0
    assert _git(repo, "commit", "-q", "-m", "init").returncode == 0
    made = subprocess.run(["bash", str(WTM), "create", branch, "--from", "main"], cwd=repo,
                          capture_output=True, text=True, timeout=120, input="")
    assert made.returncode == 0, made.stdout + made.stderr
    assert (repo / ".worktrees" / branch / ".git").exists()
    return repo


def _stored_exec_lines(tmp_path, repo, branch):
    (repo / ".aimi").mkdir(exist_ok=True)
    answer_file = repo / ".aimi" / "usage-required-x"
    answer_file.write_text(answer(projects=["."]), encoding="utf-8")
    stub = tmp_path / "stub-cli.sh"
    _exe(stub, 'echo "{}"\n')
    script = tmp_path / "stored.sh"
    script.write_text(
        'AIMI_CLI="%s"\nFEATURE="feat"\nPHASE_ID="1"\nAIMI_ROOT="%s"\nPHASE_BRANCH="%s"\nUSAGE_ANSWER_FILE="%s"\n'
        % (stub, repo, branch, answer_file) + extract_block("usage-phase-stored"),
        encoding="utf-8",
    )
    proc = subprocess.run(["bash", str(script)], capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, proc.stderr
    return [l for l in proc.stdout.splitlines() if l.startswith("usage-exec: ")]


def test_usage_phase_exec_root_is_the_phase_container_not_the_toplevel(tmp_path):
    repo = _phase_container_repo(tmp_path)
    lines = _stored_exec_lines(tmp_path, repo, "feat/pb")
    top = _git(repo, "rev-parse", "--show-toplevel").stdout.strip()
    assert lines == ["usage-exec: project=. root=%s/.worktrees/feat/pb branch=feat/pb" % top]


def test_usage_phase_a_fix_round_merges_from_the_printed_exec_root(tmp_path):
    """The Usage Validation Loop cds to EXEC_ROOT, creates the fix worktree
    --from EXEC_BRANCH and runs merge-all --into EXEC_BRANCH. From the
    repository's toplevel git refuses the checkout (the branch is checked out in
    the phase container); from the printed root the merge lands."""
    branch = "feat/pb"
    repo = _phase_container_repo(tmp_path, branch)
    line = _stored_exec_lines(tmp_path, repo, branch)[0]
    fields = dict(f.split("=", 1) for f in line.split(" ")[1:])
    exec_root, exec_branch = fields["root"], fields["branch"]
    name = exec_branch + "-usagefix-r1"

    def wtm(cwd, *args):
        return subprocess.run(["bash", str(WTM), *args], cwd=cwd, capture_output=True, text=True,
                              timeout=120, input="")

    made = wtm(exec_root, "create", name, "--from", exec_branch)
    assert made.returncode == 0, made.stdout + made.stderr
    fix_dir = Path(exec_root) / ".worktrees" / name
    (fix_dir / "fix.txt").write_text("fixed\n", encoding="utf-8")
    assert _git(fix_dir, "add", "fix.txt").returncode == 0
    assert _git(fix_dir, "commit", "-q", "-m", "fix").returncode == 0

    refused = wtm(repo, "merge-all", name, "--into", exec_branch)
    assert refused.returncode != 0

    merged = wtm(exec_root, "merge-all", name, "--subject-for", name, "Merge usage fixes", "--into", exec_branch)
    assert merged.returncode == 0, merged.stdout + merged.stderr
    assert _git(repo, "show", exec_branch + ":fix.txt").stdout == "fixed\n"
