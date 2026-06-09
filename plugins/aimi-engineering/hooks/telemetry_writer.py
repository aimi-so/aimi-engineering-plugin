from __future__ import annotations

import json
import os
from pathlib import Path

_ROTATE_THRESHOLD_BYTES = 50_000_000


def _telemetry_dir() -> Path:
    return Path.home() / ".aimi" / "telemetry"


def append(category: str, payload: dict) -> None:
    """Append payload as a single JSON line to ~/.aimi/telemetry/<category>.jsonl.

    Rotates the file (rename to .jsonl.1) when it exceeds _ROTATE_THRESHOLD_BYTES.
    Silent on any IO error.
    """
    try:
        tdir = _telemetry_dir()
        tdir.mkdir(parents=True, exist_ok=True)
        target = tdir / f"{category}.jsonl"

        if target.exists() and target.stat().st_size > _ROTATE_THRESHOLD_BYTES:
            rotated = tdir / f"{category}.jsonl.1"
            target.replace(rotated)

        line = json.dumps(payload, separators=(",", ":")) + "\n"
        with target.open("a", encoding="utf-8") as fh:
            fh.write(line)
    except Exception:  # noqa: BLE001
        return None


def is_telemetry_enabled() -> bool:
    """Walk up from $CLAUDE_PLUGIN_ROOT (fallback cwd) looking for .aimi/config.json.

    Returns config.get("telemetry", {}).get("enabled", True).
    Defaults to True when file is missing.
    """
    root = os.environ.get("CLAUDE_PLUGIN_ROOT")
    start = Path(root) if root else Path(os.getcwd())

    current = start
    while True:
        candidate = current / ".aimi" / "config.json"
        if candidate.exists():
            try:
                config = json.loads(candidate.read_text(encoding="utf-8"))
                return bool(config.get("telemetry", {}).get("enabled", True))
            except Exception:  # noqa: BLE001
                return True
        parent = current.parent
        if parent == current:
            return True
        current = parent
