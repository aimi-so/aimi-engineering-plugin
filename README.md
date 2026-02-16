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
   - Generates markdown plan via compound-engineering
   - Converts plan to `docs/tasks/tasks.json`
   - Initializes `docs/tasks/progress.md`

3. **Deepen** (optional): `/aimi:deepen docs/plans/[plan].md`
   - Enhances plan with research insights
   - Updates tasks.json while preserving completion state

4. **Execute**: `/aimi:execute`
   - Creates/checkouts feature branch automatically
   - Loops through all stories using Task tool
   - Auto-retries failures, asks user on persistent issues
   - Reports completion with discovered patterns

5. **Review**: `/aimi:review`
   - Runs compound-engineering code review

## File Structure

```
docs/tasks/
├── tasks.json    # Structured task list with user stories
└── progress.md   # Learnings and execution history
```

### tasks.json

Each story includes **task-specific execution steps** generated at plan-to-tasks time:

```json
{
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
      "taskType": "prisma_schema",
      "steps": [
        "Read prisma/schema.prisma to understand existing models",
        "Add User model with required fields",
        "Run: npx prisma generate",
        "Run: npx prisma migrate dev",
        "Verify typecheck passes"
      ],
      "relevantFiles": ["prisma/schema.prisma", "src/lib/db.ts"],
      "patternsToFollow": "prisma/AGENTS.md"
    }
  ]
}
```

### progress.md

```markdown
# Aimi Progress Log

## Codebase Patterns
_Read this section FIRST before implementing_
- Pattern: Use `@/` alias for imports
- Gotcha: Run `prisma generate` after schema changes

## US-001 - Add database schema
**Completed:** 2026-02-15T10:45:00Z
**Learnings:** [discovered patterns]
```

## How It Works

1. **Plan Generation**: Creates detailed markdown plan via compound-engineering
2. **Task Conversion**: Converts phases to sized user stories (one context window each)
3. **Step Generation**: Each story gets task-specific steps from pattern library + AGENTS.md discovery
4. **Fresh Context**: Each story executed by Task-spawned agent with fresh context
5. **Learning Capture**: Agents read progress.md patterns before starting
6. **Compounding**: Future stories benefit from past discoveries

## Task-Specific Step Generation

Instead of generic execution instructions, each story gets **domain-aware steps** generated at plan-to-tasks time.

### Pattern Library

Workflow templates in `docs/patterns/`:

| Pattern | Task Type | Description |
|---------|-----------|-------------|
| prisma-schema.md | `prisma_schema` | Database schema changes |
| server-action.md | `server_action` | Next.js server actions |
| react-component.md | `react_component` | React components |
| api-route.md | `api_route` | API endpoints |

### AGENTS.md Discovery

The system discovers AGENTS.md files in your project and matches them to tasks based on file paths:

```
Story mentions: prisma/schema.prisma
Discovery: prisma/AGENTS.md exists
Result: patternsToFollow = "prisma/AGENTS.md"
```

### Step Generation Flow

1. **Extract keywords** from story title/description
2. **Match against pattern library** (keyword + file pattern matching)
3. **If match found**: Use pattern's step template
4. **If no match**: LLM generates domain-aware steps
5. **Discover AGENTS.md**: Find relevant project patterns
6. **Store in tasks.json**: taskType, steps, relevantFiles, patternsToFollow

## Story Sizing

Each story must be completable in ONE Task iteration:

**Right-sized:**
- Add a database column
- Add a UI component
- Update a server action

**Too big (split these):**
- "Build entire dashboard"
- "Add authentication"

## Troubleshooting

### "No tasks.json found"
Run `/aimi:plan` first to create a task list.

### Story keeps failing
- Check the error in `/aimi:status`
- Try `/aimi:next` with different approach
- Use "skip" to move past blockers

### Lost progress
- tasks.json preserves completion state
- progress.md has all learnings
- Run `/aimi:execute` to resume

## Components

| Type | Count |
|------|-------|
| Commands | 7 |
| Skills | 2 |

## License

MIT
