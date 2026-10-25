# Execute: Step 3.3: Project Guidelines and Dev Server

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

## Step 3.3: Load Project Guidelines

Load project guidelines following the discovery order defined in `story-executor/SKILL.md` "PROJECT GUIDELINES" section:

1. **CLAUDE.md** (project root) - Primary project instructions
2. **AGENTS.md** (any directory) - Module-specific patterns
3. **Aimi defaults** from story-executor - Fallback if neither exists

Read these files and store the content as `PROJECT_GUIDELINES`.

### Per-Project Guidelines

When stories target different projects (via the `project` field), each project may have its own `CLAUDE.md` and `AGENTS.md`. Load guidelines per unique project path and store as a map: `PROJECT_GUIDELINES_MAP[project_path] = guidelines_content`.

- For stories without a `project` field, use the default `PROJECT_GUIDELINES` (loaded from the current repo root).
- For stories with a `project` field, look up `PROJECT_GUIDELINES_MAP[story.project]` and pass it as `PROJECT_GUIDELINES` in the worker prompt.
- If no stories have `project` fields, skip this map and use default `PROJECT_GUIDELINES` (backwards compatible).

### Container Dev Server Bootstrap

**Skip this subsection entirely unless `CONTAINER_MODE` is true** (see Execution Mode Detection in Step 1). When it applies, it MUST complete before Open Visual Follow Session below computes `VISUAL_URL` — the dev server's port is not known until `serve start` succeeds, and this ordering (install-deps → serve start → compute VISUAL_URL → open the visual-follow session → wave loop) is a hard requirement. Starting a container's dev server after the visual-follow session has already opened leaves the browser pointed at a stale or nonexistent port and is treated as a defect, never a valid alternative ordering.

Scan ALL pending stories (not just this wave's ready set — the dev server is started once, before the wave loop, and kept alive across every wave rather than restarted per wave) for the set of project groups that have at least one visual story:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
# `.project` on each visual story is already normalized by verification_report
# (tasks.py) -- any non-string shape collapsed to null there -- so `// "DEFAULT"`
# below fires on exactly the cases it always did, and `unique` never sees an
# array pretty-printed across several lines masquerading as several group keys.
VISUAL_GROUP_KEYS=$($AIMI_CLI verification-report --tasks-file "$AIMI_ROOT/$TASKS_PATH" | jq -r '[.visual[] | (.project // "DEFAULT")] | unique | .[]')
```

For each `group_key` in `VISUAL_GROUP_KEYS`, resolve its project root exactly as Multi-Repo Handling's grouping pattern does (`CWD`/`$AIMI_ROOT` for `"DEFAULT"`, otherwise `$AIMI_ROOT/[group_key]`):

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
BRANCH_NAME=$($AIMI_CLI metadata | jq -r '.branchName')
if ! [[ "$BRANCH_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
  echo "Invalid branchName: $BRANCH_NAME" >&2
  exit 1
fi
if [ "[group_key]" = "DEFAULT" ]; then
  EXEC_ROOT="$AIMI_ROOT"
else
  EXEC_ROOT="$AIMI_ROOT/[group_key]"
fi
EXEC_BRANCH="$BRANCH_NAME"
HAS_VISUAL_STORY=true
```

Delegate to **Bootstrap a Container Dev Server** with these values — targeting `CONTAINER_PATHS[group_key]`, already created by Step 2. Adopt its captured URL into this group's own entry:

```bash
if [ -n "$SERVE_URL" ]; then
  CONTAINER_DEV_URL[group_key]="$SERVE_URL"
fi
```

**Degradation is advisory, never fatal.** When a group's port never resolves, `CONTAINER_DEV_URL[group_key]` is simply never set for that group; Open Visual Follow Session below and the per-story post-merge verification block (Step 4) both treat a missing entry as "no dev server available for this group" and degrade that group's visual verification to `skipped` rather than blocking anything.

`CONTAINER_DEV_URL` is a map keyed identically to `CONTAINER_PATHS`/`project_roots` — one entry per project group, never a single global URL. A visual story in a different project group is resolved and rewritten independently, using its own group's entry.

