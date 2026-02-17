---
name: plan-to-tasks
description: >
  Convert markdown implementation plans to structured tasks.json format.
  Use when user says "convert plan to tasks", "generate tasks from plan",
  "create tasks.json", or after /aimi:plan completes.
---

# Plan to Tasks Conversion

Convert a markdown implementation plan into a structured `docs/tasks/tasks.json` file for autonomous execution.

## Input

A markdown plan file path containing Implementation Phases sections.

## Output

A `docs/tasks/tasks.json` file following the schema in [task-format.md](./references/task-format.md).

## The Number One Rule: Story Size

**Each story must be completable in ONE agent iteration (one context window).**

The agent spawns fresh per iteration with no memory of previous work. If a story is too big, the agent runs out of context before finishing and produces broken code.

### Right-sized stories:
- Add a database column and migration
- Add a UI component to an existing page
- Update a server action with new logic
- Add a filter dropdown to a list

### Too big (split these):
- "Build the entire dashboard" → Split into: schema, queries, UI components, filters
- "Add authentication" → Split into: schema, middleware, login UI, session handling

**Rule of thumb:** If you cannot describe the change in 2-3 sentences, it is too big.

## Conversion Steps

1. **Read the plan file** to extract:
   - Title (from first heading or frontmatter)
   - Type (feature/refactor/bugfix/chore - infer from title prefix)
   - Implementation phases/requirements

2. **Generate metadata**:
   ```json
   {
     "title": "feat: Add user authentication",
     "type": "feature",
     "createdAt": "2026-02-16",
     "planPath": "docs/plans/2026-02-16-feat-user-auth-plan.md",
     "brainstormPath": "docs/brainstorms/..." // if exists
   }
   ```

3. **Convert each requirement to a user story**:
   - Each atomic unit of work becomes ONE story
   - Story ID: `US-001`, `US-002`, etc.
   - Set `priority` based on dependency order
   - Write description in user story format
   - Extract verifiable acceptance criteria
   - **Always add "Typecheck passes"** as final criterion
   - Set `passes: false` and `notes: ""`

4. **Order by dependencies** (set priority):
   1. Schema/database changes (migrations)
   2. Server actions / backend logic  
   3. UI components that use the backend
   4. Dashboard/summary views that aggregate data

5. **Extract success metrics** if present in plan

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

## Acceptance Criteria Rules

Each criterion must be VERIFIABLE, not vague.

### Good criteria:
- "Add `status` column to tasks table with default 'pending'"
- "Filter dropdown has options: All, Active, Completed"
- "Clicking delete shows confirmation dialog"
- "Typecheck passes"

### Bad criteria:
- "Works correctly"
- "User can do X easily"
- "Good UX"
- "Handles edge cases"

### Always include:
- `"Typecheck passes"` - EVERY story
- `"Tests pass"` - stories with testable logic
- `"Verify in browser"` - UI stories

## Splitting Large Features

If a plan has big features, split them:

**Original:**
> "Add user notification system"

**Split into:**
1. US-001: Add notifications table to database
2. US-002: Create notification service for sending notifications
3. US-003: Add notification bell icon to header
4. US-004: Create notification dropdown panel
5. US-005: Add mark-as-read functionality
6. US-006: Add notification preferences page

Each is one focused change that can be completed and verified independently.

## Example Conversion

### Input Plan Section

```markdown
# Task Status Feature

Add ability to mark tasks with different statuses.

## Requirements
- Persist status in database
- Show status badge on each task
- Toggle between pending/in-progress/done on task list
- Filter list by status
```

### Output tasks.json

```json
{
  "schemaVersion": "3.0",
  "metadata": {
    "title": "feat: Add task status feature",
    "type": "feature",
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
  ],
  "successMetrics": {
    "taskCompletionRate": "Increase by 20%"
  }
}
```

## Validation Checklist

Before writing tasks.json, verify:

- [ ] Each story is completable in one iteration (small enough)
- [ ] Stories are ordered by dependency (priority field)
- [ ] Every story has "Typecheck passes" as criterion
- [ ] UI stories have "Verify in browser" as criterion
- [ ] Acceptance criteria are verifiable (not vague)
- [ ] No story depends on a later story
- [ ] All stories have `passes: false` and empty `notes`

## Error Handling

If plan file cannot be parsed:
```
Error: Could not parse plan file. Expected markdown with requirements or phase sections.
```

If requirements are too vague to split:
```
Error: Requirements too broad. Please specify concrete deliverables.
```
