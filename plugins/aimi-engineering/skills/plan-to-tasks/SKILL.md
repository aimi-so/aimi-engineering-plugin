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

4. **Generate task-specific fields for each story** (see below)

5. **Order by dependencies** (set priority):
   1. Schema/database changes (migrations)
   2. Server actions / backend logic  
   3. UI components that use the backend
   4. Dashboard/summary views that aggregate data

6. **Set schemaVersion to "2.0"**

7. **Extract success metrics** if present in plan

## Task-Specific Field Generation

For each story, generate 4 additional fields to guide agent execution.

### Step 1: Detect taskType

Scan the story's title + description for keywords and classify into one of 7 types:

| taskType | Keywords to Match |
|----------|-------------------|
| `prisma_schema` | schema, migration, database, table, column, model, prisma, db |
| `server_action` | action, server, backend, mutation, query, server action, use server |
| `react_component` | component, ui, display, render, page, view, button, form, modal |
| `api_route` | endpoint, route, api, handler, get, post, put, delete, request |
| `utility` | helper, util, function, service, lib, hook, context |
| `test` | test, spec, unit test, integration test, e2e |
| `other` | (fallback when no keywords match) |

**Detection logic:**
```
text = (story.title + " " + story.description).toLowerCase()

if text matches /schema|migration|database|table|column|model|prisma|db/
  → return "prisma_schema"
if text matches /action|server|backend|mutation|query|server action|use server/
  → return "server_action"
if text matches /component|ui|display|render|page|view|button|form|modal/
  → return "react_component"
if text matches /endpoint|route|api|handler|get|post|put|delete|request/
  → return "api_route"
if text matches /helper|util|function|service|lib|hook|context/
  → return "utility"
if text matches /test|spec|unit test|integration test|e2e/
  → return "test"
else
  → return "other"
```

### Step 2: Generate steps

Use predefined templates based on taskType. **Every template starts with "Read CLAUDE.md and AGENTS.md for project conventions"**.

#### prisma_schema steps:
```json
[
  "Read CLAUDE.md and AGENTS.md for project conventions",
  "Read prisma/schema.prisma to understand existing models",
  "Add/modify the model or field",
  "Run: npx prisma generate",
  "Run: npx prisma migrate dev --name [descriptive-name]",
  "Verify typecheck passes"
]
```

#### server_action steps:
```json
[
  "Read CLAUDE.md and AGENTS.md for project conventions",
  "Read existing actions in the module to understand patterns",
  "Create/update the server action function",
  "Add proper error handling and validation",
  "Export the action from actions.ts",
  "Run typecheck and tests"
]
```

#### react_component steps:
```json
[
  "Read CLAUDE.md and AGENTS.md for project conventions",
  "Read existing components to understand patterns",
  "Create the component file with proper types",
  "Import and use in parent component",
  "Style according to existing patterns",
  "Verify typecheck passes"
]
```

#### api_route steps:
```json
[
  "Read CLAUDE.md and AGENTS.md for project conventions",
  "Read existing API routes to understand patterns",
  "Create/update the route handler",
  "Add request validation and error handling",
  "Test the endpoint manually or with tests",
  "Verify typecheck passes"
]
```

#### utility steps:
```json
[
  "Read CLAUDE.md and AGENTS.md for project conventions",
  "Read related utility files to understand patterns",
  "Create/update the utility function",
  "Add proper types and JSDoc comments",
  "Write unit tests for the utility",
  "Verify typecheck and tests pass"
]
```

#### test steps:
```json
[
  "Read CLAUDE.md and AGENTS.md for project conventions",
  "Read the code being tested to understand behavior",
  "Create test file following project test patterns",
  "Write test cases covering happy path and edge cases",
  "Run tests to verify they pass",
  "Verify typecheck passes"
]
```

#### other steps (generic fallback):
```json
[
  "Read CLAUDE.md and AGENTS.md for project conventions",
  "Read relevant files to understand current state",
  "Implement the required changes",
  "Verify acceptance criteria",
  "Run quality checks",
  "Verify typecheck passes"
]
```

### Step 3: Infer relevantFiles

Extract file paths mentioned in the story content (description + acceptanceCriteria). If none found, use taskType defaults.

**Extraction logic:**
```
mentioned = extract file paths from (story.description + story.acceptanceCriteria.join(" "))
  - Match patterns like: src/..., prisma/..., app/..., pages/..., *.tsx, *.ts

if mentioned is not empty:
  return mentioned

else return defaults based on taskType:
  prisma_schema → ["prisma/schema.prisma"]
  server_action → ["src/actions/", "app/actions/"]
  react_component → ["src/components/"]
  api_route → ["app/api/", "pages/api/"]
  utility → ["src/lib/", "src/utils/"]
  test → ["__tests__/", "*.test.ts"]
  other → []
```

### Step 4: Assign qualityChecks

Assign verification commands based on taskType:

| taskType | qualityChecks |
|----------|---------------|
| `prisma_schema` | `["npx tsc --noEmit"]` |
| `server_action` | `["npx tsc --noEmit", "npm test"]` |
| `react_component` | `["npx tsc --noEmit"]` |
| `api_route` | `["npx tsc --noEmit", "npm test"]` |
| `utility` | `["npx tsc --noEmit", "npm test"]` |
| `test` | `["npm test"]` |
| `other` | `["npx tsc --noEmit"]` |

## Story Format (v2.0)

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
  "notes": "",
  "taskType": "prisma_schema",
  "steps": [
    "Read CLAUDE.md and AGENTS.md for project conventions",
    "Read prisma/schema.prisma to understand existing models",
    "Add/modify the model or field",
    "Run: npx prisma generate",
    "Run: npx prisma migrate dev --name [descriptive-name]",
    "Verify typecheck passes"
  ],
  "relevantFiles": ["prisma/schema.prisma"],
  "qualityChecks": ["npx tsc --noEmit"]
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

## Example Conversion (v2.0)

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
  "schemaVersion": "2.0",
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
      "notes": "",
      "taskType": "prisma_schema",
      "steps": [
        "Read CLAUDE.md and AGENTS.md for project conventions",
        "Read prisma/schema.prisma to understand existing models",
        "Add/modify the model or field",
        "Run: npx prisma generate",
        "Run: npx prisma migrate dev --name add-status-field",
        "Verify typecheck passes"
      ],
      "relevantFiles": ["prisma/schema.prisma"],
      "qualityChecks": ["npx tsc --noEmit"]
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
      "notes": "",
      "taskType": "react_component",
      "steps": [
        "Read CLAUDE.md and AGENTS.md for project conventions",
        "Read existing components to understand patterns",
        "Create the component file with proper types",
        "Import and use in parent component",
        "Style according to existing patterns",
        "Verify typecheck passes"
      ],
      "relevantFiles": ["src/components/TaskCard.tsx"],
      "qualityChecks": ["npx tsc --noEmit"]
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
      "notes": "",
      "taskType": "react_component",
      "steps": [
        "Read CLAUDE.md and AGENTS.md for project conventions",
        "Read existing components to understand patterns",
        "Create the component file with proper types",
        "Import and use in parent component",
        "Style according to existing patterns",
        "Verify typecheck passes"
      ],
      "relevantFiles": ["src/components/TaskList.tsx"],
      "qualityChecks": ["npx tsc --noEmit"]
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
      "notes": "",
      "taskType": "react_component",
      "steps": [
        "Read CLAUDE.md and AGENTS.md for project conventions",
        "Read existing components to understand patterns",
        "Create the component file with proper types",
        "Import and use in parent component",
        "Style according to existing patterns",
        "Verify typecheck passes"
      ],
      "relevantFiles": ["src/components/TaskFilters.tsx"],
      "qualityChecks": ["npx tsc --noEmit"]
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
- [ ] **All stories have `taskType`, `steps`, `relevantFiles`, `qualityChecks`** (v2.0)
- [ ] **All `steps[0]` start with "Read CLAUDE.md and AGENTS.md"**
- [ ] **schemaVersion is "2.0"**

## Error Handling

If plan file cannot be parsed:
```
Error: Could not parse plan file. Expected markdown with requirements or phase sections.
```

If requirements are too vague to split:
```
Error: Requirements too broad. Please specify concrete deliverables.
```
