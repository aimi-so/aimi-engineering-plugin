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

### Parse --phase Override

Scan `$ARGUMENTS` for an explicit `--phase <N>` token (mirrors the extraction style `/aimi:execute` uses for the same flag — see `commands/execute.md` "Parse --phase Override"). This flag is planning plumbing for the Rolling-Wave Phase Selection step below (Phase 0) — it is never part of the feature description text, so it is stripped before any downstream description-derived value (topic slug, research prompts, `metadata.title`) is computed:

```bash
case " $ARGUMENTS " in
  *" --phase "*)
    PHASE_OVERRIDE=$(echo "$ARGUMENTS" | sed -n 's/.*--phase[[:space:]]\+\([0-9][0-9.]*\).*/\1/p')
    ARGUMENTS_STRIPPED=$(echo "$ARGUMENTS" | sed 's/[[:space:]]*--phase[[:space:]]\+[0-9][0-9.]*[[:space:]]*/  /' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    ;;
  *)
    PHASE_OVERRIDE=""
    ARGUMENTS_STRIPPED="$ARGUMENTS"
    ;;
esac
```

If `PHASE_OVERRIDE` is non-empty but does not match `^[0-9]+(\.[0-9]+)?$`, refuse and STOP. Compose that refusal in the reader's own language per the **Adaptive Language Rule** (`${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`) rather than emitting a fixed English sentence, and have it name both the value that was typed and the ceiling it broke — a phase id carries at most one decimal level, so `1.1` is one and `1.1.1` is not. The same regex is enforced a second time, as an executed `case`, in the `--phase` override block of Rolling-Wave Phase Selection below: that block runs in its own shell and cannot see this check.

From this point forward, `$ARGUMENTS_STRIPPED` (not raw `$ARGUMENTS`) feeds the `--non-interactive` extraction below and every downstream feature-description derivation.

### Detect Interactivity

Interactive (picker) mode is the default. Pass `--non-interactive` to `/aimi:plan` to explicitly opt out of all Open Question prompts and auto-defer them instead (agent/CI mode).

Before calling the CLI, scan `$ARGUMENTS_STRIPPED` for the whitespace-delimited token `--non-interactive` (case-sensitive, exact match). When present:
- Strip it from the feature description text — store the cleaned version as `FEATURE_DESCRIPTION` for use in all downstream steps (topic slug derivation, research agent prompts, `metadata.title`). Neither the raw `$ARGUMENTS` string nor `$ARGUMENTS_STRIPPED` is used after this point.
- Forward the flag to the CLI call.

When absent, `FEATURE_DESCRIPTION` equals `$ARGUMENTS_STRIPPED` unchanged.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
# Extract --non-interactive flag and strip it from the feature description
case " $ARGUMENTS_STRIPPED " in
  *" --non-interactive "*)
    NON_INTERACTIVE_FLAG="--non-interactive"
    FEATURE_DESCRIPTION=$(echo "$ARGUMENTS_STRIPPED" | sed 's/[[:space:]]*--non-interactive[[:space:]]*/  /g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    ;;
  *)
    NON_INTERACTIVE_FLAG=""
    FEATURE_DESCRIPTION="$ARGUMENTS_STRIPPED"
    ;;
esac
INTERACTIVE_MODE=$($AIMI_CLI detect-interactivity $NON_INTERACTIVE_FLAG)
```

Store `INTERACTIVE_MODE` for use by Phase 0.5, Phase 1.8, Phase 1.9, Phase 2.5, and Phase 3c to decide whether to present AskUserQuestion prompts or auto-defer open questions. Use `FEATURE_DESCRIPTION` (not `$ARGUMENTS` or `$ARGUMENTS_STRIPPED`) everywhere a feature description string is needed from this point forward.

### Resolve Agent Models

Read and follow the **Resolve Agent Models** section of `commands/references/cli-path-resolution.md` to populate `AGENT_MODELS`. When resolution fails, treat every category as `"inherit"` and continue.
