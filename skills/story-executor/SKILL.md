---
name: story-executor
description: >
  Execute a single user story from tasks.json autonomously.
  This skill provides the prompt template for Task-spawned agents.
  Used internally by /aimi:next and /aimi:execute commands.
---

# Story Executor

This skill defines how Task-spawned agents execute individual user stories.

## Prompt Template

When spawning a Task agent to execute a story, use this template:

```
You are executing a single user story from docs/tasks/tasks.json.

## CRITICAL: Read Progress First

1. Read docs/tasks/progress.md FIRST
2. Pay special attention to the "Codebase Patterns" section at the top
3. These patterns will help you avoid known issues and follow conventions

## Your Story

ID: [STORY_ID]
Title: [STORY_TITLE]
Description: [STORY_DESCRIPTION]

Acceptance Criteria:
[ACCEPTANCE_CRITERIA as bullet list]

## Execution Steps

Follow the execution rules in order:

1. **Read context**: Read progress.md Codebase Patterns, understand the codebase
2. **Implement**: Make changes to satisfy ALL acceptance criteria
3. **Quality check**: Run typecheck, lint, tests as appropriate
4. **Fail fast**: If quality checks fail, STOP and report the failure
5. **Commit**: If all checks pass, commit with message "feat: [STORY_ID] - [STORY_TITLE]"
6. **Update tasks.json**: Set passes: true for this story
7. **Append progress**: Add your progress entry to progress.md
8. **Update patterns**: If you discovered important patterns, add to Codebase Patterns section

## Progress Entry Format

Append this to docs/tasks/progress.md:

---

## [STORY_ID] - [STORY_TITLE]

**Completed:** [ISO 8601 timestamp]
**Files changed:** [list files with backticks]

**What was implemented:**
- [bullet points]

**Learnings:**
- [patterns discovered]
- [gotchas encountered]

## On Failure

If you cannot complete the story:

1. Do NOT mark passes: true
2. Update tasks.json with:
   - passes: false
   - notes: "Failed: [detailed error]"
   - attempts: [increment]
   - lastAttempt: [timestamp]
3. Return with clear failure report
```

## Task Tool Invocation

Example of spawning a story executor:

```javascript
Task({
  subagent_type: "general-purpose",
  description: "Execute US-001: Add database schema",
  prompt: `
    You are executing a single user story from docs/tasks/tasks.json.
    
    ## CRITICAL: Read Progress First
    
    1. Read docs/tasks/progress.md FIRST
    2. Pay special attention to the "Codebase Patterns" section
    
    ## Your Story
    
    ID: US-001
    Title: Add database schema
    Description: As a developer, I need the database schema for authentication
    
    Acceptance Criteria:
    - Migration creates users table with email, password_hash, created_at
    - Email has unique constraint
    - Typecheck passes
    
    ## Execution Steps
    
    [... rest of template ...]
  `
})
```

## References

For detailed execution rules, see [execution-rules.md](./references/execution-rules.md).
