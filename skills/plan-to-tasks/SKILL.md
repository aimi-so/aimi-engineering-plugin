---
name: plan-to-tasks
description: >
  Convert markdown implementation plans to structured tasks.json format.
  Use when user says "convert plan to tasks", "generate tasks from plan",
  "create tasks.json", or after /aimi:plan completes.
---

# Plan to Tasks Conversion

Convert a markdown implementation plan into a structured `tasks.json` file for autonomous execution.

## Input

A markdown plan file path containing Implementation Phases sections.

## Output

A `tasks.json` file following the schema in [task-format.md](./references/task-format.md).

## Conversion Steps

1. **Read the plan file** to extract:
   - Project name (from title or first heading)
   - Description (from Overview section)
   - Implementation phases

2. **Generate metadata**:
   - `branchName`: Derive from project name (e.g., `feature/project-name`)
   - `createdFrom`: Path to source plan file
   - `createdAt`: Current ISO 8601 timestamp

3. **Convert each phase to user stories**:
   - Each phase becomes one or more stories
   - Assign incrementing IDs: US-001, US-002, etc.
   - Extract acceptance criteria from phase details

4. **Order stories by dependency**:
   - Priority 1: Schema/database changes
   - Priority 2: Backend logic/server actions
   - Priority 3: UI components
   - Priority 4: Aggregation/dashboard views

5. **Ensure acceptance criteria quality**:
   - Always add "Typecheck passes" for code changes
   - Add "Verify changes work" for UI stories
   - Make criteria verifiable, not vague

## Story Sizing

**Critical:** Each story must be completable in ONE Task iteration.

Split stories that are too big. See [task-format.md](./references/task-format.md) for sizing guidelines.

## Example Conversion

### Input Plan Section

```markdown
### Phase 1: Database Schema

Create the users table with authentication fields.

**Files to create:**
- prisma/schema.prisma (add User model)
- migrations/

**Acceptance criteria:**
- Users table has email, password_hash, created_at
- Email has unique constraint
```

### Output Story

```json
{
  "id": "US-001",
  "title": "Create users database schema",
  "description": "As a developer, I need the users table schema for authentication",
  "acceptanceCriteria": [
    "Users table has email, password_hash, created_at columns",
    "Email column has unique constraint",
    "Migration runs successfully",
    "Typecheck passes"
  ],
  "priority": 1,
  "passes": false,
  "notes": "",
  "attempts": 0,
  "lastAttempt": null
}
```

## Output File Structure

Write to `docs/tasks/tasks.json`:

```json
{
  "project": "[extracted from plan]",
  "branchName": "feature/[project-name]",
  "description": "[extracted from plan overview]",
  "createdFrom": "[plan file path]",
  "createdAt": "[ISO 8601 timestamp]",
  "userStories": [
    // converted stories ordered by priority
  ]
}
```

## Initialize Progress Log

Also create `docs/tasks/progress.md`:

```markdown
# Aimi Progress Log

**Project:** [project name]
**Branch:** [branch name]
**Started:** [timestamp]
**Plan:** [link to plan file]

---

## Codebase Patterns

_Consolidated learnings from all stories (read this first)_

- _No patterns discovered yet_

---

<!-- Story progress entries will be appended below -->
```
