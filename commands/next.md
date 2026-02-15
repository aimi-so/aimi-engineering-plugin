---
name: aimi:next
description: Execute the next pending story from tasks.json
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash, Task
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

## Step 2: Prepare Story Executor Prompt

Build the prompt using the story-executor skill template.

Include:
- Story ID, title, description
- All acceptance criteria as bullet list
- Full execution instructions

## Step 3: Spawn Task Agent

Spawn a general-purpose Task agent:

```
Task general-purpose: "Execute [STORY_ID]: [STORY_TITLE]

[Full story-executor prompt with story details]
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
