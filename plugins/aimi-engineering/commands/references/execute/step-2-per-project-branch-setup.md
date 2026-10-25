# Execute: Step 2: Per-Project Branch Setup

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

### Per-Project Branch Setup

After setting up the branch in the main repo (or skipping if multi-repo layout), check if any stories have a `project` field by running `$AIMI_CLI list-ready --brief` and inspecting the results.

Run the following sub-steps when any story has a non-null `project` field, or when in multi-repo layout (see Multi-Repo Handling above for the gate condition). Skip this step when no stories have a `project` field and AIMI_ROOT is a git repo (backwards compatible).

1. Collect unique project paths from ALL pending stories (not just ready ones — use `$AIMI_CLI status` and filter stories with a `project` field).
2. Resolve each project path to an absolute path: `AIMI_ROOT / story.project` where AIMI_ROOT is the directory containing `.aimi/`.
3. For each unique project path, detect its default branch. Read and validate `branchName` here too — defense in depth, mirroring `PHASE_BRANCH`'s validate-once-quote-everywhere discipline (`cmd_init_session` already rejected an invalid `branchName` in Step 1); every sub-step below reuses this same `$BRANCH_NAME`, exactly like `$PROJECT_DEFAULT` is computed once here and reused below:
   ```bash
   AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
   : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
   PROJECT_DEFAULT=$($AIMI_CLI detect-default-branch --project [resolved_project_path])
   git -C [resolved_project_path] fetch origin 2>/dev/null || true
   BRANCH_NAME=$($AIMI_CLI metadata | jq -r '.branchName')
   if ! [[ "$BRANCH_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
     echo "Invalid branchName: $BRANCH_NAME" >&2
     exit 1
   fi
   ```

   **When `PHASE_MODE` is true:** skip this project's branch setup entirely and move on to the next unique project path (or past this whole numbered sub-step once every project path has been visited). `CONTAINER_MODE` is forced false whenever `PHASE_MODE` is true (see Execution Mode Detection in Step 1), so without this skip a phase-mode run with a project-scoped story would fall into the inline branch below and run `setup-branch` directly against that project's own working tree — the same operation the Main Working Tree Untouched Invariant forbids for a claimed phase. It needs none of that: Step 1.7's **Create Phase Containers Per Project Group** already created (or reused) this same project's own phase container, keyed by the identical `project_path`/`group_key`, before Step 2 ever runs. This mirrors Main Repo Branch Setup's own `PHASE_MODE` skip above, generalized to the per-project case.

   **When `PHASE_MODE` is false and `CONTAINER_MODE` is false** (`EXECUTION_MODE` inline or absent): set up the branch directly — unchanged for an inline-mode run:
   ```bash
   BASE_BRANCH="[the value Step 0's Parse --base Override echoed, or empty when --base was absent]"
   if [ -n "$BASE_BRANCH" ]; then
     PROJECT_BRANCH_JSON=$($AIMI_CLI setup-branch "$BRANCH_NAME" --default-branch "$PROJECT_DEFAULT" --project [resolved_project_path] --base "$BASE_BRANCH")
   else
     PROJECT_BRANCH_JSON=$($AIMI_CLI setup-branch "$BRANCH_NAME" --default-branch "$PROJECT_DEFAULT" --project [resolved_project_path])
   fi
   ```
   Extract the action from the JSON output and report:
   ```
   Branch [branchName] set up in project: [project_path] (action: [action])
   ```

   **When `CONTAINER_MODE` is true:**

   `INTERACTIVE_MODE` should already be set by Step 1.6 by this point, but re-resolve here when still unset regardless — a cheap, idempotent safety net so no per-repo prompt below is ever evaluated before `INTERACTIVE_MODE` exists:
   ```bash
   AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
   : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
   if [ -z "$INTERACTIVE_MODE" ]; then
     INTERACTIVE_MODE=$($AIMI_CLI detect-interactivity)
   fi
   ```

   Resolve this project group's own base — the same shared primitive Flat Container Mode uses above, called here with `--project` so it evaluates *this* repo's checked-out state (current branch, unmerged commits, existing local/remote target) instead of AIMI_ROOT's:
   ```bash
   AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
   : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
   BASE_BRANCH="[the value Step 0's Parse --base Override echoed, or empty when --base was absent]"
   if [ -n "$BASE_BRANCH" ]; then
     PROJECT_BASE_JSON=$($AIMI_CLI resolve-base-branch "$BRANCH_NAME" --project [resolved_project_path] --default-branch "$PROJECT_DEFAULT" --base "$BASE_BRANCH")
   else
     PROJECT_BASE_JSON=$($AIMI_CLI resolve-base-branch "$BRANCH_NAME" --project [resolved_project_path] --default-branch "$PROJECT_DEFAULT")
   fi
   CONTAINER_BASE=$(echo "$PROJECT_BASE_JSON" | jq -r '.base')
   CONTAINER_BASE_REASON=$(echo "$PROJECT_BASE_JSON" | jq -r '.reason')
   PROMPT_NEEDED=$(echo "$PROJECT_BASE_JSON" | jq -r '.promptNeeded')
   CURRENT_BRANCH=$(echo "$PROJECT_BASE_JSON" | jq -r '.currentBranch')
   ```

   `PROMPT_NEEDED` is `true` only when this repo's current branch carries unmerged work relative to its own default branch — the per-repo analogue of Step 1.6's four gating conditions, now evaluated once inside `resolve-base-branch` itself. When it is `false`, skip straight to the delegation below: no prompt, no log line, `CONTAINER_BASE`/`CONTAINER_BASE_REASON` stand exactly as resolved.

   **When `PROMPT_NEEDED` is `true` and `INTERACTIVE_MODE=picker`:** use **AskUserQuestion**, naming this repo so a multi-repo run's separate prompts stay distinguishable:
   ```
   Which branch should be used as the base for [branchName] in [project_path] (currently on [current_branch])?

   A — Stack on current branch ([current_branch])
   B — Use default branch ([PROJECT_DEFAULT])
   Other — Specify a base branch
   ```
   - **Option A:** keep `CONTAINER_BASE`/`CONTAINER_BASE_REASON` exactly as already resolved above — `PROMPT_NEEDED=true` already means `resolve-base-branch` chose to stack on `[current_branch]`.
   - **Option B:** `CONTAINER_BASE="$PROJECT_DEFAULT"`, `CONTAINER_BASE_REASON="default-branch"`.
   - **Option Other:** collect the free-form branch name the user typed. Validate it against `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$`. If it does not match, report:
     ```
     Invalid branch name. Must match ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$
     ```
     and STOP. If valid, `CONTAINER_BASE=<user-input>`, `CONTAINER_BASE_REASON="explicit-base"`.

   **When `PROMPT_NEEDED` is `true` and `INTERACTIVE_MODE=agent`:** no prompt — use `CONTAINER_BASE`/`CONTAINER_BASE_REASON` exactly as already resolved (this is what keeps container mode from silently discarding an unmerged current branch the way the removed multi-repo skip guard used to) and log one line per repo:
   ```
   agent-mode: base auto-resolved [CONTAINER_BASE] ([CONTAINER_BASE_REASON]) — project: [project_path]
   ```

   *Agent-mode fallback: if `INTERACTIVE_MODE=agent` and `PROMPT_NEEDED=true`, keep `CONTAINER_BASE`/`CONTAINER_BASE_REASON` as resolved and log `agent-mode: base auto-resolved [CONTAINER_BASE] ([CONTAINER_BASE_REASON]) — project: [project_path]`.*

   Delegate to **Create or Reuse a Container** with `EXEC_ROOT=[resolved_project_path]`, `EXEC_BRANCH="$BRANCH_NAME"`, and `CONTAINER_BASE` as just resolved (and possibly overridden by the picker above) — producing one container per project group at `[resolved_project_path]/.worktrees/[branchName]`, never one container spanning multiple project roots:

   ```bash
   CONTAINER_PATHS[project_path]="[resolved_project_path]/.worktrees/$BRANCH_NAME"
   CONTAINER_BASE_MAP[project_path]="$CONTAINER_BASE"
   CONTAINER_BASE_REASON_MAP[project_path]="$CONTAINER_BASE_REASON"
   ```

   `[project_path]` here is the group_key from Multi-Repo Handling's grouping pattern (the raw `story.project` value being iterated) — the map is keyed by `project_path`/`group_key`, not by the resolved absolute path, exactly like `PROJECT_GUIDELINES_MAP[project_path]` above and the Report line below. `CONTAINER_BASE_MAP`/`CONTAINER_BASE_REASON_MAP` mirror `CONTAINER_PATHS`'s keying for the resolved base and its reason.

   Report:
   ```
   Container for [branchName] ready in project: [project_path] (CONTAINER_PATHS[project_path]) — branched from [CONTAINER_BASE] ([CONTAINER_BASE_REASON])
   ```
