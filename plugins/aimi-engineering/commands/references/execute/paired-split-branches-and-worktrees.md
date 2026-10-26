# Execute: Phase-Mode Paired Split: Branches and Worktrees

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

## Phase-Mode Paired Split

**Skip this entire section if `PHASE_SPLIT_MODE` is false** — proceed straight to Step 2 (the unchanged, single-file phase-mode flow described everywhere above). The rest of this section assumes `PHASE_SPLIT_MODE=true`: this phase's own directory holds a split of **N ≥ 2** sibling tasks files (`$PHASE_SPLIT_FILES`, with `$PHASE_ACTIVE_SPLIT_FILES` its still-has-work subset — both resolved by **Detect a Full-Stack Split Inside This Phase** above), and this section composes that split with the phase container `Step 1.7` already claimed and created — per the binding brainstorm decision that full-stack split and phase mode nest rather than being mutually exclusive.

The section heading and its subsection names keep the word "Paired" for stability — they are cross-referenced by name from **Detect a Full-Stack Split Inside This Phase**, from Phase Completion, and from `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md`'s `EXEC_ROOT`/`EXEC_BRANCH` table — but nothing below is limited to two members. A legacy frontend/backend pair is simply the N = 2 case of every loop here.

**When `PHASE_ACTIVE_COUNT` is `0`** (every member already completed — e.g. a resume after a merge conflict), skip every subsection below and go straight to **Continue to Phase Completion** at the end of this section: there is nothing left to branch, serve, spawn, merge, or clean up, and Phase Completion is what re-runs the pending-count and creates-verification checks.

Every Bash call in this section passes each active member's own resolved root or toplevel explicitly (see Derive and Validate Split Branch Names below), mirroring the rest of phase mode's Path and State Notes discipline — never a bare relative path, never an assumed-persisted CWD. `AIMI_ROOT` is **not** guaranteed to be a git repository here: whether a member's `metadata.splitGroup.project` names a monorepo subdirectory of one shared repository, or a separate sibling repository of its own, is discriminated by AIMI_ROOT_IS_GIT_REPO — re-derived per block using the canonical form in **AIMI_ROOT_IS_GIT_REPO Branching Rule** (Multi-Repo Handling), never assumed. When it is **true** (today's only previously-supported combination), every split worktree below nests under `$PHASE_CONTAINER_PATH`, and `SPLIT_PROJECT` is a monorepo subdirectory used to name and label it. When it is **false**, `SPLIT_PROJECT` instead names a separate sibling repository under `$AIMI_ROOT`, and that member's split worktree nests under its own resolved toplevel instead — never under a `$PHASE_CONTAINER_PATH` that does not exist in that layout.

### Derive and Validate Split Branch Names

One branch per **active** split file, derived from that file's own project (or, for a legacy pair member, from its own basename) and qualified by `$PHASE_BRANCH`. Iterate `$PHASE_ACTIVE_SPLIT_FILES` in order, with `$split_file` as the loop variable:

```bash
AIMI_ROOT="$PWD"
while [ "$AIMI_ROOT" != "/" ] && [ ! -d "$AIMI_ROOT/.aimi" ]; do AIMI_ROOT=$(dirname "$AIMI_ROOT"); done
[ -d "$AIMI_ROOT/.aimi" ] || AIMI_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
if git -C "$AIMI_ROOT" rev-parse --git-dir >/dev/null 2>&1; then AIMI_ROOT_IS_GIT_REPO=true; else AIMI_ROOT_IS_GIT_REPO=false; fi

AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
PHASE_DIR_PATH="$AIMI_ROOT/.aimi/tasks/$FEATURE/$PHASE_DIR"
# Hoisted once, above the loop -- never re-called per split_file.
PHASE_MEMBERS_JSON=$($AIMI_CLI split-detect --dir "$PHASE_DIR_PATH" | jq -c '.members[]')

SPLIT_BRANCHES=""
SPLIT_PLAN=""
SPLIT_KEYS=""
while IFS= read -r split_file; do
  [ -n "$split_file" ] || continue
  SPLIT_PROJECT=$(printf '%s\n' "$PHASE_MEMBERS_JSON" | jq -r --arg p "$split_file" 'select(.path == $p) | .project // ""')
  case "$SPLIT_PROJECT" in
    ""|null)
      SPLIT_SLUG=$(basename "$split_file" -tasks.json)
      SPLIT_SLUG=${SPLIT_SLUG#"$FEATURE-phase-$PHASE_ID-"}
      SPLIT_PROJECT="."
      ;;
    .)
      SPLIT_SLUG="root"
      ;;
    /*|..|../*|*/..|*/../*)
      echo "Invalid splitGroup.project in $split_file: $SPLIT_PROJECT" >&2
      exit 1
      ;;
    *)
      if ! [[ "$SPLIT_PROJECT" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$ ]]; then
        echo "Invalid splitGroup.project in $split_file: $SPLIT_PROJECT" >&2
        exit 1
      fi
      SPLIT_SLUG=$(printf '%s' "$SPLIT_PROJECT" | tr -c 'A-Za-z0-9_-' '-' | tr -s '-' | sed 's/^-//; s/-$//')
      ;;
  esac
  SPLIT_BRANCH="${PHASE_BRANCH}-${SPLIT_SLUG}"
  if ! [[ "$SPLIT_BRANCH" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Invalid split branch derived from $split_file: $SPLIT_BRANCH" >&2
    exit 1
  fi

  if [ "$AIMI_ROOT_IS_GIT_REPO" = true ]; then
    if [ "$SPLIT_PROJECT" = "." ]; then
      SPLIT_ROOT="$PHASE_CONTAINER_PATH"
    else
      SPLIT_ROOT="$PHASE_CONTAINER_PATH/$SPLIT_PROJECT"
    fi
  else
    if [ "$SPLIT_PROJECT" = "." ]; then
      SPLIT_ROOT="$AIMI_ROOT"
    else
      SPLIT_ROOT="$AIMI_ROOT/$SPLIT_PROJECT"
    fi
  fi

  SPLIT_TOPLEVEL=$(git -C "$SPLIT_ROOT" rev-parse --show-toplevel 2>/dev/null) || SPLIT_TOPLEVEL=""
  if [ -z "$SPLIT_TOPLEVEL" ]; then
    echo "Not a git repository: $SPLIT_ROOT (splitGroup.project \"$SPLIT_PROJECT\" in $split_file)" >&2
    exit 1
  fi
  SPLIT_WORKTREE_PATH="$SPLIT_TOPLEVEL/.worktrees/$SPLIT_BRANCH"

  SPLIT_BRANCHES="${SPLIT_BRANCHES}${SPLIT_BRANCH}"$'\n'
  SPLIT_PLAN="${SPLIT_PLAN}$(jq -nc \
    --arg file "$split_file" --arg project "$SPLIT_PROJECT" --arg root "$SPLIT_ROOT" \
    --arg toplevel "$SPLIT_TOPLEVEL" --arg branch "$SPLIT_BRANCH" --arg worktree "$SPLIT_WORKTREE_PATH" \
    '{file: $file, project: $project, root: $root, toplevel: $toplevel, branch: $branch, worktree: $worktree}')"$'\n'
  SPLIT_KEYS="${SPLIT_KEYS}${SPLIT_TOPLEVEL}"$'\t'"${SPLIT_BRANCH}"$'\n'
done <<< "$PHASE_ACTIVE_SPLIT_FILES"

SPLIT_KEY_TOTAL=$(printf '%s' "$SPLIT_KEYS" | grep -c .)
SPLIT_KEY_UNIQUE=$(printf '%s' "$SPLIT_KEYS" | sort -u | grep -c .)
if [ "$SPLIT_KEY_TOTAL" -ne "$SPLIT_KEY_UNIQUE" ]; then
  echo "Two split members contend for the same branch inside one repository:" >&2
  printf '%s' "$SPLIT_KEYS" | sort | uniq -d >&2
  exit 1
fi

printf '%s' "$SPLIT_PLAN"
```

Every derived name is validated against `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$` — the same regex Step 1.7 already validated `PHASE_BRANCH` against — **before `SPLIT_ROOT`/`SPLIT_TOPLEVEL` are resolved and before any worktree is created**. The whole set is then checked for collisions keyed on `(SPLIT_TOPLEVEL, SPLIT_BRANCH)`, mirroring Step 0.9 Pass 1's `SPLIT_KEYS` check (Step 0.9 “Pass 1 — Derive and Validate Per-Repo Roots and Branches”) rather than the branch name alone: two members resolving to different repository toplevels may legitimately share a branch name, but two resolving to the same toplevel (two monorepo subdirectories of one repository, or two `SPLIT_PROJECT` values normalizing to the same sibling repo) must not, since they would otherwise both create `.worktrees/<same-branch>` and silently interleave commits. On any failure — an invalid project, an invalid branch, a collision, or a `SPLIT_ROOT` that resolves to no git repository at all — release the claim (see Release the Claim on Abort), report the offending file, and STOP — create no worktree.

`SPLIT_PROJECT` itself is rejected on traversal shapes and on any character outside `^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$` — the same two guards, in the same order, that Step 0.9's flat per-repo loop applies to the same field, so the two sides stay diffable. The reason is **not** branch safety: `slugify` above maps every character outside `[A-Za-z0-9_-]` to `-`, so the derived branch already satisfies its own regex no matter what `SPLIT_PROJECT` holds. The reason is that `SPLIT_PROJECT` is echoed **verbatim** — never through the slug — into the Aggregated Completion Report's `Project:` line and into each spawned Task's `description`, so an unvalidated value reaches both the human reader and a sub-agent prompt unfiltered. `SPLIT_PROJECT` is now also joined onto a filesystem path — `$PHASE_CONTAINER_PATH/$SPLIT_PROJECT` or `$AIMI_ROOT/$SPLIT_PROJECT` above, depending on `AIMI_ROOT_IS_GIT_REPO` — so this guard is no longer only about what the value can *say*: exactly like Step 0.9 Pass 1's own explanation of the same two-guard validation (Step 0.9 “Pass 1 — Derive and Validate Per-Repo Roots and Branches”), it is also about where it can *point*.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
```

For a legacy pair the two basenames yield the slugs `frontend` and `backend`, so the derived branches are exactly `${PHASE_BRANCH}-frontend` and `${PHASE_BRANCH}-backend` — unchanged from before. For a project split, `apps/web` yields `${PHASE_BRANCH}-apps-web` and the root group (`project` = `.`) yields `${PHASE_BRANCH}-root`.

Carry each active member's resolved `(split_file, SPLIT_PROJECT, SPLIT_ROOT, SPLIT_TOPLEVEL, SPLIT_BRANCH, SPLIT_WORKTREE_PATH)` tuple forward — the worktree, dev-server, spawn, merge, and cleanup passes below all iterate that same ordered list; outline 08 migrated the merge and cleanup passes off the flat `SPLIT_BRANCHES` scalar and onto this same tuple. `SPLIT_PLAN` is that list materialized for the shell as **one JSON object per line** (fields `file`, `project`, `root`, `toplevel`, `branch`, `worktree`), never tab-delimited — a tasks-file path may contain spaces, exactly why Step 0.9's own `SPLIT_PLAN` uses this shape (Step 0.9 “Pass 1 — Derive and Validate Per-Repo Roots and Branches”). Because each Bash tool call is an isolated shell, every later pass in this section re-assigns `SPLIT_PLAN` from this block's own printed stdout, pasted back verbatim, rather than assuming it persists. Every pass below reads a member's full tuple from `SPLIT_PLAN`; `SPLIT_BRANCHES` itself is no longer read downstream of this block. **No per-member value is ever left in a bare scalar for a later step to read** — a scalar assigned inside a loop holds only the last member's value by the time the loop ends, which silently applies one member's decision to every other member.

### Create Split Worktrees

One worktree per active split file, each created at **that member's own** resolved toplevel and branched `--from "$PHASE_BRANCH"` — that member's own repository's own already-established phase branch (**Create Phase Containers Per Project Group** above creates one `$PHASE_BRANCH` ref per participating repository before this section ever runs). Re-assign `SPLIT_PLAN` from **Derive and Validate Split Branch Names**' own printed stdout, pasted back verbatim — each Bash tool call is an isolated shell (Step 0):

```bash
SPLIT_PLAN=$(cat <<'SPLIT_PLAN_EOF'
[paste Derive and Validate Split Branch Names' printed SPLIT_PLAN here, verbatim — one JSON record per line]
SPLIT_PLAN_EOF
)
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"; [ -x "$WORKTREE_MGR" ] || { echo "WORKTREE_MGR is stale: $WORKTREE_MGR does not exist — re-run check-version --quiet --fix" >&2; exit 1; }
while IFS= read -r member; do
  [ -n "$member" ] || continue
  SPLIT_TOPLEVEL=$(printf '%s' "$member" | jq -r '.toplevel')
  SPLIT_BRANCH=$(printf '%s' "$member" | jq -r '.branch')
  cd "$SPLIT_TOPLEVEL"
  $WORKTREE_MGR create "$SPLIT_BRANCH" --from "$PHASE_BRANCH"
done <<< "$SPLIT_PLAN"
```

CWD is **that member's own** `SPLIT_TOPLEVEL` — `$PHASE_CONTAINER_PATH` itself in today's single-repo case, a sibling repository's own toplevel in the multi-repo case — never a bare relative path, never `AIMI_ROOT`, and never another member's toplevel. Mirroring the CWD rule `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Phase Mode: Worktree Naming and CWD already establishes for individual story worktrees, every split worktree nests at `$SPLIT_TOPLEVEL/.worktrees/<its own split branch>` — inside that member's own repository's worktree tree — and branched from `$PHASE_BRANCH`, not `$DEFAULT_BRANCH`. Each member's path is exactly the `worktree` field **Derive and Validate Split Branch Names** already resolved and printed; it is never recomputed here, since `worktree-manager.sh` resolves its worktree-name argument against the repository's own toplevel — the same "Where the worktree actually lands" rule Step 0.9 Pass 1 documents at Step 0.9 “Pass 1 — Derive and Validate Per-Repo Roots and Branches” — and a second, independent computation could drift from it.

With exactly one participating repository — today's single-repo, non-split-across-repos case, the only one previously supported — every member's `SPLIT_TOPLEVEL` is `$PHASE_CONTAINER_PATH` itself (a linked worktree's own `git rev-parse --show-toplevel` returns its own path, container-execution.md:23), so every `$WORKTREE_MGR create` call above runs with the same CWD today's single `cd "$PHASE_CONTAINER_PATH"` did, byte-identical.
