---
name: learnings
description: Triage pending friction events captured by hooks. Wrapper that loads the aimi-learnings skill.
disable-model-invocation: true
allowed-tools: Bash, Read, Write, AskUserQuestion
---

# Aimi Learnings

Triage the pending friction queue captured by aimi hooks.

## Arguments

<arguments> $ARGUMENTS </arguments>

## Instructions

Follow the workflow defined in
`${CLAUDE_PLUGIN_ROOT}/skills/aimi-learnings/SKILL.md` exactly.

Pass through any arguments from `$ARGUMENTS` to the skill as context (for
example, a scope filter such as `project` or `plugin` may be used to limit
triage to one scope group).
