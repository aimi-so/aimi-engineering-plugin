# Aimi Engineering Plugin

Autonomous task execution for Claude Code with structured JSON task management.

Transform implementation plans into executable user stories, then run them one-by-one with full context isolation. Each story gets its own agent with task-specific steps, quality checks, and automatic state tracking.

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Commands](#commands)
- [Workflow](#workflow)
- [Task Schema](#task-schema)
- [Pattern Library](#pattern-library)
- [Architecture](#architecture)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [Version History](#version-history)

## Installation

### Prerequisites

This plugin requires **compound-engineering-plugin** to be installed first.

### Install Steps

```bash
# 1. Install compound-engineering plugin
claude /plugin marketplace add https://github.com/EveryInc/compound-engineering-plugin
claude /plugin install compound-engineering

# 2. Install aimi-engineering plugin
claude /plugin marketplace add https://github.com/aimi-so/aimi-engineering-plugin
claude /plugin install aimi-engineering
```

### Verify Installation

```bash
# Check both plugins are installed
claude /plugin list

# Test aimi commands are available
/aimi:status
```

## Quick Start

```bash
# 1. Brainstorm your feature
/aimi:brainstorm Add user authentication with email/password

# 2. Create plan and generate tasks
/aimi:plan Add user authentication

# 3. Execute all stories autonomously
/aimi:execute

# 4. Review the implementation
/aimi:review
```

## Commands

| Command | Description | Usage |
|---------|-------------|-------|
| `/aimi:brainstorm` | Explore ideas through guided brainstorming | `/aimi:brainstorm [feature]` |
| `/aimi:plan` | Create implementation plan and convert to tasks.json | `/aimi:plan [feature]` |
| `/aimi:deepen` | Enhance plan with research and update tasks.json | `/aimi:deepen [plan-path]` |
| `/aimi:status` | Show current task execution progress | `/aimi:status` |
| `/aimi:next` | Execute the next pending story | `/aimi:next` |
| `/aimi:execute` | Run all stories autonomously in a loop | `/aimi:execute` |
| `/aimi:review` | Code review using compound-engineering | `/aimi:review` |

### Command Details

#### `/aimi:brainstorm`

Wraps compound-engineering's brainstorm workflow. Explores requirements and approaches interactively before committing to implementation.

```bash
/aimi:brainstorm Add social login with Google and GitHub
```

#### `/aimi:plan`

Two-phase command that:
1. Runs compound-engineering's `/workflows:plan` to generate a markdown plan
2. Automatically converts the plan to `docs/tasks/tasks.json`

```bash
/aimi:plan Add user registration flow
```

Output:
- `docs/plans/YYYY-MM-DD-feature-name-plan.md`
- `docs/tasks/tasks.json`

#### `/aimi:deepen`

Enhances an existing plan with research insights while preserving completion state of existing stories.

```bash
/aimi:deepen docs/plans/2026-02-16-user-auth-plan.md
```

#### `/aimi:status`

Displays progress using jq for minimal context usage.

```
Aimi Status: user-auth (feature/user-auth)

Stories: 3/7 complete

✓ US-001: Add database schema          (completed)
✓ US-002: Add password utilities       (completed)
✗ US-003: Add login UI                 (skipped: auth middleware issue)
→ US-004: Add registration UI          (next)
○ US-005: Add session middleware       (pending)
○ US-006: Add logout endpoint          (pending)
○ US-007: Add dashboard                (pending)

Next: US-004 - Add registration UI
```

#### `/aimi:next`

Executes the next pending story. Uses jq to extract only the current story, keeping context clean.

Features:
- Validates required fields before execution
- Auto-retries once on failure
- Asks user to skip/retry/stop on persistent failures

#### `/aimi:execute`

Orchestrates autonomous execution of all pending stories.

Flow:
1. Validates branch name (security)
2. Creates/checkouts feature branch
3. Loops through stories one-at-a-time via `/aimi:next`
4. Handles skip/retry/stop decisions
5. Reports completion with commit count

#### `/aimi:review`

Wraps compound-engineering's review workflow for thorough code review.

```bash
/aimi:review
```

## Workflow

```
/aimi:brainstorm → /aimi:plan → /aimi:deepen (optional) → /aimi:execute → /aimi:review
```

### Workflow Diagram

```
┌─────────────────┐
│  /aimi:brainstorm  │  Explore ideas interactively
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│    /aimi:plan      │  Generate plan + tasks.json
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   /aimi:deepen     │  (Optional) Enhance with research
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   /aimi:execute    │  Run all stories autonomously
│                 │
│  ┌───────────┐  │
│  │ /aimi:next   │  │  One story at a time
│  └───────────┘  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   /aimi:review     │  Code review before merge
└─────────────────┘
```

## Task Schema

All execution state lives in `docs/tasks/tasks.json`. No separate progress file.

### Schema Version 2.0

```json
{
  "schemaVersion": "2.0",
  "project": "user-auth",
  "branchName": "feature/user-auth",
  "description": "Add user authentication with email/password",
  "createdFrom": "docs/plans/2026-02-16-user-auth-plan.md",
  "createdAt": "2026-02-16T10:30:00Z",
  "userStories": [
    {
      "id": "US-001",
      "title": "Add user database schema",
      "description": "As a developer, I need the user table schema",
      "acceptanceCriteria": [
        "Users table has email, password_hash, created_at columns",
        "Email column has unique constraint",
        "Typecheck passes"
      ],
      "priority": 1,
      "passes": false,
      "skipped": false,
      "attempts": 0,
      "notes": "",
      "taskType": "prisma_schema",
      "steps": [
        "Read CLAUDE.md and AGENTS.md for project conventions",
        "Read prisma/schema.prisma to understand existing models",
        "Add User model with id, email, passwordHash, createdAt fields",
        "Add unique constraint on email field",
        "Run: npx prisma generate",
        "Run: npx prisma migrate dev --name add-users-table",
        "Verify typecheck passes"
      ],
      "relevantFiles": ["prisma/schema.prisma", "src/lib/db.ts"],
      "qualityChecks": ["npx tsc --noEmit"]
    }
  ]
}
```

### Field Reference

#### Root Fields

| Field | Type | Description |
|-------|------|-------------|
| `schemaVersion` | string | Schema version (currently "2.0") |
| `project` | string | Project name |
| `branchName` | string | Git branch for this feature |
| `description` | string | Feature description |
| `createdFrom` | string | Path to source plan file |
| `createdAt` | string | ISO 8601 creation timestamp |
| `userStories` | array | List of user stories |

#### Story State Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Story identifier (US-001, US-002, etc.) |
| `title` | string | Short story title |
| `description` | string | User story format description |
| `acceptanceCriteria` | array | Verifiable criteria for completion |
| `priority` | number | Execution order (lower = first) |
| `passes` | boolean | `true` = completed successfully |
| `skipped` | boolean | `true` = skipped by user |
| `attempts` | number | Retry count |
| `notes` | string | Error details or learnings |
| `error` | object | Structured error info (type, message, file, line, suggestion) |

#### Task-Specific Fields

| Field | Type | Description |
|-------|------|-------------|
| `taskType` | string | Domain classification in snake_case (max 50 chars) |
| `steps` | array | Ordered execution steps (1-10 items, each max 500 chars) |
| `relevantFiles` | array | Files to read first (max 20) |
| `patternsToFollow` | string | AGENTS.md path or "none" |
| `qualityChecks` | array | Verification commands |

### Story Sizing

Each story must be completable in ONE agent iteration (one context window).

**Right-sized:**
- Add a database column
- Create a UI component
- Implement a server action
- Add an API endpoint

**Too big (split these):**
- "Build entire dashboard"
- "Add full authentication"
- "Create complete checkout flow"

### Story Ordering

Stories are ordered by dependency:

| Priority | Type | Examples |
|----------|------|----------|
| 1 | Schema/database | Migrations, models |
| 2 | Backend logic | Server actions, services |
| 3 | UI components | Forms, buttons, pages |
| 4 | Aggregation | Dashboards, summaries |

## Pattern Library

The pattern library provides workflow templates for common task types.

### Available Patterns

| Pattern | Task Type | Trigger Files |
|---------|-----------|---------------|
| `prisma-schema.md` | `prisma_schema` | `prisma/schema.prisma`, `*.prisma` |
| `server-action.md` | `server_action` | `src/actions/*`, `app/**/actions.ts` |
| `react-component.md` | `react_component` | `src/components/*`, `*.tsx` |
| `api-route.md` | `api_route` | `app/api/*`, `pages/api/*` |

### How Patterns Work

1. **At plan-to-tasks time:** Each story is analyzed for keywords and file patterns
2. **Pattern matching:** Stories matched against pattern files using combined keyword + file scoring
3. **Step generation:** Matched patterns provide step templates with placeholders
4. **Fallback:** If no pattern matches, LLM inference generates domain-aware steps

### Creating Custom Patterns

Add `.md` files to `docs/patterns/`:

```markdown
---
name: custom_task
keywords: [keyword1, keyword2, keyword3]
filePatterns: ["src/custom/*", "*.custom"]
---

# Custom Task Pattern

## Steps Template

1. Read relevant files to understand context
2. Implement the required changes
3. Run: npm test
4. Verify typecheck passes

## Relevant Files

- src/custom/config.ts
- src/lib/helpers.ts

## Gotchas

- Watch for edge case X
- Always check Y before Z
```

## Architecture

### One Story at a Time

Commands use `jq` to extract only what's needed, keeping context clean:

```bash
# /aimi:execute - metadata only
jq '{project, branchName, pending: [...] | length}' tasks.json

# /aimi:next - ONE story only
jq '[.userStories[] | select(.passes == false and .skipped != true)] 
    | sort_by(.priority) | .[0]' tasks.json
```

### Fresh Context Per Story

Each Task agent starts with clean context:
- No memory carryover between stories
- Full context window available for current story
- Learnings stored in CLAUDE.md/AGENTS.md for persistence

### Project Guidelines Discovery

Agents automatically discover and follow project conventions:

1. **CLAUDE.md** (project root) - Project-wide conventions
2. **AGENTS.md** (per directory) - Module-specific patterns
3. **Aimi defaults** - Fallback commit/PR rules

Small files (< 2KB) are inlined directly in prompts. Larger files are referenced.

### File Structure

```
docs/
├── plans/
│   └── YYYY-MM-DD-feature-name-plan.md
├── tasks/
│   └── tasks.json
└── patterns/
    ├── README.md
    ├── prisma-schema.md
    ├── server-action.md
    ├── react-component.md
    └── api-route.md
```

## Security

### Input Validation

All story content is validated before execution:

**Path traversal prevention:**
- Blocks `..` sequences
- Blocks absolute paths
- Blocks protocol prefixes (`file://`, `http://`)
- Blocks sensitive paths (`.git/`, `.env`, `.ssh/`)

**Command injection prevention:**
- Blocks `&&`, `||`, `;`
- Blocks redirects (`>`, `<`, `>>`)
- Blocks command substitution (`$()`, backticks)
- Blocks pipe operators

**Prompt injection prevention:**
- Blocks instruction override patterns
- Blocks role manipulation
- Blocks system prompt extraction attempts

### Branch Name Validation

Branch names must match:
```regex
^[a-zA-Z0-9][a-zA-Z0-9/_-]*$
```

Invalid characters (spaces, semicolons, quotes) trigger validation errors.

### Field Length Limits

| Field | Max Length |
|-------|------------|
| `title` | 200 chars |
| `description` | 500 chars |
| Each acceptance criterion | 300 chars |
| Each step | 500 chars |
| `taskType` | 50 chars |

## Troubleshooting

### "No tasks.json found"

**Cause:** No task file exists yet.

**Fix:** Run `/aimi:plan [feature]` to create a plan and tasks.

### Story keeps failing

**Cause:** Persistent implementation issues.

**Fix:**
1. Check error details with `/aimi:status`
2. Try `/aimi:next` with a different approach
3. Use "skip" to move past blockers (marks `skipped: true`)

### Infinite loop on failed task

**Cause:** Fixed in v0.5.0.

**Fix:** Update to latest version. Skipped stories are excluded from jq query.

### Missing task-specific fields

**Cause:** tasks.json created before v0.4.0.

**Fix:** Regenerate tasks:
```bash
/aimi:plan-to-tasks docs/plans/your-plan.md
```

### Invalid branch name error

**Cause:** Branch name contains invalid characters.

**Fix:** Edit `branchName` in tasks.json to use only letters, numbers, hyphens, underscores, and forward slashes.

### Story validation failed

**Cause:** Story content contains potentially malicious patterns.

**Fix:** Review tasks.json manually, remove suspicious content, regenerate with `/aimi:plan-to-tasks`.

## Version History

**Current Version:** 2.0.0

### Recent Changes

**v2.0.0** - Task-Specific Field Restoration
- Restored `taskType`, `steps`, `relevantFiles`, `qualityChecks` fields
- Automated field generation via keyword detection (7 task types)
- CLAUDE.md/AGENTS.md enforced as step 1 in all stories
- Schema version set to "2.0"

**v1.0.0** - Ralph-Style Flat Stories
- Flat story structure (no nested tasks array)
- Priority-based execution order
- Project guidelines loading from CLAUDE.md/AGENTS.md

**v0.7.0** - Project Guidelines Injection
- CLAUDE.md/AGENTS.md content injected into Task prompts
- Aimi default commit/PR rules as fallback
- Fresh context per story (no memory carryover)

See [CHANGELOG.md](CHANGELOG.md) for complete version history.

## Components

| Type | Count | Description |
|------|-------|-------------|
| Commands | 7 | Slash commands for workflow stages |
| Skills | 2 | `plan-to-tasks`, `story-executor` |
| Patterns | 4 | Workflow templates for task types |

## License

MIT
