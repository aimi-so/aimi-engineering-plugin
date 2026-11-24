"""Tests for plan Phase 4 usage surfaces and the usage recipe interview.

Covers phase-4-usage-surfaces.md: its router wiring, the two marker-delimited
blocks (run under bash and zsh against a stub $AIMI_CLI), the record call's
flags against the verb of usage-recipe-record, and the text contracts.
"""

import os
import re
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
PHASE = ROOT / "commands" / "references" / "plan" / "phase-4-usage-surfaces.md"
PLAN = ROOT / "commands" / "plan.md"
CONTEXT = ROOT / "commands" / "references" / "plan" / "phase-4-metadata-context.md"
CHECKLIST = ROOT / "commands" / "references" / "plan" / "phase-4-checklist.md"
DEPS = ROOT / "commands" / "references" / "dependency-setup.md"
CLI = ROOT / "scripts" / "aimi-cli.sh"
TEXT = PHASE.read_text(encoding="utf-8")
SHELLS = [s for s in ("bash", "zsh") if shutil.which(s)]


def block(name):
    lines = TEXT.splitlines()
    b = [i for i, l in enumerate(lines) if l.strip() == "# %s:begin" % name]
    e = [i for i, l in enumerate(lines) if l.strip() == "# %s:end" % name]
    assert len(b) == 1 and len(e) == 1 and b[0] < e[0]
    return "\n".join(lines[b[0] + 1 : e[0]]) + "\n"


def run(tmp_path, shell, body, stub_body=None, env_extra=None):
    cfg = tmp_path / "cfg"
    cfg.mkdir(exist_ok=True)
    stub = tmp_path / "stub.sh"
    stub.write_text("#!/bin/sh\n" + (stub_body or "exit 9\n"), encoding="utf-8")
    stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
    (cfg / "cli-path").write_text(str(stub), encoding="utf-8")
    script = tmp_path / "block.sh"
    script.write_text(
        'AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-$HOME/.config/aimi}/cli-path")\n' + body,
        encoding="utf-8",
    )
    env = dict(os.environ, AIMI_CONFIG_DIR=str(cfg))
    env.pop("CLAUDECODE", None)
    env.update(env_extra or {})
    return subprocess.run(
        [shutil.which(shell), str(script)], capture_output=True, text=True, env=env, timeout=60
    )


def state(tmp_path, shell, stub_body):
    body = block("usage-surfaces-recipe-state").replace("[PROJECT_KEY]", ".")
    out = run(tmp_path, shell, body, stub_body).stdout
    m = re.search(r"^RECIPE_STATE=(\w+)$", out, re.M)
    assert m, out
    return m.group(1)


@pytest.mark.parametrize("shell", SHELLS)
@pytest.mark.parametrize(
    "stub,expected",
    [
        ('echo \'{"status":"recorded","project":".","recipe":{}}\'', "recorded"),
        ('echo \'{"status":"absent","project":".","recipe":null}\'', "absent"),
        ('echo \'{"status":"untrusted","recipe":null}\'', "untrusted"),
        ("echo boom >&2; exit 1", "refused"),
        ("exit 0", "refused"),
        ("echo not-json", "refused"),
        ('echo \'{"status":"weird"}\'', "refused"),
        ("echo '[1]'", "refused"),
    ],
)
def test_usage_surfaces_recipe_state(tmp_path, shell, stub, expected):
    assert state(tmp_path, shell, stub) == expected


@pytest.mark.parametrize("shell", SHELLS)
def test_usage_surfaces_refused_never_absent_without_python(tmp_path, shell):
    body = block("usage-surfaces-recipe-state").replace("[PROJECT_KEY]", ".")
    # a PATH with no python3: only the stub's directory and sh basics
    out = run(
        tmp_path, shell, body, 'echo \'{"status":"absent"}\'', {"PATH": str(tmp_path / "nobin")}
    ).stdout
    assert "RECIPE_STATE=absent" not in out


@pytest.mark.parametrize("shell", SHELLS)
@pytest.mark.parametrize("cc,expected", [("1", "true"), ("", "false"), ("0", "false")])
def test_usage_surfaces_chrome_offer(tmp_path, shell, cc, expected):
    extra = {"CLAUDECODE": cc} if cc else {}
    out = run(tmp_path, shell, block("usage-surfaces-chrome-offer"), None, extra).stdout
    assert out.strip() == "CHROME_OFFERED=" + expected


def test_usage_surfaces_resolution_lines_match_dependency_setup():
    deps = DEPS.read_text(encoding="utf-8").splitlines()
    mine = TEXT.splitlines()
    res = [l for l in deps if l.startswith("AIMI_CLI=$(cat")]
    assert res
    for l in res:
        assert l in mine
    assert [l for l in mine if l.startswith(": \"${AIMI_CLI:?")]


def test_usage_surfaces_record_flags_are_the_verbs():
    cli = CLI.read_text(encoding="utf-8")
    m = re.search(r"--serve\|--cli\|[^)]*\)", cli)
    verb = set(m.group(0).rstrip(")").split("|"))
    verb = {f if f.startswith("--") else "--" + f for f in verb}
    line = [l for l in TEXT.splitlines() if "usage-recipe-record --project" in l and l.startswith("$AIMI_CLI")]
    assert len(line) == 1
    used = set(re.findall(r"--[a-z-]+", line[0])) - {"--project"}
    assert used <= verb
    assert {"--serve", "--ready", "--login", "--browser", "--cleanup", "--setup"} <= used
    assert "usage-recipe-record" in cli.split("Usage:")[0] or "usage-recipe-record --project" in cli
    assert re.search(r"^    usage-recipe-get --project", cli, re.M)
    assert re.search(r"^    usage-recipe-record --project", cli, re.M)
    assert "eval" not in re.findall(r"\$AIMI_CLI usage-recipe-record.*", TEXT)[0]


def test_usage_surfaces_text_contracts():
    assert len(TEXT.encode()) <= 16384
    assert "jq" not in TEXT.lower().replace("`jq`", "")
    assert "commands/references/user-communication.md" in TEXT
    assert "agent-mode: phase-4-usage-recipe not asked" in TEXT
    assert "single quote or a backslash" in TEXT
    for w in ("Bring-up", "Login", "Browser", "External services", "Cleanup"):
        assert w in TEXT
    order = [TEXT.index(". **%s" % w) for w in ("Bring-up", "Login", "Browser", "External services", "Cleanup")]
    assert order == sorted(order)
    assert "mobile-viewport" in TEXT and "recommended" in TEXT


def test_usage_surfaces_web_bullet_is_the_screen_story_rule():
    web = [l for l in TEXT.splitlines() if l.startswith("- **`web`**")]
    assert len(web) == 1
    assert "is_screen_story" in web[0] and "scripts/usage_validation.py" in web[0]
    assert "`visual`" in web[0] and "`test`" in web[0] and "loopback URL" in web[0]
    assert "whose `verification.strategy` is `visual` and whose `verification.url`" not in TEXT


def test_usage_surfaces_router_wiring():
    plan = PLAN.read_text(encoding="utf-8")
    i = plan.index("### Usage Surfaces and Usage Recipe")
    assert plan.index("phase-4-metadata-context.md") < i < plan.index("### Schema v3.3 Structure")
    seg = plan[i : plan.index("### Schema v3.3 Structure")]
    assert "Applies when:" in seg
    assert "Read ${CLAUDE_PLUGIN_ROOT}/commands/references/plan/phase-4-usage-surfaces.md in full" in seg
    assert "usageSurfaces" in CONTEXT.read_text(encoding="utf-8")
    assert "usageSurfaces" in CHECKLIST.read_text(encoding="utf-8")


def test_usage_surfaces_reads_sources_before_asking():
    assert TEXT.index("usage-recipe-sources") < TEXT.index("### Ask")
    line = [l for l in TEXT.splitlines() if l.startswith("$AIMI_CLI usage-recipe-sources")]
    assert len(line) == 1 and "--project" in line[0]
    assert "sources unknown" in TEXT and "never \"no file answers\"" in TEXT
    assert "A file's absence is never an answer" in TEXT
    assert "both" in TEXT and "disagree" in TEXT
    cli = CLI.read_text(encoding="utf-8")
    assert re.search(r"^    usage-recipe-sources --project", cli, re.M)
    assert "usage-recipe-sources) shift; cmd_usage_recipe_sources" in cli
