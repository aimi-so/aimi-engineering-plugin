---
name: aimi:execute
description: Execute all pending stories autonomously
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash(git:*), Bash(./scripts/aimi-cli.sh:*), Task
---

# Aimi Execute

Execute all pending stories in a loop, managing branches and handling failures.

## Step 1: Initialize Session

**CRITICAL:** Use the CLI script to initialize session and get metadata. Do NOT interpret jq queries directly.

```bash
./scripts/aimi-cli.sh init-session
```

This returns:
```json
{
  "tasks": "docs/tasks/2026-02-24-feature-tasks.json",
  "branch": "feat/feature-name",
  "pending": 7
}
```

If no tasks file found, the script exits with error. Report:
```
No tasks file found. Run /aimi:plan to create a task list first.
```
STOP execution.

## Step 2: Branch Setup

Get the branch name from the init-session output (already validated by CLI).

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

```bash
./scripts/aimi-cli.sh count-pending
```

If result is `0`:
```
All stories already complete!

Run /aimi:review to review the implementation.
```
STOP execution.

Report start:
```
Starting autonomous execution...

Branch: [branchName]
Pending: [pending] stories

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

    3. Check pending count:
       ./scripts/aimi-cli.sh count-pending
       - If 0: exit loop
```

**Why one-at-a-time?**
- Each story gets full context window
- No wasted tokens on other stories
- Cleaner execution flow
- State persists across /clear

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

All stories completed successfully!

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

Run `/aimi:status` to see current state.
Run `/aimi:execute` to resume execution.
```

## Resuming After /clear

If context was cleared (via `/clear`), the CLI maintains state:

```bash
./scripts/aimi-cli.sh get-state
```

Returns:
```json
{
  "tasks": "docs/tasks/...",
  "branch": "feat/...",
  "story": null,
  "last": "success"
}
```

- If `story` is set, there's an interrupted story
- If `last` is "success", continue with next story
- If `last` is "failed", ask user how to proceed

## Error Recovery

If execution is interrupted unexpectedly:

1. Tasks file preserves state (completed stories stay completed)
2. State files in `.aimi/` track current position
3. User can run `/aimi:execute` again to resume

The loop will automatically skip completed stories and continue from the next pending one (by priority).
