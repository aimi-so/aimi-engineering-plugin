# Execute: Step 1: Execution Mode, Orphan Recovery and Content Validation

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

### Execution Mode Detection

Read `metadata.execution` — the discriminator defined in `commands/references/execution-mode.md` — from the tasks file `init-session` discovered, via the same guarded `metadata` call the rest of this document uses for the same file:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
EXECUTION_MODE=$($AIMI_CLI metadata | jq -r '.execution // "inline"')
```

Only the literal string `"container"` selects the container path; every other value (`"inline"`, absence, or anything unrecognized) resolves to `inline` — the same fail-safe default rule the reference doc defines.

**Apply the `--container`/`--inline` override from above, when one was passed:**

- **`PHASE_MODE=true`:** the override is always ignored — a claimed phase already runs inside its own phase container regardless of `metadata.execution` (see the `CONTAINER_MODE` derivation below). If `EXECUTION_OVERRIDE` is non-empty, report a warning and leave `EXECUTION_MODE` exactly as read from the file:
  ```
  Warning: --container/--inline is ignored on a phase-scoped tasks file. Phase mode always runs inside its own phase container; see /aimi:execute --phase.
  ```
- **`PHASE_MODE=false` and `EXECUTION_OVERRIDE` non-empty:** the override replaces `EXECUTION_MODE` for this run. When it differs from the value already on disk, persist it via `set-execution-mode` so a later invocation without the flag continues in the same mode:

```bash
if [ "$PHASE_MODE" = "false" ] && [ -n "$EXECUTION_OVERRIDE" ]; then
  if [ "$EXECUTION_OVERRIDE" != "$EXECUTION_MODE" ]; then
    AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
    : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
    $AIMI_CLI set-execution-mode "$EXECUTION_OVERRIDE"
  fi
  EXECUTION_MODE="$EXECUTION_OVERRIDE"
fi
```

Derive `CONTAINER_MODE`, the single boolean this document's flat-mode container logic (Step 0.9, Step 2) gates on:

```bash
if [ "$PHASE_MODE" = "false" ] && [ "$EXECUTION_MODE" = "container" ]; then
  CONTAINER_MODE=true
else
  CONTAINER_MODE=false
fi
```

`CONTAINER_MODE` is always false when `PHASE_MODE=true` — a claimed phase already has its own container (`PHASE_CONTAINER_PATH`, see Create or Reuse the Phase Container), so flat container mode never applies during phase-mode execution. In a multi-repo layout (`AIMI_ROOT_IS_GIT_REPO=false`), `CONTAINER_MODE=true` produces one container per project group instead of one at `AIMI_ROOT` — stored in the map `CONTAINER_PATHS[group_key]` (see Per-Project Branch Setup in Step 2), keyed identically to the project-root grouping in Multi-Repo Handling above.

**When `CONTAINER_MODE=true`:** read `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` now (if Phase Mode Detection above didn't already — the two conditions are mutually exclusive, so this is never a second read in the same run) — it is the single source of truth for the worktree naming/CWD, container creation, dev-server bootstrap, and Step 5 teardown mechanisms every flat-container-mode step from Step 2 onward delegates to by name. A session that resolves both `PHASE_MODE` and `CONTAINER_MODE` false (inline mode, the default) never reads this file — no call site below reads it unconditionally.

### Orphaned Story Recovery

Check for and reset stories stuck in `in_progress` status (from interrupted previous runs). Resolve this run's own tasks file explicitly rather than falling through to `reset-orphaned`'s shared current-tasks fallback — a split sub-orchestrator reaching this point (see Spawn Split Sub-Orchestrators) already has `PHASE_TASKS_PATH` pre-set. The one caller that reaches this subsection before Step 1.7 has resolved `PHASE_TASKS_PATH` — the top-level orchestrator's own first pass, claiming a phase for itself, with no sibling session racing it yet — has nothing to substitute, so the formula below yields `--tasks-file ""`; that empty value is `reset-orphaned`'s own signal to fall back to the shared pointer, which is exactly today's behavior:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
AIMI_ROOT="$PWD"
while [ "$AIMI_ROOT" != "/" ] && [ ! -d "$AIMI_ROOT/.aimi" ]; do AIMI_ROOT=$(dirname "$AIMI_ROOT"); done
[ -d "$AIMI_ROOT/.aimi" ] || AIMI_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
if [ "$PHASE_MODE" = "true" ]; then
  STEP1_TASKS_FILE="$PHASE_TASKS_PATH"
else
  STEP1_TASKS_FILE="$AIMI_ROOT/$TASKS_PATH"
fi
$AIMI_CLI reset-orphaned --tasks-file "$STEP1_TASKS_FILE"
```

This atomically marks all `in_progress` stories as `failed` and returns:
```json
{"count": 2, "reset": ["US-003", "US-005"]}
```

If count > 0, report: "Recovered [count] orphaned in_progress stories (reset to failed for retry): [reset IDs]"

Note: These stories will appear as "failed" in status. The user can review and re-run.

### Content Validation

Same resolution as Orphaned Story Recovery immediately above — a fresh `AIMI_ROOT` derivation (each Bash call is an isolated shell) feeding the identical `PHASE_MODE`-conditioned formula:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
AIMI_ROOT="$PWD"
while [ "$AIMI_ROOT" != "/" ] && [ ! -d "$AIMI_ROOT/.aimi" ]; do AIMI_ROOT=$(dirname "$AIMI_ROOT"); done
[ -d "$AIMI_ROOT/.aimi" ] || AIMI_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
if [ "$PHASE_MODE" = "true" ]; then
  STEP1_TASKS_FILE="$PHASE_TASKS_PATH"
else
  STEP1_TASKS_FILE="$AIMI_ROOT/$TASKS_PATH"
fi
$AIMI_CLI validate-stories --tasks-file "$STEP1_TASKS_FILE"
```

If validation fails (exit non-zero), report the errors and STOP:
```
Story content validation failed:
[error output]

Review the stories for suspicious content and fix before execution.
```
