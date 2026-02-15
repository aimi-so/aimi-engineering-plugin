# Story Execution Rules

## Overview

Each story is executed by a Task-spawned agent with fresh context. This document defines the execution flow, quality gates, and output formats.

## Execution Flow

### Step 1: Read Progress Log

**FIRST**, read `docs/tasks/progress.md`, especially the **Codebase Patterns** section at the top.

This contains learnings from previous stories that will help you:
- Understand project conventions
- Avoid known gotchas
- Follow established patterns

### Step 2: Read Story Details

Read your assigned story from `docs/tasks/tasks.json`.

Understand:
- Title and description
- All acceptance criteria
- Priority (for context on what came before)

### Step 3: Implement the Story

Follow acceptance criteria exactly:
- Read existing code to understand patterns
- Implement the required changes
- Write tests if required by criteria

### Step 4: Run Quality Checks

Run ALL quality checks required by the project:

```bash
# Typecheck (required for all code changes)
# Examples: tsc, bun check, npx tsc --noEmit

# Linting
# Examples: eslint, rubocop, ruff

# Tests
# Examples: bun test, npm test, pytest, bin/rails test
```

### Step 5: Quality Gate

**FAIL FAST:** If any quality check fails, STOP immediately.

Do NOT:
- Continue with partial implementation
- Mark the story as passed
- Try to hack around failures

Instead:
- Report the failure with full error details
- Include relevant file paths and line numbers
- Suggest potential fixes if obvious

### Step 6: Commit Changes

If all checks pass, commit with this format:

```bash
git add [changed files]
git commit -m "feat: [US-XXX] - [Story title]"
```

Examples:
- `feat: [US-001] - Add users database schema`
- `feat: [US-002] - Add password hashing utility`
- `fix: [US-005] - Fix login redirect`

### Step 7: Update tasks.json

Read `docs/tasks/tasks.json`, update your story:

```json
{
  "id": "US-XXX",
  "passes": true,
  "notes": "Completed successfully. [brief notes]",
  "attempts": 1,
  "lastAttempt": "2026-02-15T10:45:00Z"
}
```

Write the updated file.

### Step 8: Append to Progress Log

Append your progress entry to `docs/tasks/progress.md`:

```markdown
---

## US-XXX - [Story title]

**Completed:** [ISO 8601 timestamp]
**Files changed:** `path/to/file1.ts`, `path/to/file2.ts`

**What was implemented:**
- [Bullet point 1]
- [Bullet point 2]

**Learnings:**
- [Pattern discovered]
- [Gotcha encountered]
```

### Step 9: Update Codebase Patterns (if applicable)

If you discovered a significant pattern or gotcha, ADD it to the **Codebase Patterns** section at the TOP of progress.md.

Examples of patterns worth adding:
- Import conventions (e.g., "Use `@/` alias for absolute imports")
- Required commands after changes (e.g., "Run `prisma generate` after schema changes")
- Project-specific conventions (e.g., "All services follow repository pattern")
- Known gotchas (e.g., "Tests require dev server on PORT 3000")

## progress.md Format

```markdown
# Aimi Progress Log

**Project:** [project name]
**Branch:** [branch name]
**Started:** [timestamp]
**Plan:** [link to plan file]

---

## Codebase Patterns

_Consolidated learnings from all stories (read this first)_

- Pattern: Use `@/` alias for absolute imports in this codebase
- Pattern: All services follow DDD repository pattern
- Gotcha: Must run `bun run prisma:generate` after schema changes
- Gotcha: Tests require dev server running on PORT 3000

---

## US-001 - Add database schema

**Completed:** 2026-02-15T10:45:00Z
**Files changed:** `prisma/schema.prisma`, `src/modules/x/x.repository.ts`

**What was implemented:**
- Added X table with columns a, b, c
- Created repository with CRUD operations

**Learnings:**
- This codebase uses Prisma with Bun runtime
- Migrations auto-apply in dev mode

---

## US-002 - Add password utilities

**Completed:** 2026-02-15T11:15:00Z
**Files changed:** `src/lib/auth/password.ts`, `src/lib/auth/password.test.ts`

**What was implemented:**
- Hash function using bcrypt with cost 12
- Verify function for password comparison
- Unit tests for both functions

**Learnings:**
- Project uses vitest for testing
- Test files co-located with source
```

## Failure Handling

If you fail to complete a story:

1. **Do NOT** mark `passes: true`
2. **Update** tasks.json with:
   ```json
   {
     "passes": false,
     "notes": "Failed: [detailed error message]",
     "attempts": [increment],
     "lastAttempt": "[timestamp]"
   }
   ```
3. **Return** with clear failure report including:
   - What went wrong
   - Error messages
   - Files involved
   - Suggested fix if known
