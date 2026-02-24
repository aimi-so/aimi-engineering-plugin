# Brainstorm: Aimi CLI Script

**Date:** 2026-02-24

## Problem

The AI can hallucinate when interpreting bash commands embedded in markdown command files. Specific failure modes include:

- Variable substitution errors (incorrect `$TASKS_FILE` or `[STORY_ID]` interpolation)
- Command sequence errors (wrong order or skipped steps)
- jq query modifications (changing queries instead of running as documented)
- Path/filename errors (wrong paths or hardcoded values)

Additionally, context accumulates across stories, leading to slower execution and potential confusion.

## What We're Building

A single `aimi-cli.sh` bash script that handles all deterministic task file operations. Commands call this script instead of interpreting jq queries directly.

**Key workflow change:** Execute one story at a time with `/clear` between stories to reset context.

## Why This Approach

**Single CLI Script** was chosen over alternatives:

| Approach | Pros | Cons | Decision |
|----------|------|------|----------|
| Single CLI | One file, consistent interface, easy to test | Larger file | **Selected** |
| Individual scripts | Small focused files | More files to maintain | Rejected |
| Node/Python module | Type safety, better testing | Adds dependency | Rejected |

Key reasons:
- Bash is universal (no additional dependencies except jq)
- Single file is easier to maintain and update
- All jq queries in one place ensures consistency
- Can test independently without Claude Code

## Key Decisions

1. **Script location:** `scripts/aimi-cli.sh`
2. **Interface:** Subcommand pattern (`aimi-cli.sh <command> [args]`)
3. **Output format:** JSON for machine parsing, human-readable summaries for display commands
4. **Error handling:** Exit codes (0=success, 1=error) with stderr for error messages
5. **State files:** Store current working context in `.aimi/` directory

## State Management

Store current execution context in `.aimi/` directory:

```
.aimi/
├── current-tasks    # Path to active tasks file
├── current-branch   # Current working branch name
├── current-story    # ID of story being executed (e.g., US-001)
└── last-result      # Result of last story execution (success/failed/skipped)
```

**Benefits:**
- Resume after `/clear` - script reads state files to know where we are
- Track progress across context resets
- Debug visibility into current execution state

## Execution Flow (Story-by-Story)

```
User runs: /aimi:execute

1. aimi-cli.sh init-session
   - Find tasks file, save to .aimi/current-tasks
   - Get branchName, save to .aimi/current-branch
   - Checkout/create branch

2. aimi-cli.sh next-story
   - Get next pending story
   - Save story ID to .aimi/current-story
   - Output story JSON for Task agent

3. Execute story via Task agent

4. aimi-cli.sh mark-complete US-001
   - Update tasks file
   - Clear .aimi/current-story
   - Save "success" to .aimi/last-result

5. User runs /clear (resets AI context)

6. User runs /aimi:next (or /aimi:execute continues)
   - Script reads .aimi/current-tasks to resume
   - Repeat from step 2
```

## Commands

| Command | Description | Output |
|---------|-------------|--------|
| `init-session` | Initialize execution session, save state | Session info |
| `find-tasks` | Find most recent tasks file | Path to file or error |
| `status` | Get status summary | JSON with counts and story lists |
| `metadata` | Get metadata only | JSON metadata object |
| `next-story` | Get next pending story, save to state | JSON story object |
| `current-story` | Get currently active story from state | JSON story object |
| `mark-complete <id>` | Mark story as passed, clear current | Updated JSON |
| `mark-failed <id> <notes>` | Mark story with failure notes | Updated JSON |
| `mark-skipped <id>` | Mark story as skipped | Updated JSON |
| `count-pending` | Count pending stories | Number |
| `get-branch` | Get branchName from metadata | String |
| `get-state` | Get all state files as JSON | State object |
| `clear-state` | Clear all state files | - |

## Example Workflow

```bash
# Initialize session
./scripts/aimi-cli.sh init-session
# Output: { "tasks": "docs/tasks/2026-02-24-auth-tasks.json", "branch": "feat/auth", "pending": 5 }

# Get next story (also saves to .aimi/current-story)
./scripts/aimi-cli.sh next-story
# Output: { "id": "US-001", "title": "Add user schema", ... }

# After Task agent completes
./scripts/aimi-cli.sh mark-complete US-001

# Check what we're working on (after /clear)
./scripts/aimi-cli.sh get-state
# Output: { "tasks": "...", "branch": "feat/auth", "story": null, "last": "success" }

# Get next story
./scripts/aimi-cli.sh next-story
# Output: { "id": "US-002", ... }
```

## Open Questions

1. Should the script auto-discover the tasks file or require it as argument?
   - **Decision:** Auto-discover, but cache in `.aimi/current-tasks` for consistency

2. How to handle concurrent access?
   - **Decision:** Use temp file + mv pattern (atomic on most filesystems)

3. Should `.aimi/` be gitignored?
   - **Decision:** Yes, it's local execution state

## Next Steps

Run `/workflows:plan` to create implementation plan with detailed script structure.
