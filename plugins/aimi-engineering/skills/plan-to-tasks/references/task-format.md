# tasks.json Format Reference

## Overview

The `tasks.json` file is the structured task list that drives autonomous execution. Each user story represents a unit of work completable in a single agent context window.

**Key Feature:** Each story includes **task-specific step instructions** generated at plan-to-tasks time, replacing the generic execution flow with domain-aware guidance.

## Schema Validation

**CRITICAL:** Before processing tasks.json, validate the structure:

### Required Root Fields
- `schemaVersion` (string, must be "2.0" for task-specific steps)
- `project` (string, non-empty)
- `branchName` (string, matches `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$`)
- `description` (string, non-empty)
- `userStories` (array, at least one item)

### Required UserStory Fields
- `id` (string, matches `^US-\d{3}$`)
- `title` (string, non-empty, max 200 chars)
- `description` (string, non-empty, max 500 chars)
- `acceptanceCriteria` (array of strings, at least one item, each max 300 chars)
- `priority` (number, positive integer)
- `passes` (boolean)
- `taskType` (string, snake_case, max 50 chars)
- `steps` (array of strings, min 1, max 10 items, each max 500 chars)
- `relevantFiles` (array of strings, max 20 items, valid relative paths - see Path Validation)
- `patternsToFollow` (string, file path or "none" - see Path Validation)
- `qualityChecks` (array of strings, 1-5 items, shell commands for verification)

### Path Validation (Security)

**CRITICAL:** All file paths must be validated to prevent path traversal attacks.

#### Validation Rules

1. **No parent directory traversal**: Reject paths containing `..`
2. **No absolute paths**: Reject paths starting with `/`
3. **No protocol prefixes**: Reject paths containing `://` or starting with `file:`
4. **No null bytes**: Reject paths containing `\x00` or `%00`
5. **Normalized paths only**: After normalization, path must remain within project root
6. **No hidden system files**: Reject paths to `.git/`, `.env`, `.ssh/`, etc.

#### Blocked Path Patterns

```regex
# Path traversal
\.\./
\.\.\\

# Absolute paths
^/
^[A-Za-z]:\\

# Protocol prefixes
://
^file:

# Null bytes
\x00
%00

# System/sensitive paths
^\.git/
^\.env
^\.ssh/
/\.git/
/\.env
/\.ssh/
```

#### Validation Function (Pseudocode)

```python
def validate_path(path: str) -> bool:
    # Reject empty paths
    if not path or path.strip() == "":
        return False
    
    # Block dangerous patterns
    blocked_patterns = [
        r"\.\./",           # Parent traversal (unix)
        r"\.\.\\",          # Parent traversal (windows)
        r"^/",              # Absolute path (unix)
        r"^[A-Za-z]:\\",    # Absolute path (windows)
        r"://",             # Protocol prefix
        r"^file:",          # File protocol
        r"\x00",            # Null byte
        r"%00",             # URL-encoded null
        r"^\.git/",         # Git directory
        r"^\.env",          # Environment files
        r"^\.ssh/",         # SSH directory
        r"/\.git/",         # Nested git
        r"/\.env",          # Nested env
        r"/\.ssh/",         # Nested ssh
    ]
    
    for pattern in blocked_patterns:
        if re.search(pattern, path, re.IGNORECASE):
            return False
    
    # Additional: normalize and verify still relative
    normalized = os.path.normpath(path)
    if normalized.startswith("..") or os.path.isabs(normalized):
        return False
    
    return True
```

#### Validation Error Messages

| Error | Message |
|-------|---------|
| Path traversal | `Error: Story [ID] path "[path]" contains path traversal. Remove ".." sequences.` |
| Absolute path | `Error: Story [ID] path "[path]" is absolute. Use relative paths only.` |
| Protocol prefix | `Error: Story [ID] path "[path]" contains protocol. Use local paths only.` |
| Sensitive path | `Error: Story [ID] path "[path]" accesses sensitive location. Remove system paths.` |
| Invalid format | `Error: Story [ID] path "[path]" has invalid format. Use standard relative paths.` |

### Validation Errors

If validation fails, report the specific error:
```
Error: Invalid tasks.json - [field] is missing or invalid.
Please run /aimi:plan to regenerate tasks.json.
```

**Validation Error Messages:**

All errors follow a consistent format:
```
Error: Story [ID] - [field]: [issue]. Fix: [action].
```

| Category | Example |
|----------|---------|
| Missing field | `Error: Story US-001 - taskType: missing. Fix: run /aimi:plan-to-tasks` |
| Invalid value | `Error: Story US-001 - taskType: invalid (got "Bad Value"). Fix: use snake_case` |
| Length exceeded | `Error: Story US-001 - steps[2]: too long (520/500 chars). Fix: shorten step` |
| Count exceeded | `Error: Story US-001 - steps: too many (12/10). Fix: split story` |
| Security violation | `Error: Story US-001 - relevantFiles[0]: path traversal detected. Fix: remove ".."` |

Do NOT proceed with invalid tasks.json.

## Schema

```json
{
  "schemaVersion": "2.0",
  "project": "string",
  "branchName": "string",
  "description": "string",
  "createdFrom": "string",
  "createdAt": "ISO 8601 timestamp",
  "deepenedAt": "ISO 8601 timestamp (optional)",
  "userStories": [UserStory]
}
```

### Schema Versioning

The `schemaVersion` field tracks the tasks.json format version for compatibility.

| Version | Changes |
|---------|---------|
| `1.0` | Initial schema (implicit if field missing) |
| `2.0` | Added required fields: `taskType`, `steps`, `relevantFiles`, `patternsToFollow` |

**Version Validation:**

```python
CURRENT_SCHEMA_VERSION = "2.0"
SUPPORTED_VERSIONS = ["1.0", "2.0"]

def validate_schema_version(tasks_json: dict) -> tuple[bool, str]:
    version = tasks_json.get("schemaVersion", "1.0")
    
    if version not in SUPPORTED_VERSIONS:
        return False, f"Unknown schema version: {version}. Supported: {SUPPORTED_VERSIONS}"
    
    if version == "1.0":
        # Warn about missing task-specific fields
        return True, "Warning: Schema v1.0 detected. Run /aimi:plan-to-tasks to upgrade to v2.0 with task-specific steps."
    
    return True, ""
```

**Migration from v1.0 to v2.0:**

If `schemaVersion` is missing or "1.0", the executor should:
1. Log a warning about missing task-specific fields
2. Fall back to generic execution flow (legacy behavior)
3. Suggest running `/aimi:plan-to-tasks` to regenerate with v2.0 schema

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
| `title` | string | Yes | Short descriptive title (max 200 chars) |
| `description` | string | Yes | User story format: "As a [role], I need [feature]" (max 500 chars) |
| `acceptanceCriteria` | array | Yes | List of verifiable criteria (each max 300 chars) |
| `priority` | number | Yes | Execution order (1 = first) |
| `passes` | boolean | Yes | Whether story passes (complete) |
| `notes` | string | Yes | Execution notes or learnings |
| `attempts` | number | Yes | Number of execution attempts |
| `lastAttempt` | string | No | ISO 8601 timestamp of last attempt |
| `skipped` | boolean | No | If true, story is skipped (excluded from execution loop) |
| `error` | object | No | Structured error details (see Error Schema) |
| `taskType` | string | Yes | Domain-aware task classification (snake_case, max 50 chars) |
| `steps` | array | Yes | Task-specific execution steps (1-10 items, each max 500 chars) |
| `relevantFiles` | array | Yes | Files to read first (max 20 items, relative paths) |
| `patternsToFollow` | string | Yes | AGENTS.md path or "none" |
| `qualityChecks` | array | Yes | Commands to verify acceptance criteria |

### qualityChecks Field

The `qualityChecks` array specifies commands to run for verification.

**Purpose:** Makes quality verification explicit and executable, not implicit.

**Format:**
```json
{
  "qualityChecks": [
    "npx tsc --noEmit",
    "npm test -- --testPathPattern=users",
    "npm run lint"
  ]
}
```

**Guidelines:**
- Include typecheck command if code changes are involved
- Include specific test commands (scoped to affected files)
- Include lint commands if project uses linting
- Order: typecheck → test → lint (fail fast on type errors)
- Maximum 5 commands per story

**Common Quality Checks:**

| Check Type | Example Command |
|------------|-----------------|
| TypeScript typecheck | `npx tsc --noEmit` |
| Jest tests (scoped) | `npm test -- --testPathPattern=<pattern>` |
| Vitest tests (scoped) | `npx vitest run <pattern>` |
| ESLint | `npm run lint` |
| Prettier check | `npx prettier --check src/` |
| Prisma generate | `npx prisma generate` |
| Build verification | `npm run build` |

**Validation:**
- Array must have at least 1 item
- Each command must be a non-empty string
- Maximum 5 commands
- Commands must not contain shell injection patterns (see security rules)

### Task-Specific Fields (New)

#### taskType

Domain-aware classification of the task. Generated by matching story content against the pattern library or inferred by LLM.

**Format:** snake_case string, max 50 characters

**Examples:**
- `prisma_schema` - Database schema changes
- `server_action` - Next.js server actions
- `react_component` - React component creation
- `api_route` - API endpoint implementation
- `documentation` - Documentation updates
- `test_implementation` - Test file creation
- `refactor` - Code refactoring

#### steps

Task-specific execution instructions. Generated from pattern library templates or LLM inference.

**Constraints:**
- Minimum: 1 step
- Maximum: 10 steps
- Each step: max 500 characters

**Guidelines:**
- Steps should be actionable and specific
- Include tool commands where appropriate (e.g., "Run: npx prisma generate")
- Order steps sequentially
- Final step should verify the work (typecheck, test, etc.)

#### relevantFiles

Files the agent should read before implementing. Helps agent understand context quickly.

**Constraints:**
- Maximum: 20 files
- Must be valid relative paths from project root
- Can be empty array if no specific files needed

**Guidelines:**
- Include files that will be modified
- Include files with patterns to follow
- Include configuration files if relevant

#### patternsToFollow

Reference to AGENTS.md file or pattern documentation.

**Format:** Relative file path or "none"

**Examples:**
- `prisma/AGENTS.md`
- `src/components/AGENTS.md`
- `docs/patterns/react-component.md`
- `none`

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
      "lastAttempt": null,
      "taskType": "prisma_schema",
      "steps": [
        "Read prisma/schema.prisma to understand existing models and relations",
        "Add User model with fields: id, email, passwordHash, createdAt",
        "Add unique constraint on email field",
        "Run: npx prisma generate",
        "Run: npx prisma migrate dev --name add-users-table",
        "Verify typecheck passes with: npx tsc --noEmit"
      ],
      "relevantFiles": [
        "prisma/schema.prisma",
        "src/lib/db.ts"
      ],
      "patternsToFollow": "prisma/AGENTS.md"
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
      "lastAttempt": null,
      "taskType": "server_action",
      "steps": [
        "Read existing utility files in src/lib/ to understand patterns",
        "Create src/lib/password.ts with hashPassword and verifyPassword functions",
        "Use bcrypt with cost factor 12 for hashing",
        "Add input validation for password length",
        "Create src/lib/password.test.ts with unit tests",
        "Run: npm test to verify tests pass",
        "Verify typecheck passes"
      ],
      "relevantFiles": [
        "src/lib/",
        "package.json"
      ],
      "patternsToFollow": "src/AGENTS.md"
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
      "lastAttempt": null,
      "taskType": "react_component",
      "steps": [
        "Read existing form components in src/components/ to understand patterns",
        "Create src/components/RegisterForm.tsx with email and password inputs",
        "Add client-side validation for email format and password length",
        "Connect form to registration server action",
        "Handle success redirect to /login",
        "Handle and display error messages",
        "Verify typecheck passes"
      ],
      "relevantFiles": [
        "src/components/",
        "src/app/register/page.tsx"
      ],
      "patternsToFollow": "src/components/AGENTS.md"
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
