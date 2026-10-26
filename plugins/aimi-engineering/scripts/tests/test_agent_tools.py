"""Pins each aimi agent's tool allowlist under the `tools` key Claude Code reads.

Claude Code reads `tools` (a comma string) on an agent and ignores
`allowed-tools`, so a list under the old key restricts nothing. This is an
accident guard, not a sandbox: an agent that lists Bash can still write.
Agent files are read as text; nothing is executed. Commands and skills are
not scanned and keep their own `allowed-tools` key.
"""

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
AGENTS = ROOT / "agents"

CONTEXT7 = "mcp__plugin_aimi-engineering_context7__*"
READ_ONLY = {"Read", "Grep", "Glob", "Bash"}
RESEARCHER = {"Read", "Grep", "Glob", "Write", "Bash"}

TABLE = {
    "research/aimi-spec-deriver.md": READ_ONLY,
    "workflow/aimi-scope-negative-verifier.md": READ_ONLY,
    "workflow/aimi-scope-positive-verifier.md": READ_ONLY,
    "workflow/aimi-spec-flow-symbol-extractor.md": READ_ONLY,
    "research/aimi-learnings-researcher.md": RESEARCHER,
    "research/aimi-codebase-researcher.md": RESEARCHER,
    "research/aimi-design-bundle-researcher.md": RESEARCHER,
    "research/aimi-bundle-prototype-author.md": {"Read", "Write", "Grep", "Glob"},
    "research/aimi-foundation-architect.md": {"Read", "Write", "Grep", "Glob", CONTEXT7},
    "review/aimi-cross-story-auditor.md": {"Read"},
}

TOOL_NAMES = {"Read", "Write", "Edit", "Grep", "Glob", "Bash"}
FORBIDDING = re.compile(r"\b(?:do not|don't|never|no|without)\b", re.IGNORECASE)


def _split(rel):
    text = (AGENTS / rel).read_text(encoding="utf-8")
    lines = text.splitlines()
    assert lines and lines[0] == "---", f"{rel}: no frontmatter"
    end = lines.index("---", 1)
    return lines[1:end], lines[end + 1 :]


def _tools_line(front):
    found = [ln for ln in front if re.match(r"^tools\s*:", ln)]
    assert len(found) == 1, f"expected exactly one tools line, got {found}"
    return found[0].split(":", 1)[1].strip()


def _all_agent_files():
    return sorted(p.relative_to(AGENTS).as_posix() for p in AGENTS.rglob("*.md"))


@pytest.mark.parametrize("rel", sorted(TABLE))
def test_tools_set_matches_table(rel):
    front, _ = _split(rel)
    value = _tools_line(front)
    tools = [t.strip() for t in value.split(",")]
    assert all(tools), f"{rel}: empty entry in tools line {value!r}"
    assert len(tools) == len(set(tools)), f"{rel}: duplicate tool in {value!r}"
    assert set(tools) == TABLE[rel]


def test_table_covers_the_agents_that_declare_tools():
    declared = {r for r in _all_agent_files() if any(re.match(r"^tools\s*:", ln) for ln in _split(r)[0])}
    assert declared == set(TABLE)


@pytest.mark.parametrize("rel", _all_agent_files())
def test_no_allowed_tools_key_in_frontmatter(rel):
    front, _ = _split(rel)
    assert not any(re.match(r"^allowed-tools\s*:", ln) for ln in front), rel


@pytest.mark.parametrize("rel", sorted(TABLE))
def test_tools_line_not_empty(rel):
    front, _ = _split(rel)
    assert _tools_line(front) != "", rel


@pytest.mark.parametrize("rel", sorted(TABLE))
def test_body_does_not_drift_from_frontmatter(rel):
    front, body = _split(rel)
    declared = {t.strip() for t in _tools_line(front).split(",")}
    for line in body:
        assert "allowed-tools" not in line, f"{rel}: body cites allowed-tools: {line[:80]}"
        if FORBIDDING.search(line):
            continue  # a line that forbids a tool is not a claim that the agent has it
        for span in re.findall(r"`([^`]+)`", line):
            names = [n.strip() for n in span.split(",")]
            if len(names) > 1 and all(n in TOOL_NAMES for n in names):
                missing = [n for n in names if n not in declared]
                assert not missing, f"{rel}: body lists {span!r} but frontmatter lacks {missing}"


def test_read_only_agents_state_bash_is_read_only():
    for rel, tools in TABLE.items():
        if tools == READ_ONLY:
            _, body = _split(rel)
            assert "Bash is for reading and searching only" in "\n".join(body), rel
