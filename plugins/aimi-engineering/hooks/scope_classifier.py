from __future__ import annotations

import os
from pathlib import Path


def classify_scope(prompt_text: str, frame_name: str | None) -> str:
    """Classify the scope of a prompt/frame as 'plugin', 'project', or 'inbox'.

    Classification priority:
    1. 'plugin' — if any plugin signal matches
    2. 'project' — if .aimi/ directory found above cwd and not inside plugin root
    3. 'inbox' — fallback when no signals matched
    """
    # --- Plugin signals ---
    # Frame name starts with "aimi:" or "aimi-engineering:" (case-insensitive)
    if frame_name is not None:
        lower_frame = frame_name.lower()
        if lower_frame.startswith("aimi:") or lower_frame.startswith("aimi-engineering:"):
            return "plugin"

    # Prompt text contains plugin-related keywords (case-insensitive)
    _PLUGIN_KEYWORDS = [
        "skill",
        "hook",
        "tasks.json",
        "aimi-cli",
        "hooks.json",
        "story-merge",
        "/aimi:",
    ]
    if prompt_text:
        lower_prompt = prompt_text.lower()
        for kw in _PLUGIN_KEYWORDS:
            if kw.lower() in lower_prompt:
                return "plugin"

    # $CLAUDE_PLUGIN_ROOT is set AND cwd resolves under it
    plugin_root_env = os.environ.get("CLAUDE_PLUGIN_ROOT")
    if plugin_root_env:
        try:
            plugin_root = Path(plugin_root_env).resolve()
            cwd = Path(os.getcwd()).resolve()
            if cwd == plugin_root or cwd.is_relative_to(plugin_root):
                return "plugin"
        except Exception:  # noqa: BLE001
            pass

    # --- Project signals ---
    # Walk up from cwd to find .aimi/ directory
    try:
        plugin_root_resolved: Path | None = None
        if plugin_root_env:
            try:
                plugin_root_resolved = Path(plugin_root_env).resolve()
            except Exception:  # noqa: BLE001
                pass

        current = Path(os.getcwd()).resolve()
        while True:
            candidate = current / ".aimi"
            if candidate.is_dir():
                # Found .aimi/ — check that its parent != $CLAUDE_PLUGIN_ROOT
                aimi_parent = current
                if plugin_root_resolved is None or aimi_parent != plugin_root_resolved:
                    return "project"
                # .aimi/ is inside plugin root — fall through to inbox
                break
            parent = current.parent
            if parent == current:
                break
            current = parent
    except Exception:  # noqa: BLE001
        pass

    # --- Inbox fallback ---
    return "inbox"
