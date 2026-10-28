# Execute: Step 3: Check for Pending Stories

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

## Step 3: Check for Pending Stories

Resolve this run's own tasks file explicitly — `$PHASE_TASKS_PATH` when `PHASE_MODE=true` (already set by Step 1.7, or pre-set here for a split sub-orchestrator — see Spawn Split Sub-Orchestrators), `$TASKS_PATH` otherwise (already absolute: `init-session` prints the realpath, so it is never prefixed with `$AIMI_ROOT/`) — rather than letting `count-pending` fall through to its shared current-tasks fallback. Every remaining call in this step and in Step 4 below reuses the same formula, resolved fresh in each call's own isolated shell:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
if [ "$PHASE_MODE" = "true" ]; then
  RUN_TASKS_FILE="$PHASE_TASKS_PATH"
else
  RUN_TASKS_FILE="$TASKS_PATH"
fi
$AIMI_CLI count-pending --tasks-file "$RUN_TASKS_FILE"
```

If result is `0`:

**Re-verify branch — a phase that entered `verification_failed` with nothing left to execute.** Evaluate this branch **first**, before the release-and-STOP below. It fires only when **all five** of these hold together:

1. `count-pending` returned `0` (this is the `If result is 0` case, so it already holds here);
2. `PHASE_MODE=true`;
3. `$PHASE_ID` is set — the session itself ran Step 1.7, which is never true inside a Phase-Mode Paired Split sub-orchestrator, since one never learns `$PHASE_ID`;
4. `PHASE_SPLIT_MODE=false`;
5. `PHASE_ENTRY_STATUS` equals the literal string `verification_failed` (captured in Step 1.7's on-success extraction block — the only surviving witness of the entry status, since the `in_progress` transition in that same step overwrote it in `roadmap.json`).

**If any single one of the five is false, fall through to the unchanged path below** — flat mode, flat container mode, a phase entered as `pending`/`planned`/`in_progress`, and a split sub-orchestrator with no `$PHASE_ID` all behave exactly as they do today, with no observable difference.

When it fires: do **not** release the claim, do **not** print `All stories already complete!`, and do **not** STOP. Report the block below, then **skip Validate Dependencies, Steps 3.1, 3.2, 3.3 and 3.4, and all of Step 4**, and continue directly into the **Phase Completion** section.

```
Phase [PHASE_ID] has 0 pending stories but entered this run as
verification_failed — every story is done, the phase's creates verification
is what failed.

Re-verifying branch [PHASE_BRANCH] instead of stopping. Skipping the wave
loop (nothing to execute) and continuing straight to phase verification.
```

**Why this is not a STOP, and why the claim stays held.** Phase Completion owns the release on *both* of its outcomes: Mark Phase Completed releases atomically on success, and Creates Verification's `On any missing entry` path sets `verification_failed` again and releases on a repeat failure. Releasing here would hand the phase to a racing session in the middle of its own verification. Every *other* phase-mode STOP in Step 3 — the `All stories already complete!` STOP below and Validate Dependencies' failure STOP — keeps its existing release-first call unchanged.

**Why skipping those steps is safe.** Phase Completion consumes nothing they produce: it re-fetches `PHASE_JSON`/`PHASE_NAME` from its own `roadmap-get` call, Creates Verification derives `PARTICIPATING_GROUP_KEYS` fresh from the phase's own tasks file and recomputes each participating repository's container as that repository's toplevel plus `.worktrees/$PHASE_BRANCH` rather than reusing anything from Step 1.7, and `$WORKTREE_MGR` is re-resolved inline where Mark Phase Completed needs it. `MAX_CONCURRENCY` (Step 3.2), the project guidelines (Step 3.3) and `VISUAL_URL` (Step 3.4) have no reader in Phase Completion or Step 5 on this path.

**No `init-session` re-run is added here.** Step 1.7's **Point the session at this phase's own tasks file** already pointed session state at `$PHASE_TASKS_PATH`, and the `count-pending` that just returned `0` is the proof that it did — Phase Completion's own bare `count-pending` (Multi-File Pending Count, `PHASE_SPLIT_MODE=false` branch) reads that same session state, gets the same `0`, and its "pending count is greater than 0" abort branch is therefore not taken.

This mirrors an already-supported route rather than inventing a new one: Phase-Mode Paired Split already continues to Phase Completion with `PHASE_ACTIVE_COUNT` of `0` — every member already completed, nothing spawned — precisely because Phase Completion is what re-runs the pending-count and creates-verification checks. This branch extends that same behavior to the non-split path. Condition 4 is belt-and-braces: a split phase's top-level orchestrator never reaches Step 3 at all (Step 1.7 routes `PHASE_SPLIT_MODE=true` to Phase-Mode Paired Split instead of Step 2), so the load-bearing conditions here are 3 and 5.

**When `PHASE_MODE=true` and `$PHASE_ID` is set** (this session itself ran Step 1.7 — never true inside a Phase-Mode Paired Split sub-orchestrator, which never learns `$PHASE_ID`), release the claim first (see Release the Claim on Abort):

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
```

```
All stories already complete!

Run /aimi:review to review the implementation.
```
STOP execution.

### Validate Dependencies

Same resolution as this step's own `count-pending` above — the identical `PHASE_MODE`-conditioned formula:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
if [ "$PHASE_MODE" = "true" ]; then
  RUN_TASKS_FILE="$PHASE_TASKS_PATH"
else
  RUN_TASKS_FILE="$TASKS_PATH"
fi
$AIMI_CLI validate-deps --tasks-file "$RUN_TASKS_FILE"
```

If validation fails (non-zero exit), release the claim under the same phase-mode guard as above, report the error, and STOP:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
```
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

