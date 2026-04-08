---
name: aimi:execute
description: Execute all pending stories autonomously with wave-based parallelism
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash(git:*), Bash(AIMI_CLI=*), Bash($AIMI_CLI:*), Bash(WORKTREE_MGR=*), Bash($WORKTREE_MGR:*), Task
---

# Aimi Execute

Execute all pending stories autonomously using wave-based fan-out.

Each wave uses two-phase story loading to conserve context:
- **Phase 1 (wave selection):** `list-ready --brief` returns lightweight story stubs `{id, title, priority, dependsOn, project}` for scheduling decisions.
- **Phase 2 (prompt construction):** `get-story <id>` fetches full story data `{description, acceptanceCriteria, notes}` only for selected stories, after they are claimed with `mark-in-progress`.

Single-story waves run inline (no worktree overhead). Multi-story waves spawn N foreground Tasks in one tool-call turn with worktrees, wait for all results, then merge.

## Step 0: Resolve CLI Path

Resolve `$AIMI_CLI` path using the four-layer strategy below. Each command is a separate Bash call (no compound operators).

**Layer 0 — AIMI_PLUGIN_DIR (env var override):**
```bash
if [ -n "$AIMI_PLUGIN_DIR" ] && [ "${AIMI_PLUGIN_DIR#/}" != "$AIMI_PLUGIN_DIR" ] && [ -d "$AIMI_PLUGIN_DIR" ] && [ -x "$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh" ]; then AIMI_CLI="$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh"; fi
```

**Layer 1 — Global cache (fast path):**
```bash
if [ -z "$AIMI_CLI" ]; then AIMI_CLI=$(cat ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path 2>/dev/null); fi
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

If empty, report error and STOP:
- If `$AIMI_PLUGIN_DIR` is set: "aimi-cli.sh not found. Check AIMI_PLUGIN_DIR path: $AIMI_PLUGIN_DIR"
- Otherwise: "aimi-cli.sh not found. Reinstall plugin: `/plugin install aimi-engineering`"

**Version check:**
```bash
$AIMI_CLI check-version --quiet --fix
```

Use `$AIMI_CLI` for all subsequent script calls.

## Step 0.5: Archival Check

Before starting a new session, check whether any completed task files should be archived to prevent accidental re-execution of finished work.

```bash
$AIMI_CLI list-archivable
```

This returns a JSON array of file paths, e.g.:
```json
["/home/user/project/.aimi/tasks/2026-03-15-auth-feature-tasks.json"]
```

**If the array is empty (`[]`):** Proceed silently to Step 1.

**If archivable tasks exist:** Display the list and ask the user whether to archive them:

```
Found [N] completed task file(s) that can be archived:

  - [filename1]
  - [filename2]

Archive these completed tasks before starting? (yes/no)
```

- **If user confirms (yes):** For each archivable file path, run:
  ```bash
  $AIMI_CLI archive-task [file_path]
  ```
  After all files are archived, reset state files:
  ```bash
  $AIMI_CLI clear-state
  ```
  Report:
  ```
  Archived [N] task file(s). State cleared.
  ```
  Proceed to Step 1.

- **If user declines (no):** Proceed to Step 1 without archiving.

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

## Step 1.5: Branch Freshness Check

Detect the default branch and fetch the latest from origin before branch setup.

### Detect Default Branch

```bash
DEFAULT_BRANCH=$($AIMI_CLI detect-default-branch)
```

Store `DEFAULT_BRANCH` for use in branch creation and commit counting.

### Fetch Origin

```bash
git fetch origin
```

If fetch fails (e.g., offline or no remote), warn but continue:
```
Warning: git fetch origin failed — continuing with local state. Branch may be stale.
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
- If not exists: `git checkout -b [branchName] origin/[DEFAULT_BRANCH]`

Report:
```
Switched to branch: [branchName]
```

### Per-Project Branch Setup

After setting up the branch in the current repo, check if any stories have a `project` field by running `$AIMI_CLI list-ready --brief` and inspecting the results.

If any story has a non-null `project` field:

1. Collect unique project paths from ALL pending stories (not just ready ones — use `$AIMI_CLI status` and filter stories with a `project` field).
2. Resolve each project path to an absolute path: `AIMI_ROOT / story.project` where AIMI_ROOT is the directory containing `.aimi/`.
3. For each unique project path:
   ```bash
   cd [resolved_project_path]
   git branch --list [branchName]
   ```
   - If branch exists: `git checkout [branchName]`
   - If not exists: `git checkout -b [branchName] origin/[DEFAULT_BRANCH]`
   - Then return to the original directory.

Report for each project:
```
Branch [branchName] set up in project: [project_path]
```

If no stories have a `project` field, skip this step (backwards compatible).

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

Resolve `$WORKTREE_MGR` path using the same four-layer strategy. Each command is a separate Bash call (no compound operators).

**Layer 0 — AIMI_PLUGIN_DIR (env var override):**
```bash
if [ -n "$AIMI_PLUGIN_DIR" ] && [ "${AIMI_PLUGIN_DIR#/}" != "$AIMI_PLUGIN_DIR" ] && [ -d "$AIMI_PLUGIN_DIR" ] && [ -x "$AIMI_PLUGIN_DIR/skills/git-worktree/scripts/worktree-manager.sh" ]; then WORKTREE_MGR="$AIMI_PLUGIN_DIR/skills/git-worktree/scripts/worktree-manager.sh"; fi
```

**Layer 1 — Global cache (fast path):**
```bash
if [ -z "$WORKTREE_MGR" ]; then WORKTREE_MGR=$(cat ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path 2>/dev/null); fi
```

**Layer 1 validation:**
```bash
if [ -n "$WORKTREE_MGR" ] && [ ! -x "$WORKTREE_MGR" ]; then WORKTREE_MGR=""; fi
```

**Layer 2 — Glob fallback (zsh-safe, only if Layer 1 failed):**
```bash
if [ -z "$WORKTREE_MGR" ]; then WORKTREE_MGR=$(bash -c 'ls ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/*/aimi-engineering/*/skills/git-worktree/scripts/worktree-manager.sh 2>/dev/null | tail -1'); fi
```

**Layer 2 cache update:**
```bash
if [ -n "$WORKTREE_MGR" ]; then printf '%s\n' "$WORKTREE_MGR" > "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path.tmp" && mv "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path.tmp" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" && chmod 600 "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path"; fi
```

**Layer 3 — Per-project fallback (last resort):**
```bash
if [ -z "$WORKTREE_MGR" ] && [ -f .aimi/cli-path ]; then WORKTREE_MGR=$(dirname "$(cat .aimi/cli-path)")/worktree-manager.sh; if [ ! -x "$WORKTREE_MGR" ]; then WORKTREE_MGR=""; fi; fi
```

If empty, report error and STOP:
- If `$AIMI_PLUGIN_DIR` is set: "worktree-manager.sh not found. Check AIMI_PLUGIN_DIR path: $AIMI_PLUGIN_DIR"
- Otherwise: "worktree-manager.sh not found. Reinstall plugin: `/plugin install aimi-engineering`"

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

### Per-Project Guidelines

When stories target different projects (via the `project` field), each project may have its own `CLAUDE.md` and `AGENTS.md`. Load guidelines per unique project path and store as a map: `PROJECT_GUIDELINES_MAP[project_path] = guidelines_content`.

- For stories without a `project` field, use the default `PROJECT_GUIDELINES` (loaded from the current repo root).
- For stories with a `project` field, look up `PROJECT_GUIDELINES_MAP[story.project]` and pass it as `PROJECT_GUIDELINES` in the worker prompt.
- If no stories have `project` fields, skip this map and use default `PROJECT_GUIDELINES` (backwards compatible).

## Step 4: Wave Execution Loop

```
wave = 1

while true:
    # Check remaining work
    pending = $AIMI_CLI count-pending
    if pending == 0: break

    # Get ready stories (brief mode — returns {id, title, priority, dependsOn, project, gate} only)
    # NOTE: The CLI's list-ready already filters out:
    #   - Stories with pending decision gates (blocked before start)
    #   - Stories whose dependencies have pending action gates (blocked until gate resolved)
    ready_stories = $AIMI_CLI list-ready --brief
    if ready_stories is empty:
        if pending > 0:
            # ========================================
            # GATE-BLOCKED STORY DETECTION
            # ========================================
            # Before reporting deadlock, check if stories are blocked by gates.
            # Use $AIMI_CLI status to get all stories and identify gate-blocked ones.
            all_stories = $AIMI_CLI status
            decision_blocked = []  # stories with pending decision gates
            action_blocked = []    # stories whose dependencies have pending action gates

            for story in all_stories.userStories:
                if story.status == "pending":
                    # Check for pending decision gates on this story
                    if story.gate and story.gate.type == "decision" and story.gate.status == "pending":
                        decision_blocked.append(story)
                    # Check for pending action gates on dependencies
                    else if story.dependsOn:
                        for dep_id in story.dependsOn:
                            dep = find story with id == dep_id in all_stories.userStories
                            if dep.gate and dep.gate.type == "action" and dep.gate.status == "pending":
                                action_blocked.append(story)
                                break

            if len(decision_blocked) > 0 or len(action_blocked) > 0:
                Report: "No stories ready — blocked by gates:"
                for story in decision_blocked:
                    Report: "  Waiting for decision on [story.id]: [story.gate.prompt]"
                for story in action_blocked:
                    Report: "  [story.id] paused — dependency has pending action gate"
                Report: ""
                Report: "Use /aimi:status to see gate details. Resolve gates with:"
                Report: "  $AIMI_CLI gate-pass <story-id> [--option 'value']"
                Break loop (proceed to completion)
            else:
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

        # Fetch full story data (description, acceptanceCriteria, notes)
        full_story = $AIMI_CLI get-story [story.id]
        if get-story failed:
            $AIMI_CLI mark-failed [story.id] "get-story failed"
            $AIMI_CLI cascade-skip [story.id]
            Report: "[story.id] failed (could not fetch story data). Dependent stories cascade-skipped."
            Report: "Wave [wave] complete."
            wave += 1
            continue

        # Resolve PROJECT_PATH from story.project if present
        # AIMI_ROOT = directory containing .aimi/ (resolved during init-session)
        project_path = null
        project_guidelines = PROJECT_GUIDELINES
        if full_story.project is not null/absent:
            project_path = AIMI_ROOT / full_story.project  (resolve to absolute path)
            project_guidelines = PROJECT_GUIDELINES_MAP[full_story.project] or PROJECT_GUIDELINES

        # Capture HEAD SHA before Task spawn for commit verification
        if project_path is not null:
            head_before = git -C [project_path] rev-parse HEAD
        else:
            head_before = git rev-parse HEAD

        # Spawn a single foreground Task — same pattern as next.md
        # No worktree, worker operates in current directory (or PROJECT_PATH if set)
        # IMPORTANT: subagent_type MUST be "general-purpose" — story-executor is a skill, NOT an agent.
        Task(
            subagent_type: "general-purpose",
            description: "Execute [full_story.id]: [full_story.title]",
            prompt: [story-executor SKILL.md prompt template with:
                - PROJECT_GUIDELINES = project_guidelines
                - PROJECT_PATH = project_path (only include if non-null)
                - STORY_ID = full_story.id
                - STORY_TITLE = full_story.title
                - STORY_DESCRIPTION = full_story.description
                - ACCEPTANCE_CRITERIA = full_story.acceptanceCriteria (bulleted)
                - full_story.notes = full_story.notes (include PREVIOUS NOTES section only if non-empty)
                - No WORKTREE_PATH (sequential — worker operates in current directory or PROJECT_PATH)
            ]
        )

        # Handle result
        if Task succeeded:
            # Verify a commit was actually created
            if project_path is not null:
                head_after = git -C [project_path] rev-parse HEAD
            else:
                head_after = git rev-parse HEAD

            if head_after == head_before:
                $AIMI_CLI mark-failed [story.id] "No commit detected after execution"
                $AIMI_CLI cascade-skip [story.id]
                Report: "[story.id] failed (no commit detected). Dependent stories cascade-skipped."
                Report: "Wave [wave] complete."
                wave += 1
                continue

            $AIMI_CLI mark-complete [story.id]

            # Update verification.status if story has verification and executor reports success
            if full_story.verification and full_story.verification.status == "pending":
                # Story-executor verified acceptance criteria — mark verification as passed
                $AIMI_CLI update-field [story.id] verification.status passed

            Report: "[story.id] completed."

            # ========================================
            # POST-COMPLETION GATE LOGGING
            # ========================================
            # Re-fetch story to get gate info (gate field was in brief data)
            if full_story.gate:
                if full_story.gate.type == "action" and full_story.gate.status == "pending":
                    Report: "Action required for [story.id]: [full_story.gate.prompt]"
                    Report: "  Dependents will wait until gate is resolved."
                if full_story.gate.type == "verify" and full_story.gate.status == "pending":
                    Report: "Verification pending for [story.id]: [full_story.gate.prompt]"
                    Report: "  Dependents proceed immediately (non-blocking)."
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

    # Fetch full story data for all selected stories (claim-then-fetch)
    full_stories = []
    fetch_failed = []
    for story in selected_stories:
        full_story = $AIMI_CLI get-story [story.id]
        if get-story failed:
            fetch_failed.append(story)
            $AIMI_CLI mark-failed [story.id] "get-story failed"
            $AIMI_CLI cascade-skip [story.id]
            Report: "[story.id] failed (could not fetch story data). Dependent stories cascade-skipped."
        else:
            full_stories.append(full_story)

    # If all fetches failed, skip worktree creation entirely
    if len(full_stories) == 0:
        Report: "Wave [wave] complete: 0 succeeded, [len(fetch_failed)] failed (all get-story calls failed)"
        wave += 1
        continue

    # If only one story remains after fetch failures, use single-story path (no worktree)
    if len(full_stories) == 1:
        full_story = full_stories[0]

        # Resolve PROJECT_PATH if story has project field
        project_path = null
        project_guidelines = PROJECT_GUIDELINES
        if full_story.project is not null/absent:
            project_path = AIMI_ROOT / full_story.project
            project_guidelines = PROJECT_GUIDELINES_MAP[full_story.project] or PROJECT_GUIDELINES

        # Capture HEAD SHA before Task spawn for commit verification
        if project_path is not null:
            head_before = git -C [project_path] rev-parse HEAD
        else:
            head_before = git rev-parse HEAD

        Task(
            subagent_type: "general-purpose",
            description: "Execute [full_story.id]: [full_story.title]",
            prompt: [story-executor SKILL.md prompt template with:
                - PROJECT_GUIDELINES = project_guidelines
                - PROJECT_PATH = project_path (only include if non-null)
                - STORY_ID = full_story.id
                - STORY_TITLE = full_story.title
                - STORY_DESCRIPTION = full_story.description
                - ACCEPTANCE_CRITERIA = full_story.acceptanceCriteria (bulleted)
                - full_story.notes = full_story.notes (include PREVIOUS NOTES section only if non-empty)
                - No WORKTREE_PATH (single remaining story — no worktree overhead)
            ]
        )

        if Task succeeded:
            # Verify a commit was actually created
            if project_path is not null:
                head_after = git -C [project_path] rev-parse HEAD
            else:
                head_after = git rev-parse HEAD

            if head_after == head_before:
                $AIMI_CLI mark-failed [full_story.id] "No commit detected after execution"
                $AIMI_CLI cascade-skip [full_story.id]
                Report: "[full_story.id] failed (no commit detected). Dependent stories cascade-skipped."
                Report: "Wave [wave] complete."
                wave += 1
                continue

            $AIMI_CLI mark-complete [full_story.id]

            # Update verification.status if story has verification and executor reports success
            if full_story.verification and full_story.verification.status == "pending":
                $AIMI_CLI update-field [full_story.id] verification.status passed

            Report: "[full_story.id] completed."

            # Post-completion gate logging
            if full_story.gate:
                if full_story.gate.type == "action" and full_story.gate.status == "pending":
                    Report: "Action required for [full_story.id]: [full_story.gate.prompt]"
                    Report: "  Dependents will wait until gate is resolved."
                if full_story.gate.type == "verify" and full_story.gate.status == "pending":
                    Report: "Verification pending for [full_story.id]: [full_story.gate.prompt]"
                    Report: "  Dependents proceed immediately (non-blocking)."
        else:
            $AIMI_CLI mark-failed [full_story.id] "Failed during wave [wave]"
            $AIMI_CLI cascade-skip [full_story.id]
            Report: "[full_story.id] failed. Dependent stories cascade-skipped."

        Report: "Wave [wave] complete."
        wave += 1
        continue

    # Multiple stories remain — proceed with worktree parallelism

    # ========================================
    # GROUP STORIES BY PROJECT
    # ========================================
    # Group full_stories by their `project` field.
    # Stories without a `project` field (null/absent) go into the DEFAULT group.
    # DEFAULT group uses the current repo (no cd needed).
    # Each project group has its own git root for worktree operations.

    project_groups = {}  # key: project_path (or "DEFAULT"), value: list of full_story
    for full_story in full_stories:
        if full_story.project is not null/absent:
            group_key = full_story.project
        else:
            group_key = "DEFAULT"
        project_groups[group_key].append(full_story)

    # Resolve absolute paths for each project group
    # AIMI_ROOT = directory containing .aimi/ (resolved during init-session)
    project_roots = {}  # key: group_key, value: absolute path to git root
    for group_key in project_groups:
        if group_key == "DEFAULT":
            project_roots[group_key] = CWD  (current working directory / git root)
        else:
            project_roots[group_key] = AIMI_ROOT / group_key  (resolve to absolute path)

    # ========================================
    # CAPTURE BASE SHA PER PROJECT GROUP (for commit verification)
    # ========================================
    base_sha = {}  # key: group_key, value: HEAD SHA before worktree creation
    for group_key in project_groups:
        project_root = project_roots[group_key]
        base_sha[group_key] = git -C [project_root] rev-parse [branchName]

    # ========================================
    # CREATE WORKTREES PER PROJECT GROUP
    # ========================================
    all_worktrees = {}  # key: full_story.id, value: {worktree_name, worktree_path, group_key}

    for group_key, stories in project_groups:
        project_root = project_roots[group_key]

        for full_story in stories:
            worktree_name = "[branchName]-[full_story.id]"

            # cd to the project's git root before creating worktree
            cd [project_root]
            $WORKTREE_MGR create [worktree_name] --from [branchName]

            worktree_path = [path from output]
            all_worktrees[full_story.id] = {
                worktree_name: worktree_name,
                worktree_path: worktree_path,
                group_key: group_key
            }

    # Spawn ALL workers as foreground Tasks in a SINGLE tool-call turn.
    # Claude Code runs multiple foreground Tasks concurrently and returns
    # all results before the agent's turn ends.
    #
    # IMPORTANT: subagent_type MUST be "general-purpose" — story-executor is a skill, NOT an agent.
    # In one tool-call turn, emit N Task calls (across ALL project groups):
    for full_story in full_stories:
        wt = all_worktrees[full_story.id]
        project_path = project_roots[wt.group_key] if wt.group_key != "DEFAULT" else null
        project_guidelines = PROJECT_GUIDELINES_MAP[wt.group_key] if wt.group_key != "DEFAULT" else PROJECT_GUIDELINES

        Task(
            subagent_type: "general-purpose",
            description: "Execute [full_story.id]: [full_story.title]",
            prompt: [story-executor SKILL.md prompt template with:
                - WORKTREE_PATH = wt.worktree_path
                - PROJECT_PATH = project_path (only include if non-null)
                - PROJECT_GUIDELINES = project_guidelines
                - STORY_ID = full_story.id
                - STORY_TITLE = full_story.title
                - STORY_DESCRIPTION = full_story.description
                - ACCEPTANCE_CRITERIA = full_story.acceptanceCriteria (bulleted)
                - full_story.notes = full_story.notes (include PREVIOUS NOTES section only if non-empty)
                - Do NOT modify the tasks.json file — report result (success/failure + details)
            ]
        )

    # All Tasks return in the same turn. Collect results.
    failed_stories = []
    succeeded_stories = []

    for each Task result:
        if Task succeeded:
            succeeded_stories.append(full_story)
        else:
            failed_stories.append(full_story)

    # --- Post-Wave Processing ---

    # ========================================
    # COMMIT VERIFICATION (parallel path)
    # ========================================
    # For each succeeded story, verify that a commit was actually created
    # by comparing worktree HEAD against the base SHA captured before worktree creation.
    no_commit_stories = []
    verified_stories = []
    for full_story in succeeded_stories:
        wt = all_worktrees[full_story.id]
        worktree_head = git -C [wt.worktree_path] rev-parse HEAD
        if worktree_head == base_sha[wt.group_key]:
            no_commit_stories.append(full_story)
        else:
            verified_stories.append(full_story)

    # Move no-commit stories to failed
    for full_story in no_commit_stories:
        $AIMI_CLI mark-failed [full_story.id] "No commit detected after execution"
        $AIMI_CLI cascade-skip [full_story.id]
        Report: "[full_story.id] failed (no commit detected). Dependent stories cascade-skipped."

    # Replace succeeded_stories with only verified ones (so merge-all skips no-commit stories)
    succeeded_stories = verified_stories

    # Handle failures first
    for full_story in failed_stories:
        $AIMI_CLI mark-failed [full_story.id] "Failed during parallel wave [wave]"
        $AIMI_CLI cascade-skip [full_story.id]
        Report: "[full_story.id] failed. Dependent stories cascade-skipped."

    # ========================================
    # MERGE PER PROJECT GROUP (not across repos)
    # ========================================
    # Merge successful worktrees grouped by project.
    # Each project group merges independently into its own repo's branch.

    if len(succeeded_stories) > 0:
        # Group succeeded stories by project
        succeeded_by_project = {}
        for full_story in succeeded_stories:
            group_key = all_worktrees[full_story.id].group_key
            succeeded_by_project[group_key].append(full_story)

        for group_key, stories in succeeded_by_project:
            project_root = project_roots[group_key]
            succeeded_worktree_names = [all_worktrees[s.id].worktree_name for s in stories]

            # cd to the project's git root before merging
            cd [project_root]
            merge_result = $WORKTREE_MGR merge-all [succeeded_worktree_names...] --into [branchName]

            if merge conflict (non-zero exit):
                Report:
                "MERGE CONFLICT during wave [wave] merge in project [group_key]."
                "Conflicting files:"
                "[conflict output from merge-all]"
                ""
                "Resolve the conflict on branch [branchName] in [project_root] and re-run `/aimi:execute` to continue."

                # Cleanup ALL worktrees from this wave (across all project groups) before stopping
                for full_story_id, wt in all_worktrees:
                    cd [project_roots[wt.group_key]]
                    $WORKTREE_MGR remove [wt.worktree_name]

                STOP execution.

            # Merges succeeded for this project group — mark stories complete
            for full_story in stories:
                $AIMI_CLI mark-complete [full_story.id]

                # Update verification.status if story has verification and executor reports success
                if full_story.verification and full_story.verification.status == "pending":
                    $AIMI_CLI update-field [full_story.id] verification.status passed

                Report: "[full_story.id] merged successfully."

                # Post-completion gate logging
                if full_story.gate:
                    if full_story.gate.type == "action" and full_story.gate.status == "pending":
                        Report: "Action required for [full_story.id]: [full_story.gate.prompt]"
                        Report: "  Dependents will wait until gate is resolved."
                    if full_story.gate.type == "verify" and full_story.gate.status == "pending":
                        Report: "Verification pending for [full_story.id]: [full_story.gate.prompt]"
                        Report: "  Dependents proceed immediately (non-blocking)."

    # Remove all worktrees from this wave (per project group)
    for full_story_id, wt in all_worktrees:
        cd [project_roots[wt.group_key]]
        $WORKTREE_MGR remove [wt.worktree_name]

    # Count gate statuses for wave summary
    action_gates = [s for s in succeeded_stories if s.gate and s.gate.type == "action" and s.gate.status == "pending"]
    verify_gates = [s for s in succeeded_stories if s.gate and s.gate.type == "verify" and s.gate.status == "pending"]

    wave_summary = "Wave [wave] complete: [len(succeeded_stories)] succeeded, [len(failed_stories)] failed"
    if len(action_gates) > 0:
        wave_summary += ", [len(action_gates)] action gate(s) pending"
    if len(verify_gates) > 0:
        wave_summary += ", [len(verify_gates)] verify gate(s) pending"
    Report: wave_summary
    wave += 1
```

### Post-Loop Cleanup

After the wave loop ends (all stories processed or deadlock):

```
# Remove any remaining worktrees (safety cleanup)
# When stories have project fields, clean up per project root:
for each unique project_root (including CWD for DEFAULT group):
    cd [project_root]
    $WORKTREE_MGR list
    # For each worktree matching "[branchName]-US-*":
    $WORKTREE_MGR remove [worktree_name]

# When no stories have project fields, use current directory (backwards compatible):
$WORKTREE_MGR list
# For each worktree matching "[branchName]-US-*":
$WORKTREE_MGR remove [worktree_name]
```

## Step 5: Completion

When execution ends (all stories complete, or deadlock detected):

### If all stories complete:

Count commits on this branch:
```bash
git log --oneline $DEFAULT_BRANCH..HEAD | wc -l
```

Check for any remaining pending gates across all stories:
```bash
$AIMI_CLI status
```

Parse gate summary from status output:
- `pending_action_gates`: count of stories with gate.type == "action" and gate.status == "pending"
- `pending_verify_gates`: count of stories with gate.type == "verify" and gate.status == "pending"
- `pending_decision_gates`: count of stories with gate.type == "decision" and gate.status == "pending"

```
## Execution Complete

All stories completed successfully!

Branch: [branchName]
Waves: [total_waves]
Commits: [count]
```

If any pending gates exist, append:
```
### Pending Gates

[If pending_action_gates > 0:]
Action gates ([pending_action_gates]):
  For each: "  - [story.id]: [story.gate.prompt]"

[If pending_verify_gates > 0:]
Verify gates ([pending_verify_gates]):
  For each: "  - [story.id]: [story.gate.prompt]"

[If pending_decision_gates > 0:]
Decision gates ([pending_decision_gates]):
  For each: "  - [story.id]: [story.gate.prompt]"

Resolve gates with: $AIMI_CLI gate-pass <story-id> [--option 'value']
```

```
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
