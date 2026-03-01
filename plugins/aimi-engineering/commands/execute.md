---
name: aimi:execute
description: Execute all pending stories autonomously with wave-based parallelism
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash(git:*), Bash(AIMI_CLI=*), Bash($AIMI_CLI:*), Bash(WORKTREE_MGR=*), Bash($WORKTREE_MGR:*), Task
---

# Aimi Execute

Execute all pending stories autonomously using wave-based fan-out.

Each wave collects all ready stories. Single-story waves run inline (no worktree overhead). Multi-story waves spawn N foreground Tasks in one tool-call turn with worktrees, wait for all results, then merge.

## Step 0: Resolve CLI Path

**CRITICAL:** The CLI script lives in the plugin install directory, NOT the project directory. Resolve it first:

```bash
# Glob always finds the latest installed version
AIMI_CLI=$(ls ~/.claude/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1)
# Fallback to cached cli-path if glob found nothing (edge case)
if [ -z "$AIMI_CLI" ] && [ -f .aimi/cli-path ] && [ -x "$(cat .aimi/cli-path)" ]; then
  AIMI_CLI=$(cat .aimi/cli-path)
fi
```

If empty, report: "aimi-cli.sh not found. Reinstall plugin: `/plugin install aimi-engineering`" and STOP.

**Use `$AIMI_CLI` for ALL subsequent script calls in this command.**

## Step 1: Initialize Session

**CRITICAL:** Use the CLI script to initialize session and get metadata. Do NOT interpret jq queries directly.

```bash
$AIMI_CLI init-session
```

This returns:
```json
{
  "tasks": ".aimi/tasks/2026-02-24-feature-tasks.json",
  "branch": "feat/feature-name",
  "pending": 7
}
```

If no tasks file found, the script exits with error. Report:
```
No tasks file found. Run /aimi:plan to create a task list first.
```
STOP execution.

### Orphaned Story Recovery

Check for and reset stories stuck in `in_progress` status (from interrupted previous runs):

```bash
$AIMI_CLI reset-orphaned
```

This atomically marks all `in_progress` stories as `failed` and returns:
```json
{"count": 2, "reset": ["US-003", "US-005"]}
```

If count > 0, report: "Recovered [count] orphaned in_progress stories (reset to failed for retry): [reset IDs]"

Note: These stories will appear as "failed" in status. The user can review and re-run.

### Content Validation

```bash
$AIMI_CLI validate-stories
```

If validation fails (exit non-zero), report the errors and STOP:
```
Story content validation failed:
[error output]

Review the stories for suspicious content and fix before execution.
```

## Step 2: Branch Setup

Get the branch name from the init-session output (already validated by CLI).

### Check Current Branch

```bash
current_branch=$(git branch --show-current)
```

### If already on correct branch:
Proceed to Step 3.

### If on different branch:
Check if target branch exists:
```bash
git branch --list [branchName]
```

- If exists: `git checkout [branchName]`
- If not exists: `git checkout -b [branchName]`

Report:
```
Switched to branch: [branchName]
```

## Step 3: Check for Pending Stories

```bash
$AIMI_CLI count-pending
```

If result is `0`:
```
All stories already complete!

Run /aimi:review to review the implementation.
```
STOP execution.

### Validate Dependencies

```bash
$AIMI_CLI validate-deps
```

If validation fails (non-zero exit), report the error and STOP:
```
Dependency validation failed:
[error output]

Fix the dependency graph in the tasks file and re-run /aimi:execute.
```

Report start:
```
Starting autonomous execution...

Branch: [branchName]
Schema: v3.0
Pending: [pending] stories

Beginning wave execution loop...
```

## Step 3.1: Resolve Worktree Manager

```bash
WORKTREE_MGR=$(ls ~/.claude/plugins/cache/*/aimi-engineering/*/skills/git-worktree/scripts/worktree-manager.sh 2>/dev/null | tail -1)
```

If empty, report:
```
worktree-manager.sh not found. Reinstall plugin: `/plugin install aimi-engineering`
```
STOP execution.

## Step 3.2: Read Concurrency Setting

Read the tasks file metadata to get maxConcurrency:

```bash
$AIMI_CLI init-session
```

Parse `maxConcurrency` from metadata. If not set, default to `4`.

Store as `MAX_CONCURRENCY`.

## Step 3.3: Load Project Guidelines

Load project guidelines following the discovery order defined in `story-executor/SKILL.md` "PROJECT GUIDELINES" section:

1. **CLAUDE.md** (project root) - Primary project instructions
2. **AGENTS.md** (any directory) - Module-specific patterns
3. **Aimi defaults** from story-executor - Fallback if neither exists

Read these files and store the content as `PROJECT_GUIDELINES`.

## Step 4: Wave Execution Loop

```
wave = 1

while true:
    # Check remaining work
    pending = $AIMI_CLI count-pending
    if pending == 0: break

    # Get ready stories
    ready_stories = $AIMI_CLI list-ready
    if ready_stories is empty:
        if pending > 0:
            Report: "Deadlock detected: [pending] stories pending but none are ready."
            Report: "This may indicate circular dependencies or all remaining stories depend on failed/skipped stories."
            Break loop (proceed to completion)
        else:
            break

    # Adaptive concurrency
    concurrency = min(len(ready_stories), MAX_CONCURRENCY)
    selected_stories = ready_stories[0:concurrency]

    Report:
    "--- Wave [wave] ---"
    "Executing [len(selected_stories)] stories"
    For each story: "  - [story.id]: [story.title]"

    # Mark all selected stories as in-progress
    for story in selected_stories:
        $AIMI_CLI mark-in-progress [story.id]

    # ========================================
    # SINGLE-STORY WAVE (no worktree overhead)
    # ========================================
    if len(selected_stories) == 1:
        story = selected_stories[0]

        # Spawn a single foreground Task — same pattern as next.md
        # No worktree, worker operates in current directory
        Task(
            subagent_type: "general-purpose",
            description: "Execute [story.id]: [story.title]",
            prompt: [story-executor SKILL.md prompt template with:
                - PROJECT_GUIDELINES = PROJECT_GUIDELINES
                - STORY_ID = story.id
                - STORY_TITLE = story.title
                - STORY_DESCRIPTION = story.description
                - ACCEPTANCE_CRITERIA = story.acceptanceCriteria (bulleted)
                - story.notes = story.notes (include PREVIOUS NOTES section only if non-empty)
                - No WORKTREE_PATH (sequential — worker operates in current directory)
            ]
        )

        # Handle result
        if Task succeeded:
            $AIMI_CLI mark-complete [story.id]
            Report: "[story.id] completed."
        else:
            $AIMI_CLI mark-failed [story.id] "Failed during wave [wave]"
            $AIMI_CLI cascade-skip [story.id]
            Report: "[story.id] failed. Dependent stories cascade-skipped."

        Report: "Wave [wave] complete."
        wave += 1
        continue

    # ========================================
    # MULTI-STORY WAVE (parallel with worktrees)
    # ========================================

    worktree_names = []

    for story in selected_stories:
        worktree_name = "aimi-[story.id]"
        worktree_names.append(worktree_name)

        # Create worktree from current feature branch
        $WORKTREE_MGR create [worktree_name] --from [branchName]

        # Get the worktree path from the create output
        worktree_path = [path from output]

    # Spawn ALL workers as foreground Tasks in a SINGLE tool-call turn.
    # Claude Code runs multiple foreground Tasks concurrently and returns
    # all results before the agent's turn ends.
    #
    # In one tool-call turn, emit N Task calls:
    for story in selected_stories:
        worktree_name = "aimi-[story.id]"
        worktree_path = [worktree path for this story]

        Task(
            subagent_type: "general-purpose",
            description: "Execute [story.id]: [story.title]",
            prompt: [story-executor SKILL.md prompt template with:
                - WORKTREE_PATH = worktree_path
                - PROJECT_GUIDELINES = PROJECT_GUIDELINES
                - STORY_ID = story.id
                - STORY_TITLE = story.title
                - STORY_DESCRIPTION = story.description
                - ACCEPTANCE_CRITERIA = story.acceptanceCriteria (bulleted)
                - story.notes = story.notes (include PREVIOUS NOTES section only if non-empty)
                - Do NOT modify the tasks.json file — report result (success/failure + details)
            ]
        )

    # All Tasks return in the same turn. Collect results.
    failed_stories = []
    succeeded_stories = []

    for each Task result:
        if Task succeeded:
            succeeded_stories.append(story)
        else:
            failed_stories.append(story)

    # --- Post-Wave Processing ---

    # Handle failures first
    for story in failed_stories:
        $AIMI_CLI mark-failed [story.id] "Failed during parallel wave [wave]"
        $AIMI_CLI cascade-skip [story.id]
        Report: "[story.id] failed. Dependent stories cascade-skipped."

    # Merge all successful worktrees using merge-all
    if len(succeeded_stories) > 0:
        succeeded_worktree_names = ["aimi-[story.id]" for story in succeeded_stories]

        merge_result = $WORKTREE_MGR merge-all [succeeded_worktree_names...] --into [branchName]

        if merge conflict (non-zero exit):
            Report:
            "MERGE CONFLICT during wave [wave] merge."
            "Conflicting files:"
            "[conflict output from merge-all]"
            ""
            "Resolve the conflict on branch [branchName] and re-run `/aimi:execute` to continue."

            # Cleanup all worktrees from this wave before stopping
            for wt in worktree_names:
                $WORKTREE_MGR remove [wt]

            STOP execution.

        # All merges succeeded — mark stories complete
        for story in succeeded_stories:
            $AIMI_CLI mark-complete [story.id]
            Report: "[story.id] merged successfully."

    # Remove all worktrees from this wave
    for wt in worktree_names:
        $WORKTREE_MGR remove [wt]

    Report: "Wave [wave] complete: [len(succeeded_stories)] succeeded, [len(failed_stories)] failed"
    wave += 1
```

### Post-Loop Cleanup

After the wave loop ends (all stories processed or deadlock):

```
# Remove any remaining worktrees (safety cleanup)
$WORKTREE_MGR list
# For each worktree matching "aimi-US-*":
$WORKTREE_MGR remove [worktree_name]
```

## Step 5: Completion

When execution ends (all stories complete, or deadlock detected):

### If all stories complete:

Count commits on this branch:
```bash
git log --oneline main..HEAD | wc -l
```

```
## Execution Complete

All stories completed successfully!

Branch: [branchName]
Waves: [total_waves]
Commits: [count]

### Next Steps

- Review commits: `git log --oneline -[count]`
- Run `/aimi:review` for code review
- Create PR when ready: `gh pr create`
```

### If deadlock detected:

```
## Execution Stopped - Deadlock

[N] stories remain pending but none are ready for execution.
This may be caused by failed stories whose dependents were cascade-skipped.

Run `/aimi:status` to see the dependency state.
Review failed stories and either retry or adjust dependencies.
```

## Resuming Execution

The tasks file preserves all state. Re-running `/aimi:execute` will:

1. Detect the schema version again
2. Skip completed stories automatically
3. Pick up from the next ready wave
4. Failed stories remain as "failed" -- use `/aimi:status` to review them

### After /clear

If context was cleared (via `/clear`), the CLI maintains state:

```bash
$AIMI_CLI get-state
```

Returns:
```json
{
  "tasks": ".aimi/tasks/...",
  "branch": "feat/...",
  "story": null,
  "last": "success"
}
```

- If `story` is set, there's an interrupted story
- If `last` is "success", continue with next story
- If `last` is "failed", ask user how to proceed

## Error Recovery

If execution is interrupted unexpectedly:

1. Tasks file preserves state (completed stories stay completed, in-progress stories can be retried)
2. State files in `.aimi/` track current position
3. User can run `/aimi:execute` again to resume
4. Orphaned worktrees are cleaned up on next run (safety cleanup in Post-Loop Cleanup)

The loop will automatically skip completed stories and continue from the next pending/ready one.
