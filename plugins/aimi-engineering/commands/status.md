---
name: aimi:status
description: Show current task execution progress
allowed-tools: Bash(./scripts/aimi-cli.sh:*)
---

# Aimi Status

Display the current execution progress using the CLI script.

## Step 1: Get Status via CLI

**CRITICAL:** Use the CLI script. Do NOT interpret jq queries directly.

```bash
./scripts/aimi-cli.sh status
```

This returns comprehensive status as JSON:
```json
{
  "title": "feat: Add user authentication",
  "branch": "feat/user-auth",
  "pending": 5,
  "completed": 2,
  "skipped": 1,
  "total": 8,
  "stories": [
    {"id": "US-001", "title": "Add schema", "passes": true, "skipped": false, "notes": ""},
    {"id": "US-002", "title": "Add login", "passes": false, "skipped": false, "notes": ""}
  ]
}
```

If no tasks file found, the script exits with error. Report:
```
No tasks file found. Run /aimi:plan to create a task list.
```

## Step 2: Display Status

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
- `→` for next pending (first pending by priority)
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
Next: US-004 - Add registration UI

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
→ US-004: Add registration UI          (next)
  Note: Previous attempt failed - missing dependency
```

## Session State

Optionally show session state:

```bash
./scripts/aimi-cli.sh get-state
```

If there's a current story in progress:
```
Current: US-004 (in progress)
Last result: success
```
