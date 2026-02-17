---
name: aimi:next
description: Execute the next pending story from tasks.json
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash(git:*), Bash(jq:*), Bash(npm:*), Bash(bun:*), Bash(yarn:*), Bash(pnpm:*), Bash(npx:*), Bash(tsc:*), Bash(eslint:*), Bash(prettier:*), Task
---

# Aimi Next

Execute the next pending story using a Task-spawned agent.

## Step 1: Find Next Story (via jq)

**CRITICAL:** Do NOT read the full tasks.json. Use `jq` to extract ONLY the next pending story.

```bash
# Extract the next pending story (lowest priority, passes=false, not skipped)
jq '[.userStories[] | select(.passes == false and .skipped != true)] | sort_by(.priority) | .[0]' docs/tasks/tasks.json
```

This loads only ONE story into memory, not all stories.

**Filter criteria:**
- `passes == false` - not completed
- `skipped != true` - not skipped by user
- Sort by `priority` - execute in dependency order

### Check if any pending stories exist:

```bash
# Get count of pending stories
jq '[.userStories[] | select(.passes == false and .skipped != true)] | length' docs/tasks/tasks.json
```

If result is `0`:
```
All stories complete! Run /aimi:review to review the implementation.
```
STOP execution.

### Get total counts for status display:

```bash
jq '{
  pending: [.userStories[] | select(.passes == false and .skipped != true)] | length,
  completed: [.userStories[] | select(.passes == true)] | length,
  skipped: [.userStories[] | select(.skipped == true)] | length,
  total: .userStories | length
}' docs/tasks/tasks.json
```

## Step 2: Load Project Guidelines

**BEFORE building the prompt, load project guidelines to inject into the Task agent.**

### Discovery Order:

1. **CLAUDE.md** (project root) - Primary project instructions
2. **AGENTS.md** (any directory) - Module-specific patterns
3. **Aimi defaults** - Fallback if neither exists

### Load Guidelines:

```bash
# Check for CLAUDE.md
if [ -f "CLAUDE.md" ]; then
  GUIDELINES=$(cat CLAUDE.md)
elif [ -f ".claude/CLAUDE.md" ]; then
  GUIDELINES=$(cat .claude/CLAUDE.md)
fi

# Check for AGENTS.md (optional, module-specific)
if [ -f "AGENTS.md" ]; then
  AGENTS_GUIDELINES=$(cat AGENTS.md)
fi
```

### Aimi Default Rules (fallback):

If no CLAUDE.md or AGENTS.md found, use these defaults:

```markdown
## Aimi Default Rules

### Commit Format
- Format: `<type>: <story-id> - <description>`
- Types: feat, fix, refactor, docs, test, chore
- Max 72 chars, imperative mood, no trailing period

### Quality Checks
- Run typecheck before committing
- Run lint if available
- Run tests if relevant to changes

### On Failure
- Do NOT commit if checks fail
- Update story notes with error details
- Report the failure clearly
```

## Step 3: Display Current Story

Show what's being executed:

```
Executing: [STORY_ID] - [STORY_TITLE]
Priority: [priority] | Pending: [count] remaining

Acceptance Criteria:
- [criterion 1]
- [criterion 2]
...
```

## Step 4: Build Inline Prompt

**CRITICAL:** Pass story data AND project guidelines INLINE to the Task agent.

```
Task general-purpose: "Execute [STORY_ID]: [STORY_TITLE]

## PROJECT GUIDELINES (MUST FOLLOW)

[GUIDELINES from CLAUDE.md/AGENTS.md or Aimi defaults]

## STORY

ID: [STORY_ID]
Title: [STORY_TITLE]
Description: [STORY_DESCRIPTION]

## ACCEPTANCE CRITERIA

- [criterion 1]
- [criterion 2]
- [criterion N]

## INSTRUCTIONS

1. **FIRST**: Read CLAUDE.md and/or AGENTS.md if they exist for project conventions
2. Read relevant files to understand current state
3. Implement the changes to satisfy ALL acceptance criteria
4. Verify each criterion is met
5. Run quality checks (typecheck, lint, tests as appropriate)
6. Commit with message: 'feat: [STORY_ID] - [STORY_TITLE]'
7. Update docs/tasks/tasks.json: Set passes: true for story [STORY_ID]

## ON FAILURE

Do NOT mark passes: true. Instead:
1. Update tasks.json with notes describing the failure
2. Return with clear failure report including:
   - What failed
   - Error messages
   - Suggested fix

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

**Step 5b: Report success**

```
[STORY_ID] - [STORY_TITLE] completed successfully.

Run /aimi:next for the next story.
Run /aimi:status to see overall progress.
```

### If Task fails (first attempt):

1. Update tasks.json with failure notes:

```bash
jq '(.userStories[] | select(.id == "[STORY_ID]")) |= . + {notes: "Attempt 1 failed: [error summary]"}' docs/tasks/tasks.json > tmp.json && mv tmp.json docs/tasks/tasks.json
```

2. RETRY automatically with error context:

```
Task general-purpose: "RETRY: Execute [STORY_ID]: [STORY_TITLE]

PREVIOUS ATTEMPT FAILED:
[error details from failed attempt]

Please try a different approach or fix the issue described above.

[Full prompt from Step 4 including PROJECT GUIDELINES]
"
```

### If Task fails (second attempt):

1. Update tasks.json with detailed failure:

```bash
jq '(.userStories[] | select(.id == "[STORY_ID]")) |= . + {notes: "Failed after 2 attempts: [error]"}' docs/tasks/tasks.json > tmp.json && mv tmp.json docs/tasks/tasks.json
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
jq '(.userStories[] | select(.id == "[STORY_ID]")) |= . + {skipped: true, notes: "Skipped by user after failed attempts"}' docs/tasks/tasks.json > tmp.json && mv tmp.json docs/tasks/tasks.json
```

Report: "Skipped [STORY_ID]. Run /aimi:next for the next story."

### If user says "retry [guidance]":

Spawn another Task with user's guidance included in prompt. Continue from Step 5.

### If user says "stop":

Report: "Execution stopped. Review the error and run /aimi:next when ready."
STOP execution.
