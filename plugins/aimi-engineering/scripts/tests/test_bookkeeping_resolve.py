"""Tests for `aimi-cli.sh bookkeeping-resolve` and scripts/bookkeeping_resolve.py.

Behaviour is driven through the CLI as a subprocess against real `git merge`
conflicts in throwaway repositories under tmp_path, each with an `.aimi/` marker
and an untracked config; the repository's own .aimi/ is never touched.
"""

import json
import os
import re
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
sys.path.insert(0, SCRIPTS)

import bookkeeping  # noqa: E402
import bookkeeping_resolve as BR  # noqa: E402
import bookkeeping_rules  # noqa: E402

CLI = os.path.join(SCRIPTS, "aimi-cli.sh")
HOOK = os.path.join(os.path.dirname(SCRIPTS), "hooks", "auto-approve-cli.sh")
ENV = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
       "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}


def git(root, *args, check=True):
    return subprocess.run(["git", "-C", str(root), *args], check=check,
                          capture_output=True, text=True, env=ENV)


def put(root, rel, text):
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def commit(root, msg):
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", msg)


def merge_conflict(root, base_files, ours_files, theirs_files):
    """Leave `root` mid-merge: main edits ours_files, topic edits theirs_files."""
    for rel, text in base_files.items():
        put(root, rel, text)
    commit(root, "base")
    git(root, "checkout", "-q", "-b", "topic")
    for rel, text in theirs_files.items():
        put(root, rel, text)
    commit(root, "theirs")
    git(root, "checkout", "-q", "main")
    for rel, text in ours_files.items():
        put(root, rel, text)
    commit(root, "ours")
    res = git(root, "merge", "topic", check=False)
    assert res.returncode != 0


@pytest.fixture
def root(tmp_path):
    git(tmp_path, "init", "-q", "-b", "main")
    (tmp_path / ".aimi").mkdir()
    (tmp_path / ".git" / "info" / "exclude").write_text(".aimi/\n")
    return tmp_path


def write_config(root, decl):
    (root / ".aimi" / "config.json").write_text(
        decl if isinstance(decl, str) else json.dumps({"bookkeeping": decl}))


def run(root, *args, cwd=None):
    env = {k: v for k, v in os.environ.items() if k != "AIMI_DIR"}
    return subprocess.run(["bash", CLI, "bookkeeping-resolve", *args],
                          cwd=str(cwd or root), capture_output=True, text=True, env=env)


def unmerged(root):
    return git(root, "ls-files", "-u").stdout


def test_union_lines_resolves_without_staging(root):
    merge_conflict(root, {"CHANGELOG.md": "# Log\n"}, {"CHANGELOG.md": "# Log\n- ours\n"},
                   {"CHANGELOG.md": "# Log\n- theirs\n"})
    write_config(root, {".": {"CHANGELOG.md": {"rule": "union-lines"}}})
    before = unmerged(root)
    res = run(root)
    assert res.returncode == 0, res.stderr
    out = json.loads(res.stdout)
    assert list(out) == ["resolved", "unclaimed", "refused"]
    assert out["unclaimed"] == [] and out["refused"] == []
    assert [(r["path"], r["rule"]) for r in out["resolved"]] == [("CHANGELOG.md", "union-lines")]
    assert out["resolved"][0]["changes"] == [{"line": 3, "before": None, "after": "- theirs"}]
    text = (root / "CHANGELOG.md").read_text()
    assert text.count("- ours") == 1 and text.count("- theirs") == 1 and "<<<<" not in text
    assert unmerged(root) == before  # nothing staged


def test_only_declared_conflicted_files_are_touched(root):
    merge_conflict(root, {"CHANGELOG.md": "a\n", "OTHER.md": "x\n", "CLEAN.md": "c\n"},
                   {"CHANGELOG.md": "a\no\n", "OTHER.md": "x\no\n"},
                   {"CHANGELOG.md": "a\nt\n", "OTHER.md": "x\nt\n"})
    write_config(root, {".": {"CHANGELOG.md": {"rule": "union-lines"},
                              "CLEAN.md": {"rule": "union-lines"}}})
    other = (root / "OTHER.md").read_bytes()
    out = json.loads(run(root).stdout)
    assert [r["path"] for r in out["resolved"]] == ["CHANGELOG.md"]
    assert (root / "OTHER.md").read_bytes() == other and b"<<<<" in other


def test_unclaimed_stays_conflicted_and_others_resolve(root):
    merge_conflict(root, {"CHANGELOG.md": "a\n", "VERSION": "1.0.0\n"},
                   {"CHANGELOG.md": "A\n", "VERSION": "1.1.0\n"},
                   {"CHANGELOG.md": "B\n", "VERSION": "1.2.0\n"})
    write_config(root, {".": {"CHANGELOG.md": {"rule": "union-lines"},
                              "VERSION": {"rule": "max-version"}}})
    marked = (root / "CHANGELOG.md").read_bytes()
    res = run(root)
    assert res.returncode == 0
    out = json.loads(res.stdout)
    assert [r["path"] for r in out["resolved"]] == ["VERSION"]
    assert [(u["path"], u["rule"]) for u in out["unclaimed"]] == [("CHANGELOG.md", "union-lines")]
    assert out["unclaimed"][0]["reason"]
    assert (root / "VERSION").read_text() == "1.2.0\n"
    assert (root / "CHANGELOG.md").read_bytes() == marked


def test_unproducible_refuses_and_writes_nothing(root):
    merge_conflict(root, {"CHANGELOG.md": "a\n", "VERSION": "1.0.0\n"},
                   {"CHANGELOG.md": "a\no\n", "VERSION": "1.1\n"},
                   {"CHANGELOG.md": "a\nt\n", "VERSION": "1.2.3\n"})
    write_config(root, {".": {"CHANGELOG.md": {"rule": "union-lines"},
                              "VERSION": {"rule": "max-version"}}})
    snap = {p: (root / p).read_bytes() for p in ("CHANGELOG.md", "VERSION")}
    res = run(root)
    assert res.returncode == 1
    out = json.loads(res.stdout)
    assert out["resolved"] == [] and out["unclaimed"] == []
    assert [(r["path"], r["rule"], r["kind"]) for r in out["refused"]] == [("VERSION", "max-version", "unproducible")]
    lines = res.stderr.strip().splitlines()
    assert len(lines) == 1
    assert lines[0] == "Error: bookkeeping-resolve: VERSION (max-version): %s" % out["refused"][0]["reason"]
    assert {p: (root / p).read_bytes() for p in snap} == snap


def test_not_utf8_is_unproducible(root):
    merge_conflict(root, {"CHANGELOG.md": "a\n"}, {"CHANGELOG.md": "a\no\n"}, {"CHANGELOG.md": "a\nt\n"})
    # replace the "theirs" stage with invalid UTF-8 by redoing the merge
    git(root, "merge", "--abort")
    git(root, "checkout", "-q", "topic")
    (root / "CHANGELOG.md").write_bytes(b"a\n\xff\xfe\n")
    commit(root, "bad bytes")
    git(root, "checkout", "-q", "main")
    assert git(root, "merge", "topic", check=False).returncode != 0
    write_config(root, {".": {"CHANGELOG.md": {"rule": "union-lines"}}})
    res = run(root)
    assert res.returncode == 1
    assert json.loads(res.stdout)["refused"][0]["kind"] == "unproducible"


def test_non_regular_stage_is_unproducible(root):
    put(root, "LINK", "x\n")
    commit(root, "base")
    git(root, "checkout", "-q", "-b", "topic")
    os.remove(root / "LINK")
    os.symlink("elsewhere", root / "LINK")
    commit(root, "theirs")
    git(root, "checkout", "-q", "main")
    put(root, "LINK", "y\n")
    commit(root, "ours")
    assert git(root, "merge", "topic", check=False).returncode != 0
    write_config(root, {".": {"LINK": {"rule": "union-lines"}}})
    res = run(root)
    assert res.returncode == 1
    assert json.loads(res.stdout)["refused"][0]["kind"] == "unproducible"


def test_rerun_is_identical(root):
    merge_conflict(root, {"CHANGELOG.md": "a\n"}, {"CHANGELOG.md": "a\no\n"}, {"CHANGELOG.md": "a\nt\n"})
    write_config(root, {".": {"CHANGELOG.md": {"rule": "union-lines"}}})
    first = run(root)
    snap = (root / "CHANGELOG.md").read_bytes()
    second = run(root)
    assert first.returncode == second.returncode == 0
    assert first.stdout == second.stdout and (root / "CHANGELOG.md").read_bytes() == snap


def test_mode_is_kept(root):
    merge_conflict(root, {"CHANGELOG.md": "a\n"}, {"CHANGELOG.md": "a\no\n"}, {"CHANGELOG.md": "a\nt\n"})
    os.chmod(root / "CHANGELOG.md", 0o755)
    write_config(root, {".": {"CHANGELOG.md": {"rule": "union-lines"}}})
    assert run(root).returncode == 0
    assert (os.stat(root / "CHANGELOG.md").st_mode & 0o777) == 0o755


def test_symlink_outside_root_is_unproducible(root, tmp_path_factory):
    outside = tmp_path_factory.mktemp("outside") / "target.md"
    outside.write_text("keep\n")
    merge_conflict(root, {"CHANGELOG.md": "a\n"}, {"CHANGELOG.md": "a\no\n"}, {"CHANGELOG.md": "a\nt\n"})
    os.remove(root / "CHANGELOG.md")
    os.symlink(str(outside), root / "CHANGELOG.md")
    write_config(root, {".": {"CHANGELOG.md": {"rule": "union-lines"}}})
    res = run(root)
    assert res.returncode == 1
    assert json.loads(res.stdout)["refused"][0]["kind"] == "unproducible"
    assert outside.read_text() == "keep\n"


def test_failed_write_restores_replaced_files(tmp_path, monkeypatch):
    a, b = tmp_path / "a.txt", tmp_path / "b.txt"
    a.write_text("A0\n")
    b.write_text("B0\n")
    real_replace = os.replace
    calls = []

    def flaky(src, dst):
        calls.append(dst)
        if str(dst) == str(b) and len(calls) == 2:
            raise OSError("boom")
        return real_replace(src, dst)

    monkeypatch.setattr(BR.os, "replace", flaky)
    with pytest.raises(OSError):
        BR._write_all([(str(a), b"A1\n"), (str(b), b"B1\n")])
    assert a.read_text() == "A0\n" and b.read_text() == "B0\n"
    assert not [p for p in os.listdir(tmp_path) if p.endswith(".tmp")]


def test_absence_is_an_answer(root):
    merge_conflict(root, {"CHANGELOG.md": "a\n"}, {"CHANGELOG.md": "a\no\n"}, {"CHANGELOG.md": "a\nt\n"})
    marked = (root / "CHANGELOG.md").read_bytes()
    empty = {"resolved": [], "unclaimed": [], "refused": []}
    for decl in (None, {"web": {"CHANGELOG.md": {"rule": "union-lines"}}}):
        cfg = root / ".aimi" / "config.json"
        if cfg.exists():
            cfg.unlink()
        if decl is not None:
            write_config(root, decl)
        res = run(root)
        assert res.returncode == 0 and json.loads(res.stdout) == empty
    write_config(root, '{"dependencies": {}}')
    assert json.loads(run(root).stdout) == empty
    assert (root / "CHANGELOG.md").read_bytes() == marked


def test_malformed_declaration_exits_one_naming_config(root):
    write_config(root, {".": {"X": {"rule": "nope"}}})
    res = run(root)
    assert res.returncode == 1 and res.stdout == ""
    assert res.stderr.startswith("Error: bookkeeping-resolve: ") and "config.json" in res.stderr


def test_tracked_config_with_declaration_is_refused(root):
    write_config(root, {".": {"CHANGELOG.md": {"rule": "union-lines"}}})
    git(root, "add", "-f", ".aimi/config.json")
    res = run(root)
    assert res.returncode == 1 and res.stdout == "" and "tracked" in res.stderr


@pytest.mark.parametrize("args", [["--project"], ["--root"], ["--bogus"]])
def test_flag_errors_print_usage(root, args):
    res = run(root, *args)
    assert res.returncode == 1
    assert "Usage: aimi-cli.sh bookkeeping-resolve [--project <key>] [--root <dir>]" in res.stderr


def test_root_must_be_a_repository_top_level(root):
    write_config(root, {".": {"CHANGELOG.md": {"rule": "union-lines"}}})
    (root / "sub").mkdir()
    res = run(root, "--root", "sub")
    assert res.returncode == 1 and "Usage: aimi-cli.sh bookkeeping-resolve" in res.stderr
    assert run(root, "--root", ".").returncode == 0


def test_project_flag_selects_key(root):
    merge_conflict(root, {"web/CHANGELOG.md": "a\n"}, {"web/CHANGELOG.md": "a\no\n"},
                   {"web/CHANGELOG.md": "a\nt\n"})
    write_config(root, {".": {}, "web": {"web/CHANGELOG.md": {"rule": "union-lines"}}})
    assert json.loads(run(root).stdout)["resolved"] == []
    out = json.loads(run(root, "--project", "web").stdout)
    assert [r["path"] for r in out["resolved"]] == ["web/CHANGELOG.md"]


# --- size-step measure ------------------------------------------------------

BIG = "x" * 17000 + "\n"  # 17001 bytes -> budget 20480


def _size_fixture(root, rows_base, rows_ours, rows_theirs, files):
    merge_conflict(root, {"plugins/p/scripts/baseline.txt": rows_base, **files},
                   {"plugins/p/scripts/baseline.txt": rows_ours},
                   {"plugins/p/scripts/baseline.txt": rows_theirs})


def test_size_step_row_relative_to_commands_two_levels_above(root):
    _size_fixture(root, "execute.md\t16384\n", "execute.md\t18432\n", "execute.md\t20480\n",
                  {"plugins/p/commands/execute.md": BIG})
    write_config(root, {".": {"plugins/p/scripts/baseline.txt": {"rule": "size-step"}}})
    res = run(root)
    assert res.returncode == 0, res.stderr
    out = json.loads(res.stdout)
    assert out["resolved"][0]["rule"] == "size-step"
    assert (root / "plugins/p/scripts/baseline.txt").read_text() == "execute.md\t20480\n"


def test_size_step_row_missing_everywhere_is_refused(root):
    _size_fixture(root, "nowhere.md\t16384\n", "nowhere.md\t18432\n", "nowhere.md\t20480\n", {})
    write_config(root, {".": {"plugins/p/scripts/baseline.txt": {"rule": "size-step"}}})
    marked = (root / "plugins/p/scripts/baseline.txt").read_bytes()
    res = run(root)
    assert res.returncode == 1
    assert json.loads(res.stdout)["refused"][0]["kind"] == "unproducible"
    assert (root / "plugins/p/scripts/baseline.txt").read_bytes() == marked


def test_size_step_conflicted_measured_file_is_unclaimed(root):
    merge_conflict(root, {"plugins/p/scripts/baseline.txt": "execute.md\t16384\n",
                          "plugins/p/commands/execute.md": BIG},
                   {"plugins/p/scripts/baseline.txt": "execute.md\t18432\n",
                    "plugins/p/commands/execute.md": BIG + "ours\n"},
                   {"plugins/p/scripts/baseline.txt": "execute.md\t20480\n",
                    "plugins/p/commands/execute.md": BIG + "theirs\n"})
    write_config(root, {".": {"plugins/p/scripts/baseline.txt": {"rule": "size-step"}}})
    res = run(root)
    assert res.returncode == 0
    out = json.loads(res.stdout)
    assert out["resolved"] == [] and out["unclaimed"][0]["path"] == "plugins/p/scripts/baseline.txt"


def test_size_step_row_escaping_root_measures_as_none(root):
    _size_fixture(root, "../x.md\t16384\n", "../x.md\t18432\n", "../x.md\t20480\n", {})
    write_config(root, {".": {"plugins/p/scripts/baseline.txt": {"rule": "size-step"}}})
    res = run(root)
    assert res.returncode == 1


# --- structure --------------------------------------------------------------


def test_rule_kinds_tuples_are_equal():
    assert bookkeeping.RULE_KINDS == bookkeeping_rules.RULE_KINDS


def _wrapper_body():
    text = open(CLI).read()
    start = text.index("cmd_bookkeeping_resolve() {")
    end = text.index("\n}\n", start)
    return text[start:end]


def test_wrapper_shape():
    body = _wrapper_body()
    assert body.count("python3 ") == 1
    assert "check_python3" in body
    assert "jq" not in body and "_lock" not in body
    assert body.count("validate_path_in_project") >= 2
    assert body.index("check_python3") < body.index("python3 \"")


def test_dispatcher_and_help_lines():
    text = open(CLI).read()
    assert text.count("bookkeeping-resolve) shift; cmd_bookkeeping_resolve") == 1
    assert len(re.findall(r"^    bookkeeping-resolve \[--project <key>\] \[--root <dir>\]$", text, re.M)) == 1


def test_hook_does_not_name_the_writer():
    assert "bookkeeping-resolve" not in open(HOOK).read()
