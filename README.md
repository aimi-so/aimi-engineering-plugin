# Aimi Engineering Plugin

Autonomous task execution with Ralph-style JSON tasks for Claude Code.

## Prerequisites

**Required:** compound-engineering-plugin must be installed first.

```bash
# Install compound-engineering first
claude /plugin install compound-engineering

# Then install aimi-engineering
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

```json
{
  "project": "user-auth",
  "branchName": "feature/user-auth",
  "description": "Add user authentication",
  "userStories": [
    {
      "id": "US-001",
      "title": "Add database schema",
      "acceptanceCriteria": ["...", "Typecheck passes"],
      "priority": 1,
      "passes": false
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
3. **Fresh Context**: Each story executed by Task-spawned agent with fresh context
4. **Learning Capture**: Agents read progress.md patterns before starting
5. **Compounding**: Future stories benefit from past discoveries

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
