# Execute: Resuming Execution and Error Recovery

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

## Resuming Execution

The tasks file preserves all state. Re-running `/aimi:execute` will:

1. Detect the schema version again
2. Skip completed stories automatically
3. Pick up from the next ready wave
4. Failed stories remain as "failed" -- use `/aimi:status` to review them

**Flat container mode (`CONTAINER_MODE=true`, `PHASE_MODE=false`):** re-running `/aimi:execute` after a run stopped short of full completion (deadlock, a gate-blocked wave, a per-wave merge conflict, or an unexpected session crash) needs no new resumption mechanism. Step 2's Flat Container Mode `$WORKTREE_MGR create [branchName] --from "$CONTAINER_BASE"` call (see Create or Reuse the Container) is already idempotent — it reuses `CONTAINER_PATHS[group_key]`'s existing directory silently instead of recreating it — so the container, its branch, any dev server still running inside it, and every story already merged onto `[branchName]` all survive the stop untouched, and the re-run simply picks up in the next ready wave exactly as points 1–4 above describe.

**Phase mode:** re-running `/aimi:execute` for a phase this session already claimed and left `in_progress` does not error. `roadmap-claim`'s self-reclaim path (Step 1.7) reports the same phase again instead of a contention failure, and `$WORKTREE_MGR create "$PHASE_BRANCH" --from "$CONTAINER_BASE"` reuses the existing container directory silently since the target already exists — no separate reuse-detection logic is needed beyond calling both idempotently on every claim.

**Phase mode with a split (`PHASE_SPLIT_MODE=true`):** the same idempotency extends to Phase-Mode Paired Split — `$WORKTREE_MGR create "$split_branch" --from "$PHASE_BRANCH"`, run once per active split branch, reuses each split worktree silently if a prior run left one in place, and re-spawning the sub-orchestrators is harmless: each one's own `init-session --file` points at a split file whose already-completed stories are skipped automatically (points 1–4 above), so a sub-orchestrator with nothing left pending returns immediately. A member that completed entirely on the prior run is dropped by Step 1.7's Active Split Files filter and never re-spawned at all. This is also what makes retrying after a Merge Split Branches Into the Phase Branch conflict safe, for any number N of participating repositories: re-running does not re-execute any story, and it re-issues **every** repository's own `merge-all` call in full — never a partial resume from a saved per-repository position — because a branch already merged onto its own repository's `$PHASE_BRANCH` merges again idempotently ("Already up to date", exit 0), whether this run merged it moments ago or a human resolved a different repository's conflict by hand inside that repository's own phase container first (per that section's own report instruction to do so). Retrying therefore only retries the merge and the Multi-File Pending Count / Creates Verification checks that follow it.

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

### Abandoning a Containerized Run

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Abandoning a Containerized Run — container mode (flat or phase) never removes the feature/phase container or stops its dev server outside the completion path, so giving up on a run for good (rather than resuming it) needs its own manual teardown; the reference defines the order (stop the dev server, then remove the container) and the pid-identity guarantees that make it safe.

