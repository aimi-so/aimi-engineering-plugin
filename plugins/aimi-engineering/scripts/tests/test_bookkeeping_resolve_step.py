"""Pins the bookkeeping-resolve step of the wave merge, and replays its documented
git sequence in a real merge conflict.

Wiring pins read the command files as text. The replay runs inside pytest's
tmp_path with an `.aimi/` marker and an untracked config, calling the
`aimi-cli.sh` of the tree this file ships in, never a cache.
"""

import json
import os
import re
import subprocess
from pathlib import Path

import pytest

PLUGIN = Path(__file__).resolve().parents[2]
CLI = PLUGIN / "scripts" / "aimi-cli.sh"
EXEC = PLUGIN / "commands" / "references" / "execute"
REF = EXEC / "bookkeeping-resolve.md"
S4 = EXEC / "step-4-wave-execution-loop.md"
RECON = EXEC / "wave-reconcile.md"
BRIEF = PLUGIN / "skills" / "story-executor" / "references" / "reconcile-worker.md"
ROUTER = PLUGIN / "commands" / "execute.md"
MEASURE = PLUGIN / "scripts" / "tests" / "measure_execute_reads.py"


def text(p):
    return p.read_text(encoding="utf-8")


# ---------------------------------------------------------------- wiring pins


def test_router_has_exactly_one_read_line_under_step_4():
    lines = [l for l in text(ROUTER).splitlines() if "bookkeeping-resolve.md in full" in l]
    assert len(lines) == 1 and lines[0].startswith("Before ")
    s = text(ROUTER)
    step4 = s.index("## Step 4: Wave Execution Loop")
    assert step4 < s.index("bookkeeping-resolve.md in full") < s.index("### Post-Loop Cleanup")


def test_measure_table_has_a_row():
    assert '"bookkeeping-resolve.md"' in text(MEASURE)


def test_step_4_only_points_at_the_procedure_before_the_judgment_loop():
    s = text(S4)
    assert s.count("bookkeeping-resolve") == 1
    assert s.index("bookkeeping-resolve") < s.index("Read each involved story with")
    assert "Edit each [judged] file" in s
    assert "git -C [merge_cwd] checkout --merge -- [conflicted...]" in s


def test_procedure_names_every_outcome_and_the_both_sets_restore():
    s = text(REF)
    for needle in ("bookkeeping-resolve", "--project", "--root", "unclaimed", "unproducible", "refused",
                   "git checkout --merge", "machine_resolved", "kind", "ONE `git add", "ONE `git commit --no-edit --cleanup=strip`"):
        assert needle in s, needle
    assert "```bash" not in s
    assert 'if group_key == "DEFAULT" else group_key' in s


def test_reconcile_files_carry_the_machine_resolved_contract():
    r, b = text(RECON), text(BRIEF)
    assert "machine_resolved" in r and "BOOKKEEPING_RESOLVED" in r and "BOOKKEEPING_RESOLVED" in b
    assert "round_start_sha" in r and "a path in machine_resolved" in r
    assert "requirements-conflict" in b and "name the file and its rule" in b
    assert "Hand-edit a file listed in `BOOKKEEPING_RESOLVED`" in b


# ------------------------------------------------------------- real-merge replay


def env_for(tmp_path):
    env = {k: v for k, v in os.environ.items() if k != "AIMI_DIR" and not k.startswith("GIT_")}
    env.update(GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t",
               GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull)
    return env


class Repo:
    def __init__(self, root):
        self.root = root
        self.env = env_for(root)

    def git(self, *args, check=True):
        r = subprocess.run(["git", "-c", "commit.gpgsign=false", "-C", str(self.root), *args],
                           capture_output=True, text=True, env=self.env)
        if check:
            assert r.returncode == 0, r.stdout + r.stderr
        return r

    def put(self, rel, body):
        (self.root / rel).write_text(body)

    def commit(self, msg):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", msg)

    def conflicted(self):
        return self.git("diff", "--name-only", "--diff-filter=U").stdout.split()

    def resolver(self, *extra):
        r = subprocess.run(["bash", str(CLI), "bookkeeping-resolve", "--project", ".", "--root", str(self.root), *extra],
                           cwd=self.root, capture_output=True, text=True, env=self.env)
        return r


def make_wave(tmp_path, declared, files):
    """Base, two story branches editing `files` differently, story-1 merged cleanly, story-2 conflicting."""
    repo = Repo(tmp_path)
    repo.git("init", "-q", "-b", "main")
    (tmp_path / ".aimi").mkdir()
    (tmp_path / ".git" / "info" / "exclude").write_text(".aimi/\n")
    if declared is not None:
        (tmp_path / ".aimi" / "config.json").write_text(json.dumps({"bookkeeping": declared}))
    for rel, (base, _a, _b) in files.items():
        repo.put(rel, base)
    repo.commit("base")
    for n, idx in (("story-1", 1), ("story-2", 2)):
        repo.git("checkout", "-q", "-b", n, "main")
        for rel, vals in files.items():
            repo.put(rel, vals[idx])
        repo.commit(n)
    repo.git("checkout", "-q", "main")
    repo.git("merge", "-q", "--no-ff", "-m", "Merge story: one", "story-1")
    assert repo.git("merge", "--no-ff", "-m", "Merge story: two", "story-2", check=False).returncode != 0
    return repo


CHANGELOG = ("# Log\n", "# Log\n- one\n", "# Log\n- two\n")
CODE = ("x = 0\n", "x = 1\n", "x = 2\n")


def finish_documented_sequence(repo, judged_edits, verify_ok=True):
    """The documented pass after the resolver: edit judged files, verify, add once, commit once."""
    conflicted = repo.conflicted()
    for rel, body in judged_edits.items():
        repo.put(rel, body)
    if not verify_ok:
        repo.git("checkout", "--merge", "--", *conflicted)
        return False
    repo.git("add", "--", *conflicted)
    repo.git("commit", "--no-edit", "--cleanup=strip")
    return True


def test_changelog_only_conflict_merges_without_judgment(tmp_path):
    repo = make_wave(tmp_path, {".": {"CHANGELOG.md": {"rule": "union-lines"}}}, {"CHANGELOG.md": CHANGELOG})
    assert repo.conflicted() == ["CHANGELOG.md"]
    r = repo.resolver()
    assert r.returncode == 0, r.stderr
    out = json.loads(r.stdout)
    assert [(x["path"], x["rule"]) for x in out["resolved"]] == [("CHANGELOG.md", "union-lines")]
    assert out["resolved"][0]["changes"] and out["unclaimed"] == [] and out["refused"] == []
    assert finish_documented_sequence(repo, {})
    body = (tmp_path / "CHANGELOG.md").read_text()
    assert "- one" in body and "- two" in body and "<<<<" not in body
    assert repo.git("log", "-1", "--format=%s").stdout.strip() == "Merge story: two"
    assert repo.git("ls-files", "-u").stdout == ""


def test_mixed_conflict_judges_only_the_undeclared_file_and_commits_together(tmp_path):
    repo = make_wave(tmp_path, {".": {"CHANGELOG.md": {"rule": "union-lines"}}},
                     {"CHANGELOG.md": CHANGELOG, "code.py": CODE})
    out = json.loads(repo.resolver().stdout)
    resolved = {x["path"] for x in out["resolved"]}
    assert resolved == {"CHANGELOG.md"}
    judged = [p for p in repo.conflicted() if p not in resolved]
    assert judged == ["code.py"]
    assert "<<<<" not in (tmp_path / "CHANGELOG.md").read_text()
    assert "<<<<" in (tmp_path / "code.py").read_text()
    assert finish_documented_sequence(repo, {"code.py": "x = 3\n"})
    assert repo.git("ls-files", "-u").stdout == ""
    merges = repo.git("log", "--merges", "--format=%s").stdout.split("\n")
    assert merges[0] == "Merge story: two"


def test_failed_verify_restores_both_sets_and_a_rerun_resolves_identically(tmp_path):
    repo = make_wave(tmp_path, {".": {"CHANGELOG.md": {"rule": "union-lines"}}},
                     {"CHANGELOG.md": CHANGELOG, "code.py": CODE})
    first = repo.resolver()
    assert not finish_documented_sequence(repo, {"code.py": "x = 3\n"}, verify_ok=False)
    # both files are back to git's own conflict: the rule's output and the judged edit are gone
    assert sorted(repo.conflicted()) == ["CHANGELOG.md", "code.py"]
    for rel in ("CHANGELOG.md", "code.py"):
        assert "<<<<" in (tmp_path / rel).read_text()
    second = repo.resolver()
    assert second.returncode == 0 and json.loads(second.stdout) == json.loads(first.stdout)


def test_unclaimed_file_goes_to_judgment_and_is_named(tmp_path):
    repo = make_wave(tmp_path, {".": {"CHANGELOG.md": {"rule": "union-lines"}}},
                     {"CHANGELOG.md": ("# Log\n", "# Log\n- one\n", "# Log\n- one\n- two\n"), "code.py": CODE})
    out = json.loads(repo.resolver().stdout)
    named = {x["path"] for x in out["resolved"]} | {x["path"] for x in out["unclaimed"]}
    assert "code.py" not in named and out["refused"] == []
    assert "code.py" in repo.conflicted()


def test_refusal_stops_before_judgment_and_writes_nothing(tmp_path):
    repo = make_wave(tmp_path, {".": {"VERSION": {"rule": "max-version"}}},
                     {"VERSION": ("1.0.0\n", "1.1\n", "1.2.3\n")})
    before = (tmp_path / "VERSION").read_bytes()
    r = repo.resolver()
    assert r.returncode == 1
    out = json.loads(r.stdout)
    assert [(x["path"], x["rule"], x["kind"]) for x in out["refused"]] == [("VERSION", "max-version", "unproducible")]
    assert (tmp_path / "VERSION").read_bytes() == before
    assert repo.conflicted() == ["VERSION"]


def test_malformed_declaration_exits_one_with_empty_stdout(tmp_path):
    repo = make_wave(tmp_path, None, {"CHANGELOG.md": CHANGELOG})
    (tmp_path / ".aimi" / "config.json").write_text("{not json")
    r = repo.resolver()
    assert r.returncode == 1 and r.stdout == "" and r.stderr.strip()


def test_nothing_declared_leaves_the_loop_untouched(tmp_path):
    repo = make_wave(tmp_path, None, {"CHANGELOG.md": CHANGELOG})
    r = repo.resolver()
    assert r.returncode == 0
    assert json.loads(r.stdout) == {"resolved": [], "unclaimed": [], "refused": []}
    assert "<<<<" in (tmp_path / "CHANGELOG.md").read_text()
    assert repo.conflicted() == ["CHANGELOG.md"]
