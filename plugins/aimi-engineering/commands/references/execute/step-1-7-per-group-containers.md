# Execute: Step 1.7: Phase Containers Per Project Group

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

### Create Phase Containers Per Project Group

This phase's participating project groups cannot be known until **Detect a Full-Stack Split Inside This Phase** above has run: `PHASE_SPLIT_MODE`, and — when true — `PHASE_ACTIVE_SPLIT_FILES`, are its inputs here. This subsection creates (or reuses) one phase container per participating repository, never a single container rooted at `AIMI_ROOT` regardless of where a story's or split member's own `project` field resolves — mirroring Step 0.9 Pass 1's own per-repo resolution (`git -C ... rev-parse --show-toplevel`, `$AIMI_CLI detect-default-branch --project`, collision-checked on `(repo toplevel, branch)`) rather than inventing a second mechanism. It populates `project_roots[group_key]` and `PHASE_CONTAINER_PATHS[group_key]` (`${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Phase Container Paths Per Project Group) — every later consumer of a phase's container path in this document reads one of the two.

#### Derive Participating Project Groups

**When `PHASE_SPLIT_MODE=true`,** groups come from every *active* split member's own `metadata.splitGroup.project` — never from this phase's single governing tasks file, which does not exist on disk for a split phase. A legacy frontend/backend pair (no `splitGroup` marker, both members implicitly rooted at `.`) collapses to the single `.` group, preserving today's single-container behavior for that case. **When `PHASE_SPLIT_MODE=false`,** groups come from the phase's own governing tasks file's `userStories[].project`, exactly the Per-Story Project-Grouping Pattern (Multi-Repo Handling) applied to this one file — a project-less story's `null` collapses to the same `.` group.

```bash
PHASE_MAIN_TASKS="$AIMI_ROOT/.aimi/tasks/$FEATURE/$PHASE_DIR/$FEATURE-phase-$PHASE_ID-tasks.json"
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"

if [ "$PHASE_SPLIT_MODE" = true ]; then
  PHASE_DIR_PATH="$AIMI_ROOT/.aimi/tasks/$FEATURE/$PHASE_DIR"
  # Hoisted once, above the loop -- never re-called per split_file.
  PHASE_MEMBERS_JSON=$($AIMI_CLI split-detect --dir "$PHASE_DIR_PATH" | jq -c '.members[]')
  PHASE_GROUP_RAW=""
  while IFS= read -r split_file; do
    [ -n "$split_file" ] || continue
    GROUP_PROJECT=$(printf '%s\n' "$PHASE_MEMBERS_JSON" | jq -r --arg p "$split_file" 'select(.path == $p) | .project // "."')
    PHASE_GROUP_RAW="${PHASE_GROUP_RAW}${GROUP_PROJECT}"$'\n'
  done <<< "$PHASE_ACTIVE_SPLIT_FILES"
  PHASE_GROUP_PROJECTS=$(printf '%s\n' "$PHASE_GROUP_RAW" | grep -v '^$' | sort -u)
  [ -n "$PHASE_GROUP_PROJECTS" ] || PHASE_GROUP_PROJECTS="."
else
  # project-groups now owns the jq, the sort-unique pipeline and the
  # empty-fallback this branch used to run inline (aimi-cli.sh's
  # cmd_project_groups) -- and, new here, validates every group other than
  # "." before returning it. A refusal (an invalid project value, every
  # offender named on stderr) is a deliberate tightening: this site never
  # validated before.
  PHASE_GROUPS_JSON=$($AIMI_CLI project-groups --tasks-file "$PHASE_MAIN_TASKS") || {
    $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
    exit 1
  }
  PHASE_GROUP_PROJECTS=$(printf '%s' "$PHASE_GROUPS_JSON" | jq -r '.groups[]')
fi
```

An empty result (a phase, or an active split file, whose `userStories` array is empty — legal, see Active Split Files above) falls back to exactly one `.` group, preserving today's single-container behavior rather than creating zero containers.

#### Resolve and Create Each Group's Container

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"; [ -x "$WORKTREE_MGR" ] || { echo "WORKTREE_MGR is stale: $WORKTREE_MGR does not exist — re-run check-version --quiet --fix" >&2; exit 1; }
cd "$AIMI_ROOT"
BASE_BRANCH="[the value Step 0's Parse --base Override echoed, or empty when --base was absent]"

PHASE_GROUP_TOPLEVELS_SEEN=""
PHASE_LAST_GROUP_TOPLEVEL=""
while IFS= read -r GROUP_PROJECT; do
  [ -n "$GROUP_PROJECT" ] || continue
  # This loop is fed by BOTH branches of Derive Participating Project Groups
  # above: for PHASE_SPLIT_MODE=true, $GROUP_PROJECT is a split member's own
  # metadata.splitGroup.project (validated only here, not by project-groups,
  # which that branch never calls); for PHASE_SPLIT_MODE=false it is already
  # project-groups-validated. Validating unconditionally here is therefore
  # still required for the split-mode source and a harmless no-op re-check
  # for the other -- removing it would leave split-mode's own project value
  # unvalidated before it is joined onto GROUP_ROOT below.
  case "$GROUP_PROJECT" in
    .)
      GROUP_KEY="DEFAULT"
      GROUP_ROOT="$AIMI_ROOT"
      ;;
    /*|..|../*|*/..|*/../*)
      echo "Invalid project \"$GROUP_PROJECT\" for phase $PHASE_ID" >&2
      $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
      exit 1
      ;;
    *)
      if ! [[ "$GROUP_PROJECT" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$ ]]; then
        echo "Invalid project \"$GROUP_PROJECT\" for phase $PHASE_ID" >&2
        $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
        exit 1
      fi
      GROUP_KEY="$GROUP_PROJECT"
      GROUP_ROOT="$AIMI_ROOT/$GROUP_PROJECT"
      ;;
  esac

  GROUP_TOPLEVEL=$(git -C "$GROUP_ROOT" rev-parse --show-toplevel 2>/dev/null) || GROUP_TOPLEVEL=""
  if [ -z "$GROUP_TOPLEVEL" ]; then
    echo "Not a git repository: $GROUP_ROOT (project \"$GROUP_PROJECT\" for phase $PHASE_ID)" >&2
    $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
    exit 1
  fi
  PHASE_LAST_GROUP_TOPLEVEL="$GROUP_TOPLEVEL"

  # Two group_keys sharing one toplevel collapse into one container — the
  # (repo toplevel, PHASE_BRANCH) collision rule Step 0.9 Pass 1 applies
  # (Step 0.9 “Pass 1 — Derive and Validate Per-Repo Roots and Branches”) — never a duplicate creation attempt.
  case "$PHASE_GROUP_TOPLEVELS_SEEN" in
    *"${GROUP_TOPLEVEL}"$'\n'*)
      project_roots["$GROUP_KEY"]="$GROUP_TOPLEVEL"
      PHASE_CONTAINER_PATHS["$GROUP_KEY"]="$GROUP_TOPLEVEL/.worktrees/$PHASE_BRANCH"
      continue
      ;;
  esac
  PHASE_GROUP_TOPLEVELS_SEEN="${PHASE_GROUP_TOPLEVELS_SEEN}${GROUP_TOPLEVEL}"$'\n'

  GROUP_DEFAULT=$($AIMI_CLI detect-default-branch --project "$GROUP_ROOT") || GROUP_DEFAULT=""
  if [ -z "$GROUP_DEFAULT" ]; then
    echo "Could not detect a default branch for $GROUP_ROOT (project \"$GROUP_PROJECT\" for phase $PHASE_ID)" >&2
    $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
    exit 1
  fi

  if [ -n "$BASE_BRANCH" ]; then
    GROUP_BASE_JSON=$($AIMI_CLI resolve-base-branch "$PHASE_BRANCH" --project "$GROUP_ROOT" --default-branch "$GROUP_DEFAULT" --base "$BASE_BRANCH")
  else
    GROUP_BASE_JSON=$($AIMI_CLI resolve-base-branch "$PHASE_BRANCH" --project "$GROUP_ROOT" --default-branch "$GROUP_DEFAULT")
  fi
  CONTAINER_BASE=$(printf '%s' "$GROUP_BASE_JSON" | jq -r '.base')
  CONTAINER_BASE_REASON=$(printf '%s' "$GROUP_BASE_JSON" | jq -r '.reason')

  EXEC_ROOT="$GROUP_TOPLEVEL"
  EXEC_BRANCH="$PHASE_BRANCH"
  cd "$EXEC_ROOT"
  $WORKTREE_MGR create "$EXEC_BRANCH" --from "$CONTAINER_BASE"

  project_roots["$GROUP_KEY"]="$GROUP_TOPLEVEL"
  PHASE_CONTAINER_PATHS["$GROUP_KEY"]="$GROUP_TOPLEVEL/.worktrees/$PHASE_BRANCH"
  echo "Phase container ready in project: $GROUP_KEY (${GROUP_TOPLEVEL}/.worktrees/${PHASE_BRANCH}) — branched from $CONTAINER_BASE ($CONTAINER_BASE_REASON)"
done <<< "$PHASE_GROUP_PROJECTS"
cd "$AIMI_ROOT"
```

Delegates to **Create or Reuse a Container** (`${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md`) exactly as before — `EXEC_ROOT`/`EXEC_BRANCH`/`CONTAINER_BASE` set per group, `$WORKTREE_MGR create` called once per unique toplevel. `CONTAINER_BASE` is resolved per group by `resolve-base-branch` — the same shared primitive `cmd_setup_branch` and Flat Container Mode both use (`_resolve_branch_base` in `aimi-cli.sh`) — called with `--project "$GROUP_ROOT"` so each participating repository's base is decided against **its own** checked-out state, and `--default-branch "$GROUP_DEFAULT"` so the fallback is that group's own freshly-detected default rather than the single main-root `$DEFAULT_BRANCH`. This is what keeps a repository whose checkout carries unmerged work from silently losing that stacking: the resolver returns `stacked-on-current` for it while a sibling repository sitting clean on its own default returns `default-branch`, in the same loop, each correct for itself. `BASE_BRANCH` is threaded through as `--base` when Step 0's `--base` flag or Step 1.6's picker set one, applying that explicit choice uniformly across every participating repository. `CONTAINER_BASE_REASON` is rendered verbatim in the per-group report line above, never paraphrased. A per-group `detect-default-branch` failure is fatal for that group only — the claim is released and the run stops, exactly as Step 0.9 Pass 1 does at its own call site (Step 0.9 “Pass 1 — Derive and Validate Per-Repo Roots and Branches”) — never falling back to another group's already-resolved branch.

**With exactly one group** — today's single-repo, non-split, every-story-project-less case — also alias the scalar for byte-identical backward compatibility with **Phase-Mode Paired Split** and any other unmigrated scalar consumer:

```bash
PHASE_GROUP_COUNT=$(printf '%s\n' "$PHASE_GROUP_PROJECTS" | grep -c .)
if [ "$PHASE_GROUP_COUNT" -eq 1 ]; then
  PHASE_CONTAINER_PATH="$PHASE_LAST_GROUP_TOPLEVEL/.worktrees/$PHASE_BRANCH"
fi
```

With `PHASE_SPLIT_MODE=false` and every story project-less — today's byte-for-byte-unchanged case — `PHASE_GROUP_PROJECTS` is exactly `.`, the loop runs once with `GROUP_KEY="DEFAULT"` and `GROUP_ROOT="$AIMI_ROOT"`, `GROUP_TOPLEVEL` resolves to `$AIMI_ROOT` itself (the same repository the guard above already confirmed), and `PHASE_CONTAINER_PATH` ends up `"$AIMI_ROOT/.worktrees/$PHASE_BRANCH"` — identical to today's unconditional assignment. When more than one group resolves, the scalar is deliberately left unset: **Phase-Mode Paired Split** resolves each split member's own repository independently, through its own `SPLIT_TOPLEVEL` derivation (outline 07/08, landed), so it needs no `PHASE_CONTAINER_PATHS[group_key]` consumption to work correctly across repositories. Step 4's wave loop, below, reads the per-group `PHASE_CONTAINER_PATHS[group_key]` map directly rather than this scalar (see its `EXEC_ROOT`/`EXEC_BRANCH` derivation and the Execution Context table's Phase row in `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md`), so a genuinely multi-repo, non-split phase — one tasks file whose own stories carry more than one distinct `project` — routes each group to its own container correctly; the scalar being left unset in that case is harmless, since nothing downstream still reads it.
