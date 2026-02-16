---
name: plan-to-tasks
description: >
  Convert markdown implementation plans to structured tasks.json format.
  Use when user says "convert plan to tasks", "generate tasks from plan",
  "create tasks.json", or after /aimi:plan completes.
---

# Plan to Tasks Conversion

Convert a markdown implementation plan into a structured `docs/tasks/tasks.json` file for autonomous execution.

## Input

A markdown plan file path containing Implementation Phases sections.

## Output

A `docs/tasks/tasks.json` file following the schema in [task-format.md](./references/task-format.md).

Each story includes **task-specific execution steps** generated from the pattern library and AGENTS.md files.

## Conversion Steps

1. **Read the plan file** to extract:
   - Project name (from title or first heading)
   - Description (from Overview section)
   - Implementation phases

2. **Generate metadata**:
   - `branchName`: Derive from project name (e.g., `feature/project-name`)
   - `createdFrom`: Path to source plan file
   - `createdAt`: Current ISO 8601 timestamp

3. **Discover AGENTS.md files** (see AGENTS.md Discovery Algorithm below)

4. **Load pattern library** from `docs/patterns/*.md`

5. **Convert each phase to user stories**:
   - Each phase becomes one or more stories
   - Assign incrementing IDs: US-001, US-002, etc.
   - Extract acceptance criteria from phase details
   - **Generate task-specific fields** (see Step Generation below)

6. **Order stories by dependency**:
   - Priority 1: Schema/database changes
   - Priority 2: Backend logic/server actions
   - Priority 3: UI components
   - Priority 4: Aggregation/dashboard views

7. **Validate all stories** have required fields:
   - `taskType`, `steps`, `relevantFiles`, `patternsToFollow`

8. **Ensure acceptance criteria quality**:
   - Always add "Typecheck passes" for code changes
   - Add "Verify changes work" for UI stories
   - Make criteria verifiable, not vague

---

## AGENTS.md Discovery Algorithm

Discover project-specific patterns from AGENTS.md files.

### Discovery Steps

1. **Glob for AGENTS.md files**:
   ```bash
   find . -name "AGENTS.md" -type f
   ```
   Or use glob pattern: `**/AGENTS.md`

2. **Build directory index**:
   ```
   ./AGENTS.md
   ./src/AGENTS.md
   ./src/components/AGENTS.md
   ./prisma/AGENTS.md
   ```

3. **Cache results** for the duration of the plan-to-tasks run (no re-discovery per story)

### Path Matching Algorithm

For each story, find the most relevant AGENTS.md:

1. **Extract file paths** from story description, acceptance criteria, and phase files
   - Example: "Update prisma/schema.prisma" → extract `prisma/schema.prisma`

2. **For each extracted path**, walk up the directory tree:
   ```
   prisma/schema.prisma
   └── Check: prisma/AGENTS.md (exists? → match!)
   └── Check: ./AGENTS.md (fallback)
   ```

3. **Select most specific match**:
   - If `prisma/AGENTS.md` exists and story mentions `prisma/*` → use `prisma/AGENTS.md`
   - If only root `./AGENTS.md` exists → use that
   - If no AGENTS.md found → return `"none"`

4. **Set `patternsToFollow`** to the matched path or `"none"`

### Example

```
Story: "Add User model to Prisma schema"
Files mentioned: prisma/schema.prisma

Discovery:
  1. Check prisma/AGENTS.md → EXISTS
  2. Return "prisma/AGENTS.md"

Result: patternsToFollow = "prisma/AGENTS.md"
```

### No AGENTS.md Found

If no AGENTS.md files exist in the project:

```
patternsToFollow = "none"
```

The agent will rely on the pattern library and general codebase conventions.

---

## TaskType Inference

Determine the `taskType` for each story based on content analysis.

### Inference Algorithm

1. **Extract keywords** from story title and description:
   ```
   Title: "Add User model to Prisma schema"
   Keywords: [add, user, model, prisma, schema]
   ```

2. **Load pattern library** from `docs/patterns/*.md`

3. **Score each pattern** by keyword matches:
   ```
   prisma-schema.md: keywords=[prisma, schema, model, migration, database]
   Match score: 3 (prisma, schema, model)
   ```

4. **Select highest-scoring pattern**:
   - If score > 0: use pattern's `name` as `taskType`
   - If tie: prefer more specific pattern (more keywords matched)

5. **Fallback to LLM inference** if no pattern matches:
   - Analyze story content
   - Generate a snake_case taskType (max 50 chars)
   - Common fallback types: `documentation`, `refactor`, `test_implementation`, `configuration`

### Example

```
Story: "Create RegisterForm component"
Keywords: [create, registerform, component]

Pattern scores:
  - react-component.md: 1 (component)
  - server-action.md: 0
  - prisma-schema.md: 0

Result: taskType = "react_component"
```

---

## Pattern Library Matching

Match stories to workflow patterns for step generation.

### Loading Patterns

1. **Read all files** in `docs/patterns/*.md`
2. **Parse YAML frontmatter** to extract:
   - `name`: pattern identifier (becomes taskType)
   - `keywords`: words that trigger this pattern
   - `file_patterns`: file paths that trigger this pattern
3. **Parse markdown body** to extract:
   - `## Steps Template`: numbered step list
   - `## Relevant Files`: common files for this task type

### Matching Algorithm

For each story:

1. **Keyword matching**:
   - Extract words from title + description
   - Count matches against each pattern's `keywords`

2. **File pattern matching**:
   - Extract file paths from story content
   - Check against each pattern's `file_patterns` (glob matching)

3. **Combined score**:
   ```
   score = keyword_matches + (file_pattern_matches * 2)
   ```
   File patterns weighted higher (more specific signal)

4. **Select best match** (highest score wins)

---

## Step Generation

Generate task-specific steps for each story.

### From Pattern Library

If a pattern matches:

1. **Read pattern's `## Steps Template`**
2. **Interpolate placeholders** with story-specific values:
   - `{component_name}` → extracted from story title
   - `{migration_name}` → derived from story title
3. **Validate step count**: 1-10 steps, each ≤500 chars

### LLM Fallback

If no pattern matches:

1. **Build context prompt**:
   ```
   Generate 4-8 specific execution steps for this task:
   
   Title: [story title]
   Description: [story description]
   Acceptance Criteria: [criteria list]
   
   Guidelines:
   - Steps should be actionable and specific
   - Include tool commands where appropriate
   - Final step should verify the work
   - Maximum 10 steps, each under 500 characters
   ```

2. **Parse LLM response** into step array

3. **Validate output**:
   - Min 1 step, max 10 steps
   - Each step ≤500 characters
   - Steps are actionable (not vague)

### Validation Rules

| Rule | Error |
|------|-------|
| steps.length < 1 | "Story must have at least 1 step" |
| steps.length > 10 | "Story has too many steps (max 10)" |
| step.length > 500 | "Step exceeds 500 character limit" |

---

## relevantFiles Extraction

Identify files the agent should read before implementing.

### Extraction Sources

1. **Plan file content**:
   - Files listed in "Files to create:" or "Files to modify:"
   - Paths mentioned in phase description

2. **Pattern's `## Relevant Files`**:
   - If pattern matches, include its relevant files

3. **Story content**:
   - File paths mentioned in acceptance criteria
   - Paths derived from component/model names

### Example

```
Story: "Add User model to Prisma schema"
Pattern: prisma-schema.md

relevantFiles from pattern:
  - prisma/schema.prisma
  - src/lib/db.ts

relevantFiles from story:
  - (none additional)

Result: relevantFiles = ["prisma/schema.prisma", "src/lib/db.ts"]
```

### Validation

- Maximum 20 files
- Paths must be relative (no absolute paths)
- Duplicates removed

---

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

### Output Story (with task-specific fields)

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
  "lastAttempt": null,
  "taskType": "prisma_schema",
  "steps": [
    "Read prisma/schema.prisma to understand existing models and relations",
    "Add User model with fields: id, email, passwordHash, createdAt",
    "Add unique constraint on email field",
    "Run: npx prisma generate",
    "Run: npx prisma migrate dev --name add-users-table",
    "Verify typecheck passes"
  ],
  "relevantFiles": [
    "prisma/schema.prisma",
    "src/lib/db.ts"
  ],
  "patternsToFollow": "prisma/AGENTS.md"
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
    // converted stories with task-specific fields
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
