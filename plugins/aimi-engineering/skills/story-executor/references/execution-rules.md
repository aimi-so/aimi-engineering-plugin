# Story Execution Rules

## Overview

Each story is executed by a Task-spawned agent with fresh context. This document defines the execution flow and output formats. The caller (next.md or execute.md) handles all tasks file status updates via the CLI.

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

You spawn fresh with no memory of previous work. If the story is too big, you'll run out of context before finishing.

---

## Execution Flow

### Step 1: Read Project Guidelines

Check for project-specific guidelines:

1. **CLAUDE.md** (project root) - Primary project instructions
2. **Default rules** - Standard conventions if not found

### Step 2: Implement the Story

Follow the story description and implement the required changes.

### Step 3: Verify Acceptance Criteria

After implementation, verify ALL acceptance criteria are met:

- Check each criterion explicitly
- For UI stories, verify in browser
- For logic stories, run tests

### Step 4: Run Quality Checks

```bash
npx tsc --noEmit
```

### Step 5: Quality Gate (FAIL FAST)

**If any check or criterion fails, STOP immediately.**

Do NOT:
- Continue with partial implementation
- Try to hack around failures
- Skip failing checks

Instead:
- Report the failure with full error details
- Include relevant file paths and line numbers

### Step 6: Commit Changes

If all checks pass, commit:

```bash
git add [changed files]
git commit -m "feat(tasks): Add status field to tasks table"
```

Commit format:
- `<type>(<scope>): <description>`
- Types: feat, fix, refactor, docs, test, chore
- Scope: module or feature area (e.g., tasks, auth, users)
- Use story title as description

### Step 7: Report Result

Do NOT update the tasks file directly. Return a result report to the caller. The caller (next.md or execute.md) handles status updates via the CLI (`mark-complete`, `mark-failed`, etc.).

---

## Failure Handling

If you cannot complete a story:

1. **Do NOT** update the tasks file — the caller handles all status changes via CLI
2. **Do NOT** commit partial or broken code
3. **Return** a clear failure report with:
   - Story ID
   - Error description
   - Files involved
   - Any partial work (uncommitted)

---

## Status Values

| Field | Values |
|-------|--------|
| `status` | `pending`, `in_progress`, `completed`, `failed`, `skipped` |
