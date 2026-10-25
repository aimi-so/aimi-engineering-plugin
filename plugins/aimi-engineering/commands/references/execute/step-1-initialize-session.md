# Execute: Step 1: Initialize Session and Phase Mode Detection

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

## Step 1: Initialize Session

**CRITICAL:** Use the CLI script to initialize session and get metadata. Do NOT interpret jq queries directly.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI init-session
```

This returns:
```json
{
  "tasks": ".aimi/tasks/2026-02-24-feature-tasks.json",
  "branch": "feat/feature-name",
  "pending": 7
}
```

If no tasks file found, the script exits with error. Report:
```
No tasks file found. Run /aimi:plan to create a task list first.
```
STOP execution.

### Phase Mode Detection

Determine whether the tasks file `init-session` discovered belongs to a phase/milestone roadmap (the nested `.aimi/tasks/<feature>/phase-N[.M]-<slug>/<feature>-phase-N-tasks.json` layout from outline 04) or is a flat v3.3 file (`.aimi/tasks/<date>-<feature>-tasks.json`), and store the result as `PHASE_MODE`:

```bash
TASKS_PATH="[tasks path from the init-session output above]"
FEATURE_DIR=$(dirname "$(dirname "$TASKS_PATH")")
if [ -f "$FEATURE_DIR/roadmap.json" ]; then
  PHASE_MODE=true
  FEATURE=$(basename "$FEATURE_DIR")
  ROADMAP_PATH="$FEATURE_DIR/roadmap.json"
else
  PHASE_MODE=false
fi
```

This needs no new CLI call: a flat file's tasks path is a direct child of `.aimi/tasks/` (e.g. `.aimi/tasks/2026-02-24-feature-tasks.json`), so `$FEATURE_DIR` resolves to `.aimi` — which never contains `roadmap.json`. A nested phase file's tasks path is `.aimi/tasks/<feature>/phase-N[.M]-<slug>/<feature>-phase-N-tasks.json`, so `$FEATURE_DIR` resolves to `.aimi/tasks/<feature>` — exactly where `roadmap-init` writes `roadmap.json`. This is the same directory-arithmetic `cmd_list_archivable` already uses to group nested files by feature.

**When `PHASE_MODE=false` (flat v3.3 file, no `roadmap.json` sibling): execute.md runs byte-for-byte as it does today.** No further phase-mode logic applies anywhere in this document — Step 1.7 (Phase Claim) is skipped entirely; when `EXECUTION_MODE` is `inline` or absent (see Execution Mode Detection below), Step 2 checks out `branchName` directly in the main working tree exactly as before, while `EXECUTION_MODE=container` instead routes Step 2 through Flat Container Mode's own worktree creation (see Step 2); and Step 4's story worktrees are named `[PLAN_DISC]-[branchName]-[story.id]` — the plan discriminator is the one clause of this paragraph that is no longer unchanged, and it applies identically in every mode (see `### Plan Discriminator` under Multi-Repo Handling). Phase mode is a parallel path added alongside the flat path; it never changes the flat path's behavior.

**When `PHASE_MODE=true`:** read `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` now — it is the single source of truth for the worktree naming/CWD, container creation, and dev-server bootstrap mechanisms every phase-mode step from Step 1.7 onward delegates to by name.
