"""Pins that the commands use init-session's `tasks` path as-is.

`init-session` prints `tasks` as an absolute realpath on every route, `--file`
and auto-discovery alike. A command block that prefixes it with `$AIMI_ROOT/`
builds `/root//root/.aimi/...`, and with stderr discarded the verb that reads
it fails in silence: Step 0.7 counted zero visual stories that way.
"""

import json
import os
import re
import subprocess
from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[2]
CLI = PLUGIN / "scripts" / "aimi-cli.sh"
DOUBLED = re.compile(r"\$\{?AIMI_ROOT\}?/\$\{?TASKS_PATH\}?")


def corpus():
    files = list((PLUGIN / "commands").rglob("*.md"))
    files += list((PLUGIN / "skills").glob("*/SKILL.md"))
    files += list((PLUGIN / "agents").rglob("*.md"))
    return files


def test_no_command_prefixes_the_tasks_path_with_aimi_root():
    hits = []
    for f in corpus():
        for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            if DOUBLED.search(line):
                hits.append(f"{f.relative_to(PLUGIN)}:{n}")
    assert hits == [], "init-session's tasks path is absolute; drop the $AIMI_ROOT/ prefix: " + ", ".join(hits)


def test_the_check_catches_a_doubled_path():
    assert DOUBLED.search('X=$($AIMI_CLI verification-report --tasks-file "$AIMI_ROOT/$TASKS_PATH")')
    assert DOUBLED.search('X="${AIMI_ROOT}/${TASKS_PATH}"')
    assert not DOUBLED.search('X="$TASKS_PATH"')


def test_init_session_doc_shows_an_absolute_tasks_path():
    doc = (PLUGIN / "commands" / "references" / "execute" / "step-1-initialize-session.md").read_text(encoding="utf-8")
    assert '"tasks": "/' in doc
    assert '"tasks": ".aimi/' not in doc


def test_init_session_prints_an_absolute_tasks_path(tmp_path):
    root = tmp_path / "proj"
    tasks = root / ".aimi" / "tasks"
    tasks.mkdir(parents=True)
    subprocess.run(["git", "init", "-q"], cwd=root, check=True)
    doc = {
        "schemaVersion": "3.3",
        "metadata": {"title": "t", "type": "feature", "branchName": "feat/t"},
        "userStories": [{"id": "US-001", "title": "a", "description": "d", "acceptanceCriteria": ["x"],
                         "priority": 1, "status": "pending", "dependsOn": []}],
    }
    (tasks / "2026-01-01-t-tasks.json").write_text(json.dumps(doc), encoding="utf-8")
    nested = root / "sub" / "dir"
    nested.mkdir(parents=True)
    env = {**os.environ, "HOME": str(tmp_path), "XDG_CONFIG_HOME": str(tmp_path / "xdg"),
           "AIMI_CONFIG_DIR": str(tmp_path / "cfg"), "CLAUDE_CONFIG_DIR": str(tmp_path / "claude")}
    env.pop("AIMI_DEV_DIR", None)
    env.pop("AIMI_CLI_PINNED", None)
    for args in (["init-session"], ["init-session", "--file", ".aimi/tasks/2026-01-01-t-tasks.json"]):
        res = subprocess.run(["bash", str(CLI), *args], cwd=nested, env=env, capture_output=True, text=True)
        assert res.returncode == 0, res.stderr
        out = json.loads(res.stdout)["tasks"]
        assert os.path.isabs(out) and os.path.isfile(out), out
