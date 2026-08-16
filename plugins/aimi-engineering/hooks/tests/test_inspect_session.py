from __future__ import annotations

import importlib.util
import io
import json
import subprocess
import sys
import time as _time
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

_HOOKS_DIR = Path(__file__).parent.parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

import friction_store  # noqa: E402


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _load_hook():
    """Load inspect-session.py as a module."""
    mod_name = "inspect_session"
    spec = importlib.util.spec_from_file_location(
        mod_name, _HOOKS_DIR / "inspect-session.py"
    )
    mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def _isolate_env(monkeypatch, tmp_path: Path) -> Path:
    """Point HOME and every config-dir lookup at throwaway trees under tmp_path.

    This is the module's ONE way of building a session environment — every test
    here goes through it, directly or via `_run_hook`. It exists as a named
    helper rather than four inline setenv calls because `_heal_cli_path_cache`
    reads Layer 1 (`$AIMI_CONFIG_DIR/cli-path`) and can spawn a CLI that WRITES
    it: a test that inherited the developer's real value would corrupt the very
    file the plugin resolves itself through, on the machine running the suite.
    `$CLAUDE_PLUGIN_ROOT` is removed for the same reason — a session that has it
    set must not leak into a test that is asserting the step stays inert.

    Returns the throwaway Layer 1 directory, which is deliberately NOT created:
    "the config dir does not exist yet" is the fresh-machine state the healing
    path exists for, and a test that wants it populated says so itself.
    """
    config_home = tmp_path / "xdg-config"
    aimi_config_dir = config_home / "aimi"

    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(config_home))
    monkeypatch.setenv("AIMI_CONFIG_DIR", str(aimi_config_dir))
    monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path / "claude-config"))
    monkeypatch.setenv("CLAUDECODE", "1")
    monkeypatch.delenv("CLAUDE_PLUGIN_ROOT", raising=False)
    monkeypatch.delenv("CLAUDE_SESSION_ID", raising=False)

    return aimi_config_dir


def _drive_hook(mod, monkeypatch, tmp_path: Path, payload: dict | None = None) -> str:
    """Run an ALREADY-LOADED (and possibly patched) hook module; return stdout.

    Split out of `_run_hook` so a test can monkeypatch the module's own
    namespace — `subprocess`, `is_quiet_mode` — between load and invocation.
    """
    if payload is None:
        payload = {}
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))
    monkeypatch.setattr(friction_store, "_STORE_DIR", tmp_path / ".aimi" / "learnings")

    captured = io.StringIO()
    monkeypatch.setattr("sys.stdout", captured)

    with pytest.raises(SystemExit) as exc_info:
        mod.main()
    assert exc_info.value.code == 0

    return captured.getvalue()


def _run_hook(
    monkeypatch,
    tmp_path: Path,
    payload: dict | None = None,
    plugin_root: Path | None = None,
) -> str:
    """Run the hook with mocked stdin and return captured stdout.

    `plugin_root` is applied AFTER `_isolate_env` — which unsets the variable —
    so a caller cannot set it beforehand and have it survive.
    """
    _isolate_env(monkeypatch, tmp_path)
    if plugin_root is not None:
        monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(plugin_root))
    mod = _load_hook()
    return _drive_hook(mod, monkeypatch, tmp_path, payload)


def _write_friction_events(
    tmp_path: Path,
    count: int,
    scope: str = "plugin",
    scopes: list[str] | None = None,
) -> None:
    """Write friction events to the store."""
    store_dir = tmp_path / ".aimi" / "learnings"
    store_dir.mkdir(parents=True, exist_ok=True)
    date_str = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d")
    events_file = store_dir / f"{date_str}.jsonl"
    with events_file.open("a", encoding="utf-8") as fh:
        for i in range(count):
            s = scopes[i] if scopes else scope
            event = {
                "ts": datetime.now(tz=timezone.utc).isoformat(),
                "session_id": "default",
                "frame": "aimi:plan",
                "scope": s,
                "previous_prompt": f"prev {i}",
                "current_prompt": f"curr {i}",
            }
            fh.write(json.dumps(event) + "\n")


def _write_telemetry(
    tmp_path: Path,
    category: str,
    entries: list[dict],
) -> None:
    """Write telemetry entries to ~/.aimi/telemetry/<category>.jsonl."""
    tdir = tmp_path / ".aimi" / "telemetry"
    tdir.mkdir(parents=True, exist_ok=True)
    target = tdir / f"{category}.jsonl"
    with target.open("a", encoding="utf-8") as fh:
        for entry in entries:
            fh.write(json.dumps(entry) + "\n")


# --- CLI-path healing fixtures ---------------------------------------------
#
# `prime-cache` is stubbed as a real shell script rather than mocked, because
# the thing under test is a subprocess boundary: argv, the exit status and the
# timeout are all part of the contract, and a mock reproduces none of them. The
# no-spawn assertions use the spy below instead — see `_spy_subprocess`.

# Records its own argv beside itself, then writes Layer 1 the way the real verb
# does: `$0` is the absolute path the hook passed, so the cache ends up naming
# this tree's own scripts/aimi-cli.sh.
_STUB_PRIME_CACHE = (
    'printf \'%s\\n\' "$*" > "$(dirname "$0")/argv.txt"\n'
    'mkdir -p "$AIMI_CONFIG_DIR"\n'
    'printf \'%s\\n\' "$0" > "$AIMI_CONFIG_DIR/cli-path"\n'
)
_STUB_FAILS = "exit 3\n"
_STUB_HANGS = "sleep 10\n"


def _make_plugin_root(
    tmp_path: Path,
    body: str = _STUB_PRIME_CACHE,
    *,
    name: str = "plugin",
    executable: bool = True,
    with_cli: bool = True,
) -> Path:
    """Build a throwaway $CLAUDE_PLUGIN_ROOT tree and return its path."""
    root = tmp_path / name
    scripts = root / "scripts"
    scripts.mkdir(parents=True, exist_ok=True)
    if with_cli:
        cli = scripts / "aimi-cli.sh"
        cli.write_text("#!/bin/sh\n" + body, encoding="utf-8")
        cli.chmod(0o755 if executable else 0o644)
    return root


def _stub_cli(plugin_root: Path) -> Path:
    return plugin_root / "scripts" / "aimi-cli.sh"


def _spy_subprocess(mod, monkeypatch) -> MagicMock:
    """Replace the hook module's `subprocess` with a spy exposing `run`.

    Confined to this module object (each `_load_hook()` returns a fresh one), so
    nothing else in the process observes the swap. `raising=True` is deliberate:
    if the hook stops importing subprocess, these tests should say so.
    """
    spy = MagicMock(name="subprocess.run")
    monkeypatch.setattr(
        mod, "subprocess", SimpleNamespace(run=spy, DEVNULL=subprocess.DEVNULL)
    )
    return spy


def _assert_session_completed(output: str) -> None:
    """The banner is the evidence main() ran PAST the healing step.

    @safe_hook exits 0 on an exception too, so a bare `SystemExit(0)` proves
    nothing about the healing step not having broken the session — an empty
    stdout is exactly what a propagated exception would leave behind. A banner
    carrying the friction the test wrote can only have been built after
    `_heal_cli_path_cache` returned.
    """
    data = json.loads(output.strip())
    assert "pending friction" in data["hookSpecificOutput"]["additionalContext"]


def _now_iso() -> str:
    return datetime.now(tz=timezone.utc).isoformat()


def _old_iso(hours: int = 25) -> str:
    """Return an ISO timestamp older than `hours` hours ago."""
    return (datetime.now(tz=timezone.utc) - timedelta(hours=hours)).isoformat()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_silent_exit_when_not_claude_code(monkeypatch, tmp_path):
    """When CLAUDECODE env var is absent, hook exits 0 silently (OpenCode host)."""
    # Write friction events so there would be output if the gate were absent.
    _write_friction_events(tmp_path, 3)

    # Run without setting CLAUDECODE (simulates OpenCode host).
    _isolate_env(monkeypatch, tmp_path)
    monkeypatch.delenv("CLAUDECODE", raising=False)

    mod = _load_hook()
    assert _drive_hook(mod, monkeypatch, tmp_path).strip() == ""


def test_silent_when_all_zero(monkeypatch, tmp_path):
    """No friction, no telemetry → no stdout output."""
    output = _run_hook(monkeypatch, tmp_path)
    assert output.strip() == ""


def test_banner_with_friction_only(monkeypatch, tmp_path):
    """3 friction events → banner shows pending friction line."""
    _write_friction_events(tmp_path, 3, scope="project")

    output = _run_hook(monkeypatch, tmp_path)
    assert output.strip() != ""

    data = json.loads(output.strip())
    banner = data["hookSpecificOutput"]["additionalContext"]
    assert "[aimi session]" in banner
    assert "pending friction: 3" in banner
    assert "Run /aimi:learnings to triage." in banner


def test_banner_scope_breakdown_counts_correct(monkeypatch, tmp_path):
    """2 project, 1 plugin, 1 inbox → 'project: 2 / plugin: 1 / inbox: 1'."""
    _write_friction_events(
        tmp_path,
        4,
        scopes=["project", "project", "plugin", "inbox"],
    )

    output = _run_hook(monkeypatch, tmp_path)
    data = json.loads(output.strip())
    banner = data["hookSpecificOutput"]["additionalContext"]

    assert "project: 2" in banner
    assert "plugin: 1" in banner
    assert "inbox: 1" in banner


def test_banner_includes_top_5_skills(monkeypatch, tmp_path):
    """7 distinct skills → banner shows only top 5."""
    # Write 7 distinct skills with decreasing counts
    skills_entries = []
    for i in range(7):
        skill_name = f"skill-{i:02d}"
        count = 10 - i  # skill-00 has 10 hits, skill-06 has 4 hits
        for _ in range(count):
            skills_entries.append({"ts": _now_iso(), "skill": skill_name})

    _write_telemetry(tmp_path, "skills", skills_entries)
    # Need at least 1 friction event so we don't hit the empty-state exit
    _write_friction_events(tmp_path, 1)

    output = _run_hook(monkeypatch, tmp_path)
    data = json.loads(output.strip())
    banner = data["hookSpecificOutput"]["additionalContext"]

    # Count how many skill× entries appear
    skill_markers = [part for part in banner.split(",") if "×" in part]
    # skills last 24h line may have 5 comma-separated entries
    skills_line = [line for line in banner.splitlines() if "skills last 24h" in line]
    assert len(skills_line) == 1
    top_skills_str = skills_line[0].split("skills last 24h:")[1].strip()
    top_skills = [s.strip() for s in top_skills_str.split(",")]
    assert len(top_skills) == 5


def test_banner_skills_ordered_by_count_desc(monkeypatch, tmp_path):
    """Skills are sorted by count descending."""
    skills_entries = []
    # skill-A: 3, skill-B: 7, skill-C: 1
    for name, count in [("skill-A", 3), ("skill-B", 7), ("skill-C", 1)]:
        for _ in range(count):
            skills_entries.append({"ts": _now_iso(), "skill": name})

    _write_telemetry(tmp_path, "skills", skills_entries)
    _write_friction_events(tmp_path, 1)

    output = _run_hook(monkeypatch, tmp_path)
    data = json.loads(output.strip())
    banner = data["hookSpecificOutput"]["additionalContext"]

    skills_line = [line for line in banner.splitlines() if "skills last 24h" in line][0]
    # skill-B×7 should appear before skill-A×3 which should appear before skill-C×1
    pos_b = skills_line.find("skill-B")
    pos_a = skills_line.find("skill-A")
    pos_c = skills_line.find("skill-C")
    assert pos_b < pos_a < pos_c


def test_banner_reads_count_correct(monkeypatch, tmp_path):
    """12 read events in last 24h → banner shows 'reads last 24h: 12'."""
    read_entries = [{"ts": _now_iso(), "path": f"/file{i}.py"} for i in range(12)]
    _write_telemetry(tmp_path, "reads", read_entries)
    _write_friction_events(tmp_path, 1)

    output = _run_hook(monkeypatch, tmp_path)
    data = json.loads(output.strip())
    banner = data["hookSpecificOutput"]["additionalContext"]

    assert "reads last 24h: 12" in banner


def test_banner_skips_telemetry_outside_24h(monkeypatch, tmp_path):
    """Old telemetry entries (>24h) are excluded from counts."""
    # Write 5 old entries and 2 recent entries
    old_ts = _old_iso(hours=30)
    recent_ts = _now_iso()

    read_entries = [{"ts": old_ts, "path": "/old.py"} for _ in range(5)]
    read_entries += [{"ts": recent_ts, "path": "/new.py"} for _ in range(2)]
    _write_telemetry(tmp_path, "reads", read_entries)
    _write_friction_events(tmp_path, 1)

    output = _run_hook(monkeypatch, tmp_path)
    data = json.loads(output.strip())
    banner = data["hookSpecificOutput"]["additionalContext"]

    assert "reads last 24h: 2" in banner


def test_banner_respects_quiet_mode(monkeypatch, tmp_path):
    """is_quiet_mode() True → no output."""
    _write_friction_events(tmp_path, 3)

    _isolate_env(monkeypatch, tmp_path)

    import hook_utils
    monkeypatch.setattr(hook_utils, "is_quiet_mode", lambda: True)

    # Reload module so it picks up the monkeypatched is_quiet_mode
    mod = _load_hook()
    monkeypatch.setattr(mod, "is_quiet_mode", lambda: True)

    assert _drive_hook(mod, monkeypatch, tmp_path).strip() == ""


def test_banner_respects_banner_disabled(monkeypatch, tmp_path, capsys):
    """.aimi/config.json banner.enabled false → no output."""
    _write_friction_events(tmp_path, 3)

    # Write config with banner.enabled = false
    aimi_dir = tmp_path / ".aimi"
    aimi_dir.mkdir(parents=True, exist_ok=True)
    (aimi_dir / "config.json").write_text(
        json.dumps({"banner": {"enabled": False}}), encoding="utf-8"
    )

    # Change cwd so the config is found by walk-up
    monkeypatch.chdir(str(tmp_path))

    output = _run_hook(monkeypatch, tmp_path)
    assert output.strip() == ""


def test_banner_time_budget_skips_telemetry_section(monkeypatch, tmp_path):
    """When time budget is exceeded before reading reads.jsonl, telemetry section is skipped."""
    # Write friction and telemetry data
    _write_friction_events(tmp_path, 2, scope="project")
    read_entries = [{"ts": _now_iso(), "path": f"/file{i}.py"} for i in range(5)]
    _write_telemetry(tmp_path, "reads", read_entries)
    skill_entries = [{"ts": _now_iso(), "skill": "my-skill"} for _ in range(3)]
    _write_telemetry(tmp_path, "skills", skill_entries)

    # Monkeypatch time.monotonic to simulate budget exceeded
    # We want: first call returns 0.0, subsequent calls return a value > 0.5
    import time as _time_module

    call_count = [0]
    original_monotonic = _time_module.monotonic

    def fake_monotonic():
        call_count[0] += 1
        if call_count[0] == 1:
            return 0.0  # t_start
        # All subsequent calls return past budget
        return 0.6  # exceeds 0.5s budget

    _isolate_env(monkeypatch, tmp_path)

    mod = _load_hook()
    monkeypatch.setattr(mod, "time", type("FakeTime", (), {"monotonic": staticmethod(fake_monotonic)})())

    output = _drive_hook(mod, monkeypatch, tmp_path).strip()
    assert output != "", "Expected banner output with friction"

    data = json.loads(output)
    banner = data["hookSpecificOutput"]["additionalContext"]

    # Banner should show friction but NOT skills or reads telemetry
    assert "pending friction" in banner
    assert "skills last 24h" not in banner
    assert "reads last 24h" not in banner


# ---------------------------------------------------------------------------
# CLI-path healing (_heal_cli_path_cache)
#
# Every branch of the step is asserted independently, and the two that decide
# whether a subprocess starts are asserted BY OBSERVATION — a patched
# subprocess.run's call_count — never by the state of the cache file. That is
# not a style preference: `prime-cache` answers `already_current` and writes
# nothing when Layer 1 already resolves, so an unconditional spawn leaves the
# file exactly as an inert step does. An outcome-only assertion would pass
# against the precise regression these tests exist to catch — a 299 ms spawn
# charged to every session, against this module's 500 ms budget.
# ---------------------------------------------------------------------------

def test_heal_writes_layer_1_when_the_cache_is_absent(monkeypatch, tmp_path):
    """Empty config dir + a real plugin tree → cli-path names that tree's CLI."""
    aimi_config_dir = _isolate_env(monkeypatch, tmp_path)
    plugin_root = _make_plugin_root(tmp_path)
    _write_friction_events(tmp_path, 2)

    assert not (aimi_config_dir / "cli-path").exists()

    output = _run_hook(monkeypatch, tmp_path, plugin_root=plugin_root)

    cache = aimi_config_dir / "cli-path"
    assert cache.exists(), "healing did not write Layer 1"
    assert cache.read_text(encoding="utf-8").strip() == str(_stub_cli(plugin_root))
    # The verb matters as much as the spawn: prime-cache owns confinement,
    # atomicity and the 0600 mode the hook deliberately does not reproduce.
    argv = (plugin_root / "scripts" / "argv.txt").read_text(encoding="utf-8").strip()
    assert argv == "prime-cache"
    _assert_session_completed(output)


def test_heal_spawns_exactly_once_when_the_cache_is_absent(monkeypatch, tmp_path):
    """The spy the no-spawn test relies on is shown to fire when it should.

    A `call_count == 0` assertion is only evidence if the same instrument
    reaches 1 under the opposite condition; this is that half.
    """
    _isolate_env(monkeypatch, tmp_path)
    plugin_root = _make_plugin_root(tmp_path)
    monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(plugin_root))

    mod = _load_hook()
    spy = _spy_subprocess(mod, monkeypatch)
    _drive_hook(mod, monkeypatch, tmp_path)

    assert spy.call_count == 1
    assert spy.call_args.args[0] == [str(_stub_cli(plugin_root)), "prime-cache"]


def test_heal_does_not_spawn_when_layer_1_already_resolves(monkeypatch, tmp_path):
    """cli-path already names an executable → NO subprocess is started at all."""
    aimi_config_dir = _isolate_env(monkeypatch, tmp_path)
    plugin_root = _make_plugin_root(tmp_path)
    monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(plugin_root))

    aimi_config_dir.mkdir(parents=True, exist_ok=True)
    cache = aimi_config_dir / "cli-path"
    cache.write_text(str(_stub_cli(plugin_root)) + "\n", encoding="utf-8")

    mod = _load_hook()
    spy = _spy_subprocess(mod, monkeypatch)
    _drive_hook(mod, monkeypatch, tmp_path)

    assert spy.call_count == 0, "healing spawned prime-cache on an already-healthy host"
    # Secondary, and deliberately secondary: this assertion holds for an
    # unconditional spawn too, which is why it cannot stand in for the one above.
    assert cache.read_text(encoding="utf-8").strip() == str(_stub_cli(plugin_root))


def test_heal_spawns_when_the_cached_path_is_executable_but_the_cli_would_reject_it(
    monkeypatch, tmp_path
):
    """An executable cli-path that is NOT this install's own path is still healed.

    The gate compares by identity rather than merely asking "is it executable",
    and this is the case that separates the two. Under CLAUDECODE the CLI's own
    reader accepts exactly two cached paths — the versioned cache glob, or
    today's directory-source path by exact equality — and for the running
    install both of those ARE $CLAUDE_PLUGIN_ROOT/scripts/aimi-cli.sh.

    A `*/.worktrees/*` path is the concrete instance: write_global_cli_cache
    refuses to write one and the reader refuses to read one, yet it is a real
    executable file, so an executable-only gate returned early and left the
    session unable to resolve the CLI at all — the one state this hook exists
    to repair. Any other stray executable (an install since removed, a
    hand-edited entry) fails the same way and is covered by the same identity
    comparison.
    """
    aimi_config_dir = _isolate_env(monkeypatch, tmp_path)
    plugin_root = _make_plugin_root(tmp_path)
    monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(plugin_root))

    # A genuinely executable file the CLI's reader would nonetheless refuse.
    stray = tmp_path / "elsewhere" / ".worktrees" / "wt" / "scripts" / "aimi-cli.sh"
    stray.parent.mkdir(parents=True, exist_ok=True)
    stray.write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    stray.chmod(0o755)
    assert stray.stat().st_mode & 0o111, "fixture did not produce an executable"

    aimi_config_dir.mkdir(parents=True, exist_ok=True)
    cache = aimi_config_dir / "cli-path"
    cache.write_text(str(stray) + "\n", encoding="utf-8")

    mod = _load_hook()
    spy = _spy_subprocess(mod, monkeypatch)
    _drive_hook(mod, monkeypatch, tmp_path)

    assert spy.call_count == 1, (
        "an executable-but-rejected cli-path was treated as resolved, so the "
        "hook left the session unable to locate the CLI"
    )
    assert spy.call_args.args[0][0] == str(_stub_cli(plugin_root))
    assert spy.call_args.args[0][1] == "prime-cache"


def test_heal_spawns_when_the_cached_path_no_longer_resolves(monkeypatch, tmp_path):
    """A stale cli-path naming a deleted file is not treated as resolved."""
    aimi_config_dir = _isolate_env(monkeypatch, tmp_path)
    plugin_root = _make_plugin_root(tmp_path)
    monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(plugin_root))

    aimi_config_dir.mkdir(parents=True, exist_ok=True)
    (aimi_config_dir / "cli-path").write_text(
        str(tmp_path / "uninstalled" / "scripts" / "aimi-cli.sh") + "\n",
        encoding="utf-8",
    )

    mod = _load_hook()
    spy = _spy_subprocess(mod, monkeypatch)
    _drive_hook(mod, monkeypatch, tmp_path)

    assert spy.call_count == 1


def test_heal_is_inert_without_claude_plugin_root(monkeypatch, tmp_path):
    """No $CLAUDE_PLUGIN_ROOT → nothing is spawned and nothing is written."""
    aimi_config_dir = _isolate_env(monkeypatch, tmp_path)  # already deletes the var

    mod = _load_hook()
    spy = _spy_subprocess(mod, monkeypatch)
    _drive_hook(mod, monkeypatch, tmp_path)

    assert spy.call_count == 0
    assert not (aimi_config_dir / "cli-path").exists()


def test_heal_is_inert_when_plugin_root_has_no_cli(monkeypatch, tmp_path):
    """$CLAUDE_PLUGIN_ROOT names a tree with no scripts/aimi-cli.sh at all."""
    aimi_config_dir = _isolate_env(monkeypatch, tmp_path)
    plugin_root = _make_plugin_root(tmp_path, with_cli=False)
    monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(plugin_root))

    mod = _load_hook()
    spy = _spy_subprocess(mod, monkeypatch)
    _drive_hook(mod, monkeypatch, tmp_path)

    assert spy.call_count == 0
    assert not (aimi_config_dir / "cli-path").exists()


def test_heal_is_inert_when_the_cli_is_not_executable(monkeypatch, tmp_path):
    """scripts/aimi-cli.sh exists but carries no execute bit → no spawn."""
    aimi_config_dir = _isolate_env(monkeypatch, tmp_path)
    plugin_root = _make_plugin_root(tmp_path, executable=False)
    monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(plugin_root))

    mod = _load_hook()
    spy = _spy_subprocess(mod, monkeypatch)
    _drive_hook(mod, monkeypatch, tmp_path)

    assert spy.call_count == 0
    assert not (aimi_config_dir / "cli-path").exists()


def test_a_failing_cli_does_not_break_the_session(monkeypatch, tmp_path):
    """A prime-cache that exits non-zero leaves the session exactly as it was."""
    aimi_config_dir = _isolate_env(monkeypatch, tmp_path)
    plugin_root = _make_plugin_root(tmp_path, _STUB_FAILS)
    _write_friction_events(tmp_path, 2)

    output = _run_hook(monkeypatch, tmp_path, plugin_root=plugin_root)

    _assert_session_completed(output)
    assert not (aimi_config_dir / "cli-path").exists()


def test_a_hanging_cli_does_not_break_the_session(monkeypatch, tmp_path):
    """A wedged prime-cache is killed by the timeout; the session continues.

    The elapsed bound is the assertion that carries the weight — without a
    timeout this test would still see a completed session, ten seconds later.
    """
    _isolate_env(monkeypatch, tmp_path)
    plugin_root = _make_plugin_root(tmp_path, _STUB_HANGS)
    _write_friction_events(tmp_path, 2)

    started = _time.monotonic()
    output = _run_hook(monkeypatch, tmp_path, plugin_root=plugin_root)
    elapsed = _time.monotonic() - started

    _assert_session_completed(output)
    assert elapsed < 3.0, f"the healing spawn was not bounded by a timeout ({elapsed:.2f}s)"


def test_quiet_mode_still_heals(monkeypatch, tmp_path):
    """is_quiet_mode() True suppresses the BANNER, never the healing.

    The ordering requirement from story 01 — the healing call sits above the
    quiet-mode exit — stated as an executable assertion rather than a comment.
    Without it every quiet-mode session would stay unhealed forever.
    """
    aimi_config_dir = _isolate_env(monkeypatch, tmp_path)
    plugin_root = _make_plugin_root(tmp_path)
    monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(plugin_root))
    _write_friction_events(tmp_path, 3)

    mod = _load_hook()
    monkeypatch.setattr(mod, "is_quiet_mode", lambda: True)
    output = _drive_hook(mod, monkeypatch, tmp_path)

    assert output.strip() == "", "quiet mode must still suppress the banner"
    cache = aimi_config_dir / "cli-path"
    assert cache.exists(), "quiet mode suppressed the healing, not just the banner"
    assert cache.read_text(encoding="utf-8").strip() == str(_stub_cli(plugin_root))
