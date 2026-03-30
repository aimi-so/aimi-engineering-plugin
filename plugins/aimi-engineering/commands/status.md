---
name: aimi:status
description: Show current task execution progress
allowed-tools: Bash(AIMI_CLI=*), Bash($AIMI_CLI:*)
---

# Aimi Status

Display the current execution progress using the CLI script.

## Step 0: Resolve CLI Path

Resolve `$AIMI_CLI` path using the three-layer strategy below. Each command is a separate Bash call (no compound operators).

**Layer 1 — Global cache (fast path):**
```bash
AIMI_CLI=$(cat ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path 2>/dev/null)
```

**Layer 1 validation:**
```bash
if [ -n "$AIMI_CLI" ] && [ ! -x "$AIMI_CLI" ]; then AIMI_CLI=""; fi
```

**Layer 2 — Glob fallback (zsh-safe, only if Layer 1 failed):**
```bash
if [ -z "$AIMI_CLI" ]; then AIMI_CLI=$(bash -c 'ls ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1'); fi
```

**Layer 2 cache update:**
```bash
if [ -n "$AIMI_CLI" ]; then printf '%s\n' "$AIMI_CLI" > "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path.tmp" && mv "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path.tmp" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" && chmod 600 "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path"; fi
```

**Layer 3 — Per-project fallback (last resort):**
```bash
if [ -z "$AIMI_CLI" ] && [ -f .aimi/cli-path ] && [ -x "$(cat .aimi/cli-path)" ]; then AIMI_CLI=$(cat .aimi/cli-path); fi
```

If empty, report: "aimi-cli.sh not found. Reinstall plugin: `/plugin install aimi-engineering`" and STOP.

**Version check:**
```bash
$AIMI_CLI check-version --quiet --fix
```

Use `$AIMI_CLI` for all subsequent script calls.

## Step 1: Get Status via CLI

**CRITICAL:** Use the CLI script. Do NOT interpret jq queries directly.

```bash
$AIMI_CLI status
```

This returns JSON with status counts and story list.

> The CLI status output mirrors the tasks.json structure with added aggregate counts.
> Key fields: `schemaVersion`, `title`, `branch`, `maxConcurrency`, status counts (`pending`,`in_progress`,`completed`,`failed`,`skipped`,`total`), `userStories[]{id,title,status,dependsOn,priority,notes}`

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
**Schema:** v3.0
**Max Concurrency:** [maxConcurrency]
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

Display each wave:

```
### Execution Waves

**Wave 1** (independent - no dependencies)
| ID | Title | Status |
|----|-------|--------|
| US-001 | Story title | completed |
| US-002 | Story title | pending |

**Wave 2** (depends on Wave 1)
| ID | Title | Status | Blocked By |
|----|-------|--------|------------|
| US-003 | Story title | pending | US-001 |

**Wave 3** (depends on Wave 2)
| ID | Title | Status | Blocked By |
|----|-------|--------|------------|
| US-005 | Story title | pending | US-003, US-004 |
```

**Notes on wave display:**
- Wave 1 table omits "Blocked By" column (there are no dependencies)
- Wave 2+ tables include "Blocked By" column showing the story's `dependsOn` list
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
