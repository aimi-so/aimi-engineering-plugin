---
name: aimi-learnings-triage
description: Read-only triage agent for friction events captured by aimi hooks. Returns a JSON report of pending friction grouped by scope (project/plugin/inbox) with samples. Does NOT mark or modify events — pure reporting for orchestrators that want to delegate triage analysis without invoking the interactive /aimi:learnings skill. Use when an orchestrator needs a friction snapshot without prompting the user.
---

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
