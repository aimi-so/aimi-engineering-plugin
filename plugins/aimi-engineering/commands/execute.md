---
name: aimi:execute
description: Execute all pending stories autonomously with wave-based parallelism
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash(git:*), Bash(mkdir:*), Bash(AIMI_CLI=*), Bash($AIMI_CLI:*), Bash(WORKTREE_MGR=*), Bash($WORKTREE_MGR:*), Task
---

# Aimi Execute

Execute all pending stories autonomously using wave-based fan-out.

Each wave uses pointer-only handoff to keep the orchestrator's working memory slim:
- **Wave selection:** `list-ready --brief` returns lightweight story stubs `{id, title, priority, dependsOn, project}` for scheduling decisions.
- **Spawn prompt:** carries only a `task_pointer` section with the story id — no inlined story body, no inlined prototype context. Each subagent fetches its own full context via `$AIMI_CLI get-story-context $STORY_ID` as its first action.

Every story runs in its own git worktree spawned as a fresh-context Task subagent. Within a wave, stories execute in parallel up to metadata.maxConcurrency; selection order follows $AIMI_CLI list-ready output (tasks.json file order, deterministic).

## Step 0: Resolve CLI Path

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/cli-path-resolution.md` and follow the **Resolve CLI Path** and **Version Check** sections to set `$AIMI_CLI`. Each layer is a separate Bash call.

If resolution fails, report error and STOP.

**Each Bash tool call is an isolated shell — `$AIMI_CLI` does not persist.** Re-read the cache at the top of every subsequent Bash call that needs `$AIMI_CLI` or `$WORKTREE_MGR`. See the **Per-Call Resolution** section of `commands/references/cli-path-resolution.md` for the one-liner and shell guard to prepend.

### Resolve Agent Models

Read and follow the **Resolve Agent Models** section of `commands/references/cli-path-resolution.md` to populate `AGENT_MODELS`. When resolution fails, treat every category as `"inherit"` and continue.

## Multi-Repo Handling

This section is the single source of truth for multi-repo layout detection and per-project story routing. All call sites below reference it by name.

### AIMI_ROOT_IS_GIT_REPO Branching Rule

Set in Step 1.5 by running `git -C [AIMI_ROOT] rev-parse --git-dir`. When **true**, AIMI_ROOT is itself a git repository — all inline logic (default-branch detection, fetch, branch setup, worktree creation) runs directly against AIMI_ROOT. When **false**, this is a **multi-repo layout**: Claude Code runs from a parent folder containing multiple git repos as subfolders. In this layout:

- Default-branch detection and `git fetch origin` are skipped at the AIMI_ROOT level and happen per-project instead.
- Step 1.6 (Branch Base Selection) is skipped entirely; `BASE_BRANCH` is left unset.
- Step 2 "Main Repo Branch Setup" is skipped entirely; all branch setup is handled per-project.
- All stories must carry a `project` field (the per-project path).

### Per-Story Project-Grouping Pattern

Stories are grouped by their `project` field:

- Stories with a non-null `project` field are routed to `AIMI_ROOT / story.project` (resolved to an absolute path).
- Stories without a `project` field (null/absent) form the DEFAULT group, routed to the current working directory (CWD).

**Path validation rules:** `project` field values must match `^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$`. No leading `./` and no `..` path components are allowed.

Each project group operates independently: its own default-branch detection, `git fetch origin`, branch setup, worktree creation, merge, and cleanup all run against that project's git root.

### Per-Project Cleanup Rule

After each wave (and in Post-Loop safety cleanup), for each unique `project_root` (including CWD for the DEFAULT group):

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
cd [project_root]
$WORKTREE_MGR list
# For each worktree matching "[branchName]-US-*":
$WORKTREE_MGR remove [worktree_name]
```

---

## Step 0.5: Archival Check

Before starting a new session, check whether any completed task files should be archived to prevent accidental re-execution of finished work.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
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
  AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
  : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
  $AIMI_CLI archive-task [file_path]
  ```
  After all files are archived, reset state files:
  ```bash
  AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
  : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
  $AIMI_CLI clear-state
  ```
  Report:
  ```
  Archived [N] task file(s). State cleared.
  ```
  Proceed to Step 1.

- **If user declines (no):** Proceed to Step 1 without archiving.

## Visual Follow Lifecycle

The visual-follow feature spans four phases of the execute flow. This section documents the full lifecycle; each call site below references it by name.

### Phase 1 — Detection (Step 0.7)

The tasks file is scanned for stories with `verification.strategy == "visual"`. If any are found, the user is prompted once whether to follow visually. The result is stored in `VISUAL_FOLLOW=true|false` and held for the rest of the session.

### Phase 2 — Session Open (Step 3.3)

When `VISUAL_FOLLOW=true`, a persistent headed browser session named `visual-follow` is opened before the wave loop begins:

```bash
agent-browser --headed --session visual-follow open "$VISUAL_URL"
```

**Availability check:** Before opening, `command -v agent-browser` is run. If `agent-browser` is not installed, the user is warned and `VISUAL_FOLLOW` is downgraded to `false` (headless fallback takes over in Phase 3):

```
⚠ agent-browser not installed. Falling back to headless mode — visual follow disabled.
```

The session is opened exactly once. It is never closed mid-run.

### Phase 3 — Reuse Within Wave (Step 4 per-story)

After each story merges, visual stories are verified. When `VISUAL_FOLLOW=true`, the existing `visual-follow` session is reused (`agent-browser --session visual-follow open/screenshot`). When `VISUAL_FOLLOW=false`, a fresh headless `agent-browser` session is opened, screenshot taken, and closed per story. If `agent-browser` is absent in either case, `verification.status` is set to `skipped`.

**Console capture (additive, per story).** Immediately before each per-story `open`, the wave loop issues `agent-browser console --clear` to drop logs accumulated from prior stories in the same wave. Right after `screenshot`, it captures `agent-browser console --json` and `agent-browser errors --json` for this story's page-load output and feeds both into the `attribute_console_errors()` pass defined in the Console Error Attribution section. Capture is advisory only — it never changes `verification.status` and never blocks the wave. The per-story `--clear` is what enables per-story attribution; without it, the buffer is wave-cumulative and the LAST verified story would inherit every prior story's errors.

### Phase 4 — Keep Open on Completion (Post-Loop)

When `VISUAL_FOLLOW=true`, the `visual-follow` session is intentionally left open after execution ends so the user can inspect the final UI state. The user must close it manually.

---

## Step 0.7: Visual Follow Prompt

Check the tasks file directly for any stories with a visual verification strategy. Since `$AIMI_CLI status` omits the `verification` field, read the file with jq:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
TASKS_PATH="$($AIMI_CLI init-session 2>/dev/null | jq -r '.tasks // empty')"
VISUAL_STORIES=$(jq '[.userStories[] | select(.verification | type == "object" and .strategy == "visual")] | length' "$AIMI_ROOT/$TASKS_PATH" 2>/dev/null)
MALFORMED_VERIF=$(jq '[.userStories[] | select(.verification != null and (.verification | type != "object"))] | length' "$AIMI_ROOT/$TASKS_PATH" 2>/dev/null)
```

If `MALFORMED_VERIF` > 0, collect the affected story IDs and abort:

```bash
MALFORMED_IDS=$(jq -r '[.userStories[] | select(.verification != null and (.verification | type != "object")) | .id] | join(", ")' "$AIMI_ROOT/$TASKS_PATH" 2>/dev/null)
```

Report the error and STOP:
```
Malformed verification fields detected — aborting.

Affected stories: [MALFORMED_IDS]

Verification must be an object, not a bare string. Run:
  $AIMI_CLI normalize-verification <tasks-path>
to fix the file, then re-run /aimi:execute.
```
STOP execution.

- **If `VISUAL_STORIES` is 0 or empty:** Set `VISUAL_FOLLOW=false`. Proceed to Step 1.

- **If `VISUAL_STORIES` > 0:** Prompt the user:

```
Frontend stories detected. Follow implementation visually in a headed browser? (yes/no)
```

  - **If user says yes:** Set `VISUAL_FOLLOW=true`.
  - **If user says no:** Set `VISUAL_FOLLOW=false`.

See the Visual Follow Lifecycle section above for the full lifecycle contract.

Proceed to Step 1.

## Step 0.9: Multi-File Auto-Detection

Discover all task files and check for paired frontend/backend splits:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
ALL_TASKS=$($AIMI_CLI find-tasks-all)
```

If `find-tasks-all` returns no files or fails, skip this step (Step 1 will handle the error via `init-session`).

Count the number of task files:
```bash
TASK_COUNT=$(echo "$ALL_TASKS" | wc -l)
```

### Paired Split Detection

If exactly **two** files are found, check whether they form a paired frontend+backend split:

1. Extract the basenames and check for matching `*-frontend-tasks.json` and `*-backend-tasks.json` patterns:
   - Both files must share the same date+feature prefix (e.g., `2026-04-10-live-preview`)
   - One must end with `-frontend-tasks.json`, the other with `-backend-tasks.json`

```
Example match:
  .aimi/tasks/2026-04-10-live-preview-frontend-tasks.json
  .aimi/tasks/2026-04-10-live-preview-backend-tasks.json

  Shared prefix: "2026-04-10-live-preview"
  → Paired split detected
```

2. If the two files match the paired pattern:
   - Extract `metadata.branchName` from each file using jq:
     ```bash
     FRONTEND_BRANCH=$(jq -r '.metadata.branchName' <frontend-file>)
     BACKEND_BRANCH=$(jq -r '.metadata.branchName' <backend-file>)
     ```
   - Verify both branches are different (they target separate branches — no conflicts)

### Parallel Execution for Paired Files

When a paired split is detected, spawn **two foreground Tasks in a single tool-call turn**. Each Task runs the full execute.md flow (Steps 1–5) scoped to its own file:

```
Report:
"Paired frontend+backend task files detected:"
"  Frontend: [frontend-file] (branch: [FRONTEND_BRANCH])"
"  Backend:  [backend-file] (branch: [BACKEND_BRANCH])"
""
"Spawning parallel execution flows..."
```

Create worktrees for isolation:
```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
$WORKTREE_MGR create [FRONTEND_BRANCH] --from $DEFAULT_BRANCH
$WORKTREE_MGR create [BACKEND_BRANCH] --from $DEFAULT_BRANCH
```

In a **single tool-call turn**, emit two foreground Tasks:

```
Task(
    subagent_type: "general-purpose",
    model: <AGENT_MODELS.executor when not "inherit">,
    description: "Execute frontend tasks: [frontend-file]",
    prompt: [Full execute.md flow (Steps 1–5) with:
        - WORKTREE_PATH = [frontend worktree path]
        - $AIMI_CLI init-session --file [frontend-file]
        - All subsequent steps (reset-orphaned, validate, wave loop, completion)
        - Scoped to the frontend tasks file only
        - PROJECT_GUIDELINES = PROJECT_GUIDELINES
    ]
)

Task(
    subagent_type: "general-purpose",
    model: <AGENT_MODELS.executor when not "inherit">,
    description: "Execute backend tasks: [backend-file]",
    prompt: [Full execute.md flow (Steps 1–5) with:
        - WORKTREE_PATH = [backend worktree path]
        - $AIMI_CLI init-session --file [backend-file]
        - All subsequent steps (reset-orphaned, validate, wave loop, completion)
        - Scoped to the backend tasks file only
        - PROJECT_GUIDELINES = PROJECT_GUIDELINES
    ]
)
```

Each parallel Task receives the full execute.md flow:
- **init-session** with `--file <path>` targeting its specific file
- **reset-orphaned** to recover any stuck stories in that file
- **validate-stories** for content validation
- **wave loop** (Step 4) executing all stories from its file
- Each flow commits to its own branch (`metadata.branchName` from its file) — no branch conflicts
- Prototype files are read by each subagent independently via `$AIMI_CLI get-story-context` (pointer-only handoff)

After both Tasks return, collect results and proceed to **Step 5 (Aggregated Completion)**.

### Single-File Fallback

If only **one** file is found, or the two files do **not** match the paired frontend/backend pattern, proceed with the standard single-file execution flow (Step 1 onward) unchanged. The `init-session` call in Step 1 will auto-detect the most recent file.

### Aggregated Completion (Paired Mode)

When both parallel Tasks complete, skip the normal Step 5 and report aggregated results:

```
## Execution Complete (Paired Mode)

Frontend file: [frontend-file]
  Branch: [FRONTEND_BRANCH]
  Stories completed: [count from frontend Task result]
  Commits: git log --oneline $DEFAULT_BRANCH..[FRONTEND_BRANCH] | wc -l

Backend file: [backend-file]
  Branch: [BACKEND_BRANCH]
  Stories completed: [count from backend Task result]
  Commits: git log --oneline $DEFAULT_BRANCH..[BACKEND_BRANCH] | wc -l

Total stories: [frontend_count + backend_count]
Total commits: [frontend_commits + backend_commits]

### Next Steps

- Review frontend commits: git log --oneline $DEFAULT_BRANCH..[FRONTEND_BRANCH]
- Review backend commits: git log --oneline $DEFAULT_BRANCH..[BACKEND_BRANCH]
- Run /aimi:review for code review
- Create PRs when ready: gh pr create
```

Clean up worktrees after reporting:
```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
$WORKTREE_MGR remove [FRONTEND_BRANCH]
$WORKTREE_MGR remove [BACKEND_BRANCH]
```

STOP execution (aggregated report replaces normal Step 5).

## Step 1: Initialize Session

**CRITICAL:** Use the CLI script to initialize session and get metadata. Do NOT interpret jq queries directly.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
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
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
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
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
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

### Detect Git Repo Layout

Check if AIMI_ROOT (directory containing `.aimi/`) is itself a git repository:

```bash
git -C [AIMI_ROOT] rev-parse --git-dir >/dev/null 2>&1
```

Store exit code as `AIMI_ROOT_IS_GIT_REPO` (true if exit 0, false otherwise). See the **Multi-Repo Handling** section above for the full contract.

### Default Branch and Origin Fetch

When the flag is true, run both of the following. When false, skip both — per-project detection and fetch happen in the branch setup step (see Multi-Repo Handling above).

Detect the default branch:
```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
DEFAULT_BRANCH=$($AIMI_CLI detect-default-branch)
```
Store `DEFAULT_BRANCH` for use in branch creation and commit counting.

Fetch from origin:
```bash
git fetch origin
```
If fetch fails (e.g., offline or no remote), warn but continue:
```
Warning: git fetch origin failed — continuing with local state. Branch may be stale.
```

## Step 1.6: Branch Base Selection

Before creating the task branch, when the current branch has unmerged work relative to the default branch, ask whether to stack on it or start fresh from the default branch. This prevents silently inheriting unrelated work or losing intentional stacking.

`BASE_BRANCH` starts unset. It is set only when the user explicitly chooses a base; Step 2 threads it via `--base` only when set.

### Early-Skip Guard (Multi-Repo)

If `AIMI_ROOT_IS_GIT_REPO` is false, skip this step entirely and leave `BASE_BRANCH` unset. See Multi-Repo Handling above.

### Resolve Interactivity Mode

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
INTERACTIVE_MODE=$($AIMI_CLI detect-interactivity)
```

### Compute Gating Conditions

Check whether a prompt is needed. Compute all four conditions:

```bash
TARGET_EXISTS_LOCAL=$(git branch --list [branchName])
TARGET_EXISTS_REMOTE=$(git ls-remote --heads origin [branchName])
CURRENT_BRANCH=$(git branch --show-current)
CURRENT_IS_MERGED=$(git branch --merged "origin/$DEFAULT_BRANCH" | grep -Fx "  $CURRENT_BRANCH" || git branch --merged "origin/$DEFAULT_BRANCH" | grep -Fx "* $CURRENT_BRANCH")
```

A prompt is needed when **all four** of the following are true:

- `TARGET_EXISTS_LOCAL` is empty (branch does not exist locally)
- `TARGET_EXISTS_REMOTE` is empty (branch does not exist on remote)
- `CURRENT_BRANCH` != `DEFAULT_BRANCH` (not already on the default branch)
- `CURRENT_IS_MERGED` is empty (current branch has commits not yet merged into `origin/$DEFAULT_BRANCH`)

### Picker Prompt (when prompt is needed AND INTERACTIVE_MODE=picker)

Use **AskUserQuestion** with the following options:

```
Which branch should be used as the base for [branchName]?

A — Stack on current branch ([current_branch])
B — Use default branch ([DEFAULT_BRANCH])
Other — Specify a base branch
```

**Option A:** `BASE_BRANCH=$CURRENT_BRANCH`

**Option B:** `BASE_BRANCH=$DEFAULT_BRANCH`

**Option Other:** Collect the free-form branch name the user typed. Validate it against `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$`. If it does not match, report:

```
Invalid branch name. Must match ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$
```

and STOP. If valid, store `BASE_BRANCH=<user-input>`.

### Agent-Mode Fallback (when prompt is needed AND INTERACTIVE_MODE=agent)

Leave `BASE_BRANCH` unset (preserves the existing CLI heuristic which stacks on the current branch, matching the previous automatic behavior). Log:

```
agent-mode: step-1.6 branch-base auto-preserve
```

*Agent-mode fallback: if `INTERACTIVE_MODE=agent`, leave BASE_BRANCH unset and log `agent-mode: step-1.6 branch-base auto-preserve`.*

### When Prompt Is Not Needed

If any of the four gating conditions is false, skip silently — do NOT log an agent-mode line. Leave `BASE_BRANCH` unset.

## Step 2: Branch Setup

Get the branch name from the init-session output (already validated by CLI).

### Main Repo Branch Setup

**Skip this step if `AIMI_ROOT_IS_GIT_REPO` is false** — see Multi-Repo Handling above.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
if [ -n "$BASE_BRANCH" ]; then
  BRANCH_JSON=$($AIMI_CLI setup-branch [branchName] --default-branch $DEFAULT_BRANCH --base $BASE_BRANCH)
else
  BRANCH_JSON=$($AIMI_CLI setup-branch [branchName] --default-branch $DEFAULT_BRANCH)
fi
```

If the command fails (non-zero exit), report the error and STOP.

Extract the action from the JSON output and report:
```
Branch setup: [action]
```

Where `[action]` is the `action` field from the JSON response (e.g., `already-on-branch`, `checked-out-local`, `checked-out-remote`, `created-from-default`, `created-from-current`, `created-from-base`).

### Per-Project Branch Setup

After setting up the branch in the main repo (or skipping if multi-repo layout), check if any stories have a `project` field by running `$AIMI_CLI list-ready --brief` and inspecting the results.

Run the following sub-steps when any story has a non-null `project` field, or when in multi-repo layout (see Multi-Repo Handling above for the gate condition). Skip this step when no stories have a `project` field and AIMI_ROOT is a git repo (backwards compatible).

1. Collect unique project paths from ALL pending stories (not just ready ones — use `$AIMI_CLI status` and filter stories with a `project` field).
2. Resolve each project path to an absolute path: `AIMI_ROOT / story.project` where AIMI_ROOT is the directory containing `.aimi/`.
3. For each unique project path, detect its default branch and set up the branch:
   ```bash
   AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
   : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
   PROJECT_DEFAULT=$($AIMI_CLI detect-default-branch --project [resolved_project_path])
   git -C [resolved_project_path] fetch origin 2>/dev/null || true
   if [ -n "$BASE_BRANCH" ]; then
     PROJECT_BRANCH_JSON=$($AIMI_CLI setup-branch [branchName] --default-branch $PROJECT_DEFAULT --project [resolved_project_path] --base $BASE_BRANCH)
   else
     PROJECT_BRANCH_JSON=$($AIMI_CLI setup-branch [branchName] --default-branch $PROJECT_DEFAULT --project [resolved_project_path])
   fi
   ```
   Extract the action from the JSON output and report:
   ```
   Branch [branchName] set up in project: [project_path] (action: [action])
   ```

## Step 3: Check for Pending Stories

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
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
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
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

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/cli-path-resolution.md` and follow the **Resolve Worktree Manager Path** section to set `$WORKTREE_MGR`.

If resolution fails, report error and STOP.

**`$WORKTREE_MGR` does not persist across Bash calls.** Re-read the cache at the top of every Bash call that uses it — see the **Per-Call Resolution** section of `commands/references/cli-path-resolution.md` for the one-liner and shell guard.

## Step 3.2: Read Concurrency Setting

Read the tasks file metadata to get maxConcurrency:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI init-session
```

Parse `maxConcurrency` from metadata. If not set, default to `20`.

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

### Open Visual Follow Session

See the Visual Follow Lifecycle section for context (Phase 2 — Session Open).

If `VISUAL_FOLLOW=true`, open a persistent headed browser session before entering the wave loop:

```bash
command -v agent-browser
```

- **If `agent-browser` is not found:** Warn the user and fall back to headless mode:
  ```
  ⚠ agent-browser not installed. Falling back to headless mode — visual follow disabled.
  ```
  Set `VISUAL_FOLLOW=false`.

- **If `agent-browser` is available:** Get the verification URL from the first visual story:

  ```bash
  VISUAL_URL=$(jq -r '[.userStories[] | select(.verification | type == "object" and .strategy == "visual")][0].verification.url' "$AIMI_ROOT/$TASKS_PATH")
  agent-browser --headed --session visual-follow open "$VISUAL_URL"
  ```

## Step 4: Wave Execution Loop

```
wave = 1
is_first_story_in_session = true
DESIGN_REVIEW_BUFFERS = {}  # key: story_id, value: {title, output}; populated by post-merge design reviewer
CONSOLE_BUFFER = {}         # key: story_id, value: ATTRIBUTION object; populated by post-merge console capture (see Console Error Attribution section)

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
    # WORKTREE WAVE (parallel with worktrees)
    # ========================================

    # All selected stories proceed — story data is fetched by each subagent via get-story-context
    full_stories = selected_stories

    # Proceed with worktree parallelism

    # ========================================
    # GROUP STORIES BY PROJECT — see Multi-Repo Handling section
    # ========================================

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
    #
    # Template selection: full for first story in session, compact for subsequent.
    # In a multi-story wave, the first story uses full_template only if is_first_story_in_session
    # is true; all others in the wave use compact_template.
    # In one tool-call turn, emit N Task calls (across ALL project groups):
    story_index = 0
    for full_story in full_stories:
        wt = all_worktrees[full_story.id]
        project_path = project_roots[wt.group_key] if wt.group_key != "DEFAULT" else null
        project_guidelines = PROJECT_GUIDELINES_MAP[wt.group_key] if wt.group_key != "DEFAULT" else PROJECT_GUIDELINES

        template = full_template if (is_first_story_in_session and story_index == 0) else compact_template

        Task(
            subagent_type: "general-purpose",
            model: <AGENT_MODELS.executor when not "inherit">,
            description: "Execute [full_story.id]: [full_story.title]",
            prompt: [story-executor SKILL.md [template] with:
                - WORKTREE_PATH = wt.worktree_path
                - PROJECT_PATH = project_path (only include if non-null)
                - PROJECT_GUIDELINES = project_guidelines
                - HEADED_MODE = (do NOT include for worktree stories — visual verification runs post-merge, not inside the worktree)
                - Omit the <visual_verification> section entirely for worktree stories
                  (the dev server cannot see worktree changes; verification runs after merge-all instead)
                - STORY_ID = full_story.id  ← only the id; no description, no criteria, no prototype HTML
                - Do NOT modify the tasks.json file — report result (success/failure + details)
            ]
        )
        story_index += 1

    is_first_story_in_session = false

    # All Tasks return in the same turn. Collect results.
    failed_stories = []
    succeeded_stories = []
    result_payload_by_id = {}  # full_story.id → parsed result_json object

    # ========================================
    # PARSE WORKER RESULT_JSON BLOCK (per story-executor SKILL.md Result Contract)
    # ========================================
    # The orchestrator's source of truth is the <result_json>...</result_json>
    # block at the END of each worker's final message. Prose outside the block
    # is debugging only and is NOT consumed here.
    #
    # Extraction rule (regex): the LAST occurrence in the message of
    #   <result_json>\s*({.*?})\s*</result_json>   (DOTALL, non-greedy)
    # is parsed as JSON. If the block is malformed, missing, or fails to parse,
    # fall back to the legacy heuristic: Task's own exit signal (succeeded/failed)
    # + commit verification below.
    #
    # Reading the structured block keeps the next orchestrator turn's input
    # token cost down — empirically a worker returns ~600 tokens of prose where
    # the orchestrator only consumes ~50-200 tokens of structured signal.

    for each Task result:
        payload = parse_result_json(Task.final_message_text)  # see extraction rule above
        if payload is not None:
            result_payload_by_id[full_story.id] = payload
            status = payload.get("status")
            if status == "ok":
                succeeded_stories.append(full_story)
            else:
                failed_stories.append(full_story)
        else:
            # Legacy fallback: trust Task's own success/failure signal.
            # Log: "[full_story.id] missing or malformed <result_json> — falling back to Task exit signal"
            if Task succeeded:
                succeeded_stories.append(full_story)
            else:
                failed_stories.append(full_story)

    # --- Post-Wave Processing ---

    # ========================================
    # COMMIT VERIFICATION (parallel path)
    # ========================================
    # Prefer the commit SHA from result_payload_by_id[full_story.id].commit when
    # present and non-null — cross-check it against git rev-parse HEAD in the
    # worktree. Mismatch → treat as no-commit (worker lied or aborted post-emit).
    # When result_json is absent, fall back to the legacy "HEAD differs from
    # base_sha" check unchanged.
    no_commit_stories = []
    verified_stories = []
    for full_story in succeeded_stories:
        wt = all_worktrees[full_story.id]
        worktree_head = git -C [wt.worktree_path] rev-parse HEAD
        payload = result_payload_by_id.get(full_story.id)

        if payload is not None and payload.get("commit"):
            # Cross-check declared SHA against actual HEAD (short-SHA prefix match OK)
            declared = payload["commit"]
            if not worktree_head.startswith(declared) and declared != worktree_head:
                # Declared commit not at HEAD — treat as no-commit
                no_commit_stories.append(full_story)
                continue

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
        # Prefer the structured failureCause over generic message when available
        payload = result_payload_by_id.get(full_story.id)
        cause = (payload.get("failureCause") if payload else None) or "Failed during parallel wave [wave]"
        $AIMI_CLI mark-failed [full_story.id] "[cause]"
        $AIMI_CLI cascade-skip [full_story.id]
        Report: "[full_story.id] failed: [cause]. Dependent stories cascade-skipped."

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
                # --- Extract knownGaps: prefer result_json.knownGaps, fall back to commit trailers ---
                # When result_payload_by_id[full_story.id].knownGaps is a non-empty array,
                # use those entries (one line each). Otherwise, fall back to grepping
                # KNOWN-GAP: trailers from the commit body for backward compat.
                ```bash
                mkdir -p .aimi/known-gaps
                # Pseudo: prefer payload; fall back to commit grep
                payload_gaps="${result_payload_by_id[full_story.id].knownGaps or []}"
                if [ -n "$payload_gaps" ] && [ "$payload_gaps" != "[]" ]; then
                  WORKER_GAPS=$(printf '%s\n' "$payload_gaps")
                else
                  WORKER_GAPS=$(git -C "[all_worktrees[full_story.id].worktree_path]" log -1 --format=%B | grep -E '^KNOWN-GAP:' || true)
                fi
                if [ -n "$WORKER_GAPS" ]; then
                  GAP_DATE=$(date +%Y-%m-%d)
                  GAP_FILE=".aimi/known-gaps/${GAP_DATE}-[full_story.id].md"
                  printf '%s\n' "$WORKER_GAPS" > "$GAP_FILE"
                fi
                ```

                $AIMI_CLI mark-complete [full_story.id]

                # --- Post-merge visual verification for visual stories ---
                # Session lifecycle: see Visual Follow Lifecycle section.
                # Capture sequence per story (when agent-browser is available):
                #   1. console --clear  ← drop logs accumulated from PRIOR story in this wave
                #   2. open <url>       ← navigate
                #   3. screenshot       ← visual snapshot
                #   4. console --json   ← capture this story's console output
                #   5. errors  --json   ← capture this story's uncaught exceptions
                # Per-story attribution depends on the --clear in step 1 — without it,
                # console buffer is wave-cumulative and last-story-merged eats the blame.
                if full_story.verification and full_story.verification.strategy == "visual" and full_story.verification.status == "pending":
                    if VISUAL_FOLLOW == true:
                        # Reuse the existing headed session (managed by execute.md)
                        agent-browser --session visual-follow console --clear
                        agent-browser --session visual-follow open [full_story.verification.url]
                        agent-browser --session visual-follow screenshot /tmp/verify-[full_story.id].png
                        CONSOLE_JSON=$(agent-browser --session visual-follow console --json)
                        ERRORS_JSON=$(agent-browser --session visual-follow errors --json)
                        # Read screenshot and compare against full_story.verification.expect
                        Read /tmp/verify-[full_story.id].png
                        Compare visual output against full_story.verification.expect

                        # Run console attribution pass (see "Console Error Attribution" section below)
                        ATTRIBUTION = attribute_console_errors(
                            console_json=CONSOLE_JSON,
                            errors_json=ERRORS_JSON,
                            wave_stories=succeeded_stories
                        )

                        if visual matches expectations:
                            $AIMI_CLI update-field [full_story.id] verification.status passed
                            Report: "[full_story.id] visual verification passed."
                        else:
                            $AIMI_CLI update-field [full_story.id] verification.status failed
                            Report: "[full_story.id] visual verification failed — [reason]. (advisory, not blocking)"

                        # Report attribution lines as advisory (do NOT toggle verification.status)
                        if ATTRIBUTION.has_errors:
                            Report: "[full_story.id] console: \(ATTRIBUTION.summary)"
                            # Push attribution into wave-level CONSOLE_BUFFER for the wave summary
                            CONSOLE_BUFFER[full_story.id] = ATTRIBUTION
                    else:
                        # No visual-follow session — headless verification
                        has_browser = command -v agent-browser
                        if has_browser:
                            agent-browser console --clear
                            agent-browser open [full_story.verification.url]
                            agent-browser screenshot /tmp/verify-[full_story.id].png
                            CONSOLE_JSON=$(agent-browser console --json)
                            ERRORS_JSON=$(agent-browser errors --json)
                            Read /tmp/verify-[full_story.id].png
                            Compare visual output against full_story.verification.expect

                            ATTRIBUTION = attribute_console_errors(
                                console_json=CONSOLE_JSON,
                                errors_json=ERRORS_JSON,
                                wave_stories=succeeded_stories
                            )

                            if visual matches expectations:
                                $AIMI_CLI update-field [full_story.id] verification.status passed
                            else:
                                $AIMI_CLI update-field [full_story.id] verification.status failed
                                Report: "[full_story.id] visual verification failed — [reason]. (advisory)"

                            if ATTRIBUTION.has_errors:
                                Report: "[full_story.id] console: \(ATTRIBUTION.summary)"
                                CONSOLE_BUFFER[full_story.id] = ATTRIBUTION

                            agent-browser close
                        else:
                            $AIMI_CLI update-field [full_story.id] verification.status skipped
                            Report: "[full_story.id] visual verification skipped — agent-browser not installed."

                # Non-visual stories: keep existing behavior
                elif full_story.verification and full_story.verification.status == "pending":
                    $AIMI_CLI update-field [full_story.id] verification.status passed

                Report: "[full_story.id] merged successfully."

                # --- Design Review (visual stories only) ---
                if full_story.verification and full_story.verification.strategy == "visual" and (metadata.prototypePaths is non-empty or full_story.implementation.prototypeAnchor is non-empty):
                    # 1. Resolve prototype path: prefer prototypeAnchor, fall back to metadata.prototypePaths[0]
                    REVIEW_PROTOTYPE_PATH = full_story.implementation.prototypeAnchor
                    if REVIEW_PROTOTYPE_PATH is empty:
                        REVIEW_PROTOTYPE_PATH = metadata.prototypePaths[0] (if the array is non-empty)

                    if REVIEW_PROTOTYPE_PATH is empty:
                        Report: "Design review skipped for [full_story.id] — no prototype available."
                    else:
                        # 2. Collect changed files from the worker's commit
                        ```bash
                        DESIGN_REVIEW_CHANGED_FILES=$(git -C "[all_worktrees[full_story.id].worktree_path]" show --name-only --pretty=format: HEAD | grep -v '^$')
                        ```

                        # 3. Spawn the reviewer in foreground (capture output)
                        DESIGN_REVIEW_OUTPUT = Task(
                            subagent_type: "aimi-engineering:design:aimi-design-implementation-reviewer",
                            model: <AGENT_MODELS.design when not "inherit">,
                            description: "Design review: [full_story.id]",
                            prompt: "Review the implementation of [full_story.id] ([full_story.title]).

Prototype: [REVIEW_PROTOTYPE_PATH]
Changed files:
[DESIGN_REVIEW_CHANGED_FILES]
Worktree: [all_worktrees[full_story.id].worktree_path]

Read the prototype file at the path above. Compare each visual element of the prototype against the changed files listed. Report PASS / DIVERGES / KNOWN-GAP verdicts with a brief diagnosis per element.

Output your full structured review under the heading '## Design Implementation Review'."
                        )

                        # 4. Store per-story buffer for Step 5 aggregation
                        DESIGN_REVIEW_BUFFERS[full_story.id] = {
                            title: full_story.title,
                            output: DESIGN_REVIEW_OUTPUT
                        }

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
# Per-project cleanup rule — see Multi-Repo Handling section.
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

### Visual Follow Session — Keep Open

See the Visual Follow Lifecycle section (Phase 4 — Keep Open on Completion).

If `VISUAL_FOLLOW=true`, do NOT close the `visual-follow` session.

Report: `"Visual follow session still open — close manually when done: agent-browser --session visual-follow close"`

## Console Error Attribution

Defines `attribute_console_errors()`, called by the per-story post-merge visual verification step above. Pure orchestrator-side reasoning — no new CLI calls, no new subagents. Adds ≤ 1 turn of orchestrator inference per wave (typically far less because most stories have 0 errors).

### Inputs

- `console_json` — JSON returned by `agent-browser console --json` for this story's verification page-load. Shape: `{"data":{"messages":[{"type":"log|warning|error|info","text":"...","args":[...]}]}}`. Messages with `type == "error"` and `type == "warning"` are the only ones considered; `log` / `info` are ignored.
- `errors_json` — JSON from `agent-browser errors --json`. Uncaught exceptions and unhandled promise rejections. Shape: `{"data":{"errors":[{"message":"...","stack":"..."}]}}`.
- `wave_stories` — the wave's `succeeded_stories` array, each carrying `id`, `title`, and `implementation.files[]`.

### Procedure

1. **Merge** the `messages` (filtered to type `error`/`warning`) and `errors` arrays into a flat list of `{kind, text, stack}` records where `kind ∈ {error, warning, exception}`.
2. **Drop the noise** — ignore well-known browser/extension noise that does not indicate code defects:
   - Lines matching `/extension:|chrome-extension:|moz-extension:/`
   - Lines matching `/DevTools failed to load source map/`
   - Lines matching `/Download the React DevTools/`
   - Lines whose `text` is empty after trim
3. **For each remaining record, attribute** by trying these strategies in order; first match wins, no fallthrough:
   - **a. Stack-trace file match**: parse `stack` for tokens that look like project paths (anything matching `/[A-Za-z0-9_./-]+\.(tsx?|jsx?|vue|svelte|rb|py|go|rs|java|kt)/`). For each path token, check whether it appears in any `wave_stories[*].implementation.files[]`. First story whose `files[]` contains the token → attributed.
   - **b. Text component-name match**: when no stack-trace match, scan the `text` for `PascalCase` identifiers (`/\b[A-Z][a-zA-Z0-9]+\b/`). For each, check whether any `wave_stories[*].implementation.files[]` contains a path with that identifier as a basename component (e.g., text mentions `ContributorsCard` → match story with `…/ContributorsCard/index.tsx`). First match → attributed.
   - **c. Wave-shared**: when neither matches, attribute to the wave as a whole with reason `"shared module or ambiguous origin"`.
4. **Build the `ATTRIBUTION` object**:
   ```
   ATTRIBUTION = {
     has_errors: <bool — true when any error|exception remains after de-noising>,
     summary: <one-line string: e.g., "2 errors, 1 warning (1 attributed: US-003)"
              when this is the per-story output; or "2 errors, 1 warning, 1 wave-shared">,
     attributed: [{kind, text, story_id, attribution_method: "stack-file"|"text-component"|"wave-shared"}],
   }
   ```
5. **Per-story output** (when called from the post-merge step):
   - Filter `attributed` to entries where `story_id == full_story.id` for the `Report` line.
   - Push the full per-story attribution object into `CONSOLE_BUFFER[full_story.id]` so the wave summary can emit a consolidated view.

### Confidence and policy

- Attribution is **advisory only**. It NEVER toggles `verification.status` and NEVER triggers a cascade-skip. A failed visual story stays failed only when the screenshot does not match `verification.expect` — console errors are reported in parallel.
- When attribution method is `text-component` or `wave-shared`, the report line MUST include the word "likely" (e.g., `"likely US-004 (FooComponent ref)"`) so the user knows it is heuristic.

### Wave summary section (rendered at end of wave)

After the per-story post-merge loop finishes, if `CONSOLE_BUFFER` has any entries for the wave just completed, append to the wave summary report:

```
Console (advisory):
  - US-003: 2 errors (attributed via stack: ContributorsCard/index.tsx)
  - US-005: 1 error (likely from text match: UserProfile)
  - wave-shared: 1 warning (could not attribute to a single story)
```

This is ADDITIVE to the existing `Wave [wave] complete: ...` line — does not replace it.

## Step 5: Completion

When execution ends (all stories complete, or deadlock detected):

### If all stories complete:

Count commits on this branch:
```bash
git log --oneline $DEFAULT_BRANCH..HEAD | wc -l
```

Check for any remaining pending gates across all stories:
```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
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

Aggregate known-gap files from this run:
```bash
if [ -d .aimi/known-gaps ] && [ -n "$(ls .aimi/known-gaps/ 2>/dev/null)" ]; then
  echo ""
  echo "## Known Gaps"
  for gap_file in .aimi/known-gaps/*.md; do
    [ -f "$gap_file" ] || continue
    story_id=$(basename "$gap_file" .md | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//')
    echo ""
    echo "### $story_id"
    cat "$gap_file"
  done
fi
```

If `DESIGN_REVIEW_BUFFERS` is non-empty, append:
```
## Design Review

For each entry in DESIGN_REVIEW_BUFFERS (keyed by story id, insertion order):

### [story_id]: [entry.title]

[entry.output]
```

If `DESIGN_REVIEW_BUFFERS` is empty, omit the `## Design Review` section entirely.

If `CONSOLE_BUFFER` is non-empty, append:
```
## Console (advisory)

For each entry in CONSOLE_BUFFER (keyed by story id, insertion order):

### [story_id]
- [N] errors, [M] warnings, [E] exceptions
[For each entry in attributed where story_id matches:]
  - [kind] [text] (attribution: [attribution_method])

If any record was attributed via "text-component" or "wave-shared", prefix the
record's line with "likely:" so the user knows the call is heuristic.

[After per-story groups, if any wave-shared entries exist:]
### wave-shared
- [N] message(s) could not be attributed to a single story
  - [kind] [text]

Reminder: Console output is advisory. It does NOT change `verification.status`
and never blocks the wave — failed visual stories still fail on screenshot
mismatch only.
```

If `CONSOLE_BUFFER` is empty, omit the `## Console` section entirely.

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
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
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
