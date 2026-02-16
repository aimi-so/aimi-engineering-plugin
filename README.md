# Aimi Engineering Plugin

Autonomous task execution with Ralph-style JSON tasks for Claude Code.

## Prerequisites

**Required:** compound-engineering-plugin must be installed first.

```bash
# Install compound-engineering first
claude /plugin marketplace add https://github.com/EveryInc/compound-engineering-plugin
claude /plugin install compound-engineering

# Then install aimi-engineering
claude /plugin marketplace add https://github.com/aimi-so/aimi-engineering-plugin
claude /plugin install aimi-engineering
```

## Commands

| Command | Description |
|---------|-------------|
| `/aimi:brainstorm` | Explore ideas through guided brainstorming (wraps compound-engineering) |
| `/aimi:plan` | Create implementation plan and convert to tasks.json |
| `/aimi:deepen` | Enhance plan with research and update tasks.json |
| `/aimi:review` | Code review using compound-engineering workflows |
| `/aimi:status` | Show current task execution progress |
| `/aimi:next` | Execute the next pending story |
| `/aimi:execute` | Run all stories autonomously in a loop |

## Workflow

```
/aimi:brainstorm → /aimi:plan → /aimi:deepen → /aimi:execute → /aimi:review
```

1. **Brainstorm**: `/aimi:brainstorm Add user authentication`
   - Explores ideas and requirements interactively
   - Suggests running `/aimi:plan` when ready

2. **Plan**: `/aimi:plan Add user authentication`
   - Runs compound-engineering `/workflows:plan` first
   - Automatically converts plan to `docs/tasks/tasks.json`

3. **Deepen** (optional): `/aimi:deepen docs/plans/[plan].md`
   - Enhances plan with research insights
   - Updates tasks.json while preserving completion state

4. **Execute**: `/aimi:execute`
   - Creates/checkouts feature branch automatically
   - Loops through stories ONE AT A TIME using jq extraction
   - Auto-retries failures, asks user on persistent issues
   - Skipped stories excluded from loop (prevents infinite retry)

5. **Review**: `/aimi:review`
   - Runs compound-engineering code review

## File Structure

```
docs/
├── plans/
│   └── YYYY-MM-DD-feat-name-plan.md   # Implementation plan
└── tasks/
    └── tasks.json                      # Structured task list (single source of truth)
```

## tasks.json Schema (v2.0)

All execution state is stored in `tasks.json`. No separate progress file needed.

```json
{
  "schemaVersion": "2.0",
  "project": "user-auth",
  "branchName": "feature/user-auth",
  "description": "Add user authentication",
  "userStories": [
    {
      "id": "US-001",
      "title": "Add database schema",
      "description": "As a developer, I need the user table schema",
      "acceptanceCriteria": ["...", "Typecheck passes"],
      "priority": 1,
      "passes": false,
      "skipped": false,
      "attempts": 0,
      "notes": "",
      "taskType": "prisma_schema",
      "steps": [
        "Read prisma/schema.prisma to understand existing models",
        "Add User model with required fields",
        "Run: npx prisma generate",
        "Run: npx prisma migrate dev",
        "Verify typecheck passes"
      ],
      "relevantFiles": ["prisma/schema.prisma", "src/lib/db.ts"],
      "patternsToFollow": "prisma/AGENTS.md",
      "qualityChecks": ["npx tsc --noEmit", "npm test"]
    }
  ]
}
```

### Story State Fields

| Field | Type | Description |
|-------|------|-------------|
| `passes` | boolean | `true` = completed successfully |
| `skipped` | boolean | `true` = skipped by user (excluded from execution) |
| `attempts` | number | Retry count |
| `notes` | string | Error details or learnings |
| `error` | object | Structured error (type, message, file, line, suggestion) |

### Task-Specific Fields

| Field | Type | Description |
|-------|------|-------------|
| `taskType` | string | Domain classification (snake_case) |
| `steps` | array | Task-specific execution steps (1-10 items) |
| `relevantFiles` | array | Files to read first (max 20) |
| `patternsToFollow` | string | AGENTS.md path or "none" |
| `qualityChecks` | array | Verification commands (typecheck, test, lint) |

## How It Works

### One Story at a Time

Commands use `jq` to extract only what's needed:

```bash
# /aimi:execute - gets metadata only
jq '{project, branchName, pending: [...] | length}' tasks.json

# /aimi:next - gets ONE story only
jq '[.userStories[] | select(.passes == false and .skipped != true)] | sort_by(.priority) | .[0]' tasks.json
```

This keeps the context window clean - only the current task is loaded.

### Execution Flow

1. **jq extracts** next pending story (lowest priority, not completed, not skipped)
2. **Task agent spawned** with story data inline (no file re-reading)
3. **Agent executes** the task-specific steps
4. **On success**: tasks.json updated via jq (`passes: true`)
5. **On failure**: retry once, then ask user (skip/retry/stop)
6. **If skipped**: `skipped: true` set, story excluded from future loops

### Task-Specific Step Generation

Instead of generic instructions, each story gets **domain-aware steps** generated at plan-to-tasks time.

#### Pattern Library

Workflow templates in `docs/patterns/`:

| Pattern | Task Type | Description |
|---------|-----------|-------------|
| prisma-schema.md | `prisma_schema` | Database schema changes |
| server-action.md | `server_action` | Next.js server actions |
| react-component.md | `react_component` | React components |
| api-route.md | `api_route` | API endpoints |

#### AGENTS.md Discovery

The system discovers AGENTS.md files and matches them to tasks:

```
Story mentions: prisma/schema.prisma
Discovery: prisma/AGENTS.md exists
Result: patternsToFollow = "prisma/AGENTS.md"
```

Small AGENTS.md files (< 2KB) are inlined directly in the prompt.

#### Pattern Matching

1. Extract keywords from story title/description
2. Match against pattern library (keyword + filePatterns)
3. Score: `keyword_matches + (file_pattern_matches * 2)`
4. Tie-breaking: file matches → keyword matches → alphabetical

## Story Sizing

Each story must be completable in ONE Task iteration:

**Right-sized:**
- Add a database column
- Add a UI component
- Update a server action

**Too big (split these):**
- "Build entire dashboard"
- "Add authentication"

## Security

### Input Validation

- **Path traversal prevention**: Blocks `..`, absolute paths, protocol prefixes
- **Command injection prevention**: Blocks `&&`, `||`, `>`, `<`, `;`, etc.
- **Prompt injection prevention**: Blocks instruction override attempts

### Branch Name Validation

```regex
^[a-zA-Z0-9][a-zA-Z0-9/_-]*$
```

## Troubleshooting

### "No tasks.json found"
Run `/aimi:plan` first to create a task list.

### Story keeps failing
- Check the error in `/aimi:status`
- Try `/aimi:next` with different approach
- Use "skip" to move past blockers (sets `skipped: true`)

### Infinite loop on failed task
Fixed in v0.5.0 - skipped stories are excluded from jq query.

### Missing task-specific fields
```
Error: Story US-001 missing required fields for task-specific execution.
```
Regenerate with: `/aimi:plan-to-tasks [plan-file-path]`

## Components

| Type | Count |
|------|-------|
| Commands | 7 |
| Skills | 2 |
| Patterns | 4 |

## Version

Current: **0.6.0**

See [CHANGELOG.md](CHANGELOG.md) for version history.

## License

MIT
