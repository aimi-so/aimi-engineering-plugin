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
0. If PROJECT_PATH is provided, cd to it first; if WORKTREE_PATH is also provided, cd to WORKTREE_PATH instead (worktree takes precedence)
1. Read project guidelines (CLAUDE.md)
2. Implement the story
3. Verify acceptance criteria
4. Commit changes
5. Report result — the caller (next.md/execute.md) handles status updates via the CLI

---

## Story Format

> Each story is one atomic unit of work completable in a single agent iteration.
> Key fields: `id(US-NNN)`, `title(<=200)`, `description(<=500)`, `acceptanceCriteria(each<=600)`, `priority`, `status`, `dependsOn([])`, `notes`, `project(optional, relative path for multi-repo)`

---

## The Number One Rule

**Each story must be completable in ONE iteration (one context window).**

The agent spawns fresh with no memory of previous work. If the story is too big, the agent runs out of context before finishing.

---

## Project Root Boundary (CRITICAL)

**Agents must NOT read or modify files outside the project boundary.**

- The project boundary is PROJECT_PATH when set, otherwise the git repository root (where `.git/` lives)
- All file operations (Read, Write, Edit, Bash) must target paths within the project boundary
- Worktree paths under `.worktrees/` inside the git root are explicitly allowed
- Never use `../` traversal to escape the project boundary
- Never read system files, home directory configs, or files in parent directories
- If a task seems to require accessing files outside the project boundary, report failure instead of proceeding

---

## Prompt Template

> This is the canonical worker prompt template. execute.md and next.md should reference this skill rather than duplicating the prompt inline.

When spawning a Task agent to execute a story:

```
You are executing a single story from the tasks file.

## PROJECT GUIDELINES (READ FIRST)

[CLAUDE.md content or default rules]

## Project Context

[PROJECT_PATH]   ← optional, resolved absolute path to the target project

If PROJECT_PATH is provided:
- cd to PROJECT_PATH before any work
- Load CLAUDE.md from PROJECT_PATH root
- All file operations stay within PROJECT_PATH

## Worktree Context

[WORKTREE_PATH]  ← optional, provided by execute.md parallel mode

If both PROJECT_PATH and WORKTREE_PATH are provided:
- cd to WORKTREE_PATH (worktree takes precedence; it is inside the project repo)
- All file operations happen within the worktree
- Commit to the worktree's branch (already checked out)
- Do NOT modify the tasks.json file (leader handles this)
- Report result (success/failure + details) — the leader processes your report

If only WORKTREE_PATH is provided:
- cd to WORKTREE_PATH before any work
- All file operations happen within the worktree
- Commit to the worktree's branch (already checked out)
- Do NOT modify the tasks.json file (leader handles this)
- Report result (success/failure + details) — the leader processes your report

If neither is provided:
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

## Tools

Use built-in tools directly: Read, Write, Edit, Bash, Grep, Glob.
Do NOT invoke these via the Skill tool — "write" is a Write tool, not a skill.

## Project Root Boundary (CRITICAL)

All file operations MUST stay within the project boundary: PROJECT_PATH when set, otherwise the git repository root.
- Do NOT read or modify files outside the project boundary
- Worktree paths (.worktrees/ inside git root) are allowed
- Never use ../ traversal to escape the project boundary
- If a task requires accessing external files, report failure instead

## Execution Flow

0. If PROJECT_PATH is set, cd to PROJECT_PATH; if WORKTREE_PATH is also set, cd to WORKTREE_PATH instead (takes precedence)
1. Read CLAUDE.md for project conventions (from PROJECT_PATH root when set)
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

- [ ] All file operations stayed within project root (no parent directory access)
- [ ] All acceptance criteria verified
- [ ] Typecheck passes (`npx tsc --noEmit`)
- [ ] Changes committed with proper format
- [ ] Result report returned to caller (do NOT update tasks file directly — caller handles via CLI)
