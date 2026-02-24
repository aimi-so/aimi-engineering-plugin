---
name: aimi:execute
description: Execute all pending stories autonomously
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash(git:*), Bash(jq:*), Task
---

# Aimi Execute

Execute all pending stories in a loop, managing branches and handling failures.

## Step 1: Discover and Read Tasks (Metadata Only via jq)

**CRITICAL:** Do NOT read the full tasks file. Use `jq` to extract only metadata.

### Find the tasks file:

```bash
# Find the most recent tasks file
TASKS_FILE=$(ls -t docs/tasks/*-tasks.json 2>/dev/null | head -1)
```

If no file found:
```
No tasks file found. Run /aimi:plan to create a task list first.
```
STOP execution.

### Extract metadata:

```bash
# Extract metadata only (no stories loaded into context)
jq '{
  title: .metadata.title,
  pending: [.userStories[] | select(.passes == false and .skipped != true)] | length,
  completed: [.userStories[] | select(.passes == true)] | length,
  skipped: [.userStories[] | select(.skipped == true)] | length,
  total: .userStories | length
}' "$TASKS_FILE"
```

This returns:
```json
{
  "title": "feat: Add task status feature",
  "pending": 7,
  "completed": 2,
  "skipped": 1,
  "total": 10
}
```

**Counts:**
- `pending` - stories that can be executed (`passes=false`, not skipped)
- `completed` - stories that passed (`passes=true`)
- `skipped` - stories marked as skipped by user

**DO NOT:**
- Read the full tasks file into memory
- Load all stories into context

## Step 2: Branch Setup

Derive branch name from the metadata title:
- Convert to kebab-case
- Prefix with `aimi/`
- Example: "feat: Add task status" → `aimi/feat-add-task-status`

### Validate Branch Name (SECURITY)

**CRITICAL:** Branch name must match:
```
^[a-zA-Z0-9][a-zA-Z0-9/_-]*$
```

If invalid characters found:
```
Error: Invalid branch name derived from title.
```
STOP execution.

### Check Current Branch

```bash
current_branch=$(git branch --show-current)
```

### If already on correct branch:
Proceed to Step 3.

### If on different branch:
Check if target branch exists:
```bash
git branch --list [branchName]
```

- If exists: `git checkout [branchName]`
- If not exists: `git checkout -b [branchName]`

Report:
```
Switched to branch: [branchName]
```

## Step 3: Check for Pending Stories

If no pending stories:
```
All stories already complete! ([total]/[total])

Run /aimi:review to review the implementation.
```
STOP execution.

Report start:
```
Starting autonomous execution...

Feature: [title]
Branch: [branchName]
Stories: [pending] pending, [completed] completed

Beginning execution loop...
```

## Step 4: Execution Loop

**CRITICAL:** Execute stories ONE AT A TIME by priority order.

```
while (pending stories exist):
    1. Call /aimi:next (loads ONLY the next pending story by priority)
    
    2. Check result:
       - If success: continue to next iteration
       - If user chose "skip": continue to next iteration
       - If user chose "stop": break loop
    
    3. Re-read counts via jq (not full stories)
       - If no pending: exit loop
```

**Why one-at-a-time?**
- Each story gets full context window
- No wasted tokens on other stories
- Cleaner execution flow

## Step 5: Completion

When loop ends (all stories complete OR user stopped):

### If all stories complete:

Count commits on this branch:
```bash
git log --oneline main..HEAD | wc -l
```

Report:
```
## Execution Complete

All [total] stories completed successfully!

Branch: [branchName]
Commits: [count]

### Next Steps

- Review commits: `git log --oneline -[count]`
- Run `/aimi:review` for code review
- Create PR when ready: `gh pr create`
```

### If user stopped early:

```
## Execution Paused

Completed: [completed]/[total] stories

Run `/aimi:status` to see current state.
Run `/aimi:execute` to resume execution.
```

## Error Recovery

If execution is interrupted unexpectedly:

1. Tasks file preserves state (completed stories stay completed)
2. User can run `/aimi:execute` again to resume

The loop will automatically skip completed stories and continue from the next pending one (by priority).
