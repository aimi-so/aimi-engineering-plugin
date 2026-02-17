# Story Execution Rules

## Overview

Each story is executed by a Task-spawned agent with fresh context. This document defines the execution flow, quality gates, and output formats for the v2.0 schema.

## Schema Overview (v2.0)

Stories include task-specific guidance fields:

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

## The Number One Rule

**Each story must be completable in ONE iteration (one context window).**

You spawn fresh with no memory of previous work. If the story is too big, you'll run out of context before finishing.

## Execution Flow

### Step 1: Read Project Guidelines

**FIRST**, check for project-specific guidelines:

1. **CLAUDE.md** (project root) - Primary project instructions
2. **AGENTS.md** (directory-specific) - Module-specific patterns
3. **Aimi defaults** - Standard conventions if neither exists

### Step 2: Review Task Guidance

Check the task-specific fields for domain context:

- **`taskType`**: Domain classification (e.g., "prisma_schema", "react_component")
  - Helps understand the type of work being done
- **`steps`**: Concrete execution steps (follow in order)
  - The first step is always "Read CLAUDE.md and AGENTS.md for project conventions"
  - Each step provides specific guidance for this task type
- **`relevantFiles`**: Files to read first before implementing
  - Start by reading these to understand current state
- **`qualityChecks`**: Quality gates that must pass before commit
  - Run ALL of these commands before committing

### Step 3: Follow Execution Steps

**Execute the steps in order from `story.steps` array.**

The steps are pre-generated based on the task type and provide domain-specific guidance. Example for `prisma_schema`:

1. Read CLAUDE.md and AGENTS.md for project conventions
2. Read prisma/schema.prisma to understand existing models
3. Add/modify the model or field
4. Run: npx prisma generate
5. Run: npx prisma migrate dev --name [descriptive-name]
6. Verify typecheck passes

### Step 4: Verify Acceptance Criteria

After following the steps, verify ALL acceptance criteria are met:

- Check each criterion explicitly
- For UI stories, verify in browser
- For logic stories, run tests

### Step 5: Run Quality Checks

Run ALL commands from `story.qualityChecks`:

```bash
# Example for prisma_schema
npx tsc --noEmit

# Example for server_action
npx tsc --noEmit
npm test
```

### Step 6: Quality Gate (FAIL FAST)

**If any quality check or acceptance criterion fails, STOP immediately.**

Do NOT:
- Continue with partial implementation
- Try to hack around failures
- Skip failing checks

Instead:
- Report the failure with full error details
- Include relevant file paths and line numbers
- Suggest potential fixes if obvious

### Step 7: Commit Changes

If all checks pass, commit with this format:

```bash
git add [changed files]
git commit -m "feat: US-001 - Add status field to tasks table"
```

Commit message format:
- `feat:` for feature work
- `fix:` for bug fixes
- `refactor:` for refactoring
- `[story-id]` from the story
- Title from story title

### Step 8: Update tasks.json

Update the story to mark it complete:

```bash
jq '(.userStories[] | select(.id == "US-001")) |= . + {passes: true}' docs/tasks/tasks.json > tmp.json && mv tmp.json docs/tasks/tasks.json
```

### Step 9: Update AGENTS.md or CLAUDE.md (if learnings)

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

If you cannot complete a story:

1. **Do NOT** mark `passes: true`
2. **Update tasks.json** with failure details:

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
   - Suggested fix if known

## Status Values

| Field | Value | Meaning |
|-------|-------|---------|
| `passes` | `false` | Not completed yet |
| `passes` | `true` | Completed successfully |
| `skipped` | `true` | Skipped by user (won't retry) |

## Task Types Reference

| taskType | Description | Typical qualityChecks |
|----------|-------------|----------------------|
| `prisma_schema` | Database schema/migration | `npx tsc --noEmit` |
| `server_action` | Server-side logic | `npx tsc --noEmit`, `npm test` |
| `react_component` | React/UI components | `npx tsc --noEmit` |
| `api_route` | API endpoints | `npx tsc --noEmit`, `npm test` |
| `utility` | Helper functions | `npx tsc --noEmit`, `npm test` |
| `test` | Test implementation | `npm test` |
| `other` | Generic tasks | `npx tsc --noEmit` |

## Quality Gates Reference

Common quality checks by task type:

| Gate | Command | When Used |
|------|---------|-----------|
| Typecheck | `npx tsc --noEmit` | All TypeScript tasks |
| Lint | `bun run lint`, `npm run lint` | Code style enforcement |
| Test | `bun run test`, `npm test` | Backend logic, utilities |
| Build | `bun run build`, `npm run build` | Production readiness |
| Browser | Manual verification | UI changes |

## Success Metrics

The root `successMetrics` object tracks improvements:

```json
{
  "successMetrics": {
    "apiCalls": "2 → 1",
    "saveTime": "~400ms → ~200ms"
  }
}
```

These are informational - verify them where possible during implementation.
