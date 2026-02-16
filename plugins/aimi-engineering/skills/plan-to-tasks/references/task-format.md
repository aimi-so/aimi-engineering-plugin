# tasks.json Format Reference

## Overview

The `tasks.json` file is the structured task list that drives autonomous execution. Each user story represents a unit of work completable in a single agent context window.

## Schema Validation

**CRITICAL:** Before processing tasks.json, validate the structure:

### Required Root Fields
- `project` (string, non-empty)
- `branchName` (string, matches `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$`)
- `description` (string, non-empty)
- `userStories` (array, at least one item)

### Required UserStory Fields
- `id` (string, matches `^US-\d{3}$`)
- `title` (string, non-empty, max 200 chars)
- `description` (string, non-empty, max 500 chars)
- `acceptanceCriteria` (array of strings, at least one item)
- `priority` (number, positive integer)
- `passes` (boolean)

### Validation Errors

If validation fails, report the specific error:
```
Error: Invalid tasks.json - [field] is missing or invalid.
Please run /aimi:plan to regenerate tasks.json.
```

Do NOT proceed with invalid tasks.json.

## Schema

```json
{
  "project": "string",
  "branchName": "string",
  "description": "string",
  "createdFrom": "string",
  "createdAt": "ISO 8601 timestamp",
  "deepenedAt": "ISO 8601 timestamp (optional)",
  "userStories": [UserStory]
}
```

## Field Definitions

### Root Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `project` | string | Yes | Project name (used in progress reports) |
| `branchName` | string | Yes | Git branch for this work (e.g., `feature/user-auth`) |
| `description` | string | Yes | Brief description of the feature/task |
| `createdFrom` | string | Yes | Path to source plan file |
| `createdAt` | string | Yes | ISO 8601 timestamp of creation |
| `deepenedAt` | string | No | ISO 8601 timestamp if plan was deepened |
| `userStories` | array | Yes | Array of UserStory objects |

### UserStory Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique identifier (US-001, US-002, etc.) |
| `title` | string | Yes | Short descriptive title |
| `description` | string | Yes | User story format: "As a [role], I need [feature]" |
| `acceptanceCriteria` | array | Yes | List of verifiable criteria |
| `priority` | number | Yes | Execution order (1 = first) |
| `passes` | boolean | Yes | Whether story passes (complete) |
| `notes` | string | Yes | Execution notes or learnings |
| `attempts` | number | Yes | Number of execution attempts |
| `lastAttempt` | string | No | ISO 8601 timestamp of last attempt |
| `error` | object | No | Structured error details (see Error Schema) |

### Error Schema (for failed stories)

When a story fails, populate the `error` field with structured data:

```json
{
  "error": {
    "type": "typecheck_failure|test_failure|lint_failure|runtime_error|dependency_missing|unknown",
    "message": "Detailed error message",
    "file": "path/to/file.ts (optional)",
    "line": 42,
    "suggestion": "Possible fix or next step (optional)"
  }
}
```

**Error Types:**
| Type | Description |
|------|-------------|
| `typecheck_failure` | TypeScript/type errors |
| `test_failure` | Unit/integration test failures |
| `lint_failure` | ESLint/Prettier/linting errors |
| `runtime_error` | Errors during execution |
| `dependency_missing` | Missing npm/pip/gem packages |
| `unknown` | Unclassified errors |

This structured format enables:
- Programmatic error categorization
- Smart retry decisions (transient vs permanent errors)
- Better error reporting in `/aimi:status`

## Complete Example

```json
{
  "project": "user-authentication",
  "branchName": "feature/user-auth",
  "description": "Add user authentication with login and registration",
  "createdFrom": "docs/plans/2026-02-15-feat-user-auth-plan.md",
  "createdAt": "2026-02-15T10:30:00Z",
  "userStories": [
    {
      "id": "US-001",
      "title": "Add user database schema",
      "description": "As a developer, I need the user table schema for authentication",
      "acceptanceCriteria": [
        "Migration creates users table with email, password_hash, created_at columns",
        "Email column has unique constraint",
        "Typecheck passes"
      ],
      "priority": 1,
      "passes": false,
      "notes": "",
      "attempts": 0,
      "lastAttempt": null
    },
    {
      "id": "US-002",
      "title": "Add password hashing utility",
      "description": "As a developer, I need secure password hashing functions",
      "acceptanceCriteria": [
        "Hash function uses bcrypt with cost factor 12",
        "Verify function compares hash correctly",
        "Typecheck passes",
        "Unit tests pass"
      ],
      "priority": 2,
      "passes": false,
      "notes": "",
      "attempts": 0,
      "lastAttempt": null
    },
    {
      "id": "US-003",
      "title": "Add registration UI",
      "description": "As a user, I want to register with email and password",
      "acceptanceCriteria": [
        "Registration form with email and password fields",
        "Form validates email format and password length",
        "Successful registration redirects to login",
        "Typecheck passes",
        "Verify changes work in browser"
      ],
      "priority": 3,
      "passes": false,
      "notes": "",
      "attempts": 0,
      "lastAttempt": null
    }
  ]
}
```

## Story Sizing Rules

**Critical Rule:** Each story must be completable in ONE Task iteration (one context window).

Task tool spawns fresh context per story. If a story is too big, the agent runs out of context before finishing.

### Right-Sized Stories

- Add a database column and migration
- Add a UI component to an existing page
- Update a server action with new logic
- Add a filter dropdown to a list
- Create a utility function with tests

### Too Big (Split These)

- "Build the entire dashboard" → Split into: schema, queries, UI components, filters
- "Add authentication" → Split into: schema, password utils, login UI, registration UI, session handling
- "Implement search" → Split into: search index setup, search API, search UI, filters

**Rule of thumb:** If you cannot describe the change in 2-3 sentences, it's too big.

## Story Ordering

Stories execute in priority order. Earlier stories must not depend on later ones.

### Correct Order

1. Schema/database changes (migrations)
2. Server actions / backend logic
3. UI components that use the backend
4. Dashboard/summary views that aggregate data

### Wrong Order (Avoid)

1. UI component (depends on schema that doesn't exist yet)
2. Schema change

## Acceptance Criteria Rules

- Must be verifiable (not vague)
- Always include "Typecheck passes" for code changes
- UI stories should include "Verify changes work" or similar
- Include test requirements when applicable

### Good Criteria

- "Migration creates table with columns X, Y, Z"
- "Function returns correct result for edge cases"
- "Form shows validation error for invalid email"
- "Typecheck passes"

### Bad Criteria (Too Vague)

- "Code is clean"
- "Works correctly"
- "User can do the thing"
