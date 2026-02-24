---
name: aimi:next
description: Execute the next pending story from tasks.json
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash(git:*), Bash(./scripts/aimi-cli.sh:*), Bash(npm:*), Bash(bun:*), Bash(yarn:*), Bash(pnpm:*), Bash(npx:*), Bash(tsc:*), Bash(eslint:*), Bash(prettier:*), Task
---

# Aimi Next

Execute the next pending story using a Task-spawned agent.

## Step 1: Get Next Story

**CRITICAL:** Use the CLI script to get the next story. Do NOT interpret jq queries directly.

```bash
./scripts/aimi-cli.sh next-story
```

This returns the next pending story as JSON:
```json
{
  "id": "US-001",
  "title": "Add user schema",
  "description": "As a developer, I need...",
  "acceptanceCriteria": ["Criterion 1", "Criterion 2"],
  "priority": 1,
  "passes": false,
  "notes": ""
}
```

If result is `null`:
```
All stories complete! Run /aimi:review to review the implementation.
```
STOP execution.

The CLI also saves the story ID to `.aimi/current-story` for tracking.

## Step 2: Load Project Guidelines

**BEFORE building the prompt, load project guidelines to inject into the Task agent.**

### Discovery Order:

1. **CLAUDE.md** (project root) - Primary project instructions
2. **AGENTS.md** (any directory) - Module-specific patterns
3. **Aimi defaults** - Fallback if neither exists

### Load Guidelines:

Check for CLAUDE.md and AGENTS.md files. Read them if they exist.

### Aimi Default Rules (fallback):

If no CLAUDE.md or AGENTS.md found, use these defaults:

```markdown
## Aimi Default Rules

### Commit Format
- Format: `<type>(<scope>): <description>`
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
Priority: [priority]

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
6. Commit with message: 'feat(scope): [STORY_TITLE]'
7. Report success when done

## ON FAILURE

Do NOT claim success. Instead:
1. Report the failure clearly with:
   - What failed
   - Error messages
   - Suggested fix

"
```

## Step 5: Handle Result

### If Task succeeds:

Mark the story as complete:

```bash
./scripts/aimi-cli.sh mark-complete [STORY_ID]
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
./scripts/aimi-cli.sh mark-failed [STORY_ID] "Attempt 1 failed: [error summary]"
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

1. Mark with detailed failure:

```bash
./scripts/aimi-cli.sh mark-failed [STORY_ID] "Failed after 2 attempts: [error]"
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
./scripts/aimi-cli.sh mark-skipped [STORY_ID]
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
./scripts/aimi-cli.sh current-story
```

Returns the story that was in progress, or `null` if none.
