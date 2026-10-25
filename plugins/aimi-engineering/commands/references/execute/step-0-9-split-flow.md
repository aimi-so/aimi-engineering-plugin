# Execute: Step 0.9: Split Flow

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

### Per-Repo Branch and Container Setup for the Split

**Each active split file owns exactly one repo, so its worktree/container is rooted at that repo's own resolved path — never at `$AIMI_ROOT`.** In a multi-repo layout `$AIMI_ROOT` is a plain parent folder holding several repos, not a repository itself; rooting the split's worktree there is what produces `fatal: not a git repository` (issue #73).

Four passes follow, each one a real loop over the same ordered member list: derive, create, report, clean up.

**Each Bash tool call is an isolated shell**, so Pass 1 serializes its result into `SPLIT_PLAN` — one JSON object per line — and prints it, and every later pass opens by re-assigning `SPLIT_PLAN` from that printed stdout verbatim. Passes 2–4 must **not** re-run `split-detect` to rebuild the list: by the time Pass 3 runs, every member's stories are `completed`, so the verb's active filter would correctly return nothing and the report and cleanup passes would iterate an empty list.

Each record is **one JSON object per line**, never tab-delimited fields. A tasks-file path may contain spaces — `_find_tasks_files_all` is NUL-delimited specifically so it survives them — and a `read -r file project root branch` split would undo that hardening at the first such path.

#### Pass 1 — Derive and Validate Per-Repo Roots and Branches

Nothing is created in this pass. It reads the verb's active members, validates each one, resolves where that member's worktree will actually land, and emits the plan:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
AIMI_ROOT="$PWD"
while [ "$AIMI_ROOT" != "/" ] && [ ! -d "$AIMI_ROOT/.aimi" ]; do AIMI_ROOT=$(dirname "$AIMI_ROOT"); done
[ -d "$AIMI_ROOT/.aimi" ] || AIMI_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
if git -C "$AIMI_ROOT" rev-parse --git-dir >/dev/null 2>&1; then AIMI_ROOT_IS_GIT_REPO=true; else AIMI_ROOT_IS_GIT_REPO=false; fi

SPLIT_PLAN=""
SPLIT_KEYS=""
while IFS= read -r member; do
  [ -n "$member" ] || continue
  split_file=$(printf '%s' "$member" | jq -r '.path')
  SPLIT_BRANCH=$(printf '%s' "$member" | jq -r '.branchName // ""')
  SPLIT_PROJECT=$(printf '%s' "$member" | jq -r '.project // "."')

  if ! [[ "$SPLIT_BRANCH" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
    echo "Invalid branchName in $split_file: $SPLIT_BRANCH" >&2
    exit 1
  fi

  case "$SPLIT_PROJECT" in
    ""|null|.)
      if [ "$AIMI_ROOT_IS_GIT_REPO" != true ]; then
        echo "Root group (project \".\") in $split_file, but AIMI_ROOT is not a git repository: $AIMI_ROOT" >&2
        echo "This is a multi-repo layout — AIMI_ROOT is a parent folder holding several repos, so the root group has no repository to execute in. Give every story its own project path and re-plan, or run /aimi:execute from inside the repo that owns this work." >&2
        exit 1
      fi
      SPLIT_ROOT="$AIMI_ROOT"
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
      SPLIT_ROOT="$AIMI_ROOT/$SPLIT_PROJECT"
      ;;
  esac

  SPLIT_TOPLEVEL=$(git -C "$SPLIT_ROOT" rev-parse --show-toplevel 2>/dev/null) || SPLIT_TOPLEVEL=""
  if [ -z "$SPLIT_TOPLEVEL" ]; then
    echo "Not a git repository: $SPLIT_ROOT (splitGroup.project \"$SPLIT_PROJECT\" in $split_file)" >&2
    exit 1
  fi

  SPLIT_DEFAULT=$($AIMI_CLI detect-default-branch --project "$SPLIT_ROOT") || SPLIT_DEFAULT=""
  if [ -z "$SPLIT_DEFAULT" ]; then
    echo "Could not detect a default branch for $SPLIT_ROOT (splitGroup.project \"$SPLIT_PROJECT\" in $split_file)" >&2
    exit 1
  fi
  SPLIT_WORKTREE_PATH="$SPLIT_TOPLEVEL/.worktrees/$SPLIT_BRANCH"

  SPLIT_PLAN="${SPLIT_PLAN}$(jq -nc \
    --arg file "$split_file" --arg project "$SPLIT_PROJECT" --arg root "$SPLIT_ROOT" \
    --arg branch "$SPLIT_BRANCH" --arg default "$SPLIT_DEFAULT" --arg worktree "$SPLIT_WORKTREE_PATH" \
    '{file: $file, project: $project, root: $root, branch: $branch, default: $default, worktree: $worktree}')"$'\n'
  SPLIT_KEYS="${SPLIT_KEYS}${SPLIT_TOPLEVEL}"$'\t'"${SPLIT_BRANCH}"$'\n'
done <<< "$($AIMI_CLI split-detect | jq -c '.members[] | select(.active)')"

SPLIT_KEY_TOTAL=$(printf '%s' "$SPLIT_KEYS" | grep -c .)
SPLIT_KEY_UNIQUE=$(printf '%s' "$SPLIT_KEYS" | sort -u | grep -c .)
if [ "$SPLIT_KEY_TOTAL" -ne "$SPLIT_KEY_UNIQUE" ]; then
  echo "Two split members contend for the same branch inside one repository:" >&2
  printf '%s' "$SPLIT_KEYS" | sort | uniq -d >&2
  exit 1
fi

printf '%s' "$SPLIT_PLAN"
```

`branchName` is validated against `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$` — the same regex `init-session` enforces in Step 1 — before it can reach any git command. `splitGroup.project` is rejected first on traversal shapes and then on any character outside `^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$`; that `case` list and that regex are byte-identical to the pair `commands/plan.md` applies to the same field in its Phase 3e staging check, so the two sites stay diffable. Here the guard is not only about what the value can *say* (it is echoed verbatim into the report below and into each spawned Task's `description`) but about where it can *point* — this is the one site that joins it onto a filesystem path.

**Where the worktree actually lands.** `SPLIT_ROOT` is the *project* path; `SPLIT_WORKTREE_PATH` is built from `git -C "$SPLIT_ROOT" rev-parse --show-toplevel`, because `worktree-manager.sh` resolves its worktree-name argument against `$(git rev-parse --show-toplevel)/.worktrees/<name>` — the repository's toplevel, not its own CWD. For three sibling repos the two coincide. For a monorepo subdirectory (`project` = `apps/web`) they do not: the worktree lands at `<repo-toplevel>/.worktrees/<branch>`, so computing `$SPLIT_ROOT/.worktrees/$SPLIT_BRANCH` instead would hand every downstream consumer a path that never exists. That same `rev-parse` call doubles as the "is this a git repository at all" check, so no separate probe is needed.

**The `"."` root group.** `story-merge` now refuses untagged stories, so a `"."` group exists only when an author wrote it explicitly. It is still handled — but only where it can run: when `AIMI_ROOT` is not a git repository there is no repo for it to execute in, so this refuses by name and says which layout it found, rather than letting `detect-default-branch` or `$WORKTREE_MGR create` fail obscurely a pass or two later. `AIMI_ROOT_IS_GIT_REPO` is derived inside this block using the canonical form from **AIMI_ROOT_IS_GIT_REPO Branching Rule** above — never read from a prior block, which is a different shell.

**An undetectable default branch stops the pass.** `detect-default-branch` exits non-zero when it can resolve neither `origin`'s HEAD nor `refs/remotes/origin/HEAD`; an unchecked capture would leave `SPLIT_DEFAULT` empty, and empty reaches `$WORKTREE_MGR create --from ""` in Pass 2 and an empty `git log ""..branch` range in Pass 3. A project whose default branch cannot be detected is not a usable repo — report it and STOP rather than falling back to some other repo's branch, exactly as `commands/plan.md` requires at its own call site of the same verb.

**The collision check** keys on `(repo toplevel, branch)`, not on the branch alone. Two separate repos may legitimately carry the same branch name; two monorepo subdirectories share one toplevel and would contend for the same `.worktrees/<branch>` directory, silently interleaving their commits onto one branch. On collision, report the offending pairs and STOP — nothing has been created yet.

Report, one line per active member:

```
Split task files detected ([activeCount] members):
  [1/activeCount] [file] → project: [project] (branch: [branch], repo: [root])
  [2/activeCount] [file] → project: [project] (branch: [branch], repo: [root])
  ...

Spawning parallel execution flows...
```

`project` / `root` / `default` are exactly the values Step 2's **Per-Project Branch Setup** computes per project group (`detect-default-branch --project [resolved_project_path]`, keyed generically by project path) — this pass reuses that machinery rather than adding a second per-repo worktree/container mechanism. For a legacy pair every `project` is `.`, every `root` is `$AIMI_ROOT`, and every `default` equals the `$DEFAULT_BRANCH` Step 1.5 would detect.

#### Pass 2 — Create Worktrees or Containers

One iteration per plan record. `EXECUTION_MODE` (Step 1's mode detection) is not yet in scope this early, so `metadata.execution` is read directly from the first plan record's file — every member of a group is written by the same `story-merge` run and carries the same value:

```bash
SPLIT_PLAN=$(cat <<'SPLIT_PLAN_EOF'
[paste Pass 1's printed SPLIT_PLAN here, verbatim — one JSON record per line]
SPLIT_PLAN_EOF
)
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"; [ -x "$WORKTREE_MGR" ] || { echo "WORKTREE_MGR is stale: $WORKTREE_MGR does not exist — re-run check-version --quiet --fix" >&2; exit 1; }
BASE_BRANCH="[the value Step 0's Parse --base Override echoed, or empty when --base was absent]"

SPLIT_EXECUTION_MODE=$(jq -r '.metadata.execution // "inline"' \
  "$(printf '%s\n' "$SPLIT_PLAN" | head -1 | jq -r '.file')")
echo "Split execution mode: $SPLIT_EXECUTION_MODE"

while IFS= read -r record; do
  [ -n "$record" ] || continue
  SPLIT_ROOT=$(printf '%s' "$record" | jq -r '.root')
  SPLIT_BRANCH=$(printf '%s' "$record" | jq -r '.branch')
  SPLIT_DEFAULT=$(printf '%s' "$record" | jq -r '.default')
  if [ -n "$BASE_BRANCH" ]; then
    SPLIT_BASE_JSON=$($AIMI_CLI resolve-base-branch "$SPLIT_BRANCH" --project "$SPLIT_ROOT" --default-branch "$SPLIT_DEFAULT" --base "$BASE_BRANCH")
  else
    SPLIT_BASE_JSON=$($AIMI_CLI resolve-base-branch "$SPLIT_BRANCH" --project "$SPLIT_ROOT" --default-branch "$SPLIT_DEFAULT")
  fi
  CONTAINER_BASE=$(printf '%s' "$SPLIT_BASE_JSON" | jq -r '.base')
  SPLIT_BASE_REASON=$(printf '%s' "$SPLIT_BASE_JSON" | jq -r '.reason')
  cd "$SPLIT_ROOT"
  if ! $WORKTREE_MGR create "$SPLIT_BRANCH" --from "$CONTAINER_BASE"; then
    echo "Worktree creation failed for $SPLIT_BRANCH in $SPLIT_ROOT — see the error above." >&2
    exit 1
  fi
  echo "Worktree for $SPLIT_BRANCH ready in $SPLIT_ROOT — branched from $CONTAINER_BASE ($SPLIT_BASE_REASON)"
done <<< "$SPLIT_PLAN"
```

Each iteration's last line reports its own resolved base immediately once `create` above exits zero — fresh-create and reuse alike, since the echo runs unconditionally after that check rather than depending on which internal branch `$WORKTREE_MGR create` took. `$SPLIT_BASE_REASON` is rendered verbatim from `resolve-base-branch`'s own `reason` field, never paraphrased.

**When `SPLIT_EXECUTION_MODE` is `inline` or absent** (the fail-safe default — see `commands/references/execution-mode.md`), that loop is the whole pass: one worktree per active split file, each cut from its own repo's own `resolve-base-branch` resolution — its default branch, unless that repo's own current checkout carries unmerged work worth stacking on, exactly as Step 1.6's picker would decide for a single repo. `BASE_BRANCH` is passed through as `--base` on every iteration when Step 0 parsed one, applying the same explicit choice uniformly across every active repo in the split rather than re-deriving it per member.

**When `SPLIT_EXECUTION_MODE` is `container`,** the loop body is instead one delegation per record to **Create or Reuse a Container** (`${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md`), with `EXEC_ROOT` set to that record's `root`, `EXEC_BRANCH` to its `branch`, and `CONTAINER_BASE` as computed above — giving each member its own independently checkout-conflict-checked container rather than nesting one inside another, mirroring the phase-mode split's Create Split Worktrees. That reference's body is the same `cd "$EXEC_ROOT"` + `$WORKTREE_MGR create "$EXEC_BRANCH" --from "$CONTAINER_BASE"` pair the loop already runs, so the shape above is unchanged; what the delegation adds is the single source of truth for the reuse/idempotency and error contract. Handle its exit code exactly as Step 2's Per-Project Branch Setup does — no pre-flight checkout check is needed, since `$WORKTREE_MGR create` is branch-aware and its stderr already names the worktree holding the branch. Report that stderr verbatim and STOP without attempting remediation.

Either way, every worktree or container lands at that record's `worktree` value — under its **own repo's** `.worktrees/`, which is the path the next section passes to each Task as `WORKTREE_PATH`. For a legacy pair every root is `$AIMI_ROOT` and every worktree lands as a sibling under `$AIMI_ROOT/.worktrees/`, unchanged.

### Parallel Execution for Split Files

In a **single tool-call turn**, emit one foreground Task per plan record — `activeCount` Tasks in total (two for a legacy pair, three for a three-repo project split, N for N). Never one turn per record; that would serialize them. Each Task runs the full execute.md flow (Steps 1–5) scoped to its own file:

```
For each record in SPLIT_PLAN, all Task( calls in one turn:

Task(
    subagent_type: "general-purpose",
    model: <AGENT_MODELS.executor when not "inherit">,
    description: "Execute split tasks: [that record's file basename]",
    prompt: [Full execute.md flow (Steps 1–5) with:
        - WORKTREE_PATH = [that record's worktree]
        - $AIMI_CLI init-session --file [that record's file]
        - All subsequent steps (reset-orphaned, validate, wave loop, completion)
        - Scoped to that split file only
        - PROJECT_GUIDELINES = PROJECT_GUIDELINES
    ]
)
```

Each parallel Task receives the full execute.md flow:
- **init-session** with `--file <path>` targeting its specific file
- **reset-orphaned** to recover any stuck stories in that file
- **validate-stories** for content validation
- **wave loop** (Step 4) executing all stories from its file
- Each flow commits to its own branch (`metadata.branchName` from its file) inside its own repo — no branch conflicts
- Prototype files are read by each subagent independently via `$AIMI_CLI get-story-context` (pointer-only handoff)

**None of the above depends on the shared current-tasks pointer once running concurrently.** `init-session --file <path>` still writes that pointer (see Point the session at this phase's own tasks file for why the write itself is kept), but every call this flow's own Step 1/3/4 makes afterward — `reset-orphaned`, `validate-stories`, `count-pending`, `list-ready`, `status`, `mark-in-progress`, `mark-failed`, `cascade-skip`, `mark-complete`, and each spawned story executor's own `get-story-context` — passes `--tasks-file` resolved from this Task's own `TASKS_PATH` (the path this Task's own `init-session --file` call was given), never the bare form. Two or more of these Tasks run in the same turn and each overwrites the pointer with its own path; that stomping is harmless now, because nothing on this path reads the pointer back to decide what to read or mutate.

After all Tasks return, collect results and proceed to **Aggregated Completion (Split Mode)**.
