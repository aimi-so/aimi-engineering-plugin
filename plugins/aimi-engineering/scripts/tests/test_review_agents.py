"""Pins the review agents and the command that spawns them.

`/aimi:review` merges and checks what its reviewers return, which works only
while they return one shape. Nine files in agents/review/ review code; each
ends with the same two sections, byte for byte, and the command, the catalogue
and the README all name the same nine. The cross-story auditor shares the
directory and none of this: it audits staged stories, not code.
Files are read as text; nothing is executed.
"""

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
REPO = ROOT.parent.parent
REVIEW = ROOT / "agents" / "review"

REVIEWERS = [
    "aimi-correctness-reviewer",
    "aimi-security-reviewer",
    "aimi-performance-reviewer",
    "aimi-maintainability-reviewer",
    "aimi-project-standards-reviewer",
    "aimi-frontend-races-reviewer",
    "aimi-agent-native-reviewer",
    "aimi-data-migration-reviewer",
    "aimi-deployment-verification-agent",
]
SHARED = ("## How you work", "## What you return")


def _text(name):
    return (REVIEW / f"{name}.md").read_text(encoding="utf-8")


def test_the_review_directory_holds_these_reviewers_and_the_auditor_only():
    found = sorted(p.stem for p in REVIEW.glob("*.md"))
    assert found == sorted(REVIEWERS + ["aimi-cross-story-auditor"])


@pytest.mark.parametrize("name", REVIEWERS)
def test_a_reviewer_names_itself_and_inherits_its_category_model(name):
    front = _text(name).split("---")[1]
    assert re.search(rf"^name: {re.escape(name)}$", front, re.M), name
    assert re.search(r'^description: ".{40,}"$', front, re.M), name
    assert re.search(r"^model: inherit$", front, re.M), name


def test_every_reviewer_ends_with_the_same_two_sections():
    tails = {}
    for name in REVIEWERS:
        text = _text(name)
        for heading in SHARED:
            assert text.count(heading) == 1, f"{name}: {heading!r} must appear once"
        assert text.index(SHARED[0]) < text.index(SHARED[1]), name
        tails[name] = text[text.index(SHARED[0]):]
    assert len(set(tails.values())) == 1, (
        "the closing sections differ between: "
        + ", ".join(sorted(n for n, t in tails.items() if t != tails[REVIEWERS[0]]))
    )


def test_the_shared_sections_ask_for_the_line_and_forbid_changing_the_repository():
    tail = _text(REVIEWERS[0])
    assert "**Quote:**" in tail and "**Location:**" in tail
    for severity in ("P1", "P2", "P3"):
        assert severity in tail
    assert "Never edit, write, stage, commit or otherwise change the repository" in tail


def test_the_command_spawns_reviewers_through_one_literal_template_and_names_all_nine():
    command = (ROOT / "commands" / "review.md").read_text(encoding="utf-8")
    # install.sh rewrites this literal and adds the OpenCode preamble only when the body has it
    assert 'Task subagent_type="aimi-engineering:review:[REVIEWER]"' in command
    assert '[model: <AGENT_MODELS.review when not "inherit">]' in command
    for name in REVIEWERS:
        assert f"`{name}`" in command, f"review.md does not name {name}"
    for line in ("REPO:", "WORKDIR:", "REVISION:", "DIFF_CMD:", "SCOPE:", "FOCUS:", "INTENT:",
                 "PROJECT_GUIDELINES:", "RELATED:", "DESIGN_REFERENCE:", "FILES:"):
        assert line in command, line


def test_the_prompt_lines_the_command_sends_are_the_ones_the_reviewers_read():
    how = _text(REVIEWERS[0])
    for word in ("REPO", "WORKDIR", "REVISION", "DIFF_CMD", "SCOPE", "FOCUS", "INTENT",
                 "PROJECT_GUIDELINES", "RELATED", "DESIGN_REFERENCE", "FILES"):
        assert f"`{word}`" in how, word


def test_the_reviewers_return_their_coverage_by_path():
    # Step 4's second pass is chosen from these lists, so every reviewer must name files
    tail = _text(REVIEWERS[0])
    assert "the changed files you read, and the changed files you did not read" in tail
    command = (ROOT / "commands" / "review.md").read_text(encoding="utf-8")
    assert "Not read by any reviewer:" in command


def test_the_catalogue_lists_the_same_reviewers():
    catalogue = (REPO / "docs" / "agents-and-skills.md").read_text(encoding="utf-8")
    section = catalogue.split("### Review (")[1].split("###")[0]
    listed = sorted(re.findall(r"^\| `(aimi-[a-z-]+)` \|", section, re.M))
    assert listed == sorted(REVIEWERS + ["aimi-cross-story-auditor"])


def test_the_readme_counts_match_the_tree():
    readme = (REPO / "README.md").read_text(encoding="utf-8")
    agents = len(list((ROOT / "agents").glob("*/*.md")))
    skills = len(list((ROOT / "skills").glob("*/SKILL.md")))
    assert re.search(rf"^\| Agents \| {agents} \|", readme, re.M), f"README agents row should say {agents}"
    assert re.search(rf"^\| Skills \| {skills} \|", readme, re.M), f"README skills row should say {skills}"
    review = len(list(REVIEW.glob("*.md")))
    assert f"{review} review," in readme


def test_the_plugin_notice_credits_every_reviewer_and_ships_with_the_plugin():
    notice = (ROOT / "NOTICE.md").read_text(encoding="utf-8")
    for name in REVIEWERS:
        assert f"`{name}`" in notice, f"NOTICE.md does not credit {name}"
    assert "Copyright (c) 2025 Every" in notice
    assert "Permission is hereby granted" in notice
    # a notice under agents/ would be installed as an agent
    assert not list((ROOT / "agents").rglob("NOTICE*"))
