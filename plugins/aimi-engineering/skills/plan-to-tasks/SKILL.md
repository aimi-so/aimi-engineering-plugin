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

## Conversion Steps

1. **Read the plan file** to extract:
   - Title (from first heading or frontmatter)
   - Type (feature/refactor/bugfix/chore - infer from title prefix)
   - Implementation phases with tasks

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

3. **Convert each phase to a story**:
   - Each phase becomes one story
   - Story ID: `story-0`, `story-1`, etc.
   - Extract estimated effort from phase details
   - Convert phase tasks to task objects

4. **Convert phase tasks to task objects**:
   ```json
   {
     "id": "task-1-1",
     "title": "Create users table migration",
     "description": "Create Prisma migration to add users table",
     "file": "prisma/migrations/[timestamp]_add_users/migration.sql",
     "status": "pending"
   }
   ```

5. **Extract acceptance criteria** into three categories:
   - `functional`: Feature requirements
   - `nonFunctional`: Performance, security, quality requirements
   - `qualityGates`: Commands that must pass (lint, test, typecheck)

6. **Generate deployment order** from phases:
   - List deployment steps in order
   - Include verification steps between phases

7. **Extract success metrics** if present in plan

## Story Ordering

Stories should follow dependency order:

1. **Phase 0**: Rolling deploy safety / backward compatibility
2. **Backend phases**: Schema → Domain → Controllers → Services
3. **Frontend phases**: Types → API → Hooks → Components
4. **Data migration phases**: Step remapping, cleanup
5. **Final phases**: Documentation, tests

## Task ID Convention

Task IDs follow: `task-{story-index}-{task-index}`

- `task-0-1`: Story 0, Task 1
- `task-1-3`: Story 1, Task 3

## Special Task Actions

Use the `action` field for special operations:

| Action | Description |
|--------|-------------|
| `delete` | File should be deleted |
| `create` | New file to create |
| (omit) | Default: modify existing file |

## Effort Estimation

Infer effort from task complexity:

| Estimate | Scope |
|----------|-------|
| "15 minutes" | Single file, small change |
| "30 minutes" | 1-3 files, straightforward |
| "1 hour" | Multiple files, some complexity |
| "1-2 hours" | Significant changes |
| "2-3 hours" | Complex feature, many files |

## Example Conversion

### Input Plan Section

```markdown
### Phase 1: Database Schema

Create the users table with authentication fields.

**Estimated effort:** 1-2 hours

**Tasks:**
1. Create audit backup table
2. Create migration to add users table
3. Update Prisma schema

**Files:**
- prisma/migrations/[timestamp]_add_users/migration.sql
- prisma/schema.prisma
```

### Output Story

```json
{
  "id": "story-1",
  "title": "Phase 1: Database Schema",
  "description": "Create the users table with authentication fields.",
  "estimatedEffort": "1-2 hours",
  "tasks": [
    {
      "id": "task-1-1",
      "title": "Create audit backup table",
      "description": "Create migration to backup existing data before schema changes",
      "file": "prisma/migrations/[timestamp]_backup/migration.sql",
      "status": "pending"
    },
    {
      "id": "task-1-2",
      "title": "Create migration to add users table",
      "description": "Create Prisma migration to add users table with id, email, password_hash columns",
      "file": "prisma/migrations/[timestamp]_add_users/migration.sql",
      "status": "pending"
    },
    {
      "id": "task-1-3",
      "title": "Update Prisma schema",
      "description": "Add User model to schema.prisma with email unique constraint",
      "file": "prisma/schema.prisma",
      "status": "pending"
    }
  ]
}
```

## Acceptance Criteria Categorization

### Functional
Requirements about what the feature does:
- "Users can register with email and password"
- "Invalid credentials show error message"
- "API returns 404 for removed endpoint"

### Non-Functional
Quality attributes:
- "No TypeScript compilation errors"
- "Response time < 500ms"
- "Password hashed with bcrypt"

### Quality Gates
Commands/checks that must pass:
- "bun run lint passes"
- "bun run test passes"
- "Manual E2E test of flow"

## Output File Structure

Write to `docs/tasks/tasks.json`:

```json
{
  "schemaVersion": "2.0",
  "metadata": {
    "title": "refactor: Remove state field",
    "type": "refactor",
    "createdAt": "2026-02-16",
    "planPath": "docs/plans/2026-02-16-refactor-plan.md"
  },
  "stories": [
    // converted stories with tasks
  ],
  "acceptanceCriteria": {
    "functional": [...],
    "nonFunctional": [...],
    "qualityGates": [...]
  },
  "deploymentOrder": [
    "Phase 0: Deploy backend with optional fields",
    "Phase 1-5: Deploy backend changes",
    "Verify: Test API endpoints",
    "Phase 6-9: Deploy frontend changes"
  ],
  "successMetrics": {
    "apiCalls": "2 → 1",
    "linesRemoved": "~225"
  }
}
```

## Validation

Before writing, validate:

1. `schemaVersion` is "2.0"
2. `metadata` has all required fields
3. At least one story exists
4. Each story has at least one task
5. All task IDs are unique
6. All file paths are relative (no absolute paths, no `..`)
7. `acceptanceCriteria` has all three arrays
8. `deploymentOrder` has at least one item

## Error Handling

If plan file cannot be parsed:
```
Error: Could not parse plan file. Expected markdown with "## Phase" or "### Phase" headings.
```

If no phases found:
```
Error: No implementation phases found in plan. Expected sections like "### Phase 1: ..."
```
