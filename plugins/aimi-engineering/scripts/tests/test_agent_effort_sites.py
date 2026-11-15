"""Pins the effort annotation beside every model annotation at a Claude Code spawn site.

A spawn site that carries `[model: <AGENT_MODELS.CATEGORY when not "inherit">]`
(or the parameter-list `model: ...,`) must carry the same category's effort on
the line right after it, spelled the same way, so a stored effort reaches the
spawned agent. Every prose line that tells a command to populate or hand on
`AGENT_MODELS` must name `AGENT_EFFORTS` too, and the two split-handoff lists
pair the two values. Files are read as text; the echo line of the Resolve
Agent Models block is the one thing executed, under bash, against a stub CLI
and against this tree's `aimi-cli.sh`.

`findings(files)` is a pure function over {relative name: text} returning
"name:line: problem" strings, so one function serves the shipped tree and the
synthetic cases below.
"""

import json
import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATEGORIES = ("research", "review", "design", "workflow", "executor")

BR_MODEL = re.compile(r'\[model: <AGENT_MODELS\.(\w+) when not "inherit">\]')
BR_EFFORT = re.compile(r'\[effort: <AGENT_EFFORTS\.(\w+) when not "inherit">\]')
PL_MODEL = re.compile(r'^(\s*)model: <AGENT_MODELS\.(\w+) when not "inherit">,\s*$')
PL_EFFORT = re.compile(r'^(\s*)effort: <AGENT_EFFORTS\.(\w+) when not "inherit">,\s*$')
LOOSE_EFFORT = re.compile(r"AGENT_EFFORTS\.\w+")
HANDOFF_MODELS = re.compile(r"^\s*- AGENT_MODELS = \[the value Resolve Agent Models echoed\]\s*$")
HANDOFF_EFFORTS = re.compile(r"^\s*- AGENT_EFFORTS = \[the value Resolve Agent Models echoed\]\s*$")


def corpus():
    out = {}
    for sub in ("commands", "skills"):
        for p in sorted((ROOT / sub).rglob("*.md")):
            out[str(p.relative_to(ROOT))] = p.read_text(encoding="utf-8")
    return out


def findings(files):
    problems = []
    for name, text in files.items():
        lines = text.split("\n")
        models, efforts = {}, {}
        for i, line in enumerate(lines):
            n = i + 1
            pm = PL_MODEL.match(line)
            bm_all = BR_MODEL.findall(line)
            be_all = BR_EFFORT.findall(line)
            pe = PL_EFFORT.match(line)
            for c in bm_all:
                models[c] = models.get(c, 0) + 1
            for c in be_all:
                efforts[c] = efforts.get(c, 0) + 1
            if pm:
                models[pm.group(2)] = models.get(pm.group(2), 0) + 1
            if pe:
                efforts[pe.group(2)] = efforts.get(pe.group(2), 0) + 1
            nxt = lines[i + 1] if i + 1 < len(lines) else ""
            indent = re.match(r"\s*", line).group(0)
            # model annotation adjacency
            if pm:
                want = f'{pm.group(1)}effort: <AGENT_EFFORTS.{pm.group(2)} when not "inherit">,'
                if nxt.rstrip() != want:
                    problems.append(f"{name}:{n}: model line not followed by its effort line ({want.strip()})")
            elif bm_all:
                stripped = line.strip()
                if BR_MODEL.fullmatch(stripped):
                    want = f'{indent}[effort: <AGENT_EFFORTS.{bm_all[0]} when not "inherit">]'
                    if nxt.rstrip() != want:
                        problems.append(f"{name}:{n}: model line not followed by its effort line ({want.strip()})")
                else:
                    # inline site: effort directly after the model on the same line
                    for c in bm_all:
                        pair = (f'[model: <AGENT_MODELS.{c} when not "inherit">] '
                                f'[effort: <AGENT_EFFORTS.{c} when not "inherit">]')
                        if pair not in line:
                            problems.append(f"{name}:{n}: inline model annotation lacks its adjacent effort ({c})")
            # stray effort annotation spelled otherwise or orphaned
            if (be_all or pe) and not (pm or bm_all):
                prev = lines[i - 1] if i else ""
                if not (BR_MODEL.search(prev) or PL_MODEL.match(prev)):
                    problems.append(f"{name}:{n}: effort annotation not adjacent to a model annotation")
            if LOOSE_EFFORT.search(line) and "when not" in line and not (be_all or pe) \
                    and ("effort" in line):
                problems.append(f"{name}:{n}: effort annotation spelled differently")
            # prose naming AGENT_MODELS without AGENT_EFFORTS
            if "AGENT_MODELS" in line and "AGENT_EFFORTS" not in line \
                    and not (pm or bm_all) and not line.lstrip().startswith('echo "AGENT_MODELS='):
                if HANDOFF_MODELS.match(line):
                    if not HANDOFF_EFFORTS.match(nxt):
                        problems.append(f"{name}:{n}: AGENT_MODELS handoff line not followed by AGENT_EFFORTS")
                else:
                    problems.append(f"{name}:{n}: line names AGENT_MODELS without AGENT_EFFORTS")
            if HANDOFF_EFFORTS.match(line):
                prev = lines[i - 1] if i else ""
                if not HANDOFF_MODELS.match(prev):
                    problems.append(f"{name}:{n}: AGENT_EFFORTS handoff line not right after AGENT_MODELS")
        for c in sorted(set(models) | set(efforts)):
            if models.get(c, 0) != efforts.get(c, 0):
                problems.append(
                    f"{name}:1: category {c}: {models.get(c, 0)} model annotation(s) vs {efforts.get(c, 0)} effort")
    return problems


def test_the_shipped_tree_has_an_effort_beside_every_model():
    assert findings(corpus()) == []


def test_the_scan_reaches_all_five_categories_in_both_syntaxes():
    seen_br, seen_pl = set(), set()
    for text in corpus().values():
        for line in text.split("\n"):
            seen_br.update(BR_EFFORT.findall(line))
            m = PL_EFFORT.match(line)
            if m:
                seen_pl.add(m.group(2))
    assert seen_br >= {"research", "review", "design", "workflow"}
    assert seen_pl >= {"executor", "design"}
    assert (seen_br | seen_pl) == set(CATEGORIES)


# --- synthetic text: the findings function bites -------------------------------

GOOD_BR = '  [model: <AGENT_MODELS.research when not "inherit">]\n  [effort: <AGENT_EFFORTS.research when not "inherit">]\n'
GOOD_PL = ('    model: <AGENT_MODELS.executor when not "inherit">,\n'
           '    effort: <AGENT_EFFORTS.executor when not "inherit">,\n')


def test_effort_synthetic_good_text_is_clean():
    assert findings({"a.md": GOOD_BR + GOOD_PL}) == []


def test_effort_missing_bracketed_is_reported_with_file_and_line():
    out = findings({"a.md": 'x\n  [model: <AGENT_MODELS.review when not "inherit">]\n  prompt\n'})
    assert any(p.startswith("a.md:2:") and "effort" in p for p in out)


def test_effort_missing_parameter_list_is_reported():
    out = findings({"a.md": '    model: <AGENT_MODELS.design when not "inherit">,\n    description: "x",\n'})
    assert any(p.startswith("a.md:1:") for p in out)


def test_effort_misplaced_is_reported():
    text = ('  [model: <AGENT_MODELS.research when not "inherit">]\n  prompt: x\n'
            '  [effort: <AGENT_EFFORTS.research when not "inherit">]\n')
    out = findings({"a.md": text})
    assert any("a.md:1:" in p for p in out)
    assert any("a.md:3:" in p and "not adjacent" in p for p in out)


def test_effort_miscategorised_is_reported():
    text = ('  [model: <AGENT_MODELS.research when not "inherit">]\n'
            '  [effort: <AGENT_EFFORTS.review when not "inherit">]\n')
    out = findings({"a.md": text})
    assert any("a.md:1:" in p for p in out)
    assert any("category research" in p for p in out)


def test_effort_misspelled_is_reported():
    text = ('  [model: <AGENT_MODELS.research when not "inherit">]\n'
            '  [effort: <AGENT_EFFORTS.research when not inherit>]\n')
    assert any("a.md:1:" in p for p in findings({"a.md": text}))


def test_effort_inline_site_must_carry_its_effort():
    bad = 'with `[model: <AGENT_MODELS.research when not "inherit">]` and the prompt\n'
    good = ('with `[model: <AGENT_MODELS.research when not "inherit">] '
            '[effort: <AGENT_EFFORTS.research when not "inherit">]` and the prompt\n')
    assert findings({"a.md": bad})
    assert findings({"a.md": good}) == []


def test_effort_prose_naming_models_alone_is_reported():
    out = findings({"a.md": "x\nto populate `AGENT_MODELS`.\n"})
    assert out == ["a.md:2: line names AGENT_MODELS without AGENT_EFFORTS"]


def test_effort_unpaired_handoff_is_reported():
    h = "        - AGENT_MODELS = [the value Resolve Agent Models echoed]\n"
    e = "        - AGENT_EFFORTS = [the value Resolve Agent Models echoed]\n"
    assert findings({"a.md": h + "        - BASE = x\n"})
    assert findings({"a.md": e})
    assert findings({"a.md": h + e}) == []


# --- the echo line, executed ---------------------------------------------------

def _echo_line():
    text = (ROOT / "commands/references/cli-path-resolution.md").read_text(encoding="utf-8")
    lines = [l for l in text.split("\n") if l.startswith('echo "AGENT_EFFORTS=')]
    assert len(lines) == 1
    return lines[0]


def test_effort_echo_follows_the_models_echo_in_the_same_fence():
    text = (ROOT / "commands/references/cli-path-resolution.md").read_text(encoding="utf-8")
    assert ('echo "AGENT_MODELS=$($AIMI_CLI resolve-models)"\n'
            'echo "AGENT_EFFORTS=$($AIMI_CLI resolve-efforts | head -n 1)"\n') in text


def test_effort_echo_is_bounded_against_a_cli_that_prints_help(tmp_path):
    stub = tmp_path / "stub-cli"
    stub.write_text("#!/bin/sh\nawk 'BEGIN{for(i=0;i<5000;i++)print \"help line \" i}'\n")
    stub.chmod(0o755)
    r = subprocess.run(["bash", "-c", f'AIMI_CLI={stub}\n{_echo_line()}'],
                       capture_output=True, text=True, timeout=30)
    assert r.returncode == 0
    assert r.stdout.count("\n") == 1
    assert r.stdout.startswith("AGENT_EFFORTS=")
    assert len(r.stdout) < 200


def test_effort_echo_against_this_trees_cli_with_an_empty_config(tmp_path):
    cli = ROOT / "scripts" / "aimi-cli.sh"
    env = dict(os.environ, AIMI_CONFIG_DIR=str(tmp_path / "cfg"), XDG_CONFIG_HOME=str(tmp_path / "xdg"))
    env.pop("AIMI_DEV_DIR", None)
    r = subprocess.run(["bash", "-c", f'AIMI_CLI={cli}\n{_echo_line()}'],
                       capture_output=True, text=True, timeout=60, cwd=tmp_path, env=env)
    assert r.returncode == 0, r.stderr
    expected = "AGENT_EFFORTS=" + json.dumps(dict.fromkeys(CATEGORIES, "inherit"), separators=(",", ":"))
    assert r.stdout.strip() == expected
