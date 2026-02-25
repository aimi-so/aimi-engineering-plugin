---
name: plan-to-tasks
description: "Convert implementation plans to tasks.json format for autonomous execution. Use when you have a plan and need to convert it to tasks format. Triggers on: convert plan to tasks, create tasks.json, generate tasks from plan."
user-invocable: true
---

# Plan to Tasks Converter

Converts implementation plans (markdown files) to the tasks.json format for autonomous agent execution.

> **Note:** This skill is for converting external markdown plans. For direct generation from a feature description (no intermediate plan), use the `task-planner` skill instead.

---

## The Job

Take a plan (markdown file) and convert it to `docs/tasks/YYYY-MM-DD-[feature-name]-tasks.json`.

---

## Output Format

**Filename:** `docs/tasks/YYYY-MM-DD-[feature-name]-tasks.json`

Example: `docs/tasks/2026-02-16-task-status-tasks.json`

```json
{
  "schemaVersion": "2.2",
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
      "title": "[Story title]",
      "description": "As a [user], I want [feature] so that [benefit]",
      "acceptanceCriteria": [
        "Criterion 1",
        "Criterion 2",
        "Typecheck passes"
      ],
      "priority": 1,
      "passes": false,
      "notes": ""
    }
  ]
}
```

### Type Values

| Type | Use When |
|------|----------|
| `feat` | New feature |
| `ref` | Refactoring |
| `bug` | Bug fix |
| `chore` | Maintenance task |

---

## Story Size: The Number One Rule

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

**Rule of thumb:** If you cannot describe the change in 2-3 sentences, it is too big.

---

## Story Ordering: Dependencies First

Stories execute in priority order. Earlier stories must not depend on later ones.

**Correct order:**
1. Schema/database changes (migrations)
2. Server actions / backend logic
3. UI components that use the backend
4. Dashboard/summary views that aggregate data

**Wrong order:**
1. UI component (depends on schema that does not exist yet)
2. Schema change

---

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

For stories that change UI:
```
"Verify in browser"
```

---

## Conversion Rules

1. **Each requirement becomes one JSON story**
2. **IDs**: Sequential (US-001, US-002, etc.)
3. **Priority**: Based on dependency order
4. **All stories**: `passes: false` and empty `notes`
5. **branchName**: Derive from feature name, kebab-case, prefixed with type
6. **Always add**: "Typecheck passes" to every story's acceptance criteria

---

## Splitting Large Plans

If a plan has big features, split them:

**Original:**
> "Add user notification system"

**Split into:**
1. US-001: Add notifications table to database
2. US-002: Create notification service for sending
3. US-003: Add notification bell icon to header
4. US-004: Create notification dropdown panel
5. US-005: Add mark-as-read functionality

Each is one focused change that can be completed and verified independently.

---

## Example

**Input Plan:**
```markdown
# Task Status Feature

Add ability to mark tasks with different statuses.

## Requirements
- Persist status in database
- Show status badge on each task
- Toggle between pending/in-progress/done
- Filter list by status
```

**Output `docs/tasks/2026-02-16-task-status-tasks.json`:**
```json
{
  "schemaVersion": "2.2",
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

---

## Checklist Before Saving

Before writing tasks.json, verify:

- [ ] Each story is completable in one iteration (small enough)
- [ ] Stories are ordered by dependency (schema → backend → UI)
- [ ] Every story has "Typecheck passes" as criterion
- [ ] UI stories have "Verify in browser" as criterion
- [ ] Acceptance criteria are verifiable (not vague)
- [ ] No story depends on a later story
