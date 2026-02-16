---
name: aimi:status
description: Show current task execution progress
allowed-tools: Bash(jq:*)
---

# Aimi Status

Display the current execution progress using jq (minimal context usage).

## Step 1: Get Status via jq

**CRITICAL:** Do NOT read full tasks.json. Use jq to extract status:

```bash
jq '{
  project: .project,
  branchName: .branchName,
  completed: [.userStories[] | select(.passes == true) | {id, title}],
  pending: [.userStories[] | select(.passes == false and .skipped != true) | {id, title}],
  skipped: [.userStories[] | select(.skipped == true) | {id, title, notes}],
  total: .userStories | length
}' docs/tasks/tasks.json
```

If file doesn't exist, report:
```
No tasks.json found. Run /aimi:plan to create a task list.
```

## Step 2: Calculate Progress

From jq output:
- Completed: length of completed array
- Pending: length of pending array  
- Skipped: length of skipped array
- Total: total count

## Step 3: Display Status

Output format:

```
Aimi Status: [project] ([branchName])

Stories: [completed]/[total] complete

[status list - see below]

Next: [next story info or completion message]
```

## Status List Format

For each story, show status indicator:

- `✓` for completed (passes: true)
- `✗` for skipped (skipped: true)
- `→` for next pending (first in pending array)
- `○` for other pending

Example:
```
✓ US-001: Add database schema          (completed)
✓ US-002: Add password utilities       (completed)
✗ US-003: Add login UI                 (skipped: auth middleware issue)
→ US-004: Add registration UI          (next)
○ US-005: Add session middleware       (pending)
```

## Next Steps

If there are pending stories:
```
Next: US-003 - Add login UI

Run /aimi:next to execute the next story.
Run /aimi:execute to run all remaining stories.
```

If all stories complete:
```
All stories complete! (5/5)

Run /aimi:review to review the implementation.
Run `git log --oneline` to see commits.
```

## Notes Display

If a story has notes (especially failures), show them:

```
→ US-003: Add login UI                 (next)
  Note: Previous attempt failed - auth middleware missing
```


