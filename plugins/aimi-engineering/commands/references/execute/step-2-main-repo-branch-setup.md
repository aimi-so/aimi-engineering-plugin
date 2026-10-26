# Execute: Step 2: Main Repo Branch Setup

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

### Main Repo Branch Setup

**Skip this step if `AIMI_ROOT_IS_GIT_REPO` is false, if `PHASE_MODE` is true, or if flat container mode applies (`PHASE_MODE=false` and `EXECUTION_MODE=container`, i.e. `CONTAINER_MODE=true`)** — see Multi-Repo Handling above for the first condition. In phase mode, the phase container's `$WORKTREE_MGR create` call in Step 1.7 is the only branch-creating operation for this phase; no `setup-branch` call runs against the main working tree, which is what keeps the Main Working Tree Untouched Invariant (see `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Phase Mode: Worktree Naming and CWD) true. In flat container mode, Flat Container Mode's own `$WORKTREE_MGR create` call above is likewise the only branch-creating operation for this run. When `EXECUTION_MODE` is `inline` or absent, this subsection runs byte-for-byte exactly as it does today — no observable change to the inline path.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
BASE_BRANCH="[the value Step 0's Parse --base Override echoed, or empty when --base was absent]"
if [ -n "$BASE_BRANCH" ]; then
  BRANCH_JSON=$($AIMI_CLI setup-branch [branchName] --default-branch "$DEFAULT_BRANCH" --base "$BASE_BRANCH")
else
  BRANCH_JSON=$($AIMI_CLI setup-branch [branchName] --default-branch "$DEFAULT_BRANCH")
fi
```

If the command fails (non-zero exit), report the error and STOP.

Extract the action from the JSON output and report:
```
Branch setup: [action]
```

Where `[action]` is the `action` field from the JSON response (e.g., `already-on-branch`, `checked-out-local`, `checked-out-remote`, `created-from-default`, `created-from-current`, `created-from-base`).
