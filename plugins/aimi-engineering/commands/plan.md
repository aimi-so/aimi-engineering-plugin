---
name: aimi:plan
description: Create implementation plan and convert to tasks.json
argument-hint: "[feature description]"
disable-model-invocation: true
allowed-tools: Read, Write, Bash(mkdir:*), Bash(ls:*), Skill(plan-to-tasks)
---

# Aimi Plan

Create an implementation plan using compound-engineering, then convert it to tasks.json for autonomous execution.

## Step 1: Generate Plan

Run compound-engineering's plan workflow:

/workflows:plan $ARGUMENTS

## Step 2: Locate Generated Plan

After plan completion, find the most recent plan file:

```bash
ls -t docs/plans/*-plan.md | head -1
```

Store the path for the next step.

## Step 3: Convert to Tasks

Read the plan file and invoke the plan-to-tasks skill to convert it to structured tasks.

Use the plan-to-tasks skill with the plan file path.

## Step 4: Initialize Output Directory

Create the tasks directory if it doesn't exist:

```bash
mkdir -p docs/tasks
```

## Step 5: Write Output Files

Write the converted tasks to `docs/tasks/tasks.json`.

Initialize `docs/tasks/progress.md` with the header template (see plan-to-tasks skill).

## Step 6: Report Output

Tell the user:

```
Plan and tasks created successfully!

- Plan: docs/plans/[filename].md
- Tasks: docs/tasks/tasks.json
- Progress: docs/tasks/progress.md

Stories: [X] total

Next steps:
- Run `/aimi:deepen [plan-path]` to enhance with research (optional)
- Run `/aimi:status` to view task list
- Run `/aimi:execute` to begin autonomous execution
```
