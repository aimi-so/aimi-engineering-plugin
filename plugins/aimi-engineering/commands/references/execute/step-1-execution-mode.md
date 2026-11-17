# Execute: Step 1: Execution Mode, Orphan Recovery and Content Validation

> Loaded by `commands/execute.md` when its `Applies when:` condition holds.

### Execution Mode Detection

Read `metadata.execution` — the discriminator defined in `commands/references/execution-mode.md` — from the tasks file `init-session` discovered, apply the `--container`/`--inline` override, and derive `CONTAINER_MODE` (the single boolean this document's flat-mode container logic in Step 0.9 and Step 2 gates on), all in one block that echoes the two results:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
PHASE_MODE="[PHASE_MODE echoed by Step 1]"
EXECUTION_OVERRIDE="[EXECUTION_OVERRIDE from Parse --container/--inline Override, empty when neither flag was passed]"
EXECUTION_MODE=$($AIMI_CLI metadata | jq -r '.execution // "inline"')
if [ "$PHASE_MODE" = "true" ] && [ -n "$EXECUTION_OVERRIDE" ]; then
  echo "EXECUTION_OVERRIDE_IGNORED=true"
fi
if [ "$PHASE_MODE" = "false" ] && [ -n "$EXECUTION_OVERRIDE" ]; then
  if [ "$EXECUTION_OVERRIDE" != "$EXECUTION_MODE" ]; then
    $AIMI_CLI set-execution-mode "$EXECUTION_OVERRIDE"
  fi
  EXECUTION_MODE="$EXECUTION_OVERRIDE"
fi
if [ "$PHASE_MODE" = "false" ] && [ "$EXECUTION_MODE" = "container" ]; then
  CONTAINER_MODE=true
else
  CONTAINER_MODE=false
fi
echo "EXECUTION_MODE=$EXECUTION_MODE"
echo "CONTAINER_MODE=$CONTAINER_MODE"
```

Only the literal string `"container"` selects the container path; every other value (`"inline"`, absence, or anything unrecognized) resolves to `inline` — the same fail-safe default rule the reference doc defines.

**The `--container`/`--inline` override:**

- **`PHASE_MODE=true`:** the override is always ignored — a claimed phase already runs inside its own phase container regardless of `metadata.execution` (see the `CONTAINER_MODE` derivation above). When the block printed `EXECUTION_OVERRIDE_IGNORED=true`, report this warning; `EXECUTION_MODE` stays exactly as read from the file:
  ```
  Warning: --container/--inline is ignored on a phase-scoped tasks file. Phase mode always runs inside its own phase container; see /aimi:execute --phase.
  ```
- **`PHASE_MODE=false` and `EXECUTION_OVERRIDE` non-empty:** the override replaces `EXECUTION_MODE` for this run. When it differs from the value already on disk, the block persists it via `set-execution-mode` so a later invocation without the flag continues in the same mode.

`CONTAINER_MODE` is always false when `PHASE_MODE=true` — a claimed phase already has its own container (`PHASE_CONTAINER_PATH`, see Create or Reuse the Phase Container), so flat container mode never applies during phase-mode execution. In a multi-repo layout (`AIMI_ROOT_IS_GIT_REPO=false`), `CONTAINER_MODE=true` produces one container per project group instead of one at `AIMI_ROOT` — stored in the map `CONTAINER_PATHS[group_key]` (see Per-Project Branch Setup in Step 2), keyed identically to the project-root grouping in Multi-Repo Handling above.

**When `CONTAINER_MODE=true`:** read `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` now (if Phase Mode Detection above didn't already — the two conditions are mutually exclusive, so this is never a second read in the same run) — it is the single source of truth for the worktree naming/CWD, container creation, dev-server bootstrap, and Step 5 teardown mechanisms every flat-container-mode step from Step 2 onward delegates to by name. A session that resolves both `PHASE_MODE` and `CONTAINER_MODE` false (inline mode, the default) never reads this file — no call site below reads it unconditionally.

### Integrated Re-verify on Resume

A run that ended with `INTEGRATION CHECK FAILED` (see `commands/references/execute/wave-reconcile.md`) leaves the stories its merge brought onto the integration branch `in_progress`, with their worktrees and branches kept. Resuming must neither fail them nor run them again: their work is merged and only its union check is open. This section runs first, before any `reset-orphaned` call, because `reset-orphaned` marks every `in_progress` story failed and a failed story is never put back.

It applies when at least one story is `in_progress` in the run's tasks file. Otherwise INTEGRATED_UNCHECKED is empty and Orphaned Story Recovery runs untouched.

Integration branch, for each repository that holds an `in_progress` story: `.deliverableBranch` from `$AIMI_CLI metadata --with-deliverable-branch` (Step 1.7 has not yet named PHASE_BRANCH), or the SPLIT_BRANCH carried by the spawn prompt of a phase-split sub-orchestrator.

A story is recognized only when all four proofs hold:

```
1. status is in_progress in the run's tasks file
2. git -C [repo] branch --list "[PLAN_DISC]-*-[story id]" --format='%(refname:short)'
   prints exactly one branch
3. git reflog show --format=%gs [branch] (run with -C [repo]) has a line that starts with "commit"
   (the branch holds a commit of its own)
4. git -C [repo] merge-base --is-ancestor [branch] [integration branch] exits 0
```

An ancestor branch with no commit of its own, and a branch with commits that is not on the integration branch, are not recognized. Echo `INTEGRATED_UNCHECKED=[ids, space separated]`, empty when none.

Hold-out, when INTEGRATED_UNCHECKED is non-empty: drop the `reset-orphaned` line from the Orphaned Story Recovery Bash call. List the other `in_progress` ids with `$AIMI_CLI status --tasks-file "$STEP1_TASKS_FILE" | jq -r '.userStories[] | select(.status == "in_progress") | .id'` (omit `--tasks-file` when STEP1_TASKS_FILE is empty), and call `mark-failed` on each id outside the set with the cause `orphaned from previous session`. The recognized stories stay `in_progress`.

Hand-over, run by Step 3 (see its pointer paragraph). Per project group of the recognized ids, pass `commands/references/execute/wave-reconcile.md` these inputs:

```
label                "resume"
group_key            the project group of the stories
merge_cwd            derived as Step 4 derives EXEC_ROOT
merge_target         derived as Step 4 derives EXEC_BRANCH
base_sha             last line of: git -C [repo] reflog show --format=%H [a story branch]
                     (the branch's creation commit)
merged_stories       the group's recognized ids, with title from get-story;
                     worktree name = the matched branch
WAVE_TASKS_FILE, AIMI_ROOT, PLAN_DISC   as in the run
evidence             recorded for each (they merged only after their executor reported
                     success) but its exit is unknown, so the skip rule never applies
```

Step 4's entry reads that file later in the run: read it in full here only if it is not yet in context. A story with no `implementation.verify` is listed as not re-verified and still completed.

Outcomes per group: on passed or reconciled, `mark-complete` each recognized id with no `--evidence`, remove its worktree and branch with `$WORKTREE_MGR remove` from the group's merge_cwd, then read `count-pending` again so Step 4 and the start report use the new count. On the integration stop, wave-reconcile.md's own stop prints INTEGRATION CHECK FAILED; nothing is marked complete or removed, and the stories stay `in_progress`.

### Orphaned Story Recovery

Check for and reset stories stuck in `in_progress` status (from interrupted previous runs). Resolve this run's own tasks file explicitly rather than falling through to `reset-orphaned`'s shared current-tasks fallback — a split sub-orchestrator reaching this point (see Spawn Split Sub-Orchestrators) already has `PHASE_TASKS_PATH` pre-set. The one caller that reaches this subsection before Step 1.7 has resolved `PHASE_TASKS_PATH` — the top-level orchestrator's own first pass, claiming a phase for itself, with no sibling session racing it yet — has nothing to substitute, so the formula below yields `--tasks-file ""`; that empty value is `reset-orphaned`'s own signal to fall back to the shared pointer, which is exactly today's behavior:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
PHASE_MODE="[PHASE_MODE echoed by Step 1, or from the spawn prompt]"
TASKS_PATH="[tasks path from the init-session output]"
PHASE_TASKS_PATH="[PHASE_TASKS_PATH from Step 1.7 or the spawn prompt, empty when neither has set it]"
if [ "$PHASE_MODE" = "true" ]; then
  STEP1_TASKS_FILE="$PHASE_TASKS_PATH"
else
  STEP1_TASKS_FILE="$TASKS_PATH"
fi
$AIMI_CLI reset-orphaned --tasks-file "$STEP1_TASKS_FILE"
$AIMI_CLI validate-stories --tasks-file "$STEP1_TASKS_FILE" || echo "VALIDATE_STORIES=failed"
```

When Integrated Re-verify on Resume above echoed a non-empty INTEGRATED_UNCHECKED, this block does not call `reset-orphaned`; follow that section's hold-out instead.

The same block runs Content Validation below, on the same file, so it is one Bash call for both.

This atomically marks all `in_progress` stories as `failed` and returns:
```json
{"count": 2, "reset": ["US-003", "US-005"]}
```

If count > 0, report: "Recovered [count] orphaned in_progress stories (marked failed): [reset IDs]"

Note: These stories will appear as "failed" in status. `/aimi:execute` does not run a failed story again; to run one again, set it back to `pending` first.

### Content Validation

`validate-stories` ran in the Orphaned Story Recovery block above, on the same `PHASE_MODE`-conditioned file. `TASKS_PATH` is used as-is there: `init-session` always prints it absolute, so prefixing `$AIMI_ROOT/` would double it.

If the block printed `VALIDATE_STORIES=failed`, report the errors and STOP:
```
Story content validation failed:
[error output]

Review the stories for suspicious content and fix before execution.
```
