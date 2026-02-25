---
name: aimi:plan
description: Create implementation plan and convert to tasks.json
argument-hint: "[feature description]"
---

# Aimi Plan

Run compound-engineering's plan workflow, then convert to tasks.json for autonomous execution.

## Step 1: Execute Compound Plan

/workflows:plan $ARGUMENTS

**IMPORTANT:** When compound-engineering presents post-generation options, DO NOT show them to the user. Proceed directly to Step 2.

## Step 2: Locate Generated Plan

Find the most recent plan file:

```bash
ls -t docs/plans/*-plan.md | head -1
```

## Step 3: Initialize Output Directory

```bash
mkdir -p docs/tasks
```

## Step 4: Convert to Tasks

Read the plan file and invoke the plan-to-tasks skill:

```
Skill: plan-to-tasks
Args: [plan-file-path]
```

## Step 5: Write Tasks File

Write the converted tasks to `docs/tasks/YYYY-MM-DD-[feature-name]-tasks.json`.

The filename should match the plan filename pattern:
- Plan: `docs/plans/2026-02-16-task-status-plan.md`
- Tasks: `docs/tasks/2026-02-16-task-status-tasks.json`

## Step 6: Aimi-Branded Report (OVERRIDE)

**CRITICAL:** Display ONLY Aimi-specific output. NEVER show compound-engineering options.

```
Plan and tasks created successfully!

📋 Plan: docs/plans/[filename].md
📝 Tasks: docs/tasks/[tasks-filename].json

Stories: [X] total
Schema version: 2.1

Next steps:
1. **Run `/aimi:deepen`** - Enhance plan with parallel research (optional)
2. **Run `/aimi:review`** - Get feedback from code reviewers
3. **Run `/aimi:status`** - View task list
4. **Run `/aimi:execute`** - Begin autonomous execution
```

**Command Mapping (what to say vs what NOT to say):**

| If compound says... | Aimi says instead... |
|---------------------|----------------------|
| `/workflows:plan` | `/aimi:plan` |
| `/workflows:work` | `/aimi:execute` |
| `/deepen-plan` | `/aimi:deepen` |
| `/plan_review` | `/aimi:review` |
| `/technical_review` | `/aimi:review` |

**NEVER mention:**
- compound-engineering
- workflows:*
- Any command without the `aimi:` prefix

## Error Handling

If Step 1 fails or is cancelled:
- Do NOT proceed to Step 2-6
- Report the error to the user

If Step 4-5 fails:
- Report which step failed
- Plan file still exists - user can run `/aimi:plan-to-tasks [path]` manually
