# Execute: Steps 3.1 and 3.2: Worktree Manager and Concurrency

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

## Step 3.1: Resolve Worktree Manager

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/cli-path-resolution.md` and follow the **Resolve Worktree Manager Path** section to set `$WORKTREE_MGR`.

If resolution fails, report error and STOP.

**`$WORKTREE_MGR` does not persist across Bash calls.** Re-read the cache at the top of every Bash call that uses it — see the **Per-Call Resolution** section of `commands/references/cli-path-resolution.md` for the one-liner and shell guard.

## Step 3.2: Read Concurrency Setting

`init-session` does not return `maxConcurrency`; `metadata` does. Read it from this run's own tasks file — `$PHASE_TASKS_PATH` in phase mode (`PHASE_MODE=true`), so the value comes from the claimed phase's own tasks file and not from a feature-root or sibling phase file (see Concurrency Source in `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Phase Mode: Worktree Naming and CWD), `$TASKS_PATH` otherwise. `--tasks-file` never re-runs auto-discovery and writes no session state.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
CONCURRENCY_FILE="[PHASE_TASKS_PATH in phase mode, otherwise TASKS_PATH]"
echo "MAX_CONCURRENCY=$($AIMI_CLI metadata --tasks-file "$CONCURRENCY_FILE" | jq -r '.maxConcurrency // 20')"
```

Fill `CONCURRENCY_FILE` from the value an earlier step echoed. Store the echoed value as `MAX_CONCURRENCY` (20 when the metadata sets none). No `init-session` re-run happens here: Step 1.7 already pointed the session at the phase's file, and a re-run would rewrite the shared current-tasks pointer under a concurrent split.
