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
  title: .metadata.title,
  completed: [.userStories[] | select(.passes == true) | {id, title}],
  pending: [.userStories[] | select(.passes == false and .skipped != true) | {id, title, priority}] | sort_by(.priority),
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
Aimi Status: [title]

Stories: [completed]/[total] complete

[status list - see below]

Next: [next story info or completion message]
```

## Status List Format

For each story, show status indicator:

- `✓` for completed (passes: true)
- `✗` for skipped (skipped: true)
- `→` for next pending (first in pending array by priority)
- `○` for other pending

Example:
```
✓ US-001: Add database schema          (completed)
✓ US-002: Add password utilities       (completed)
✗ US-003: Add login UI                 (skipped: auth middleware issue)
→ US-004: Add registration UI          (next - priority 4)
○ US-005: Add session middleware       (pending - priority 5)
```

## Next Steps

If there are pending stories:
```
Next: US-004 - Add registration UI (priority 4)

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
→ US-004: Add registration UI          (next - priority 4)
  Note: Previous attempt failed - missing dependency
```
