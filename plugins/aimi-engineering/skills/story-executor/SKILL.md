---
name: story-executor
description: >
  Execute a single story from the tasks file autonomously.
  This skill defines how Task-spawned agents execute individual stories.
  Used internally by /aimi:execute and /aimi:status commands.
---

# Story Executor

Defines how Task-spawned agents execute individual stories from the tasks file.

---

## The Job

Execute ONE story from the tasks file:
1. Read project guidelines (CLAUDE.md)
2. Implement the story
3. Verify acceptance criteria
4. Commit changes
5. Update tasks.json

---

## Story Format

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

---

## The Number One Rule

**Each story must be completable in ONE iteration (one context window).**

The agent spawns fresh with no memory of previous work. If the story is too big, the agent runs out of context before finishing.

---

## Prompt Template

When spawning a Task agent to execute a story:

```
You are executing a single story from the tasks file.

## PROJECT GUIDELINES (READ FIRST)

[CLAUDE.md content or default rules]

## Your Story

ID: [STORY_ID]
Title: [STORY_TITLE]
Description: [STORY_DESCRIPTION]

## Acceptance Criteria

[ACCEPTANCE_CRITERIA_BULLETED]

## Execution Flow

1. Read CLAUDE.md for project conventions
2. Implement the story requirements
3. Verify ALL acceptance criteria are met
4. Run typecheck: npx tsc --noEmit
5. If all checks pass, commit with: "feat(scope): Story title"
6. Update the tasks file: set passes: true for this story

## On Failure

If you cannot complete the story:

1. Do NOT mark passes: true
2. Update the tasks file with notes describing the failure
3. Return with clear failure report
```

---

## Compact Prompt

For token efficiency:

```
Execute [STORY_ID]: [STORY_TITLE]

STORY: [STORY_DESCRIPTION]

CRITERIA:
- [criterion 1]
- [criterion 2]
...

RULES: [CLAUDE.md conventions]

FLOW: implement → verify criteria → typecheck → commit → update tasks file
FAIL: stop on failure, report error, do not commit
```

---

## Task Tool Invocation

```javascript
Task({
  subagent_type: "general-purpose",
  description: `Execute ${story.id}: ${story.title}`,
  prompt: interpolate_prompt(PROMPT_TEMPLATE, story)
})
```

---

## Project Guidelines

When building the prompt, inject CLAUDE.md content. If not found, use default rules:

```markdown
## Default Rules

### Commit Format
- Format: `<type>(<scope>): <description>`
- Example: `feat(tasks): Add status field to tasks table`
- Types: feat, fix, refactor, docs, test, chore
- Scope: module or feature area
- Max 72 chars, imperative mood, no trailing period

### Commit Behavior
- One commit per completed story
- Typecheck MUST pass before commit
- NEVER use --no-verify or skip hooks
- NEVER force push

### On Failure
- Do NOT commit if checks fail
- Update story notes with error details
- Report the failure clearly
```

---

## Failure Handling

If you cannot complete a story:

1. **Do NOT** mark `passes: true`
2. **Update the tasks file** with failure details:

```json
{
  "id": "US-001",
  "passes": false,
  "notes": "Failed: TypeScript error - User type missing 'status' field"
}
```

3. **Return** with clear failure report

---

## Checklist

Before completing a story:

- [ ] All acceptance criteria verified
- [ ] Typecheck passes (`npx tsc --noEmit`)
- [ ] Changes committed with proper format
- [ ] Tasks file updated with `passes: true`
