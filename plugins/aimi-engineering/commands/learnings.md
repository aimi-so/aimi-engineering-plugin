---
name: learnings
description: Triage pending friction events captured by hooks. Wrapper that loads the aimi-learnings skill.
disable-model-invocation: true
allowed-tools: Bash, Read, Write, AskUserQuestion
---

# Aimi Learnings

Triage the pending friction queue captured by aimi hooks.

## Quick Start

Run `/aimi:learnings` to review all pending friction events. Pass
`--scope <project|plugin|inbox>` to filter to a single scope group.
Pass `--since <date>` to narrow to events newer than a given date (e.g.
`--since 2026-06-01`).

For orchestrators that want a read-only JSON snapshot without prompting, spawn `aimi-engineering:workflow:aimi-learnings-triage` as a Task subagent instead of invoking this command.

## Arguments

<arguments> $ARGUMENTS </arguments>

## Instructions

Follow the workflow defined in
`${CLAUDE_PLUGIN_ROOT}/skills/aimi-learnings/SKILL.md` exactly.

Pass through any arguments from `$ARGUMENTS` to the skill body — for
example `--scope project` limits triage to the project scope group, and
`--since 2026-06-01` restricts the queue to events newer than that date.
These flags are forwarded to `drain-friction.py` as-is.
