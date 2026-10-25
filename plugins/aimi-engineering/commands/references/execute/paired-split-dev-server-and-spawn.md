# Execute: Phase-Mode Paired Split: Dev Servers and Spawn

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

### Split Container Dev Server Bootstrap

Independently for each active split — never against `PHASE_CONTAINER_PATH` itself, since no story ever lands directly on the un-merged phase branch — gate on that split's **own** tasks file having at least one visual story, mirroring Phase Container Dev Server Bootstrap's gate above exactly, scoped one level deeper. Each member computes its own gate; no member's count ever gates another's:

This block **computes** the gates; it starts no server. It re-assigns `SPLIT_PLAN` from **Derive and Validate Split Branch Names**' own printed stdout (pasted back verbatim, same isolated-shell rule as above) and emits one plan line per active member — `<SPLIT_TOPLEVEL>\t<SPLIT_BRANCH>\t<true|false>` — because the delegation that consumes the gate happens after the loop, and a bare `HAS_VISUAL_STORY` (or `SPLIT_TOPLEVEL`) would by then hold only the *last* member's value:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
SPLIT_PLAN=$(cat <<'SPLIT_PLAN_EOF'
[paste Derive and Validate Split Branch Names' printed SPLIT_PLAN here, verbatim — one JSON record per line]
SPLIT_PLAN_EOF
)
SPLIT_SERVER_PLAN=""
while IFS= read -r member; do
  [ -n "$member" ] || continue
  split_file=$(printf '%s' "$member" | jq -r '.file')
  SPLIT_TOPLEVEL=$(printf '%s' "$member" | jq -r '.toplevel')
  SPLIT_BRANCH=$(printf '%s' "$member" | jq -r '.branch')
  # A missing or unreadable split file degrades to zero visual stories --
  # mirroring the old `.userStories[]?` tolerance for a missing userStories
  # key, which this verb raises for instead of swallowing (every other
  # verification-report call site wants that raise; here the `2>/dev/null`
  # plus the `${:-0}` fallback below swallow it, same as they already
  # swallowed a genuinely malformed split file).
  SPLIT_VISUAL_STORIES=$($AIMI_CLI verification-report --tasks-file "$split_file" 2>/dev/null | jq '.visual | length' 2>/dev/null)
  if [ "${SPLIT_VISUAL_STORIES:-0}" -gt 0 ]; then
    HAS_VISUAL_STORY=true
  else
    HAS_VISUAL_STORY=false
  fi
  SPLIT_SERVER_PLAN="${SPLIT_SERVER_PLAN}${SPLIT_TOPLEVEL}"$'\t'"${SPLIT_BRANCH}"$'\t'"${HAS_VISUAL_STORY}"$'\n'
done <<< "$SPLIT_PLAN"
```

Then iterate `$SPLIT_SERVER_PLAN` — one delegation per line, never one delegation reading a leftover scalar:

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"; [ -x "$WORKTREE_MGR" ] || { echo "WORKTREE_MGR is stale: $WORKTREE_MGR does not exist — re-run check-version --quiet --fix" >&2; exit 1; }
while IFS=$'\t' read -r EXEC_ROOT EXEC_BRANCH GROUP_HAS_VISUAL; do
  [ -n "$EXEC_ROOT" ] || continue
  [ "$GROUP_HAS_VISUAL" = "true" ] || continue
  cd "$EXEC_ROOT"
  $WORKTREE_MGR install-deps "$EXEC_BRANCH"
  $WORKTREE_MGR serve start "$EXEC_BRANCH" >/dev/null
done <<< "$SPLIT_SERVER_PLAN"
```

Each delegation to **Bootstrap a Container Dev Server** reads `EXEC_ROOT` from that line's first field (that member's own `SPLIT_TOPLEVEL` — `$PHASE_CONTAINER_PATH` in today's single-repo case, a sibling repository's own toplevel in the multi-repo case, and the same CWD Create Split Worktrees above already used to create that member's own worktree), `EXEC_BRANCH` from its second field, and `HAS_VISUAL_STORY` from its third. Read `HAS_VISUAL_STORY` (and `EXEC_ROOT`) only from the plan line being processed; their value after the loop above belongs to whichever member happened to be last and is meaningless for every other member. Getting this wrong fails in both directions: a pure-API split inherits a visual sibling's `true` and gets a server it must never get, or a visual split inherits an API sibling's `false`, gets no server, and cannot run the visual verification its stories require.

A split with no visual story (e.g. a pure-API service) never gets nor blocks on a server — its gate simply fails, exactly like the single-file bootstrap above. Every port is discarded here too — re-resolved fresh via `serve url` at the point each split sub-orchestrator's own Step 3.3 / Step 4 call sites need it. A split sub-orchestrator's spawn prompt pre-sets `PHASE_MODE=true`, `PHASE_BRANCH=[its own split branch]`, and `PHASE_CONTAINER_PATH=[its own split worktree path]` (see Spawn Split Sub-Orchestrators below), so its own copies of Open Visual Follow Session and Step 4's post-merge visual verification apply unmodified — no split-specific code path is needed at either call site. Two members never collide on a `dev-server.json` entry either: `serve start` keys state by the container's absolute resolved path, which is unique per split branch.

**Documented limitation — no proxy between split servers:** when a story's page depends on an API served by a sibling split's container, its visual verification runs only against its own split's server; there is no proxy between them, for any N. A broken API call or failed visual check caused solely by this is expected, not a bug — it must never block the wave and never trigger a retry.

### Spawn Split Sub-Orchestrators

Report — one line per active split file, never a fixed two-slot Frontend/Backend list:

```
Phase [PHASE_ID] split detected ([PHASE_ACTIVE_COUNT] members):
  [1/PHASE_ACTIVE_COUNT] [split_file] → project: [SPLIT_PROJECT] (branch: [SPLIT_BRANCH], repo: [SPLIT_TOPLEVEL])
  [2/PHASE_ACTIVE_COUNT] [split_file] → project: [SPLIT_PROJECT] (branch: [SPLIT_BRANCH], repo: [SPLIT_TOPLEVEL])
  ...

Spawning parallel execution flows...
```

Each line's `project`/`branch`/`repo` are read straight from that member's own `SPLIT_PLAN` record (fields `project`, `branch`, `toplevel`) — never re-derived. With exactly one participating repository (today's unchanged case), every `repo` value is the same `$PHASE_CONTAINER_PATH`, and the report reads exactly as before except for the added `repo:` field.

In a **single tool-call turn**, emit one foreground Task per active split file — `PHASE_ACTIVE_COUNT` Tasks in total (two for a legacy pair, three for a three-way project split, N for N). Never one turn per member; that would serialize them. Each Task runs execute.md's **Steps 2–5 only** — never Step 1's Phase Mode Detection and never Step 1.7's Phase Claim, both of which are already resolved by this parent session; a sub-orchestrator that re-derived or re-claimed the phase itself would either double-claim it or (since it has a different session identity than the parent) fail the claim outright:

```
For each active split file (loop over PHASE_ACTIVE_SPLIT_FILES, all Task( calls in one turn):

Task(
    subagent_type: "general-purpose",
    model: <AGENT_MODELS.executor when not "inherit">,
    description: "Execute split for phase [PHASE_ID]: [split_file basename]",
    prompt: [execute.md Steps 2–5, with the following pre-set — do not re-derive:
        - PHASE_MODE = true
        - PHASE_BRANCH = [that member's SPLIT_PLAN record: .branch]
        - PHASE_CONTAINER_PATH = [that member's SPLIT_PLAN record: .worktree — that member's
          own SPLIT_WORKTREE_PATH, landing inside that member's own repository when it
          differs from the phase's own]
        - PHASE_TASKS_PATH = [that split_file]   (Step 3.2 reads maxConcurrency from this)
        - $AIMI_CLI init-session --file [that split_file]
        - Skip Step 2's Main Repo Branch Setup (PHASE_MODE=true skips it exactly as
          the single-file case already does) and skip Step 1.7 entirely
        - Run Step 3 onward (reset-orphaned, validate-stories, wave loop, Post-Loop
          Cleanup) using the container-execution.md § Phase Mode: Worktree Naming
          and CWD Execution Context contract exactly as written, with the pre-set
          PHASE_BRANCH/PHASE_CONTAINER_PATH above standing in for the outer phase's
          own values — so this sub-orchestrator's own story worktrees are named
          "[SPLIT_BRANCH]-[story.id]", created --from [SPLIT_BRANCH], and merged
          via merge-all --into [SPLIT_BRANCH] with CWD inside [SPLIT_WORKTREE_PATH]
        - Skip this file's own Phase Completion section and Step 5 entirely — the
          parent aggregates completion after every Task returns (see below)
        - PROJECT_GUIDELINES = PROJECT_GUIDELINES
    ]
)
```

Each sub-orchestrator's individual story-level merges therefore land on its **own** split branch — never `$DEFAULT_BRANCH`, never `AIMI_ROOT`, and never any sibling split's worktree or branch. This reuses the existing phase-mode Step 4 wave-loop structure one level deeper, with the split worktree standing in for the outer `PHASE_CONTAINER_PATH` and the split branch standing in for the outer `PHASE_BRANCH`.

**Every Step 3/Step 4 call this sub-orchestrator makes carries its own `--tasks-file [that split_file]` explicitly** — `count-pending`, `list-ready`, `status`, `mark-in-progress`, `mark-failed`, `cascade-skip`, `mark-complete`, `reset-orphaned`, `validate-stories`, and each spawned story executor's own `get-story-context` — resolved from the pre-set `PHASE_TASKS_PATH` above via the same `PHASE_MODE`-conditioned formula Step 3/Step 4 use everywhere else. `$AIMI_CLI init-session --file [that split_file]` still writes the shared current-tasks pointer (see Point the session at this phase's own tasks file for why that write is kept), and `PHASE_ACTIVE_COUNT` sub-orchestrators spawned in the same turn each overwrite it with their own path — but nothing on this sub-orchestrator's own read/mark path reads that pointer back, so the concurrent overwrite is cosmetic, not a race.

After every Task returns, collect each one's completed-story count and failure list.

#### Nested Concurrency

Each split's own `metadata.maxConcurrency` governs only its own sub-orchestrator's wave loop. **No split's limit ever governs any other split's worktree creation or wave loop, for any N** — and none of them is governed by the phase's `roadmap.json` or by any single phase-level tasks file (there is none, in split mode). This falls out of the existing worktree-budget pre-bash-dispatcher hook with **no code change**: `_select_governing_tasks_file` (`hooks/pre-bash-dispatcher.py`) picks the candidate tasks file among every `.aimi/tasks/**/*-tasks.json` whose `metadata.branchName` exactly matches the git branch checked out at the `git worktree add` command's CWD. A story worktree created inside a given sub-orchestrator's wave loop runs with CWD inside that member's own split worktree (branch = that member's own split branch); `plan.md`'s Phase 4 metadata patch writes each split file's `metadata.branchName` as exactly that same value (see Phase 3e/Phase 4's `--phase-aware` composition), so the hook's branch-match resolves to that member's own file uniquely — every sibling's `metadata.branchName` differs (the branch names are collision-checked in Derive and Validate Split Branch Names above), so none of them ever matches.

This scoping is per-repository, not merely per-branch: `_select_governing_tasks_file`'s branch-match resolves against whichever repository the `git worktree add` command's own CWD belongs to (that member's own `SPLIT_TOPLEVEL`), so N members split across N different repositories each get independent, unshared worktree-budget accounting — none of them summed or governed across repositories — exactly as each split's own `metadata.maxConcurrency` already governs only its own sub-orchestrator's wave loop.
