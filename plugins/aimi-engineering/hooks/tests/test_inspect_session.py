from __future__ import annotations

import importlib.util
import io
import json
import subprocess
import sys
import time as _time
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

_HOOKS_DIR = Path(__file__).parent.parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))


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
    namespace — `subprocess` — between load and invocation.
    """
    if payload is None:
        payload = {}
    monkeypatch.setattr("sys.stdin", io.StringIO(json.dumps(payload)))

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
# charged to every session.
# ---------------------------------------------------------------------------

def test_heal_writes_layer_1_when_the_cache_is_absent(monkeypatch, tmp_path):
    """Empty config dir + a real plugin tree → cli-path names that tree's CLI."""
    aimi_config_dir = _isolate_env(monkeypatch, tmp_path)
    plugin_root = _make_plugin_root(tmp_path)

    assert not (aimi_config_dir / "cli-path").exists()

    output = _run_hook(monkeypatch, tmp_path, plugin_root=plugin_root)

    cache = aimi_config_dir / "cli-path"
    assert cache.exists(), "healing did not write Layer 1"
    assert cache.read_text(encoding="utf-8").strip() == str(_stub_cli(plugin_root))
    # The verb matters as much as the spawn: prime-cache owns confinement,
    # atomicity and the 0600 mode the hook deliberately does not reproduce.
    argv = (plugin_root / "scripts" / "argv.txt").read_text(encoding="utf-8").strip()
    assert argv == "prime-cache"
    assert output.strip() == ""


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
    """A prime-cache that exits non-zero leaves the session exactly as it was.

    The healing step is called directly, outside @safe_hook: the decorator exits
    0 on an exception too, so only a direct call can show the step itself
    returns instead of raising.
    """
    aimi_config_dir = _isolate_env(monkeypatch, tmp_path)
    plugin_root = _make_plugin_root(tmp_path, _STUB_FAILS)
    monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(plugin_root))

    assert _load_hook()._heal_cli_path_cache() is None
    assert not (aimi_config_dir / "cli-path").exists()


def test_a_hanging_cli_does_not_break_the_session(monkeypatch, tmp_path):
    """A wedged prime-cache is killed by the timeout and the step returns.

    The elapsed bound is the assertion that carries the weight -- without a
    timeout this step would still return, ten seconds later.
    """
    _isolate_env(monkeypatch, tmp_path)
    plugin_root = _make_plugin_root(tmp_path, _STUB_HANGS)
    monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(plugin_root))

    started = _time.monotonic()
    assert _load_hook()._heal_cli_path_cache() is None
    elapsed = _time.monotonic() - started

    assert elapsed < 3.0, f"the healing spawn was not bounded by a timeout ({elapsed:.2f}s)"


def test_the_hook_prints_nothing(monkeypatch, tmp_path):
    """Healing is the hook's only job: no banner, no additionalContext."""
    plugin_root = _make_plugin_root(tmp_path)
    assert _run_hook(monkeypatch, tmp_path, plugin_root=plugin_root).strip() == ""


def test_silent_and_inert_when_not_claude_code(monkeypatch, tmp_path):
    """Without CLAUDECODE (an OpenCode host) the hook neither spawns nor prints."""
    _isolate_env(monkeypatch, tmp_path)
    monkeypatch.delenv("CLAUDECODE", raising=False)
    monkeypatch.setenv("CLAUDE_PLUGIN_ROOT", str(_make_plugin_root(tmp_path)))

    mod = _load_hook()
    spy = _spy_subprocess(mod, monkeypatch)
    assert _drive_hook(mod, monkeypatch, tmp_path).strip() == ""
    assert spy.call_count == 0
