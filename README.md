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
| `/aimi:brainstorm` | Explore ideas (wraps compound-engineering) |
| `/aimi:plan` | Create plan + convert to tasks.json |
| `/aimi:deepen` | Enhance plan + update tasks.json |
| `/aimi:review` | Code review (wraps compound-engineering) |
| `/aimi:status` | Show execution progress |
| `/aimi:next` | Execute next pending story |
| `/aimi:execute` | Run all stories autonomously |

## Workflow

1. **Brainstorm**: `/aimi:brainstorm Add user authentication`
2. **Plan**: `/aimi:plan` (generates tasks.json)
3. **Deepen** (optional): `/aimi:deepen docs/plans/[plan].md`
4. **Execute**: `/aimi:execute` (autonomous loop)
5. **Review**: `/aimi:review` (code review)

## File Structure

```
docs/tasks/
├── tasks.json    # Structured task list with user stories
└── progress.md   # Learnings and execution history
```

## How It Works

1. Plan generates markdown plan via compound-engineering
2. Plan converted to tasks.json with sized user stories
3. Execute spawns fresh Task agents per story
4. Each agent reads progress.md for prior learnings
5. Learnings compound: future stories benefit from past discoveries

## Components

| Type | Count |
|------|-------|
| Commands | 7 |
| Skills | 2 |

## License

MIT
