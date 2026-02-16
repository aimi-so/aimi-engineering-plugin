---
name: aimi:status
description: Show current task execution progress
allowed-tools: Read
---

# Aimi Status

Display the current execution progress from tasks.json.

## Step 1: Read Tasks

Read `docs/tasks/tasks.json`.

If file doesn't exist, report:
```
No tasks.json found. Run /aimi:plan to create a task list.
```

## Step 2: Calculate Progress

Count stories:
- Total: length of userStories array
- Completed: count where passes === true
- Pending: count where passes === false

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
- `→` for next pending (first story where passes: false)
- `○` for pending (passes: false)

Example:
```
✓ US-001: Add database schema          (completed)
✓ US-002: Add password utilities       (completed)
→ US-003: Add login UI                 (next)
○ US-004: Add registration UI          (pending)
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
