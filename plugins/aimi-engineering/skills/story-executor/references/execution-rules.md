# Story Execution Rules

## Overview

Each story is executed by a Task-spawned agent with fresh context. This document defines the execution flow, quality gates, and output formats for the v2.0 schema.

## Schema Overview (v2.0)

Stories contain nested tasks:

```json
{
  "id": "story-1",
  "title": "Phase 1: Database Schema",
  "description": "Add users table with authentication fields.",
  "estimatedEffort": "1-2 hours",
  "tasks": [
    {
      "id": "task-1-1",
      "title": "Create migration",
      "description": "Create Prisma migration for users table",
      "file": "prisma/migrations/xxx/migration.sql",
      "status": "pending"
    }
  ]
}
```

Acceptance criteria are at the root level:

```json
{
  "acceptanceCriteria": {
    "functional": ["Users can register..."],
    "nonFunctional": ["No TypeScript errors"],
    "qualityGates": ["bun run lint passes"]
  }
}
```

## Execution Flow

### Step 1: Read Project Guidelines

**FIRST**, check for project-specific guidelines in this order:

1. **CLAUDE.md** (project root) - Primary project instructions
2. **AGENTS.md** (directory-specific) - Module-specific patterns
3. **Aimi defaults** - Standard conventions if neither exists

### Step 2: Understand Story Scope

Read the story details:
- Story title and description
- All tasks with their target files
- Estimated effort (to pace yourself)

### Step 3: Execute Tasks Sequentially

For each task in the story:

1. **Read the target file** (if it exists)
2. **Implement the change** described in the task
3. **Handle special actions**:
   - `action: "delete"` - Remove the file
   - `action: "create"` - Create new file
   - (default) - Modify existing file
4. **Mark task as completed** in your working state

### Step 4: Run Quality Checks

After ALL tasks are complete, run quality checks:

```bash
# Check for quality gates in acceptanceCriteria.qualityGates
# Common examples:
bun run lint
bun run test
npx tsc --noEmit
```

### Step 5: Quality Gate (FAIL FAST)

**If any quality check fails, STOP immediately.**

Do NOT:
- Continue with partial implementation
- Try to hack around failures
- Skip failing checks

Instead:
- Report the failure with full error details
- Include relevant file paths and line numbers
- Suggest potential fixes if obvious

### Step 6: Commit Changes

If all checks pass, commit with this format:

```bash
git add [changed files]
git commit -m "feat: [story-1] - Phase 1: Database Schema"
```

Commit message format:
- `feat:` for feature/refactor work
- `fix:` for bug fixes
- `[story-id]` from the story
- Title from story title

### Step 7: Update tasks.json

Read `docs/tasks/tasks.json`, update the story's tasks:

```json
{
  "id": "story-1",
  "tasks": [
    {
      "id": "task-1-1",
      "status": "completed"
    },
    {
      "id": "task-1-2", 
      "status": "completed"
    }
  ]
}
```

### Step 8: Update AGENTS.md or CLAUDE.md (if learnings)

If you discovered something future developers/agents should know:

**Good additions:**
- "When modifying X, also update Y"
- "This module uses pattern Z"
- "Tests require dev server on PORT 3000"

**Where to add:**
- **CLAUDE.md** (root) - Project-wide patterns
- **AGENTS.md** (directory) - Module-specific patterns

Only add **genuinely reusable knowledge**.

## Failure Handling

If you cannot complete a task:

1. **Do NOT** mark task as completed
2. **Stop execution** - do not proceed to remaining tasks
3. **Update tasks.json** with failure details:

```json
{
  "id": "task-1-2",
  "status": "pending",
  "notes": "Failed: TypeScript error in UserModel - missing field 'createdAt'"
}
```

4. **Return** with clear failure report:
   - Which task failed
   - Error messages
   - Files involved
   - Suggested fix if known

## Task Status Values

| Status | Meaning |
|--------|---------|
| `pending` | Not started |
| `in_progress` | Currently working on |
| `completed` | Successfully finished |
| `skipped` | Intentionally skipped (blocked or not applicable) |

## Deployment Order Awareness

The root `deploymentOrder` array indicates the intended deployment sequence:

```json
{
  "deploymentOrder": [
    "Phase 0: Deploy backend with optional fields",
    "Phase 1-5: Deploy backend changes",
    "Verify: Test API endpoints",
    "Phase 6-9: Deploy frontend changes"
  ]
}
```

Stories should be executed in order (story-0, story-1, story-2, etc.) to respect dependencies.

## Quality Gates Reference

Common quality gates from `acceptanceCriteria.qualityGates`:

| Gate | Command |
|------|---------|
| Lint | `bun run lint`, `npm run lint` |
| Test | `bun run test`, `npm test` |
| Typecheck | `npx tsc --noEmit`, `bun check` |
| Build | `bun run build`, `npm run build` |
| E2E test | Manual - report if required |

## Success Metrics

The root `successMetrics` object tracks improvements:

```json
{
  "successMetrics": {
    "apiCalls": "2 → 1",
    "saveTime": "~400ms → ~200ms",
    "linesRemoved": "~225"
  }
}
```

These are informational - verify them where possible during implementation.
