---
name: aimi:execute
description: Execute all pending stories autonomously
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash(git:*), Bash(jq:*), Task
---

# Aimi Execute

Execute all pending stories in a loop, managing branches and handling failures.

## Step 1: Read Tasks (Metadata Only via jq)

**CRITICAL:** Do NOT read the full tasks.json file. Use `jq` to extract only metadata.

```bash
# Extract metadata only (no stories loaded into context)
jq '{
  project: .project,
  branchName: .branchName,
  pending: [.userStories[] | select(.passes == false)] | length,
  completed: [.userStories[] | select(.passes == true)] | length,
  total: .userStories | length
}' docs/tasks/tasks.json
```

This returns:
```json
{
  "project": "project-name",
  "branchName": "feature/branch",
  "pending": 8,
  "completed": 2,
  "total": 10
}
```

**DO NOT:**
- Read the full tasks.json into memory
- Use TodoWrite to list all stories
- Display all stories in the Plan panel

If file doesn't exist:
```
No tasks.json found. Run /aimi:plan to create a task list first.
```
STOP execution.

## Step 2: Branch Setup

Get the branch name from tasks.json `branchName` field.

### Validate Branch Name (SECURITY)

**CRITICAL:** Before using branchName in any git command, validate it matches:
```
^[a-zA-Z0-9][a-zA-Z0-9/_-]*$
```

If branchName contains invalid characters (spaces, semicolons, quotes, etc.):
```
Error: Invalid branch name "[branchName]". 
Branch names must contain only letters, numbers, hyphens, underscores, and forward slashes.
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

**CRITICAL:** Execute stories ONE AT A TIME. Only the current story should be in context.

```
while (pending stories exist):
    1. Call /aimi:next (this loads ONLY the next pending story)
    
    2. Check result:
       - If success: continue to next iteration
       - If user chose "skip": continue to next iteration
       - If user chose "stop": break loop
    
    3. Re-read tasks.json to get updated counts (not full stories)
       - Count remaining pending
       - If none pending: exit loop
```

**Why one-at-a-time?**
- Each story gets full context window
- No wasted tokens on stories not being executed
- Cleaner UI (only current task visible)
- Matches the "task-specific step injection" design

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
