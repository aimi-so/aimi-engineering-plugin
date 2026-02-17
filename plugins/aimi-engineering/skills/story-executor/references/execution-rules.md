# Story Execution Rules

## Overview

Each story is executed by a Task-spawned agent with fresh context. This document defines the execution flow, quality gates, and output formats for the v3.0 schema.

## Schema Overview (v3.0)

Stories are flat, atomic units of work:

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

## The Number One Rule

**Each story must be completable in ONE iteration (one context window).**

You spawn fresh with no memory of previous work. If the story is too big, you'll run out of context before finishing.

## Execution Flow

### Step 1: Read Project Guidelines

**FIRST**, check for project-specific guidelines:

1. **CLAUDE.md** (project root) - Primary project instructions
2. **AGENTS.md** (directory-specific) - Module-specific patterns
3. **Aimi defaults** - Standard conventions if neither exists

### Step 2: Understand Story Scope

Read the story details:
- Title and description
- All acceptance criteria
- Infer which files need modification

### Step 3: Implement the Change

1. **Read relevant files** to understand current state
2. **Make the necessary changes** to satisfy acceptance criteria
3. **Verify each criterion** as you go

### Step 4: Run Quality Checks

After implementation, run quality checks:

```bash
# Standard quality checks
bun run lint      # or npm run lint
bun run test      # or npm test  
npx tsc --noEmit  # typecheck
```

Then verify ALL acceptance criteria are met.

### Step 5: Quality Gate (FAIL FAST)

**If any quality check or acceptance criterion fails, STOP immediately.**

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
git commit -m "feat: US-001 - Add status field to tasks table"
```

Commit message format:
- `feat:` for feature work
- `fix:` for bug fixes
- `refactor:` for refactoring
- `[story-id]` from the story
- Title from story title

### Step 7: Update tasks.json

Update the story to mark it complete:

```bash
jq '(.userStories[] | select(.id == "US-001")) |= . + {passes: true}' docs/tasks/tasks.json > tmp.json && mv tmp.json docs/tasks/tasks.json
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

## Quality Gates Reference

Common quality checks to run:

| Gate | Command |
|------|---------|
| Lint | `bun run lint`, `npm run lint` |
| Test | `bun run test`, `npm test` |
| Typecheck | `npx tsc --noEmit`, `bun check` |
| Build | `bun run build`, `npm run build` |
| Browser | Manual verification for UI changes |

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
