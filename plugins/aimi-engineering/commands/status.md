---
name: aimi:status
description: Show current task execution progress
argument-hint: "[--phase <id>]"
allowed-tools: Bash(AIMI_CLI=*), Bash($AIMI_CLI:*)
---

# Aimi Status

Display the current execution progress using the CLI script.

## Flags

- `--phase <id>`: Scopes the render to a single roadmap phase's detail view — that phase's stories, its computed waves (labeled `Phase <id> · Wave <n>`), and its gate states. Only meaningful when Step 0.5 discovers a roadmap layout; there is nothing to scope to on a flat-layout feature.
- Default (no `--phase`): on a roadmap layout, renders the full **Roadmap Summary** across every phase, in phase order. On a flat layout, renders the existing Task Status view (Step 1/Step 2) unchanged.

Example:
```
/aimi:status --phase 2
```

## Step 0: Resolve CLI Path

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/cli-path-resolution.md` and follow the **Resolve CLI Path** and **Version Check** sections to set `$AIMI_CLI`. Each layer is a separate Bash call.

If resolution fails, report error and STOP.

Use `$AIMI_CLI` for all subsequent script calls.

## Step 0.5: Discover Task Layout

**CRITICAL:** Use the CLI script. Do NOT interpret jq queries directly, and do NOT `ls`/glob `.aimi/tasks/` directly — all layout detection goes through `$AIMI_CLI`.

```bash
$AIMI_CLI init-session
```

This is the same discovery `$AIMI_CLI status` uses internally (state pointer first, most-recent-file fallback second — across both the flat and nested phase-folder layouts), so calling it here does not change which file is "active."

If this fails (no tasks file found anywhere under `.aimi/tasks/`), report:
```
No tasks file found. Run /aimi:plan to create a task list.
```
STOP.

Otherwise it returns `{tasks, branch, pending, schemaVersion}`. Extract the resolved tasks path and inspect its parent directory's name — this is string inspection of a path the CLI already returned, not a filesystem glob/ls/jq of `.aimi/tasks/`:

```bash
TASKS_PATH=$($AIMI_CLI init-session | jq -r '.tasks')
PHASE_DIR_NAME=$(basename "$(dirname "$TASKS_PATH")")
```

- **`$PHASE_DIR_NAME` does NOT match `^phase-[0-9]`** → **flat layout**. Continue to Step 1 below and render exactly as documented there — no Roadmap Summary section, no `Phase <id> ·` prefix on any wave label.
- **`$PHASE_DIR_NAME` matches `^phase-[0-9]`** → **roadmap layout**. Derive the feature slug and the tasks-root directory (two and three levels above the tasks file, respectively):

  ```bash
  FEATURE_SLUG=$(basename "$(dirname "$(dirname "$TASKS_PATH")")")
  TASKS_DIR_ABS=$(dirname "$(dirname "$(dirname "$TASKS_PATH")")")
  ```

  - If `$ARGUMENTS` contains `--phase <id>` (a numeric phase id, e.g. `2` or `2.1`), skip Step 1/Step 2 and go to **Phase Detail View (`--phase <id>`)** below.
  - Otherwise, skip Step 1/Step 2 and go to **Roadmap Summary (Default View)** below.

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

## Roadmap Summary (Default View)

Rendered instead of Step 1/Step 2 whenever Step 0.5 detects a roadmap layout and no `--phase <id>` flag was given. A **phase** here is a roadmap milestone (its own row in this summary); a **wave** is a dependency tier inside one phase's own `tasks.json` — the two are never conflated in this render.

### Get Roadmap State

**CRITICAL:** Use the CLI script. Do NOT interpret jq queries directly.

```bash
$AIMI_CLI roadmap-get --feature "$FEATURE_SLUG"
```

Returns the full `roadmap.json`: `{roadmapVersion, feature, createdAt, brainstormPath, phases: [{id, name, goal, slug, dir, status, dependsOn, claim}]}`. `phases[]` is already sorted numerically by `id` (e.g. `2`, `2.1`, `3` — never lexical, so `2.1` never sorts after `3`) — render phases in the order returned; do not re-sort them.

Also fetch the discovered file list, needed to tell an expanded phase from an outline-only one:

```bash
$AIMI_CLI find-tasks-all
```

### Header

```
## Roadmap: [roadmap.feature]

**Branch context:** [current branch, e.g. from `git branch --show-current`]
```

### Per-Phase Row

For each phase, in the order returned by `roadmap-get` (numeric):

1. **ID and name:** `Phase [id]: [name]`
2. **Status:** printed verbatim from `phase.status` — one of `pending`, `planned`, `in_progress`, `verification_failed`, `completed`.
3. **Claim holder** (only when `phase.claim` is non-null): `Claimed by: [claim.claimedBy]`, followed by an `(alive)` or `(stale)` marker. Determine liveness with a signal-zero probe on `claim.claimedPid` — this mirrors the CLI's own stale-claim check and never mutates `roadmap.json`:
   ```bash
   kill -0 [claim.claimedPid] 2>/dev/null && echo alive || echo stale
   ```
   When the marker is `(stale)`, append a recovery hint on the same line: `— run $AIMI_CLI roadmap-release-claim --feature [feature] --phase [id] to clear it, or the next roadmap-claim call auto-releases it.`
4. **Story progress or outline marker:**
   - Construct this phase's expected tasks path: `$TASKS_DIR_ABS/$FEATURE_SLUG/[phase.dir]/$FEATURE_SLUG-phase-[phase.id]-tasks.json`.
   - If that exact path appears in the `find-tasks-all` output fetched above, the phase is **expanded** — point the CLI at it and read counts:
     ```bash
     $AIMI_CLI init-session --file [phase-tasks-path]
     $AIMI_CLI status --counts-only
     ```
     Show progress as `[completed]/[total]` from the returned counts.
   - If it does NOT appear, the phase is **outline only** — show the literal marker `outline only` instead of a done/total figure.
5. **Blockers** (only when `phase.status` is not `completed` and `phase.dependsOn` is non-empty): from the phases array already fetched, list every id in `phase.dependsOn` whose corresponding phase has `status != "completed"`, as `Blocked by: Phase [id] ([name], [status])`. Omit this line entirely when every dependency is `completed` (or `dependsOn` is empty).

### Sample Output

```
## Roadmap: notification-center

**Branch context:** feat/notification-center

**Phase 1: Foundations** — completed
  Progress: 4/4 stories done

**Phase 2: Delivery Channels** — in_progress
  Claimed by: session-a1b2c3 (alive)
  Progress: 2/5 stories done

**Phase 2.1: Retry Hardening** — pending
  outline only
  Blocked by: Phase 2 (Delivery Channels, in_progress)

**Phase 3: Admin Console** — pending
  outline only
  Blocked by: Phase 2 (Delivery Channels, in_progress), Phase 2.1 (Retry Hardening, pending)
```

Expanded-phase detail (e.g. `/aimi:status --phase 2`) renders that phase's own wave table, labeled with the owning phase id so it is never mistaken for a roadmap row:

```
**Phase 2 · Wave 1** (independent - no dependencies)
| ID | Title | Status | Gate | Verification |
|----|-------|--------|------|--------------|
| US-001 | Add channel registry | completed | — | — |
| US-002 | Wire email channel | completed | — | — |

**Phase 2 · Wave 2** (depends on Phase 2 · Wave 1)
| ID | Title | Status | Gate | Verification | Blocked By |
|----|-------|--------|------|--------------|------------|
| US-003 | Wire SMS channel | in_progress | — | — | US-001, US-002 |
```

---

## Phase Detail View (`--phase <id>`)

Rendered instead of Step 1/Step 2/Roadmap Summary whenever Step 0.5 detects a roadmap layout and `$ARGUMENTS` contains `--phase <id>`.

### Get the Phase

**CRITICAL:** Use the CLI script. Do NOT interpret jq queries directly.

```bash
$AIMI_CLI roadmap-get --feature "$FEATURE_SLUG" --phase [id]
```

Returns a single phase object — the full roadmap phase record, including `{id, name, goal, slug, dir, status, dependsOn, areas, claim}` and any other optional fields set on it (`successCriteria`, `creates`, `needs`, `notes`, `branch`). If the phase id does not exist, the CLI exits non-zero — report its stderr message and STOP.

### Declared Areas

When `phase.areas` is a non-empty array, render it once, above the expanded/outline-only report below:
```
**Areas:** app/checkout/**, lib/payments/**
```
Omit this line entirely when `areas` is absent or empty.

### Expanded vs. Outline Only

Construct the phase's expected tasks path exactly as in the Roadmap Summary's story-progress step above, and check it against `$AIMI_CLI find-tasks-all`.

- **Outline only** (no matching file): report
  ```
  Phase [id] ([name]) has not been expanded yet — it is outline only.
  Run /aimi:plan --phase [id] to expand it, then re-run /aimi:status --phase [id].
  ```
  STOP.

- **Expanded:** point the CLI at that phase's file and reuse Step 2's rendering:
  ```bash
  $AIMI_CLI init-session --file [phase-tasks-path]
  $AIMI_CLI status
  ```
  Follow Step 2's Header, Progress Summary, Execution Waves, Dependency Graph, and Next Steps rendering exactly as documented above, scoped to this phase's stories only — except every wave heading is labeled `Phase [id] · Wave [n]` instead of a bare `Wave [n]` (see the Sample Output above), and its Gate/Verification columns render this phase's own gate states.

### Example Invocation

```
/aimi:status --phase 2
```

Renders only Phase 2's stories, waves (`Phase 2 · Wave 1`, `Phase 2 · Wave 2`, ...), and gate states — omitting every other phase's rows.

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
