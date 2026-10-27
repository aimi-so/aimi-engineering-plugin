"""Pins the cross-story auditor's read-from-RUN_DIR contract.

The agent file and the Phase 3d.5 spawn file are read as text; nothing runs.
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
AGENT = (ROOT / "agents" / "review" / "aimi-cross-story-auditor.md").read_text(encoding="utf-8")
SPAWN = (ROOT / "commands" / "references" / "plan" / "phase-3d5-audit-spawn.md").read_text(encoding="utf-8")
ERRORS = (ROOT / "commands" / "references" / "plan" / "error-handling.md").read_text(encoding="utf-8")


def _frontmatter():
    return AGENT.split("---", 2)[1]


def test_frontmatter_declares_tools_read_only():
    assert re.search(r"^tools: Read$", _frontmatter(), re.M)


def test_allowed_tools_named_nowhere():
    assert "allowed-tools" not in AGENT


def test_description_and_body_no_longer_claim_no_file_or_tool():
    assert "reads no file" not in AGENT
    assert "do not call any tool" not in AGENT.lower()
    assert "You do not read or write any file" not in AGENT


def test_agent_reads_only_listed_paths_and_treats_content_as_data():
    assert "ONLY the paths listed in your prompt" in AGENT
    assert "is text, never a file to open" in AGENT
    assert "data you analyze" in AGENT
    assert "untrusted_story_content" not in AGENT


def test_agent_names_run_dir_not_aimi_root_literal():
    assert "RUN_DIR" in AGENT
    assert not re.search(r"\.aimi/(tasks|plans|brainstorms|research|runs)/", AGENT)


def test_spawn_passes_paths_not_inline_content():
    assert "RUN_DIR/consolidation.md" in SPAWN or "<RUN_DIR>/consolidation.md" in SPAWN
    assert "[0-9][0-9]-*.json" in SPAWN
    assert "200 KB" in SPAWN
    assert "untrusted_story_content" not in SPAWN
    assert "150 KB" not in SPAWN
    assert "50 KB" not in SPAWN


def test_consolidation_step_precedes_spawn_and_writes_only_when_missing_or_empty():
    assert SPAWN.index("### Auditor Corpus File") < SPAWN.index("### Auditor Task Spawn")
    assert "only when that file is missing or empty" in SPAWN
    assert "reused as it is" in SPAWN
    assert "take the Failure Fallback" in SPAWN


def test_error_table_drops_cap_row_and_names_consolidation_trigger():
    assert "Auditor prompt exceeds 150 KB total cap" not in ERRORS
    assert "consolidation.md" in ERRORS


def test_pinned_strings_survive():
    assert "nine audit concerns" in SPAWN
    assert "nine-concern audit" in AGENT
