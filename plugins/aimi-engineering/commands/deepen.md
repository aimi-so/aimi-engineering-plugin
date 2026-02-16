---
name: aimi:deepen
description: Enhance plan with research and update tasks.json
argument-hint: "[path to plan file]"
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Skill(plan-to-tasks)
---

# Aimi Deepen

Enhance an existing plan with research insights, then update tasks.json while preserving completion state.

## Step 1: Enhance Plan

Run compound-engineering's deepen workflow:

/deepen-plan $ARGUMENTS

## Step 2: Read Current State

After deepening completes, read `docs/tasks/tasks.json` to capture current state:

- Which stories have `completed: true`
- Current `notes` field contents
- Current `attempts` counts
- Current `lastAttempt` timestamps

## Step 3: Re-Convert to Tasks

Re-read the enhanced plan file.
Re-invoke the plan-to-tasks skill to generate updated stories.

## Step 4: Preserve State

**CRITICAL:** Merge the new conversion with existing state:

For each story in the new conversion:
- If a matching story (by ID or title) exists in old state:
  - Keep `completed` value from old state
  - Keep `notes` value from old state
  - Keep `attempts` value from old state
  - Keep `lastAttempt` value from old state
  - Update `acceptanceCriteria` with enhanced details
- If no match, use new story as-is

## Step 5: Update tasks.json

Write the merged result to `docs/tasks/tasks.json`.

Add or update `deepenedAt` field with current ISO 8601 timestamp.

## Step 6: Report Changes

Tell the user what was enhanced:

```
Plan deepened successfully!

Updated stories:
- US-001: Added [X] new acceptance criteria
- US-003: Enhanced description with research insights

Preserved state:
- [Y] completed stories kept their status
- [Z] stories with notes preserved

Run `/aimi:status` to view updated task list.
```
