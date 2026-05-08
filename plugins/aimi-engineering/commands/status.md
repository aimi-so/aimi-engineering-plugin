---
name: aimi:status
description: Show current task execution progress
allowed-tools: Bash(AIMI_CLI=*), Bash($AIMI_CLI:*)
---

# Aimi Status

Display the current execution progress using the CLI script.

## Step 0: Resolve CLI Path

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/cli-path-resolution.md` and follow the **Resolve CLI Path** and **Version Check** sections to set `$AIMI_CLI`. Each layer is a separate Bash call.

If resolution fails, report error and STOP.

Use `$AIMI_CLI` for all subsequent script calls.

## Step 1: Get Status via CLI

**CRITICAL:** Use the CLI script. Do NOT interpret jq queries directly.

```bash
$AIMI_CLI status
```

This returns JSON with status counts and story list.

> The CLI status output mirrors the tasks.json structure with added aggregate counts.
> Key fields: `schemaVersion`, `title`, `branch`, `maxConcurrency`, `researchDepth`, status counts (`pending`,`in_progress`,`completed`,`failed`,`skipped`,`total`), `userStories[]{id,title,status,dependsOn,priority,notes,wave,implementation,verification,gate}`

If no tasks file found, the script exits with error. Report:
```
No tasks file found. Run /aimi:plan to create a task list.
```

## Step 2: Display Status

Display execution waves and dependency information.

### Header

```
## Task Status: [title]

**Branch:** [branchName]
**Schema:** v3.3
**Max Concurrency:** [maxConcurrency]
**Research Depth:** [researchDepth or "auto"]
```

### Progress Summary

Count each status from the JSON:

```
### Progress
- Completed: X/Y
- In Progress: Z
- Failed: W
- Skipped: S
- Pending: P
```

### Execution Waves

Group stories into waves using topological level assignment:
- **Wave 1:** stories with `dependsOn: []` (empty array, no dependencies)
- **Wave 2:** stories whose ALL dependencies are in Wave 1
- **Wave 3:** stories whose ALL dependencies are in Wave 1 or Wave 2
- General rule: each story's wave = max(wave of its dependencies) + 1

**Algorithm to compute waves:**
1. Initialize a wave map: `{story_id -> wave_number}`
2. Stories with empty `dependsOn` are Wave 1
3. For remaining stories, wave = max(wave(dep) for dep in dependsOn) + 1
4. If a dependency's wave is not yet assigned, process dependencies first (topological order)

Use the `wave` field from the story if present; otherwise compute the wave using the algorithm above.

Display each wave:

```
### Execution Waves

**Wave 1** (independent - no dependencies)
| ID | Title | Status | Gate | Verification |
|----|-------|--------|------|--------------|
| US-001 | Story title | completed | decision:passed | — |
| US-002 | Story title | pending | — | — |

**Wave 2** (depends on Wave 1)
| ID | Title | Status | Gate | Verification | Blocked By |
|----|-------|--------|------|--------------|------------|
| US-003 | Story title | pending | action:pending | api:pending | US-001 |

**Wave 3** (depends on Wave 2)
| ID | Title | Status | Gate | Verification | Blocked By |
|----|-------|--------|------|--------------|------------|
| US-005 | Story title | pending | verify:pending | test:passed | US-003, US-004 |
```

**Notes on wave display:**
- Wave 1 table omits "Blocked By" column (there are no dependencies)
- Wave 2+ tables include "Blocked By" column showing the story's `dependsOn` list
- **Gate column:** Shows `type:status` from the story's `gate` object (e.g., `decision:pending`, `action:passed`). Show `—` if story has no gate.
- **Verification column:** Shows `strategy:status` from the story's `verification` object (e.g., `api:pending`, `test:passed`). Show `—` if story has no verification.
- Status uses the status values: pending, in_progress, completed, failed, skipped
- If a story has notes (especially failures), show on the next line: `Note: [notes text]`

### Dependency Graph

After the wave tables, show a simplified dependency graph:

```
### Dependency Graph
US-001 -> US-003, US-004
US-002 -> US-003
US-003 -> US-005
```

For each story that has other stories depending on it, show: `[story_id] -> [list of stories that depend on it]`.
Only show stories that have dependents (skip leaf nodes with no downstream).

### Next Steps

If there are pending or in_progress stories:
```
Next: Run /aimi:execute to continue execution.
```

If there are failed stories:
```
Failed stories detected. Run /aimi:execute to retry or /aimi:skip [story-id] to skip.
```

If all stories complete or skipped:
```
All stories complete! ([completed]/[total])

Run /aimi:review to review the implementation.
Run `git log --oneline` to see commits.
```

---

## Session State (Optional)

Optionally show session state:

```bash
$AIMI_CLI get-state
```

If there's a current story in progress:
```
Current: US-004 (in progress)
Last result: success
```
