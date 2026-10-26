# Plan: Step 0: Environment Setup

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.

## Step 0: Environment Setup

### Resolve CLI Path

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/cli-path-resolution.md` and follow the **Resolve CLI Path** and **Version Check** sections to set `$AIMI_CLI`. Each layer is a separate Bash call.

If resolution fails, report error and STOP.

**Each Bash tool call is an isolated shell — `$AIMI_CLI` does not persist.** Re-read the cache at the top of every subsequent Bash call that needs `$AIMI_CLI`. See the **Per-Call Resolution** section of `commands/references/cli-path-resolution.md` for the one-liner and shell guard to prepend.

### Capture AIMI_ROOT

Capture the project root as an absolute path **once** at the start of Step 0. All subsequent phases resolve paths against this value — no phase may rely on the persisted shell CWD, which can drift across Bash calls.

```bash
# Walk up from CWD to the directory containing .aimi/ — this is the SAME root
# the CLI resolves (it discovers .aimi/ by walking up), so single-repo and
# multi-repo layouts (where .aimi/ lives in a non-git parent above the child
# repos) both resolve to the root the rest of the system agrees on. Fall back
# to the git toplevel, then $PWD, only when no .aimi/ marker is found.
AIMI_ROOT="$PWD"
while [ "$AIMI_ROOT" != "/" ] && [ ! -d "$AIMI_ROOT/.aimi" ]; do AIMI_ROOT=$(dirname "$AIMI_ROOT"); done
[ -d "$AIMI_ROOT/.aimi" ] || AIMI_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
```

Store `AIMI_ROOT` in working memory. Every path constructed in Phase 0, Phase 1, Phase 3, and Phase 4 (research output paths, spec paths, prototype paths, staging directories, output tasks file) must be expressed as `$AIMI_ROOT/<relative-path>` or verified to start with the captured value.

### Detect Git Repo Layout

Check if the current directory (AIMI root) is itself a git repository:

```bash
git rev-parse --git-dir >/dev/null 2>&1
```

Store the result as `AIMI_ROOT_IS_GIT_REPO` (true/false). When false, this is a **multi-repo layout** — default branch detection is deferred to Phase 4 after the git repo auto-scan discovers project paths.

### Fetch Origin & Detect Default Branch

**If `AIMI_ROOT_IS_GIT_REPO` is true:**

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
git fetch origin 2>&1 || echo "WARNING: git fetch failed (offline?). Continuing with local refs."
$AIMI_CLI detect-default-branch
```

Use the output as the default branch for `branchName` derivation in Phase 4.

**If `AIMI_ROOT_IS_GIT_REPO` is false:** Skip. Default branch detection happens per-project in Phase 4 using `$AIMI_CLI detect-default-branch --project [path]`.
