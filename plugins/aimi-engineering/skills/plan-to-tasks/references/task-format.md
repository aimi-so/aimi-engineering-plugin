# tasks.json Format Reference

## Overview

The `tasks.json` file is the structured task list that drives autonomous execution. Each story represents a phase of work, containing granular tasks that can be executed sequentially.

## Schema

```json
{
  "schemaVersion": "2.0",
  "metadata": {
    "title": "string",
    "type": "feature|refactor|bugfix|chore",
    "createdAt": "YYYY-MM-DD",
    "planPath": "string",
    "brainstormPath": "string (optional)"
  },
  "stories": [Story],
  "acceptanceCriteria": {
    "functional": ["string"],
    "nonFunctional": ["string"],
    "qualityGates": ["string"]
  },
  "deploymentOrder": ["string"],
  "successMetrics": {
    "key": "value"
  }
}
```

## Field Definitions

### Root Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schemaVersion` | string | Yes | Schema version, always "2.0" |
| `metadata` | object | Yes | Project metadata |
| `stories` | array | Yes | Array of Story objects (phases) |
| `acceptanceCriteria` | object | Yes | Categorized acceptance criteria |
| `deploymentOrder` | array | Yes | Ordered deployment steps |
| `successMetrics` | object | No | Key metrics to track |

### Metadata Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `title` | string | Yes | Plan title (e.g., "feat: Add user authentication") |
| `type` | string | Yes | One of: `feature`, `refactor`, `bugfix`, `chore` |
| `createdAt` | string | Yes | Creation date (YYYY-MM-DD) |
| `planPath` | string | Yes | Path to source plan markdown file |
| `brainstormPath` | string | No | Path to brainstorm file if exists |

### Story Fields

Each story represents a phase of implementation.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique identifier (e.g., `story-0`, `story-1`) |
| `title` | string | Yes | Phase title (e.g., "Phase 1: Database Schema") |
| `description` | string | Yes | Brief description of the phase |
| `estimatedEffort` | string | Yes | Time estimate (e.g., "1-2 hours", "30 minutes") |
| `tasks` | array | Yes | Array of Task objects |

### Task Fields

Each task is a granular unit of work within a story.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique identifier (e.g., `task-1-1`, `task-1-2`) |
| `title` | string | Yes | Short task title |
| `description` | string | Yes | Detailed description of what to do |
| `file` | string | Yes | Target file path (relative to project root) |
| `action` | string | No | Special action: `delete`, `create`, `modify` (default: modify) |
| `status` | string | Yes | One of: `pending`, `in_progress`, `completed`, `skipped` |

### Acceptance Criteria Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `functional` | array | Yes | Functional requirements that must be met |
| `nonFunctional` | array | Yes | Performance, security, quality requirements |
| `qualityGates` | array | Yes | Commands/checks that must pass |

## Task ID Convention

Task IDs follow the pattern: `task-{story-index}-{task-index}`

- `task-0-1`: Story 0, Task 1
- `task-1-3`: Story 1, Task 3
- `task-10-2`: Story 10, Task 2

## Story Ordering

Stories should be ordered by dependency:

1. **Phase 0**: Rolling deploy safety / backward compatibility
2. **Phase 1-N**: Backend changes (schema → domain → controllers)
3. **Phase N+1**: Frontend changes (types → API → components)
4. **Final phases**: Migrations, cleanup, documentation

## Path Validation (Security)

All file paths must be validated:

1. **No parent directory traversal**: Reject paths containing `..`
2. **No absolute paths**: Reject paths starting with `/`
3. **No protocol prefixes**: Reject paths containing `://`
4. **Relative paths only**: Must be relative to project root

## Complete Example

```json
{
  "schemaVersion": "2.0",
  "metadata": {
    "title": "feat: Add user authentication",
    "type": "feature",
    "createdAt": "2026-02-16",
    "planPath": "docs/plans/2026-02-16-feat-user-auth-plan.md",
    "brainstormPath": "docs/brainstorms/2026-02-16-user-auth-brainstorm.md"
  },
  "stories": [
    {
      "id": "story-0",
      "title": "Phase 0: Backend Preparation",
      "description": "Make fields optional for rolling deploy compatibility.",
      "estimatedEffort": "30 minutes",
      "tasks": [
        {
          "id": "task-0-1",
          "title": "Make email field optional in validation",
          "description": "Update UserBodySchema to make email field optional for backward compatibility",
          "file": "src/controllers/user/user.presentation.ts",
          "status": "pending"
        }
      ]
    },
    {
      "id": "story-1",
      "title": "Phase 1: Database Schema",
      "description": "Add users table with authentication fields.",
      "estimatedEffort": "1-2 hours",
      "tasks": [
        {
          "id": "task-1-1",
          "title": "Create users table migration",
          "description": "Create Prisma migration to add users table with id, email, password_hash, created_at columns",
          "file": "prisma/migrations/[timestamp]_add_users/migration.sql",
          "status": "pending"
        },
        {
          "id": "task-1-2",
          "title": "Update Prisma schema",
          "description": "Add User model to schema.prisma with email unique constraint",
          "file": "prisma/schema.prisma",
          "status": "pending"
        }
      ]
    },
    {
      "id": "story-2",
      "title": "Phase 2: Frontend Components",
      "description": "Create login and registration UI components.",
      "estimatedEffort": "2-3 hours",
      "tasks": [
        {
          "id": "task-2-1",
          "title": "Create LoginForm component",
          "description": "Create LoginForm with email/password inputs, validation, and submit handling",
          "file": "src/components/auth/LoginForm.tsx",
          "status": "pending"
        },
        {
          "id": "task-2-2",
          "title": "Delete legacy auth component",
          "description": "Remove the deprecated OldAuthForm component",
          "file": "src/components/auth/OldAuthForm.tsx",
          "action": "delete",
          "status": "pending"
        }
      ]
    }
  ],
  "acceptanceCriteria": {
    "functional": [
      "Users can register with email and password",
      "Users can login with valid credentials",
      "Invalid credentials show error message"
    ],
    "nonFunctional": [
      "Password hashed with bcrypt cost factor 12",
      "Login completes in < 500ms",
      "No TypeScript compilation errors"
    ],
    "qualityGates": [
      "bun run lint passes",
      "bun run test passes",
      "Manual E2E test of login flow"
    ]
  },
  "deploymentOrder": [
    "Phase 0: Deploy backend with optional fields",
    "Phase 1: Run database migrations",
    "Verify: Test API endpoints",
    "Phase 2: Deploy frontend changes",
    "Verify: Complete E2E test"
  ],
  "successMetrics": {
    "registrationTime": "< 2 seconds",
    "loginTime": "< 500ms",
    "testCoverage": "> 80%"
  }
}
```

## Status Transitions

Tasks follow this state machine:

```
pending → in_progress → completed
                     → skipped (if blocked or not applicable)
```

## Effort Estimation Guidelines

| Estimate | Typical Scope |
|----------|---------------|
| "15 minutes" | Single file, small change |
| "30 minutes" | 1-3 files, straightforward |
| "1 hour" | Multiple files, some complexity |
| "1-2 hours" | Significant changes, multiple components |
| "2-3 hours" | Complex feature, many files |
| "3+ hours" | Consider splitting into multiple stories |

## Validation Rules

### Required Fields Check

Before processing, validate:

1. `schemaVersion` must be "2.0"
2. `metadata.title` must be non-empty
3. `metadata.type` must be one of: feature, refactor, bugfix, chore
4. `stories` must have at least one item
5. Each story must have at least one task
6. Each task must have `id`, `title`, `description`, `file`, `status`
7. `acceptanceCriteria` must have all three arrays (can be empty)
8. `deploymentOrder` must have at least one item

### Validation Error Format

```
Error: Invalid tasks.json - [field] is missing or invalid.
Fix: [specific action to fix]
```
