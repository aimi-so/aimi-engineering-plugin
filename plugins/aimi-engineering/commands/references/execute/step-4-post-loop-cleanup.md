# Execute: Post-Loop Cleanup

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

### Post-Loop Cleanup

After the wave loop ends (all stories processed or deadlock):

**Phase and container mode (`EXEC_OWNS_ROOT=true`):** cleanup runs per project group with CWD = `EXEC_ROOT[group_key]`, matching worktrees named `"[PLAN_DISC]-[EXEC_BRANCH[group_key]]-US-*"` — the same derivation rule as `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md`'s Execution Context: EXEC_ROOT, EXEC_BRANCH, EXEC_OWNS_ROOT, EXEC_KEEPS_BRANCH subsection (`PHASE_CONTAINER_PATHS[group_key]`/`PHASE_BRANCH` in phase mode, `CONTAINER_PATHS[group_key]`/`branchName` in container mode). Step 4's own wave loop rebuilds `EXEC_ROOT`/`EXEC_BRANCH` fresh each wave, scoped to that wave's own stories; Post-Loop Cleanup runs after the loop ends, so it re-derives them here across every unique `group_key` with at least one story scheduled this run, rather than reading a stale, single-wave-scoped copy. In phase mode every `group_key` resolves to its own `PHASE_CONTAINER_PATHS[group_key]` — the same `PHASE_BRANCH` name, but each group's own repository's own container — so in the common case of a single group_key this degenerates to exactly the single iteration today's phase-only cleanup already runs; on a genuinely multi-repo phase that grouped stories under more than one `group_key`, the loop below runs once per group_key against that group's own container, sweeping each participating repository in turn rather than repeating a pass against the one the first iteration already covered. The main working tree (`AIMI_ROOT`) is never `cd`'d into by this step.

```
for each unique group_key with at least one story scheduled this run:
    cd [EXEC_ROOT[group_key]]
    $WORKTREE_MGR list
    # For each worktree matching "[PLAN_DISC]-[EXEC_BRANCH[group_key]]-US-*":
    $WORKTREE_MGR remove [worktree_name]

    # Legacy pass — the un-prefixed shape a run predating the plan discriminator
    # left inside this same container. Same list, same CWD; only the pattern
    # differs, and no run can create another one.
    # For each worktree matching "[EXEC_BRANCH[group_key]]-US-*":
    $WORKTREE_MGR remove [worktree_name]
```

**Flat/inline mode (`PHASE_MODE=false`, `CONTAINER_MODE=false`):** unchanged.

```
# Remove any remaining worktrees (safety cleanup)
# Per-project cleanup rule — see Multi-Repo Handling section.
for each unique project_root (including CWD for DEFAULT group):
    cd [project_root]
    $WORKTREE_MGR list
    # For each worktree matching "[PLAN_DISC]-[branchName]-US-*":
    $WORKTREE_MGR remove [worktree_name]

# When no stories have project fields, use current directory (backwards compatible):
$WORKTREE_MGR list
# For each worktree matching "[PLAN_DISC]-[branchName]-US-*":
$WORKTREE_MGR remove [worktree_name]
```

### Visual Follow Session — Keep Open

See the Visual Follow Lifecycle section (Phase 4 — Keep Open on Completion).

If `VISUAL_FOLLOW=true`, do NOT close the `visual-follow` session.

Report: `"Visual follow session still open — close manually when done: agent-browser --session visual-follow close"`

