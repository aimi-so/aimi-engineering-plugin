"""Tests for scripts/sanitize.py's rm_sanitize_report.

rm_sanitize itself is covered by test_roadmap.py's
test_sanitizers_match_the_jq_they_replaced, against the golden corpus --
nothing here duplicates that. This module covers only the classification
rm_sanitize_report adds on top: rewritten/truncated/both/neither, and the
before/after character counts a caller derives from its two return values.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import sanitize as S  # noqa: E402


def test_unchanged_value_reports_no_changes():
    """Plain text no rule touches: rm_sanitize_report reports nothing, and
    its sanitized_value is byte-identical to the input."""
    value = "a clean phase name"
    sanitized, changes = S.rm_sanitize_report(value, 200)
    assert changes == []
    assert sanitized == value
    before, after = len(value), len(sanitized)
    assert before == after == 18


def test_rewritten_only_value():
    """A single backticked span unwraps -- shorter, but nowhere near maxlen,
    so only "rewritten" fires."""
    value = "a `tick` here"
    sanitized, changes = S.rm_sanitize_report(value, 200)
    assert changes == ["rewritten"]
    assert sanitized == "a tick here"
    before, after = len(value), len(sanitized)
    assert before == 13
    assert after == 11


def test_truncated_only_value():
    """A long run of one plain character: nothing for rm_sanitize's own
    rules to rewrite, so only "truncated" fires."""
    value = "x" * 2500
    sanitized, changes = S.rm_sanitize_report(value, 2000)
    assert changes == ["truncated"]
    assert sanitized == value[:2000]
    before, after = len(value), len(sanitized)
    assert before == 2500
    assert after == 2000


def test_rewritten_and_truncated_together_in_fixed_order():
    """A long run of backticked spans: unwrapping shortens each one, but the
    unwrapped text still exceeds maxlen, so both rules fire -- and always in
    this order, never reversed."""
    value = "`t` " * 700  # 2800 raw chars
    sanitized, changes = S.rm_sanitize_report(value, 200)
    assert changes == ["rewritten", "truncated"]
    before, after = len(value), len(sanitized)
    assert before == 2800
    assert after == 200


def test_none_value_reports_no_changes():
    """len(None) would raise before either rule could be judged -- this is
    the early return that never calls rm_sanitize at all, matching
    rm_sanitize(None, maxlen)'s own None-in/None-out contract."""
    sanitized, changes = S.rm_sanitize_report(None, 200)
    assert sanitized is None
    assert changes == []


def test_sanitized_value_matches_a_caller_own_rm_sanitize_call():
    """rm_sanitize_report computes nothing a caller could use in place of its
    own rm_sanitize(value, maxlen) call -- the two must agree exactly, for
    every shape above."""
    for value, maxlen in (
        ("a clean phase name", 200),
        ("a `tick` here", 200),
        ("x" * 2500, 2000),
        ("`t` " * 700, 200),
    ):
        sanitized, _ = S.rm_sanitize_report(value, maxlen)
        assert sanitized == S.rm_sanitize(value, maxlen)
