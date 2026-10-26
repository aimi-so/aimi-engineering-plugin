#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

_HOOKS_DIR = Path(__file__).parent
if str(_HOOKS_DIR) not in sys.path:
    sys.path.insert(0, str(_HOOKS_DIR))

from hook_utils import safe_hook  # noqa: E402

# Upper bound for the one-off `prime-cache` spawn below. A spawn measured 299 ms
# on a directory-source install, so this is a ceiling it should never reach; it
# exists so a wedged CLI cannot stall session start indefinitely.
_HEAL_TIMEOUT_SECS = 0.5


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

    Gated on the cheap read on purpose: a `prime-cache` spawn measured 299 ms,
    while the Layer 1 read plus os.access measured 0.025 ms. Running the spawn
    unconditionally would charge that to every session on a host that needs
    nothing.

    Confinement, atomicity and the 0600 mode of the write itself are NOT
    reproduced here — `prime-cache` owns all three, and invoking the verb instead
    of re-deriving its rules is the whole point of this shape.

    Never raises: every failure mode (no CLAUDE_PLUGIN_ROOT, a root with no
    executable scripts/aimi-cli.sh, an unreadable config dir, a non-zero exit, a
    timeout) leaves the session exactly as it found it.
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


@safe_hook
def main(tool_input: dict) -> None:
    if not os.environ.get("CLAUDECODE"):
        sys.exit(0)
    _heal_cli_path_cache()
    sys.exit(0)


if __name__ == "__main__":
    main()
