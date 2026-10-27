"""Runs the wave block of /aimi:execute's Split File Waves entry.

The block is extracted from `step-0-9-split-waves.md` and run under bash against
a stub `split-detect` that answers a canned member list, so the block that ships
is the block that is measured.
"""

import json
import shutil
import subprocess
from pathlib import Path

import pytest

PLUGIN = Path(__file__).resolve().parents[2]
WAVES = PLUGIN / "commands" / "references" / "execute" / "step-0-9-split-waves.md"
SHELLS = [s for s in ("bash", "zsh") if shutil.which(s)]

STUB = """#!/bin/sh
printf '%s\\n' "$@" > "$STUB_ARGS"
cat "$STUB_ANSWER"
"""


def wave_block():
    text = WAVES.read_text(encoding="utf-8")
    return text.split("```bash\n", 1)[1].split("\n```", 1)[0]


def member(name, after=(), active=True):
    return {
        "path": "/proj/.aimi/tasks/" + name,
        "project": name,
        "branchName": None,
        "active": active,
        "after": ["/proj/.aimi/tasks/" + a for a in after],
    }


def run_block(tmp_path, members, scope_dir=None, shell="bash"):
    cfg = tmp_path / "cfg"
    cfg.mkdir(exist_ok=True)
    stub = tmp_path / "stub-cli.sh"
    stub.write_text(STUB)
    stub.chmod(0o755)
    (cfg / "cli-path").write_text(str(stub))
    answer = tmp_path / "answer.json"
    answer.write_text(json.dumps({"mode": "project-split", "members": members}))
    args = tmp_path / "args.txt"
    script = wave_block()
    if scope_dir is not None:
        assert 'WAVE_SCOPE_DIR=""' in script
        script = script.replace('WAVE_SCOPE_DIR=""', 'WAVE_SCOPE_DIR="%s"' % scope_dir)
    env = {
        "PATH": "/usr/bin:/bin",
        "HOME": str(tmp_path),
        "AIMI_CONFIG_DIR": str(cfg),
        "STUB_ANSWER": str(answer),
        "STUB_ARGS": str(args),
    }
    proc = subprocess.run([shell, "-c", script], cwd=tmp_path, env=env, capture_output=True, text=True)
    lines = [json.loads(x) for x in proc.stdout.splitlines() if x.strip()]
    called = args.read_text().split() if args.exists() else []
    return proc, lines, called


def by_wave(lines):
    out = {}
    for rec in lines:
        out.setdefault(rec["wave"], []).append(Path(rec["file"]).name)
    return {k: sorted(v) for k, v in out.items()}


@pytest.mark.parametrize("shell", SHELLS)
def test_no_after_gives_one_wave(tmp_path, shell):
    proc, lines, _ = run_block(tmp_path, [member("a.json"), member("b.json"), member("c.json")], shell=shell)
    assert proc.returncode == 0, proc.stderr
    assert by_wave(lines) == {1: ["a.json", "b.json", "c.json"]}


@pytest.mark.parametrize("shell", SHELLS)
def test_chain_gives_three_waves(tmp_path, shell):
    members = [member("a.json"), member("b.json", after=["a.json"]), member("c.json", after=["b.json"])]
    proc, lines, _ = run_block(tmp_path, members, shell=shell)
    assert proc.returncode == 0, proc.stderr
    assert by_wave(lines) == {1: ["a.json"], 2: ["b.json"], 3: ["c.json"]}


@pytest.mark.parametrize("shell", SHELLS)
def test_diamond_gives_three_waves_with_the_middle_pair_together(tmp_path, shell):
    members = [
        member("a.json"),
        member("b.json", after=["a.json"]),
        member("c.json", after=["a.json"]),
        member("d.json", after=["b.json", "c.json"]),
    ]
    proc, lines, _ = run_block(tmp_path, members, shell=shell)
    assert proc.returncode == 0, proc.stderr
    assert by_wave(lines) == {1: ["a.json"], 2: ["b.json", "c.json"], 3: ["d.json"]}


def test_every_printed_line_is_a_wave_and_file_object(tmp_path):
    proc, lines, _ = run_block(tmp_path, [member("a.json"), member("b.json", after=["a.json"])])
    assert proc.returncode == 0, proc.stderr
    assert all(sorted(rec) == ["file", "wave"] for rec in lines)
    assert [rec["file"] for rec in lines] == ["/proj/.aimi/tasks/a.json", "/proj/.aimi/tasks/b.json"]


def test_inactive_predecessor_is_satisfied(tmp_path):
    members = [member("a.json", active=False), member("b.json", after=["a.json"])]
    proc, lines, _ = run_block(tmp_path, members)
    assert proc.returncode == 0, proc.stderr
    assert by_wave(lines) == {1: ["b.json"]}


def test_after_naming_no_member_is_satisfied(tmp_path):
    members = [member("b.json", after=["gone.json"])]
    proc, lines, _ = run_block(tmp_path, members)
    assert proc.returncode == 0, proc.stderr
    assert by_wave(lines) == {1: ["b.json"]}


def test_after_entries_match_by_basename(tmp_path):
    members = [member("a.json"), member("b.json")]
    members[1]["after"] = ["/elsewhere/deep/a.json"]
    proc, lines, _ = run_block(tmp_path, members)
    assert proc.returncode == 0, proc.stderr
    assert by_wave(lines) == {1: ["a.json"], 2: ["b.json"]}


@pytest.mark.parametrize("shell", SHELLS)
def test_cycle_exits_non_zero_naming_the_files(tmp_path, shell):
    members = [member("a.json", after=["b.json"]), member("b.json", after=["a.json"]), member("c.json")]
    proc, lines, _ = run_block(tmp_path, members, shell=shell)
    assert proc.returncode != 0
    assert "a.json" in proc.stderr and "b.json" in proc.stderr
    assert "c.json" not in proc.stderr
    assert lines == []


def test_self_reference_exits_non_zero_naming_the_file(tmp_path):
    proc, lines, _ = run_block(tmp_path, [member("a.json", after=["a.json"])])
    assert proc.returncode != 0
    assert "a.json" in proc.stderr
    assert lines == []


def test_flat_scope_passes_no_dir(tmp_path):
    proc, _, called = run_block(tmp_path, [member("a.json")])
    assert proc.returncode == 0, proc.stderr
    assert called == ["split-detect"]


def test_phase_directory_is_passed_to_split_detect_as_dir(tmp_path):
    phase_dir = "/proj/.aimi/tasks/feat/phase-1"
    proc, _, called = run_block(tmp_path, [member("a.json")], scope_dir=phase_dir)
    assert proc.returncode == 0, proc.stderr
    assert called == ["split-detect", "--dir", phase_dir]


def test_block_keeps_nothing_between_runs(tmp_path):
    members = [member("a.json"), member("b.json", after=["a.json"])]
    _, first, _ = run_block(tmp_path, members)
    members[0]["active"] = False
    _, second, _ = run_block(tmp_path, members)
    assert by_wave(first) == {1: ["a.json"], 2: ["b.json"]}
    assert by_wave(second) == {1: ["b.json"]}
