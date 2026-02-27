# Story Execution Rules

## Overview

Each story is executed by a Task-spawned agent with fresh context. This document defines the execution flow and output formats.

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
  "passes": false,
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

### Step 7: Update the Tasks File

Mark the story complete:

```json
{
  "id": "US-001",
  "passes": true,
  "notes": ""
}
```

---

## Failure Handling

If you cannot complete a story:

1. **Do NOT** mark `passes: true`
2. **Update the tasks file** with failure details:

```json
{
  "id": "US-001",
  "passes": false,
  "notes": "Failed: TypeScript error - User type missing 'status' field"
}
```

3. **Return** with clear failure report:
   - What failed
   - Error messages
   - Files involved

---

## Status Values

| Field | Value | Meaning |
|-------|-------|---------|
| `passes` | `false` | Not completed yet |
| `passes` | `true` | Completed successfully |
| `skipped` | `true` | Skipped by user (won't retry) |
