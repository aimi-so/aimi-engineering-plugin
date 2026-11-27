"""Tests for the Unverified Screen Stop step of /aimi:execute (US-009).

The marked `unverified-screens` block of
commands/references/execute/run-end-unverified-screens.md is extracted and run
under bash and zsh against a stub $AIMI_CLI that answers `unverified-screens`
and `detect-interactivity` from canned values. The stub never reads a real
tasks file, and the aimi-cli.sh the flags are compared with is the one of the
tree under test, never the cli-path cache. The text cases pin the step file,
the router entry and the three call sites.
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
STEP = (EXEC / "run-end-unverified-screens.md").read_text(encoding="utf-8")
STEP5 = (EXEC / "step-5-completion.md").read_text(encoding="utf-8")
PHASE_PR = (EXEC / "phase-completion-offer-pull-request.md").read_text(encoding="utf-8")
ROUTER = (ROOT / "commands" / "execute.md").read_text(encoding="utf-8")
CLI = ROOT / "scripts" / "aimi-cli.sh"
SHELLS = [s for s in ("bash", "zsh") if shutil.which(s)]
HEADING = "Unverified Screen Stop"


def block(text, name):
    lines = text.splitlines()
    begin = [i for i, l in enumerate(lines) if l.strip() == "# %s:begin" % name]
    end = [i for i, l in enumerate(lines) if l.strip() == "# %s:end" % name]
    assert len(begin) == 1 and len(end) == 1 and begin[0] < end[0]
    return "\n".join(lines[begin[0] + 1 : end[0]]) + "\n"


def make_stub(tmp, answer, mode="picker"):
    """answer: ('json', obj) | ('raw', text) | ('exit', code), for unverified-screens;
    mode: what detect-interactivity prints."""
    kind, val = answer
    if kind == "exit":
        body = "exit %d" % val
    else:
        f = tmp / "answer.out"
        f.write_text(json.dumps(val) if kind == "json" else val, encoding="utf-8")
        body = 'cat "%s"; exit 0' % f
    stub = tmp / "stub-cli.sh"
    stub.write_text(
        "#!/bin/sh\n"
        'echo "$*" >> "%s"\n' % (tmp / "cli.log")
        + 'case "$1" in\n'
        "unverified-screens) %s ;;\n" % body
        + "detect-interactivity) echo %s ;;\n" % mode
        + "*) exit 9 ;; esac\n",
        encoding="utf-8",
    )
    stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
    cfg = tmp / "cfg"
    cfg.mkdir(exist_ok=True)
    (cfg / "cli-path").write_text(str(stub), encoding="utf-8")
    return cfg


def story(sid, title, cause="no-visual-check", visual=None, reason=None, usage=None):
    return {
        "id": sid, "title": title, "project": ".", "cause": cause,
        "visualStatus": visual, "skipReason": reason,
        "usageSkip": usage or {"status": "skipped", "kind": "unable-to-evaluate", "reason": "no browser"},
    }


def answer(stories):
    return {"count": len(stories), "scope": "flat", "feature": None, "phase": None,
            "visualGate": None, "usageValidation": {}, "reason": "x", "stories": stories}


TWO = answer([
    story("US-003", "Login screen"),
    story("US-005", "Settings screen", "visual-not-passed", "skipped", "agent-browser not installed"),
])

FLAT_HEADER = 'PHASE_MODE=false\nFEATURE=""\nPHASE_ID=""\nTASKS_PATH=/x/t.json\n'
PHASE_HEADER = 'PHASE_MODE=true\nFEATURE=feat\nPHASE_ID=2\nTASKS_PATH=""\n'


def run(tmp, shell, header, cfg):
    script = tmp / "block.sh"
    script.write_text(
        'AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-$HOME/.config/aimi}/cli-path")\n'
        + header + block(STEP, "unverified-screens"),
        encoding="utf-8",
    )
    env = dict(os.environ, AIMI_CONFIG_DIR=str(cfg))
    r = subprocess.run([shutil.which(shell), str(script)], capture_output=True, text=True, env=env, timeout=60)
    assert r.returncode == 0, r.stderr
    return r.stdout.splitlines()


def calls(tmp):
    return (tmp / "cli.log").read_text().splitlines()


@pytest.mark.parametrize("shell", SHELLS)
def test_block_count_zero_asks_nothing(tmp_path, shell):
    out = run(tmp_path, shell, FLAT_HEADER, make_stub(tmp_path, ("json", answer([]))))
    assert out == ["unverified-screens: 0", "unverified-screens-stop: none"]
    assert calls(tmp_path) == ["unverified-screens --tasks-file /x/t.json"]


@pytest.mark.parametrize("shell", SHELLS)
def test_block_picker_with_two_stories_asks(tmp_path, shell):
    out = run(tmp_path, shell, FLAT_HEADER, make_stub(tmp_path, ("json", TWO), "picker"))
    lines = [l for l in out if l.startswith("unverified-screen:")]
    assert len(lines) == 2
    assert "US-003 | Login screen | cause=no-visual-check | usage=skipped (unable-to-evaluate)" in lines[0]
    assert "US-005 | Settings screen | cause=visual-not-passed | visual=skipped | skipReason=agent-browser not installed" in lines[1]
    assert "unverified-screens: 2" in out
    assert out[-1] == "unverified-screens-stop: ask"
    assert sum(l.startswith("unverified-screens-stop:") for l in out) == 1


@pytest.mark.parametrize("shell", SHELLS)
def test_block_agent_mode_prints_the_report_marker_and_no_question(tmp_path, shell):
    out = run(tmp_path, shell, FLAT_HEADER, make_stub(tmp_path, ("json", TWO), "agent"))
    assert out[-1] == "unverified-screens-stop: report"
    assert "unverified-screens: 2" in out and sum(l.startswith("unverified-screen:") for l in out) == 2
    assert "unverified-screens-stop: ask" not in out


@pytest.mark.parametrize("shell", SHELLS)
@pytest.mark.parametrize(
    "spec,stage",
    [(("exit", 1), "unverified-screens exited non-zero"), (("raw", ""), "empty answer"), (("raw", "not json{"), "answer is not JSON")],
)
def test_block_unreadable_answer_is_unknown_and_asks_nothing(tmp_path, shell, spec, stage):
    out = run(tmp_path, shell, FLAT_HEADER, make_stub(tmp_path, spec, "picker"))
    assert "unverified-screens: unknown — %s" % stage in out
    assert out[-1] == "unverified-screens-stop: report"
    assert not any(l.startswith("unverified-screens: ") and "unknown" not in l for l in out)
    assert "unverified-screens-stop: ask" not in out
    assert "detect-interactivity" not in " ".join(calls(tmp_path))


@pytest.mark.parametrize("shell", SHELLS)
def test_block_json_without_a_count_is_unknown(tmp_path, shell):
    out = run(tmp_path, shell, FLAT_HEADER, make_stub(tmp_path, ("json", {"stories": []})))
    assert "unverified-screens: unknown — count is not a number" in out
    assert out[-1] == "unverified-screens-stop: report"


@pytest.mark.parametrize("shell", SHELLS)
def test_block_phase_form_passes_feature_and_phase(tmp_path, shell):
    run(tmp_path, shell, PHASE_HEADER, make_stub(tmp_path, ("json", answer([]))))
    assert calls(tmp_path) == ["unverified-screens --feature feat --phase 2"]


@pytest.mark.parametrize("shell", SHELLS)
def test_block_flat_form_passes_tasks_file(tmp_path, shell):
    run(tmp_path, shell, FLAT_HEADER, make_stub(tmp_path, ("json", answer([]))))
    assert calls(tmp_path) == ["unverified-screens --tasks-file /x/t.json"]


def test_block_flags_exist_in_the_tree_cli_help():
    help_text = subprocess.run(["bash", str(CLI), "help"], capture_output=True, text=True, timeout=60).stdout
    used = set()
    for m in re.finditer(r'"\$AIMI_CLI" (unverified-screens|detect-interactivity)([^|)\n]*)', block(STEP, "unverified-screens")):
        for flag in re.findall(r"--[a-z-]+", m.group(2)):
            used.add((m.group(1), flag))
    assert ("unverified-screens", "--feature") in used and ("unverified-screens", "--phase") in used
    assert ("unverified-screens", "--tasks-file") in used
    for verb, flag in used:
        line = [l for l in help_text.splitlines() if l.strip().startswith(verb + " ")]
        assert line and flag in line[0], (verb, flag)


def test_block_shape():
    b = block(STEP, "unverified-screens")
    assert b.count('"$AIMI_CLI" unverified-screens') == 2
    assert not re.search(r"jq[^|\n]*<\s*\S", b)
    resolve = 'AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)'
    i = STEP.index("# unverified-screens:begin")
    assert resolve in STEP[:i][STEP[:i].rindex("```bash"):]


def test_text_stop_is_first_and_the_silent_default():
    q = STEP[STEP.index("## The Question"):]
    assert q.index("A — Stop") < q.index("B — Continue")
    assert "Anything that is not an explicit B" in q and "is Stop: silence is not approval" in q
    assert "Option A** sets `UNVERIFIED_STOP=stop`" in q and "Option B** sets `UNVERIFIED_STOP=continue`" in q
    assert "Adaptive Language Rule" in q


def test_text_unverified_stop_state_is_stated_with_its_readers():
    assert "`UNVERIFIED_STOP` holds `stop` or `continue`" in STEP
    assert "It is `continue` when this step is skipped, when the count is 0" in STEP
    assert "in agent mode" in STEP
    assert "The flat container push, the phase publish question and the inline close each read it" in STEP


def test_text_stop_withholds_publishing_only():
    s = STEP[STEP.index("## Stop and Continue"):STEP.index("## Agent Mode")]
    assert "`PHASE_PUBLISH=none`" in s
    assert "skip the three container steps" in s and "the dev server keeps running" in s
    for form in ("--branch [PHASE_BRANCH]", "--branch [branchName]", "bare `/aimi:open-pr`"):
        assert form in s
    assert "nothing new is written" in s


def test_text_agent_mode_section_never_prints_a_pass_line():
    a = STEP[STEP.index("## Agent Mode"):]
    template = a[a.index("```\n") + 4:]
    template = template[:template.index("```")]
    assert "## Unverified Screen Stories" in template
    assert "screen stories unverified: [N]" in template
    assert "passed" not in template.lower()
    assert "unverified-screens: unknown — [stage]" in a


def test_text_hold_and_phase_mode_ask_no_second_question():
    assert "adds no second question" in STEP
    assert "Step 5 does not ask it again" in STEP
    assert "phase mode ran it at Offer a Pull Request and does not ask again" in STEP5


def test_wiring_router_entry_and_spawned_tasks_rows():
    assert ROUTER.count("\n## %s\n" % HEADING) == 1
    entry = ROUTER[ROUTER.index("## %s\n" % HEADING):]
    entry = entry[:entry.index("\n\n## ", 1)]
    assert "Applies when:" in entry and "(default `UNVERIFIED_STOP=continue`)" in entry
    assert entry.count("Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/run-end-unverified-screens.md in full") == 1
    rows = {l.split("|")[1].strip(): l.split("|") for l in ROUTER.splitlines() if l.startswith("| ") and "SPAWNED_SPLIT_TASK=" in l}
    flat = rows["flat-split-child"]
    sub = rows["phase-split-sub-orchestrator"]
    assert HEADING in [h.strip() for h in flat[3].split(";")]
    assert HEADING in [h.strip() for h in sub[4].split(";")]
    assert HEADING not in flat[4] and HEADING not in sub[3]


def test_wiring_the_three_call_sites_point_at_the_step_file():
    assert STEP5.count("run-end-unverified-screens.md") >= 2
    assert PHASE_PR.count("run-end-unverified-screens.md") >= 1
    assert PHASE_PR.index("run-end-unverified-screens.md") < PHASE_PR.index("#### Select the acting forge account per repository")
    assert "`PHASE_PUBLISH=none`" in PHASE_PR[:PHASE_PR.index("```bash")]
    # the call sites point at the step and never restate its block or question
    for text in (STEP5, PHASE_PR, ROUTER):
        assert "unverified-screens:begin" not in text and "A — Stop" not in text


def test_wiring_step_stays_under_the_shared_ceiling():
    assert len(STEP.encode("utf-8")) <= 16384
