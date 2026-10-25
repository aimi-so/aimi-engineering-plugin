"""Tests for tasks.py's guard-rail readers: broken_rail_indices and guard_rail_findings.

A guard rail is the exact text of ONE top-level segment of
implementation.verify. These two readers say which rails are not, and why, in
words an expander can act on (issue 169: a rail naming one line inside a
function definition). They share one segment-membership helper with the
validator's _guard_rail_errors, and the validator's three messages must not
move.
"""

import inspect
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import tasks as T  # noqa: E402

FUNCTION_VERIFY = (
    "set -e\n"
    "M=/tmp/x\n"
    "file_ok() {\n"
    '  test -f "$M/$1"\n'
    '  grep -q ok "$M/$1"\n'
    "}\n"
    "file_ok a"
)
FUNCTION_DEF = 'file_ok() {\n  test -f "$M/$1"\n  grep -q ok "$M/$1"\n}'
HEREDOC = "python3 - <<'EOF'\nprint(1)\nEOF"


def story(verify, rails):
    implementation = {}
    if verify is not None:
        implementation["verify"] = verify
    if rails is not None:
        implementation["guardRails"] = rails
    return {"id": "US-001", "implementation": implementation}


def only(findings):
    assert len(findings) == 1
    return findings[0]


def test_issue_169_repro_names_the_function_and_the_remedy():
    st = story(FUNCTION_VERIFY, ['test -f "$M/$1"'])
    assert T.broken_rail_indices(st) == [0]
    finding = only(T.guard_rail_findings(st))
    assert "implementation.guardRails[0]" in finding
    assert "function definition" in finding
    assert "top-level segment" in finding
    assert "whole function definition" in finding
    assert "top-level call line" in finding
    assert "never a line inside it" in finding


def test_rails_that_are_segments_are_in_sync():
    for rail in (FUNCTION_DEF, "file_ok a", "set -e", "M=/tmp/x"):
        st = story(FUNCTION_VERIFY, [rail])
        assert T.broken_rail_indices(st) == []
        assert T.guard_rail_findings(st) == []


def test_a_whole_heredoc_segment_terminator_included_is_a_segment():
    verify = "set -e\n" + HEREDOC + "\ntrue"
    assert T.broken_rail_indices(story(verify, [HEREDOC])) == []
    assert T.guard_rail_findings(story(verify, [HEREDOC])) == []


def test_each_compound_kind_is_named():
    cases = {
        "for/while/until loop": "for f in a b; do\n  test -f $f\ndone",
        "if/case block": "if true; then\n  test -f a\nfi",
        "{ } group": "{\n  test -f a\n  test -f b\n}",
        "( ) subshell": "(\n  test -f a\n  test -f b\n)",
    }
    for kind, block in cases.items():
        verify = "set -e\n" + block
        inner = [line for line in block.split("\n") if "test -f" in line][0].strip()
        st = story(verify, [inner])
        assert T.broken_rail_indices(st) == [0], kind
        assert kind in only(T.guard_rail_findings(st)), kind


def test_while_and_until_loops_use_the_loop_name():
    for opener in ("while true; do", "until false; do"):
        verify = opener + "\n  test -f a\n  break\ndone"
        st = story(verify, ["test -f a"])
        assert "for/while/until loop" in only(T.guard_rail_findings(st))


def test_case_block_is_named():
    verify = 'case "$1" in\n  a) test -f a ;;\nesac'
    finding = only(T.guard_rail_findings(story(verify, ["a) test -f a ;;"])))
    assert "if/case block" in finding


def test_a_line_inside_a_heredoc_body_is_explained_as_a_heredoc():
    verify = "set -e\n" + HEREDOC + "\ntrue"
    st = story(verify, ["print(1)"])
    assert T.broken_rail_indices(st) == [0]
    finding = only(T.guard_rail_findings(st))
    assert "heredoc" in finding
    assert "implementation.guardRails[0]" in finding


def test_a_rail_inside_a_plain_longer_command_gets_the_generic_sentence():
    st = story("set -e\ncat a | grep -q b", ["grep -q b"])
    finding = only(T.guard_rail_findings(st))
    assert "larger segment" in finding
    assert "top-level segment" in finding


def test_a_rail_that_matches_nothing_asks_for_the_exact_segment_text():
    st = story("set -e\ntrue", ["nothing like it"])
    assert T.broken_rail_indices(st) == [0]
    finding = only(T.guard_rail_findings(st))
    assert "matches no segment" in finding
    assert "exact text" in finding


def test_non_string_and_empty_entries_have_a_sentence_of_their_own():
    st = story("true", [5, "", None, "true"])
    assert T.broken_rail_indices(st) == [0, 1, 2]
    findings = T.guard_rail_findings(st)
    assert len(findings) == 3
    for i, finding in enumerate(findings):
        assert "implementation.guardRails[%d]" % i in finding
        assert "non-empty string" in finding


def test_missing_verify_reports_every_rail_with_its_own_sentence():
    for verify in (None, 7, ["true"]):
        st = story(verify, ["true", "false"])
        assert T.broken_rail_indices(st) == [0, 1]
        findings = T.guard_rail_findings(st)
        assert len(findings) == 2
        assert all("no implementation.verify" in f for f in findings)
        assert "implementation.guardRails[1]" in findings[1]


def test_absent_or_non_list_guard_rails_report_nothing():
    for st in (
        {},
        {"implementation": None},
        {"implementation": "x"},
        story("true", None),
        story("true", "true"),
        story("true", {"a": 1}),
        "not a story",
        None,
        [],
    ):
        assert T.broken_rail_indices(st) == []
        assert T.guard_rail_findings(st) == []


def test_duplicated_rails_are_allowed_and_each_broken_one_is_reported():
    assert T.broken_rail_indices(story("true\nfalse", ["true", "true"])) == []
    st = story("true\nfalse", ["nope", "true", "nope"])
    assert T.broken_rail_indices(st) == [0, 2]
    findings = T.guard_rail_findings(st)
    assert "guardRails[0]" in findings[0] and "guardRails[2]" in findings[1]


def test_findings_are_in_index_order_and_one_per_broken_rail():
    st = story(
        FUNCTION_VERIFY,
        ["set -e", 'grep -q ok "$M/$1"', 5, "file_ok a", "zzz"],
    )
    assert T.broken_rail_indices(st) == [1, 2, 4]
    findings = T.guard_rail_findings(st)
    assert [f.split("]")[0].split("[")[1] for f in findings] == ["1", "2", "4"]


def test_findings_hold_no_backtick_no_dollar_paren_and_stay_short():
    hostile = "echo `date` $(whoami) " + "x" * 600
    verify = "set -e\nf() {\n  " + hostile + "\n}\nf"
    for rail in (hostile, "`nope` $(nope) " + "y" * 900):
        findings = T.guard_rail_findings(story(verify, [rail]))
        assert len(findings) == 1
        finding = findings[0]
        assert "`" not in finding
        assert "$(" not in finding
        assert len(finding) < 500
        assert "x" * 100 not in finding and "y" * 100 not in finding


def test_a_dollar_paren_assembled_by_the_cut_is_still_removed():
    finding = only(T.guard_rail_findings(story("true", ["$$(((echo" + "z" * 50])))
    assert "$(" not in finding


def test_the_membership_test_exists_once():
    helper = inspect.getsource(T._broken_guard_rails)
    assert "verify_segments(" in helper
    for fn in (
        T._guard_rail_errors,
        T.broken_rail_indices,
        T.guard_rail_findings,
        T._guard_rail_subject,
    ):
        assert "verify_segments(" not in inspect.getsource(fn)
    for fn in (T._guard_rail_errors, T.broken_rail_indices, T.guard_rail_findings):
        assert "_broken_guard_rails(" in inspect.getsource(fn)
    module = inspect.getsource(T)
    uses = [
        line for line in module.splitlines()
        if "verify_segments(" in line and "def verify_segments" not in line
        and not line.lstrip().startswith(("#", '"', "`"))
    ]
    guard_lines = [line for line in uses if "for _, segment in verify_segments(verify)" in line]
    assert len(guard_lines) == 1


def test_validator_messages_are_unchanged():
    doc = {
        "userStories": [
            {
                "id": "US-009",
                "implementation": {"verify": "true\nfalse", "guardRails": ["true", 5, "", "nope"]},
            }
        ]
    }
    errors = [e for e in T._guard_rail_errors("US-009", doc["userStories"][0])]
    assert errors == [
        "US-009: implementation.guardRails[1] must be a non-empty string",
        "US-009: implementation.guardRails[2] must be a non-empty string",
        "US-009: implementation.guardRails[3] matches no segment of implementation.verify",
    ]
    assert T._guard_rail_errors(
        "US-009", {"implementation": {"guardRails": "true"}}
    ) == ["US-009: implementation.guardRails must be an array"]
    assert T._guard_rail_errors(
        "US-009", {"implementation": {"guardRails": ["true"]}}
    ) == ["US-009: implementation.guardRails[0] matches no segment of implementation.verify"]


def test_the_validator_and_both_readers_agree_on_which_rails_are_broken():
    st = story(FUNCTION_VERIFY, ['test -f "$M/$1"', "file_ok a", "", 3])
    indices = T.broken_rail_indices(st)
    errors = T._guard_rail_errors("US-001", st)
    assert [int(e.split("[")[1].split("]")[0]) for e in errors] == indices
    assert len(T.guard_rail_findings(st)) == len(indices)


def test_known_limitation_nested_quoting_under_counts_segments():
    """Known gap 2026-09-10-US-001, pinned and NOT fixed here.

    A single quote inside a double-quoted command substitution holding a
    double quote leaves verify_segments inside a quote it never closes, so
    every line after it fuses into the first segment. A rail naming one of
    those later lines is then reported inside a larger segment, although bash
    would run it as a segment of its own. This test records today's behaviour;
    when the scanner is fixed it should change with it.
    """
    verify = "x=\"$(echo 'a\"b')\"\ntrue\nfalse\ntrue"
    segments = [text for _, text in T.verify_segments(verify)]
    assert len(segments) == 1
    assert segments[0] == verify
    assert T.verify_unterminated(verify) == "single-quote"
    assert T.broken_rail_indices(story(verify, ["false"])) == [0]
    assert "larger segment" in only(T.guard_rail_findings(story(verify, ["false"])))
