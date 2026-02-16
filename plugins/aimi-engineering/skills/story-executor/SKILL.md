---
name: story-executor
description: >
  Execute a single story from tasks.json autonomously.
  This skill provides the prompt template for Task-spawned agents.
  Used internally by /aimi:execute command.
---

# Story Executor

This skill defines how Task-spawned agents execute individual stories from the new tasks.json schema (v2.0).

## Schema Reference

Stories now follow this structure (see [task-format.md](../plan-to-tasks/references/task-format.md)):

```json
{
  "id": "story-1",
  "title": "Phase 1: Database Schema",
  "description": "Add users table with authentication fields.",
  "estimatedEffort": "1-2 hours",
  "tasks": [
    {
      "id": "task-1-1",
      "title": "Create users table migration",
      "description": "Create Prisma migration to add users table",
      "file": "prisma/migrations/[timestamp]_add_users/migration.sql",
      "status": "pending"
    }
  ]
}
```

## Input Sanitization (SECURITY)

**CRITICAL:** Before interpolating story data into the prompt, sanitize all fields:

### 1. Strip Dangerous Characters

From `title`, `description`, task titles/descriptions:
- Remove newlines (`\n`, `\r`, `\r\n`)
- Remove markdown headers (`#`, `##`, `###`, etc.)
- Remove code fence markers (triple backticks)
- Remove HTML tags (`<script>`, `<style>`, etc.)
- Remove control characters (ASCII 0-31 except space)

### 2. Validate Field Lengths

| Field | Max Length |
|-------|------------|
| Story `title` | 200 characters |
| Story `description` | 500 characters |
| Task `title` | 200 characters |
| Task `description` | 500 characters |
| Task `file` | 300 characters |

### 3. Command Injection Prevention

**Reject fields containing ANY of these patterns:**

```python
COMMAND_INJECTION_PATTERNS = [
    r"\$\(",           # Command substitution $(...)
    r"`",              # Backtick command substitution
    r"\|",             # Pipe
    r";",              # Command separator
    r"&&",             # AND operator
    r"\|\|",           # OR operator
    r">",              # Redirect stdout
    r">>",             # Append stdout
    r"<",              # Redirect stdin
    r"\n",             # Newline
    r"\r",             # Carriage return
    r"\$\{",           # Variable expansion
    r"\$[A-Z_]",       # Environment variable
]
```

### 4. Path Validation

All `file` paths must be validated:
- No parent directory traversal (`..`)
- No absolute paths (`/`)
- No protocol prefixes (`://`)
- Relative paths only

### 5. Validation Response

If ANY validation fails:
```
Error: Story [ID] contains potentially malicious content.
Field: [field_name]
Pattern matched: [pattern_description]
Please review tasks.json manually and regenerate with /aimi:plan-to-tasks.
```

## Available Capabilities

Spawned agents have access to:

- **File operations**: Read, Write, Edit (any file in the codebase)
- **Shell commands**: Bash for git, npm/bun/yarn, typecheck, lint, test runners
- **Git operations**: git add, git commit (branch already checked out by /aimi:execute)

## Prompt Template

When spawning a Task agent to execute a story, use this template:

```
You are executing a single story from docs/tasks/tasks.json.

## Your Story

ID: [STORY_ID]
Title: [STORY_TITLE]
Description: [STORY_DESCRIPTION]
Estimated Effort: [ESTIMATED_EFFORT]

## Tasks to Complete

[TASKS as numbered list with details]
1. [task-1-1] [title]
   File: [file]
   Description: [description]
   
2. [task-1-2] [title]
   File: [file]
   Description: [description]
...

## Acceptance Criteria (from root)

[ACCEPTANCE_CRITERIA - functional, nonFunctional, qualityGates relevant to this story]

## Project Guidelines (MUST FOLLOW)

[PROJECT_GUIDELINES - injected from CLAUDE.md/AGENTS.md or Aimi defaults]

## Execution Flow

1. For each task in order:
   a. Read the target file (if it exists)
   b. Implement the change described
   c. Handle `action: "delete"` tasks by removing the file
   d. Update task status to "completed"

2. After all tasks complete:
   a. Run quality checks (typecheck, lint, test as appropriate)
   b. If checks fail, STOP and report failure
   c. If checks pass, commit with: "feat: [STORY_ID] - [STORY_TITLE]"

3. Update tasks.json:
   - Set all task statuses to "completed"
   - Add any notes about implementation

## On Failure

If you cannot complete a task:

1. Do NOT mark task as completed
2. Update tasks.json with the task status and notes:
   ```json
   {
     "id": "task-1-2",
     "status": "pending",
     "notes": "Failed: [error summary]"
   }
   ```
3. Stop execution - do not proceed to remaining tasks
4. Return with clear failure report
```

## Task Tool Invocation

To spawn a story executor:

```javascript
Task({
  subagent_type: "general-purpose",
  description: `Execute ${story.id}: ${story.title}`,
  prompt: interpolate_prompt(FULL_PROMPT_TEMPLATE, story, rootAcceptanceCriteria)
})
```

## Compact Prompt (for subsequent stories)

For stories after the first one, use this compressed prompt:

```
Execute [STORY_ID]: [STORY_TITLE]

EFFORT: [ESTIMATED_EFFORT]
STORY: [STORY_DESCRIPTION]

TASKS:
1. [task-id] [title] → [file]
   [description]
2. [task-id] [title] → [file]
   [description]
...

CRITERIA: [relevant acceptance criteria]

RULES:
[PROJECT_GUIDELINES - commit format, conventions]

FLOW: read file → implement → next task → quality checks → commit → update tasks.json
FAIL: stop on first failure, report error, do not continue
```

## Project Guidelines Injection

When building the prompt, inject CLAUDE.md/AGENTS.md content directly for small files.

### Discovery Order

```python
def get_project_guidelines(project_root: str, task_files: list[str]) -> str:
    """
    Returns project guidelines content with Aimi defaults as fallback.
    """
    guidelines = []
    
    # 1. Check for CLAUDE.md (project-wide)
    claude_md = find_claude_md(project_root)
    if claude_md:
        guidelines.append(("CLAUDE.md", read_file(claude_md)))
    
    # 2. Check for AGENTS.md (directory-specific)
    for task_file in task_files:
        agents_md = find_agents_md(project_root, task_file)
        if agents_md and agents_md not in [g[0] for g in guidelines]:
            guidelines.append((agents_md, read_file(agents_md)))
    
    # 3. Fallback to Aimi defaults if neither found
    if not guidelines:
        return get_aimi_default_rules()
    
    # Check if existing files have commit rules
    has_commit_rules = any(
        "commit" in content.lower() and "format" in content.lower()
        for _, content in guidelines
    )
    
    # Append Aimi defaults if not covered
    if not has_commit_rules:
        guidelines.append(("Aimi Defaults", get_aimi_default_rules()))
    
    return format_guidelines(guidelines)
```

### Aimi Default Rules

```markdown
## Aimi Default Rules

### Commit Format
- Format: `<type>: [<story-id>] - <description>`
- Types: feat, fix, refactor, docs, test, chore
- Max 72 chars, imperative mood, no trailing period

### Commit Behavior (MANDATORY)
- One commit per completed story
- All quality checks MUST pass before commit
- NEVER use --no-verify or skip hooks
- NEVER force push unless explicitly instructed

### On Failure
- Do NOT commit if checks fail
- Mark tasks as failed with error details
- Report the failure clearly
```

## Placeholder Interpolation

| Placeholder | Source | Description |
|-------------|--------|-------------|
| `[STORY_ID]` | `story.id` | Story identifier (e.g., "story-1") |
| `[STORY_TITLE]` | `story.title` | Story title |
| `[STORY_DESCRIPTION]` | `story.description` | Story description |
| `[ESTIMATED_EFFORT]` | `story.estimatedEffort` | Time estimate |
| `[TASKS]` | `story.tasks` | Formatted task list |
| `[ACCEPTANCE_CRITERIA]` | Root `acceptanceCriteria` | Relevant criteria |
| `[PROJECT_GUIDELINES]` | Computed | CLAUDE.md/AGENTS.md or defaults |

### Interpolation Process

```python
def interpolate_prompt(template: str, story: dict, acceptance_criteria: dict) -> str:
    """Replace all placeholders with story data."""
    # Sanitize all inputs first
    is_valid, error = sanitize_story(story)
    if not is_valid:
        raise ValueError(f"Story validation failed: {error}")
    
    task_files = [t["file"] for t in story["tasks"]]
    
    replacements = {
        "[STORY_ID]": story["id"],
        "[STORY_TITLE]": story["title"],
        "[STORY_DESCRIPTION]": story["description"],
        "[ESTIMATED_EFFORT]": story.get("estimatedEffort", "unknown"),
        "[TASKS]": format_tasks(story["tasks"]),
        "[ACCEPTANCE_CRITERIA]": format_acceptance_criteria(acceptance_criteria, story),
        "[PROJECT_GUIDELINES]": get_project_guidelines(project_root, task_files),
    }
    
    result = template
    for placeholder, value in replacements.items():
        result = result.replace(placeholder, value)
    
    return result


def format_tasks(tasks: list[dict]) -> str:
    """Format tasks as numbered list with details."""
    lines = []
    for i, task in enumerate(tasks, 1):
        lines.append(f"{i}. [{task['id']}] {task['title']}")
        lines.append(f"   File: {task['file']}")
        lines.append(f"   Description: {task['description']}")
        if task.get("action"):
            lines.append(f"   Action: {task['action']}")
        lines.append("")
    return "\n".join(lines)


def format_acceptance_criteria(criteria: dict, story: dict) -> str:
    """Format relevant acceptance criteria for the story."""
    lines = []
    
    # Include quality gates always
    if criteria.get("qualityGates"):
        lines.append("Quality Gates:")
        for gate in criteria["qualityGates"]:
            lines.append(f"  - {gate}")
    
    # Include relevant functional criteria based on story content
    if criteria.get("functional"):
        lines.append("\nFunctional:")
        for criterion in criteria["functional"]:
            # Simple relevance check - could be made smarter
            lines.append(f"  - {criterion}")
    
    return "\n".join(lines)
```

## Handling Special Task Actions

### Delete Action

When a task has `"action": "delete"`:

```python
if task.get("action") == "delete":
    # Use Bash to remove the file
    # git rm [file] to stage deletion
    pass
```

### Create Action

When a task has `"action": "create"`:
- File does not exist yet
- Use Write tool to create it

### Default (Modify)

When no action specified:
- File should exist
- Use Edit tool to modify it

## References

For detailed execution rules, see [execution-rules.md](./references/execution-rules.md).
