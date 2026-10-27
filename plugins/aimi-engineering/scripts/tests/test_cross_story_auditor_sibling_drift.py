"""Pins the sibling-drift wording folded into concerns 1 and 8 of the cross-story auditor.

The agent file is read as text and nothing is executed. The checks are folded
into existing concerns, so the nine-heading shape must be unchanged.
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
AGENT_TEXT = (ROOT / "agents" / "review" / "aimi-cross-story-auditor.md").read_text(encoding="utf-8")


def _section(n):
    # Slice from one '### N.' heading to the next heading (or end of file).
    m = re.search(rf"^### {n}\. .*$", AGENT_TEXT, re.M)
    assert m, f"concern {n} heading missing"
    nxt = re.search(r"^### ", AGENT_TEXT[m.end():], re.M)
    end = m.end() + nxt.start() if nxt else len(AGENT_TEXT)
    return AGENT_TEXT[m.start():end]


def test_nine_numbered_concern_headings_remain():
    nums = re.findall(r"^### (\d+)\. ", AGENT_TEXT, re.M)
    assert nums == [str(i) for i in range(1, 10)]
    assert "nine concerns" in AGENT_TEXT
    assert "nine-concern" in AGENT_TEXT


def test_concern_one_covers_identifier_drift():
    s = _section(1)
    assert "cross-story identifier drift" in s
    assert "`--verify-evidence`" in s and "`--evidence`" in s
    assert "same identifier" in s
    assert "never compare every pair" in s.lower()
    assert "Never invent the winner" in s
    assert "unresolved[]" in s and "op: replace" in s


def test_concern_eight_covers_sibling_exact_numbers():
    s = _section(8)
    assert "exact numbers" in s
    assert "same noun" in s
    assert "Never invent the winner" in s
    assert "unresolved[]" in s
    # The new paragraph precedes the intra-story duplication paragraph.
    assert s.index("exact numbers") < s.index("intra-story duplication")
