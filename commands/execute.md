---
name: aimi:execute
description: Execute all pending stories autonomously
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash(git:*), Task
---

# Aimi Execute

Execute all pending stories in a loop, managing branches and handling failures.

## Step 1: Read Tasks

Read `docs/tasks/tasks.json`.

If file doesn't exist:
```
No tasks.json found. Run /aimi:plan to create a task list first.
```
STOP execution.

## Step 2: Branch Setup

Get the branch name from tasks.json `branchName` field.

Check current branch:
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

Count pending stories (where `passes === false`).

If none pending:
```
All stories already complete! ([total]/[total])

Run /aimi:review to review the implementation.
```
STOP execution.

Report start:
```
Starting autonomous execution...

Project: [project]
Branch: [branchName]
Stories: [pending] pending, [completed] completed

Beginning execution loop...
```

## Step 4: Execution Loop

```
while (pending stories exist):
    1. Run /aimi:next
    
    2. Check result:
       - If success: continue to next iteration
       - If user chose "skip": continue to next iteration
       - If user chose "stop": break loop
    
    3. Re-read tasks.json to check remaining pending
```

## Step 5: Completion

When loop ends (all stories complete OR user stopped):

### If all stories complete:

Count commits on this branch:
```bash
git log --oneline [default_branch]..HEAD | wc -l
```

Read Codebase Patterns from progress.md.

Report:
```
## Execution Complete

All [total] stories completed successfully!

Branch: [branchName]
Commits: [count]

### Codebase Patterns Discovered

[list patterns from progress.md Codebase Patterns section]

### Next Steps

- Review commits: `git log --oneline -[count]`
- Run `/aimi:review` for code review
- Create PR when ready: `gh pr create`
```

### If user stopped early:

```
## Execution Paused

Completed: [completed]/[total] stories
Stopped at: [current story ID]

Run `/aimi:status` to see current state.
Run `/aimi:execute` to resume execution.
```

## Error Recovery

If execution is interrupted unexpectedly:

1. tasks.json preserves state (completed stories stay completed)
2. progress.md has all learnings
3. User can run `/aimi:execute` again to resume

The loop will automatically skip completed stories and continue from the next pending one.
