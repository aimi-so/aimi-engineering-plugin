"""Tests for the usage-validation gate wiring of US-013.

Three marked blocks are extracted from the command text and run under bash and
zsh against a stub $AIMI_CLI that answers `metadata` and `roadmap-get` from
canned files: `usage-gate` (step-5-completion.md), `usage-open-pr`
(open-pr.md) and `usage-rollup` (step-0-9-aggregated-completion.md). The stub
never reads a real tasks file, and the aimi-cli.sh the flags are compared with
is the one of the tree under test, never the cli-path cache.
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
EXEC = ROOT / "commands" / "references" / "execute"
STEP5 = (EXEC / "step-5-completion.md").read_text(encoding="utf-8")
ROLLUP = (EXEC / "step-0-9-aggregated-completion.md").read_text(encoding="utf-8")
OPEN_PR = (ROOT / "commands" / "open-pr.md").read_text(encoding="utf-8")
PUBLISH = (ROOT / "commands" / "references" / "publish-confirmation.md").read_text(encoding="utf-8")
CLI = ROOT / "scripts" / "aimi-cli.sh"
SHELLS = [s for s in ("bash", "zsh") if shutil.which(s)]


def block(text, name):
    lines = text.splitlines()
    begin = [i for i, l in enumerate(lines) if l.strip() == "# %s:begin" % name]
    end = [i for i, l in enumerate(lines) if l.strip() == "# %s:end" % name]
    assert len(begin) == 1 and len(end) == 1 and begin[0] < end[0]
    return "\n".join(lines[begin[0] + 1 : end[0]]) + "\n"


def make_stub(tmp, meta, roadmap, per_file=None):
    """meta/roadmap: ('json', obj) | ('raw', text) | ('exit', code)."""
    def emit(name, spec):
        kind, val = spec
        if kind == "exit":
            return "exit %d" % val
        f = tmp / (name + ".out")
        f.write_text(json.dumps(val) if kind == "json" else val, encoding="utf-8")
        return 'cat "%s"; exit 0' % f
    cases = []
    for fname, spec in (per_file or {}).items():
        cases.append('*%s) %s ;;' % (fname, emit("m-" + fname, spec)))
    cases.append("*) %s ;;" % emit("meta", meta))
    stub = tmp / "stub-cli.sh"
    stub.write_text(
        "#!/bin/sh\n"
        'case "$1" in\n'
        "metadata)\n"
        '  last=""; for a in "$@"; do last="$a"; done\n'
        '  case "$last" in\n' + "\n".join(cases) + "\n  esac ;;\n"
        "roadmap-get) %s ;;\n" % emit("roadmap", roadmap)
        + "*) exit 9 ;; esac\n",
        encoding="utf-8",
    )
    stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
    cfg = tmp / "cfg"
    cfg.mkdir(exist_ok=True)
    (cfg / "cli-path").write_text(str(stub), encoding="utf-8")
    return cfg


def run(tmp, shell, header, body, cfg):
    script = tmp / "block.sh"
    script.write_text(
        'AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-$HOME/.config/aimi}/cli-path")\n' + header + body,
        encoding="utf-8",
    )
    env = dict(os.environ, AIMI_CONFIG_DIR=str(cfg))
    r = subprocess.run([shutil.which(shell), str(script)], capture_output=True, text=True, env=env, timeout=60)
    return r.stdout, r.stderr


GATE_FLAT = 'USAGE_MODE=flat\nUSAGE_TASKS_FILE=/x/t.json\nUSAGE_FEATURE=""\nUSAGE_PHASE_ID=""\n'
GATE_PHASE = 'USAGE_MODE=phase\nUSAGE_TASKS_FILE=/x/t.json\nUSAGE_FEATURE=feat\nUSAGE_PHASE_ID=1\n'


def gate(tmp_path, shell, header, rec=None, meta_spec=None, roadmap_spec=None):
    body = {"usageValidation": rec} if rec is not None else {}
    cfg = make_stub(tmp_path, meta_spec or ("json", body), roadmap_spec or ("json", body))
    out, _ = run(tmp_path, shell, header, block(STEP5, "usage-gate"), cfg)
    return out.splitlines()


FAILING = {
    "status": "failing", "reason": "login broken", "rounds": 2, "review": ".aimi/reviews/r.md",
    "findings": {"a": {"status": "open"}, "b": {"status": "fixed"}, "c": {"status": "open"}},
}


@pytest.mark.parametrize("shell", SHELLS)
@pytest.mark.parametrize("header", [GATE_FLAT, GATE_PHASE])
def test_usage_gate_failing_holds(tmp_path, shell, header):
    out = gate(tmp_path, shell, header, FAILING)
    assert "usage-validation: failing — login broken" in out
    assert "usage-validation-detail: rounds=2 open=2 review=.aimi/reviews/r.md" in out
    assert out[-1] == "usage-validation-gate: hold"
    assert sum(l.startswith("usage-validation-gate:") for l in out) == 1


@pytest.mark.parametrize("shell", SHELLS)
@pytest.mark.parametrize("header", [GATE_FLAT, GATE_PHASE])
def test_usage_gate_passed_goes(tmp_path, shell, header):
    out = gate(tmp_path, shell, header, {"status": "passed", "rounds": 0})
    assert "usage-validation: passed" in out
    assert out[-1] == "usage-validation-gate: go"


@pytest.mark.parametrize("shell", SHELLS)
@pytest.mark.parametrize("kind", ["not-applicable", "disabled-by-operator", "unable-to-evaluate", "undeclared-surface"])
@pytest.mark.parametrize("header", [GATE_FLAT, GATE_PHASE])
def test_usage_gate_skipped_of_any_kind_goes(tmp_path, shell, kind, header):
    out = gate(tmp_path, shell, header, {"status": "skipped", "kind": kind, "reason": "why"})
    assert "usage-validation: skipped (%s) — why" % kind in out
    assert out[-1] == "usage-validation-gate: go"


@pytest.mark.parametrize("shell", SHELLS)
@pytest.mark.parametrize("header", [GATE_FLAT, GATE_PHASE])
def test_usage_gate_absent_record_goes(tmp_path, shell, header):
    out = gate(tmp_path, shell, header, None)
    assert "usage-validation: not recorded" in out
    assert out[-1] == "usage-validation-gate: go"


@pytest.mark.parametrize("shell", SHELLS)
@pytest.mark.parametrize("header,spec_name", [(GATE_FLAT, "meta_spec"), (GATE_PHASE, "roadmap_spec")])
@pytest.mark.parametrize("spec,stage", [(("exit", 1), "exited non-zero"), (("raw", ""), "empty answer"), (("raw", "not json{"), "not JSON")])
def test_usage_gate_unreadable_record_is_unknown_and_never_passed(tmp_path, shell, header, spec_name, spec, stage):
    out = gate(tmp_path, shell, header, None, **{spec_name: spec})
    line = [l for l in out if l.startswith("usage-validation:")]
    assert len(line) == 1 and line[0].startswith("usage-validation: unknown — ") and stage in line[0]
    assert "passed" not in line[0]
    assert out[-1] == "usage-validation-gate: go"


def test_usage_gate_block_shape():
    b = block(STEP5, "usage-gate")
    assert "jq" in b and not re.search(r"jq[^|\n]*<\s*\S", b)
    assert "metadata --tasks-file" in b.replace('"$AIMI_CLI" ', "") or '"$AIMI_CLI" metadata --tasks-file' in b
    assert 'roadmap-get --feature "$USAGE_FEATURE" --phase "$USAGE_PHASE_ID"' in b
    resolve = 'AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)'
    i = STEP5.index("# usage-gate:begin")
    assert resolve in STEP5[:i][STEP5[:i].rindex("```bash"):]
    assert STEP5.index("# usage-gate:begin") < STEP5.index("**When `usage-validation-gate: go` and `CONTAINER_MODE=true`:**")


def test_step5_text_cases():
    assert "## Usage Validation" in STEP5
    assert "usage-validation-stale:" in STEP5
    assert "Re-run `/aimi:execute` to validate again" in STEP5
    held = STEP5[STEP5.index("**When `usage-validation-gate: hold`:** usage validation is failing"):]
    assert "/aimi:open-pr --branch [branchName]" in held and "Warning: usage validation is failing" in held
    assert len(STEP5.encode("utf-8")) <= 36864


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_rollup_holds_on_any_failing_record(tmp_path, shell):
    plan = "\n".join(json.dumps({"file": f}) for f in ("/p/a.json", "/p/b.json", "/p/c.json"))
    cfg = make_stub(
        tmp_path, ("json", {}), ("json", {}),
        per_file={"a.json": ("json", {"usageValidation": {"status": "passed"}}),
                  "b.json": ("json", {"usageValidation": {"status": "failing"}}),
                  "c.json": ("exit", 1)},
    )
    header = "SPLIT_PLAN='%s'\n" % plan
    out, _ = run(tmp_path, shell, header, block(ROLLUP, "usage-rollup"), cfg)
    lines = out.splitlines()
    assert "usage-validation: /p/a.json\tpassed" in lines
    assert "usage-validation: /p/c.json\tunknown" in lines
    assert lines.count("usage-rollup-failing: /p/b.json\t/aimi:execute /p/b.json") == 1
    assert lines[-1] == "usage-rollup-gate: hold"


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_rollup_go_without_failing_record(tmp_path, shell):
    plan = json.dumps({"file": "/p/a.json"})
    cfg = make_stub(tmp_path, ("json", {"usageValidation": {"status": "skipped", "kind": "unable-to-evaluate"}}), ("json", {}))
    out, _ = run(tmp_path, shell, "SPLIT_PLAN='%s'\n" % plan, block(ROLLUP, "usage-rollup"), cfg)
    assert out.splitlines()[-1] == "usage-rollup-gate: go"
    assert "usage-rollup-failing" not in out


def test_rollup_text_cases():
    assert "never names a re-run of the parent plan" in ROLLUP
    assert "kept: $SPLIT_BRANCH worktree" in ROLLUP
    assert "--keep-branch" in ROLLUP


OPEN_PR_HEADER = 'CURRENT_BRANCH=feat/x\n'


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_open_pr_flat_failing_warns_on_stderr(tmp_path, shell):
    meta = {"deliverableBranch": "feat/x", "usageValidation": {"status": "failing", "reason": "broken"}}
    cfg = make_stub(tmp_path, ("json", meta), ("json", {}))
    out, err = run(tmp_path, shell, OPEN_PR_HEADER, block(OPEN_PR, "usage-open-pr"), cfg)
    assert out == ""
    assert "Warning: usage validation is FAILING (broken)" in err and "/aimi:execute" in err


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_open_pr_phase_reads_roadmap_record(tmp_path, shell):
    meta = {"deliverableBranch": "feat/x", "roadmapPath": ".aimi/tasks/feat/roadmap.json", "phase": {"id": 2}}
    cfg = make_stub(tmp_path, ("json", meta), ("json", {"usageValidation": {"status": "passed"}}))
    _, err = run(tmp_path, shell, OPEN_PR_HEADER, block(OPEN_PR, "usage-open-pr"), cfg)
    assert "usage-validation: passed" in err and "FAILING" not in err


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_open_pr_silent_for_other_branch_or_no_record(tmp_path, shell):
    other = {"deliverableBranch": "feat/other", "usageValidation": {"status": "failing"}}
    cfg = make_stub(tmp_path, ("json", other), ("json", {}))
    assert run(tmp_path, shell, OPEN_PR_HEADER, block(OPEN_PR, "usage-open-pr"), cfg) == ("", "")
    none = {"deliverableBranch": "feat/x"}
    cfg = make_stub(tmp_path, ("json", none), ("json", {}))
    assert run(tmp_path, shell, OPEN_PR_HEADER, block(OPEN_PR, "usage-open-pr"), cfg) == ("", "")


def test_open_pr_step_sits_after_2f_and_never_stops():
    assert OPEN_PR.index("### 2f.") < OPEN_PR.index("# usage-open-pr:begin") < OPEN_PR.index("## Step 4:")
    b = block(OPEN_PR, "usage-open-pr")
    assert "exit" not in b and "--merge" not in b
    assert len(OPEN_PR.encode("utf-8")) <= 94208


def test_publish_confirmation_exception_in_prose_only():
    assert "The Exception to Always Name /aimi:open-pr" in PUBLISH
    assert "```" not in PUBLISH and "AskUserQuestion" not in PUBLISH
    assert "no exception" in PUBLISH.replace("is no exception", "no exception")


def test_every_flag_the_blocks_pass_is_in_the_tree_cli_help():
    help_text = subprocess.run(["bash", str(CLI), "help"], capture_output=True, text=True, timeout=60).stdout
    verbs = {"metadata": ["--tasks-file", "--with-deliverable-branch"], "roadmap-get": ["--feature", "--phase"]}
    used = set()
    for text, name in ((STEP5, "usage-gate"), (OPEN_PR, "usage-open-pr"), (ROLLUP, "usage-rollup")):
        for m in re.finditer(r'"\$AIMI_CLI" (metadata|roadmap-get)([^|)\n]*)', block(text, name)):
            for flag in re.findall(r"--[a-z-]+", m.group(2)):
                used.add((m.group(1), flag))
    assert used
    for verb, flag in used:
        line = [l for l in help_text.splitlines() if l.strip().startswith(verb + " ")]
        assert line and flag in line[0], (verb, flag)
