# Execute: Step 1.6: Branch Base Selection

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

## Step 1.6: Branch Base Selection

Before creating the task branch, when the current branch has unmerged work relative to the default branch, ask whether to stack on it or start fresh from the default branch. This prevents silently inheriting unrelated work or losing intentional stacking.

This step resolves the base for AIMI_ROOT itself. In a multi-repo layout (`AIMI_ROOT_IS_GIT_REPO=false`) AIMI_ROOT is not a git repository, so the four gating conditions below have nothing to evaluate — `CURRENT_BRANCH` and `DEFAULT_BRANCH` both resolve empty, condition 3 (`CURRENT_BRANCH` != `DEFAULT_BRANCH`) is trivially false, and the step falls through to **When Prompt Is Not Needed** below without a dedicated early return. Each project group resolves its own base independently in Step 2's Per-Project Branch Setup instead — see Multi-Repo Handling above.

**Skip this step's gating and prompt entirely when `$BASE_BRANCH` is already non-empty** — Step 0's Parse --base Override already ran and the user supplied an explicit base on the command line. Re-asking on top of an explicit answer would prompt twice for the same decision. Proceed straight to Step 1.7 with `BASE_BRANCH` unchanged; Step 2 and the phase container thread it exactly as if this step's picker had chosen it, and `resolve-base-branch` reports `explicit-base`/`promptNeeded: false` for it downstream.

`BASE_BRANCH` otherwise starts unset entering this step. It is set only when the user explicitly chooses a base via the picker below; Step 2 threads it via `--base` only when set, either way.

### Resolve Interactivity Mode

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
INTERACTIVE_MODE=$($AIMI_CLI detect-interactivity)
```

### Compute Gating Conditions

Check whether a prompt is needed. Compute all four conditions:

```bash
TARGET_EXISTS_LOCAL=$(git branch --list [branchName])
TARGET_EXISTS_REMOTE=$(git ls-remote --heads origin [branchName])
CURRENT_BRANCH=$(git branch --show-current)
CURRENT_IS_MERGED=$(git branch --merged "origin/$DEFAULT_BRANCH" | grep -Fx "  $CURRENT_BRANCH" || git branch --merged "origin/$DEFAULT_BRANCH" | grep -Fx "* $CURRENT_BRANCH")
```

A prompt is needed when **all four** of the following are true:

- `TARGET_EXISTS_LOCAL` is empty (branch does not exist locally)
- `TARGET_EXISTS_REMOTE` is empty (branch does not exist on remote)
- `CURRENT_BRANCH` != `DEFAULT_BRANCH` (not already on the default branch)
- `CURRENT_IS_MERGED` is empty (current branch has commits not yet merged into `origin/$DEFAULT_BRANCH`)

### Picker Prompt (when prompt is needed AND INTERACTIVE_MODE=picker)

Use **AskUserQuestion** with the following options:

```
Which branch should be used as the base for [branchName]?

A — Stack on current branch ([current_branch])
B — Use default branch ([DEFAULT_BRANCH])
Other — Specify a base branch
```

**Option A:** leave `BASE_BRANCH` unset. Do **not** set it to `$CURRENT_BRANCH` — that turns the answer into an `explicit-base`, and an explicit base is a reference point the resolver prefers `origin/` for, which would hand the container the last pushed commit instead of the local tip the user just asked to stack on. Unset is exactly right: `resolve-base-branch` resolves this repo to `stacked-on-current` on its own, and that reason deliberately keeps the bare local ref. This mirrors Option A of the per-project picker in Step 2, which likewise keeps the already-resolved value.

**Option B:** `BASE_BRANCH=$DEFAULT_BRANCH`

**Option Other:** Collect the free-form branch name the user typed. Validate it against `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$`. If it does not match, report:

```
Invalid branch name. Must match ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$
```

and STOP. If valid, store `BASE_BRANCH=<user-input>`.

### Agent-Mode Fallback (when prompt is needed AND INTERACTIVE_MODE=agent)

Leave `BASE_BRANCH` unset (preserves the existing CLI heuristic which stacks on the current branch, matching the previous automatic behavior). Log:

```
agent-mode: step-1.6 branch-base auto-preserve
```

*Agent-mode fallback: if `INTERACTIVE_MODE=agent`, leave BASE_BRANCH unset and log `agent-mode: step-1.6 branch-base auto-preserve`.*

### When Prompt Is Not Needed

If any of the four gating conditions is false, skip silently — do NOT log an agent-mode line. Leave `BASE_BRANCH` unset.
