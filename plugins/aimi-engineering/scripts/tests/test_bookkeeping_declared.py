"""Tests for `aimi-cli.sh bookkeeping-declared` and scripts/bookkeeping_declared.py.

Behaviour is driven through the CLI as a subprocess against throwaway git
repositories under tmp_path; the repository's own .aimi/ is never touched.
"""

import json
import os
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
sys.path.insert(0, SCRIPTS)

import bookkeeping_declared as BD  # noqa: E402

CLI = os.path.join(SCRIPTS, "aimi-cli.sh")


def _git(root, *args):
    subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True,
                   env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"})


@pytest.fixture
def root(tmp_path):
    _git(tmp_path, "init", "-q")
    (tmp_path / ".aimi").mkdir()
    return tmp_path


def write_config(root, doc):
    path = root / ".aimi" / "config.json"
    path.write_text(doc if isinstance(doc, str) else json.dumps(doc))
    return path


def run(root, *args):
    env = {k: v for k, v in os.environ.items() if k != "AIMI_DIR"}
    return subprocess.run(["bash", CLI, "bookkeeping-declared", *args], cwd=str(root),
                          capture_output=True, text=True, env=env)


DECL = {"bookkeeping": {".": {"CHANGELOG.md": {"rule": "union-lines"},
                              "VERSION": {"rule": "max-version"}},
                        "web": {"a.txt": {"rule": "sum-delta"}}}}


def test_prints_declaration_in_order(root):
    write_config(root, DECL)
    res = run(root)
    assert res.returncode == 0 and res.stderr == ""
    assert res.stdout.count("\n") == 1
    out = json.loads(res.stdout)
    assert out == {"project": ".", "paths": {"CHANGELOG.md": "union-lines", "VERSION": "max-version"}}
    assert list(out["paths"]) == ["CHANGELOG.md", "VERSION"]


def test_project_flag_selects_key(root):
    write_config(root, DECL)
    res = run(root, "--project", "web")
    assert res.returncode == 0
    assert json.loads(res.stdout) == {"project": "web", "paths": {"a.txt": "sum-delta"}}


def test_absence_is_an_answer(root):
    # no config file
    res = run(root)
    assert res.returncode == 0 and json.loads(res.stdout) == {"project": ".", "paths": {}}
    # no bookkeeping key
    write_config(root, {"dependencies": {}})
    assert json.loads(run(root).stdout) == {"project": ".", "paths": {}}
    # another key declares, requested one does not
    write_config(root, DECL)
    res = run(root, "--project", "api")
    assert res.returncode == 0 and json.loads(res.stdout) == {"project": "api", "paths": {}}


def test_malformed_declaration_is_refused_naming_the_file(root):
    write_config(root, {"bookkeeping": {".": {"x": {"rule": "nope"}}}})
    res = run(root)
    assert res.returncode == 1 and res.stdout == ""
    assert res.stderr.startswith("Error: bookkeeping-declared: ")
    assert "config.json" in res.stderr


def test_invalid_json_is_refused(root):
    write_config(root, "{not json")
    res = run(root)
    assert res.returncode == 1 and res.stdout == ""
    assert "Error: bookkeeping-declared: " in res.stderr and "config.json" in res.stderr


def test_tracked_config_with_declaration_is_refused(root):
    cfg = write_config(root, DECL)
    _git(root, "add", "-f", str(cfg))
    res = run(root)
    assert res.returncode == 1 and res.stdout == ""
    assert "tracked" in res.stderr and "config.json" in res.stderr


def test_usage_errors(root):
    res = run(root, "--project")
    assert res.returncode == 1 and res.stdout == "" and "Usage: aimi-cli.sh bookkeeping-declared" in res.stderr
    res = run(root, "--bogus")
    assert res.returncode == 1 and res.stdout == "" and "Usage: aimi-cli.sh bookkeeping-declared" in res.stderr


@pytest.mark.parametrize("args", [(), ("--project", "web")])
def test_read_only_even_when_refused(root, args):
    cfg = write_config(root, DECL)
    before = cfg.read_bytes()
    run(root, *args)
    assert cfg.read_bytes() == before
    cfg = write_config(root, {"bookkeeping": {".": {"x": {"rule": "bad"}}}})
    before = cfg.read_bytes()
    assert run(root, *args).returncode in (0, 1)
    assert cfg.read_bytes() == before


def test_module_usage_exits_2(capsys):
    assert BD.main(["bookkeeping_declared.py"]) == 2
    assert BD.main(["bookkeeping_declared.py", "declared", "--config", "x"]) == 2
    assert "Usage:" in capsys.readouterr().err


def test_non_ascii_key_is_not_escaped(root):
    write_config(root, {"bookkeeping": {"é": {"ç.txt": {"rule": "union-lines"}}}})
    res = run(root, "--project", "é")
    assert res.returncode == 0 and "ç.txt" in res.stdout
