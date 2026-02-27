---
name: story-executor
description: >
  Execute a single story from the tasks file autonomously.
  This skill defines how Task-spawned agents execute individual stories.
  Used internally by /aimi:execute and /aimi:status commands.
---

# Story Executor

Defines how Task-spawned agents execute individual stories from the tasks file.

---

## The Job

Execute ONE story from the tasks file:
0. If WORKTREE_PATH is provided, cd to it first
1. Read project guidelines (CLAUDE.md)
2. Implement the story
3. Verify acceptance criteria
4. Commit changes
5. Report result — the caller (next.md/execute.md) handles status updates via the CLI

---

## Story Format

```json
{
  "id": "US-001",
  "title": "Add status field to tasks table",
  "description": "As a developer, I need to store task status in the database.",
  "acceptanceCriteria": [
    "Add status column: 'pending' | 'in_progress' | 'done' (default 'pending')",
    "Generate and run migration successfully",
    "Typecheck passes"
  ],
  "priority": 1,
  "status": "pending",
  "dependsOn": [],
  "notes": ""
}
```

---

## The Number One Rule

**Each story must be completable in ONE iteration (one context window).**

The agent spawns fresh with no memory of previous work. If the story is too big, the agent runs out of context before finishing.

---

## Prompt Template

> This is the canonical worker prompt template. execute.md and next.md should reference this skill rather than duplicating the prompt inline.

When spawning a Task agent to execute a story:

```
You are executing a single story from the tasks file.

## PROJECT GUIDELINES (READ FIRST)

[CLAUDE.md content or default rules]

## Worktree Context (if applicable)

[WORKTREE_PATH]  ← optional, provided by execute.md parallel mode

If WORKTREE_PATH is provided:
- cd to WORKTREE_PATH before any work
- All file operations happen within the worktree
- Commit to the worktree's branch (already checked out)
- Do NOT modify the tasks.json file (leader handles this)
- Report result (success/failure + details) — the leader processes your report

If no WORKTREE_PATH:
- Work in current directory (standard sequential behavior)
- Report result — the caller (next.md/execute.md) handles status updates via the CLI

## Your Story

ID: [STORY_ID]
Title: [STORY_TITLE]
Description: [STORY_DESCRIPTION]

## Acceptance Criteria

[ACCEPTANCE_CRITERIA_BULLETED]

## Previous Notes (if non-empty)

[story.notes]

## Execution Flow

0. If WORKTREE_PATH is set, cd to WORKTREE_PATH
1. Read CLAUDE.md for project conventions
2. Implement the story requirements
3. Verify ALL acceptance criteria are met
4. Run typecheck: npx tsc --noEmit
5. If all checks pass, commit with: "feat(scope): Story title"
6. If WORKTREE_PATH is set: do NOT update tasks file — return result report instead
   If no WORKTREE_PATH: do NOT update tasks file directly — the caller (next.md/execute.md) handles status updates via the CLI

## On Failure

If you cannot complete the story:

1. Do NOT update the tasks file (the caller handles status via CLI)
2. Return with clear failure report including error details
3. The caller will mark the story as failed and handle dependent stories
```

---

## Failure Handling

If you cannot complete a story:

1. **Do NOT** update the tasks file — the caller (next.md or execute.md leader) handles all status changes via CLI
2. **Do NOT** run cascade-skip — the caller handles dependent story skipping
3. **Return** a clear failure report with:
   - Story ID
   - Error description
   - Any partial work committed (or not)
4. The caller will mark the story as failed and handle dependent stories

---

## Checklist

Before completing a story:

- [ ] All acceptance criteria verified
- [ ] Typecheck passes (`npx tsc --noEmit`)
- [ ] Changes committed with proper format
- [ ] Result report returned to caller (do NOT update tasks file directly — caller handles via CLI)
