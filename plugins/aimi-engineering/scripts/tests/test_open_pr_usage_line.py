"""/aimi:open-pr carries a failing usage-validation verdict into the PR body.

Step 2g prints the stored verdict on stderr and never blocks. When the verdict
is `failing` it also prints one `usage-pr-line:` line on stdout, and Step 4d
renders that text as the body's first line. Both blocks are extracted from
commands/open-pr.md and run under bash and zsh: Step 2g against a stub CLI,
Step 4d inside a throwaway git repository.
"""

import json
import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

PLUGIN = Path(__file__).resolve().parents[2]
OPEN_PR = (PLUGIN / "commands" / "open-pr.md").read_text(encoding="utf-8")
SHELLS = [s for s in ("bash", "zsh") if shutil.which(s)]


def marked(name):
    lines = OPEN_PR.splitlines()
    begin = [i for i, l in enumerate(lines) if l.strip() == "# %s:begin" % name]
    end = [i for i, l in enumerate(lines) if l.strip() == "# %s:end" % name]
    assert len(begin) == 1 and len(end) == 1
    return "\n".join(lines[begin[0] + 1 : end[0]]) + "\n"


def step_4d_block():
    section = OPEN_PR.split("### 4d.", 1)[1].split("## Step 5:", 1)[0]
    blocks = [part.split("\n```", 1)[0] for part in section.split("```bash\n")[1:]]
    assert len(blocks) == 1
    return blocks[0]


def step_2g(tmp_path, shell, record):
    stub = tmp_path / "stub-cli.sh"
    meta = tmp_path / "meta.json"
    meta.write_text(json.dumps({"deliverableBranch": "feat/x"}), encoding="utf-8")
    uvg = tmp_path / "uvg.json"
    uvg.write_text(json.dumps({"scope": "flat", "feature": None, "phase": None, "record": record}), encoding="utf-8")
    stub.write_text('#!/bin/sh\ncase "$1" in\nmetadata) cat "%s" ;;\nusage-validation-get) cat "%s" ;;\n*) exit 9 ;;\nesac\n'
                    % (meta, uvg), encoding="utf-8")
    stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
    script = tmp_path / "2g.sh"
    script.write_text('AIMI_CLI="%s"\nCURRENT_BRANCH=feat/x\n' % stub + marked("usage-open-pr"), encoding="utf-8")
    proc = subprocess.run([shutil.which(shell), str(script)], capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, proc.stderr
    return proc


def render_body(tmp_path, shell, usage_line):
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    block = step_4d_block()
    placeholder = "[the text after Step 2g's usage-pr-line:, or empty when it printed none]"
    assert block.count(placeholder) == 1
    block = block.replace(placeholder, usage_line)
    preamble = (
        "COMMIT_LOG=$(printf 'h1\\037feat: one\\037a body\\036')\n"
        "DIFF_STAT=' a.txt | 1 +'\nCLOSES_SECTION=''\nINCLUDE_BACKEND_SPEC=0\n"
    )
    script = tmp_path / "4d.sh"
    script.write_text(preamble + block, encoding="utf-8")
    proc = subprocess.run([shutil.which(shell), str(script)], cwd=repo, capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, proc.stderr
    return (repo / ".git" / "aimi-pr-body.md").read_text(encoding="utf-8")


@pytest.mark.parametrize("shell", SHELLS)
def test_a_failing_verdict_prints_one_pr_line_and_still_warns(tmp_path, shell):
    proc = step_2g(tmp_path, shell, {"status": "failing", "reason": "login broken"})
    assert proc.stdout == "usage-pr-line: Usage validation: FAILING — login broken. Re-run /aimi:execute to re-validate.\n"
    assert "Warning: usage validation is FAILING (login broken)" in proc.stderr


@pytest.mark.parametrize("shell", SHELLS)
@pytest.mark.parametrize("record", [{"status": "passed"}, {"status": "skipped", "kind": "not-applicable", "reason": "r"}, None])
def test_any_other_verdict_prints_no_pr_line(tmp_path, shell, record):
    assert step_2g(tmp_path, shell, record).stdout == ""


@pytest.mark.parametrize("shell", SHELLS)
def test_the_pr_line_is_the_first_line_of_the_body(tmp_path, shell):
    line = step_2g(tmp_path, shell, {"status": "failing", "reason": "login broken"}).stdout
    text = line.split("usage-pr-line: ", 1)[1].rstrip("\n")
    body = render_body(tmp_path, shell, text)
    assert body.startswith("Usage validation: FAILING — login broken. Re-run /aimi:execute to re-validate.\n\n## Summary\n")
    assert body.count("Usage validation: FAILING") == 1


@pytest.mark.parametrize("shell", SHELLS)
def test_without_a_pr_line_the_body_is_unchanged(tmp_path, shell):
    body = render_body(tmp_path, shell, "")
    assert body.startswith("## Summary\n") and "Usage validation" not in body
