---
name: story-executor
description: >
  Execute a single story from tasks.json autonomously.
  This skill provides the prompt template for Task-spawned agents.
  Used internally by /aimi:execute and /aimi:next commands.
---

# Story Executor

This skill defines how Task-spawned agents execute individual stories from the tasks.json schema (v2.0).

## Schema Reference (v2.0)

Stories include task-specific guidance fields (see [task-format.md](../plan-to-tasks/references/task-format.md)):

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
  "notes": "",
  "taskType": "prisma_schema",
  "steps": [
    "Read CLAUDE.md and AGENTS.md for project conventions",
    "Read prisma/schema.prisma to understand existing models",
    "Add/modify the model or field",
    "Run: npx prisma generate",
    "Run: npx prisma migrate dev --name [descriptive-name]",
    "Verify typecheck passes"
  ],
  "relevantFiles": ["prisma/schema.prisma"],
  "qualityChecks": ["npx tsc --noEmit"]
}
```

## The Number One Rule

**Each story must be completable in ONE iteration (one context window).**

The agent spawns fresh with no memory of previous work. If the story is too big, the agent runs out of context before finishing.

## Input Sanitization (SECURITY)

**CRITICAL:** Before interpolating story data into the prompt, sanitize all fields:

### 1. Strip Dangerous Characters

From `title`, `description`, `steps`:
- Remove newlines (`\n`, `\r`, `\r\n`)
- Remove markdown headers (`#`, `##`, `###`, etc.)
- Remove code fence markers (triple backticks)
- Remove HTML tags
- Remove control characters (ASCII 0-31 except space)

### 2. Validate Field Lengths

| Field | Max Length |
|-------|------------|
| Story `id` | 20 characters |
| Story `title` | 200 characters |
| Story `description` | 500 characters |
| Each acceptance criterion | 300 characters |
| Each step | 500 characters |
| `taskType` | 50 characters |

### 3. Command Injection Prevention

**Reject fields containing ANY of these patterns:**

```
$( ` | ; && || > >> < \n \r ${ $[A-Z_]
```

### 4. Validation Response

If ANY validation fails:
```
Error: Story [ID] contains potentially malicious content.
Field: [field_name]
Please review tasks.json manually.
```

## Available Capabilities

Spawned agents have access to:

- **File operations**: Read, Write, Edit (any file in the codebase)
- **Shell commands**: Bash for git, npm/bun/yarn, typecheck, lint, test runners
- **Git operations**: git add, git commit (branch already checked out by /aimi:execute)

## Prompt Template (v2.0)

When spawning a Task agent to execute a story, use this template:

```
You are executing a single story from docs/tasks/tasks.json.

## PROJECT GUIDELINES (READ FIRST - MUST FOLLOW)

[PROJECT_GUIDELINES]

## Your Story

ID: [STORY_ID]
Title: [STORY_TITLE]
Description: [STORY_DESCRIPTION]

## Task Type

[TASK_TYPE]

## Execution Steps (follow in order)

[STEPS_ENUMERATED]

## Files to Read First

[RELEVANT_FILES_BULLETED]

## Acceptance Criteria

[ACCEPTANCE_CRITERIA_BULLETED]

## Quality Checks (must pass before commit)

[QUALITY_CHECKS_BULLETED]

## Execution Flow

Follow the execution steps above in order. After implementation:

1. Run ALL quality checks listed above
2. If any check fails, STOP and report failure
3. If all checks pass, commit with: "feat: [STORY_ID] - [STORY_TITLE]"
4. Update tasks.json: set passes: true for this story

## On Failure

If you cannot complete the story:

1. Do NOT mark passes: true
2. Update tasks.json with notes describing the failure:
   ```json
   {
     "id": "[STORY_ID]",
     "passes": false,
     "notes": "Failed: [error summary]"
   }
   ```
3. Return with clear failure report
```

## Task Tool Invocation

To spawn a story executor:

```javascript
Task({
  subagent_type: "general-purpose",
  description: `Execute ${story.id}: ${story.title}`,
  prompt: interpolate_prompt(PROMPT_TEMPLATE, story)
})
```

## Compact Prompt (for efficiency)

For a more token-efficient prompt:

```
Execute [STORY_ID]: [STORY_TITLE]

TYPE: [TASK_TYPE]
STORY: [STORY_DESCRIPTION]

STEPS:
1. [step 1]
2. [step 2]
...

FILES: [relevantFiles joined]

CRITERIA:
- [criterion 1]
- [criterion 2]
...

CHECKS: [qualityChecks joined]

RULES:
[PROJECT_GUIDELINES - commit format, conventions]

FLOW: follow steps → verify criteria → run checks → commit → update tasks.json
FAIL: stop on failure, report error, do not commit
```

## Project Guidelines Injection

When building the prompt, inject CLAUDE.md/AGENTS.md content directly.

### Discovery Order

1. **CLAUDE.md** (project root) - Primary project instructions
2. **AGENTS.md** (directory-specific) - Module-specific patterns
3. **Aimi defaults** - Fallback if neither exists

### Aimi Default Rules

```markdown
## Aimi Default Rules

### Commit Format
- Format: `<type>: <story-id> - <description>`
- Types: feat, fix, refactor, docs, test, chore
- Max 72 chars, imperative mood, no trailing period

### Commit Behavior (MANDATORY)
- One commit per completed story
- All quality checks MUST pass before commit
- NEVER use --no-verify or skip hooks
- NEVER force push unless explicitly instructed

### On Failure
- Do NOT commit if checks fail
- Update story notes with error details
- Report the failure clearly
```

## Placeholder Interpolation (v2.0)

| Placeholder | Source | Description |
|-------------|--------|-------------|
| `[STORY_ID]` | `story.id` | Story identifier (e.g., "US-001") |
| `[STORY_TITLE]` | `story.title` | Story title |
| `[STORY_DESCRIPTION]` | `story.description` | Story description |
| `[TASK_TYPE]` | `story.taskType` | Domain classification (e.g., "prisma_schema") |
| `[STEPS_ENUMERATED]` | `story.steps` | Enumerated list (1. step1, 2. step2...) |
| `[RELEVANT_FILES_BULLETED]` | `story.relevantFiles` | Bulleted list of file paths |
| `[ACCEPTANCE_CRITERIA_BULLETED]` | `story.acceptanceCriteria` | Bulleted list of criteria |
| `[QUALITY_CHECKS_BULLETED]` | `story.qualityChecks` | Bulleted list of commands |
| `[PROJECT_GUIDELINES]` | Computed | CLAUDE.md/AGENTS.md or defaults |

### Interpolation Process

```python
def interpolate_prompt(template: str, story: dict) -> str:
    """Replace all placeholders with story data."""
    # Sanitize all inputs first
    is_valid, error = sanitize_story(story)
    if not is_valid:
        raise ValueError(f"Story validation failed: {error}")
    
    replacements = {
        "[STORY_ID]": story["id"],
        "[STORY_TITLE]": story["title"],
        "[STORY_DESCRIPTION]": story["description"],
        "[TASK_TYPE]": story["taskType"],
        "[STEPS_ENUMERATED]": format_steps(story["steps"]),
        "[RELEVANT_FILES_BULLETED]": format_bullet_list(story["relevantFiles"]),
        "[ACCEPTANCE_CRITERIA_BULLETED]": format_bullet_list(story["acceptanceCriteria"]),
        "[QUALITY_CHECKS_BULLETED]": format_bullet_list(story["qualityChecks"]),
        "[PROJECT_GUIDELINES]": get_project_guidelines(project_root),
    }
    
    result = template
    for placeholder, value in replacements.items():
        result = result.replace(placeholder, value)
    
    return result


def format_steps(steps: list[str]) -> str:
    """Format steps as enumerated list."""
    return "\n".join(f"{i+1}. {step}" for i, step in enumerate(steps))


def format_bullet_list(items: list[str]) -> str:
    """Format items as bullet list."""
    return "\n".join(f"- {item}" for item in items)
```

## References

For detailed execution rules, see [execution-rules.md](./references/execution-rules.md).
