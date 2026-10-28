# Execute: Step 3.4: Open Visual Follow Session

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

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

- **If `agent-browser` is available:** Get the verification URL from the first visual story. In phase mode, source it from `$PHASE_TASKS_PATH` — never the mtime-discovered `$TASKS_PATH` from Step 1, which (exactly like `FEATURE_TYPE` in Step 1.7) could belong to a different, more-recently-touched sibling phase file when several are materialized:

  ```bash
  AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
  : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
  if [ "$PHASE_MODE" = "true" ]; then
    VISUAL_SOURCE="$PHASE_TASKS_PATH"
  else
    VISUAL_SOURCE="$TASKS_PATH"
  fi
  FIRST_VISUAL=$($AIMI_CLI verification-report --tasks-file "$VISUAL_SOURCE" | jq -c '.visual[0]')
  VISUAL_URL=$(printf '%s' "$FIRST_VISUAL" | jq -r '.url')
  VISUAL_GROUP_KEY=$(printf '%s' "$FIRST_VISUAL" | jq -r '.project // "DEFAULT"')
  ```

  **When `PHASE_MODE` is true** (the top-level single-file phase orchestrator, or a Phase-Mode Paired Split sub-orchestrator whose spawn prompt pre-set `PHASE_BRANCH`/`PHASE_CONTAINER_PATH` to its own split — see Spawn Split Sub-Orchestrators — so this branch applies unmodified in either case, keyed by whichever branch this session owns): resolve `EXEC_ROOT` from `VISUAL_GROUP_KEY` just computed above — never the unconditional `$AIMI_ROOT` — since a visual story's own `project` field may resolve to a repository distinct from `AIMI_ROOT`'s own (see Create Phase Containers Per Project Group). This CWD must exactly match whichever group's dev server Phase Container Dev Server Bootstrap started for that same `VISUAL_GROUP_KEY` (container-execution.md:100/:111/:134's CWD-must-match requirement — a mismatched CWD silently misses the registered entry). Read `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Rewrite a Verification URL Origin and apply it with `EXEC_ROOT` resolved as follows, `EXEC_BRANCH="$PHASE_BRANCH"`, and `RAW_URL="$VISUAL_URL"` — never a value cached from Phase Container Dev Server Bootstrap or Split Container Dev Server Bootstrap earlier in this run, since each Bash call is an isolated shell (Step 0):

  ```bash
  WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
  : "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"; [ -x "$WORKTREE_MGR" ] || { echo "WORKTREE_MGR is stale: $WORKTREE_MGR does not exist — re-run check-version --quiet --fix" >&2; exit 1; }
  if [ "$VISUAL_GROUP_KEY" = "DEFAULT" ]; then
    VISUAL_GROUP_ROOT="$AIMI_ROOT"
  else
    VISUAL_GROUP_ROOT="$AIMI_ROOT/$VISUAL_GROUP_KEY"
  fi
  EXEC_ROOT=$(git -C "$VISUAL_GROUP_ROOT" rev-parse --show-toplevel 2>/dev/null) || EXEC_ROOT="$VISUAL_GROUP_ROOT"
  cd "$EXEC_ROOT"
  SERVE_URL_JSON=$($WORKTREE_MGR serve url "$PHASE_BRANCH" "$VISUAL_URL")
  VISUAL_URL=$(printf '%s' "$SERVE_URL_JSON" | jq -r '.url')
  ```

  `VISUAL_URL` is simply reassigned to `.url` either way — the reference's degrade-safely contract (never fails, falls back to the raw URL unchanged) applies here unconditionally, with no gating on `.rewritten`.

  **When `CONTAINER_MODE` is true and `CONTAINER_DEV_URL[VISUAL_GROUP_KEY]` resolved** (see Container Dev Server Bootstrap above; `PHASE_MODE` and `CONTAINER_MODE` are mutually exclusive — see Execution Mode Detection — so at most one of these two branches ever applies): apply the same reference section with `EXEC_BRANCH` = this run's `branchName`, scoped to the FIRST visual story's OWN project group. This resolves the port of that group only — a second visual story from a different project group is unaffected by this rewrite and is instead resolved independently at its own post-merge verification step (Step 4). `EXEC_ROOT` is the same project root Container Dev Server Bootstrap (Step 3.3) already used for `VISUAL_GROUP_KEY` — `$AIMI_ROOT` for `"DEFAULT"`, otherwise `$AIMI_ROOT/[VISUAL_GROUP_KEY]`:

  ```bash
  AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
  : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
  WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
  : "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"; [ -x "$WORKTREE_MGR" ] || { echo "WORKTREE_MGR is stale: $WORKTREE_MGR does not exist — re-run check-version --quiet --fix" >&2; exit 1; }
  BRANCH_NAME=$($AIMI_CLI metadata | jq -r '.branchName')
  if [ "[VISUAL_GROUP_KEY]" = "DEFAULT" ]; then
    cd "$AIMI_ROOT"
  else
    cd "$AIMI_ROOT/[VISUAL_GROUP_KEY]"
  fi
  SERVE_URL_JSON=$($WORKTREE_MGR serve url "$BRANCH_NAME" "$VISUAL_URL")
  VISUAL_URL=$(printf '%s' "$SERVE_URL_JSON" | jq -r '.url')
  ```

  **Otherwise** (neither phase mode nor container mode applies, or the relevant server's port never resolved): `VISUAL_URL` remains the raw `verification.url` — unchanged from today.

  ```bash
  agent-browser --headed --session visual-follow open "$VISUAL_URL"
  ```

