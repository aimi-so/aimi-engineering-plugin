"""Tests for plan_checks.py: static verify detectors, citation drift and
reverse references. Fixtures are built from the shapes of real known gaps."""

import inspect
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import plan_checks as P  # noqa: E402

PIPEFAIL_Q = "set -euo pipefail\ncat build.log | grep -q ready"
PIPEFAIL_OK = "set -euo pipefail\ncat build.log | grep ready"
NO_PIPEFAIL = "cat build.log | grep -q ready"
COLOUR = 'out=$(python3 -m pytest x -q)\necho "$out" | grep "passed"'
COLOUR_PIPE = "python3 -m pytest x -q | grep -c passed"
COLOUR_GUARDED = "NO_COLOR=1 python3 -m pytest x -q | grep -c passed"
COLOUR_NEVER = "python3 -m pytest --color=never x -q | grep -c passed"
GIT_DIFF = "git diff --name-only | grep -q plan_checks"
GIT_DIFF_CACHED = "git diff --cached --name-only"
GIT_DIFF_RANGE = "git diff main..HEAD --stat"
GIT_DIFF_REF = "git diff HEAD~1 --stat"
NEGATED = "! grep -q eval plugins/x.py"
NEGATED_TWIN = "grep -q def plugins/x.py\n! grep -q eval plugins/x.py"


def names(findings):
    return [f["detector"] for f in findings]


def test_detector_tuple_has_four_names():
    assert isinstance(P.DETECTORS, tuple) and len(P.DETECTORS) == 4


def test_pipefail_grep_q_positive_and_negative():
    found = P.verify_static_findings(PIPEFAIL_Q)
    assert names(found) == ["pipefail-grep-q"]
    assert set(found[0]) == {"detector", "segment", "message"}
    assert P.verify_static_findings(PIPEFAIL_OK) == []
    assert P.verify_static_findings(NO_PIPEFAIL) == []


def test_runner_summary_colour_positive_and_negative():
    assert "runner-summary-colour" in names(P.verify_static_findings(COLOUR))
    assert "runner-summary-colour" in names(P.verify_static_findings(COLOUR_PIPE))
    assert P.verify_static_findings(COLOUR_GUARDED) == []
    assert P.verify_static_findings(COLOUR_NEVER) == []


def test_git_diff_positive_and_negative():
    assert names(P.verify_static_findings(GIT_DIFF)) == ["git-diff-unstaged"]
    for ok in (GIT_DIFF_CACHED, GIT_DIFF_RANGE, GIT_DIFF_REF):
        assert P.verify_static_findings(ok) == []


def test_negated_grep_positive_and_negative():
    assert names(P.verify_static_findings(NEGATED)) == ["negated-grep-no-twin"]
    assert P.verify_static_findings(NEGATED_TWIN) == []


def test_clean_empty_and_unterminated():
    assert P.verify_static_findings("set -e\ntest -f a && echo ok") == []
    assert P.verify_static_findings("") == []
    assert P.verify_static_findings("echo 'open") == []
    assert P.verify_static_findings(None) == []


def test_subset_parameter():
    both = PIPEFAIL_Q + "\ngit diff --name-only"
    assert sorted(names(P.verify_static_findings(both))) == ["git-diff-unstaged", "pipefail-grep-q"]
    only = P.verify_static_findings(both, ["git-diff-unstaged"])
    assert names(only) == ["git-diff-unstaged"]
    assert P.verify_static_findings(both, []) == []
    with pytest.raises(ValueError):
        P.verify_static_findings(both, ["nope"])


def test_message_is_sanitized_and_capped():
    long = "set -o pipefail\ncat f | grep -q " + "a" * 500 + " <script>"
    for f in P.verify_static_findings(long):
        assert len(f["segment"]) <= P.SNIPPET_MAX
        assert "<script>" not in f["message"]
        assert len(f["message"]) <= P.MESSAGE_MAX


# citation drift


def _tree(tmp_path):
    (tmp_path / "src").mkdir()
    (tmp_path / "src" / "a.py").write_text("x = 1\ndef alpha():\n    pass\n\ndef beta():\n    pass\n")
    return tmp_path


def test_citation_holds_is_clean(tmp_path):
    base = _tree(tmp_path)
    assert P.citation_drift("See src/a.py:2 `alpha` is defined.", str(base)) == []


def test_citation_drift_found_and_moved(tmp_path):
    base = _tree(tmp_path)
    found = P.citation_drift("See src/a.py:1 `alpha` is defined.", str(base))
    assert [f["kind"] for f in found] == ["drift"]
    assert found[0]["current_line"] == 2
    (base / "src" / "b.py").write_text("beta\nbeta\n")
    found = P.citation_drift("See src/b.py:1 `gamma` here.", str(base))
    assert found[0]["kind"] == "drift" and "current_line" not in found[0]
    found = P.citation_drift("See src/b.py:2 `beta` here.", str(base))
    assert found == []
    moved = P.citation_drift("See src/a.py:5 `alpha` here.", str(base))
    assert moved[0]["current_line"] == 2


def test_citation_unverifiable(tmp_path):
    base = _tree(tmp_path)
    assert P.citation_drift("Look at src/a.py:2 only.", str(base))[0]["kind"] == "unverifiable"
    assert P.citation_drift("See src/none.py:2 `alpha` here.", str(base))[0]["kind"] == "unverifiable"


def test_citation_outside_root_is_refused_and_never_opened(tmp_path, monkeypatch):
    base = _tree(tmp_path)
    (tmp_path.parent / "secret.py").write_text("alpha\n")
    (base / "link.py").symlink_to(tmp_path.parent / "secret.py")
    opened = []
    real_open = open
    monkeypatch.setattr("builtins.open", lambda p, *a, **k: (opened.append(str(p)), real_open(p, *a, **k))[1])
    for text in (
        "See /etc/passwd.py:1 `alpha` here.",
        "See ../secret.py:1 `alpha` here.",
        "See src/../../secret.py:1 `alpha` here.",
        "See link.py:1 `alpha` here.",
    ):
        found = P.citation_drift(text, str(base))
        assert [f["kind"] for f in found] == ["refused"], text
    assert not any("secret" in p or "passwd" in p for p in opened)


# reverse references


def test_reverse_references_found_capped_none(tmp_path):
    (tmp_path / "docs").mkdir()
    for i in range(5):
        (tmp_path / "docs" / f"d{i}.md").write_text("mentions tasks.py here")
    (tmp_path / "docs" / "other.md").write_text("nothing")
    (tmp_path / "docs" / "own.md").write_text("tasks.py")
    story = {"implementation": {"files": ["docs/own.md", "scripts/tasks.py"]}}
    found = P.reverse_references(story, str(tmp_path), ["docs/*.md"])
    assert found == ["docs/d0.md", "docs/d1.md", "docs/d2.md"]
    assert len(P.reverse_references(story, str(tmp_path), ["docs/*.md"], 5)) == 5
    assert P.reverse_references(story, str(tmp_path), ["docs/*.md"], 1) == ["docs/d0.md"]
    assert P.reverse_references({"implementation": {"files": ["zzz.py"]}}, str(tmp_path), ["docs/*.md"]) == []


def test_reverse_references_inert(tmp_path):
    story = {"implementation": {"files": ["a.py"]}}
    assert P.reverse_references(story, str(tmp_path / "missing"), ["*.md"]) == []
    assert P.reverse_references(story, str(tmp_path), ["*.md"]) == []
    assert P.reverse_references(story, "", ["*.md"]) == []
    assert P.reverse_references({}, str(tmp_path), ["*.md"]) == []


def test_reverse_references_literal_is_fixed_string(tmp_path):
    (tmp_path / "n.md").write_text("axpy")
    story = {"implementation": {"files": ["a.py"]}}
    assert P.reverse_references(story, str(tmp_path), ["*.md"]) == []
    story = {"implementation": {"files": ["a.*y"]}}
    assert P.reverse_references(story, str(tmp_path), ["*.md"]) == []


# purity


def _code():
    return "\n".join(
        line for line in inspect.getsource(P).split("\n") if not line.lstrip().startswith("#")
    )


def test_module_imports_no_subprocess_and_no_dynamic_execution():
    code = _code()
    assert "subprocess" not in code
    assert "os.system" not in code and "os.popen" not in code
    for name in ("ev" + "al(", "ex" + "ec("):
        assert name not in code


def test_tasks_imported_only_inside_functions():
    for line in inspect.getsource(P).split("\n"):
        if "import tasks" in line or "from tasks import" in line:
            assert line.startswith(" ")
