---
name: aimi:execute
description: Execute all pending stories autonomously (sequential or parallel)
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash(git:*), Bash(AIMI_CLI=*), Bash($AIMI_CLI:*), Bash(WORKTREE_MGR=*), Bash($WORKTREE_MGR:*), Task, TeamCreate, TeamDelete, SendMessage
---

# Aimi Execute

Execute all pending stories autonomously with smart execution mode detection.

- **v2.2 schema**: Sequential execution (backward-compatible)
- **v3 schema, linear deps**: Sequential execution (no Team/worktree overhead)
- **v3 schema, parallel opportunities**: Wave-based parallel execution with worktrees

## Step 0: Resolve CLI Path

**CRITICAL:** The CLI script lives in the plugin install directory, NOT the project directory. Resolve it first:

```bash
AIMI_CLI=$(ls ~/.claude/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1)
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

### Detect Schema Version

Immediately after init-session, detect the schema version:

```bash
SCHEMA_VERSION=$($AIMI_CLI detect-schema)
```

Store `SCHEMA_VERSION` for use in Step 3.5.

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

Report start:
```
Starting autonomous execution...

Branch: [branchName]
Schema: v[SCHEMA_VERSION]
Pending: [pending] stories

Beginning execution loop...
```

## Step 3.5: Detect Execution Mode

Based on the schema version detected in Step 1, determine which execution path to follow.

### If SCHEMA_VERSION is "2.2":

Report:
```
Mode: Sequential (v2.2 schema)
```

Proceed to **Step 4a: Sequential Execution**.

### If SCHEMA_VERSION is "3.0":

Check how many stories are immediately ready:

```bash
$AIMI_CLI list-ready
```

Parse the output. Count the number of ready stories.

**If 1 or fewer stories are ready:**

Report:
```
Mode: Sequential (v3 linear dependency chain)
```

Proceed to **Step 4a: Sequential Execution**.

**If 2 or more stories are ready:**

Report:
```
Mode: Parallel (v3 with parallel opportunities detected)
```

Proceed to **Step 4b: Parallel Execution**.

---

## Step 4a: Sequential Execution

This path handles both v2.2 (using next-story) and v3 linear chains (using list-ready).

### For v2.2 Schema:

```
while (pending stories exist):
    1. Call /aimi:next (loads ONLY the next pending story by priority)

    2. Check result:
       - If success: continue to next iteration
       - If user chose "skip": continue to next iteration
       - If user chose "stop": break loop

    3. Check pending count:
       $AIMI_CLI count-pending
       - If 0: exit loop
```

### For v3 Schema (linear):

```
while (pending stories exist):
    1. Get next ready story:
       ready_json=$($AIMI_CLI list-ready)
       Parse the first story from the list.

    2. If no stories ready but pending > 0:
       Report deadlock: "No stories are ready but [N] are still pending. Check dependency graph."
       STOP execution.

    3. Mark story as in-progress:
       $AIMI_CLI mark-in-progress [STORY_ID]

    4. Call /aimi:next to execute the story
       (next-story for v3 uses list-ready logic internally)

    5. Check result:
       - If success:
           $AIMI_CLI mark-complete [STORY_ID]
           Continue to next iteration
       - If user chose "skip":
           $AIMI_CLI cascade-skip [STORY_ID]
           Continue to next iteration
       - If user chose "stop": break loop

    6. Check pending count:
       $AIMI_CLI count-pending
       - If 0: exit loop
```

After the loop ends, proceed to **Step 5: Completion**.

---

## Step 4b: Parallel Execution

This path is used only for v3 schemas where multiple independent stories can run concurrently.

### 4b.1: Validate Dependencies

```bash
$AIMI_CLI validate-deps
```

If validation fails (non-zero exit), report the error and STOP:
```
Dependency validation failed:
[error output]

Fix the dependency graph in the tasks file and re-run /aimi:execute.
```

### 4b.2: Resolve Worktree Manager

```bash
WORKTREE_MGR=$(ls ~/.claude/plugins/cache/*/aimi-engineering/*/skills/git-worktree/scripts/worktree-manager.sh 2>/dev/null | tail -1)
```

If empty, report:
```
worktree-manager.sh not found. Reinstall plugin: `/plugin install aimi-engineering`
```
STOP execution.

### 4b.3: Read Concurrency Setting

Read the tasks file metadata to get maxConcurrency:

```bash
$AIMI_CLI init-session
```

Parse `maxConcurrency` from metadata. If not set, default to `4`.

Store as `MAX_CONCURRENCY`.

### 4b.4: Load Project Guidelines

Before starting the wave loop, load project guidelines that will be injected into worker prompts.

**Discovery Order:**

1. **CLAUDE.md** (project root) - Primary project instructions
2. **AGENTS.md** (any directory) - Module-specific patterns
3. **Aimi defaults** - Fallback if neither exists

Read these files and store the content as `PROJECT_GUIDELINES`.

### 4b.5: Create Team

```
TeamCreate with:
  team_name: "aimi-execute"
  description: "Parallel execution of stories from [tasks file name]"
```

### 4b.6: Wave Execution Loop

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
            Break loop (proceed to cleanup)
        else:
            break

    # Adaptive concurrency
    concurrency = min(len(ready_stories), MAX_CONCURRENCY)
    selected_stories = ready_stories[0:concurrency]

    Report:
    "--- Wave [wave] ---"
    "Executing [len(selected_stories)] stories in parallel (max concurrency: [MAX_CONCURRENCY])"
    For each story: "  - [story.id]: [story.title]"

    # Mark all selected stories as in-progress
    for story in selected_stories:
        $AIMI_CLI mark-in-progress [story.id]

    # Create worktrees and spawn workers
    worker_names = []
    worktree_names = []

    for story in selected_stories:
        worktree_name = "aimi-[story.id]"
        worktree_names.append(worktree_name)

        # Create worktree from current feature branch
        $WORKTREE_MGR create [worktree_name] --from [branchName]

        # Get the worktree path from the create output
        # worktree-manager.sh prints the path on creation
        worktree_path = [path from output]

        worker_name = "worker-[story.id]"
        worker_names.append(worker_name)

        # Spawn worker as Task teammate
        Task(
            subagent_type: "general-purpose",
            team_name: "aimi-execute",
            name: worker_name,
            description: "Execute [story.id]: [story.title]",
            prompt: "You are a parallel execution worker in a Team.

## YOUR WORKTREE

You MUST work inside this worktree directory:
[worktree_path]

All file operations, git commands, and code changes must happen within this path.
cd to this path before starting any work.

## PROJECT GUIDELINES (MUST FOLLOW)

[PROJECT_GUIDELINES]

## STORY

ID: [story.id]
Title: [story.title]
Description: [story.description]

## ACCEPTANCE CRITERIA

- [criterion 1]
- [criterion 2]
- [criterion N]

## INSTRUCTIONS

1. cd to your worktree path: [worktree_path]
2. Read CLAUDE.md and/or AGENTS.md if they exist for project conventions
3. Read relevant files to understand current state
4. Implement the changes to satisfy ALL acceptance criteria
5. Verify each criterion is met
6. Run quality checks (typecheck, lint, tests as appropriate)
7. Commit with message: 'feat(scope): [story.title]'
8. Send a message to the team leader reporting success or failure

## IMPORTANT

- Do NOT modify the tasks.json file directly. The leader handles task status updates.
- Do NOT leave the worktree directory for file operations.
- When done, send a message with: SUCCESS or FAILURE and any relevant details.

## ON FAILURE

Do NOT claim success. Instead send a message with:
- FAILURE
- What failed
- Error messages
- Suggested fix
",
            run_in_background: true
        )

    # Wait for all workers in this wave to complete
    # Workers send messages when done (SUCCESS or FAILURE)
    # Track completion count
    completed = 0
    failed_stories = []
    succeeded_stories = []
    total = len(selected_stories)

    # As each worker message arrives:
    for each worker message received:
        completed += 1

        Report: "Wave [wave]: [completed]/[total] workers reported"

        if worker reports SUCCESS:
            succeeded_stories.append(story)
        else if worker reports FAILURE:
            failed_stories.append(story)

    # --- Post-Wave Processing ---

    # Handle failures first
    for story in failed_stories:
        $AIMI_CLI mark-failed [story.id] "Failed during parallel wave [wave]"
        $AIMI_CLI cascade-skip [story.id]
        Report: "[story.id] failed. Dependent stories cascade-skipped."

    # Merge successful worktrees sequentially
    for story in succeeded_stories:
        worktree_name = "aimi-[story.id]"

        # Merge worktree branch into feature branch
        merge_result = $WORKTREE_MGR merge [worktree_name] --into [branchName]

        if merge conflict (non-zero exit):
            Report:
            "MERGE CONFLICT merging [worktree_name] into [branchName]"
            "Conflicting files:"
            "[conflict output]"
            ""
            "Resolve the conflict manually and re-run /aimi:execute to continue."

            # Cleanup: remove all worktrees from this wave
            for wt in worktree_names:
                $WORKTREE_MGR remove [wt]

            # Shutdown team
            for worker in worker_names:
                SendMessage type: "shutdown_request", recipient: worker
            TeamDelete

            STOP execution.

        # Mark complete after successful merge
        $AIMI_CLI mark-complete [story.id]
        Report: "[story.id] merged successfully."

    # Remove all worktrees from this wave
    for wt in worktree_names:
        $WORKTREE_MGR remove [wt]

    Report: "Wave [wave] complete: [len(succeeded_stories)] succeeded, [len(failed_stories)] failed"
    wave += 1
```

### 4b.7: Cleanup

After the wave loop ends (all stories processed or deadlock):

```
# Shutdown all remaining workers
for worker in all_worker_names:
    SendMessage type: "shutdown_request", recipient: worker

# Delete the team
TeamDelete

# Remove any remaining worktrees (safety cleanup)
$WORKTREE_MGR list
# For each worktree matching "aimi-US-*":
$WORKTREE_MGR remove [worktree_name]
```

Proceed to **Step 5: Completion**.

---

## Step 5: Completion

When execution ends (all stories complete, user stopped, or deadlock detected):

### If all stories complete:

Count commits on this branch:
```bash
git log --oneline main..HEAD | wc -l
```

**For sequential execution:**
```
## Execution Complete

All stories completed successfully!

Mode: Sequential
Branch: [branchName]
Commits: [count]

### Next Steps

- Review commits: `git log --oneline -[count]`
- Run `/aimi:review` for code review
- Create PR when ready: `gh pr create`
```

**For parallel execution:**
```
## Execution Complete

All stories completed successfully!

Mode: Parallel ([total_waves] waves)
Branch: [branchName]
Commits: [count]

### Execution Summary

[For each wave:]
Wave [N]: [count] stories executed in parallel
  - [story.id]: [story.title] - completed

### Next Steps

- Review commits: `git log --oneline -[count]`
- Run `/aimi:review` for code review
- Create PR when ready: `gh pr create`
```

### If user stopped early (sequential mode):

```
## Execution Paused

Run `/aimi:status` to see current state.
Run `/aimi:execute` to resume execution.
```

### If deadlock detected (parallel mode):

```
## Execution Stopped - Deadlock

[N] stories remain pending but none are ready for execution.
This may be caused by failed stories whose dependents were cascade-skipped.

Run `/aimi:status` to see the dependency state.
Review failed stories and either retry or adjust dependencies.
```

### If merge conflict (parallel mode):

```
## Execution Stopped - Merge Conflict

A merge conflict occurred while merging worker results.
Worktrees have been cleaned up. The team has been shut down.

Resolve the conflict on branch [branchName] and re-run `/aimi:execute` to continue.
```

## Resuming Execution

The tasks file preserves all state. Re-running `/aimi:execute` will:

1. Detect the schema version again
2. Skip completed stories automatically
3. Pick up from the next pending story (sequential) or next ready wave (parallel)
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
4. For parallel mode: orphaned worktrees are cleaned up on next run (safety cleanup in Step 4b.7)

The loop will automatically skip completed stories and continue from the next pending/ready one.
