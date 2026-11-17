"""Tests for scripts/bookkeeping_rules.py, the pure resolver of conflicted
bookkeeping files.

Every case is an in-memory string fixture: the module reads no file. What is
pinned: each rule's result, the refusal kind of each way a rule can fail, the
whole-file-or-nothing claim of the three walk rules, union-lines idempotence,
and that the module imports no I/O module.
"""

import os
import re
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
sys.path.insert(0, SCRIPTS)

import bookkeeping_rules as B  # noqa: E402

MODULE = os.path.join(SCRIPTS, "bookkeeping_rules.py")


def resolve(rule, base, ours, theirs, measure=None):
    return B.resolve_by_rule(rule, "f.txt", base, ours, theirs, measure)


def refusal(rule, base, ours, theirs, measure=None):
    with pytest.raises(B.RuleRefusal) as exc:
        resolve(rule, base, ours, theirs, measure)
    return exc.value


# --- the shape of the module ------------------------------------------------


def test_rule_kinds_are_exactly_the_four():
    assert B.RULE_KINDS == ("union-lines", "max-version", "sum-delta", "size-step")


def test_unknown_rule_is_value_error_not_refusal():
    with pytest.raises(ValueError):
        resolve("take-ours", "a", "a", "a")


def test_refusal_kind_is_validated():
    for kind in ("unclaimed", "unproducible"):
        r = B.RuleRefusal("p", "union-lines", "why", kind)
        assert (r.path, r.rule, r.reason, r.kind) == ("p", "union-lines", "why", kind)
    with pytest.raises(ValueError):
        B.RuleRefusal("p", "union-lines", "why", "other")


def test_module_imports_no_io_module():
    src = open(MODULE, encoding="utf-8").read()
    bad = re.findall(
        r"^\s*(?:import|from)\s+(os|sys|subprocess|pathlib|shutil|tempfile|json)\b",
        src,
        re.M,
    )
    assert bad == []


# --- union-lines ------------------------------------------------------------

BASE_CL = "# Changelog\n\n## Unreleased\n\n- base\n"


def test_union_lines_keeps_both_bullets_once_and_names_added_lines():
    ours = "# Changelog\n\n## Unreleased\n\n- ours\n- base\n"
    theirs = "# Changelog\n\n## Unreleased\n\n- theirs\n- base\n"
    res = resolve("union-lines", BASE_CL, ours, theirs)
    lines = res.text.splitlines()
    assert lines.count("- ours") == 1
    assert lines.count("- theirs") == 1
    assert lines.count("- base") == 1
    assert res.text.endswith("\n")
    assert res.changes == [
        {"line": lines.index("- theirs") + 1, "before": None, "after": "- theirs"}
    ]


def test_union_lines_theirs_only_run_goes_after_its_preceding_shared_line():
    base = "a\nz\n"
    ours = "a\nz\n"
    theirs = "a\nx\ny\nz\n"
    assert resolve("union-lines", base, ours, theirs).text == "a\nx\ny\nz\n"


def test_union_lines_ours_only_lines_at_the_spot_come_first():
    base = "a\n"
    res = resolve("union-lines", base, "a\no\n", "a\nt\n")
    assert res.text == "a\no\nt\n"


def test_union_lines_is_idempotent():
    base = BASE_CL
    ours = "# Changelog\n\n## Unreleased\n\n- ours\n- base\n"
    theirs = "# Changelog\n\n## Unreleased\n\n- theirs\n- base\n"
    once = resolve("union-lines", base, ours, theirs)
    twice = resolve("union-lines", base, once.text, theirs)
    assert twice.text == once.text
    assert twice.changes == []


def test_union_lines_add_add_without_base():
    res = resolve("union-lines", None, "a\nb\n", "a\nc\n")
    assert res.text == "a\nb\nc\n"


def test_union_lines_changed_or_removed_base_line_is_unclaimed():
    assert refusal("union-lines", "a\nb\n", "a\n", "a\nb\nc\n").kind == "unclaimed"
    assert refusal("union-lines", "a\nb\n", "a\nB\n", "a\nb\n").kind == "unclaimed"


def test_union_lines_absent_side_is_unproducible():
    assert refusal("union-lines", "a\n", None, "a\n").kind == "unproducible"
    assert refusal("union-lines", "a\n", "a\n", None).kind == "unproducible"
    assert refusal("union-lines", None, None, "a\n").kind == "unproducible"


def test_union_lines_blank_lines_are_ordinary():
    base = "a\n\nb\n"
    ours = "a\n\no\nb\n"
    theirs = "a\n\nt\nb\n"
    assert resolve("union-lines", base, ours, theirs).text == "a\n\no\nt\nb\n"


# --- undecodable side -------------------------------------------------------


def test_undecodable_side_is_unproducible():
    assert refusal("union-lines", "a\n", b"a\n", "a\n").kind == "unproducible"
    assert refusal("sum-delta", "1\n", "2\n", "\udcff").kind == "unproducible"


# --- max-version ------------------------------------------------------------


def j(v, tail=","):
    return '{\n  "name": "x",\n  "version": "%s"%s\n}\n' % (v, tail)


def test_max_version_json_line_keeps_the_highest():
    res = resolve("max-version", j("1.9.0"), j("1.10.0"), j("1.9.5"))
    assert res.text == j("1.10.0")
    assert res.changes == []  # ours already holds the highest
    res = resolve("max-version", j("1.9.0"), j("1.9.5"), j("1.10.0"))
    assert res.text == j("1.10.0")
    assert res.changes == [
        {"line": 3, "before": '  "version": "1.9.5",', "after": '  "version": "1.10.0",'}
    ]


def test_max_version_bare_line():
    assert resolve("max-version", "1.2.3\n", "1.2.4\n", "1.3.0\n").text == "1.3.0\n"


def test_max_version_unparseable_or_mixed_part_counts_is_unproducible():
    assert refusal("max-version", j("1.0.0"), j("1.0.x"), j("1.0.1")).kind == "unproducible"
    assert refusal("max-version", j("1.0.0"), j("1.1"), j("1.0.1")).kind == "unproducible"


def test_max_version_non_version_conflicting_line_is_unclaimed_whole_file():
    base = "x: 1\n1.0.0\n"
    ours = "x: 2\n1.0.1\n"
    theirs = "x: 3\n1.0.2\n"
    assert refusal("max-version", base, ours, theirs).kind == "unclaimed"


def test_max_version_line_count_mismatch_is_unclaimed():
    assert refusal("max-version", "1.0.0\n", "1.0.1\n", "1.0.2\nextra\n").kind == "unclaimed"


# --- sum-delta --------------------------------------------------------------


def test_sum_delta_is_ours_plus_theirs_minus_base():
    base = "EXPECTED_ASSERTIONS=100\nrest\n"
    ours = "EXPECTED_ASSERTIONS=103\nrest\n"
    theirs = "EXPECTED_ASSERTIONS=105\nrest\n"
    res = resolve("sum-delta", base, ours, theirs)
    assert res.text == "EXPECTED_ASSERTIONS=108\nrest\n"
    assert res.changes == [
        {"line": 1, "before": "EXPECTED_ASSERTIONS=103", "after": "EXPECTED_ASSERTIONS=108"}
    ]


def test_sum_delta_missing_base_negative_or_non_integer_is_unproducible():
    assert refusal("sum-delta", None, "n=1\n", "n=2\n").kind == "unproducible"
    assert refusal("sum-delta", "n=10\n", "n=1\n", "n=2\n").kind == "unproducible"
    assert refusal("sum-delta", "n=1\n", "n=2\n", "n=x\n").kind == "unproducible"
    assert refusal("sum-delta", "n=1\n", "n=2\n", "n=3.5\n").kind == "unproducible"


def test_sum_delta_unclaimable_line_refuses_whole_file():
    base = "n=1\ntitle a\n"
    ours = "n=2\ntitle b\n"
    theirs = "n=3\ntitle c\n"
    assert refusal("sum-delta", base, ours, theirs).kind == "unclaimed"


# --- size-step --------------------------------------------------------------


def sizes(table):
    return lambda path: table.get(path)


def test_size_step_rounds_up_to_a_multiple_of_4096():
    base = "a.md\t16384\nb.md\t20480\n"
    ours = "a.md\t20480\nb.md\t20480\n"
    theirs = "a.md\t24576\nb.md\t20480\n"
    res = resolve("size-step", base, ours, theirs, sizes({"a.md": 20481}))
    assert res.text == "a.md\t24576\nb.md\t20480\n"
    res = resolve("size-step", base, ours, theirs, sizes({"a.md": 20480}))
    assert res.text == "a.md\t20480\nb.md\t20480\n"


def test_size_step_measure_none_is_unproducible_and_conflicted_is_unclaimed():
    base, ours, theirs = "a.md\t16384\n", "a.md\t20480\n", "a.md\t24576\n"
    assert refusal("size-step", base, ours, theirs, sizes({})).kind == "unproducible"
    assert refusal("size-step", base, ours, theirs).kind == "unproducible"
    assert (
        refusal("size-step", base, ours, theirs, lambda p: B.CONFLICTED).kind
        == "unclaimed"
    )


def test_size_step_size_at_or_under_the_floor_is_unclaimed():
    base, ours, theirs = "a.md\t16384\n", "a.md\t20480\n", "a.md\t24576\n"
    for size in (16384, 100):
        assert refusal("size-step", base, ours, theirs, sizes({"a.md": size})).kind == "unclaimed"


def test_size_step_unclaimed_row_refuses_whole_file_with_no_partial_text():
    base = "a.md\t16384\nb.md\t16384\n"
    ours = "a.md\t20480\nb.md\t20480\n"
    theirs = "a.md\t24576\nb.md\t24576\n"
    r = refusal("size-step", base, ours, theirs, sizes({"a.md": 20481, "b.md": 100}))
    assert r.kind == "unclaimed"
    assert (r.path, r.rule) == ("f.txt", "size-step")


def test_size_step_non_row_conflict_is_unclaimed():
    assert (
        refusal("size-step", "# h\n", "# a\n", "# b\n", sizes({})).kind == "unclaimed"
    )


def test_walk_yields_to_the_side_that_changed_and_keeps_equal_lines():
    base = "n=1\nm=5\nk=7\n"
    ours = "n=1\nm=6\nk=7\n"
    theirs = "n=2\nm=5\nk=7\n"
    assert resolve("sum-delta", base, ours, theirs).text == "n=2\nm=6\nk=7\n"
