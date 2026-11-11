# Execute: Step 1.5: Branch Freshness Check

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

## Step 1.5: Branch Freshness Check

Detect the default branch and fetch the latest from origin before branch setup.

### Detect Git Repo Layout

One block. It checks whether AIMI_ROOT (the directory containing `.aimi/`) is itself a git repository, by the canonical derivation from the **AIMI_ROOT_IS_GIT_REPO Branching Rule** in Multi-Repo Handling, embedded verbatim (each Bash call is an isolated shell, so `AIMI_ROOT` is re-derived here first). When it is, the same block detects the default branch and fetches from origin; when it is not, it does neither, because per-project detection and fetch happen in the branch setup step (see Multi-Repo Handling above).

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
AIMI_ROOT="$PWD"
while [ "$AIMI_ROOT" != "/" ] && [ ! -d "$AIMI_ROOT/.aimi" ]; do AIMI_ROOT=$(dirname "$AIMI_ROOT"); done
[ -d "$AIMI_ROOT/.aimi" ] || AIMI_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
if git -C "$AIMI_ROOT" rev-parse --git-dir >/dev/null 2>&1; then AIMI_ROOT_IS_GIT_REPO=true; else AIMI_ROOT_IS_GIT_REPO=false; fi
echo "AIMI_ROOT_IS_GIT_REPO=$AIMI_ROOT_IS_GIT_REPO"
if [ "$AIMI_ROOT_IS_GIT_REPO" = "true" ]; then
  echo "DEFAULT_BRANCH=$($AIMI_CLI detect-default-branch)"
  git fetch origin >/dev/null 2>&1 && echo "FETCH=ok" || echo "FETCH=failed"
fi
```

The echoed lines are what every agent-level branch below reads, and the only place the values become observable outside a shell. See the **Multi-Repo Handling** section above for the full contract. Store `DEFAULT_BRANCH` for use in branch creation and commit counting.

If `FETCH=failed` (e.g., offline or no remote), warn but continue:
```
Warning: git fetch origin failed — continuing with local state. Branch may be stale.
```
