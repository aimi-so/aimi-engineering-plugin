# tasks.json Format Reference

## Overview

The tasks file is the structured task list that drives autonomous execution. Each user story represents ONE atomic unit of work that can be completed in a single agent iteration.

**Filename:** `docs/tasks/YYYY-MM-DD-[feature-name]-tasks.json`

Example: `docs/tasks/2026-02-16-task-status-tasks.json`

## Schema

```json
{
  "schemaVersion": "2.0",
  "metadata": {
    "title": "string",
    "type": "feat|ref|bug|chore",
    "branchName": "string",
    "createdAt": "YYYY-MM-DD",
    "planPath": "string",
    "brainstormPath": "string (optional)"
  },
  "userStories": [Story]
}
```

## Field Definitions

### Root Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schemaVersion` | string | Yes | Schema version, always "2.0" |
| `metadata` | object | Yes | Project metadata |
| `userStories` | array | Yes | Array of Story objects |

### Metadata Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `title` | string | Yes | Plan title (e.g., "feat: Add user authentication") |
| `type` | string | Yes | One of: `feat`, `ref`, `bug`, `chore` |
| `branchName` | string | Yes | Git branch name (e.g., "feat/add-user-auth") |
| `createdAt` | string | Yes | Creation date (YYYY-MM-DD) |
| `planPath` | string | Yes | Path to source plan markdown file |
| `brainstormPath` | string | No | Path to brainstorm file if exists |

### Story Fields

Each story is ONE atomic unit of work completable in a single agent iteration.

#### Core Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique identifier (e.g., `US-001`, `US-002`) |
| `title` | string | Yes | Short story title |
| `description` | string | Yes | User story format: "As a [user], I want [feature] so that [benefit]" |
| `acceptanceCriteria` | array | Yes | Verifiable criteria (must include "Typecheck passes") |
| `priority` | number | Yes | Execution order (lower = first, based on dependencies) |
| `passes` | boolean | Yes | `true` = completed successfully |
| `notes` | string | No | Error details or learnings |
| `skipped` | boolean | No | `true` = skipped by user |

## The Number One Rule: Story Size

**Each story must be completable in ONE agent iteration (one context window).**

The agent spawns fresh per iteration with no memory of previous work. If a story is too big, the agent runs out of context before finishing.

### Right-sized stories:
- Add a database column and migration
- Add a UI component to an existing page
- Update a server action with new logic
- Add a filter dropdown to a list

### Too big (split these):
- "Build the entire dashboard" → Split into: schema, queries, UI components, filters
- "Add authentication" → Split into: schema, middleware, login UI, session handling
- "Refactor the API" → Split into one story per endpoint or pattern

**Rule of thumb:** If you cannot describe the change in 2-3 sentences, it is too big.

## Story Ordering: Dependencies First

Stories execute in priority order. Earlier stories must not depend on later ones.

**Correct order (priority 1, 2, 3...):**
1. Schema/database changes (migrations)
2. Server actions / backend logic
3. UI components that use the backend
4. Dashboard/summary views that aggregate data

**Wrong order:**
1. UI component (depends on schema that doesn't exist yet)
2. Schema change

## Acceptance Criteria: Must Be Verifiable

Each criterion must be something the agent can CHECK, not something vague.

### Good criteria (verifiable):
- "Add `status` column to tasks table with default 'pending'"
- "Filter dropdown has options: All, Active, Completed"
- "Clicking delete shows confirmation dialog"
- "Typecheck passes"
- "Tests pass"

### Bad criteria (vague):
- "Works correctly"
- "User can do X easily"
- "Good UX"
- "Handles edge cases"

### Always include as final criterion:
```
"Typecheck passes"
```

For stories with testable logic:
```
"Tests pass"
```

For UI stories:
```
"Verify in browser"
```

## Story ID Convention

Story IDs follow the pattern: `US-XXX`

- `US-001`: First story
- `US-002`: Second story
- `US-010`: Tenth story

## Complete Example

```json
{
  "schemaVersion": "2.0",
  "metadata": {
    "title": "feat: Add task status feature",
    "type": "feat",
    "branchName": "feat/add-task-status",
    "createdAt": "2026-02-16",
    "planPath": "docs/plans/2026-02-16-task-status-plan.md"
  },
  "userStories": [
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
    },
    {
      "id": "US-002",
      "title": "Display status badge on task cards",
      "description": "As a user, I want to see task status at a glance.",
      "acceptanceCriteria": [
        "Each task card shows colored status badge",
        "Badge colors: gray=pending, blue=in_progress, green=done",
        "Typecheck passes",
        "Verify in browser"
      ],
      "priority": 2,
      "passes": false,
      "notes": ""
    },
    {
      "id": "US-003",
      "title": "Add status toggle to task list rows",
      "description": "As a user, I want to change task status directly from the list.",
      "acceptanceCriteria": [
        "Each row has status dropdown or toggle",
        "Changing status saves immediately",
        "UI updates without page refresh",
        "Typecheck passes",
        "Verify in browser"
      ],
      "priority": 3,
      "passes": false,
      "notes": ""
    },
    {
      "id": "US-004",
      "title": "Filter tasks by status",
      "description": "As a user, I want to filter the list to see only certain statuses.",
      "acceptanceCriteria": [
        "Filter dropdown: All | Pending | In Progress | Done",
        "Filter persists in URL params",
        "Typecheck passes",
        "Verify in browser"
      ],
      "priority": 4,
      "passes": false,
      "notes": ""
    }
  ]
}
```

## Status Tracking

Stories use a simple pass/fail model:

| Field | Value | Meaning |
|-------|-------|---------|
| `passes` | `false` | Not completed yet |
| `passes` | `true` | Completed successfully |
| `skipped` | `true` | Skipped by user (won't retry) |

## Validation Rules

### Required Fields Check

Before processing, validate:

1. `schemaVersion` must be "2.0"
2. `metadata.title` must be non-empty
3. `metadata.type` must be one of: feat, ref, bug, chore
4. `metadata.branchName` must be non-empty
5. `userStories` must have at least one item
6. Each story must have `id`, `title`, `description`, `acceptanceCriteria`, `priority`, `passes`
7. Each story's `acceptanceCriteria` must include "Typecheck passes"
8. Stories must be ordered by `priority` (no duplicates)

### Validation Error Format

```
Error: Invalid tasks.json - [field] is missing or invalid.
Fix: [specific action to fix]
```

