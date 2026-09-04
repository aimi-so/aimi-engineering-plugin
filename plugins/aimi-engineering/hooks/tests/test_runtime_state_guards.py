from __future__ import annotations

import importlib
import importlib.util
import io
import json
import os
import sys
import types
from pathlib import Path

import pytest

# Insert the hooks directory onto sys.path so we can import the guard modules.
_HOOKS_DIR = Path(__file__).parent.parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))


def _load_module(name: str, file_path: Path):
    """Load a module from a file path, using a dotted name for caching."""
    spec = importlib.util.spec_from_file_location(name, file_path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


_GUARD_RUNTIME_STATE_PATH = _HOOKS_DIR / "guard-runtime-state.py"
_GUARD_TASKS_PRESENCE_PATH = _HOOKS_DIR / "guard-tasks-presence.py"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_write_input(file_path: str) -> str:
    """Return a JSON-encoded PreToolUse payload for a Write tool call."""
    payload = {
        "tool_name": "Write",
        "tool_input": {
            "file_path": file_path,
        },
    }
    return json.dumps(payload)


def _make_skill_input(skill_name: str) -> str:
    """Return a JSON-encoded PreToolUse payload for a Skill tool call."""
    payload = {
        "tool_name": "Skill",
        "tool_input": {
            "name": skill_name,
        },
    }
    return json.dumps(payload)


def _load_runtime_state_module():
    """Load a fresh copy of guard-runtime-state module."""
    sys.modules.pop("guard_runtime_state", None)
    return _load_module("guard_runtime_state", _GUARD_RUNTIME_STATE_PATH)


def _run_guard_runtime_state(
    monkeypatch,
    stdin_payload: str,
    module=None,
) -> tuple[str, int | None]:
    """Run guard-runtime-state.py main() and capture stdout + SystemExit code.

    Pass *module* when you need to patch the module before running (e.g. to
    replace _is_alive).  If None, a fresh module is loaded automatically.
    """
    monkeypatch.setattr("sys.stdin", io.StringIO(stdin_payload))

    if module is None:
        module = _load_runtime_state_module()

    captured_output: list[str] = []

    def fake_print(*args, **kwargs):
        captured_output.append(" ".join(str(a) for a in args))

    monkeypatch.setattr("builtins.print", fake_print)

    exit_code: int | None = None
    try:
        module.main()
    except SystemExit as exc:
        exit_code = exc.code

    return "\n".join(captured_output), exit_code


def _run_guard_tasks_presence(monkeypatch, stdin_payload: str) -> tuple[str, int | None]:
    """Run guard-tasks-presence.py main() and capture stdout + SystemExit code."""
    monkeypatch.setattr("sys.stdin", io.StringIO(stdin_payload))

    sys.modules.pop("guard_tasks_presence", None)
    guard_tasks_presence = _load_module("guard_tasks_presence", _GUARD_TASKS_PRESENCE_PATH)

    captured_output: list[str] = []

    def fake_print(*args, **kwargs):
        captured_output.append(" ".join(str(a) for a in args))

    monkeypatch.setattr("builtins.print", fake_print)

    exit_code: int | None = None
    try:
        guard_tasks_presence.main()
    except SystemExit as exc:
        exit_code = exc.code

    return "\n".join(captured_output), exit_code


def _parse_deny_output(output: str) -> dict:
    return json.loads(output.strip())


# ---------------------------------------------------------------------------
# guard-runtime-state.py tests
# ---------------------------------------------------------------------------


def test_runtime_guard_blocks_state_dir(tmp_path, monkeypatch):
    """A path under .aimi/state/ should be denied."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("AIMI_RUNTIME_STATE_GUARD", raising=False)
    monkeypatch.chdir(tmp_path)

    aimi_dir = tmp_path / ".aimi"
    aimi_dir.mkdir()
    state_dir = aimi_dir / "state"
    state_dir.mkdir()

    target = state_dir / "some-state-file.json"
    target.touch()

    output, exit_code = _run_guard_runtime_state(monkeypatch, _make_write_input(str(target)))

    assert exit_code == 0
    result = _parse_deny_output(output)
    decision = result["hookSpecificOutput"]["permissionDecision"]
    assert decision == "deny"
    assert "State files reflect live runtime" in result["hookSpecificOutput"]["userMessage"]


def test_runtime_guard_blocks_learnings(tmp_path, monkeypatch):
    """A path under $HOME/.aimi/learnings/ should always be denied."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("AIMI_RUNTIME_STATE_GUARD", raising=False)
    monkeypatch.chdir(tmp_path)

    learnings_dir = tmp_path / ".aimi" / "learnings"
    learnings_dir.mkdir(parents=True)
    target = learnings_dir / "friction.jsonl"
    target.touch()

    output, exit_code = _run_guard_runtime_state(monkeypatch, _make_write_input(str(target)))

    assert exit_code == 0
    result = _parse_deny_output(output)
    assert result["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert "Friction log is append-only" in result["hookSpecificOutput"]["userMessage"]


def test_runtime_guard_blocks_telemetry(tmp_path, monkeypatch):
    """A path under $HOME/.aimi/telemetry/ should always be denied."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("AIMI_RUNTIME_STATE_GUARD", raising=False)
    monkeypatch.chdir(tmp_path)

    telemetry_dir = tmp_path / ".aimi" / "telemetry"
    telemetry_dir.mkdir(parents=True)
    target = telemetry_dir / "events.jsonl"
    target.touch()

    output, exit_code = _run_guard_runtime_state(monkeypatch, _make_write_input(str(target)))

    assert exit_code == 0
    result = _parse_deny_output(output)
    assert result["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert "Telemetry log is append-only" in result["hookSpecificOutput"]["userMessage"]


def test_runtime_guard_blocks_tasks_when_lock_alive(tmp_path, monkeypatch):
    """Tasks file should be denied when .execute.lock exists with a live PID."""
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.delenv("AIMI_RUNTIME_STATE_GUARD", raising=False)
    monkeypatch.chdir(tmp_path)

    aimi_dir = tmp_path / ".aimi"
    aimi_dir.mkdir()
    tasks_dir = aimi_dir / "tasks"
    tasks_dir.mkdir()

    tasks_file = tasks_dir / "2024-01-01-my-feature-tasks.json"
    tasks_file.touch()

    lock_file = aimi_dir / ".execute.lock"
    fake_pid = 99999
    lock_file.write_text(str(fake_pid))

    # Load the module first, then patch _is_alive to pretend the process is alive.
    mod = _load_runtime_state_module()
    mod._is_alive = lambda pid: True

    output, exit_code = _run_guard_runtime_state(
        monkeypatch, _make_write_input(str(tasks_file)), module=mod
    )

    assert exit_code == 0
    result = _parse_deny_output(output)
    assert result["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert "Execute lock is active" in result["hookSpecificOutput"]["userMessage"]


def test_runtime_guard_allows_tasks_when_lock_missing(tmp_path, monkeypatch):
    """Tasks file should be allowed when no .execute.lock exists."""
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.delenv("AIMI_RUNTIME_STATE_GUARD", raising=False)
    monkeypatch.chdir(tmp_path)

    aimi_dir = tmp_path / ".aimi"
    aimi_dir.mkdir()
    tasks_dir = aimi_dir / "tasks"
    tasks_dir.mkdir()

    tasks_file = tasks_dir / "2024-01-01-my-feature-tasks.json"
    tasks_file.touch()

    # No lock file created.

    output, exit_code = _run_guard_runtime_state(monkeypatch, _make_write_input(str(tasks_file)))

    assert exit_code == 0
    assert output.strip() == "" or "deny" not in output


def test_runtime_guard_allows_tasks_when_lock_pid_dead(tmp_path, monkeypatch):
    """Tasks file should be allowed when lock exists but PID is dead."""
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.delenv("AIMI_RUNTIME_STATE_GUARD", raising=False)
    monkeypatch.chdir(tmp_path)

    aimi_dir = tmp_path / ".aimi"
    aimi_dir.mkdir()
    tasks_dir = aimi_dir / "tasks"
    tasks_dir.mkdir()

    tasks_file = tasks_dir / "2024-01-01-my-feature-tasks.json"
    tasks_file.touch()

    lock_file = aimi_dir / ".execute.lock"
    lock_file.write_text("99999")

    mod = _load_runtime_state_module()
    mod._is_alive = lambda pid: False

    output, exit_code = _run_guard_runtime_state(
        monkeypatch, _make_write_input(str(tasks_file)), module=mod
    )

    assert exit_code == 0
    assert output.strip() == "" or "deny" not in output


def test_runtime_guard_allows_unrelated_path(tmp_path, monkeypatch):
    """A path unrelated to any protected zone should be allowed."""
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.delenv("AIMI_RUNTIME_STATE_GUARD", raising=False)
    monkeypatch.chdir(tmp_path)

    aimi_dir = tmp_path / ".aimi"
    aimi_dir.mkdir()

    target = tmp_path / "src" / "main.py"
    target.parent.mkdir(parents=True)
    target.touch()

    output, exit_code = _run_guard_runtime_state(monkeypatch, _make_write_input(str(target)))

    assert exit_code == 0
    assert output.strip() == "" or "deny" not in output


def test_runtime_guard_blocks_roadmap_json(tmp_path, monkeypatch):
    """A roadmap.json path under .aimi/tasks/<feature>/ should be denied."""
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.delenv("AIMI_RUNTIME_STATE_GUARD", raising=False)
    monkeypatch.chdir(tmp_path)

    aimi_dir = tmp_path / ".aimi"
    aimi_dir.mkdir()
    feature_dir = aimi_dir / "tasks" / "my-feature"
    feature_dir.mkdir(parents=True)

    target = feature_dir / "roadmap.json"
    target.touch()

    output, exit_code = _run_guard_runtime_state(monkeypatch, _make_write_input(str(target)))

    assert exit_code == 0
    result = _parse_deny_output(output)
    assert result["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert "Roadmap state is owned by aimi-cli roadmap verbs" in result["hookSpecificOutput"]["userMessage"]


def test_runtime_guard_blocks_phase_handoff(tmp_path, monkeypatch):
    """A handoff.md path under .aimi/tasks/<feature>/phase-N/ should be denied."""
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.delenv("AIMI_RUNTIME_STATE_GUARD", raising=False)
    monkeypatch.chdir(tmp_path)

    aimi_dir = tmp_path / ".aimi"
    aimi_dir.mkdir()
    phase_dir = aimi_dir / "tasks" / "my-feature" / "phase-1"
    phase_dir.mkdir(parents=True)

    target = phase_dir / "handoff.md"
    target.touch()

    output, exit_code = _run_guard_runtime_state(monkeypatch, _make_write_input(str(target)))

    assert exit_code == 0
    result = _parse_deny_output(output)
    assert result["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert "Phase handoff is generated by aimi-cli" in result["hookSpecificOutput"]["userMessage"]


def test_runtime_guard_bypass_env_allows_roadmap_and_handoff(tmp_path, monkeypatch):
    """AIMI_RUNTIME_STATE_GUARD=off should allow both roadmap.json and handoff.md writes."""
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setenv("AIMI_RUNTIME_STATE_GUARD", "off")
    monkeypatch.chdir(tmp_path)

    aimi_dir = tmp_path / ".aimi"
    aimi_dir.mkdir()
    feature_dir = aimi_dir / "tasks" / "my-feature"
    phase_dir = feature_dir / "phase-1"
    phase_dir.mkdir(parents=True)

    roadmap_target = feature_dir / "roadmap.json"
    roadmap_target.touch()
    handoff_target = phase_dir / "handoff.md"
    handoff_target.touch()

    output, exit_code = _run_guard_runtime_state(
        monkeypatch, _make_write_input(str(roadmap_target))
    )
    assert exit_code == 0
    assert output.strip() == "" or "deny" not in output

    output, exit_code = _run_guard_runtime_state(
        monkeypatch, _make_write_input(str(handoff_target))
    )
    assert exit_code == 0
    assert output.strip() == "" or "deny" not in output


def test_runtime_guard_allows_roadmap_and_handoff_outside_tasks_dir(tmp_path, monkeypatch):
    """roadmap.json/handoff.md files outside the discovered .aimi/tasks/ tree are not blocked."""
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.delenv("AIMI_RUNTIME_STATE_GUARD", raising=False)
    monkeypatch.chdir(tmp_path)

    aimi_dir = tmp_path / ".aimi"
    aimi_dir.mkdir()

    outside_dir = tmp_path / "unrelated" / "phase-1"
    outside_dir.mkdir(parents=True)

    roadmap_target = tmp_path / "unrelated" / "roadmap.json"
    roadmap_target.touch()
    handoff_target = outside_dir / "handoff.md"
    handoff_target.touch()

    output, exit_code = _run_guard_runtime_state(
        monkeypatch, _make_write_input(str(roadmap_target))
    )
    assert exit_code == 0
    assert output.strip() == "" or "deny" not in output

    output, exit_code = _run_guard_runtime_state(
        monkeypatch, _make_write_input(str(handoff_target))
    )
    assert exit_code == 0
    assert output.strip() == "" or "deny" not in output


def test_runtime_guard_bypass_env(tmp_path, monkeypatch):
    """When AIMI_RUNTIME_STATE_GUARD=off, all paths should be allowed."""
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("AIMI_RUNTIME_STATE_GUARD", "off")
    monkeypatch.chdir(tmp_path)

    aimi_dir = tmp_path / ".aimi"
    aimi_dir.mkdir()
    state_dir = aimi_dir / "state"
    state_dir.mkdir()
    target = state_dir / "blocked.json"
    target.touch()

    output, exit_code = _run_guard_runtime_state(monkeypatch, _make_write_input(str(target)))

    assert exit_code == 0
    assert output.strip() == "" or "deny" not in output


def _golden_corpus_path(root: Path) -> Path:
    """Create the golden corpus at a plausible checkout path under *root*.

    The path is built from *root* on purpose: the guard matches the last three
    path components, so any tree (a checkout, a worktree, a tmp_path) must be
    blocked identically.  A test pinned to this repository's own absolute path
    would pass against a guard that only works in one tree.
    """
    tests_dir = root / "plugins" / "aimi-engineering" / "scripts" / "tests"
    tests_dir.mkdir(parents=True, exist_ok=True)
    target = tests_dir / "golden_from_jq.json"
    target.touch()
    return target


def test_runtime_guard_blocks_golden_corpus(tmp_path, monkeypatch):
    """A Write to scripts/tests/golden_from_jq.json is denied, in any tree.

    No .aimi/ is created here: the block sits with the two $HOME checks and must
    fire before the .aimi/ walk-up, so a tree with no .aimi/ at all still blocks.
    """
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.delenv("AIMI_RUNTIME_STATE_GUARD", raising=False)
    monkeypatch.chdir(tmp_path)

    target = _golden_corpus_path(tmp_path)

    output, exit_code = _run_guard_runtime_state(monkeypatch, _make_write_input(str(target)))

    # Non-zero: the deny is carried by the exit status as well as the JSON, so a
    # host reading either protocol sees the block.
    assert exit_code == 2
    result = _parse_deny_output(output)
    assert result["hookSpecificOutput"]["permissionDecision"] == "deny"

    message = result["hookSpecificOutput"]["userMessage"]
    # The message must name the legitimate route, not merely refuse: a guard
    # that only says no is a guard that gets worked around.
    assert "rewrite the generator or re-run the capture" in message
    assert "never by editing this file by hand" in message


def test_runtime_guard_allows_golden_corpus_neighbour(tmp_path, monkeypatch):
    """A sibling file in the same scripts/tests/ directory stays allowed.

    This is the assertion that discriminates: without it the guard could deny
    the whole directory -- or every path under it -- and still pass the test
    above.
    """
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.delenv("AIMI_RUNTIME_STATE_GUARD", raising=False)
    monkeypatch.chdir(tmp_path)

    golden = _golden_corpus_path(tmp_path)
    neighbour = golden.parent / "test_tasks.py"
    neighbour.touch()

    output, exit_code = _run_guard_runtime_state(monkeypatch, _make_write_input(str(neighbour)))

    assert exit_code == 0
    assert output.strip() == "" or "deny" not in output


def test_runtime_guard_golden_match_is_by_path_component(tmp_path, monkeypatch):
    """The suffix match compares components, so 'myscripts/tests/' does not match.

    A str.endswith("scripts/tests/golden_from_jq.json") would block this path;
    comparing Path.parts does not.
    """
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.delenv("AIMI_RUNTIME_STATE_GUARD", raising=False)
    monkeypatch.chdir(tmp_path)

    lookalike_dir = tmp_path / "myscripts" / "tests"
    lookalike_dir.mkdir(parents=True)
    target = lookalike_dir / "golden_from_jq.json"
    target.touch()

    output, exit_code = _run_guard_runtime_state(monkeypatch, _make_write_input(str(target)))

    assert exit_code == 0
    assert output.strip() == "" or "deny" not in output


def test_runtime_guard_bypass_env_allows_golden_corpus(tmp_path, monkeypatch):
    """AIMI_RUNTIME_STATE_GUARD=off releases the corpus block like every other."""
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setenv("AIMI_RUNTIME_STATE_GUARD", "off")
    monkeypatch.chdir(tmp_path)

    target = _golden_corpus_path(tmp_path)

    output, exit_code = _run_guard_runtime_state(monkeypatch, _make_write_input(str(target)))

    assert exit_code == 0
    assert output.strip() == "" or "deny" not in output


# ---------------------------------------------------------------------------
# guard-tasks-presence.py tests
# ---------------------------------------------------------------------------


def test_tasks_presence_denies_when_no_aimi_dir(tmp_path, monkeypatch):
    """Should deny when no .aimi/ directory found in cwd walk-up."""
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.chdir(tmp_path)
    # No .aimi directory created.

    output, exit_code = _run_guard_tasks_presence(monkeypatch, _make_skill_input("aimi:execute"))

    assert exit_code == 0
    result = _parse_deny_output(output)
    assert result["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert "No .aimi/ directory" in result["hookSpecificOutput"]["userMessage"]


def test_tasks_presence_denies_when_no_tasks_file(tmp_path, monkeypatch):
    """Should deny when .aimi/ exists but no *-tasks.json files."""
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.chdir(tmp_path)

    aimi_dir = tmp_path / ".aimi"
    aimi_dir.mkdir()
    tasks_dir = aimi_dir / "tasks"
    tasks_dir.mkdir()
    # No tasks.json files.

    output, exit_code = _run_guard_tasks_presence(monkeypatch, _make_skill_input("aimi:execute"))

    assert exit_code == 0
    result = _parse_deny_output(output)
    assert result["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert "No tasks.json detected" in result["hookSpecificOutput"]["userMessage"]


def test_tasks_presence_denies_on_wrong_schema(tmp_path, monkeypatch):
    """Should deny when tasks.json has wrong schemaVersion."""
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.chdir(tmp_path)

    aimi_dir = tmp_path / ".aimi"
    aimi_dir.mkdir()
    tasks_dir = aimi_dir / "tasks"
    tasks_dir.mkdir()

    tasks_data = {"schemaVersion": "1.0", "userStories": []}
    (tasks_dir / "2024-01-01-my-feature-tasks.json").write_text(json.dumps(tasks_data))

    output, exit_code = _run_guard_tasks_presence(monkeypatch, _make_skill_input("aimi:execute"))

    assert exit_code == 0
    result = _parse_deny_output(output)
    assert result["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert "1.0" in result["hookSpecificOutput"]["userMessage"]


def test_tasks_presence_denies_on_unparseable(tmp_path, monkeypatch):
    """Should deny when the tasks.json file cannot be parsed."""
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.chdir(tmp_path)

    aimi_dir = tmp_path / ".aimi"
    aimi_dir.mkdir()
    tasks_dir = aimi_dir / "tasks"
    tasks_dir.mkdir()

    (tasks_dir / "2024-01-01-my-feature-tasks.json").write_text("not valid json {{{{")

    output, exit_code = _run_guard_tasks_presence(monkeypatch, _make_skill_input("aimi:execute"))

    assert exit_code == 0
    result = _parse_deny_output(output)
    assert result["hookSpecificOutput"]["permissionDecision"] == "deny"
    assert "Failed to parse" in result["hookSpecificOutput"]["userMessage"]


def test_tasks_presence_allows_on_valid_file(tmp_path, monkeypatch):
    """Should allow when a valid tasks.json with correct schemaVersion exists."""
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.chdir(tmp_path)

    aimi_dir = tmp_path / ".aimi"
    aimi_dir.mkdir()
    tasks_dir = aimi_dir / "tasks"
    tasks_dir.mkdir()

    tasks_data = {"schemaVersion": "3.3", "userStories": []}
    (tasks_dir / "2024-01-01-my-feature-tasks.json").write_text(json.dumps(tasks_data))

    output, exit_code = _run_guard_tasks_presence(monkeypatch, _make_skill_input("aimi:execute"))

    assert exit_code == 0
    assert output.strip() == "" or "deny" not in output


def test_tasks_presence_skips_non_execute_skill(tmp_path, monkeypatch):
    """Should allow (exit 0) for skills other than aimi:execute."""
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.chdir(tmp_path)
    # No .aimi/ — but that doesn't matter since we skip non-execute skills.

    output, exit_code = _run_guard_tasks_presence(monkeypatch, _make_skill_input("aimi:plan"))

    assert exit_code == 0
    assert output.strip() == "" or "deny" not in output
