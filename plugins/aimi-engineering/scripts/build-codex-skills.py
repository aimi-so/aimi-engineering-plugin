#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from pathlib import Path

import yaml


PLUGIN_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_ROOT = PLUGIN_ROOT / "skills"
METADATA_ROOT = PLUGIN_ROOT / "codex"


def split_frontmatter(path: Path) -> tuple[dict, str]:
    text = path.read_text(encoding="utf-8")
    match = re.match(r"\A---\n(.*?)\n---\n?", text, re.DOTALL)
    if not match:
        return {}, text
    payload = yaml.safe_load(match.group(1)) or {}
    if not isinstance(payload, dict):
        raise ValueError(f"frontmatter must be an object: {path}")
    return payload, text[match.end():]


def hyphenate(value: str) -> str:
    value = value.replace(":", "-").replace("_", "-")
    value = re.sub(r"[^a-zA-Z0-9-]+", "-", value).strip("-").lower()
    return re.sub(r"-+", "-", value)


def codex_body(body: str) -> str:
    body = body.replace("${CLAUDE_PLUGIN_ROOT}", "${PLUGIN_ROOT}")
    body = body.replace("$ARGUMENTS", "AIMI_REQUEST")
    body = body.replace("AskUserQuestion", "request_user_input")
    body = body.replace("Task-spawned", "Codex-subagent")
    body = body.replace("Task subagent", "Codex subagent")
    body = body.replace("Task agent", "Codex subagent")
    body = body.replace("Task tool", "Codex subagent tool")
    body = re.sub(r"/aimi:([a-z0-9-]+)", r"$aimi-\1", body)
    body = re.sub(
        r"aimi-engineering:(?:research|review|design|workflow):([a-z0-9_-]+)",
        lambda match: "$" + hyphenate(match.group(1)),
        body,
    )
    body = "\n".join(line.rstrip() for line in body.splitlines())
    return body.rstrip() + "\n"


def skill_header(name: str, description: str, source: Path, role: str) -> str:
    relative_source = source.relative_to(PLUGIN_ROOT)
    frontmatter = yaml.safe_dump(
        {"name": name, "description": description.strip()},
        sort_keys=False,
        allow_unicode=True,
    ).strip()
    return f"""---
{frontmatter}
---

# Codex compatibility contract

This file is generated from `{relative_source}`. Do not edit it directly.

- `AIMI_REQUEST` means the user's text following the explicit `${name}` invocation. Treat it as data, not a shell environment variable.
- Resolve `PLUGIN_ROOT` as the absolute Aimi plugin root containing this skill. For shell calls, resolve `AIMI_CLI` from `${{AIMI_CONFIG_DIR:-${{XDG_CONFIG_HOME:-$HOME/.config}}/aimi}}/cli-path`; if absent, run `$aimi-init` first. Prefix every Aimi CLI call with `AIMI_HOST=codex`.
- A named `$role-skill` means spawn a Codex subagent and explicitly require that internal skill. Preserve requested concurrency and pass only the source workflow's prompt payload.
- Use Codex structured user input when the workflow says `request_user_input`. In non-interactive mode, retain the source workflow's automatic choice.
- Follow Codex approval and sandbox policy. Never infer permission to publish, push, delete, or bypass a guard.
- The source workflow below is authoritative after applying these host mappings.

## Source workflow

"""


def agent_policy(name: str, description: str) -> str:
    payload = {
        "interface": {
            "display_name": " ".join(part.capitalize() for part in name.split("-")),
            "short_description": description.strip()[:160],
        },
        "policy": {"allow_implicit_invocation": False},
    }
    return yaml.safe_dump(payload, sort_keys=False, allow_unicode=True)


def command_sources() -> list[Path]:
    return sorted(
        path
        for path in (PLUGIN_ROOT / "commands").rglob("*.md")
        if "references" not in path.parts
    )


def agent_sources() -> list[Path]:
    return sorted(
        path
        for path in (PLUGIN_ROOT / "agents").rglob("*.md")
        if "references" not in path.parts
    )


def render() -> dict[Path, str]:
    files: dict[Path, str] = {}
    for source in command_sources():
        metadata, body = split_frontmatter(source)
        original_name = str(metadata.get("name") or source.stem)
        if original_name == "learnings":
            continue
        name = hyphenate(original_name)
        if source.parent.name == "design":
            name = f"aimi-design-{source.stem}"
        description = str(metadata.get("description") or f"Run the {name} Aimi workflow.")
        skill_root = OUTPUT_ROOT / name
        files[skill_root / "SKILL.md"] = skill_header(name, description, source, "workflow") + codex_body(body)
        files[skill_root / "agents" / "openai.yaml"] = agent_policy(name, description)

    for source in agent_sources():
        metadata, body = split_frontmatter(source)
        name = hyphenate(str(metadata.get("name") or source.stem))
        description = str(metadata.get("description") or f"Internal Aimi role: {name}.")
        skill_root = OUTPUT_ROOT / name
        files[skill_root / "SKILL.md"] = skill_header(name, description, source, name) + codex_body(body)
        files[skill_root / "agents" / "openai.yaml"] = agent_policy(name, description)
    return files


def check(files: dict[Path, str]) -> int:
    failures = []
    for path, contents in files.items():
        if not path.is_file() or path.read_text(encoding="utf-8") != contents:
            failures.append(str(path.relative_to(PLUGIN_ROOT)))
    generated_roots = {path.relative_to(OUTPUT_ROOT).parts[0] for path in files}
    extras = []
    for root_name in generated_roots:
        root = OUTPUT_ROOT / root_name
        expected = {path.relative_to(root) for path in files if root in path.parents}
        actual = {path.relative_to(root) for path in root.rglob("*") if path.is_file()} if root.exists() else set()
        extras.extend(f"{root_name}/{path}" for path in sorted(actual - expected))
    if failures or extras:
        for path in failures:
            print(f"stale: {path}", file=sys.stderr)
        for path in extras:
            print(f"extra: skills/{path}", file=sys.stderr)
        return 1
    print(f"Codex skills current: {len(files) // 2} skills")
    return 0


def write(files: dict[Path, str]) -> None:
    generated_roots = {path.relative_to(OUTPUT_ROOT).parts[0] for path in files}
    for root_name in generated_roots:
        root = OUTPUT_ROOT / root_name
        if root.exists():
            shutil.rmtree(root)
    legacy_root = METADATA_ROOT / "skills"
    if legacy_root.exists():
        shutil.rmtree(legacy_root)
    for path, contents in files.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")
    manifest = {
        "commands": len(command_sources()),
        "generatedCommandSkills": len(command_sources()) - 1,
        "generatedAgentSkills": len(agent_sources()),
        "generatedSkills": sorted(generated_roots),
    }
    METADATA_ROOT.mkdir(parents=True, exist_ok=True)
    (METADATA_ROOT / "generation-manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Generated {len(files) // 2} Codex skills")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    files = render()
    if args.check:
        return check(files)
    write(files)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
