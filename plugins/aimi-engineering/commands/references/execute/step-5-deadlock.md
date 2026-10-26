# Execute: Step 5: Deadlock

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

### If deadlock detected:

This branch also fires for the gate-blocked case above (Step 4's Gate-Blocked Story Detection reports its own "blocked by gates" message inline and then breaks the loop into this same completion path) — "none ready" is never caused only by cascade-skip.

```
## Execution Stopped - Deadlock

[N] stories remain pending but none are ready for execution.
This may be caused by failed stories whose dependents were cascade-skipped, or by a
permanently pending action gate blocking every remaining dependent story.

Run `/aimi:status` to see the dependency state.
Review failed stories and either retry or adjust dependencies.
```

**Container mode (`CONTAINER_MODE=true` or `PHASE_MODE=true`):** this branch never runs Container Mode: Stop the Dev Server / Push the Branch / Remove the Container — those only run in the **If all stories complete** branch above. The feature or phase container and its `.aimi/state/dev-server.json` entry are left exactly as they were; append to the report above:

```
The feature container and any dev server inside it are untouched — inspect the
branch there directly, or resume with a plain /aimi:execute re-run (see Resuming
Execution).
```

