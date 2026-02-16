# Story Execution Rules

## Overview

Each story is executed by a Task-spawned agent with fresh context. This document defines the execution flow, quality gates, and output formats.

## Execution Flow

### Step 1: Read Project Guidelines

**FIRST**, check for project-specific guidelines in this order:

1. **CLAUDE.md** (project root) - Primary project instructions
2. **AGENTS.md** (directory-specific) - Module-specific patterns and gotchas
3. **Aimi defaults** - If neither exists, follow standard conventions

These files contain:
- Project conventions and patterns
- Commit and PR rules
- Known gotchas to avoid
- Module-specific guidance

### Step 2: Read Story Details

Your story data is provided inline in the prompt.

Understand:
- Title and description
- All acceptance criteria
- Task-specific steps to follow

### Step 3: Implement the Story

Follow acceptance criteria exactly:
- Read existing code to understand patterns
- Implement the required changes
- Write tests if required by criteria

### Step 4: Run Quality Checks

Run ALL quality checks required by the project:

```bash
# Typecheck (required for all code changes)
# Examples: tsc, bun check, npx tsc --noEmit

# Linting
# Examples: eslint, rubocop, ruff

# Tests
# Examples: bun test, npm test, pytest, bin/rails test
```

### Step 5: Quality Gate

**FAIL FAST:** If any quality check fails, STOP immediately.

Do NOT:
- Continue with partial implementation
- Mark the story as passed
- Try to hack around failures

Instead:
- Report the failure with full error details
- Include relevant file paths and line numbers
- Suggest potential fixes if obvious

### Step 6: Commit Changes

If all checks pass, commit with this format:

```bash
git add [changed files]
git commit -m "feat: [US-XXX] - [Story title]"
```

Examples:
- `feat: [US-001] - Add users database schema`
- `feat: [US-002] - Add password hashing utility`
- `fix: [US-005] - Fix login redirect`

### Step 7: Update tasks.json

Read `docs/tasks/tasks.json`, update your story:

```json
{
  "id": "US-XXX",
  "passes": true,
  "notes": "Completed successfully. [brief notes]",
  "attempts": 1,
  "lastAttempt": "2026-02-15T10:45:00Z"
}
```

Write the updated file.

### Step 8: Update AGENTS.md or CLAUDE.md with Learnings

Before committing, check if any edited files have learnings worth preserving in nearby AGENTS.md files:

1. **Identify directories with edited files** - Look at which directories you modified
2. **Check for existing AGENTS.md** - Look for AGENTS.md in those directories or parent directories
3. **Add valuable learnings** - If you discovered something future developers/agents should know:
   - API patterns or conventions specific to that module
   - Gotchas or non-obvious requirements
   - Dependencies between files
   - Testing approaches for that area
   - Configuration or environment requirements

**Examples of good AGENTS.md additions:**
- "When modifying X, also update Y to keep them in sync"
- "This module uses pattern Z for all API calls"
- "Tests require the dev server running on PORT 3000"
- "Field names must match the template exactly"

**Do NOT add to AGENTS.md or CLAUDE.md:**
- Story-specific implementation details
- Temporary debugging notes
- Redundant information already documented

Only update these files if you have **genuinely reusable knowledge** that would help future work.

**Where to add learnings:**
- **CLAUDE.md** (root) - Project-wide patterns, conventions, and setup instructions
- **AGENTS.md** (directory) - Module-specific patterns and gotchas

## Failure Handling

If you fail to complete a story:

1. **Do NOT** mark `passes: true`
2. **Update** tasks.json with structured error:
   ```json
   {
     "passes": false,
     "notes": "Failed: [brief summary]",
     "attempts": [increment],
     "lastAttempt": "[timestamp]",
     "error": {
       "type": "typecheck_failure|test_failure|lint_failure|runtime_error|dependency_missing|unknown",
       "message": "Detailed error message from the failure",
       "file": "path/to/file.ts (if applicable)",
       "line": 42,
       "suggestion": "Possible fix or next step (if known)"
     }
   }
   ```
   
   **Error type classification:**
   - `typecheck_failure`: TypeScript/type errors (tsc failed)
   - `test_failure`: Unit/integration tests failed
   - `lint_failure`: ESLint/Prettier violations
   - `runtime_error`: Execution errors
   - `dependency_missing`: npm/pip/gem package not found
   - `unknown`: Cannot classify
3. **Return** with clear failure report including:
   - What went wrong
   - Error messages
   - Files involved
   - Suggested fix if known
