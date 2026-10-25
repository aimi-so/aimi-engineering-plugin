# Execute: Steps 3.1 and 3.2: Worktree Manager and Concurrency

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

## Step 3.1: Resolve Worktree Manager

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/cli-path-resolution.md` and follow the **Resolve Worktree Manager Path** section to set `$WORKTREE_MGR`.

If resolution fails, report error and STOP.

**`$WORKTREE_MGR` does not persist across Bash calls.** Re-read the cache at the top of every Bash call that uses it — see the **Per-Call Resolution** section of `commands/references/cli-path-resolution.md` for the one-liner and shell guard.

## Step 3.2: Read Concurrency Setting

Read the tasks file metadata to get maxConcurrency.

**Phase mode (`PHASE_MODE=true`):** re-run `init-session` with `--file "$PHASE_TASKS_PATH"` explicitly — not the bare form — so `maxConcurrency` is read from the claimed phase's own tasks file (see Concurrency Source in `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Phase Mode: Worktree Naming and CWD), not any feature-root or global file. The bare form would re-run `init-session`'s mtime-based auto-discovery and could silently re-point session state at a different, more-recently-touched sibling phase file:

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

