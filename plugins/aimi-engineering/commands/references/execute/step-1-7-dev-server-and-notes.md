# Execute: Step 1.7: Phase Container Dev Server and Path Notes

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

### Phase Container Dev Server Bootstrap

**Skip this subsection entirely when `PHASE_SPLIT_MODE` is true** — a split phase never lands a story directly on `PHASE_CONTAINER_PATH` itself, so there is nothing to serve here; each split gets its own independently-bootstrapped server instead (see Split Container Dev Server Bootstrap in Phase-Mode Paired Split below). The rest of this subsection assumes `PHASE_SPLIT_MODE=false`, and therefore that every group came from `PHASE_MAIN_TASKS` (Create Phase Containers Per Project Group above never reads a split file's own tasks source in this branch).

When it applies, this MUST complete before Step 3.3's Open Visual Follow Session computes `VISUAL_URL` — the same hard ordering rule Container Dev Server Bootstrap (Step 3.3) already enforces for flat container mode: install-deps → serve start → compute VISUAL_URL → open the visual-follow session.

Gate on the phase's own tasks file having at least one visual story at all — the same verb Step 0.7 already uses — before doing any per-group work:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
PHASE_VISUAL_STORIES=$($AIMI_CLI verification-report --tasks-file "$PHASE_TASKS_PATH" 2>/dev/null | jq '.visual | length' 2>/dev/null)
```

**When `PHASE_VISUAL_STORIES` is 0 or empty:** skip the rest of this subsection entirely — no group needs a server, so no `WORKTREE_MGR` resolution happens.

**Otherwise**, compute each group's *own* `HAS_VISUAL_STORY` gate — filtering `PHASE_MAIN_TASKS`'s visual stories (fetched ONCE, before the loop, from the same verb) by that group's own `.project` value, never the whole-file count just computed above — into a `<toplevel>\t<true|false>` plan-line list, mirroring Split Container Dev Server Bootstrap's plan-line technique (Phase-Mode Paired Split, below) so a bare `HAS_VISUAL_STORY` scalar is never read after being reassigned across groups in a loop:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
# This subsection only runs for PHASE_SPLIT_MODE=false (see above), so
# project-groups' single tasks-file mode is always the right one here --
# unlike Derive Participating Project Groups, there is no split branch to
# preserve. A refusal here (an invalid project value) is new: this site
# never validated before.
PHASE_GROUPS_JSON=$($AIMI_CLI project-groups --tasks-file "$PHASE_MAIN_TASKS") || exit 1
PHASE_GROUP_PROJECTS=$(printf '%s' "$PHASE_GROUPS_JSON" | jq -r '.groups[]')
PHASE_MAIN_VERIF_REPORT=$($AIMI_CLI verification-report --tasks-file "$PHASE_MAIN_TASKS" 2>/dev/null)

PHASE_SERVER_PLAN=""
while IFS= read -r GROUP_PROJECT; do
  [ -n "$GROUP_PROJECT" ] || continue
  if [ "$GROUP_PROJECT" = "." ]; then
    GROUP_ROOT="$AIMI_ROOT"
  else
    GROUP_ROOT="$AIMI_ROOT/$GROUP_PROJECT"
  fi
  GROUP_TOPLEVEL=$(git -C "$GROUP_ROOT" rev-parse --show-toplevel 2>/dev/null) || GROUP_TOPLEVEL="$GROUP_ROOT"
  # A trivial jq FILTER over the verb's own JSON, already fetched above -- not
  # a second document read with a --project flag. `.project` on each visual
  # story already collapsed any non-string shape to null (verification_report
  # in tasks.py), so `// "."` here fires on exactly the cases it always did.
  PHASE_GROUP_VISUAL=$(printf '%s' "$PHASE_MAIN_VERIF_REPORT" | jq --arg p "$GROUP_PROJECT" \
    '[.visual[] | select((.project // ".") == $p)] | length' 2>/dev/null)
  if [ "${PHASE_GROUP_VISUAL:-0}" -gt 0 ]; then
    PHASE_SERVER_PLAN="${PHASE_SERVER_PLAN}${GROUP_TOPLEVEL}"$'\t'"true"$'\n'
  else
    PHASE_SERVER_PLAN="${PHASE_SERVER_PLAN}${GROUP_TOPLEVEL}"$'\t'"false"$'\n'
  fi
done <<< "$PHASE_GROUP_PROJECTS"
```

Then, for each plan line whose second field is `true`, delegate to **Bootstrap a Container Dev Server** with `EXEC_ROOT` = that line's first field (that group's own resolved toplevel — the project root, never inside the container itself, the same `EXEC_ROOT` Create Phase Containers Per Project Group above `cd`s to before calling `$WORKTREE_MGR create`) and `EXEC_BRANCH="$PHASE_BRANCH"`:

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"; [ -x "$WORKTREE_MGR" ] || { echo "WORKTREE_MGR is stale: $WORKTREE_MGR does not exist — re-run check-version --quiet --fix" >&2; exit 1; }
while IFS=$'\t' read -r GROUP_TOPLEVEL GROUP_HAS_VISUAL; do
  [ -n "$GROUP_TOPLEVEL" ] || continue
  [ "$GROUP_HAS_VISUAL" = "true" ] || continue
  EXEC_ROOT="$GROUP_TOPLEVEL"
  EXEC_BRANCH="$PHASE_BRANCH"
  cd "$EXEC_ROOT"
  $WORKTREE_MGR install-deps "$EXEC_BRANCH"
  $WORKTREE_MGR serve start "$EXEC_BRANCH" >/dev/null
done <<< "$PHASE_SERVER_PLAN"
```

Its captured URL is discarded here — every later consumer (Step 3.3's Open Visual Follow Session, and Step 4's post-merge visual verification) re-queries the server fresh via `serve url` at the point it needs it. With exactly one group (today's unchanged case), `GROUP_TOPLEVEL` resolves to `$AIMI_ROOT` and this reduces to exactly one `install-deps`/`serve start` pair against `$AIMI_ROOT`, `$PHASE_BRANCH` — the same call this subsection made before.

### Path and State Notes

From this point forward, for the remainder of this phase's execution:

- Every Bash call that touches this phase's git state passes `PHASE_CONTAINER_PATH` explicitly — `cd "$PHASE_CONTAINER_PATH"` at the top of the call, or `git -C "$PHASE_CONTAINER_PATH"` / `$WORKTREE_MGR` invocations that take it as an argument — never assuming a CWD persisted from a prior call. This is the same "each Bash tool call is an isolated shell" rule from Step 0, applied to the container path instead of `AIMI_ROOT`. See `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Phase Mode: Worktree Naming and CWD for how this threads through Step 4's wave loop.
- `$AIMI_CLI` calls issued with CWD inside `PHASE_CONTAINER_PATH` still resolve to the main root's central `.aimi/` state with no special-casing required: `.aimi/` is gitignored, so it is absent from the container's checkout. `find_aimi_root`'s upward directory walk starts inside `PHASE_CONTAINER_PATH` (`<GIT_ROOT>/.worktrees/<phase-branch>`), finds no `.aimi/` there or in `.worktrees/`, and continues up through `<GIT_ROOT>` where the real `.aimi/` lives — passing straight through the extra nesting.
