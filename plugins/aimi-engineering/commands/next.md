---
name: aimi:next
description: Execute the next pending story from tasks.json
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash(git:*), Bash(npm:*), Bash(bun:*), Bash(yarn:*), Bash(pnpm:*), Bash(npx:*), Bash(tsc:*), Bash(eslint:*), Bash(prettier:*), Task
---

# Aimi Next

Execute the next pending story using a Task-spawned agent.

## Step 1: Find Next Story

Read `docs/tasks/tasks.json`.

Find the story with:
- Lowest priority value
- Where `passes === false`

If no pending stories found:
```
All stories complete! (X/X)

Run /aimi:review to review the implementation.
```
STOP execution.

## Step 2: Extract Codebase Patterns

Read `docs/tasks/progress.md` and extract ONLY the "Codebase Patterns" section.

This avoids passing the full progress history to the agent (performance optimization).

## Step 3: Build Inline Prompt (Performance Optimization)

**CRITICAL:** Pass story data INLINE to the Task agent. Do NOT tell the agent to re-read tasks.json.

Build the prompt with all story data embedded:

```
Task general-purpose: "Execute [STORY_ID]: [STORY_TITLE]

## INLINE STORY DATA (do not read tasks.json)

ID: [STORY_ID]
Title: [STORY_TITLE]
Description: [STORY_DESCRIPTION]

Acceptance Criteria:
- [criterion 1]
- [criterion 2]
- [criterion N]

## CODEBASE PATTERNS (extracted from progress.md)

[paste extracted patterns here, or "No patterns discovered yet" if empty]

## EXECUTION FLOW

1. Read codebase to understand existing patterns
2. Implement changes to satisfy ALL acceptance criteria above
3. Run quality checks (typecheck, lint, tests as appropriate)
4. If checks FAIL: Update tasks.json with error details, return failure
5. If checks PASS: Commit with message 'feat: [STORY_ID] - [STORY_TITLE]'
6. Update tasks.json: Set passes: true for story [STORY_ID]
7. Append progress entry to docs/tasks/progress.md
8. If you discovered important patterns, add to Codebase Patterns section

## ON FAILURE

Do NOT mark passes: true. Update tasks.json with:
- passes: false
- notes: 'Failed: [detailed error]'
- attempts: [increment]
- lastAttempt: [timestamp]

Return with clear failure report.
"
```

## Step 4: Handle Result

### If Task succeeds:

Verify:
1. `docs/tasks/tasks.json` was updated (story has `passes: true`)
2. `docs/tasks/progress.md` was appended with progress entry

Report:
```
✓ [STORY_ID] - [STORY_TITLE] completed successfully.

Files changed: [from progress entry]

Run /aimi:next for the next story.
Run /aimi:status to see overall progress.
```

### If Task fails (first attempt):

1. Read tasks.json and update the story:
   - Increment `attempts`
   - Set `lastAttempt` to current timestamp
   - Add error details to `notes`

2. RETRY automatically with error context:

```
Task general-purpose: "RETRY: Execute [STORY_ID]: [STORY_TITLE]

PREVIOUS ATTEMPT FAILED with:
[error details from failed attempt]

Please try a different approach or fix the issue described above.

[Full story-executor prompt]
"
```

### If Task fails (second attempt):

1. Update tasks.json with failure details

2. Ask user with clear options:

```
Story [STORY_ID] failed after 2 attempts.

Error: [error summary]

Options:
- **Skip**: Type "skip" to mark as skipped and continue to next story
- **Retry**: Type "retry" with guidance to try again
- **Stop**: Type "stop" to halt execution and investigate manually

What would you like to do?
```

## Step 5: Handle User Response

### If user says "skip":
- Update tasks.json notes: "Skipped by user after 2 failed attempts"
- Report: "Skipped [STORY_ID]. Run /aimi:next for the next story."

### If user says "retry [guidance]":
- Spawn another Task with user's guidance included in prompt
- Continue from Step 4

### If user says "stop":
- Report: "Execution stopped. Review the error and run /aimi:next when ready."
- STOP execution

## Step 6: Update State

After any outcome, ensure tasks.json reflects:
- `attempts`: Total attempt count
- `lastAttempt`: Timestamp of most recent attempt
- `notes`: Current status or error information
