---
name: aimi:next
description: Execute the next pending story from tasks.json
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash(git:*), Bash(jq:*), Bash(grep:*), Bash(cat:*), Bash(npm:*), Bash(bun:*), Bash(yarn:*), Bash(pnpm:*), Bash(npx:*), Bash(tsc:*), Bash(eslint:*), Bash(prettier:*), Task
---

# Aimi Next

Execute the next pending story using a Task-spawned agent.

## Step 1: Find Next Story (via jq)

**CRITICAL:** Do NOT read the full tasks.json. Use `jq` to extract ONLY the next pending story.

```bash
# Extract only the next pending story (lowest priority, passes=false, not skipped)
jq '[.userStories[] | select(.passes == false and .skipped != true)] | sort_by(.priority) | .[0]' docs/tasks/tasks.json
```

This loads only ONE story into memory, not all 10+.

**Filter criteria:**
- `passes == false` - not completed
- `skipped != true` - not skipped by user

### Check if any pending stories exist:

```bash
# Get count of pending stories
jq '[.userStories[] | select(.passes == false)] | length' docs/tasks/tasks.json
```

If result is `0`:
```
All stories complete! Run /aimi:review to review the implementation.
```
STOP execution.

### Get total counts for status display:

```bash
jq '{
  pending: [.userStories[] | select(.passes == false)] | length,
  total: .userStories | length
}' docs/tasks/tasks.json
```

## Step 2: Validate Required Fields

**CRITICAL:** Before execution, validate the story has all required task-specific fields.

Required fields:
- `taskType` (string, snake_case)
- `steps` (array, 1-10 items)
- `relevantFiles` (array)
- `patternsToFollow` (string)

### If any field is missing:

```
Error: Story [STORY_ID] missing required fields for task-specific execution.

Missing: [list missing fields]

This tasks.json was created before task-specific step injection was implemented.
Please regenerate with: /aimi:plan-to-tasks [plan-file-path]
```

STOP execution.

## Step 3: Extract Codebase Patterns

Read `docs/tasks/progress.md` and extract ONLY the "Codebase Patterns" section.

This avoids passing the full progress history to the agent (performance optimization).

## Step 4: Build Inline Prompt (Performance Optimization)

**CRITICAL:** Pass story data INLINE to the Task agent. Do NOT tell the agent to re-read tasks.json.

Build the prompt with all story data embedded, using task-specific steps:

```
Task general-purpose: "Execute [STORY_ID]: [STORY_TITLE]

## STORY DATA

ID: [STORY_ID]
Title: [STORY_TITLE]
Description: [STORY_DESCRIPTION]
Type: [TASK_TYPE]

## ACCEPTANCE CRITERIA

- [criterion 1]
- [criterion 2]
- [criterion N]

## STEPS (follow these in order)

1. [step 1 from story.steps]
2. [step 2 from story.steps]
3. [step 3 from story.steps]
...
[all steps from story.steps array]

## RELEVANT FILES (read these first)

- [file 1 from story.relevantFiles]
- [file 2 from story.relevantFiles]
...
[If empty: "No specific files - explore codebase to understand patterns"]

## PATTERNS TO FOLLOW

[If patternsToFollow != "none": "See: [patternsToFollow] for conventions and gotchas"]
[If patternsToFollow == "none": "No specific patterns - use codebase conventions"]

## CODEBASE PATTERNS (from progress.md)

[paste extracted patterns here, or "No patterns discovered yet" if empty]

## ON COMPLETION

1. Verify ALL acceptance criteria are satisfied
2. Run quality checks (typecheck, lint, tests as appropriate)
3. Commit with message: 'feat: [STORY_ID] - [STORY_TITLE]'
4. Update tasks.json: Set passes: true for story [STORY_ID]
5. Append progress entry to docs/tasks/progress.md
6. If you discovered important patterns, add to Codebase Patterns section

## ON FAILURE

Do NOT mark passes: true. Update tasks.json with:
- passes: false
- notes: 'Failed: [detailed error]'
- attempts: [increment]
- lastAttempt: [timestamp]
- error: { type, message, file, line, suggestion }

Return with clear failure report.
"
```

## Step 5: Handle Result

### If Task succeeds:

**Step 5a: Verify tasks.json updated**

```bash
jq '.userStories[] | select(.id == "[STORY_ID]") | .passes' docs/tasks/tasks.json
```

If not `true`, update it:
```bash
jq '(.userStories[] | select(.id == "[STORY_ID]")) |= . + {passes: true}' docs/tasks/tasks.json > tmp.json && mv tmp.json docs/tasks/tasks.json
```

**Step 5b: Ensure progress.md was appended**

Check if progress entry exists for this story:
```bash
grep -q "## [STORY_ID]" docs/tasks/progress.md
```

If NOT found, append the progress entry:

```bash
cat >> docs/tasks/progress.md << 'EOF'

---

## [STORY_ID] - [STORY_TITLE]

**Completed:** [ISO 8601 timestamp]
**Status:** Completed by Task agent

**What was implemented:**
- Story completed successfully

**Files changed:**
- (see git diff)
EOF
```

**Step 5c: Report**

```
[STORY_ID] - [STORY_TITLE] completed successfully.

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

[Full prompt from Step 4]
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

## Step 6: Handle User Response

### If user says "skip":

Update tasks.json for this story using `jq`:

```bash
# Mark story as skipped (prevents infinite loop)
jq '(.userStories[] | select(.id == "[STORY_ID]")) |= . + {skipped: true, notes: "Skipped by user after failed attempts"}' docs/tasks/tasks.json > tmp.json && mv tmp.json docs/tasks/tasks.json
```

Report: "Skipped [STORY_ID]. Run /aimi:next for the next story."

### If user says "retry [guidance]":
- Spawn another Task with user's guidance included in prompt
- Continue from Step 5

### If user says "stop":
- Report: "Execution stopped. Review the error and run /aimi:next when ready."
- STOP execution

## Step 7: Update State

After any outcome, ensure tasks.json reflects:
- `attempts`: Total attempt count
- `lastAttempt`: Timestamp of most recent attempt
- `notes`: Current status or error information
