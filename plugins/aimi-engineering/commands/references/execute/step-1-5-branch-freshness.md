# Execute: Step 1.5: Branch Freshness Check

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

## Step 1.5: Branch Freshness Check

Detect the default branch and fetch the latest from origin before branch setup.

### Detect Git Repo Layout

Check whether AIMI_ROOT (the directory containing `.aimi/`) is itself a git repository. This is the canonical derivation from the **AIMI_ROOT_IS_GIT_REPO Branching Rule** in Multi-Repo Handling, embedded verbatim — each Bash call is an isolated shell, so `AIMI_ROOT` is re-derived here first:

```bash
AIMI_ROOT="$PWD"
while [ "$AIMI_ROOT" != "/" ] && [ ! -d "$AIMI_ROOT/.aimi" ]; do AIMI_ROOT=$(dirname "$AIMI_ROOT"); done
[ -d "$AIMI_ROOT/.aimi" ] || AIMI_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
if git -C "$AIMI_ROOT" rev-parse --git-dir >/dev/null 2>&1; then AIMI_ROOT_IS_GIT_REPO=true; else AIMI_ROOT_IS_GIT_REPO=false; fi
echo "AIMI_ROOT_IS_GIT_REPO=$AIMI_ROOT_IS_GIT_REPO"
```

The echoed line is what every agent-level branch below reads — this block's only output, and the only place the value becomes observable outside a shell. See the **Multi-Repo Handling** section above for the full contract.

### Default Branch and Origin Fetch

When the flag is true, run both of the following. When false, skip both — per-project detection and fetch happen in the branch setup step (see Multi-Repo Handling above).

Detect the default branch:
```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
DEFAULT_BRANCH=$($AIMI_CLI detect-default-branch)
```
Store `DEFAULT_BRANCH` for use in branch creation and commit counting.

Fetch from origin:
```bash
git fetch origin
```
If fetch fails (e.g., offline or no remote), warn but continue:
```
Warning: git fetch origin failed — continuing with local state. Branch may be stale.
```
