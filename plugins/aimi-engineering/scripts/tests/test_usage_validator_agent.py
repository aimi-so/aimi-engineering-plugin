"""Pins agents/review/aimi-usage-validator.md and its one example verdict block.

The block's schema is written in the docstring of `usage_validation_verdict`;
the example is fed to that function so the two cannot drift. The file is read
as text; nothing is executed."""

import json
import os
import re
import sys
import tempfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import usage_validation  # noqa: E402

AGENT = ROOT / "agents" / "review" / "aimi-usage-validator.md"
FENCE = "`" * 3
TAG = FENCE + "usage_validation_verdict"


@pytest.fixture(scope="module")
def text():
    return AGENT.read_text(encoding="utf-8")


def _fences(text):
    return [ln for ln in text.splitlines() if ln.startswith(FENCE)]


def _example(text):
    start = text.index(TAG + "\n") + len(TAG) + 1
    return json.loads(text[start:text.index("\n" + FENCE, start)])


def test_usage_validator_frontmatter_is_pinned(text):
    front = text.split("---")[1]
    assert re.search(r"^name: aimi-usage-validator$", front, re.M)
    assert re.search(r'^description: ".{40,}"$', front, re.M)
    assert re.search(r"^model: inherit$", front, re.M)
    assert re.search(r"^tools: Read, Grep, Glob, Bash, mcp__claude-in-chrome__\*$", front, re.M)
    assert text.startswith("---\nname: aimi-usage-validator\n")


def test_usage_validator_stays_small_and_clear_of_the_block_suites(text):
    assert len(text.encode("utf-8")) <= 16384
    assert FENCE + "bash" not in text
    assert ".aimi/" not in text
    for cite in ("BusinessSpec § 2", "BusinessSpec § 7", "BusinessSpec § 9"):
        assert cite in text


def test_usage_validator_names_every_input(text):
    for name in ("CHARTERS", "SURFACES", "SPECS", "TASKS_FILE", "ORIGINS", "BROWSER", "SESSION",
                 "SESSION_NAME", "EVIDENCE_DIR", "RECHECK", "ACTION_CAP", "CHARTER_CAP"):
        assert f"`{name}`" in text, name
    for word in ("CH-<story id>", "CH-<n>-<story id>", "tasksFile", "deferred-verification"):
        assert word in text, word


def test_usage_validator_walks_a_persona_with_the_four_questions(text):
    assert "cognitive walkthrough" in text
    assert "numbered from 1" in text
    for h in ("H1", "H10"):
        assert h in text
    assert "Nielsen" in text
    assert "DesignSpec silence never authorizes a departure" in text
    assert "agent-browser set viewport" in text


def test_usage_validator_keeps_the_browser_rules(text):
    for rule in ("agent-browser auth", "--state", "--profile", "--auto-connect", "throwaway `HOME`",
                 "Navigate only to `ORIGINS`", "never `executed`"):
        assert rule in text, rule


def test_usage_validator_rates_and_explores_within_bounds(text):
    assert "rated 2 at most" in text
    assert "No two findings of one charter share a step and a heuristic" in text
    assert "Explore <target> with <resources> to discover <risks>" in text
    assert "`EX-1`" in text and "SFDPOT" in text
    assert "3 and 40" in text and "never by wall time" in text


def test_usage_validator_ends_with_exactly_one_verdict_block(text):
    tagged = [ln for ln in _fences(text) if ln == TAG]
    assert len(tagged) == 1
    fences = _fences(text)
    assert fences[-2] == TAG and fences[-1] == FENCE


def test_usage_validator_example_fails_with_a_bug_a_decision_and_an_unmapped_finding(text):
    block = _example(text)
    with tempfile.TemporaryDirectory() as ev:
        for f in block["findings"]:
            for e in f["evidence"]:
                p = os.path.join(ev, e["path"])
                os.makedirs(os.path.dirname(p), exist_ok=True)
                Path(p).write_text("x")
        answer = usage_validation.usage_validation_verdict(
            "prose\n" + text[text.index(TAG):], ["CH-US-001", "CH-US-002"], ev)
    assert answer["outcome"] == "fails"
    assert answer["outcome"] != "tooling-failed"
    assert len(answer["bugs"]) == 1
    assert len(answer["decisions"]) == 1
    assert len(answer["unmapped"]) == 1
    assert [b["id"] for b in answer["blockedCharters"]] == ["CH-US-002"]
