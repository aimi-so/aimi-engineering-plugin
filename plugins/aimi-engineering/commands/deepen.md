---
name: aimi:deepen
description: Enhance plan with research and update tasks.json
argument-hint: "[path to plan file]"
---

# Aimi Deepen

Run compound-engineering's deepen workflow, then update tasks.json while preserving state.

## Step 1: Execute Compound Deepen

/deepen-plan $ARGUMENTS

**IMPORTANT:** When compound-engineering presents post-enhancement options, DO NOT show them to the user. Proceed directly to Step 2.

## Step 2: Discover and Read Current State

Find the tasks file:

```bash
TASKS_FILE=$(ls -t docs/tasks/*-tasks.json 2>/dev/null | head -1)
```

If found, capture current state:

- Which stories have `passes: true`
- Current `notes` field contents

## Step 3: Re-Convert to Tasks

Re-read the enhanced plan file and invoke the plan-to-tasks skill to generate updated stories.

## Step 4: Preserve State

**CRITICAL:** Merge the new conversion with existing state:

For each story in the new conversion:
- If a matching story (by ID or title) exists in old state:
  - Keep `passes` value from old state
  - Keep `notes` value from old state
  - Update story's `acceptanceCriteria` with enhanced details
- If no match, use new story as-is

## Step 5: Update Tasks File

Write the merged result back to the same tasks file (preserving the dynamic filename).

## Step 6: Aimi-Branded Report (OVERRIDE)

**CRITICAL:** Display ONLY Aimi-specific output. NEVER show compound-engineering options.

```
Plan deepened successfully!

📋 Enhanced: docs/plans/[filename].md
📝 Updated: docs/tasks/[tasks-filename].json

Changes:
- [X] stories updated with research insights
- [Y] completed stories preserved their status

Next steps:
1. **Run `/aimi:review`** - Get feedback from code reviewers
2. **Run `/aimi:status`** - View updated task list
3. **Run `/aimi:execute`** - Begin autonomous execution
```

**Command Mapping (what to say vs what NOT to say):**

| If compound says... | Aimi says instead... |
|---------------------|----------------------|
| `/workflows:work` | `/aimi:execute` |
| `/technical_review` | `/aimi:review` |
| `/plan_review` | `/aimi:review` |

**NEVER mention:**
- compound-engineering
- workflows:*
- Any command without the `aimi:` prefix
