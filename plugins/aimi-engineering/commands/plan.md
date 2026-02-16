---
name: aimi:plan
description: Create implementation plan and convert to tasks.json
argument-hint: "[feature description]"
disable-model-invocation: true
allowed-tools: Read, Write, Bash(mkdir:*), Bash(ls:*), Skill(compound-engineering:workflows:plan), Skill(plan-to-tasks)
---

# Aimi Plan

Create an implementation plan using compound-engineering, then convert it to tasks.json for autonomous execution.

## Execution Flow

**IMPORTANT:** This command has two phases that MUST run sequentially:

1. **Phase 1:** Run `/workflows:plan` to generate the implementation plan
2. **Phase 2:** After Phase 1 completes, automatically run Steps 2-6 to convert to tasks.json

Do NOT wait for user input between phases. The entire flow runs as one operation.

---

## Phase 1: Generate Plan

**CRITICAL:** Invoke the compound-engineering plan workflow FIRST:

```
/workflows:plan $ARGUMENTS
```

Wait for this skill to complete fully. It will:
- Research the codebase
- Ask clarifying questions if needed
- Generate a plan file at `docs/plans/YYYY-MM-DD-*-plan.md`
- Present post-generation options to the user

**After the user selects an option OR the plan is complete**, proceed immediately to Phase 2.

---

## Phase 2: Convert to Tasks (Automatic)

Once the plan file exists, execute these steps automatically WITHOUT user prompts:

### Step 2: Locate Generated Plan

Find the most recent plan file:

```bash
ls -t docs/plans/*-plan.md | head -1
```

Store the path for the next step.

### Step 3: Initialize Output Directory

Create the tasks directory if it doesn't exist:

```bash
mkdir -p docs/tasks
```

### Step 4: Convert to Tasks

Read the plan file and invoke the plan-to-tasks skill:

```
Skill: plan-to-tasks
Args: [plan-file-path]
```

This generates the structured tasks.json with:
- Task-specific steps for each story
- Pattern library matching
- AGENTS.md discovery
- qualityChecks for verification

### Step 5: Write Output Files

Write the converted tasks to `docs/tasks/tasks.json`.

Initialize `docs/tasks/progress.md` with the header template (see plan-to-tasks skill).

### Step 6: Report Output

Tell the user:

```
Plan and tasks created successfully!

- Plan: docs/plans/[filename].md
- Tasks: docs/tasks/tasks.json
- Progress: docs/tasks/progress.md

Stories: [X] total
Schema version: 2.0

Next steps:
- Run `/aimi:deepen [plan-path]` to enhance with research (optional)
- Run `/aimi:status` to view task list
- Run `/aimi:execute` to begin autonomous execution
```

---

## Error Handling

If Phase 1 fails or is cancelled:
- Do NOT proceed to Phase 2
- Report the error to the user

If Phase 2 fails:
- Report which step failed
- The plan file still exists and can be converted manually with `/plan-to-tasks [path]`
