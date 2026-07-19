---
name: aimi:execute
description: Execute all pending stories autonomously with wave-based parallelism
argument-hint: "[--phase <N>]"
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

This rule is unchanged, but does not apply in phase mode — see Phase Mode: Worktree Naming and CWD below, which supersedes `project_root` with `PHASE_CONTAINER_PATH` for the duration of a claimed phase's execution.

## Phase Mode: Worktree Naming and CWD

This section is the single source of truth for how `PHASE_MODE=true` (see Step 1's Phase Mode Detection and Step 1.7's Phase Claim) changes worktree naming and working-directory handling in Step 4's wave loop and its cleanup passes. All call sites below reference it by name. It only applies once a phase has been claimed; when `PHASE_MODE=false` none of this applies and every rule below reduces to the existing flat-mode behavior unchanged.

### Why Story Worktrees Are Phase-Qualified

Git branch names are repository-global. Two parallel `/aimi:execute` sessions each running their own phase container would otherwise mint identical unqualified story branches (e.g. both minting `US-003`) and collide. Story worktree/branch names in phase mode are therefore `<PHASE_BRANCH>-<story.id>` instead of `<branchName>-<story.id>` — qualified by the full phase branch, not just the phase id, so they stay collision-free even against a sibling phase container running concurrently for the same feature.

### CWD For Every Worktree Operation

Every `$WORKTREE_MGR create`/`merge-all`/`remove`/`list` call for a phase's stories runs with CWD set to `PHASE_CONTAINER_PATH`, never `AIMI_ROOT` and never a `project_root` from the Multi-Repo Handling grouping above. Two reasons:

1. **`merge-all` checks out its target branch against whatever repo its CWD belongs to.** `worktree-manager.sh`'s `GIT_ROOT` is computed per-invocation from CWD (`git rev-parse --show-toplevel`), and `merge-all <story-worktree-names> --into <target-branch>` issues a bare `git checkout <target-branch>` against that root. Run from `AIMI_ROOT`, that would check the phase branch out onto the main working tree — forbidden by the Main Working Tree Untouched Invariant below. Run from `PHASE_CONTAINER_PATH`, `GIT_ROOT` resolves to the phase worktree's own root instead, and story worktrees nest at `PHASE_CONTAINER_PATH/.worktrees/<story-worktree-name>` — a pattern `worktree-manager.sh` already supports unmodified, since a linked worktree's own `git rev-parse --show-toplevel` returns its own path, not the main repo's.
2. **Every Bash call is an isolated shell** (Step 0). `PHASE_CONTAINER_PATH` does not persist across calls on its own — each call that needs it either `cd`s to it explicitly at the top of the call, or passes it via `git -C`/`$WORKTREE_MGR` arguments, exactly like `$AIMI_CLI`/`$WORKTREE_MGR` themselves are re-resolved per call.

Concretely, in Step 4's wave loop, wherever the pseudocode below reads `project_root`, `branchName`, or `[branchName]-US-*` for a phase-mode session, substitute:

| Flat mode (`PHASE_MODE=false`, unchanged) | Phase mode (`PHASE_MODE=true`) |
|---|---|
| `worktree_name = "[branchName]-[story.id]"` | `worktree_name = "[PHASE_BRANCH]-[story.id]"` |
| `cd [project_root]` before create/merge-all/remove | `cd [PHASE_CONTAINER_PATH]` before create/merge-all/remove |
| `git -C [project_root] rev-parse [branchName]` (base_sha) | `git -C [PHASE_CONTAINER_PATH] rev-parse [PHASE_BRANCH]` |
| `$WORKTREE_MGR merge-all [...] --into [branchName]` | `$WORKTREE_MGR merge-all [...] --into [PHASE_BRANCH]` |
| Cleanup scan matches `"[branchName]-US-*"` | Cleanup scan matches `"[PHASE_BRANCH]-US-*"` |

### Main Working Tree Untouched Invariant

For the entire span of a phase's execution — from the moment it is claimed (Step 1.7) through the last wave's merge — `AIMI_ROOT`'s `git rev-parse HEAD` and `git status --porcelain` never change. Every commit for the phase lands only on `PHASE_BRANCH` inside `PHASE_CONTAINER_PATH`. This holds automatically once every rule above is followed: nothing in phase mode ever `cd`s to `AIMI_ROOT` (or runs a mutating git command against it), and Step 2's Main Repo Branch Setup is skipped entirely in phase mode (see Step 2).

### Concurrency Source

`MAX_CONCURRENCY` (Step 3.2) is read from the claimed phase's own tasks file (`PHASE_TASKS_PATH`), not any feature-root or global file — this is the same per-phase value the worktree-budget guard hook enforces against nested story-worktree creation inside the container, so the phase's own setting (not a global default) governs how many story worktrees can exist under it at once.

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

**Generalized rule (composes with phase mode):** the shared prefix is not limited to the flat date+feature form above. When the two files instead live inside a claimed phase's own directory (`.aimi/tasks/<feature>/phase-<N>-<slug>/`) and share the `<feature>-phase-<N>` prefix — e.g. `<feature>-phase-<N>-frontend-tasks.json` / `-backend-tasks.json` — this is the same paired-split match, just phase-qualified. This flat-mode detection pass (driven by `find-tasks-all`, which runs before Step 1's Phase Mode Detection has resolved a phase branch) never itself matches that phase-prefixed form in practice, since a live phase's two split files are the *only* pair sharing that prefix and phase-qualified worktree/branch naming additionally requires `PHASE_BRANCH` — not yet known this early. The phase-prefixed case is therefore matched and executed by **Phase-Mode Paired Split** (Step 1.7, after the phase branch is claimed and the container exists), which reuses this exact matching rule — same "two files, one `-frontend-tasks.json`, one `-backend-tasks.json`, shared prefix" test — scoped to just that phase's own directory. This subsection's own flat-prefix detection and everything below it (worktree creation from `$DEFAULT_BRANCH`, sub-orchestrator spawn, merge target, Aggregated Completion report, cleanup) is unaffected and runs byte-for-byte as before.

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

### Phase Mode Detection

Determine whether the tasks file `init-session` discovered belongs to a phase/milestone roadmap (the nested `.aimi/tasks/<feature>/phase-N[.M]-<slug>/<feature>-phase-N-tasks.json` layout from outline 04) or is a flat v3.3 file (`.aimi/tasks/<date>-<feature>-tasks.json`), and store the result as `PHASE_MODE`:

```bash
TASKS_PATH="[tasks path from the init-session output above]"
FEATURE_DIR=$(dirname "$(dirname "$TASKS_PATH")")
if [ -f "$FEATURE_DIR/roadmap.json" ]; then
  PHASE_MODE=true
  FEATURE=$(basename "$FEATURE_DIR")
  ROADMAP_PATH="$FEATURE_DIR/roadmap.json"
else
  PHASE_MODE=false
fi
```

This needs no new CLI call: a flat file's tasks path is a direct child of `.aimi/tasks/` (e.g. `.aimi/tasks/2026-02-24-feature-tasks.json`), so `$FEATURE_DIR` resolves to `.aimi` — which never contains `roadmap.json`. A nested phase file's tasks path is `.aimi/tasks/<feature>/phase-N[.M]-<slug>/<feature>-phase-N-tasks.json`, so `$FEATURE_DIR` resolves to `.aimi/tasks/<feature>` — exactly where `roadmap-init` writes `roadmap.json`. This is the same directory-arithmetic `cmd_list_archivable` already uses to group nested files by feature.

**When `PHASE_MODE=false` (flat v3.3 file, no `roadmap.json` sibling): execute.md runs byte-for-byte as it does today.** No further phase-mode logic applies anywhere in this document — Step 1.7 (Phase Claim) is skipped entirely, Step 2 checks out `branchName` directly in the main working tree, and Step 4's story worktrees are named `[branchName]-[story.id]` exactly as now. Phase mode is a parallel path added alongside the flat path; it never changes the flat path's behavior.

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

## Step 1.7: Phase Claim

**Skip this step entirely if `PHASE_MODE` is false** (see Phase Mode Detection in Step 1) — proceed straight to Step 2. The rest of this step assumes `PHASE_MODE=true`.

### Parse --phase Override

Scan `$ARGUMENTS` for an explicit `--phase <N>` token (mirrors the `--root <path>` extraction style used by `/aimi:plan`):

```bash
case " $ARGUMENTS " in
  *" --phase "*)
    PHASE_OVERRIDE=$(echo "$ARGUMENTS" | sed -n 's/.*--phase[[:space:]]\+\([0-9][0-9.]*\).*/\1/p')
    ;;
  *)
    PHASE_OVERRIDE=""
    ;;
esac
```

If `PHASE_OVERRIDE` is non-empty but does not match `^[0-9]+(\.[0-9]+)?$`, report `Invalid --phase value: [PHASE_OVERRIDE]. Must be a numeric phase id.` and STOP.

### Resolve Session Identity

`roadmap-claim`'s stale-claim recovery needs a PID that stays alive for the whole `/aimi:execute` session, not the PID of one isolated Bash call (`$$` would be a different, already-dead process by the time any other session checks liveness). `$PPID` inside a Bash tool call is the PID of the process that spawns each isolated shell — the persistent host process for this session — so it stays constant across calls even though `$$` does not.

```bash
SESSION_ID="${CLAUDE_SESSION_ID:-execute-$PPID}"
SESSION_PID=$PPID
```

Compute this once; both `$CLAUDE_SESSION_ID` and `$PPID` re-derive identically on every subsequent Bash call within the same session, so re-running the two lines above anywhere this document calls `roadmap-claim` or `roadmap-release-claim` yields the same `SESSION_ID`/`SESSION_PID` values.

### Claim the Phase

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
if [ -n "$PHASE_OVERRIDE" ]; then
  CLAIM_JSON=$($AIMI_CLI roadmap-claim --feature "$FEATURE" --session-id "$SESSION_ID" --session-pid "$SESSION_PID" --phase "$PHASE_OVERRIDE" 2>&1)
else
  CLAIM_JSON=$($AIMI_CLI roadmap-claim --feature "$FEATURE" --session-id "$SESSION_ID" --session-pid "$SESSION_PID" 2>&1)
fi
CLAIM_EXIT=$?
```

`roadmap-claim` is a single atomic, flock-guarded check-and-set (mirrors the atomic-write pattern already documented for `story-merge`). It auto-releases any claim whose recorded PID fails a liveness probe, then:

- **No `--phase` (auto mode):** claims the lowest-numeric-id phase that is `pending`/`planned`, unclaimed, and whose `dependsOn` phases are all `completed`. If the top candidate loses a claim race to a concurrent session, the CLI falls through internally to the next eligible phase and returns that one — this step contains no retry loop of its own, it consumes whatever phase the single call reports back as claimed.
- **With `--phase <N>` (explicit override):** claims phase `N` only if it is eligible. If phase `N` is ineligible, the call never falls through to a different phase.
- **Self-reclaim:** if this exact session already owns an unreleased claim on a phase still in `pending`/`planned`/`in_progress` (matching `--phase N` when an override was given, or any such phase in auto mode), the call returns that same phase again instead of erroring — this is what makes re-running `/aimi:execute` on an already-claimed phase idempotent (see Resuming Execution).

**On success (`CLAIM_EXIT=0`):** `CLAIM_JSON` is the claimed phase object. Extract:

```bash
PHASE_ID=$(printf '%s' "$CLAIM_JSON" | jq -r '.id')
PHASE_DIR=$(printf '%s' "$CLAIM_JSON" | jq -r '.dir')
PHASE_SLUG=$(printf '%s' "$CLAIM_JSON" | jq -r '.slug // ""')
PHASE_BRANCH=$(printf '%s' "$CLAIM_JSON" | jq -r '.branch // ""')
FEATURE_TYPE=$(jq -r '.metadata.type // "feat"' "$AIMI_ROOT/$TASKS_PATH")
```

If `PHASE_BRANCH` is empty (the phase carries no pre-assigned `.branch`), compute it from the `type/<feature>-phase-<N>-<slug>` convention:

```bash
if [ -z "$PHASE_BRANCH" ]; then
  PHASE_BRANCH="${FEATURE_TYPE}/${FEATURE}-phase-${PHASE_ID}-${PHASE_SLUG}"
fi
```

Validate `PHASE_BRANCH` against `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$` (the same regex Step 1.6 already enforces for user-supplied base branches). If it fails, report the invalid branch name and STOP.

### Report Stale Claim Releases

`CLAIM_JSON.staleReleased` is a (possibly empty) array the CLI populates whenever this exact `roadmap-claim` call auto-released one or more dead-PID claims before evaluating eligibility (see the PID-alive check described above). Report each released entry with this exact line, substituting the real values:

```bash
STALE_COUNT=$(printf '%s' "$CLAIM_JSON" | jq '.staleReleased | length')
if [ "$STALE_COUNT" -gt 0 ]; then
  while IFS=$'\t' read -r sr_id sr_sid sr_pid; do
    [ -z "$sr_id" ] && continue
    echo "released stale claim on phase $sr_id (session $sr_sid pid $sr_pid not alive)"
  done < <(printf '%s' "$CLAIM_JSON" | jq -r '.staleReleased[] | [(.id|tostring), .sessionId, (.pid|tostring)] | @tsv')
fi
```

This is a report of automatic recovery that already happened inside the atomic `roadmap-claim` call above — it never changes the outcome of this session's own claim.

### Two-Stage Overlap Guard

Before transitioning the newly claimed phase to `in_progress`, check whether any other phase in this roadmap is currently `in_progress` (in a sibling `/aimi:execute` session) and, if so, whether the two phases' declared work overlaps. This guard is **soft in both interactive and agent mode** — it never blocks or fails the claim itself, since `roadmap-claim`'s atomic check-and-set already succeeded before this section runs. Every read of a sibling phase's state below goes through `$AIMI_CLI roadmap-get` / `$AIMI_CLI phase-overlap` — never a direct Read of a phase directory this session does not own.

**Stage 1 (always runs) — coarse `areas` comparison against every `in_progress` sibling, then stage 2 (gated) — exact file intersection via the `phase-overlap` CLI verb, only for siblings whose areas intersected:**

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
ROADMAP_ALL_JSON=$($AIMI_CLI roadmap-get --feature "$FEATURE")
AREAS_X=$(printf '%s' "$ROADMAP_ALL_JSON" | jq -c --argjson x "$PHASE_ID" '(.phases[] | select(.id == $x) | .areas) // []')

OVERLAP_WARNINGS_JSON='[]'
while IFS= read -r y_id; do
  [ -z "$y_id" ] && continue
  AREAS_Y=$(printf '%s' "$ROADMAP_ALL_JSON" | jq -c --argjson y "$y_id" '(.phases[] | select(.id == $y) | .areas) // []')
  AREA_OVERLAP_COUNT=$(jq -n --argjson a "$AREAS_X" --argjson b "$AREAS_Y" '[$a[] | . as $v | select($b | index($v) != null)] | length')
  if [ "$AREA_OVERLAP_COUNT" -gt 0 ]; then
    # Stage 2, gated on stage 1's non-empty area intersection. phase-overlap
    # failing here (e.g. the sibling has not been rolling-wave expanded yet,
    # no tasks.json) is not an error for this soft guard -- skip that sibling.
    if OVERLAP_JSON=$($AIMI_CLI phase-overlap "$FEATURE" "$PHASE_ID" "$y_id" 2>/dev/null); then
      FILES_COUNT=$(printf '%s' "$OVERLAP_JSON" | jq '.overlapping_files | length')
      if [ "$FILES_COUNT" -gt 0 ]; then
        FILES_ARR=$(printf '%s' "$OVERLAP_JSON" | jq -c '.overlapping_files')
        OVERLAP_WARNINGS_JSON=$(printf '%s' "$OVERLAP_WARNINGS_JSON" | jq --argjson y "$y_id" --argjson files "$FILES_ARR" '. + [{phaseId: $y, files: $files}]')
      fi
    fi
  fi
done < <(printf '%s' "$ROADMAP_ALL_JSON" | jq -r --argjson x "$PHASE_ID" '[.phases[] | select(.status == "in_progress" and .id != $x)] | .[].id')
```

**When `OVERLAP_WARNINGS_JSON` is `[]`** (no `in_progress` sibling, or every sibling's stage-1 area comparison was empty): skip silently — no prompt, no log line. Proceed straight to the status transition below.

**When `OVERLAP_WARNINGS_JSON` is non-empty**, for each `{phaseId: Y_ID, files}` entry in order:

- **`INTERACTIVE_MODE=picker`:** use **AskUserQuestion**:
  ```
  Phase [PHASE_ID] and in-progress phase [Y_ID] both touch:
  [one line per path in files]

  A — Proceed in parallel anyway
  B — Wait for phase [Y_ID] to finish before claiming
  C — Abort this claim attempt
  ```
  - **Option A:** continue to the next entry (or, if this was the last entry, proceed to the status transition below).
  - **Option B or C:** release the claim this session just took, and STOP — do not evaluate any remaining entries:
    ```bash
    AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
    : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
    $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
    ```
    Report `Claim on phase [PHASE_ID] released — [waiting for phase [Y_ID] to finish | claim attempt aborted] per user choice.` and STOP.
- **`INTERACTIVE_MODE=agent`:** log a one-line warning per entry and proceed automatically — never release the claim:
  ```
  Warning: phase [PHASE_ID] and in-progress phase [Y_ID] share file(s): [comma-joined files] (agent-mode: proceeding in parallel)
  ```
  After logging every entry, continue to the status transition below.

**Immediately after a successful claim, transition the phase to `in_progress`.** This is a SEPARATE call — `roadmap-claim` manages only the claim sub-object (`claimedBy`/`claimedAt`/`claimedPid`) and never drives status itself, so this step contains exactly one roadmap-status-mutating call beyond the claim:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
if ! SET_STATUS_ERR=$($AIMI_CLI roadmap-set-status --feature "$FEATURE" --phase "$PHASE_ID" --status in_progress 2>&1); then
  echo "ERROR: could not transition phase $PHASE_ID to in_progress:" >&2
  echo "$SET_STATUS_ERR" >&2
  echo "roadmap.json and this phase's tasks file disagree. Run: $AIMI_CLI roadmap-reconcile --feature \"$FEATURE\"" >&2
  exit 1
fi
```

Do **not** swallow this call's exit status. Every state a claim can hand back — `pending`, `planned`, `in_progress` (crashed-session resume) and `verification_failed` (re-verify retry) — has an explicit `→ in_progress` transition, including the idempotent `in_progress → in_progress`. So a rejection here is never routine: it means the phase is in a state the claim should not have returned, i.e. roadmap.json has diverged from the phase's tasks file. Failing loudly and pointing at `roadmap-reconcile` is the recovery path; an earlier `|| true` hid this and let the phase run to completion only to fail at the final `completed` transition.

**On failure (`CLAIM_EXIT` is 3 or 4):** `CLAIM_JSON` holds the CLI's stderr.

- **Auto mode, `CLAIM_EXIT=4` (no phase remains pending/planned):** report `No eligible phase — every phase in [FEATURE]'s roadmap is already claimed, completed, or terminal.` and STOP.
- **Auto mode, `CLAIM_EXIT=3` (all remaining phases blocked):** list every ineligible phase with its specific reason, taken verbatim from `CLAIM_JSON`'s `phase N: <reason>` lines (mirrors the "Deadlock detected" reporting style in Step 4):
  ```
  No phase is ready to claim:
  [one line per blocked phase, from CLAIM_JSON]

  Resolve the blocking dependency, or run /aimi:execute --phase <N> to override.
  ```
  STOP.
- **Explicit override, either exit code:** report the specific reason `CLAIM_JSON` gives for phase `PHASE_OVERRIDE` (unmet dependency, still claimed by a live session, wrong status, or not found) — never a generic "not ready" message — and STOP. Do not fall through to a different phase.

### Create or Reuse the Phase Container

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
cd "$AIMI_ROOT"
if [ -n "$BASE_BRANCH" ]; then
  CONTAINER_BASE="$BASE_BRANCH"
else
  CONTAINER_BASE="$DEFAULT_BRANCH"
fi
$WORKTREE_MGR create "$PHASE_BRANCH" --from "$CONTAINER_BASE"
```

`<container-base>` is `BASE_BRANCH` when Step 1.6 set one, otherwise `DEFAULT_BRANCH` — reusing the exact default-branch/base-selection values Steps 1.5–1.6 already computed against the main root.

`$WORKTREE_MGR create` prints the worktree path and, when the target directory already exists, reuses it silently instead of recreating it — so calling it idempotently on every claim (including a self-reclaim resume) is sufficient; no separate reuse-detection branch is needed. The path is deterministic given `AIMI_ROOT` and `PHASE_BRANCH`:

```bash
PHASE_CONTAINER_PATH="$AIMI_ROOT/.worktrees/$PHASE_BRANCH"
```

### Detect a Full-Stack Split Inside This Phase

Before pointing the session at a single governing tasks file, check whether this phase's own directory instead holds a full-stack paired split — the phase-prefixed generalization of Step 0.9's Paired Split Detection matching rule (see above), scoped to just this phase's own directory:

```bash
PHASE_DIR_PATH="$AIMI_ROOT/.aimi/tasks/$FEATURE/$PHASE_DIR"
PHASE_FE_TASKS="$PHASE_DIR_PATH/$FEATURE-phase-$PHASE_ID-frontend-tasks.json"
PHASE_BE_TASKS="$PHASE_DIR_PATH/$FEATURE-phase-$PHASE_ID-backend-tasks.json"
if [ -f "$PHASE_FE_TASKS" ] && [ -f "$PHASE_BE_TASKS" ]; then
  PHASE_SPLIT_MODE=true
else
  PHASE_SPLIT_MODE=false
fi
```

**When `PHASE_SPLIT_MODE=true`:** skip **Point the session at this phase's own tasks file** below entirely — a split phase has no single governing tasks file for this session to point at — and, after Path and State Notes immediately below, proceed to **Phase-Mode Paired Split** instead of Step 2.

**When `PHASE_SPLIT_MODE=false` (unchanged):** continue with **Point the session at this phase's own tasks file** below exactly as before.

**Point the session at this phase's own tasks file** so Steps 2–5 operate on the claimed phase, not whichever nested file `init-session`'s mtime-based auto-discovery happened to pick in Step 1 (a feature with multiple materialized phase tasks files could have a more-recently-touched sibling phase that is not the one just claimed):

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
PHASE_TASKS_PATH="$AIMI_ROOT/.aimi/tasks/$FEATURE/$PHASE_DIR/$FEATURE-phase-$PHASE_ID-tasks.json"
$AIMI_CLI init-session --file "$PHASE_TASKS_PATH"
```

If this errors with "File not found," the claimed phase has not been planned yet. Report:
```
Phase [PHASE_ID] is claimed but has no tasks file yet ([PHASE_TASKS_PATH]).
Run /aimi:plan --phase [PHASE_ID] to materialize it, then re-run /aimi:execute.
```
Release the claim so it does not block other sessions, then STOP:
```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
```

### Path and State Notes

From this point forward, for the remainder of this phase's execution:

- Every Bash call that touches this phase's git state passes `PHASE_CONTAINER_PATH` explicitly — `cd "$PHASE_CONTAINER_PATH"` at the top of the call, or `git -C "$PHASE_CONTAINER_PATH"` / `$WORKTREE_MGR` invocations that take it as an argument — never assuming a CWD persisted from a prior call. This is the same "each Bash tool call is an isolated shell" rule from Step 0, applied to the container path instead of `AIMI_ROOT`. See Phase Mode: Worktree Naming and CWD above for how this threads through Step 4's wave loop.
- `$AIMI_CLI` calls issued with CWD inside `PHASE_CONTAINER_PATH` still resolve to the main root's central `.aimi/` state with no special-casing required: `.aimi/` is gitignored, so it is absent from the container's checkout. `find_aimi_root`'s upward directory walk starts inside `PHASE_CONTAINER_PATH` (`<GIT_ROOT>/.worktrees/<phase-branch>`), finds no `.aimi/` there or in `.worktrees/`, and continues up through `<GIT_ROOT>` where the real `.aimi/` lives — passing straight through the extra nesting.

## Phase-Mode Paired Split

**Skip this entire section if `PHASE_SPLIT_MODE` is false** — proceed straight to Step 2 (the unchanged, single-file phase-mode flow described everywhere above). The rest of this section assumes `PHASE_SPLIT_MODE=true`: this phase's own directory holds a full-stack paired split (`$PHASE_FE_TASKS` / `$PHASE_BE_TASKS`), and this section composes that split with the phase container `Step 1.7` already claimed and created — per the binding brainstorm decision that full-stack split and phase mode nest rather than being mutually exclusive.

Every Bash call in this section passes `$PHASE_CONTAINER_PATH` explicitly, exactly like the rest of phase mode (see Path and State Notes above) — never a bare relative path, never `AIMI_ROOT`.

### Derive and Validate Split Branch Names

```bash
FRONTEND_BRANCH="${PHASE_BRANCH}-frontend"
BACKEND_BRANCH="${PHASE_BRANCH}-backend"
```

Validate both against `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$` (the same regex Step 1.7 already validated `PHASE_BRANCH` against). If either fails, report the invalid branch name and STOP — do not create any worktree. (In practice this can only fail if `PHASE_BRANCH` itself changed since Step 1.7's own validation; the check is defense-in-depth, not expected to trigger.)

### Create Split Worktrees

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
cd "$PHASE_CONTAINER_PATH"
$WORKTREE_MGR create "$FRONTEND_BRANCH" --from "$PHASE_BRANCH"
$WORKTREE_MGR create "$BACKEND_BRANCH" --from "$PHASE_BRANCH"
```

CWD is `$PHASE_CONTAINER_PATH` — never `$DEFAULT_BRANCH`'s checkout, never `AIMI_ROOT` — so, mirroring the CWD rule Phase Mode: Worktree Naming and CWD already establishes for individual story worktrees, both split worktrees nest at `$PHASE_CONTAINER_PATH/.worktrees/$FRONTEND_BRANCH` and `$PHASE_CONTAINER_PATH/.worktrees/$BACKEND_BRANCH` — inside the phase container's own worktree tree, not a sibling of it under `AIMI_ROOT/.worktrees/`, and branched from `$PHASE_BRANCH`, not `$DEFAULT_BRANCH`.

```bash
FRONTEND_WORKTREE_PATH="$PHASE_CONTAINER_PATH/.worktrees/$FRONTEND_BRANCH"
BACKEND_WORKTREE_PATH="$PHASE_CONTAINER_PATH/.worktrees/$BACKEND_BRANCH"
```

### Spawn Split Sub-Orchestrators

Report:
```
Phase [PHASE_ID] full-stack split detected:
  Frontend: [PHASE_FE_TASKS] (branch: [FRONTEND_BRANCH])
  Backend:  [PHASE_BE_TASKS] (branch: [BACKEND_BRANCH])

Spawning parallel execution flows inside the phase container...
```

In a **single tool-call turn**, emit two foreground Tasks. Each runs execute.md's **Steps 2–5 only** — never Step 1's Phase Mode Detection and never Step 1.7's Phase Claim, both of which are already resolved by this parent session; a sub-orchestrator that re-derived or re-claimed the phase itself would either double-claim it or (since it has a different session identity than the parent) fail the claim outright:

```
Task(
    subagent_type: "general-purpose",
    model: <AGENT_MODELS.executor when not "inherit">,
    description: "Execute frontend split for phase [PHASE_ID]: [PHASE_FE_TASKS]",
    prompt: [execute.md Steps 2–5, with the following pre-set — do not re-derive:
        - PHASE_MODE = true
        - PHASE_BRANCH = [FRONTEND_BRANCH]
        - PHASE_CONTAINER_PATH = [FRONTEND_WORKTREE_PATH]
        - PHASE_TASKS_PATH = [PHASE_FE_TASKS]   (Step 3.2 reads maxConcurrency from this)
        - $AIMI_CLI init-session --file [PHASE_FE_TASKS]
        - Skip Step 2's Main Repo Branch Setup (PHASE_MODE=true skips it exactly as
          the single-file case already does) and skip Step 1.7 entirely
        - Run Step 3 onward (reset-orphaned, validate-stories, wave loop, Post-Loop
          Cleanup) using the Phase Mode: Worktree Naming and CWD substitution table
          exactly as written, with the pre-set PHASE_BRANCH/PHASE_CONTAINER_PATH
          above standing in for the outer phase's own values — so this
          sub-orchestrator's own story worktrees are named
          "[FRONTEND_BRANCH]-[story.id]", created --from [FRONTEND_BRANCH], and
          merged via merge-all --into [FRONTEND_BRANCH] with CWD inside
          [FRONTEND_WORKTREE_PATH]
        - Skip this file's own Phase Completion section and Step 5 entirely — the
          parent aggregates completion after both Tasks return (see below)
        - PROJECT_GUIDELINES = PROJECT_GUIDELINES
    ]
)

Task(
    subagent_type: "general-purpose",
    model: <AGENT_MODELS.executor when not "inherit">,
    description: "Execute backend split for phase [PHASE_ID]: [PHASE_BE_TASKS]",
    prompt: [execute.md Steps 2–5, with the following pre-set — do not re-derive:
        - PHASE_MODE = true
        - PHASE_BRANCH = [BACKEND_BRANCH]
        - PHASE_CONTAINER_PATH = [BACKEND_WORKTREE_PATH]
        - PHASE_TASKS_PATH = [PHASE_BE_TASKS]
        - $AIMI_CLI init-session --file [PHASE_BE_TASKS]
        - Same substitutions as the frontend Task above, scoped to the backend
          split: story worktrees "[BACKEND_BRANCH]-[story.id]", created --from
          [BACKEND_BRANCH], merged via merge-all --into [BACKEND_BRANCH] with CWD
          inside [BACKEND_WORKTREE_PATH]
        - Skip this file's own Phase Completion section and Step 5, exactly as the
          frontend Task
        - PROJECT_GUIDELINES = PROJECT_GUIDELINES
    ]
)
```

Each sub-orchestrator's individual story-level merges therefore land on its **own** split branch (`[FRONTEND_BRANCH]` / `[BACKEND_BRANCH]`) — never `$DEFAULT_BRANCH`, never `AIMI_ROOT`, and never the sibling split's worktree or branch. This reuses the existing phase-mode Step 4 wave-loop machinery unmodified, one level deeper, with the split worktree standing in for the outer `PHASE_CONTAINER_PATH` and the split branch standing in for the outer `PHASE_BRANCH`.

After both Tasks return, collect each one's completed-story count and failure list.

#### Nested Concurrency

Each split's own `metadata.maxConcurrency` governs only its own sub-orchestrator's wave loop — the frontend split's limit never governs the backend split's worktree creation, or vice versa, and neither is governed by the phase's `roadmap.json` or by any single phase-level tasks file (there is none, in split mode). This falls out of the existing worktree-budget pre-bash-dispatcher hook with **no code change**: `_select_governing_tasks_file` (`hooks/pre-bash-dispatcher.py`) picks the candidate tasks file among every `.aimi/tasks/**/*-tasks.json` whose `metadata.branchName` exactly matches the git branch checked out at the `git worktree add` command's CWD. A story worktree created inside the frontend sub-orchestrator's wave loop runs with CWD inside `$FRONTEND_WORKTREE_PATH` (branch `$FRONTEND_BRANCH`); `plan.md`'s Phase 4 metadata patch writes the frontend split file's `metadata.branchName` as exactly that same value (see Phase 3e/Phase 4's `--phase-aware` composition), so the hook's branch-match resolves to the frontend split's own file uniquely — the backend file's `metadata.branchName` differs (`...-backend`), so it never matches.

### Aggregated Completion Report (Phase-Mode Paired Split)

Report — computed against `$PHASE_BRANCH`, never `$DEFAULT_BRANCH`:

```
## Execution Complete (Phase [PHASE_ID] — Paired Mode)

Frontend file: [PHASE_FE_TASKS]
  Branch: [FRONTEND_BRANCH]
  Stories completed: [count from frontend Task result]
  Commits: git -C "$PHASE_CONTAINER_PATH" log --oneline [PHASE_BRANCH]..[FRONTEND_BRANCH] | wc -l

Backend file: [PHASE_BE_TASKS]
  Branch: [BACKEND_BRANCH]
  Stories completed: [count from backend Task result]
  Commits: git -C "$PHASE_CONTAINER_PATH" log --oneline [PHASE_BRANCH]..[BACKEND_BRANCH] | wc -l

Total stories: [frontend_count + backend_count]
Total commits: [frontend_commits + backend_commits]
```

This report is computed **before** the merge below, while `[FRONTEND_BRANCH]`/`[BACKEND_BRANCH]` are still ahead of `$PHASE_BRANCH` — after the merge the same `git log` range would read zero and the counts would no longer be informative.

### Merge Split Branches Into the Phase Branch

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
cd "$PHASE_CONTAINER_PATH"
$WORKTREE_MGR merge-all "$FRONTEND_BRANCH" "$BACKEND_BRANCH" --into "$PHASE_BRANCH"
```

This is the same `merge-all ... --into` primitive Step 4's own wave loop already uses for individual story branches, reused here for the two split branches: the merge target is `$PHASE_BRANCH`, executed with CWD inside the phase container's own worktree (`$PHASE_CONTAINER_PATH`) — never `$DEFAULT_BRANCH`, never `AIMI_ROOT`. Centralizing both merges in this parent step (rather than having each sub-orchestrator merge into `$PHASE_BRANCH` itself, mid-flight, from its own worktree) avoids two parallel Tasks racing a `git checkout`/`git merge` against the same `$PHASE_CONTAINER_PATH` working directory at once; running them sequentially here, after both Tasks have already returned, is safe by construction. This step is also what makes Phase Completion's Creates Verification (below) meaningful: it inspects `$PHASE_CONTAINER_PATH`'s actual tracked files, which only reflect both splits' work once this merge has landed.

**On merge conflict:** mirrors the existing per-wave conflict handling (Step 4) exactly — report the conflicting files, clean up both split worktrees (the conflict lives in `$PHASE_CONTAINER_PATH`'s own working directory, not in the source worktrees, so removing them is safe), and STOP:

```
MERGE CONFLICT while merging phase [PHASE_ID]'s split branches into [PHASE_BRANCH].
Conflicting files:
[conflict output from merge-all]

Resolve the conflict on branch [PHASE_BRANCH] in [PHASE_CONTAINER_PATH] and re-run
`/aimi:execute` to continue. Both split files' stories are already marked complete —
re-running will not re-execute them, only retry this merge and the phase-completion
checks that follow it.
```

### Clean Up Split Worktrees

Only reached once the merge above succeeds:

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
cd "$PHASE_CONTAINER_PATH"
$WORKTREE_MGR remove "$FRONTEND_BRANCH"
$WORKTREE_MGR remove "$BACKEND_BRANCH"
```

Removes only the two split worktrees. `$PHASE_CONTAINER_PATH` itself is left intact — its removal is a separate, later-timed operation owned entirely by Phase Completion's own lifecycle (the phase container is only ever torn down once the *phase* — not just this split — is fully done), never by this section.

### Continue to Phase Completion

Proceed to the **Phase Completion** section below with `PHASE_SPLIT_MODE=true` still in scope. Its "phase's own pending count is zero" gate and Creates Verification step both branch on `PHASE_SPLIT_MODE` — see **Multi-File Pending Count** in Phase Completion. Once Phase Completion (if it ran) has produced its own report, the **Aggregated Completion Report** above is what replaces this file's normal Step 5 — do not additionally run Step 5's single-file reporting for either split file.

## Step 2: Branch Setup

Get the branch name from the init-session output (already validated by CLI).

### Main Repo Branch Setup

**Skip this step if `AIMI_ROOT_IS_GIT_REPO` is false, or if `PHASE_MODE` is true** — see Multi-Repo Handling above for the first condition. In phase mode, the phase container's `$WORKTREE_MGR create` call in Step 1.7 is the only branch-creating operation for this phase; no `setup-branch` call runs against the main working tree, which is what keeps the Main Working Tree Untouched Invariant (see Phase Mode: Worktree Naming and CWD) true.

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

Read the tasks file metadata to get maxConcurrency.

**Phase mode (`PHASE_MODE=true`):** re-run `init-session` with `--file "$PHASE_TASKS_PATH"` explicitly — not the bare form — so `maxConcurrency` is read from the claimed phase's own tasks file (see Concurrency Source in Phase Mode: Worktree Naming and CWD), not any feature-root or global file. The bare form would re-run `init-session`'s mtime-based auto-discovery and could silently re-point session state at a different, more-recently-touched sibling phase file:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI init-session --file "$PHASE_TASKS_PATH"
```

**Flat mode (`PHASE_MODE=false`):** unchanged — bare `init-session`:

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
    # PHASE_MODE: read from PHASE_CONTAINER_PATH/PHASE_BRANCH instead of
    # project_root/branchName — see Phase Mode: Worktree Naming and CWD.
    base_sha = {}  # key: group_key, value: HEAD SHA before worktree creation
    for group_key in project_groups:
        if PHASE_MODE:
            base_sha[group_key] = git -C [PHASE_CONTAINER_PATH] rev-parse [PHASE_BRANCH]
        else:
            project_root = project_roots[group_key]
            base_sha[group_key] = git -C [project_root] rev-parse [branchName]

    # ========================================
    # CREATE WORKTREES PER PROJECT GROUP
    # ========================================
    # PHASE_MODE: every story worktree is created inside the phase container,
    # never at project_root — see Phase Mode: Worktree Naming and CWD.
    all_worktrees = {}  # key: full_story.id, value: {worktree_name, worktree_path, group_key}

    for group_key, stories in project_groups:
        project_root = project_roots[group_key]
        worktree_cwd = PHASE_CONTAINER_PATH if PHASE_MODE else project_root
        worktree_base = PHASE_BRANCH if PHASE_MODE else branchName

        for full_story in stories:
            worktree_name = worktree_base + "-" + full_story.id

            # cd to the phase container (phase mode) or the project's git root (flat mode)
            cd [worktree_cwd]
            $WORKTREE_MGR create [worktree_name] --from [worktree_base]

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
            merge_cwd = PHASE_CONTAINER_PATH if PHASE_MODE else project_root
            merge_target = PHASE_BRANCH if PHASE_MODE else branchName
            succeeded_worktree_names = [all_worktrees[s.id].worktree_name for s in stories]

            # cd to the phase container (phase mode) or the project's git root (flat mode) before merging.
            # PHASE_MODE requires this: merge-all issues a bare `git checkout <target-branch>` against
            # whatever repo its CWD belongs to -- running it from AIMI_ROOT would check the phase branch
            # out onto the main working tree, violating the Main Working Tree Untouched Invariant
            # (see Phase Mode: Worktree Naming and CWD).
            cd [merge_cwd]
            merge_result = $WORKTREE_MGR merge-all [succeeded_worktree_names...] --into [merge_target]

            if merge conflict (non-zero exit):
                Report:
                "MERGE CONFLICT during wave [wave] merge in project [group_key]."
                "Conflicting files:"
                "[conflict output from merge-all]"
                ""
                "Resolve the conflict on branch [merge_target] in [merge_cwd] and re-run `/aimi:execute` to continue."

                # Cleanup ALL worktrees from this wave (across all project groups) before stopping
                for full_story_id, wt in all_worktrees:
                    cd (PHASE_CONTAINER_PATH if PHASE_MODE else project_roots[wt.group_key])
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

    # Remove all worktrees from this wave (per project group; PHASE_MODE uses
    # PHASE_CONTAINER_PATH instead — see Phase Mode: Worktree Naming and CWD)
    for full_story_id, wt in all_worktrees:
        cd (PHASE_CONTAINER_PATH if PHASE_MODE else project_roots[wt.group_key])
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

**Phase mode (`PHASE_MODE=true`):** cleanup runs with CWD = `PHASE_CONTAINER_PATH` only, and matches worktrees named `"[PHASE_BRANCH]-US-*"` — see Phase Mode: Worktree Naming and CWD. The main working tree (`AIMI_ROOT`) is never `cd`'d into by this step.

```
cd [PHASE_CONTAINER_PATH]
$WORKTREE_MGR list
# For each worktree matching "[PHASE_BRANCH]-US-*":
$WORKTREE_MGR remove [worktree_name]
```

**Flat mode (`PHASE_MODE=false`):** unchanged.

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

## Phase Completion

Runs once, and before Step 5. Its trigger point depends on whether this phase used a full-stack split:

- **Single-file phase (`PHASE_SPLIT_MODE=false`, unchanged):** immediately after Post-Loop Cleanup and the Visual Follow Session note above.
- **Full-stack split phase (`PHASE_SPLIT_MODE=true`):** from Phase-Mode Paired Split's **Continue to Phase Completion** step, after both split sub-orchestrators have returned, their branches have been merged into `$PHASE_BRANCH`, and their worktrees have been cleaned up.

It fires only when **both** are true:

- `PHASE_MODE == true` (see Phase Mode Detection in Step 1)
- the phase's own pending count is zero — see **Multi-File Pending Count** immediately below for how this is computed; when it is greater than 0, the wave loop (or, in split mode, one or both sub-orchestrators) broke on deadlock or a gate-blocked wave, not true completion — skip this entire section and go straight to Step 5 (single-file) or the Aggregated Completion Report (split mode, already produced by Phase-Mode Paired Split before this section was reached).

### Multi-File Pending Count

**When `PHASE_SPLIT_MODE=false` (unchanged):**
```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI count-pending
```
(`count-pending` reads the session's tracked tasks file, which Step 1.7 already repointed at `PHASE_TASKS_PATH`.)

**When `PHASE_SPLIT_MODE=true`:** `count-pending`'s session-state read does not apply — Step 1.7's Detect a Full-Stack Split Inside This Phase step never pointed this session's state at a single governing file, because a split phase has none. Sum pending stories across both split files directly, by path, instead:
```bash
FRONTEND_PENDING=$(jq '[.userStories[] | select(.status == "pending")] | length' "$PHASE_FE_TASKS")
BACKEND_PENDING=$(jq '[.userStories[] | select(.status == "pending")] | length' "$PHASE_BE_TASKS")
PHASE_PENDING=$((FRONTEND_PENDING + BACKEND_PENDING))
```
The phase's split work only counts as complete when `PHASE_PENDING` is `0` — i.e. **both** files report zero pending stories, not just one.

**For legacy flat v3.3 tasks.json files (`PHASE_MODE=false`): skip this entire section.** Step 5 runs completely unchanged, exactly as it does today.

Every Bash call in this section that touches the phase container's git state or filesystem passes `$PHASE_CONTAINER_PATH` explicitly (`cd "$PHASE_CONTAINER_PATH"`, `git -C "$PHASE_CONTAINER_PATH"`, or an absolute path built from it) — never a bare relative path, and never anything derived from `find_aimi_root()`'s own CWD. `find_aimi_root()` (invoked internally by every `$AIMI_CLI` call) `cd`s to `PROJECT_ROOT` — the *main* repo root — as a side effect, so by the time any code here runs, CWD cannot be trusted to be `PHASE_CONTAINER_PATH`. This is the same rule Step 1.7's Path and State Notes already established for the rest of phase mode.

Fetch the claimed phase's roadmap object once, reused by every subsection below:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
PHASE_JSON=$($AIMI_CLI roadmap-get --feature "$FEATURE" --phase "$PHASE_ID")
PHASE_NAME=$(printf '%s' "$PHASE_JSON" | jq -r '.name')
```

### Creates Verification

For every entry the phase declared in `roadmap.json`'s `creates[]`, confirm the artifact is actually present in the phase branch's code — not merely that some other phase's `needs` resolved against it. This is a distinct, stricter check than `validate-contracts`: `validate-contracts` (outline 03) answers "does a `needs` entry have a completed, handoff-documented provider," using `roadmap.json` and `handoff.md` as its only inputs, and never inspects source code. This check answers "does this phase's own promised artifact exist," by inspecting the phase container's actual tracked files.

**Split-mode timing (`PHASE_SPLIT_MODE=true`):** this check always runs against `$PHASE_CONTAINER_PATH`'s tracked files, unchanged — but by the time this section is reached in split mode, Phase-Mode Paired Split's Merge Split Branches Into the Phase Branch step has already landed both `$FRONTEND_BRANCH` and `$BACKEND_BRANCH` onto `$PHASE_BRANCH`, so `$PHASE_CONTAINER_PATH`'s checkout already reflects both splits' combined work. This check therefore verifies the merged phase branch state as a natural consequence of running after that merge — never either split branch in isolation — with no special-casing needed in the procedure below.

> **Cross-story flag for the auditor:** this story's brief describes creates verification as invoking "the outline:03 contract-validation CLI surface... in its phase-closure mode" (e.g. `validate-contracts <phase-id> --root <path>`) as an illustrative example. The landed `validate-contracts` (outline 03) has no `--root` flag or code-existence mode, and its own notes scope it exclusively to needs-vs-creates delivery resolution ("wiring validate-contracts and roadmap-sweep into plan.md and execute.md is owned by outline 08 and outline 11" — this story). Extending `validate-contracts`'s jq-only, roadmap.json-only logic to also grep real source files would be new scope outline 03 never claimed. This section therefore implements creates verification as its own orchestrator-side procedure below — the same pattern Console Error Attribution (above) already uses for judgment-requiring checks that need no new CLI call. Reconcile if a future story wants to fold this into `validate-contracts` instead.

#### Inputs

- `CREATES_RAW` — one line per `creates[]` entry:
  ```bash
  CREATES_RAW=$(printf '%s' "$PHASE_JSON" | jq -r '(.creates // [])[]')
  ```
  Each line is a `"<identity> (<description>)"` string (see the Creates/Needs Contracts format in `${CLAUDE_PLUGIN_ROOT}/commands/references/scope-contexts.md`).
- `PHASE_CONTAINER_PATH` — from Step 1.7, absolute, never CWD-derived.

#### Procedure

For each line of `CREATES_RAW`:

1. **Compute identity**: the substring before the first `(`, trimmed of surrounding whitespace (mirrors `_cv_identity` in aimi-cli.sh). Empty identity → missing, reason `"malformed creates entry"`.
2. **Reject unsafe identities before touching the filesystem**: if identity contains a `..` path segment or starts with `/`, do not resolve it against `PHASE_CONTAINER_PATH` — record it as missing with reason `"unsafe creates identity"` and move on. Mirrors the escape-prevention posture `validate_path_in_project` already enforces inside aimi-cli.sh.
3. **Direct file check** (covers the `creates` "file" identity kind — a relative path):
   ```bash
   [ -f "$PHASE_CONTAINER_PATH/$identity" ]
   ```
   Success → verified, `location = identity`.
4. **Tracked-source search** (covers `creates` "endpoint"/"table"/"service" identity kinds, and files whose identity string differs from their literal path) — only when step 3 did not verify:
   ```bash
   MATCH=$(git -C "$PHASE_CONTAINER_PATH" grep -l -F -- "$identity" 2>/dev/null | head -1)
   ```
   Non-empty `MATCH` → verified, `location = $MATCH`. `-F` is fixed-string (never regex); `--` stops identity from ever being parsed as a flag even if it starts with `-`.
5. Neither check succeeds → **missing**, recorded as `{identity, description, entry}`.

Accumulate two lists: `VERIFIED_ARTIFACTS` (`"<identity> — <location>"` strings, in `creates[]` order) and `MISSING_CREATES` (`{identity, description}` objects).

#### On any missing entry

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI roadmap-set-status --feature "$FEATURE" --phase "$PHASE_ID" --status verification_failed
```

Report:
```
## Phase [PHASE_ID] Verification Failed

[len(MISSING_CREATES)] declared creates entr(y|ies) could not be confirmed in the phase branch:

[for each entry in MISSING_CREATES:]
  - [entry.identity] ([entry.description]) — not found under [PHASE_CONTAINER_PATH]

Phase status set to verification_failed. Fix the missing artifact(s) on branch
[PHASE_BRANCH], then re-run /aimi:execute to re-verify — creates verification
re-runs from scratch on the next pass. Next-phase planning stays blocked
until this phase re-verifies successfully (verification_failed is excluded
from next-eligible-phase selection, the same way pending/in_progress are).
```

Do **not** write `handoff.md`, do **not** offer a PR, do **not** run the Next Phase step below. Skip directly to Step 5 (which still reports this phase's own story-level completion, unaffected by the roadmap-level failure).

### Write Handoff

Only reached when every `creates` entry verified. Build the five-section payload:

- **Decisions Made** — one bullet per notable implementation decision surfaced by this phase's stories (their `implementation.approach` text, gate resolutions, or explicit deviations the story-executor agents reported). Empty array if nothing stood out.
- **Artifacts Created** — exactly `VERIFIED_ARTIFACTS` from Creates Verification above, unmodified. This is the section `validate-contracts`'s `_cv_handoff_lists_artifact` searches when a downstream phase's `needs` references this phase — every identity must appear verbatim.
- **Deviations** — one bullet per `.aimi/known-gaps/*.md` file belonging to this phase's stories (same source Step 5's "Known Gaps" aggregation reads), summarizing the story id and gap. Empty array if none.
- **Deferred Items** — one bullet per this phase's own story left in `skipped` status, if any. Empty array if none.
- **Contracts Delivered** — one bullet per `creates` entry restating the identity now available to dependent phases (`"<identity> — contract fulfilled, available to phases depending on [PHASE_ID]"`), mirroring Artifacts Created's identities but phrased for downstream `needs` resolution.

Write via the guard-protected CLI call only — **never** a direct Write or Edit tool call on `handoff.md`'s path (`guard-runtime-state.py` blocks that and points back at this verb):

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
HANDOFF_PAYLOAD=$(jq -n \
  --argjson decisions "$DECISIONS_JSON" \
  --argjson artifacts "$ARTIFACTS_JSON" \
  --argjson deviations "$DEVIATIONS_JSON" \
  --argjson deferred "$DEFERRED_JSON" \
  --argjson contracts "$CONTRACTS_JSON" \
  '{decisions: $decisions, artifacts: $artifacts, deviations: $deviations, deferred: $deferred, contracts: $contracts}')
HANDOFF_RESULT=$(printf '%s' "$HANDOFF_PAYLOAD" | $AIMI_CLI roadmap-write-handoff --feature "$FEATURE" --phase "$PHASE_ID" 2>&1)
HANDOFF_EXIT=$?
```
`DECISIONS_JSON` / `ARTIFACTS_JSON` / `DEVIATIONS_JSON` / `DEFERRED_JSON` / `CONTRACTS_JSON` are each a JSON array of strings built from the bullets above (e.g. `jq -Rn '[inputs]'` fed one bullet per line, or a literal JSON array). `ARTIFACTS_JSON` is `VERIFIED_ARTIFACTS` converted to a JSON array directly.

**On failure (`HANDOFF_EXIT != 0`):** the phase's status is left exactly where it already was (`in_progress` — the write failure means the status-mutating call below is never reached, so there is nothing to revert). Report:
```
Handoff write failed for phase [PHASE_ID]: [HANDOFF_RESULT]

Phase status remains in_progress. Retry with:
  $AIMI_CLI roadmap-write-handoff --feature [FEATURE] --phase [PHASE_ID]
  (same payload as above)

Re-running /aimi:execute re-enters this section and re-verifies creates
harmlessly — the retry above does not require repeating that step by hand.
```
Skip directly to Step 5.

### Mark Phase Completed

Only reached when `handoff.md` is confirmed on disk (the CLI call above returned `{"handoff": "<path>"}`). Exactly one call — sets status to `completed` **and** releases the phase's claim in the same atomic write (no window where status reads completed while still claimed; see `cmd_roadmap_set_status`'s completed-branch in aimi-cli.sh, which also refuses this transition when no `handoff.md` is on disk — a second, CLI-enforced guarantee behind the check above):

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI roadmap-set-status --feature "$FEATURE" --phase "$PHASE_ID" --status completed
```

Report: `"Phase [PHASE_ID] ([PHASE_SLUG]) completed. Claim released."`

### Offer a Pull Request

Best-effort only — never reverts or changes the already-`completed` status on failure or refusal.

```bash
if command -v gh >/dev/null 2>&1; then
  cd "$PHASE_CONTAINER_PATH"
  git push -u origin "$PHASE_BRANCH"
  gh pr create --base "$DEFAULT_BRANCH" --head "$PHASE_BRANCH" \
    --title "Phase [PHASE_ID]: [PHASE_NAME]" \
    --body "Completes phase [PHASE_ID] of [FEATURE]. See phase-[PHASE_DIR]/handoff.md for details."
else
  echo "gh not found — create the PR manually:"
  echo "  git -C \"$PHASE_CONTAINER_PATH\" push -u origin $PHASE_BRANCH"
  echo "  Then open a PR: $DEFAULT_BRANCH...$PHASE_BRANCH"
fi
```

If `git push` or `gh pr create` fails (no permissions, offline, branch already has an open PR, etc.), report the failure verbatim and continue — do not retry, do not prompt interactively, and never revert the phase's `completed` status.

### Next Phase

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
NEXT_ELIGIBLE_JSON=$($AIMI_CLI roadmap-get --feature "$FEATURE" --next-eligible 2>&1)
NEXT_ELIGIBLE_EXIT=$?
```

**When `NEXT_ELIGIBLE_EXIT != 0`** (no phase remains pending/planned, unclaimed, and dependency-complete — the roadmap-exhaustion case; a phase stuck in `verification_failed` also falls here since it is neither `pending` nor `planned`, matching outline 02's landed `roadmap-get --next-eligible` contract): skip both the interactive offer and the agent-mode auto-continue branch entirely. Run the residual sweep exactly once and hand its report to Step 5:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
ROADMAP_SWEEP_REPORT=$($AIMI_CLI roadmap-sweep "$FEATURE")
```
`ROADMAP_SWEEP_REPORT` is rendered as a `## Roadmap Sweep` section in Step 5's final summary (see below). No next-phase offer of any kind is shown.

**Otherwise**, `NEXT_ELIGIBLE_JSON` is the next eligible phase object; extract `NEXT_PHASE_ID=$(printf '%s' "$NEXT_ELIGIBLE_JSON" | jq -r '.id')`.

- **Interactive mode** (`$AIMI_CLI detect-interactivity` = `picker`): use **AskUserQuestion** with exactly two options:
  ```
  Phase [PHASE_ID] is complete. Plan phase [NEXT_PHASE_ID] now?

  A — Plan it now
  B — Plan it later
  ```
  **Option A:** set `NEXT_PHASE_HANDOFF=$NEXT_PHASE_ID` (consumed after Step 5's report — see below).
  **Option B:** report `"Resume with: /aimi:plan --phase [NEXT_PHASE_ID]"` and end the session after Step 5's report.

- **Agent mode** (`detect-interactivity` = `agent`): skip AskUserQuestion. Log exactly:
  ```
  agent-mode: phase-complete auto-continue [PHASE_ID]
  ```
  (`[PHASE_ID]` is the phase that **just completed**, not `NEXT_PHASE_ID`.) Set `NEXT_PHASE_HANDOFF=$NEXT_PHASE_ID`.

After Step 5's report is shown, if `NEXT_PHASE_HANDOFF` is set, proceed immediately into `/aimi:plan --phase [NEXT_PHASE_HANDOFF]`'s command flow — no further prompt, no waiting on additional user input.

## Step 5: Completion

When execution ends (all stories complete, or deadlock detected):

> **PHASE_MODE scope note:** this step's reporting is written for the flat-mode case (CWD = `AIMI_ROOT`, `HEAD` on `branchName`). In phase mode, run this step's commands with CWD inside `PHASE_CONTAINER_PATH` and substitute `PHASE_BRANCH` for `branchName` / `CONTAINER_BASE` for `DEFAULT_BRANCH` where used below. Phase-level completion — verifying the claimed phase's `creates`, writing `handoff.md`, updating roadmap status, offering a PR, and offering or auto-continuing to the next phase — is handled entirely by the **Phase Completion** section above, which runs before this step whenever `PHASE_MODE=true` and the phase's own pending count reaches zero. This step still runs afterward, in both modes, to report story-level completion for the phase's own tasks file.

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

If `ROADMAP_SWEEP_REPORT` is set (only ever set by Phase Completion's Next Phase step, roadmap-exhaustion branch), append:
```
## Roadmap Sweep

No phase remains ready to plan or claim — every phase in [FEATURE]'s roadmap
is completed, verification_failed, or otherwise not pending/planned.
Residual report from `roadmap-sweep`:

[If ROADMAP_SWEEP_REPORT.orphanCreates is non-empty:]
Orphan creates (declared but never consumed by any needs):
  For each: "  - phase [entry.phase]: [entry.creates]"

[If ROADMAP_SWEEP_REPORT.deferredNeeds is non-empty:]
Deferred needs (a provider exists but has not completed):
  For each: "  - phase [entry.phase] needs \"[entry.need]\", provided by phase [entry.deferred] (not yet completed)"

[If ROADMAP_SWEEP_REPORT.warnings is non-empty:]
Warnings:
  For each: "  - phase [entry.phase] field '[entry.field]': [entry.message]"

[If orphanCreates, deferredNeeds, and warnings are all empty:]
No residual gaps — every declared creates entry is consumed and every need is satisfied.
```

If `ROADMAP_SWEEP_REPORT` is unset, omit the `## Roadmap Sweep` section entirely.

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

**Phase mode:** re-running `/aimi:execute` for a phase this session already claimed and left `in_progress` does not error. `roadmap-claim`'s self-reclaim path (Step 1.7) reports the same phase again instead of a contention failure, and `$WORKTREE_MGR create "$PHASE_BRANCH" --from "$CONTAINER_BASE"` reuses the existing container directory silently since the target already exists — no separate reuse-detection logic is needed beyond calling both idempotently on every claim.

**Phase mode with a full-stack split (`PHASE_SPLIT_MODE=true`):** the same idempotency extends to Phase-Mode Paired Split — `$WORKTREE_MGR create "$FRONTEND_BRANCH"/"$BACKEND_BRANCH" --from "$PHASE_BRANCH"` reuses each split worktree silently if a prior run left one in place, and re-spawning both sub-orchestrators is harmless: each one's own `init-session --file` points at a split file whose already-completed stories are skipped automatically (points 1–4 above), so a sub-orchestrator with nothing left pending returns immediately. This is also what makes retrying after a Merge Split Branches Into the Phase Branch conflict safe — re-running does not re-execute any story, only retries the merge and the Multi-File Pending Count / Creates Verification checks that follow it.

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
