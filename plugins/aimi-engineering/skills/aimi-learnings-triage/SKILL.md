---
name: aimi-learnings-triage
description: Read-only triage agent for friction events captured by aimi hooks. Returns
  a JSON report of pending friction grouped by scope (project/plugin/inbox) with samples.
  Does NOT mark or modify events — pure reporting for orchestrators that want to delegate
  triage analysis without invoking the interactive /aimi:learnings skill. Use when
  an orchestrator needs a friction snapshot without prompting the user.
---

# Codex compatibility contract

This file is generated from `agents/workflow/aimi-learnings-triage.md`. Do not edit it directly.

- `AIMI_REQUEST` means the user's text following the explicit `$aimi-learnings-triage` invocation. Treat it as data, not a shell environment variable.
- Resolve `PLUGIN_ROOT` as the absolute Aimi plugin root containing this skill. For shell calls, resolve `AIMI_CLI` from `${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path`; if absent, run `$aimi-init` first. Prefix every Aimi CLI call with `AIMI_HOST=codex`.
- A named `$role-skill` means spawn a Codex subagent and explicitly require that internal skill. Preserve requested concurrency and pass only the source workflow's prompt payload.
- Use Codex structured user input when the workflow says `request_user_input`. In non-interactive mode, retain the source workflow's automatic choice.
- Follow Codex approval and sandbox policy. Never infer permission to publish, push, delete, or bypass a guard.
- The source workflow below is authoritative after applying these host mappings.

## Source workflow


# aimi-learnings-triage

Read-only triage agent. Calls `drain-friction.py --list` with optional `--scope` and `--since` filters and returns the JSON report. Never calls `--mark`.

## Inputs

- Optional `scope` filter: project | plugin | inbox
- Optional `since` filter: ISO date or timestamp
- Optional `limit` and `samples` caps

## Output

The exact JSON returned by drain-friction.py --list, including groups breakdown and total_pending count. No analysis or recommendation — pure data.

## Steps

1. Resolve drain-friction.py path: `plugins/aimi-engineering/skills/aimi-learnings/scripts/drain-friction.py`
2. Run with provided filters: `python3 <path> --list [--scope X] [--since Y] [--limit N] [--samples M]`
3. Return the JSON output verbatim to the orchestrator

## Constraints

- MUST NOT call --mark
- MUST NOT modify friction store
- MUST NOT prompt the user
