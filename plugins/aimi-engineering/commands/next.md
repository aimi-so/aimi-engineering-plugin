---
name: aimi:next
description: Execute the next pending story from tasks.json
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash(git:*), Bash(AIMI_CLI=*), Bash($AIMI_CLI:*), Bash(npm:*), Bash(bun:*), Bash(yarn:*), Bash(pnpm:*), Bash(npx:*), Bash(tsc:*), Bash(eslint:*), Bash(prettier:*), Task
---

# Aimi Next

Execute the next pending story using a Task-spawned agent.

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

## Step 1: Get Next Story

**CRITICAL:** Use the CLI script to get the next story. Do NOT interpret jq queries directly.

```bash
$AIMI_CLI next-story
```

This returns the next pending story as JSON. Fields depend on schema version:

**Response format:**
```json
{
  "id": "US-001",
  "title": "Add user schema",
  "description": "As a developer, I need...",
  "acceptanceCriteria": ["Criterion 1", "Criterion 2"],
  "priority": 1,
  "status": "pending",
  "dependsOn": [],
  "notes": ""
}
```

If result is `null`:
```
All stories complete! Run /aimi:review to review the implementation.
```
STOP execution.

The CLI also saves the story ID to `.aimi/current-story` for tracking.

## Step 1b: Resolve Project Path

If the story JSON contains a `project` field:

1. Determine `AIMI_ROOT` — the parent directory of `.aimi/` (the CLI auto-discovers `.aimi/` by walking up from CWD)
2. Resolve `PROJECT_PATH = realpath(AIMI_ROOT / story.project)`
3. Verify `PROJECT_PATH` exists as a directory; if not, report failure and STOP

If the story does **not** have a `project` field, skip this step — `PROJECT_PATH` remains unset and behavior is unchanged (CWD fallback).

## Step 2: Load Project Guidelines

Load project guidelines following the discovery order defined in `story-executor/SKILL.md` → "PROJECT GUIDELINES" section:

1. **CLAUDE.md** — If `PROJECT_PATH` is set, look for `CLAUDE.md` in `PROJECT_PATH` first. Otherwise use the current project root.
2. **AGENTS.md** (any directory) - Module-specific patterns
3. **Aimi defaults** from story-executor - Fallback if neither exists

Read these files and store the content as `PROJECT_GUIDELINES`.

## Step 3: Display Current Story

Show what's being executed:

```
Executing: [STORY_ID] - [STORY_TITLE]
Priority: [priority]

Acceptance Criteria:
- [criterion 1]
- [criterion 2]
...
```

## Step 4: Build Worker Prompt

**CRITICAL:** Construct the worker prompt following the canonical template in `story-executor/SKILL.md`.

Interpolate the following into the template:
- `PROJECT_GUIDELINES` = guidelines loaded in Step 2
- `PROJECT_PATH` = resolved project path from Step 1b (include `## Project Context` section only if set)
- `STORY_ID` = story.id
- `STORY_TITLE` = story.title
- `STORY_DESCRIPTION` = story.description
- `ACCEPTANCE_CRITERIA` = story.acceptanceCriteria (bulleted)
- `story.notes` = story.notes (include PREVIOUS NOTES section only if non-empty)
- No WORKTREE_PATH (sequential mode — worker operates in current directory, or PROJECT_PATH if set)

```
# IMPORTANT: subagent_type MUST be "general-purpose" — story-executor is a skill, NOT an agent.
Task general-purpose: "Execute [STORY_ID]: [STORY_TITLE]

[story-executor/SKILL.md prompt template with interpolated values]
"
```

## Step 5: Handle Result

### If Task succeeds:

Mark the story as complete:

```bash
$AIMI_CLI mark-complete [STORY_ID]
```

Report success:
```
[STORY_ID] - [STORY_TITLE] completed successfully.

Run /aimi:next for the next story.
Run /aimi:status to see overall progress.
```

### If Task fails (first attempt):

1. Mark the story as failed with notes:

```bash
$AIMI_CLI mark-failed [STORY_ID] "Attempt 1 failed: [error summary]"
```

2. RETRY automatically with error context:

```
# IMPORTANT: subagent_type MUST be "general-purpose" — story-executor is a skill, NOT an agent.
Task general-purpose: "RETRY: Execute [STORY_ID]: [STORY_TITLE]

PREVIOUS ATTEMPT FAILED:
[error details from failed attempt]

Please try a different approach or fix the issue described above.

[Full prompt from Step 4 including PROJECT GUIDELINES]
"
```

### If Task fails (second attempt):

1. Mark with detailed failure:

```bash
$AIMI_CLI mark-failed [STORY_ID] "Failed after 2 attempts: [error]"
```

2. Ask user with clear options:

```
Story [STORY_ID] failed after 2 attempts.

Error: [error summary]

Options:
- **skip** - Mark as skipped and continue to next story
- **retry [guidance]** - Try again with your guidance
- **stop** - Halt execution to investigate manually

What would you like to do?
```

## Step 6: Handle User Response

### If user says "skip":

```bash
$AIMI_CLI mark-skipped [STORY_ID]
```

Report: "Skipped [STORY_ID]. Run /aimi:next for the next story."

### If user says "retry [guidance]":

Spawn another Task with user's guidance included in prompt. Continue from Step 5.

### If user says "stop":

Report: "Execution stopped. Review the error and run /aimi:next when ready."
STOP execution.

## Resuming After /clear

If you need to check the current story after a `/clear`:

```bash
$AIMI_CLI current-story
```

Returns the story that was in progress, or `null` if none.
