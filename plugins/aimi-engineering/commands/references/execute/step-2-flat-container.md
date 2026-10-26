# Execute: Step 2: Flat Container Mode

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

## Step 2: Branch Setup

Get the branch name from the init-session output (already validated by CLI).

### Flat Container Mode: Create or Reuse the Feature Container

**Skip this subsection entirely unless `CONTAINER_MODE` is true** (see Execution Mode Detection in Step 1) **and `AIMI_ROOT_IS_GIT_REPO` is true** — the multi-repo case is handled per project group inside Per-Project Branch Setup below, not here. When skipped, `### Main Repo Branch Setup` below runs exactly as it does today.

#### Create or Reuse the Container

Read and validate `branchName` — defense in depth, mirroring `PHASE_BRANCH`'s validate-once-quote-everywhere discipline (`cmd_init_session` already rejected an invalid `branchName` in Step 1, before this subsection ever runs):

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
BRANCH_NAME=$($AIMI_CLI metadata | jq -r '.branchName')
if ! [[ "$BRANCH_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
  echo "Invalid branchName: $BRANCH_NAME" >&2
  exit 1
fi
```

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
BASE_BRANCH="[the value Step 0's Parse --base Override echoed, or empty when --base was absent]"
if [ -n "$BASE_BRANCH" ]; then
  BASE_JSON=$($AIMI_CLI resolve-base-branch "$BRANCH_NAME" --default-branch "$DEFAULT_BRANCH" --base "$BASE_BRANCH")
else
  BASE_JSON=$($AIMI_CLI resolve-base-branch "$BRANCH_NAME" --default-branch "$DEFAULT_BRANCH")
fi
CONTAINER_BASE=$(echo "$BASE_JSON" | jq -r '.base')
CONTAINER_BASE_REASON=$(echo "$BASE_JSON" | jq -r '.reason')
```

Delegate to **Create or Reuse a Container** with `EXEC_ROOT="$AIMI_ROOT"`, `EXEC_BRANCH="$BRANCH_NAME"`, and `CONTAINER_BASE` as just resolved by `resolve-base-branch` — the same shared primitive `cmd_setup_branch` uses (`_resolve_branch_base` in `aimi-cli.sh`), called here with `--project` omitted because this path already runs with CWD at `AIMI_ROOT`, a git repository (Flat Container Mode's own skip condition above guarantees this). `BASE_BRANCH` is passed through as `--base` when Step 1.6 set one, so an explicit user choice is honored verbatim; when unset, the resolver applies its own stacked-on-current/default-branch heuristic — the same rule Step 1.6's own picker would have used for this repo. The path is deterministic given `AIMI_ROOT` and `[branchName]`:

```bash
FEATURE_CONTAINER_PATH="$AIMI_ROOT/.worktrees/$BRANCH_NAME"
CONTAINER_PATHS["DEFAULT"]="$FEATURE_CONTAINER_PATH"
CONTAINER_BASE_MAP["DEFAULT"]="$CONTAINER_BASE"
CONTAINER_BASE_REASON_MAP["DEFAULT"]="$CONTAINER_BASE_REASON"
```

`CONTAINER_PATHS["DEFAULT"]` aliases the single-repo container into the same map Per-Project Branch Setup populates below, under the `"DEFAULT"` key Multi-Repo Handling's grouping pattern already uses for stories without a `project` field — so Step 4's wave loop can look up `CONTAINER_PATHS[group_key]` uniformly regardless of single-repo or multi-repo layout. `CONTAINER_BASE_MAP["DEFAULT"]`/`CONTAINER_BASE_REASON_MAP["DEFAULT"]` mirror it for the resolved base and its reason, keyed identically, so anything downstream that needs to report or reuse the base a project group's container was actually cut from can look it up the same way.

Report — on the create call above returning zero, whether it created `$FEATURE_CONTAINER_PATH` fresh or reused it silently (see Create or Reuse a Container's reuse contract):
```
Container for [branchName] ready — branched from [CONTAINER_BASE] ([CONTAINER_BASE_REASON])
```

Because this subsection's own `$WORKTREE_MGR create` call is the branch-creating operation for this run, `### Main Repo Branch Setup` below is skipped whenever this subsection applies — see its skip condition.

#### Plan Base Freshness (advisory)

`metadata.baseRef` is the 40-character SHA `/aimi:plan` recorded for the commit this file's stories were planned against (see `commands/plan.md`'s metadata contract, which writes it per file and states plainly that comparing it against the branch an executor actually starts from belongs to whoever consumes it). Nothing ever has. This is that consumer.

The question it answers is whether the tree moved between planning and execution, and the answer is an **advisory** in every case. A plan written against an older commit is ordinary — the branch it targeted simply advanced — so the useful thing is to say it once, here, where the reader can weigh it, and never to refuse a run over it.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
PLAN_BASE_REF=$($AIMI_CLI metadata --tasks-file "$AIMI_ROOT/$TASKS_PATH" 2>/dev/null | jq -r '.baseRef // empty')
if [ -n "$PLAN_BASE_REF" ]; then
  # git merge-base --is-ancestor <metadata.baseRef> <container base>: exit 0
  # means the recorded plan base is reachable from the base this container was
  # actually cut from — the plan is behind, but on the same line of history.
  if git -C "$AIMI_ROOT" merge-base --is-ancestor "$PLAN_BASE_REF" "$CONTAINER_BASE" 2>/dev/null; then
    echo "Plan base $PLAN_BASE_REF is reachable from $CONTAINER_BASE."
  else
    echo "advisory: the plan was written against $PLAN_BASE_REF, which is NOT reachable from this container's base $CONTAINER_BASE — plan and container stand on different trees. Stories may cite code that is not here, or miss code that is. Not a blocker."
  fi
fi
```

`$AIMI_CLI metadata --tasks-file` is a verb call rather than a raw open of the tasks file: the flag exists, and the verb returns the whole `metadata` object with `baseRef` among its keys. `// empty` is what keeps an absent key silent — the field is optional and every file planned before it existed has none, so a missing `baseRef` must print nothing at all rather than the word `null`.

A `baseRef` this repository does not have — a plan made in a clone whose commits were never pushed, or a history since rewritten — exits non-zero exactly as a genuine divergence does, and lands in the same advisory line. The conflation is deliberate: to the reader both mean the one thing worth saying, which is that the recorded base is not on the path this run stands on.

**In phase mode** the same check belongs once per participating group, inside **Create Phase Containers Per Project Group** above, with `--tasks-file "$PHASE_TASKS_PATH"` and `git -C "$GROUP_TOPLEVEL"` in place of `$AIMI_ROOT` — so each repository's plan base is compared against the base of the container that repository just got, never against a sibling's.
