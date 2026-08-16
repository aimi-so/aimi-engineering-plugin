#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

_HOOKS_DIR = Path(__file__).parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

from hook_utils import safe_hook, is_quiet_mode, load_aimi_config  # noqa: E402
import friction_store  # noqa: E402

_BUDGET_SECS = 0.5  # 500 ms hard budget

# Upper bound for the one-off `prime-cache` spawn below. A spawn measured 299 ms
# on a directory-source install, so the whole budget is a ceiling it should never
# reach; it exists so a wedged CLI cannot stall session start indefinitely.
_HEAL_TIMEOUT_SECS = _BUDGET_SECS


def _read_banner_enabled() -> bool:
    """Walk up from cwd looking for .aimi/config.json -> banner.enabled (default True)."""
    return bool(load_aimi_config().get("banner", {}).get("enabled", True))


def _aimi_config_dir() -> Path:
    """Layer 1's directory: $AIMI_CONFIG_DIR, else ${XDG_CONFIG_HOME:-~/.config}/aimi.

    Mirrors `_aimi_config_dir` in scripts/aimi-cli.sh, including its treatment of
    an empty variable as unset.
    """
    explicit = os.environ.get("AIMI_CONFIG_DIR")
    if explicit:
        return Path(explicit)
    xdg = os.environ.get("XDG_CONFIG_HOME")
    base = Path(xdg) if xdg else Path.home() / ".config"
    return base / "aimi"


def _heal_cli_path_cache() -> None:
    """Write Layer 1 of the CLI path cache when it does not already resolve.

    On a directory-source install nothing primes `~/.config/aimi/cli-path`, so the
    first `/aimi:*` command of a fresh machine cannot locate `aimi-cli.sh` at all.
    Session start is the earliest moment the plugin can fix that for itself, and
    `$CLAUDE_PLUGIN_ROOT` — which Claude Code puts in this process's environment —
    is the one path that names the running install without guessing.

    Gated on the cheap read on purpose: a `prime-cache` spawn measured 299 ms
    against this module's 500 ms budget, while the Layer 1 read plus os.access
    measured 0.025 ms. Running the spawn unconditionally would charge 60% of the
    budget to every session on a host that needs nothing.

    Confinement, atomicity and the 0600 mode of the write itself are NOT
    reproduced here — `prime-cache` owns all three, and invoking the verb instead
    of re-deriving its rules is the whole point of this shape.

    Never raises: every failure mode (no CLAUDE_PLUGIN_ROOT, a root with no
    executable scripts/aimi-cli.sh, an unreadable config dir, a non-zero exit, a
    timeout) leaves the session exactly as it found it. The module-level
    @safe_hook would swallow an exception too, but it would swallow the banner
    logic that follows along with it.
    """
    try:
        root = os.environ.get("CLAUDE_PLUGIN_ROOT")
        if not root:
            return

        cli = Path(root) / "scripts" / "aimi-cli.sh"
        if not (cli.is_file() and os.access(cli, os.X_OK)):
            return

        cached = ""
        try:
            cached = (_aimi_config_dir() / "cli-path").read_text(encoding="utf-8").strip()
        except OSError:
            cached = ""

        # By IDENTITY, not by shape, and not merely "is it executable".
        #
        # Under CLAUDECODE — the only condition this hook runs in — the CLI's own
        # reader accepts exactly two cached paths: one matching the versioned
        # cache glob, or today's directory-source path by exact equality. For the
        # install that is actually running, BOTH of those ARE
        # $CLAUDE_PLUGIN_ROOT/scripts/aimi-cli.sh: on a versioned install that
        # variable points into the cache, and on a directory-source install it
        # points at the checkout. So comparing against `cli` re-derives none of
        # _validate_cached_cli_path's arms while admitting exactly what they do.
        #
        # An executable-only test was strictly weaker: a cli-path naming some
        # other executable — a hand-written */.worktrees/* path, which
        # write_global_cli_cache refuses to write and the reader then refuses to
        # read, or a stale entry from an install no longer present — passed it,
        # so the hook returned early and left the session unable to resolve the
        # CLI at all. That is the one state this hook exists to repair.
        if cached == str(cli):
            return

        subprocess.run(
            [str(cli), "prime-cache"],
            timeout=_HEAL_TIMEOUT_SECS,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except Exception:  # noqa: BLE001
        return


def _read_telemetry_file(path: Path, cutoff: datetime) -> list[dict]:
    """Read a JSONL telemetry file and return entries with ts >= cutoff."""
    results = []
    if not path.exists():
        return results
    try:
        with path.open("r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                    ts_raw = entry.get("ts")
                    if ts_raw:
                        ts = datetime.fromisoformat(ts_raw)
                        # Ensure both are offset-aware for comparison
                        if ts.tzinfo is None:
                            ts = ts.replace(tzinfo=timezone.utc)
                        if ts >= cutoff:
                            results.append(entry)
                except (json.JSONDecodeError, ValueError):
                    continue
    except (OSError, json.JSONDecodeError, ValueError):
        pass
    return results


@safe_hook
def main(tool_input: dict) -> None:
    if not os.environ.get("CLAUDECODE"):
        sys.exit(0)

    # Before the quiet-mode exit, deliberately: quiet mode suppresses the banner,
    # not the plugin's ability to locate itself. Placed after this point instead,
    # every quiet-mode session would stay unhealed. It is also outside t_start's
    # window on purpose, so the two elapsed checks below keep measuring exactly
    # the banner work they were written to bound.
    _heal_cli_path_cache()

    t_start = time.monotonic()

    if is_quiet_mode():
        sys.exit(0)

    if not _read_banner_enabled():
        sys.exit(0)

    # --- Friction ---
    total_friction = 0
    scope_counts: dict[str, int] = {"project": 0, "plugin": 0, "inbox": 0}
    for event in friction_store.read_pending():
        total_friction += 1
        scope = event.get("scope", "inbox")
        if scope in scope_counts:
            scope_counts[scope] += 1
        else:
            scope_counts["inbox"] += 1

    # --- Telemetry (only if budget allows) ---
    now_utc = datetime.now(tz=timezone.utc)
    cutoff = now_utc - timedelta(hours=24)

    skills_counter: Counter[str] = Counter()
    reads_24h = 0
    telemetry_skipped = False

    telemetry_base = Path.home() / ".aimi" / "telemetry"
    skills_path = telemetry_base / "skills.jsonl"
    reads_path = telemetry_base / "reads.jsonl"

    # Read skills if budget allows
    elapsed = time.monotonic() - t_start
    if elapsed < _BUDGET_SECS:
        skill_entries = _read_telemetry_file(skills_path, cutoff)
        for entry in skill_entries:
            skill_name = entry.get("skill")
            if skill_name:
                skills_counter[skill_name] += 1

    # Read reads.jsonl only if budget still allows
    elapsed = time.monotonic() - t_start
    if elapsed < _BUDGET_SECS:
        read_entries = _read_telemetry_file(reads_path, cutoff)
        reads_24h = len(read_entries)
    else:
        telemetry_skipped = True

    # Empty state: nothing to show
    if total_friction == 0 and not skills_counter and reads_24h == 0:
        sys.exit(0)

    # Build banner lines
    lines = ["[aimi session]"]

    if total_friction > 0:
        p = scope_counts.get("project", 0)
        l_val = scope_counts.get("plugin", 0)
        i = scope_counts.get("inbox", 0)
        lines.append(
            f"  pending friction: {total_friction}  "
            f"(project: {p} / plugin: {l_val} / inbox: {i})"
        )

    if not telemetry_skipped:
        if skills_counter:
            top5 = skills_counter.most_common(5)
            skills_str = ", ".join(f"{name}×{count}" for name, count in top5)
            lines.append(f"  skills last 24h: {skills_str}")

        if reads_24h > 0:
            lines.append(f"  reads last 24h: {reads_24h}")

    lines.append("Run /aimi:learnings to triage.")

    banner_text = "\n".join(lines)

    output = {
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": banner_text,
        }
    }
    print(json.dumps(output))
    sys.exit(0)


if __name__ == "__main__":
    main()
