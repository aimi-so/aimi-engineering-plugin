"""Pins where /aimi:execute writes known-gap files and which ones it reports.

Step 4 used to write `.aimi/known-gaps/...` relative to the CWD right after it
cd'd into the container, so in container and phase mode the gap file landed
inside the container and was deleted with it. Step 5 used to print every file
in the shared `.aimi/known-gaps/` directory, every plan's, under "Known Gaps".
Both now go through `$AIMI_ROOT`, and Step 5 keeps only this plan's
`-<PLAN_DISC>.md` files.
"""

import re
import shutil
import subprocess
from pathlib import Path

import pytest

PLUGIN = Path(__file__).resolve().parents[2]
EXECUTE = PLUGIN / "commands" / "references" / "execute"
SHELLS = [s for s in ("bash", "zsh") if shutil.which(s)]
STEM = "2026-10-27-demo-tasks"


def step5_block():
    text = (EXECUTE / "step-5-completion.md").read_text(encoding="utf-8")
    after = text.split("Aggregate this plan's known-gap files", 1)[1]
    return after.split("```bash\n", 1)[1].split("\n```", 1)[0]


def step4_gap_lines():
    text = (EXECUTE / "step-4-wave-execution-loop.md").read_text(encoding="utf-8")
    start = text.index("# --- Extract knownGaps")
    block = text[start:text.index("VERIFY_EVIDENCE_JSON", start)]
    return block


def fill(script, root, tasks_file):
    script = re.sub(r'^(\s*)AIMI_ROOT="\[[^\]]*\]"', lambda m: f'{m.group(1)}AIMI_ROOT="{root}"', script, flags=re.M)
    return re.sub(r'^(\s*)WAVE_TASKS_FILE="\[[^\]]*\]"', lambda m: f'{m.group(1)}WAVE_TASKS_FILE="{tasks_file}"', script, flags=re.M)


@pytest.fixture
def layout(tmp_path):
    root = tmp_path / "proj"
    gaps = root / ".aimi" / "known-gaps"
    gaps.mkdir(parents=True)
    (gaps / f"2026-10-27-US-001-{STEM}.md").write_text("mine one\n")
    (gaps / f"2026-10-28-US-003-{STEM}.md").write_text("mine three\n")
    (gaps / "2026-10-27-US-001-other-plan-tasks.md").write_text("theirs\n")
    (gaps / "2026-09-01-US-002.md").write_text("legacy\n")
    container = root / ".worktrees" / "feat" / "x"
    container.mkdir(parents=True)
    return root, container


@pytest.mark.parametrize("shell", SHELLS)
def test_step5_prints_only_this_plans_gaps_from_any_cwd(shell, layout):
    root, container = layout
    script = fill(step5_block(), root, str(root / ".aimi" / "tasks" / f"{STEM}.json"))
    res = subprocess.run([shell, "-c", script], cwd=container, capture_output=True, text=True)
    assert res.returncode == 0, res.stderr
    assert "## Known Gaps" in res.stdout
    assert "mine one" in res.stdout and "mine three" in res.stdout
    assert "theirs" not in res.stdout and "legacy" not in res.stdout
    assert re.findall(r"^### (.+)$", res.stdout, flags=re.M) == ["US-001", "US-003"]


@pytest.mark.parametrize("shell", SHELLS)
def test_step5_prints_nothing_when_this_plan_has_no_gaps(shell, layout):
    root, container = layout
    script = fill(step5_block(), root, str(root / ".aimi" / "tasks" / "2026-11-01-quiet-tasks.json"))
    res = subprocess.run([shell, "-c", script], cwd=container, capture_output=True, text=True)
    assert res.returncode == 0, res.stderr
    assert res.stdout.strip() == ""


def test_step4_writes_gaps_under_aimi_root_not_the_cwd():
    block = step4_gap_lines()
    assert 'mkdir -p "$AIMI_ROOT/.aimi/known-gaps"' in block
    assert 'GAP_FILE="$AIMI_ROOT/.aimi/known-gaps/' in block
    assert not re.search(r'mkdir -p \.aimi/', block)
    assert not re.search(r'GAP_FILE="\.aimi/', block)


def test_step4_gap_lines_land_under_the_root_when_run_from_the_container(layout):
    root, container = layout
    block = step4_gap_lines()
    keep = [l.strip() for l in block.splitlines()
            if re.match(r'\s*(AIMI_ROOT=|mkdir -p|GAP_DATE=|GAP_FILE=|printf .*GAP_FILE)', l)]
    script = fill("\n".join(keep), root, "")
    script = script.replace("[full_story.id]", "US-009").replace("[PLAN_DISC]", STEM)
    script = 'WORKER_GAPS="a gap"\n' + script
    res = subprocess.run(["bash", "-c", script], cwd=container, capture_output=True, text=True)
    assert res.returncode == 0, res.stderr
    assert list((root / ".aimi" / "known-gaps").glob(f"*-US-009-{STEM}.md"))
    assert not (container / ".aimi").exists()
