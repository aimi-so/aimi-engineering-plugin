---
name: aimi:execute
description: Execute all pending stories autonomously with wave-based parallelism
argument-hint: "[--phase <N>] [--container|--inline] [--push]"
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash(git:*), Bash(mkdir:*), Bash(AIMI_CLI=*), Bash($AIMI_CLI:*), Bash(WORKTREE_MGR=*), Bash($WORKTREE_MGR:*), Task
---

# Aimi Execute

Execute all pending stories autonomously using wave-based fan-out.

Each wave uses pointer-only handoff to keep the orchestrator's working memory slim:
- **Wave selection:** `list-ready --brief` returns lightweight story stubs `{id, title, priority, dependsOn, project}` for scheduling decisions.
- **Spawn prompt:** carries only a `task_pointer` section with the story id — no inlined story body, no inlined prototype context. Each subagent fetches its own full context via `$AIMI_CLI get-story-context $STORY_ID` as its first action.

Every story runs in its own git worktree spawned as a fresh-context Task subagent. Within a wave, stories execute in parallel up to metadata.maxConcurrency; selection order follows $AIMI_CLI list-ready output (tasks.json file order, deterministic).

## Step 0: Resolve CLI Path

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/cli-path-resolution.md` and follow the **Resolve CLI Path** and **Version Check** sections to set `$AIMI_CLI`. Each layer is a separate Bash call.

If resolution fails, report error and STOP.

**Each Bash tool call is an isolated shell — `$AIMI_CLI` does not persist.** Re-read the cache at the top of every subsequent Bash call that needs `$AIMI_CLI` or `$WORKTREE_MGR`. See the **Per-Call Resolution** section of `commands/references/cli-path-resolution.md` for the one-liner and shell guard to prepend.

### Resolve Agent Models

Read and follow the **Resolve Agent Models** section of `commands/references/cli-path-resolution.md` to populate `AGENT_MODELS`. When resolution fails, treat every category as `"inherit"` and continue.

## Multi-Repo Handling

This section is the single source of truth for multi-repo layout detection and per-project story routing. All call sites below reference it by name.

### AIMI_ROOT_IS_GIT_REPO Branching Rule

`AIMI_ROOT_IS_GIT_REPO` is a **per-block derived value**, never a variable carried between Bash calls — each Bash tool call is an isolated shell, so nothing assigned in one block survives into the next. Every block that branches on it derives it first, exactly like `$AIMI_CLI` and `$AIMI_ROOT` are re-derived per call. This is the canonical form; embed it verbatim (the git check needs `AIMI_ROOT` in scope, so the upward walk comes first):

```bash
AIMI_ROOT="$PWD"
while [ "$AIMI_ROOT" != "/" ] && [ ! -d "$AIMI_ROOT/.aimi" ]; do AIMI_ROOT=$(dirname "$AIMI_ROOT"); done
[ -d "$AIMI_ROOT/.aimi" ] || AIMI_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
if git -C "$AIMI_ROOT" rev-parse --git-dir >/dev/null 2>&1; then AIMI_ROOT_IS_GIT_REPO=true; else AIMI_ROOT_IS_GIT_REPO=false; fi
```

Two shell consumers embed it: Step 1.5's **Detect Git Repo Layout** (which echoes the value so the agent can read it) and the phase container's **Unsupported Combination Guard: Phase Mode + Multi-Repo**. Every other consumer below — Step 1.6's Early-Skip Guard, Step 2's container/branch-setup skips, Step 4's per-group commit counting — is an agent-level branch that references this rule by name and reads the value Step 1.5 echoed; no shell is involved, so none of them needs its own derivation.

When **true**, AIMI_ROOT is itself a git repository — all inline logic (default-branch detection, fetch, branch setup, worktree creation) runs directly against AIMI_ROOT. When **false**, this is a **multi-repo layout**: Claude Code runs from a parent folder containing multiple git repos as subfolders. In this layout:

- Default-branch detection and `git fetch origin` are skipped at the AIMI_ROOT level and happen per-project instead.
- Step 1.6 (Branch Base Selection) is skipped entirely; `BASE_BRANCH` is left unset.
- Step 2 "Main Repo Branch Setup" is skipped entirely; all branch setup is handled per-project.
- All stories must carry a `project` field (the per-project path).

### Per-Story Project-Grouping Pattern

Stories are grouped by their `project` field:

- Stories with a non-null `project` field are routed to `AIMI_ROOT / story.project` (resolved to an absolute path).
- Stories without a `project` field (null/absent) form the DEFAULT group, routed to the current working directory (CWD).

**Path validation rules:** `project` field values must match `^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$`. No leading `./` and no `..` path components are allowed.

Each project group operates independently: its own default-branch detection, `git fetch origin`, branch setup, worktree creation, merge, and cleanup all run against that project's git root.

### Per-Project Cleanup Rule

After each wave (and in Post-Loop safety cleanup), for each unique `project_root` (including CWD for the DEFAULT group):

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
cd [project_root]
$WORKTREE_MGR list
# For each worktree matching "[branchName]-US-*":
$WORKTREE_MGR remove [worktree_name]
```

This rule is unchanged, but does not apply in phase mode — see `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Phase Mode: Worktree Naming and CWD, which supersedes `project_root` with `PHASE_CONTAINER_PATH` for the duration of a claimed phase's execution — nor does it apply, in the same way, to container mode (`PHASE_MODE=false`, `CONTAINER_MODE=true`; see Execution Mode Detection in Step 1), which supersedes `project_root` with `CONTAINER_PATHS[group_key]` for the duration of that project group's container-mode execution. See that same reference's Execution Context: EXEC_ROOT, EXEC_BRANCH, EXEC_OWNS_ROOT, EXEC_KEEPS_BRANCH subsection for the contract that replaces this per-consumer branching.

### Container Paths Per Project Group (Container Mode)

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Container Paths Per Project Group — defines `CONTAINER_PATHS[group_key]`, populated by Step 2's Flat Container Mode / Per-Project Branch Setup and consumed by Step 4's wave loop and both cleanup passes via `EXEC_ROOT`/`EXEC_BRANCH`.

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Phase Mode: Worktree Naming and CWD — the single source of truth for how `PHASE_MODE=true` and `CONTAINER_MODE=true` each change worktree naming, CWD, and the `EXEC_ROOT`/`EXEC_BRANCH`/`EXEC_OWNS_ROOT`/`EXEC_KEEPS_BRANCH` execution context that Step 4's wave loop, its cleanup passes, and the post-merge visual-verification origin rewrite all consume. When both modes are false (inline, the default), every rule there reduces to exactly today's flat-mode behavior — no new variable is read, no new conditional branch is taken.

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Create or Reuse a Container and § Bootstrap a Container Dev Server — the shared mechanisms every container, phase-container, and split-container creation and dev-server bootstrap call site below delegates to.

---

## Release the Claim on Abort

This section is the single source of truth for releasing a phase's `roadmap-claim` when a phase-mode session (Step 1.7 onward) stops without reaching the normal completion path (**Mark Phase Completed** in Phase Completion, which already releases the claim atomically as part of its `completed` status write). Every other STOP/abort in phase mode, once this session has successfully claimed a phase, releases the claim first. There are no exceptions: a session that has stopped acting on a phase is no longer "actively working" it, and `roadmap-claim`'s own auto-mode branch already treats any *unclaimed* `pending`/`planned`/`in_progress`/`verification_failed` phase as re-claimable (lowest id among dependency-eligible candidates) — so an unclaimed phase, whatever its status, is cleanly recoverable by a plain `/aimi:execute` re-run, self or otherwise. Holding the claim past this session's own stop only forces that recovery to wait on PID-liveness staleness instead of being immediate.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
```

**Guard — only the session that itself ran Step 1.7 calls this.** A Phase-Mode Paired Split sub-orchestrator never runs Step 1.7 (its spawn prompt pre-sets `PHASE_MODE`/`PHASE_BRANCH`/`PHASE_CONTAINER_PATH`/`PHASE_TASKS_PATH` directly and explicitly skips Step 1.7 entirely), so it never learns `$PHASE_ID` and must never call this — doing so would release the *parent's* claim on the whole phase out from under the sibling split still running. Every call site below is therefore written as "when `PHASE_MODE=true` **and** `$PHASE_ID` is set" — true only in the top-level orchestrator that itself claimed the phase, never in a spawned split sub-orchestrator.

---

## Step 0.5: Archival Check

Before starting a new session, check whether any completed task files should be archived to prevent accidental re-execution of finished work.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI list-archivable
```

This returns a JSON array of file paths, e.g.:
```json
["/home/user/project/.aimi/tasks/2026-03-15-auth-feature-tasks.json"]
```

**If the array is empty (`[]`):** Proceed silently to Step 1.

**If archivable tasks exist:** Display the list and ask the user whether to archive them:

```
Found [N] completed task file(s) that can be archived:

  - [filename1]
  - [filename2]

Archive these completed tasks before starting? (yes/no)
```

- **If user confirms (yes):** For each archivable file path, run:
  ```bash
  AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
  : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
  $AIMI_CLI archive-task [file_path]
  ```
  After all files are archived, reset state files:
  ```bash
  AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
  : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
  $AIMI_CLI clear-state
  ```
  Report:
  ```
  Archived [N] task file(s). State cleared.
  ```
  Proceed to Step 1.

- **If user declines (no):** Proceed to Step 1 without archiving.

## Visual Follow Lifecycle

The visual-follow feature spans four phases of the execute flow. This section documents the full lifecycle; each call site below references it by name.

### Phase 1 — Detection (Step 0.7)

The tasks file is scanned for stories with `verification.strategy == "visual"`. If any are found, the user is prompted once whether to follow visually. The result is stored in `VISUAL_FOLLOW=true|false` and held for the rest of the session.

### Phase 2 — Session Open (Step 3.3)

When `VISUAL_FOLLOW=true`, a persistent headed browser session named `visual-follow` is opened before the wave loop begins:

```bash
agent-browser --headed --session visual-follow open "$VISUAL_URL"
```

**Availability check:** Before opening, `command -v agent-browser` is run. If `agent-browser` is not installed, the user is warned and `VISUAL_FOLLOW` is downgraded to `false` (headless fallback takes over in Phase 3):

```
⚠ agent-browser not installed. Falling back to headless mode — visual follow disabled.
```

The session is opened exactly once. It is never closed mid-run.

**Container mode:** `$VISUAL_URL` is not the raw `verification.url` in this case — its origin (scheme + host + port) is rewritten to the first visual story's own project group's container dev server, preserving path and query (see Container Dev Server Bootstrap and Open Visual Follow Session, both in Step 3.3). The dev server is started, and its port resolved, before this URL is computed — never after. Outside container mode, `$VISUAL_URL` is the unrewritten `verification.url`, exactly as before.

**Phase mode:** the same origin rewrite applies, keyed by `PHASE_BRANCH` instead of a project group — but unlike container mode, the port is never cached from the earlier bootstrap: it is re-queried fresh via `serve status "$PHASE_BRANCH"` at this exact point, since a phase's wave loop can run long after Step 1.7's bootstrap and each Bash call is an isolated shell (see Phase Container Dev Server Bootstrap and Open Visual Follow Session, both in Step 1.7/Step 3.3). This applies unmodified inside a Phase-Mode Paired Split sub-orchestrator too, whose spawn prompt already pre-sets `PHASE_BRANCH`/`PHASE_CONTAINER_PATH` to its own split before this step runs.

### Phase 3 — Reuse Within Wave (Step 4 per-story)

After each story merges, visual stories are verified. When `VISUAL_FOLLOW=true`, the existing `visual-follow` session is reused (`agent-browser --session visual-follow open/screenshot`). When `VISUAL_FOLLOW=false`, a fresh headless `agent-browser` session is opened, screenshot taken, and closed per story. If `agent-browser` is absent in either case, `verification.status` is set to `skipped`.

**Container mode:** the URL used at each per-story verification call is likewise rewritten to that story's own project group's container dev server origin (see the post-merge verification block in Step 4). When that group's dev server never resolved a port, `verification.status` is set to `skipped` for that story — mirroring the "agent-browser not installed" degradation above — without ever blocking `mark-complete` or the wave loop.

**Phase mode:** the same per-story rewrite applies, again via a fresh `serve status "$PHASE_BRANCH"` query at this exact call site rather than any cached value. A full-stack split story whose page depends on an API served by the sibling split's container may fail or show a broken API call against its own split's server — there is no proxy between the two split servers (see Split Container Dev Server Bootstrap in Phase-Mode Paired Split). This is a documented limitation, not a bug: it degrades that story's `verification.status` exactly like a missing dev server does, and never blocks the wave or triggers a retry.

**Console capture (additive, per story).** Immediately before each per-story `open`, the wave loop issues `agent-browser console --clear` to drop logs accumulated from prior stories in the same wave. Right after `screenshot`, it captures `agent-browser console --json` and `agent-browser errors --json` for this story's page-load output and feeds both into the `attribute_console_errors()` pass defined in the Console Error Attribution section. Capture is advisory only — it never changes `verification.status` and never blocks the wave. The per-story `--clear` is what enables per-story attribution; without it, the buffer is wave-cumulative and the LAST verified story would inherit every prior story's errors.

### Phase 4 — Keep Open on Completion (Post-Loop)

When `VISUAL_FOLLOW=true`, the `visual-follow` session is intentionally left open after execution ends so the user can inspect the final UI state. The user must close it manually.

---

## Step 0.7: Visual Follow Prompt

Check the tasks file directly for any stories with a visual verification strategy. Since `$AIMI_CLI status` omits the `verification` field, read the file with jq:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
TASKS_PATH="$($AIMI_CLI init-session 2>/dev/null | jq -r '.tasks // empty')"
VISUAL_STORIES=$(jq '[.userStories[] | select(.verification | type == "object" and .strategy == "visual")] | length' "$AIMI_ROOT/$TASKS_PATH" 2>/dev/null)
MALFORMED_VERIF=$(jq '[.userStories[] | select(.verification != null and (.verification | type != "object"))] | length' "$AIMI_ROOT/$TASKS_PATH" 2>/dev/null)
```

If `MALFORMED_VERIF` > 0, collect the affected story IDs and abort:

```bash
MALFORMED_IDS=$(jq -r '[.userStories[] | select(.verification != null and (.verification | type != "object")) | .id] | join(", ")' "$AIMI_ROOT/$TASKS_PATH" 2>/dev/null)
```

Report the error and STOP:
```
Malformed verification fields detected — aborting.

Affected stories: [MALFORMED_IDS]

Verification must be an object, not a bare string. Run:
  $AIMI_CLI normalize-verification <tasks-path>
to fix the file, then re-run /aimi:execute.
```
STOP execution.

- **If `VISUAL_STORIES` is 0 or empty:** Set `VISUAL_FOLLOW=false`. Proceed to Step 1.

- **If `VISUAL_STORIES` > 0:** Prompt the user:

```
Frontend stories detected. Follow implementation visually in a headed browser? (yes/no)
```

  - **If user says yes:** Set `VISUAL_FOLLOW=true`.
  - **If user says no:** Set `VISUAL_FOLLOW=false`.

See the Visual Follow Lifecycle section above for the full lifecycle contract.

Proceed to Step 1.

## Step 0.9: Multi-File Auto-Detection

Discover whether the tasks files on disk form a **split group** — a set of sibling task files planned together in one `story-merge` run that must all execute in this single invocation. Detection is owned entirely by one CLI verb; this step reads its answer and never re-derives it:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI split-detect | jq -r '
  "mode=\(.mode) activeCount=\(.activeCount) total=\(.total)",
  "anchor=\(.anchor // "-")",
  (if .degradedReason == null then empty else "degraded: \(.degradedReason)" end),
  (.members[] | "  \(if .active then "active " else "skipped" end)  \(.project)  \(.branchName // "-")  \(.path)")
'
```

### Split Detection

`split-detect` is a **query, not a gate**: every detection outcome — including `single` and `none` — exits 0. A non-zero exit means a real error (bad argument, unreadable directory); report its stderr verbatim and STOP.

It owns every rule this step used to spell out as prose, and each of those rules is now a test case in `test-aimi-cli.sh` (TC36–TC46):

- **Project-Split Detection** — reads the `metadata.splitGroup` marker `{project, index, total, siblings[]}` that `story-merge`'s N-file PROJECT-axis writer stamps on every file it emits, resolves the anchor's declared siblings **by basename** against the anchor's own directory (which renders a traversal-shaped sibling entry inert), and validates the declared `total` against the resolved count. Nothing outside the anchor's own declared sibling list ever joins the group, however similar its basename.
- **Paired Split Detection** — the legacy `-frontend-tasks.json`/`-backend-tasks.json` suffix-and-shared-prefix rule, reached only when the newest candidate carries no marker. Unmarked pair members report `project` as `"."`.
- **Active Split Files** — a member is *active* when it has at least one story whose status is not `completed`. A file whose `userStories` array is empty (the N-file writer legitimately emits one for a project group that ended up with zero stories) is never active, and an inactive member produces no worktree, no branch, no container, no spawned Task, no report block, and no cleanup call. The predicate is `(.status // "pending") != "completed"` — one definition behind every count the verb reports.

Two of its properties are load-bearing for this step:

- **Its flat scope is depth 1 only** — the `*-tasks.json` files sitting directly in `.aimi/tasks/`, never a phase directory's own files. Step 0.9 runs before phase mode is resolved, so without that bound a PROJECT-axis phase would be picked up and executed here as a flat split, with the phase never claimed and nothing merged into the phase branch. A phase's own split is matched instead by Step 1.7's **Detect a Full-Stack Split Inside This Phase**, which detects against that one phase's directory; `split-detect --dir <phase-dir>` is the same verb narrowed to exactly that scope.
- **Newest wins.** The anchor is the newest candidate by mtime — not the first marker-carrying file in mtime order. A group with no active member is dropped from the candidate pool and the next-newest candidate is considered, so a stale split can neither preempt today's plan nor divert it to a single-file fallback.

Branch on `mode` and `activeCount`:

| `mode` | `activeCount` | Continue with |
|---|---|---|
| `none` | `0` | Skip the rest of Step 0.9 — Step 1's `init-session` reports the missing-file error. |
| `single` | `1` | **Single-File Fallback**, passing `.anchor` explicitly. |
| `project-split` / `paired-split` | `1` | Nothing left to parallelize — **Single-File Fallback**, passing the one active member's `.path` explicitly. |
| `project-split` / `paired-split` | `≥ 2` | The split flow: **Per-Repo Branch and Container Setup for the Split** onward. |

When `degradedReason` is non-null, report it verbatim; do not re-derive *why* the group was rejected, since the verb already computed both counts and the specific defect. A degraded group is terminal — it deliberately does not fall through to the legacy pair rule, because a scope planned by the project-split writer makes any `-frontend-tasks.json`/`-backend-tasks.json` sitting beside it stale, and running it would execute the wrong work.

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
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"

SPLIT_EXECUTION_MODE=$(jq -r '.metadata.execution // "inline"' \
  "$(printf '%s\n' "$SPLIT_PLAN" | head -1 | jq -r '.file')")
echo "Split execution mode: $SPLIT_EXECUTION_MODE"

while IFS= read -r record; do
  [ -n "$record" ] || continue
  SPLIT_ROOT=$(printf '%s' "$record" | jq -r '.root')
  SPLIT_BRANCH=$(printf '%s' "$record" | jq -r '.branch')
  SPLIT_DEFAULT=$(printf '%s' "$record" | jq -r '.default')
  # BASE_BRANCH is a Step 1.6 value and Step 1.6 has not run this early, so this
  # always resolves to that repo's own default branch. Written as a default
  # expansion rather than an `if [ -n "$BASE_BRANCH" ]` whose true branch is
  # unreachable here.
  CONTAINER_BASE="${BASE_BRANCH:-$SPLIT_DEFAULT}"
  cd "$SPLIT_ROOT"
  if ! $WORKTREE_MGR create "$SPLIT_BRANCH" --from "$CONTAINER_BASE"; then
    echo "Worktree creation failed for $SPLIT_BRANCH in $SPLIT_ROOT — see the error above." >&2
    exit 1
  fi
done <<< "$SPLIT_PLAN"
```

**When `SPLIT_EXECUTION_MODE` is `inline` or absent** (the fail-safe default — see `commands/references/execution-mode.md`), that loop is the whole pass: one worktree per active split file, each branched from its own repo's default branch.

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

After all Tasks return, collect results and proceed to **Aggregated Completion (Split Mode)**.

### Single-File Fallback

When `split-detect` reports `mode` = `single`, or reports a split whose `activeCount` is `1`, proceed with the standard single-file execution flow (Step 1 onward) unchanged — but pass that one file explicitly (`$AIMI_CLI init-session --file [the anchor, or the one active member's path]`) instead of letting Step 1's mtime auto-discovery pick a sibling that has nothing pending. When `mode` is `none`, run Step 1 with no `--file` and let `init-session` report the error.

### Aggregated Completion (Split Mode)

When all parallel Tasks complete, skip the normal Step 5 and report aggregated results. The report contains exactly one block per plan record — a member the verb never reported as active contributes no block and no "0 stories completed" line anywhere.

#### Pass 3 — Aggregated Completion Report

Each commit count is scoped with `git -C` against that repo's own default branch: a single global `git log $DEFAULT_BRANCH..` is wrong in a multi-repo layout, where `$AIMI_ROOT` is not a repo and no global `$DEFAULT_BRANCH` was ever detected.

```bash
SPLIT_PLAN=$(cat <<'SPLIT_PLAN_EOF'
[paste Pass 1's printed SPLIT_PLAN here, verbatim — one JSON record per line]
SPLIT_PLAN_EOF
)
SPLIT_TOTAL_COMMITS=0
while IFS= read -r record; do
  [ -n "$record" ] || continue
  SPLIT_FILE=$(printf '%s' "$record" | jq -r '.file')
  SPLIT_PROJECT=$(printf '%s' "$record" | jq -r '.project')
  SPLIT_ROOT=$(printf '%s' "$record" | jq -r '.root')
  SPLIT_BRANCH=$(printf '%s' "$record" | jq -r '.branch')
  SPLIT_DEFAULT=$(printf '%s' "$record" | jq -r '.default')
  SPLIT_COMMITS=$(git -C "$SPLIT_ROOT" log --oneline "$SPLIT_DEFAULT".."$SPLIT_BRANCH" 2>/dev/null | grep -c .)
  SPLIT_TOTAL_COMMITS=$((SPLIT_TOTAL_COMMITS + SPLIT_COMMITS))
  printf '%s\t%s\t%s\t%s\t%s\n' "$SPLIT_FILE" "$SPLIT_PROJECT" "$SPLIT_BRANCH" "$SPLIT_DEFAULT" "$SPLIT_COMMITS"
done <<< "$SPLIT_PLAN"
printf 'TOTAL_COMMITS\t%s\n' "$SPLIT_TOTAL_COMMITS"
```

Render one block per line of that output, filling **Stories completed** from that member's own Task result:

```
## Execution Complete (Split Mode)

For each plan record, one block:

[file]
  Project: [project]
  Branch: [branch]
  Stories completed: [count from that file's Task result]
  Commits: [that line's commit count]

Total stories: [sum of every record's completed count]
Total commits: [TOTAL_COMMITS from the loop above]

### Next Steps

- Review [branch] commits: git -C [root] log --oneline [default]..[branch]   (one line per plan record)
- Run /aimi:review for code review
- Create PRs when ready: gh pr create
```

Both `Total` lines are sums across **all** plan records, not two named Frontend/Backend slots. For a legacy pair every root is `$AIMI_ROOT` and every default is that repo's own default branch, so the two blocks render the same lines the paired-mode report produced before.

#### Pass 4 — Clean Up Split Worktrees

Clean up after reporting — once per plan record's own branch, in its own repo, never a fixed pair of calls. Every branch is a deliverable the report above just pointed the user at for review and PR creation — not a throwaway per-story worktree — so `--keep-branch` is required here to avoid deleting the very branches the user was told to open PRs against:

```bash
SPLIT_PLAN=$(cat <<'SPLIT_PLAN_EOF'
[paste Pass 1's printed SPLIT_PLAN here, verbatim — one JSON record per line]
SPLIT_PLAN_EOF
)
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
while IFS= read -r record; do
  [ -n "$record" ] || continue
  SPLIT_ROOT=$(printf '%s' "$record" | jq -r '.root')
  SPLIT_BRANCH=$(printf '%s' "$record" | jq -r '.branch')
  cd "$SPLIT_ROOT"
  $WORKTREE_MGR remove "$SPLIT_BRANCH" --keep-branch
done <<< "$SPLIT_PLAN"
```

STOP execution (aggregated report replaces normal Step 5).

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

**When `PHASE_MODE=false` (flat v3.3 file, no `roadmap.json` sibling): execute.md runs byte-for-byte as it does today.** No further phase-mode logic applies anywhere in this document — Step 1.7 (Phase Claim) is skipped entirely; when `EXECUTION_MODE` is `inline` or absent (see Execution Mode Detection below), Step 2 checks out `branchName` directly in the main working tree exactly as before, while `EXECUTION_MODE=container` instead routes Step 2 through Flat Container Mode's own worktree creation (see Step 2); and Step 4's story worktrees are named `[branchName]-[story.id]` exactly as now. Phase mode is a parallel path added alongside the flat path; it never changes the flat path's behavior.

**When `PHASE_MODE=true`:** read `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` now — it is the single source of truth for the worktree naming/CWD, container creation, and dev-server bootstrap mechanisms every phase-mode step from Step 1.7 onward delegates to by name.

### Parse --container/--inline Override

Scan `$ARGUMENTS` for an explicit `--container` or `--inline` token (mirrors the `--phase <N>` extraction style used by Step 1.7's Parse --phase Override):

```bash
case " $ARGUMENTS " in
  *" --container "*) CONTAINER_FLAG=true ;;
  *) CONTAINER_FLAG=false ;;
esac
case " $ARGUMENTS " in
  *" --inline "*) INLINE_FLAG=true ;;
  *) INLINE_FLAG=false ;;
esac

if [ "$CONTAINER_FLAG" = "true" ] && [ "$INLINE_FLAG" = "true" ]; then
  EXECUTION_OVERRIDE="conflict"
elif [ "$CONTAINER_FLAG" = "true" ]; then
  EXECUTION_OVERRIDE="container"
elif [ "$INLINE_FLAG" = "true" ]; then
  EXECUTION_OVERRIDE="inline"
else
  EXECUTION_OVERRIDE=""
fi
```

If `EXECUTION_OVERRIDE` is `"conflict"`, report `--container and --inline are mutually exclusive — pass at most one.` and STOP. Otherwise `EXECUTION_OVERRIDE` is `"container"`, `"inline"`, or empty (no flag passed) — consumed by Execution Mode Detection below.

### Parse --push Override

Scan `$ARGUMENTS` for an explicit `--push` token, the same way. `PUSH_FLAG` is consumed later, only in flat container mode, at container-execution.md's **Container Mode: Push the Branch** (invoked from Step 5) — it is agent mode's explicit opt-in to publish `[branchName]` to `origin` on completion; see that section for why an opt-in is required at all:

```bash
case " $ARGUMENTS " in
  *" --push "*) PUSH_FLAG=true ;;
  *) PUSH_FLAG=false ;;
esac
```

### Execution Mode Detection

Read `metadata.execution` — the discriminator defined in `commands/references/execution-mode.md` — from the tasks file `init-session` discovered:

```bash
EXECUTION_MODE=$(jq -r '.metadata.execution // "inline"' "$AIMI_ROOT/$TASKS_PATH")
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

Check for and reset stories stuck in `in_progress` status (from interrupted previous runs):

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI reset-orphaned
```

This atomically marks all `in_progress` stories as `failed` and returns:
```json
{"count": 2, "reset": ["US-003", "US-005"]}
```

If count > 0, report: "Recovered [count] orphaned in_progress stories (reset to failed for retry): [reset IDs]"

Note: These stories will appear as "failed" in status. The user can review and re-run.

### Content Validation

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI validate-stories
```

If validation fails (exit non-zero), report the errors and STOP:
```
Story content validation failed:
[error output]

Review the stories for suspicious content and fix before execution.
```

## Step 1.5: Branch Freshness Check

Detect the default branch and fetch the latest from origin before branch setup.

### Detect Git Repo Layout

Check whether AIMI_ROOT (the directory containing `.aimi/`) is itself a git repository. This is the canonical derivation from the **AIMI_ROOT_IS_GIT_REPO Branching Rule** in Multi-Repo Handling, embedded verbatim — each Bash call is an isolated shell, so `AIMI_ROOT` is re-derived here first:

```bash
AIMI_ROOT="$PWD"
while [ "$AIMI_ROOT" != "/" ] && [ ! -d "$AIMI_ROOT/.aimi" ]; do AIMI_ROOT=$(dirname "$AIMI_ROOT"); done
[ -d "$AIMI_ROOT/.aimi" ] || AIMI_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
if git -C "$AIMI_ROOT" rev-parse --git-dir >/dev/null 2>&1; then AIMI_ROOT_IS_GIT_REPO=true; else AIMI_ROOT_IS_GIT_REPO=false; fi
echo "AIMI_ROOT_IS_GIT_REPO=$AIMI_ROOT_IS_GIT_REPO"
```

The echoed line is what every agent-level branch below reads — this block's only output, and the only place the value becomes observable outside a shell. See the **Multi-Repo Handling** section above for the full contract.

### Default Branch and Origin Fetch

When the flag is true, run both of the following. When false, skip both — per-project detection and fetch happen in the branch setup step (see Multi-Repo Handling above).

Detect the default branch:
```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
DEFAULT_BRANCH=$($AIMI_CLI detect-default-branch)
```
Store `DEFAULT_BRANCH` for use in branch creation and commit counting.

Fetch from origin:
```bash
git fetch origin
```
If fetch fails (e.g., offline or no remote), warn but continue:
```
Warning: git fetch origin failed — continuing with local state. Branch may be stale.
```

## Step 1.6: Branch Base Selection

Before creating the task branch, when the current branch has unmerged work relative to the default branch, ask whether to stack on it or start fresh from the default branch. This prevents silently inheriting unrelated work or losing intentional stacking.

`BASE_BRANCH` starts unset. It is set only when the user explicitly chooses a base; Step 2 threads it via `--base` only when set.

### Early-Skip Guard (Multi-Repo)

If `AIMI_ROOT_IS_GIT_REPO` is false, skip this step entirely and leave `BASE_BRANCH` unset. See Multi-Repo Handling above.

### Resolve Interactivity Mode

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
INTERACTIVE_MODE=$($AIMI_CLI detect-interactivity)
```

### Compute Gating Conditions

Check whether a prompt is needed. Compute all four conditions:

```bash
TARGET_EXISTS_LOCAL=$(git branch --list [branchName])
TARGET_EXISTS_REMOTE=$(git ls-remote --heads origin [branchName])
CURRENT_BRANCH=$(git branch --show-current)
CURRENT_IS_MERGED=$(git branch --merged "origin/$DEFAULT_BRANCH" | grep -Fx "  $CURRENT_BRANCH" || git branch --merged "origin/$DEFAULT_BRANCH" | grep -Fx "* $CURRENT_BRANCH")
```

A prompt is needed when **all four** of the following are true:

- `TARGET_EXISTS_LOCAL` is empty (branch does not exist locally)
- `TARGET_EXISTS_REMOTE` is empty (branch does not exist on remote)
- `CURRENT_BRANCH` != `DEFAULT_BRANCH` (not already on the default branch)
- `CURRENT_IS_MERGED` is empty (current branch has commits not yet merged into `origin/$DEFAULT_BRANCH`)

### Picker Prompt (when prompt is needed AND INTERACTIVE_MODE=picker)

Use **AskUserQuestion** with the following options:

```
Which branch should be used as the base for [branchName]?

A — Stack on current branch ([current_branch])
B — Use default branch ([DEFAULT_BRANCH])
Other — Specify a base branch
```

**Option A:** `BASE_BRANCH=$CURRENT_BRANCH`

**Option B:** `BASE_BRANCH=$DEFAULT_BRANCH`

**Option Other:** Collect the free-form branch name the user typed. Validate it against `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$`. If it does not match, report:

```
Invalid branch name. Must match ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$
```

and STOP. If valid, store `BASE_BRANCH=<user-input>`.

### Agent-Mode Fallback (when prompt is needed AND INTERACTIVE_MODE=agent)

Leave `BASE_BRANCH` unset (preserves the existing CLI heuristic which stacks on the current branch, matching the previous automatic behavior). Log:

```
agent-mode: step-1.6 branch-base auto-preserve
```

*Agent-mode fallback: if `INTERACTIVE_MODE=agent`, leave BASE_BRANCH unset and log `agent-mode: step-1.6 branch-base auto-preserve`.*

### When Prompt Is Not Needed

If any of the four gating conditions is false, skip silently — do NOT log an agent-mode line. Leave `BASE_BRANCH` unset.

## Step 1.7: Phase Claim

**Skip this step entirely if `PHASE_MODE` is false** (see Phase Mode Detection in Step 1) — proceed straight to Step 2. The rest of this step assumes `PHASE_MODE=true`.

### Parse --phase Override

Scan `$ARGUMENTS` for an explicit `--phase <N>` token (mirrors the `--root <path>` extraction style used by `/aimi:plan`):

```bash
case " $ARGUMENTS " in
  *" --phase "*)
    PHASE_OVERRIDE=$(echo "$ARGUMENTS" | sed -n 's/.*--phase[[:space:]]\+\([0-9][0-9.]*\).*/\1/p')
    ;;
  *)
    PHASE_OVERRIDE=""
    ;;
esac
```

If `PHASE_OVERRIDE` is non-empty but does not match `^[0-9]+(\.[0-9]+)?$`, report `Invalid --phase value: [PHASE_OVERRIDE]. Must be a numeric phase id.` and STOP.

### Resolve Session Identity

`roadmap-claim`'s stale-claim recovery needs a PID that stays alive for the whole `/aimi:execute` session, not the PID of one isolated Bash call (`$$` would be a different, already-dead process by the time any other session checks liveness). `$PPID` inside a Bash tool call is the PID of the process that spawns each isolated shell — the persistent host process for this session — so it stays constant across calls even though `$$` does not.

```bash
SESSION_ID="${CLAUDE_SESSION_ID:-execute-$PPID}"
SESSION_PID=$PPID
```

Compute this once; both `$CLAUDE_SESSION_ID` and `$PPID` re-derive identically on every subsequent Bash call within the same session, so re-running the two lines above anywhere this document calls `roadmap-claim` or `roadmap-release-claim` yields the same `SESSION_ID`/`SESSION_PID` values.

### Claim the Phase

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
if [ -n "$PHASE_OVERRIDE" ]; then
  CLAIM_JSON=$($AIMI_CLI roadmap-claim --feature "$FEATURE" --session-id "$SESSION_ID" --session-pid "$SESSION_PID" --phase "$PHASE_OVERRIDE" 2>&1)
else
  CLAIM_JSON=$($AIMI_CLI roadmap-claim --feature "$FEATURE" --session-id "$SESSION_ID" --session-pid "$SESSION_PID" 2>&1)
fi
CLAIM_EXIT=$?
```

`roadmap-claim` is a single atomic, flock-guarded check-and-set (mirrors the atomic-write pattern already documented for `story-merge`). It auto-releases any claim whose recorded PID fails a liveness probe, then:

- **No `--phase` (auto mode):** claims the lowest-numeric-id phase that is `pending`/`planned`, unclaimed, and whose `dependsOn` phases are all `completed`. If the top candidate loses a claim race to a concurrent session, the CLI falls through internally to the next eligible phase and returns that one — this step contains no retry loop of its own, it consumes whatever phase the single call reports back as claimed.
- **With `--phase <N>` (explicit override):** claims phase `N` only if it is eligible. If phase `N` is ineligible, the call never falls through to a different phase.
- **Self-reclaim:** if this exact session already owns an unreleased claim on a phase still in `pending`/`planned`/`in_progress` (matching `--phase N` when an override was given, or any such phase in auto mode), the call returns that same phase again instead of erroring — this is what makes re-running `/aimi:execute` on an already-claimed phase idempotent (see Resuming Execution).

**On success (`CLAIM_EXIT=0`):** `CLAIM_JSON` is the claimed phase object. Extract:

```bash
PHASE_ID=$(printf '%s' "$CLAIM_JSON" | jq -r '.id')
PHASE_DIR=$(printf '%s' "$CLAIM_JSON" | jq -r '.dir')
PHASE_SLUG=$(printf '%s' "$CLAIM_JSON" | jq -r '.slug // ""')
PHASE_BRANCH=$(printf '%s' "$CLAIM_JSON" | jq -r '.branch // ""')
```

`FEATURE_TYPE` must come from this phase's own tasks file, not the mtime-discovered `$TASKS_PATH` from Step 1 — a feature with multiple materialized phase tasks files could have a more-recently-touched sibling phase file win that mtime race, leaking the sibling's `type` into this phase's branch prefix. `PHASE_TASKS_PATH` itself isn't resolved until **Point the session at this phase's own tasks file** below, so read directly from the same path that section computes, tolerating the file not existing yet (a not-yet-planned phase, or a full-stack split phase with no single governing file):

```bash
FEATURE_TYPE=$(jq -r '.metadata.type // "feat"' "$AIMI_ROOT/.aimi/tasks/$FEATURE/$PHASE_DIR/$FEATURE-phase-$PHASE_ID-tasks.json" 2>/dev/null)
FEATURE_TYPE="${FEATURE_TYPE:-feat}"
```

If `PHASE_BRANCH` is empty (the phase carries no pre-assigned `.branch`), compute it from the `type/<feature>-phase-<N>-<slug>` convention. `PHASE_SLUG` can itself be empty (a phase with no slug); when it is, drop the trailing `-` rather than emitting a branch name that ends in one:

```bash
if [ -z "$PHASE_BRANCH" ]; then
  if [ -z "$PHASE_SLUG" ]; then
    PHASE_BRANCH="${FEATURE_TYPE}/${FEATURE}-phase-${PHASE_ID}"
  else
    PHASE_BRANCH="${FEATURE_TYPE}/${FEATURE}-phase-${PHASE_ID}-${PHASE_SLUG}"
  fi
fi
```

Validate `PHASE_BRANCH` against `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$` (the same regex Step 1.6 already enforces for user-supplied base branches). If it fails, release the claim (see Release the Claim on Abort) and report the invalid branch name, then STOP:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
```

### Report Stale Claim Releases

`CLAIM_JSON.staleReleased` is a (possibly empty) array the CLI populates whenever this exact `roadmap-claim` call auto-released one or more dead-PID claims before evaluating eligibility (see the PID-alive check described above). Report each released entry with this exact line, substituting the real values:

```bash
STALE_COUNT=$(printf '%s' "$CLAIM_JSON" | jq '.staleReleased | length')
if [ "$STALE_COUNT" -gt 0 ]; then
  while IFS=$'\t' read -r sr_id sr_sid sr_pid; do
    [ -z "$sr_id" ] && continue
    echo "released stale claim on phase $sr_id (session $sr_sid pid $sr_pid not alive)"
  done < <(printf '%s' "$CLAIM_JSON" | jq -r '.staleReleased[] | [(.id|tostring), .sessionId, (.pid|tostring)] | @tsv')
fi
```

This is a report of automatic recovery that already happened inside the atomic `roadmap-claim` call above — it never changes the outcome of this session's own claim.

### Reconcile Roadmap/Tasks Divergence

Immediately after a successful claim — before the `in_progress` status transition below — run `roadmap-reconcile` once as an advisory health check across the whole roadmap. This is the only call site in the command flow; `roadmap-reconcile` is otherwise defined and tested but never invoked, so drift between a phase's `status` in `roadmap.json` and its own tasks file's actual story statuses would otherwise go unnoticed until it surfaces as the `in_progress` transition failure below.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
RECONCILE_JSON=$($AIMI_CLI roadmap-reconcile --feature "$FEATURE" 2>/dev/null)
```

If the call fails or returns malformed JSON, skip silently — this is advisory only and never blocks the claim or the transition that follows. Otherwise, count each array and surface non-empty ones to the user without stopping:

```bash
CORRECTIONS_COUNT=$(printf '%s' "$RECONCILE_JSON" | jq '.corrections | length' 2>/dev/null || echo 0)
BLOCKED_COUNT=$(printf '%s' "$RECONCILE_JSON" | jq '.blocked | length' 2>/dev/null || echo 0)
```

```
[If CORRECTIONS_COUNT > 0:]
Roadmap reconcile corrected [CORRECTIONS_COUNT] phase(s) whose status had drifted from its tasks file:
  For each entry in RECONCILE_JSON.corrections: "  - phase [entry.id]: [entry.from] → [entry.to]"

[If BLOCKED_COUNT > 0:]
Roadmap reconcile found [BLOCKED_COUNT] phase(s) that should be completed but can't be corrected yet:
  For each entry in RECONCILE_JSON.blocked: "  - phase [entry.id]: [entry.from] → [entry.to] ([entry.reason])"
```

This is healing, not gating — it never aborts this session's claim, even when it reports corrections or blocked entries for phases other than the one just claimed.

### Overlap Guard

Before transitioning the newly claimed phase to `in_progress`, check whether any other phase in this roadmap is currently `in_progress` (in a sibling `/aimi:execute` session) and, if so, whether the two phases' declared work overlaps. This guard is **soft in both interactive and agent mode** — it never blocks or fails the claim itself, since `roadmap-claim`'s atomic check-and-set already succeeded before this section runs. Every read of a sibling phase's state below goes through `$AIMI_CLI roadmap-get` / `$AIMI_CLI phase-overlap` — never a direct Read of a phase directory this session does not own.

`roadmap-get` is used only to list which siblings are currently `in_progress`; the overlap answer itself always comes from `phase-overlap`'s exact `implementation.files` intersection — there is no coarser pre-filter gating it. A coarse `areas`-array comparison was tried first and dropped: `areas` are declared as broad globs (e.g. `app/checkout/**` vs. `app/checkout/cart/**`), so two phases that provably share files could still compare as disjoint under exact string equality, silently skipping the real check it was meant to gate — and a phase with no `areas` at all disabled the guard entirely. Calling `phase-overlap` unconditionally for every `in_progress` sibling has no such gap:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
ROADMAP_ALL_JSON=$($AIMI_CLI roadmap-get --feature "$FEATURE")

OVERLAP_WARNINGS_JSON='[]'
while IFS= read -r y_id; do
  [ -z "$y_id" ] && continue
  # phase-overlap failing here (e.g. the sibling has not been rolling-wave
  # expanded yet, no tasks.json) is not an error for this soft guard -- skip
  # that sibling.
  if OVERLAP_JSON=$($AIMI_CLI phase-overlap "$FEATURE" "$PHASE_ID" "$y_id" 2>/dev/null); then
    FILES_COUNT=$(printf '%s' "$OVERLAP_JSON" | jq '.overlapping_files | length')
    if [ "$FILES_COUNT" -gt 0 ]; then
      FILES_ARR=$(printf '%s' "$OVERLAP_JSON" | jq -c '.overlapping_files')
      OVERLAP_WARNINGS_JSON=$(printf '%s' "$OVERLAP_WARNINGS_JSON" | jq --argjson y "$y_id" --argjson files "$FILES_ARR" '. + [{phaseId: $y, files: $files}]')
    fi
  fi
done < <(printf '%s' "$ROADMAP_ALL_JSON" | jq -r --argjson x "$PHASE_ID" '[.phases[] | select(.status == "in_progress" and .id != $x)] | .[].id')
```

**When `OVERLAP_WARNINGS_JSON` is `[]`** (no `in_progress` sibling, or `phase-overlap` found no shared file with any sibling it could evaluate): skip silently — no prompt, no log line. Proceed straight to the status transition below.

**When `OVERLAP_WARNINGS_JSON` is non-empty**, for each `{phaseId: Y_ID, files}` entry in order:

- **`INTERACTIVE_MODE=picker`:** use **AskUserQuestion**:
  ```
  Phase [PHASE_ID] and in-progress phase [Y_ID] both touch:
  [one line per path in files]

  A — Proceed in parallel anyway
  B — Wait for phase [Y_ID] to finish before claiming
  C — Abort this claim attempt
  ```
  - **Option A:** continue to the next entry (or, if this was the last entry, proceed to the status transition below).
  - **Option B or C:** release the claim this session just took, and STOP — do not evaluate any remaining entries:
    ```bash
    AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
    : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
    $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
    ```
    Report `Claim on phase [PHASE_ID] released — [waiting for phase [Y_ID] to finish | claim attempt aborted] per user choice.` and STOP.
- **`INTERACTIVE_MODE=agent`:** log a one-line warning per entry and proceed automatically — never release the claim:
  ```
  Warning: phase [PHASE_ID] and in-progress phase [Y_ID] share file(s): [comma-joined files] (agent-mode: proceeding in parallel)
  ```
  After logging every entry, continue to the status transition below.

**Immediately after a successful claim, transition the phase to `in_progress`.** This is a SEPARATE call — `roadmap-claim` manages only the claim sub-object (`claimedBy`/`claimedAt`/`claimedPid`) and never drives status itself, so this step contains exactly one roadmap-status-mutating call beyond the claim:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
if ! SET_STATUS_ERR=$($AIMI_CLI roadmap-set-status --feature "$FEATURE" --phase "$PHASE_ID" --status in_progress 2>&1); then
  echo "ERROR: could not transition phase $PHASE_ID to in_progress:" >&2
  echo "$SET_STATUS_ERR" >&2
  echo "roadmap.json and this phase's tasks file disagree. Run: $AIMI_CLI roadmap-reconcile --feature \"$FEATURE\"" >&2
  $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
  exit 1
fi
```

Do **not** swallow this call's exit status. Every state a claim can hand back — `pending`, `planned`, `in_progress` (crashed-session resume) and `verification_failed` (re-verify retry) — has an explicit `→ in_progress` transition, including the idempotent `in_progress → in_progress`. So a rejection here is never routine: it means the phase is in a state the claim should not have returned, i.e. roadmap.json has diverged from the phase's tasks file. Failing loudly and pointing at `roadmap-reconcile` is the recovery path; an earlier `|| true` hid this and let the phase run to completion only to fail at the final `completed` transition. The claim is released (see Release the Claim on Abort) before exiting — `roadmap-reconcile` heals the divergence, and the reconcile call above already ran once for this claim, so a retry (self or otherwise) after running it manually re-claims cleanly instead of piling onto a claim this session can no longer make progress on.

**On failure (`CLAIM_EXIT` is 3 or 4):** `CLAIM_JSON` holds the CLI's stderr.

- **Auto mode, `CLAIM_EXIT=4` (no phase remains pending/planned):** report `No eligible phase — every phase in [FEATURE]'s roadmap is already claimed, completed, or terminal.` and STOP.
- **Auto mode, `CLAIM_EXIT=3` (all remaining phases blocked):** list every ineligible phase with its specific reason, taken verbatim from `CLAIM_JSON`'s `phase N: <reason>` lines (mirrors the "Deadlock detected" reporting style in Step 4):
  ```
  No phase is ready to claim:
  [one line per blocked phase, from CLAIM_JSON]

  Resolve the blocking dependency, or run /aimi:execute --phase <N> to override.
  ```
  STOP.
- **Explicit override, either exit code:** report the specific reason `CLAIM_JSON` gives for phase `PHASE_OVERRIDE` (unmet dependency, still claimed by a live session, wrong status, or not found) — never a generic "not ready" message — and STOP. Do not fall through to a different phase.

### Create or Reuse the Phase Container

#### Unsupported Combination Guard: Phase Mode + Multi-Repo

**This guard runs first — before the `cd "$AIMI_ROOT"` below, before any `$WORKTREE_MGR create`, and before any split detection.** Every phase-mode container and worktree in this file is created downstream of this point: the phase container itself, and every split worktree **Phase-Mode Paired Split** later nests inside it. One check here therefore covers all of them, including the case where a project split converges to a single distinct project (`story-merge`'s SIDE axis, by design) and lands as a two-file frontend/backend split under a root that is not a repository.

`AIMI_ROOT_IS_GIT_REPO` is re-derived here rather than carried over from Step 1.5's **Detect Git Repo Layout** — each Bash call is an isolated shell, so the canonical derivation from the **AIMI_ROOT_IS_GIT_REPO Branching Rule** (Multi-Repo Handling) is embedded verbatim below, `AIMI_ROOT` walk included. When the value is **false**, `AIMI_ROOT` is a plain parent folder holding one git repository per subfolder, not a repository itself — `cd "$AIMI_ROOT"` followed by `$WORKTREE_MGR create` exits **128** with a bare `fatal: not a git repository` (nothing is created, so no state is corrupted — but the message names neither the phase, nor the layout, nor the fix). That opaque failure is issue #73. Refuse here instead.

The decision and its consequence live in the same block: the claim release (see **Release the Claim on Abort** — this session ran Step 1.7's **Claim the Phase** itself, so `$PHASE_ID` is set and this call is the top-level orchestrator's to make) runs inside the failing branch, so a single-repo layout never touches it and a multi-repo layout can never skip it.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
AIMI_ROOT="$PWD"
while [ "$AIMI_ROOT" != "/" ] && [ ! -d "$AIMI_ROOT/.aimi" ]; do AIMI_ROOT=$(dirname "$AIMI_ROOT"); done
[ -d "$AIMI_ROOT/.aimi" ] || AIMI_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
if git -C "$AIMI_ROOT" rev-parse --git-dir >/dev/null 2>&1; then AIMI_ROOT_IS_GIT_REPO=true; else AIMI_ROOT_IS_GIT_REPO=false; fi

if [ "$AIMI_ROOT_IS_GIT_REPO" != "true" ]; then
  echo "Phase mode needs a git repository at $AIMI_ROOT; multi-repo layout detected." >&2
  $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
  exit 1
fi
```

Exit 0 means the guard passed and this subsection continues below. **When the block exits non-zero,** the claim is already released — report and **STOP** without `cd`-ing to `AIMI_ROOT`, without computing `PHASE_CONTAINER_PATH`, and without creating any container, worktree, or branch:

```
Phase mode is not supported in a multi-repo layout.

Detected layout: multi-repo — [AIMI_ROOT] is not a git repository. It is a parent
folder holding one repository per subfolder (see Multi-Repo Handling), so every
story carries its own `project` path and each repo is branched independently.

Phase [PHASE_ID] of [FEATURE] would need a phase container at
[AIMI_ROOT]/.worktrees/[PHASE_BRANCH], and a worktree cannot be created from a
directory that is not a repository — git would exit 128 with
"fatal: not a git repository".

Phase mode plus multi-repo is a combination this command does not support yet.

What you can do instead:
  - Run /aimi:execute without --phase. The flat flow (Step 0.9 onward) is
    multi-repo aware: it creates one worktree per repository, rooted at that
    repository's own path, and runs them in parallel.
  - Or run /aimi:execute from inside a single repository that has its own
    .aimi/ directory, so AIMI_ROOT is that repository and phase mode applies
    to it alone.

Phase [PHASE_ID]'s claim has been released. Nothing was created.
```

**Only when `AIMI_ROOT_IS_GIT_REPO` is true does the rest of this subsection run.** From here on, `AIMI_ROOT` is guaranteed to be a repository — which is also why every split worktree in **Phase-Mode Paired Split** below nests under `$PHASE_CONTAINER_PATH` rather than resolving a per-repo root of its own: in phase mode there is exactly one repository, and a split member's `metadata.splitGroup.project` (when present) is a monorepo subdirectory used for naming and reporting, never a separate git root.

```bash
cd "$AIMI_ROOT"
if [ -n "$BASE_BRANCH" ]; then
  CONTAINER_BASE="$BASE_BRANCH"
else
  CONTAINER_BASE="$DEFAULT_BRANCH"
fi
```

`CONTAINER_BASE` is `BASE_BRANCH` when Step 1.6 set one, otherwise `DEFAULT_BRANCH` — reusing the exact default-branch/base-selection values Steps 1.5–1.6 already computed against the main root. Delegate to **Create or Reuse a Container** with `EXEC_ROOT="$AIMI_ROOT"`, `EXEC_BRANCH="$PHASE_BRANCH"`, and `CONTAINER_BASE` as just computed. The resulting path is deterministic given `AIMI_ROOT` and `PHASE_BRANCH`:

```bash
PHASE_CONTAINER_PATH="$AIMI_ROOT/.worktrees/$PHASE_BRANCH"
```

### Detect a Full-Stack Split Inside This Phase

Before pointing the session at a single governing tasks file, check whether this phase's own directory instead holds a **split** — a set of sibling tasks files planned together for this one phase that must all execute in this single invocation. Detection mirrors Step 0.9's fixed two-pass order (project-split marker first, legacy `-frontend-tasks.json`/`-backend-tasks.json` suffix pair only as the fallback), scoped to just this phase's own directory. `PHASE_SPLIT_MODE` stays a plain boolean — *is this phase split at all* — and never becomes a count; the member list is what carries N.

Enumerate this phase's own candidate files:

```bash
PHASE_DIR_PATH="$AIMI_ROOT/.aimi/tasks/$FEATURE/$PHASE_DIR"
PHASE_MAIN_TASKS="$PHASE_DIR_PATH/$FEATURE-phase-$PHASE_ID-tasks.json"
PHASE_SPLIT_CANDIDATES=""
for candidate in "$PHASE_DIR_PATH"/*-tasks.json; do
  [ -f "$candidate" ] || continue
  [ "$candidate" = "$PHASE_MAIN_TASKS" ] && continue
  PHASE_SPLIT_CANDIDATES="${PHASE_SPLIT_CANDIDATES}${candidate}"$'\n'
done
```

**Why a directory glob is safe here and is forbidden in Step 0.9.** `PHASE_DIR_PATH` contains exactly one phase's own files. Step 0.9's `find-tasks-all` returns every `*-tasks.json` under the flat `.aimi/tasks/` root, across every feature ever planned, which is why it must never derive a group from a filename scan. The asymmetry is deliberate and load-bearing: the glob above only enumerates *candidates* local to this phase, and the group itself is still decided by the marker (Pass 1) or by the legacy pair rule (Pass 2), never by the glob alone.

#### Pass 1 — Project-Split Detection (`metadata.splitGroup`)

Read the same self-describing marker Step 0.9's **Project-Split Detection** reads — `metadata.splitGroup` = `{project, index, total, siblings[]}`, where `project` is the normalized project path (`"."` meaning the root group) and `siblings` lists every *other* member — with the same anchor-plus-declared-siblings rule and the same `total`-versus-resolved-count validation. The anchor is the first candidate carrying a well-formed marker; the group is exactly the anchor plus its own declared siblings, each resolved **by basename** against `$PHASE_DIR_PATH` (which renders a traversal-shaped sibling entry inert):

```bash
PHASE_ANCHOR_FILE=""
while IFS= read -r candidate; do
  [ -n "$candidate" ] || continue
  if jq -e '(.metadata.splitGroup | type) == "object"
            and (.metadata.splitGroup.total | type) == "number"
            and (.metadata.splitGroup.siblings | type) == "array"' "$candidate" >/dev/null 2>&1; then
    PHASE_ANCHOR_FILE="$candidate"
    break
  fi
done <<< "$PHASE_SPLIT_CANDIDATES"

PHASE_SPLIT_FILES=""
if [ -n "$PHASE_ANCHOR_FILE" ]; then
  PHASE_SPLIT_TOTAL=$(jq -r '.metadata.splitGroup.total' "$PHASE_ANCHOR_FILE")
  PHASE_SPLIT_FILES="$PHASE_ANCHOR_FILE"
  PHASE_SPLIT_OK=true
  while IFS= read -r sibling; do
    [ -n "$sibling" ] || continue
    SIBLING_PATH="$PHASE_DIR_PATH/$(basename "$sibling")"
    if [ ! -f "$SIBLING_PATH" ]; then
      echo "Warning: declared split sibling missing on disk: $SIBLING_PATH" >&2
      PHASE_SPLIT_OK=false
      break
    fi
    PHASE_SPLIT_FILES="${PHASE_SPLIT_FILES}"$'\n'"${SIBLING_PATH}"
  done < <(jq -r '.metadata.splitGroup.siblings[]?' "$PHASE_ANCHOR_FILE")
  PHASE_SPLIT_COUNT=$(printf '%s\n' "$PHASE_SPLIT_FILES" | grep -c .)
  if [ "$PHASE_SPLIT_OK" != true ] || [ "$PHASE_SPLIT_COUNT" -ne "$PHASE_SPLIT_TOTAL" ] || [ "$PHASE_SPLIT_COUNT" -lt 2 ]; then
    echo "Warning: phase split group is incomplete (declared total ${PHASE_SPLIT_TOTAL}, resolved ${PHASE_SPLIT_COUNT}) — falling back to single-file phase execution" >&2
    PHASE_SPLIT_FILES=""
  fi
fi
```

A group that fails validation degrades to single-file phase execution rather than running a partial split — and it does **not** fall through to Pass 2. Emptying `PHASE_SPLIT_FILES` above records only "no usable group here"; `PHASE_ANCHOR_FILE` stays set and is what the dispatch below reads, precisely so a failed group cannot resurrect a stale legacy pair that happens to sit in the same directory.

#### Pass 2 — Legacy Paired Split (fallback)

**Only reached when Pass 1 found no marker-carrying candidate at all** — i.e. this phase's files predate the project-split writer. The legacy rule is unchanged: two files sharing the `<feature>-phase-<N>` prefix, one ending `-frontend-tasks.json` and the other `-backend-tasks.json`. It terminates by feeding the pair into the same N-aware member list as its two-member case.

Pass 1 and Pass 2 run in the **same** Bash call, so `PHASE_ANCHOR_FILE` from Pass 1 is in scope here. The dispatch has exactly three arms, and the discriminator is `PHASE_ANCHOR_FILE` — never `PHASE_SPLIT_FILES`, which Pass 1 empties for *two* different reasons (no marker found, and marker found but group invalid) that must not be treated alike:

```bash
if [ -n "$PHASE_ANCHOR_FILE" ] && [ -n "$PHASE_SPLIT_FILES" ]; then
  # Arm 1 — Pass 1 found a marker and its group validated. Run the project split.
  PHASE_SPLIT_MODE=true
elif [ -n "$PHASE_ANCHOR_FILE" ]; then
  # Arm 2 — a marker was found but its group failed validation. Degrade to
  # single-file phase execution. The legacy pair is NOT considered: this phase
  # was planned by the project-split writer, so any -frontend-/-backend-tasks.json
  # sitting beside it is stale, and running it would execute the wrong work.
  echo "Phase split group failed validation — degrading to single-file phase execution (legacy frontend/backend pair not considered: this phase carries a project-split marker)" >&2
  PHASE_SPLIT_FILES=""
  PHASE_SPLIT_MODE=false
else
  # Arm 3 — no candidate carries the marker. Legacy pair fallback.
  LEGACY_FE_TASKS="$PHASE_DIR_PATH/$FEATURE-phase-$PHASE_ID-frontend-tasks.json"
  LEGACY_BE_TASKS="$PHASE_DIR_PATH/$FEATURE-phase-$PHASE_ID-backend-tasks.json"
  if [ -f "$LEGACY_FE_TASKS" ] && [ -f "$LEGACY_BE_TASKS" ]; then
    PHASE_SPLIT_FILES="$LEGACY_FE_TASKS"$'\n'"$LEGACY_BE_TASKS"
    PHASE_SPLIT_MODE=true
  else
    PHASE_SPLIT_MODE=false
  fi
fi
```

This mirrors the flat side, whose Project-Split Detection likewise dispatches on `ANCHOR_FILE` ("When `ANCHOR_FILE` is empty… fall through to Paired Split Detection"; "When the group failed validation… the run degrades to Single-File Fallback"). Arm 2 is the case a `PHASE_SPLIT_FILES` gate silently mishandles: it announces the degradation and then runs the stale pair anyway.

Legacy pair files carry no `metadata.splitGroup`, so every step below derives their slugs from their own basenames (`frontend`, `backend`) and reproduces exactly today's `<PHASE_BRANCH>-frontend` / `<PHASE_BRANCH>-backend` branch pair — byte-for-byte the same worktree creation, spawn, report, merge, and cleanup behavior as before, now expressed as the two-iteration case of one loop.

#### Active Split Files

A member with nothing left to do takes no part in execution. Before any branch, worktree, dev server, or Task exists, filter the member list down to its **active** entries — those with at least one story that is not already `completed`. A file whose `userStories` array is empty (the N-file writer legitimately emits a file for a project group that ended up with zero stories) drops out here and produces no worktree, no branch, no spawned Task, no dev-server bootstrap, no report block, and no cleanup call. This is the identical skip rule Step 0.9's **Active Split Files** applies in the flat flow:

```bash
PHASE_ACTIVE_SPLIT_FILES=""
if [ "$PHASE_SPLIT_MODE" = true ]; then
  while IFS= read -r split_file; do
    [ -n "$split_file" ] || continue
    SPLIT_PENDING=$(jq '[.userStories[]? | select((.status // "pending") != "completed")] | length' "$split_file")
    if [ "${SPLIT_PENDING:-0}" -gt 0 ]; then
      if [ -n "$PHASE_ACTIVE_SPLIT_FILES" ]; then
        PHASE_ACTIVE_SPLIT_FILES="${PHASE_ACTIVE_SPLIT_FILES}"$'\n'"${split_file}"
      else
        PHASE_ACTIVE_SPLIT_FILES="$split_file"
      fi
    else
      echo "Skipping split file with no pending stories: $split_file" >&2
    fi
  done <<< "$PHASE_SPLIT_FILES"
fi
PHASE_ACTIVE_COUNT=$(printf '%s\n' "$PHASE_ACTIVE_SPLIT_FILES" | grep -c .)
```

`PHASE_SPLIT_FILES` (every member) and `PHASE_ACTIVE_SPLIT_FILES` (the members that still have work) are both carried forward. Everything that *creates* something loops over the active list; **Multi-File Pending Count** in Phase Completion sums over the full member list.

**When `PHASE_SPLIT_MODE=true`:** skip **Point the session at this phase's own tasks file** below entirely — a split phase has no single governing tasks file for this session to point at — and, after Path and State Notes immediately below, proceed to **Phase-Mode Paired Split** instead of Step 2. `PHASE_ACTIVE_COUNT` of `0` is legal (every member already completed, e.g. on a resume after a merge conflict): that case creates nothing and spawns nothing, and Phase-Mode Paired Split routes it straight to **Continue to Phase Completion**.

**When `PHASE_SPLIT_MODE=false` (unchanged):** continue with **Point the session at this phase's own tasks file** below exactly as before.

**Point the session at this phase's own tasks file** so Steps 2–5 operate on the claimed phase, not whichever nested file `init-session`'s mtime-based auto-discovery happened to pick in Step 1 (a feature with multiple materialized phase tasks files could have a more-recently-touched sibling phase that is not the one just claimed):

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
PHASE_TASKS_PATH="$AIMI_ROOT/.aimi/tasks/$FEATURE/$PHASE_DIR/$FEATURE-phase-$PHASE_ID-tasks.json"
$AIMI_CLI init-session --file "$PHASE_TASKS_PATH"
```

If this errors with "File not found," the claimed phase has not been planned yet. Report:
```
Phase [PHASE_ID] is claimed but has no tasks file yet ([PHASE_TASKS_PATH]).
Run /aimi:plan --phase [PHASE_ID] to materialize it, then re-run /aimi:execute.
```
Release the claim so it does not block other sessions, then STOP:
```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
```

### Phase Container Dev Server Bootstrap

**Skip this subsection entirely when `PHASE_SPLIT_MODE` is true** — a split phase never lands a story directly on `PHASE_CONTAINER_PATH` itself, so there is nothing to serve here; each split gets its own independently-bootstrapped server instead (see Split Container Dev Server Bootstrap in Phase-Mode Paired Split below). The rest of this subsection assumes `PHASE_SPLIT_MODE=false`.

When it applies, this MUST complete before Step 3.3's Open Visual Follow Session computes `VISUAL_URL` — the same hard ordering rule Container Dev Server Bootstrap (Step 3.3) already enforces for flat container mode: install-deps → serve start → compute VISUAL_URL → open the visual-follow session.

Gate on the phase's own tasks file having at least one visual story — the same jq shape Step 0.7 already uses:

```bash
PHASE_VISUAL_STORIES=$(jq '[.userStories[] | select(.verification | type == "object" and .strategy == "visual")] | length' "$PHASE_TASKS_PATH" 2>/dev/null)
if [ -n "$PHASE_VISUAL_STORIES" ] && [ "$PHASE_VISUAL_STORIES" -gt 0 ]; then
  HAS_VISUAL_STORY=true
else
  HAS_VISUAL_STORY=false
fi
```

Delegate to **Bootstrap a Container Dev Server** with `EXEC_ROOT="$AIMI_ROOT"` (the project root, never inside the container itself — the same reason Create or Reuse the Phase Container above `cd`s to the project root before calling `$WORKTREE_MGR create`), `EXEC_BRANCH="$PHASE_BRANCH"`, and `HAS_VISUAL_STORY` as just computed. Its captured URL is discarded here — every later consumer (Step 3.3's Open Visual Follow Session, and Step 4's post-merge visual verification) re-queries the server fresh via `serve url` at the point it needs it.

### Path and State Notes

From this point forward, for the remainder of this phase's execution:

- Every Bash call that touches this phase's git state passes `PHASE_CONTAINER_PATH` explicitly — `cd "$PHASE_CONTAINER_PATH"` at the top of the call, or `git -C "$PHASE_CONTAINER_PATH"` / `$WORKTREE_MGR` invocations that take it as an argument — never assuming a CWD persisted from a prior call. This is the same "each Bash tool call is an isolated shell" rule from Step 0, applied to the container path instead of `AIMI_ROOT`. See `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Phase Mode: Worktree Naming and CWD for how this threads through Step 4's wave loop.
- `$AIMI_CLI` calls issued with CWD inside `PHASE_CONTAINER_PATH` still resolve to the main root's central `.aimi/` state with no special-casing required: `.aimi/` is gitignored, so it is absent from the container's checkout. `find_aimi_root`'s upward directory walk starts inside `PHASE_CONTAINER_PATH` (`<GIT_ROOT>/.worktrees/<phase-branch>`), finds no `.aimi/` there or in `.worktrees/`, and continues up through `<GIT_ROOT>` where the real `.aimi/` lives — passing straight through the extra nesting.

## Phase-Mode Paired Split

**Skip this entire section if `PHASE_SPLIT_MODE` is false** — proceed straight to Step 2 (the unchanged, single-file phase-mode flow described everywhere above). The rest of this section assumes `PHASE_SPLIT_MODE=true`: this phase's own directory holds a split of **N ≥ 2** sibling tasks files (`$PHASE_SPLIT_FILES`, with `$PHASE_ACTIVE_SPLIT_FILES` its still-has-work subset — both resolved by **Detect a Full-Stack Split Inside This Phase** above), and this section composes that split with the phase container `Step 1.7` already claimed and created — per the binding brainstorm decision that full-stack split and phase mode nest rather than being mutually exclusive.

The section heading and its subsection names keep the word "Paired" for stability — they are cross-referenced by name from **Detect a Full-Stack Split Inside This Phase**, from Phase Completion, and from `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md`'s `EXEC_ROOT`/`EXEC_BRANCH` table — but nothing below is limited to two members. A legacy frontend/backend pair is simply the N = 2 case of every loop here.

**When `PHASE_ACTIVE_COUNT` is `0`** (every member already completed — e.g. a resume after a merge conflict), skip every subsection below and go straight to **Continue to Phase Completion** at the end of this section: there is nothing left to branch, serve, spawn, merge, or clean up, and Phase Completion is what re-runs the pending-count and creates-verification checks.

Every Bash call in this section passes `$PHASE_CONTAINER_PATH` explicitly, exactly like the rest of phase mode (see Path and State Notes above) — never a bare relative path, never `AIMI_ROOT`. `AIMI_ROOT` is guaranteed to be a git repository here: **Create or Reuse the Phase Container**'s Unsupported Combination Guard already refused the multi-repo layout before this section could be reached. Every split worktree below therefore nests under `$PHASE_CONTAINER_PATH`, and a member's `metadata.splitGroup.project` is a monorepo subdirectory used only to name and label it — never a separate git root.

### Derive and Validate Split Branch Names

One branch per **active** split file, derived from that file's own project (or, for a legacy pair member, from its own basename) and qualified by `$PHASE_BRANCH`. Iterate `$PHASE_ACTIVE_SPLIT_FILES` in order, with `$split_file` as the loop variable:

```bash
SPLIT_BRANCHES=""
SPLIT_PLAN=""
while IFS= read -r split_file; do
  [ -n "$split_file" ] || continue
  SPLIT_PROJECT=$(jq -r '.metadata.splitGroup.project // ""' "$split_file")
  case "$SPLIT_PROJECT" in
    ""|null)
      SPLIT_SLUG=$(basename "$split_file" -tasks.json)
      SPLIT_SLUG=${SPLIT_SLUG#"$FEATURE-phase-$PHASE_ID-"}
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
  SPLIT_BRANCHES="${SPLIT_BRANCHES}${SPLIT_BRANCH}"$'\n'
  SPLIT_PLAN="${SPLIT_PLAN}${split_file}"$'\t'"${SPLIT_BRANCH}"$'\n'
done <<< "$PHASE_ACTIVE_SPLIT_FILES"

SPLIT_BRANCH_TOTAL=$(printf '%s' "$SPLIT_BRANCHES" | grep -c .)
SPLIT_BRANCH_UNIQUE=$(printf '%s' "$SPLIT_BRANCHES" | sort -u | grep -c .)
if [ "$SPLIT_BRANCH_TOTAL" -ne "$SPLIT_BRANCH_UNIQUE" ]; then
  echo "Split branch names collide across this phase's split files" >&2
  exit 1
fi
```

Every derived name is validated against `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$` — the same regex Step 1.7 already validated `PHASE_BRANCH` against — **before any worktree is created**, and the whole set is checked for collisions (two members whose slugs coincide would otherwise share one branch and silently interleave their commits). On any failure: release the claim (see Release the Claim on Abort), report the offending file and branch name, and STOP — create no worktree.

`SPLIT_PROJECT` itself is rejected on traversal shapes and on any character outside `^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$` — the same two guards, in the same order, that Step 0.9's flat per-repo loop applies to the same field, so the two sides stay diffable. The reason is **not** branch safety: `slugify` above maps every character outside `[A-Za-z0-9_-]` to `-`, so the derived branch already satisfies its own regex no matter what `SPLIT_PROJECT` holds. The reason is that `SPLIT_PROJECT` is echoed **verbatim** — never through the slug — into the Aggregated Completion Report's `Project:` line and into each spawned Task's `description`, so an unvalidated value reaches both the human reader and a sub-agent prompt unfiltered. Unlike the flat side, `SPLIT_PROJECT` is never joined onto a filesystem path here (every split worktree nests under `$PHASE_CONTAINER_PATH`), which is why this guard is about what the value can *say*, not where it can point.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
```

For a legacy pair the two basenames yield the slugs `frontend` and `backend`, so the derived branches are exactly `${PHASE_BRANCH}-frontend` and `${PHASE_BRANCH}-backend` — unchanged from before. For a project split, `apps/web` yields `${PHASE_BRANCH}-apps-web` and the root group (`project` = `.`) yields `${PHASE_BRANCH}-root`.

Carry each active member's resolved `(split_file, SPLIT_PROJECT, SPLIT_SLUG, SPLIT_BRANCH, SPLIT_WORKTREE_PATH)` tuple forward — the worktree, dev-server, spawn, report, merge, and cleanup passes below all iterate that same ordered list. `SPLIT_PLAN` is that list materialized for the shell: one tab-separated `<split_file>\t<SPLIT_BRANCH>` line per active member, in the same order as `SPLIT_BRANCHES`. A pass that needs both halves of a member's tuple reads `SPLIT_PLAN`; a pass that needs only the branch reads `SPLIT_BRANCHES`. **No per-member value is ever left in a bare scalar for a later step to read** — a scalar assigned inside a loop holds only the last member's value by the time the loop ends, which silently applies one member's decision to every other member.

### Create Split Worktrees

One worktree per active split file, each branched from `$PHASE_BRANCH`:

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
cd "$PHASE_CONTAINER_PATH"
while IFS= read -r split_branch; do
  [ -n "$split_branch" ] || continue
  $WORKTREE_MGR create "$split_branch" --from "$PHASE_BRANCH"
done <<< "$SPLIT_BRANCHES"
```

CWD is `$PHASE_CONTAINER_PATH` — never `$DEFAULT_BRANCH`'s checkout, never `AIMI_ROOT` — so, mirroring the CWD rule `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Phase Mode: Worktree Naming and CWD already establishes for individual story worktrees, every split worktree nests at `$PHASE_CONTAINER_PATH/.worktrees/<its own split branch>` — inside the phase container's own worktree tree, not a sibling of it under `AIMI_ROOT/.worktrees/`, and branched from `$PHASE_BRANCH`, not `$DEFAULT_BRANCH`. Each member's path is therefore deterministic:

```bash
SPLIT_WORKTREE_PATH="$PHASE_CONTAINER_PATH/.worktrees/$SPLIT_BRANCH"
```

### Split Container Dev Server Bootstrap

Independently for each active split — never against `PHASE_CONTAINER_PATH` itself, since no story ever lands directly on the un-merged phase branch — gate on that split's **own** tasks file having at least one visual story, mirroring Phase Container Dev Server Bootstrap's gate above exactly, scoped one level deeper. Each member computes its own gate; no member's count ever gates another's:

This block **computes** the gates; it starts no server. It emits one plan line per active member — `<SPLIT_BRANCH>\t<true|false>` — because the delegation that consumes the gate happens after the loop, and a bare `HAS_VISUAL_STORY` would by then hold only the *last* member's value:

```bash
SPLIT_SERVER_PLAN=""
while IFS=$'\t' read -r split_file split_branch; do
  [ -n "$split_file" ] || continue
  SPLIT_VISUAL_STORIES=$(jq '[.userStories[]? | select(.verification | type == "object" and .strategy == "visual")] | length' "$split_file" 2>/dev/null)
  if [ "${SPLIT_VISUAL_STORIES:-0}" -gt 0 ]; then
    HAS_VISUAL_STORY=true
  else
    HAS_VISUAL_STORY=false
  fi
  SPLIT_SERVER_PLAN="${SPLIT_SERVER_PLAN}${split_branch}"$'\t'"${HAS_VISUAL_STORY}"$'\n'
done <<< "$SPLIT_PLAN"
```

Then iterate `$SPLIT_SERVER_PLAN` — one delegation per line, never one delegation reading a leftover scalar. For each line, delegate to **Bootstrap a Container Dev Server** with `EXEC_ROOT="$PHASE_CONTAINER_PATH"` (the same CWD Create Split Worktrees above already used to create every worktree), `EXEC_BRANCH` set to **that line's** first field, and `HAS_VISUAL_STORY` set to **that line's** second field. Read `HAS_VISUAL_STORY` only from the plan line being processed; its value after the loop above belongs to whichever member happened to be last and is meaningless for every other member. Getting this wrong fails in both directions: a pure-API split inherits a visual sibling's `true` and gets a server it must never get, or a visual split inherits an API sibling's `false`, gets no server, and cannot run the visual verification its stories require.

A split with no visual story (e.g. a pure-API service) never gets nor blocks on a server — its gate simply fails, exactly like the single-file bootstrap above. Every port is discarded here too — re-resolved fresh via `serve url` at the point each split sub-orchestrator's own Step 3.3 / Step 4 call sites need it. A split sub-orchestrator's spawn prompt pre-sets `PHASE_MODE=true`, `PHASE_BRANCH=[its own split branch]`, and `PHASE_CONTAINER_PATH=[its own split worktree path]` (see Spawn Split Sub-Orchestrators below), so its own copies of Open Visual Follow Session and Step 4's post-merge visual verification apply unmodified — no split-specific code path is needed at either call site. Two members never collide on a `dev-server.json` entry either: `serve start` keys state by the container's absolute resolved path, which is unique per split branch.

**Documented limitation — no proxy between split servers:** when a story's page depends on an API served by a sibling split's container, its visual verification runs only against its own split's server; there is no proxy between them, for any N. A broken API call or failed visual check caused solely by this is expected, not a bug — it must never block the wave and never trigger a retry.

### Spawn Split Sub-Orchestrators

Report — one line per active split file, never a fixed two-slot Frontend/Backend list:

```
Phase [PHASE_ID] split detected ([PHASE_ACTIVE_COUNT] members):
  [1/PHASE_ACTIVE_COUNT] [split_file] → project: [SPLIT_PROJECT] (branch: [SPLIT_BRANCH])
  [2/PHASE_ACTIVE_COUNT] [split_file] → project: [SPLIT_PROJECT] (branch: [SPLIT_BRANCH])
  ...

Spawning parallel execution flows inside the phase container...
```

In a **single tool-call turn**, emit one foreground Task per active split file — `PHASE_ACTIVE_COUNT` Tasks in total (two for a legacy pair, three for a three-way project split, N for N). Never one turn per member; that would serialize them. Each Task runs execute.md's **Steps 2–5 only** — never Step 1's Phase Mode Detection and never Step 1.7's Phase Claim, both of which are already resolved by this parent session; a sub-orchestrator that re-derived or re-claimed the phase itself would either double-claim it or (since it has a different session identity than the parent) fail the claim outright:

```
For each active split file (loop over PHASE_ACTIVE_SPLIT_FILES, all Task( calls in one turn):

Task(
    subagent_type: "general-purpose",
    model: <AGENT_MODELS.executor when not "inherit">,
    description: "Execute split for phase [PHASE_ID]: [split_file basename]",
    prompt: [execute.md Steps 2–5, with the following pre-set — do not re-derive:
        - PHASE_MODE = true
        - PHASE_BRANCH = [that member's SPLIT_BRANCH]
        - PHASE_CONTAINER_PATH = [that member's SPLIT_WORKTREE_PATH]
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

Each sub-orchestrator's individual story-level merges therefore land on its **own** split branch — never `$DEFAULT_BRANCH`, never `AIMI_ROOT`, and never any sibling split's worktree or branch. This reuses the existing phase-mode Step 4 wave-loop machinery unmodified, one level deeper, with the split worktree standing in for the outer `PHASE_CONTAINER_PATH` and the split branch standing in for the outer `PHASE_BRANCH`.

After every Task returns, collect each one's completed-story count and failure list.

#### Nested Concurrency

Each split's own `metadata.maxConcurrency` governs only its own sub-orchestrator's wave loop. **No split's limit ever governs any other split's worktree creation or wave loop, for any N** — and none of them is governed by the phase's `roadmap.json` or by any single phase-level tasks file (there is none, in split mode). This falls out of the existing worktree-budget pre-bash-dispatcher hook with **no code change**: `_select_governing_tasks_file` (`hooks/pre-bash-dispatcher.py`) picks the candidate tasks file among every `.aimi/tasks/**/*-tasks.json` whose `metadata.branchName` exactly matches the git branch checked out at the `git worktree add` command's CWD. A story worktree created inside a given sub-orchestrator's wave loop runs with CWD inside that member's own split worktree (branch = that member's own split branch); `plan.md`'s Phase 4 metadata patch writes each split file's `metadata.branchName` as exactly that same value (see Phase 3e/Phase 4's `--phase-aware` composition), so the hook's branch-match resolves to that member's own file uniquely — every sibling's `metadata.branchName` differs (the branch names are collision-checked in Derive and Validate Split Branch Names above), so none of them ever matches.

### Aggregated Completion Report (Phase-Mode Paired Split)

Report — computed against `$PHASE_BRANCH`, never `$DEFAULT_BRANCH`. Exactly one block per **active** split file; a member skipped for having no pending stories contributes no block and no "0 stories completed" line anywhere:

```
## Execution Complete (Phase [PHASE_ID] — Split Mode)

For each active split file, one block:

[split_file]
  Project: [SPLIT_PROJECT]
  Branch: [SPLIT_BRANCH]
  Stories completed: [count from that member's Task result]
  Commits: git -C "$PHASE_CONTAINER_PATH" log --oneline [PHASE_BRANCH]..[SPLIT_BRANCH] | wc -l

Total stories: [sum of every active split file's completed count]
Total commits: [sum of every active split file's commit count]
```

Both `Total` lines are sums across **all** active split files, not two named Frontend/Backend slots. This report is computed **before** the merge below, while every split branch is still ahead of `$PHASE_BRANCH` — after the merge the same `git log` ranges would all read zero and the counts would no longer be informative.

### Merge Split Branches Into the Phase Branch

One `merge-all` call listing **every** active split branch:

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
cd "$PHASE_CONTAINER_PATH"
set --
while IFS= read -r split_branch; do
  [ -n "$split_branch" ] || continue
  set -- "$@" "$split_branch"
done <<< "$SPLIT_BRANCHES"
if [ "$#" -gt 0 ]; then
  $WORKTREE_MGR merge-all "$@" --into "$PHASE_BRANCH"
fi
```

The argv is built with positional parameters and the same `while IFS= read -r ... done <<<` pattern every other loop in this file uses. **Do not substitute bash 4's read-into-array builtin here.** It is a bash-only builtin: it does not exist in zsh, and it does not exist in the bash 3.2 that ships as `/bin/bash` on macOS. Where it is missing the read fails, the array stays empty, and the arity guard turns that failure into a **silent no-op** — every split branch stays unmerged, `$PHASE_BRANCH` keeps none of the work, and the flow proceeds to Creates Verification, which inspects `$PHASE_CONTAINER_PATH`'s tracked files and can only pass because this merge landed. A no-op here is therefore not a degraded merge, it is a phase that reports success having landed nothing. Verified: under zsh the array read fails, the guard swallows it, and the block exits 0 having merged nothing; the positional-parameter form above builds the identical argv under both bash and zsh.

This is the same `merge-all ... --into` primitive Step 4's own wave loop already uses for individual story branches, reused here for the split branches: the merge target is `$PHASE_BRANCH`, executed with CWD inside the phase container's own worktree (`$PHASE_CONTAINER_PATH`) — never `$DEFAULT_BRANCH`, never `AIMI_ROOT`. Centralizing every merge in this parent step (rather than having each sub-orchestrator merge into `$PHASE_BRANCH` itself, mid-flight, from its own worktree) avoids N parallel Tasks racing a `git checkout`/`git merge` against the same `$PHASE_CONTAINER_PATH` working directory at once; running them sequentially here, after every Task has already returned, is safe by construction. This step is also what makes Phase Completion's Creates Verification (below) meaningful: it inspects `$PHASE_CONTAINER_PATH`'s actual tracked files, which only reflect every split's work once this merge has landed.

**On merge conflict:** mirrors the existing per-wave conflict handling (Step 4) exactly — report the conflicting files, clean up every split worktree (the conflict lives in `$PHASE_CONTAINER_PATH`'s own working directory, not in the source worktrees, so removing them is safe), release the claim (see Release the Claim on Abort), and STOP:

```
MERGE CONFLICT while merging phase [PHASE_ID]'s split branches into [PHASE_BRANCH].
Split branches merged: [one line per active split branch]
Conflicting files:
[conflict output from merge-all]

Resolve the conflict on branch [PHASE_BRANCH] in [PHASE_CONTAINER_PATH] and re-run
`/aimi:execute` to continue. Every split file's stories are already marked complete —
re-running will not re-execute them, only retry this merge and the phase-completion
checks that follow it.

The phase container [PHASE_CONTAINER_PATH] itself — and any live dev server running
inside it — is left untouched by this failure; only the split worktrees above are
removed.
```

Before cleaning up the split worktrees, stop each split's own dev server — an orphaned server would otherwise keep holding its port after its worktree is gone. One iteration per active split branch, never a fixed pair of calls:

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
cd "$PHASE_CONTAINER_PATH"
while IFS= read -r split_branch; do
  [ -n "$split_branch" ] || continue
  $WORKTREE_MGR serve stop "$split_branch"
  $WORKTREE_MGR remove "$split_branch"
done <<< "$SPLIT_BRANCHES"
```

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
```

### Clean Up Split Worktrees

Only reached once the merge above succeeds. Stop each split's own dev server first — same ordering rule as the merge-conflict path above, so no split's server outlives its own worktree. One iteration per active split branch:

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
cd "$PHASE_CONTAINER_PATH"
while IFS= read -r split_branch; do
  [ -n "$split_branch" ] || continue
  $WORKTREE_MGR serve stop "$split_branch"
  $WORKTREE_MGR remove "$split_branch"
done <<< "$SPLIT_BRANCHES"
```

`serve stop` exits 0 and reports "No dev server registered" when no server was ever started for a split (its own gate in Split Container Dev Server Bootstrap never passed) — so every call above is always safe to issue, identical to container-execution.md's Container Mode: Stop the Dev Server contract (invoked from Step 5).

Removes only the split worktrees this run created. `$PHASE_CONTAINER_PATH` itself is left intact — its removal is a separate, later-timed operation owned entirely by Phase Completion's own lifecycle (the phase container is only ever torn down once the *phase* — not just this split — is fully done), never by this section.

**Why no `--keep-branch` here, unlike Step 0.9's Aggregated Completion (Split Mode).** The flat flow passes `--keep-branch` when it cleans up *its* split worktrees; this section deliberately does not, so `remove` also runs `git branch -D` on each split branch. The difference is what the branch still owes: a flat split branch is the run's final deliverable that the user is told to open a PR from, whereas a phase split branch is an intermediate that Merge Split Branches Into the Phase Branch — which this section only runs *after* — has already merged into `$PHASE_BRANCH`. Its commits are reachable from the phase branch, so the branch ref itself has no remaining consumer and keeping it would only accumulate one dead ref per member per phase. `$PHASE_BRANCH` is what carries the work forward from here, and nothing deletes it.

### Continue to Phase Completion

Proceed to the **Phase Completion** section below with `PHASE_SPLIT_MODE=true` and `$PHASE_SPLIT_FILES` still in scope. Its "phase's own pending count is zero" gate and Creates Verification step both branch on `PHASE_SPLIT_MODE` — see **Multi-File Pending Count** in Phase Completion, which sums over every member of `$PHASE_SPLIT_FILES`, not a fixed pair. Once Phase Completion (if it ran) has produced its own report, the **Aggregated Completion Report** above is what replaces this file's normal Step 5 — do not additionally run Step 5's single-file reporting for any split file.

## Step 2: Branch Setup

Get the branch name from the init-session output (already validated by CLI).

### Flat Container Mode: Create or Reuse the Feature Container

**Skip this subsection entirely unless `CONTAINER_MODE` is true** (see Execution Mode Detection in Step 1) **and `AIMI_ROOT_IS_GIT_REPO` is true** — the multi-repo case is handled per project group inside Per-Project Branch Setup below, not here. When skipped, `### Main Repo Branch Setup` below runs exactly as it does today.

#### Create or Reuse the Container

Read and validate `branchName` — defense in depth, mirroring `PHASE_BRANCH`'s validate-once-quote-everywhere discipline (`cmd_init_session` already rejected an invalid `branchName` in Step 1, before this subsection ever runs):

```bash
BRANCH_NAME=$(jq -r '.metadata.branchName' "$AIMI_ROOT/$TASKS_PATH")
if ! [[ "$BRANCH_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
  echo "Invalid branchName: $BRANCH_NAME" >&2
  exit 1
fi
```

```bash
if [ -n "$BASE_BRANCH" ]; then
  CONTAINER_BASE="$BASE_BRANCH"
else
  CONTAINER_BASE="$DEFAULT_BRANCH"
fi
```

Delegate to **Create or Reuse a Container** with `EXEC_ROOT="$AIMI_ROOT"`, `EXEC_BRANCH="$BRANCH_NAME"`, and `CONTAINER_BASE` as just computed (`BASE_BRANCH` when Step 1.6 set one, otherwise `DEFAULT_BRANCH` — the exact same base-selection rule the phase container already uses; see Create or Reuse the Phase Container). The path is deterministic given `AIMI_ROOT` and `[branchName]`:

```bash
FEATURE_CONTAINER_PATH="$AIMI_ROOT/.worktrees/$BRANCH_NAME"
CONTAINER_PATHS["DEFAULT"]="$FEATURE_CONTAINER_PATH"
```

`CONTAINER_PATHS["DEFAULT"]` aliases the single-repo container into the same map Per-Project Branch Setup populates below, under the `"DEFAULT"` key Multi-Repo Handling's grouping pattern already uses for stories without a `project` field — so Step 4's wave loop can look up `CONTAINER_PATHS[group_key]` uniformly regardless of single-repo or multi-repo layout.

Because this subsection's own `$WORKTREE_MGR create` call is the branch-creating operation for this run, `### Main Repo Branch Setup` below is skipped whenever this subsection applies — see its skip condition.

### Main Repo Branch Setup

**Skip this step if `AIMI_ROOT_IS_GIT_REPO` is false, if `PHASE_MODE` is true, or if flat container mode applies (`PHASE_MODE=false` and `EXECUTION_MODE=container`, i.e. `CONTAINER_MODE=true`)** — see Multi-Repo Handling above for the first condition. In phase mode, the phase container's `$WORKTREE_MGR create` call in Step 1.7 is the only branch-creating operation for this phase; no `setup-branch` call runs against the main working tree, which is what keeps the Main Working Tree Untouched Invariant (see `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Phase Mode: Worktree Naming and CWD) true. In flat container mode, Flat Container Mode's own `$WORKTREE_MGR create` call above is likewise the only branch-creating operation for this run. When `EXECUTION_MODE` is `inline` or absent, this subsection runs byte-for-byte exactly as it does today — no observable change to the inline path.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
if [ -n "$BASE_BRANCH" ]; then
  BRANCH_JSON=$($AIMI_CLI setup-branch [branchName] --default-branch $DEFAULT_BRANCH --base $BASE_BRANCH)
else
  BRANCH_JSON=$($AIMI_CLI setup-branch [branchName] --default-branch $DEFAULT_BRANCH)
fi
```

If the command fails (non-zero exit), report the error and STOP.

Extract the action from the JSON output and report:
```
Branch setup: [action]
```

Where `[action]` is the `action` field from the JSON response (e.g., `already-on-branch`, `checked-out-local`, `checked-out-remote`, `created-from-default`, `created-from-current`, `created-from-base`).

### Per-Project Branch Setup

After setting up the branch in the main repo (or skipping if multi-repo layout), check if any stories have a `project` field by running `$AIMI_CLI list-ready --brief` and inspecting the results.

Run the following sub-steps when any story has a non-null `project` field, or when in multi-repo layout (see Multi-Repo Handling above for the gate condition). Skip this step when no stories have a `project` field and AIMI_ROOT is a git repo (backwards compatible).

1. Collect unique project paths from ALL pending stories (not just ready ones — use `$AIMI_CLI status` and filter stories with a `project` field).
2. Resolve each project path to an absolute path: `AIMI_ROOT / story.project` where AIMI_ROOT is the directory containing `.aimi/`.
3. For each unique project path, detect its default branch. Read and validate `branchName` here too — defense in depth, mirroring `PHASE_BRANCH`'s validate-once-quote-everywhere discipline (`cmd_init_session` already rejected an invalid `branchName` in Step 1); every sub-step below reuses this same `$BRANCH_NAME`, exactly like `$PROJECT_DEFAULT` is computed once here and reused below:
   ```bash
   AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
   : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
   PROJECT_DEFAULT=$($AIMI_CLI detect-default-branch --project [resolved_project_path])
   git -C [resolved_project_path] fetch origin 2>/dev/null || true
   BRANCH_NAME=$(jq -r '.metadata.branchName' "$AIMI_ROOT/$TASKS_PATH")
   if ! [[ "$BRANCH_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
     echo "Invalid branchName: $BRANCH_NAME" >&2
     exit 1
   fi
   ```

   **When `CONTAINER_MODE` is false** (`EXECUTION_MODE` inline or absent): set up the branch directly — unchanged for an inline-mode run. `CONTAINER_MODE` is forced false whenever `PHASE_MODE` is true (see Execution Mode Detection in Step 1), so a phase-mode run with a project-scoped story falls into this same branch today; unlike Main Repo Branch Setup above, this subsection has no `PHASE_MODE` skip condition of its own. Phase mode pairing with per-story `project` fields is not yet a validated combination — running `setup-branch` here would check out `[branchName]` directly onto that project's own working tree, the same operation the Main Working Tree Untouched Invariant forbids for a claimed phase. Treat this as a known gap, not as "unchanged," until phase mode grows its own per-project container handling:
   ```bash
   if [ -n "$BASE_BRANCH" ]; then
     PROJECT_BRANCH_JSON=$($AIMI_CLI setup-branch "$BRANCH_NAME" --default-branch $PROJECT_DEFAULT --project [resolved_project_path] --base $BASE_BRANCH)
   else
     PROJECT_BRANCH_JSON=$($AIMI_CLI setup-branch "$BRANCH_NAME" --default-branch $PROJECT_DEFAULT --project [resolved_project_path])
   fi
   ```
   Extract the action from the JSON output and report:
   ```
   Branch [branchName] set up in project: [project_path] (action: [action])
   ```

   **When `CONTAINER_MODE` is true:**

   Pure multi-repo layout (`AIMI_ROOT_IS_GIT_REPO=false`) skips Step 1.6 entirely and therefore never sets `INTERACTIVE_MODE`, which downstream picker/agent-mode gates elsewhere in this document still expect to be set. Re-resolve it here when still unset:
   ```bash
   AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
   : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
   if [ -z "$INTERACTIVE_MODE" ]; then
     INTERACTIVE_MODE=$($AIMI_CLI detect-interactivity)
   fi
   ```

   ```bash
   if [ -n "$BASE_BRANCH" ]; then
     CONTAINER_BASE="$BASE_BRANCH"
   else
     CONTAINER_BASE="$PROJECT_DEFAULT"
   fi
   ```

   Delegate to **Create or Reuse a Container** with `EXEC_ROOT=[resolved_project_path]`, `EXEC_BRANCH="$BRANCH_NAME"`, and `CONTAINER_BASE` as just computed (`BASE_BRANCH` when Step 1.6 set one, otherwise `PROJECT_DEFAULT`) — producing one container per project group at `[resolved_project_path]/.worktrees/[branchName]`, never one container spanning multiple project roots:

   ```bash
   CONTAINER_PATHS[project_path]="[resolved_project_path]/.worktrees/$BRANCH_NAME"
   ```

   `[project_path]` here is the group_key from Multi-Repo Handling's grouping pattern (the raw `story.project` value being iterated) — the map is keyed by `project_path`/`group_key`, not by the resolved absolute path, exactly like `PROJECT_GUIDELINES_MAP[project_path]` above and the Report line below.

   Report:
   ```
   Container for [branchName] ready in project: [project_path] (CONTAINER_PATHS[project_path])
   ```

## Step 3: Check for Pending Stories

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI count-pending
```

If result is `0`:

**When `PHASE_MODE=true` and `$PHASE_ID` is set** (this session itself ran Step 1.7 — never true inside a Phase-Mode Paired Split sub-orchestrator, which never learns `$PHASE_ID`), release the claim first (see Release the Claim on Abort):

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
```

```
All stories already complete!

Run /aimi:review to review the implementation.
```
STOP execution.

### Validate Dependencies

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI validate-deps
```

If validation fails (non-zero exit), release the claim under the same phase-mode guard as above, report the error, and STOP:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
```
```
Dependency validation failed:
[error output]

Fix the dependency graph in the tasks file and re-run /aimi:execute.
```

Report start:
```
Starting autonomous execution...

Branch: [branchName]
Schema: v3.0
Pending: [pending] stories

Beginning wave execution loop...
```

## Step 3.1: Resolve Worktree Manager

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/cli-path-resolution.md` and follow the **Resolve Worktree Manager Path** section to set `$WORKTREE_MGR`.

If resolution fails, report error and STOP.

**`$WORKTREE_MGR` does not persist across Bash calls.** Re-read the cache at the top of every Bash call that uses it — see the **Per-Call Resolution** section of `commands/references/cli-path-resolution.md` for the one-liner and shell guard.

## Step 3.2: Read Concurrency Setting

Read the tasks file metadata to get maxConcurrency.

**Phase mode (`PHASE_MODE=true`):** re-run `init-session` with `--file "$PHASE_TASKS_PATH"` explicitly — not the bare form — so `maxConcurrency` is read from the claimed phase's own tasks file (see Concurrency Source in `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Phase Mode: Worktree Naming and CWD), not any feature-root or global file. The bare form would re-run `init-session`'s mtime-based auto-discovery and could silently re-point session state at a different, more-recently-touched sibling phase file:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI init-session --file "$PHASE_TASKS_PATH"
```

**Flat mode (`PHASE_MODE=false`):** unchanged — bare `init-session`:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI init-session
```

Parse `maxConcurrency` from metadata. If not set, default to `20`.

Store as `MAX_CONCURRENCY`.

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
VISUAL_GROUP_KEYS=$(jq -r '[.userStories[] | select(.verification | type == "object" and .strategy == "visual") | (.project // "DEFAULT")] | unique | .[]' "$AIMI_ROOT/$TASKS_PATH")
```

For each `group_key` in `VISUAL_GROUP_KEYS`, resolve its project root exactly as Multi-Repo Handling's grouping pattern does (`CWD`/`$AIMI_ROOT` for `"DEFAULT"`, otherwise `$AIMI_ROOT/[group_key]`):

```bash
BRANCH_NAME=$(jq -r '.metadata.branchName' "$AIMI_ROOT/$TASKS_PATH")
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

### Open Visual Follow Session

See the Visual Follow Lifecycle section for context (Phase 2 — Session Open).

If `VISUAL_FOLLOW=true`, open a persistent headed browser session before entering the wave loop:

```bash
command -v agent-browser
```

- **If `agent-browser` is not found:** Warn the user and fall back to headless mode:
  ```
  ⚠ agent-browser not installed. Falling back to headless mode — visual follow disabled.
  ```
  Set `VISUAL_FOLLOW=false`.

- **If `agent-browser` is available:** Get the verification URL from the first visual story. In phase mode, source it from `$PHASE_TASKS_PATH` — never the mtime-discovered `$TASKS_PATH` from Step 1, which (exactly like `FEATURE_TYPE` in Step 1.7) could belong to a different, more-recently-touched sibling phase file when several are materialized:

  ```bash
  if [ "$PHASE_MODE" = "true" ]; then
    VISUAL_SOURCE="$PHASE_TASKS_PATH"
  else
    VISUAL_SOURCE="$AIMI_ROOT/$TASKS_PATH"
  fi
  FIRST_VISUAL=$(jq -c '[.userStories[] | select(.verification | type == "object" and .strategy == "visual")][0]' "$VISUAL_SOURCE")
  VISUAL_URL=$(printf '%s' "$FIRST_VISUAL" | jq -r '.verification.url')
  VISUAL_GROUP_KEY=$(printf '%s' "$FIRST_VISUAL" | jq -r '.project // "DEFAULT"')
  ```

  **When `PHASE_MODE` is true** (the top-level single-file phase orchestrator, or a Phase-Mode Paired Split sub-orchestrator whose spawn prompt pre-set `PHASE_BRANCH`/`PHASE_CONTAINER_PATH` to its own split — see Spawn Split Sub-Orchestrators — so this branch applies unmodified in either case, keyed by whichever branch this session owns): read `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Rewrite a Verification URL Origin and apply it with `EXEC_ROOT="$AIMI_ROOT"` (the same CWD Phase Container Dev Server Bootstrap used for its own `serve start`), `EXEC_BRANCH="$PHASE_BRANCH"`, and `RAW_URL="$VISUAL_URL"` — never a value cached from Phase Container Dev Server Bootstrap or Split Container Dev Server Bootstrap earlier in this run, since each Bash call is an isolated shell (Step 0):

  ```bash
  WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
  : "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
  cd "$AIMI_ROOT"
  SERVE_URL_JSON=$($WORKTREE_MGR serve url "$PHASE_BRANCH" "$VISUAL_URL")
  VISUAL_URL=$(printf '%s' "$SERVE_URL_JSON" | jq -r '.url')
  ```

  `VISUAL_URL` is simply reassigned to `.url` either way — the reference's degrade-safely contract (never fails, falls back to the raw URL unchanged) applies here unconditionally, with no gating on `.rewritten`.

  **When `CONTAINER_MODE` is true and `CONTAINER_DEV_URL[VISUAL_GROUP_KEY]` resolved** (see Container Dev Server Bootstrap above; `PHASE_MODE` and `CONTAINER_MODE` are mutually exclusive — see Execution Mode Detection — so at most one of these two branches ever applies): apply the same reference section with `EXEC_BRANCH` = this run's `branchName`, scoped to the FIRST visual story's OWN project group. This resolves the port of that group only — a second visual story from a different project group is unaffected by this rewrite and is instead resolved independently at its own post-merge verification step (Step 4). `EXEC_ROOT` is the same project root Container Dev Server Bootstrap (Step 3.3) already used for `VISUAL_GROUP_KEY` — `$AIMI_ROOT` for `"DEFAULT"`, otherwise `$AIMI_ROOT/[VISUAL_GROUP_KEY]`:

  ```bash
  WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
  : "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
  BRANCH_NAME=$(jq -r '.metadata.branchName' "$AIMI_ROOT/$TASKS_PATH")
  if [ "[VISUAL_GROUP_KEY]" = "DEFAULT" ]; then
    cd "$AIMI_ROOT"
  else
    cd "$AIMI_ROOT/[VISUAL_GROUP_KEY]"
  fi
  SERVE_URL_JSON=$($WORKTREE_MGR serve url "$BRANCH_NAME" "$VISUAL_URL")
  VISUAL_URL=$(printf '%s' "$SERVE_URL_JSON" | jq -r '.url')
  ```

  **Otherwise** (neither phase mode nor container mode applies, or the relevant server's port never resolved): `VISUAL_URL` remains the raw `verification.url` — unchanged from today.

  ```bash
  agent-browser --headed --session visual-follow open "$VISUAL_URL"
  ```

## Step 4: Wave Execution Loop

```
wave = 1
is_first_story_in_session = true
DESIGN_REVIEW_BUFFERS = {}  # key: story_id, value: {title, output}; populated by post-merge design reviewer
CONSOLE_BUFFER = {}         # key: story_id, value: ATTRIBUTION object; populated by post-merge console capture (see Console Error Attribution section)

while true:
    # Check remaining work
    pending = $AIMI_CLI count-pending
    if pending == 0: break

    # Get ready stories (brief mode — returns {id, title, priority, dependsOn, project, gate} only)
    # NOTE: The CLI's list-ready already filters out:
    #   - Stories with pending decision gates (blocked before start)
    #   - Stories whose dependencies have pending action gates (blocked until gate resolved)
    ready_stories = $AIMI_CLI list-ready --brief
    if ready_stories is empty:
        if pending > 0:
            # ========================================
            # GATE-BLOCKED STORY DETECTION
            # ========================================
            # Before reporting deadlock, check if stories are blocked by gates.
            # Use $AIMI_CLI status to get all stories and identify gate-blocked ones.
            all_stories = $AIMI_CLI status
            decision_blocked = []  # stories with pending decision gates
            action_blocked = []    # stories whose dependencies have pending action gates

            for story in all_stories.userStories:
                if story.status == "pending":
                    # Check for pending decision gates on this story
                    if story.gate and story.gate.type == "decision" and story.gate.status == "pending":
                        decision_blocked.append(story)
                    # Check for pending action gates on dependencies
                    else if story.dependsOn:
                        for dep_id in story.dependsOn:
                            dep = find story with id == dep_id in all_stories.userStories
                            if dep.gate and dep.gate.type == "action" and dep.gate.status == "pending":
                                action_blocked.append(story)
                                break

            if len(decision_blocked) > 0 or len(action_blocked) > 0:
                Report: "No stories ready — blocked by gates:"
                for story in decision_blocked:
                    Report: "  Waiting for decision on [story.id]: [story.gate.prompt]"
                for story in action_blocked:
                    Report: "  [story.id] paused — dependency has pending action gate"
                Report: ""
                Report: "Use /aimi:status to see gate details. Resolve gates with:"
                Report: "  $AIMI_CLI gate-pass <story-id> [--option 'value']"
                Break loop (proceed to completion)
            else:
                Report: "Deadlock detected: [pending] stories pending but none are ready."
                Report: "This may indicate circular dependencies or all remaining stories depend on failed/skipped stories."
                Break loop (proceed to completion)
        else:
            break

    # Adaptive concurrency
    concurrency = min(len(ready_stories), MAX_CONCURRENCY)
    selected_stories = ready_stories[0:concurrency]

    Report:
    "--- Wave [wave] ---"
    "Executing [len(selected_stories)] stories"
    For each story: "  - [story.id]: [story.title]"

    # Mark all selected stories as in-progress
    for story in selected_stories:
        $AIMI_CLI mark-in-progress [story.id]

    # ========================================
    # WORKTREE WAVE (parallel with worktrees)
    # ========================================

    # All selected stories proceed — story data is fetched by each subagent via get-story-context
    full_stories = selected_stories

    # Proceed with worktree parallelism

    # ========================================
    # GROUP STORIES BY PROJECT — see Multi-Repo Handling section
    # ========================================

    project_groups = {}  # key: project_path (or "DEFAULT"), value: list of full_story
    for full_story in full_stories:
        if full_story.project is not null/absent:
            group_key = full_story.project
        else:
            group_key = "DEFAULT"
        project_groups[group_key].append(full_story)

    # Resolve absolute paths for each project group
    # AIMI_ROOT = directory containing .aimi/ (resolved during init-session)
    project_roots = {}  # key: group_key, value: absolute path to git root
    for group_key in project_groups:
        if group_key == "DEFAULT":
            project_roots[group_key] = CWD  (current working directory / git root)
        else:
            project_roots[group_key] = AIMI_ROOT / group_key  (resolve to absolute path)

    # ========================================
    # DERIVE EXEC_ROOT / EXEC_BRANCH PER PROJECT GROUP — see container-
    # execution.md's Execution Context: EXEC_ROOT, EXEC_BRANCH, EXEC_OWNS_ROOT,
    # EXEC_KEEPS_BRANCH. This is the only place in the wave loop
    # and its cleanup passes that checks PHASE_MODE/CONTAINER_MODE directly —
    # every consumer below reads EXEC_ROOT[group_key]/EXEC_BRANCH[group_key]
    # instead (project_roots itself still survives untouched for the four
    # consumers that need it independently of EXEC_ROOT — see that section).
    # ========================================
    EXEC_ROOT = {}    # key: group_key, value: path every git/worktree op targets
    EXEC_BRANCH = {}  # key: group_key, value: branch every git/worktree op targets
    for group_key in project_groups:
        if PHASE_MODE:
            EXEC_ROOT[group_key] = PHASE_CONTAINER_PATH
            EXEC_BRANCH[group_key] = PHASE_BRANCH
        elif CONTAINER_MODE:
            EXEC_ROOT[group_key] = CONTAINER_PATHS[group_key]
            EXEC_BRANCH[group_key] = branchName
        else:
            EXEC_ROOT[group_key] = project_roots[group_key]
            EXEC_BRANCH[group_key] = branchName
    EXEC_OWNS_ROOT = PHASE_MODE or CONTAINER_MODE    # single scalar, not a map
    EXEC_KEEPS_BRANCH = true                         # single scalar; no consumer reads it yet

    # ========================================
    # CAPTURE BASE SHA PER PROJECT GROUP (for commit verification)
    # ========================================
    base_sha = {}  # key: group_key, value: HEAD SHA before worktree creation
    for group_key in project_groups:
        base_sha[group_key] = git -C [EXEC_ROOT[group_key]] rev-parse [EXEC_BRANCH[group_key]]

    # ========================================
    # CREATE WORKTREES PER PROJECT GROUP
    # ========================================
    all_worktrees = {}  # key: full_story.id, value: {worktree_name, worktree_path, group_key}

    for group_key, stories in project_groups:
        worktree_cwd = EXEC_ROOT[group_key]
        worktree_base = EXEC_BRANCH[group_key]

        for full_story in stories:
            worktree_name = worktree_base + "-" + full_story.id

            # cd to this group's execution root (see Execution Context above)
            cd [worktree_cwd]
            $WORKTREE_MGR create [worktree_name] --from [worktree_base]

            worktree_path = [path from output]
            all_worktrees[full_story.id] = {
                worktree_name: worktree_name,
                worktree_path: worktree_path,
                group_key: group_key
            }

    # Spawn ALL workers as foreground Tasks in a SINGLE tool-call turn.
    # Claude Code runs multiple foreground Tasks concurrently and returns
    # all results before the agent's turn ends.
    #
    # IMPORTANT: subagent_type MUST be "general-purpose" — story-executor is a skill, NOT an agent.
    #
    # Template selection: full for first story in session, compact for subsequent.
    # In a multi-story wave, the first story uses full_template only if is_first_story_in_session
    # is true; all others in the wave use compact_template.
    # In one tool-call turn, emit N Task calls (across ALL project groups):
    story_index = 0
    for full_story in full_stories:
        wt = all_worktrees[full_story.id]
        project_path = project_roots[wt.group_key] if wt.group_key != "DEFAULT" else null
        project_guidelines = PROJECT_GUIDELINES_MAP[wt.group_key] if wt.group_key != "DEFAULT" else PROJECT_GUIDELINES

        template = full_template if (is_first_story_in_session and story_index == 0) else compact_template

        Task(
            subagent_type: "general-purpose",
            model: <AGENT_MODELS.executor when not "inherit">,
            description: "Execute [full_story.id]: [full_story.title]",
            prompt: [story-executor SKILL.md [template] with:
                - WORKTREE_PATH = wt.worktree_path
                - PROJECT_PATH = project_path (only include if non-null)
                - PROJECT_GUIDELINES = project_guidelines
                - HEADED_MODE = (do NOT include for worktree stories — visual verification runs post-merge, not inside the worktree)
                - Omit the <visual_verification> section entirely for worktree stories
                  (the dev server cannot see worktree changes; verification runs after merge-all instead)
                - STORY_ID = full_story.id  ← only the id; no description, no criteria, no prototype HTML
                - Do NOT modify the tasks.json file — report result (success/failure + details)
            ]
        )
        story_index += 1

    is_first_story_in_session = false

    # All Tasks return in the same turn. Collect results.
    failed_stories = []
    succeeded_stories = []
    result_payload_by_id = {}  # full_story.id → parsed result_json object

    # ========================================
    # PARSE WORKER RESULT_JSON BLOCK (per story-executor SKILL.md Result Contract)
    # ========================================
    # The orchestrator's source of truth is the <result_json>...</result_json>
    # block at the END of each worker's final message. Prose outside the block
    # is debugging only and is NOT consumed here.
    #
    # Extraction rule (regex): the LAST occurrence in the message of
    #   <result_json>\s*({.*?})\s*</result_json>   (DOTALL, non-greedy)
    # is parsed as JSON. If the block is malformed, missing, or fails to parse,
    # fall back to the legacy heuristic: Task's own exit signal (succeeded/failed)
    # + commit verification below.
    #
    # Reading the structured block keeps the next orchestrator turn's input
    # token cost down — empirically a worker returns ~600 tokens of prose where
    # the orchestrator only consumes ~50-200 tokens of structured signal.

    for each Task result:
        payload = parse_result_json(Task.final_message_text)  # see extraction rule above
        if payload is not None:
            result_payload_by_id[full_story.id] = payload
            status = payload.get("status")
            if status == "ok":
                succeeded_stories.append(full_story)
            else:
                failed_stories.append(full_story)
        else:
            # Legacy fallback: trust Task's own success/failure signal.
            # Log: "[full_story.id] missing or malformed <result_json> — falling back to Task exit signal"
            if Task succeeded:
                succeeded_stories.append(full_story)
            else:
                failed_stories.append(full_story)

    # --- Post-Wave Processing ---

    # ========================================
    # COMMIT VERIFICATION (parallel path)
    # ========================================
    # Prefer the commit SHA from result_payload_by_id[full_story.id].commit when
    # present and non-null — cross-check it against git rev-parse HEAD in the
    # worktree. Mismatch → treat as no-commit (worker lied or aborted post-emit).
    # When result_json is absent, fall back to the legacy "HEAD differs from
    # base_sha" check unchanged.
    no_commit_stories = []
    verified_stories = []
    for full_story in succeeded_stories:
        wt = all_worktrees[full_story.id]
        worktree_head = git -C [wt.worktree_path] rev-parse HEAD
        payload = result_payload_by_id.get(full_story.id)

        if payload is not None and payload.get("commit"):
            # Cross-check declared SHA against actual HEAD (short-SHA prefix match OK)
            declared = payload["commit"]
            if not worktree_head.startswith(declared) and declared != worktree_head:
                # Declared commit not at HEAD — treat as no-commit
                no_commit_stories.append(full_story)
                continue

        if worktree_head == base_sha[wt.group_key]:
            no_commit_stories.append(full_story)
        else:
            verified_stories.append(full_story)

    # Move no-commit stories to failed
    for full_story in no_commit_stories:
        $AIMI_CLI mark-failed [full_story.id] "No commit detected after execution"
        $AIMI_CLI cascade-skip [full_story.id]
        Report: "[full_story.id] failed (no commit detected). Dependent stories cascade-skipped."

    # Replace succeeded_stories with only verified ones (so merge-all skips no-commit stories)
    succeeded_stories = verified_stories

    # Handle failures first
    for full_story in failed_stories:
        # Prefer the structured failureCause over generic message when available
        payload = result_payload_by_id.get(full_story.id)
        cause = (payload.get("failureCause") if payload else None) or "Failed during parallel wave [wave]"
        $AIMI_CLI mark-failed [full_story.id] "[cause]"
        $AIMI_CLI cascade-skip [full_story.id]
        Report: "[full_story.id] failed: [cause]. Dependent stories cascade-skipped."

    # ========================================
    # MERGE PER PROJECT GROUP (not across repos)
    # ========================================
    # Merge successful worktrees grouped by project.
    # Each project group merges independently into its own repo's branch.

    if len(succeeded_stories) > 0:
        # Group succeeded stories by project
        succeeded_by_project = {}
        for full_story in succeeded_stories:
            group_key = all_worktrees[full_story.id].group_key
            succeeded_by_project[group_key].append(full_story)

        for group_key, stories in succeeded_by_project:
            merge_cwd = EXEC_ROOT[group_key]
            merge_target = EXEC_BRANCH[group_key]
            succeeded_worktree_names = [all_worktrees[s.id].worktree_name for s in stories]

            # cd to this group's execution root before merging (see container-
            # execution.md's Execution Context: EXEC_ROOT, EXEC_BRANCH,
            # EXEC_OWNS_ROOT, EXEC_KEEPS_BRANCH) -- merge-all issues a bare
            # `git checkout <target-branch>` against whatever repo its CWD belongs
            # to, so running it from AIMI_ROOT in phase mode would check the phase
            # branch out onto the main working tree, violating the Main Working
            # Tree Untouched Invariant.
            cd [merge_cwd]
            merge_result = $WORKTREE_MGR merge-all [succeeded_worktree_names...] --into [merge_target]

            if merge conflict (non-zero exit):
                Report:
                "MERGE CONFLICT during wave [wave] merge in project [group_key]."
                "Conflicting files:"
                "[conflict output from merge-all]"
                ""
                "Resolve the conflict on branch [merge_target] in [merge_cwd] and re-run `/aimi:execute` to continue."
                "[merge_cwd] itself — this group's execution root, whichever mode created it — and any live dev server running inside it are left untouched by this failure; only this wave's story worktrees (cleaned up below) are removed, so the conflict can be resolved directly in the still-live working tree."

                # Cleanup ALL worktrees from this wave (across all project groups) before stopping
                for full_story_id, wt in all_worktrees:
                    cd EXEC_ROOT[wt.group_key]
                    $WORKTREE_MGR remove [wt.worktree_name]

                # PHASE_MODE with PHASE_ID set (this session itself ran Step 1.7 --
                # never true inside a Phase-Mode Paired Split sub-orchestrator):
                # release the claim before stopping (see Release the Claim on Abort).
                if PHASE_MODE and PHASE_ID is set:
                    $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"

                STOP execution.

            # Merges succeeded for this project group — mark stories complete
            for full_story in stories:
                # --- Extract knownGaps: prefer result_json.knownGaps, fall back to commit trailers ---
                # When result_payload_by_id[full_story.id].knownGaps is a non-empty array,
                # use those entries (one line each). Otherwise, fall back to grepping
                # KNOWN-GAP: trailers from the commit body for backward compat.
                ```bash
                mkdir -p .aimi/known-gaps
                # Pseudo: prefer payload; fall back to commit grep
                payload_gaps="${result_payload_by_id[full_story.id].knownGaps or []}"
                if [ -n "$payload_gaps" ] && [ "$payload_gaps" != "[]" ]; then
                  WORKER_GAPS=$(printf '%s\n' "$payload_gaps")
                else
                  WORKER_GAPS=$(git -C "[all_worktrees[full_story.id].worktree_path]" log -1 --format=%B | grep -E '^KNOWN-GAP:' || true)
                fi
                if [ -n "$WORKER_GAPS" ]; then
                  GAP_DATE=$(date +%Y-%m-%d)
                  GAP_FILE=".aimi/known-gaps/${GAP_DATE}-[full_story.id].md"
                  printf '%s\n' "$WORKER_GAPS" > "$GAP_FILE"
                fi
                ```

                $AIMI_CLI mark-complete [full_story.id]

                # --- Post-merge visual verification for visual stories ---
                # Session lifecycle: see Visual Follow Lifecycle section.
                # Capture sequence per story (when agent-browser is available):
                #   1. console --clear  ← drop logs accumulated from PRIOR story in this wave
                #   2. open <url>       ← navigate
                #   3. screenshot       ← visual snapshot
                #   4. console --json   ← capture this story's console output
                #   5. errors  --json   ← capture this story's uncaught exceptions
                # Per-story attribution depends on the --clear in step 1 — without it,
                # console buffer is wave-cumulative and last-story-merged eats the blame.
                if full_story.verification and full_story.verification.strategy == "visual" and full_story.verification.status == "pending":
                    # --- Post-merge visual verification origin rewrite / degradation gate ---
                    # `group_key` is already in scope here from the enclosing "for
                    # group_key, stories in succeeded_by_project" loop above — this
                    # story's own project group. Discriminates on EXEC_OWNS_ROOT (see
                    # container-execution.md's Execution Context: EXEC_ROOT,
                    # EXEC_BRANCH, EXEC_OWNS_ROOT, EXEC_KEEPS_BRANCH) rather
                    # than checking PHASE_MODE/CONTAINER_MODE separately at this top
                    # level: false only for inline mode (no shared server exists to
                    # rewrite against), true for both phase and container mode, which
                    # keep their own distinct port-acquisition mechanisms below.
                    SKIP_VISUAL=false
                    if not EXEC_OWNS_ROOT:
                        # Inline mode — identical to today's inline branch: the
                        # story's own verification.url, no rewrite, no gate.
                        STORY_TASKS_FILE="$AIMI_ROOT/$TASKS_PATH"
                        STORY_VERIFICATION_URL=$(jq -r --arg id "[full_story.id]" '.userStories[] | select(.id == $id) | .verification.url // empty' "$STORY_TASKS_FILE")
                        EFFECTIVE_URL="$STORY_VERIFICATION_URL"
                    else:
                        # EXEC_OWNS_ROOT is true for both phase and container mode.
                        # PHASE_MODE is read here too, but only to pick between the
                        # two modes' own distinct port-acquisition mechanisms — never
                        # again as a top-level EXEC_ROOT/EXEC_BRANCH mode gate.
                        if PHASE_MODE:
                            # Apply container-execution.md's § Rewrite a Verification
                            # URL Origin with EXEC_ROOT="$AIMI_ROOT", EXEC_BRANCH=
                            # "$PHASE_BRANCH" — never a value cached from Phase/Split
                            # Container Dev Server Bootstrap or Step 3.3 earlier in
                            # this run. Inside a split sub-orchestrator, PHASE_BRANCH
                            # is already that split's own branch (see Spawn Split
                            # Sub-Orchestrators), so this applies unmodified one level
                            # deeper too.
                            ```bash
                            WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
                            : "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
                            cd "$AIMI_ROOT"
                            STORY_TASKS_FILE="$PHASE_TASKS_PATH"
                            STORY_VERIFICATION_URL=$(jq -r --arg id "[full_story.id]" '.userStories[] | select(.id == $id) | .verification.url // empty' "$STORY_TASKS_FILE")
                            SERVE_URL_JSON=$($WORKTREE_MGR serve url "$PHASE_BRANCH" "$STORY_VERIFICATION_URL")
                            REWRITTEN=$(printf '%s' "$SERVE_URL_JSON" | jq -r '.rewritten')
                            EFFECTIVE_URL=$(printf '%s' "$SERVE_URL_JSON" | jq -r '.url')
                            ```
                            if REWRITTEN != "true":
                                # No dev server running for this phase's (or split's) own
                                # branch. Degrade to skipped — this is also the expected,
                                # non-bug outcome for a full-stack split story whose page
                                # depends on the sibling split's API (no proxy exists between
                                # the two split servers — see Split Container Dev Server
                                # Bootstrap). mark-complete already ran above; this never
                                # blocks it, never blocks the wave, and never retries.
                                $AIMI_CLI update-field [full_story.id] verification.status skipped
                                Report: "[full_story.id] visual verification skipped — no dev server running for [PHASE_BRANCH]."
                                SKIP_VISUAL=true
                        else:
                            # CONTAINER_MODE — EXEC_OWNS_ROOT is true and PHASE_MODE is
                            # false, so this is the only remaining case. Gates on the
                            # Step 3.3 cache before applying container-execution.md's
                            # § Rewrite a Verification URL Origin, keyed by this story's
                            # own project group.
                            if group_key not in CONTAINER_DEV_URL:
                                # No dev server ever resolved a port for this group (see Container
                                # Dev Server Bootstrap in Step 3.3) — degrade to skipped. mark-complete
                                # already ran above; this never blocks it or the wave loop.
                                $AIMI_CLI update-field [full_story.id] verification.status skipped
                                Report: "[full_story.id] visual verification skipped — no dev server resolved for project group [group_key]."
                                SKIP_VISUAL=true
                            else:
                                ```bash
                                WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
                                : "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
                                BRANCH_NAME=$(jq -r '.metadata.branchName' "$AIMI_ROOT/$TASKS_PATH")
                                if [ "[group_key]" = "DEFAULT" ]; then
                                  cd "$AIMI_ROOT"
                                else
                                  cd "$AIMI_ROOT/[group_key]"
                                fi
                                STORY_TASKS_FILE="$AIMI_ROOT/$TASKS_PATH"
                                STORY_VERIFICATION_URL=$(jq -r --arg id "[full_story.id]" '.userStories[] | select(.id == $id) | .verification.url // empty' "$STORY_TASKS_FILE")
                                SERVE_URL_JSON=$($WORKTREE_MGR serve url "$BRANCH_NAME" "$STORY_VERIFICATION_URL")
                                EFFECTIVE_URL=$(printf '%s' "$SERVE_URL_JSON" | jq -r '.url')
                                ```

                    if not SKIP_VISUAL:

                        if VISUAL_FOLLOW == true:
                            # Reuse the existing headed session (managed by execute.md)
                            agent-browser --session visual-follow console --clear
                            agent-browser --session visual-follow open [EFFECTIVE_URL]
                            agent-browser --session visual-follow screenshot /tmp/verify-[full_story.id].png
                            CONSOLE_JSON=$(agent-browser --session visual-follow console --json)
                            ERRORS_JSON=$(agent-browser --session visual-follow errors --json)
                            # Read screenshot and compare against full_story.verification.expect
                            Read /tmp/verify-[full_story.id].png
                            Compare visual output against full_story.verification.expect

                            # Run console attribution pass (see "Console Error Attribution" section below)
                            ATTRIBUTION = attribute_console_errors(
                                console_json=CONSOLE_JSON,
                                errors_json=ERRORS_JSON,
                                wave_stories=succeeded_stories
                            )

                            if visual matches expectations:
                                $AIMI_CLI update-field [full_story.id] verification.status passed
                                Report: "[full_story.id] visual verification passed."
                            else:
                                $AIMI_CLI update-field [full_story.id] verification.status failed
                                Report: "[full_story.id] visual verification failed — [reason]. (advisory, not blocking)"

                            # Report attribution lines as advisory (do NOT toggle verification.status)
                            if ATTRIBUTION.has_errors:
                                Report: "[full_story.id] console: \(ATTRIBUTION.summary)"
                                # Push attribution into wave-level CONSOLE_BUFFER for the wave summary
                                CONSOLE_BUFFER[full_story.id] = ATTRIBUTION
                        else:
                            # No visual-follow session — headless verification
                            has_browser = command -v agent-browser
                            if has_browser:
                                agent-browser console --clear
                                agent-browser open [EFFECTIVE_URL]
                                agent-browser screenshot /tmp/verify-[full_story.id].png
                                CONSOLE_JSON=$(agent-browser console --json)
                                ERRORS_JSON=$(agent-browser errors --json)
                                Read /tmp/verify-[full_story.id].png
                                Compare visual output against full_story.verification.expect

                                ATTRIBUTION = attribute_console_errors(
                                    console_json=CONSOLE_JSON,
                                    errors_json=ERRORS_JSON,
                                    wave_stories=succeeded_stories
                                )

                                if visual matches expectations:
                                    $AIMI_CLI update-field [full_story.id] verification.status passed
                                else:
                                    $AIMI_CLI update-field [full_story.id] verification.status failed
                                    Report: "[full_story.id] visual verification failed — [reason]. (advisory)"

                                if ATTRIBUTION.has_errors:
                                    Report: "[full_story.id] console: \(ATTRIBUTION.summary)"
                                    CONSOLE_BUFFER[full_story.id] = ATTRIBUTION

                                agent-browser close
                            else:
                                $AIMI_CLI update-field [full_story.id] verification.status skipped
                                Report: "[full_story.id] visual verification skipped — agent-browser not installed."

                # Non-visual stories: keep existing behavior
                elif full_story.verification and full_story.verification.status == "pending":
                    $AIMI_CLI update-field [full_story.id] verification.status passed

                Report: "[full_story.id] merged successfully."

                # --- Design Review (visual stories only) ---
                if full_story.verification and full_story.verification.strategy == "visual" and (metadata.prototypePaths is non-empty or full_story.implementation.prototypeAnchor is non-empty):
                    # 1. Resolve prototype path: prefer prototypeAnchor, fall back to metadata.prototypePaths[0]
                    REVIEW_PROTOTYPE_PATH = full_story.implementation.prototypeAnchor
                    if REVIEW_PROTOTYPE_PATH is empty:
                        REVIEW_PROTOTYPE_PATH = metadata.prototypePaths[0] (if the array is non-empty)

                    if REVIEW_PROTOTYPE_PATH is empty:
                        Report: "Design review skipped for [full_story.id] — no prototype available."
                    else:
                        # 2. Collect changed files from the worker's commit
                        ```bash
                        DESIGN_REVIEW_CHANGED_FILES=$(git -C "[all_worktrees[full_story.id].worktree_path]" show --name-only --pretty=format: HEAD | grep -v '^$')
                        ```

                        # 3. Spawn the reviewer in foreground (capture output)
                        DESIGN_REVIEW_OUTPUT = Task(
                            subagent_type: "aimi-engineering:design:aimi-design-implementation-reviewer",
                            model: <AGENT_MODELS.design when not "inherit">,
                            description: "Design review: [full_story.id]",
                            prompt: "Review the implementation of [full_story.id] ([full_story.title]).

Prototype: [REVIEW_PROTOTYPE_PATH]
Changed files:
[DESIGN_REVIEW_CHANGED_FILES]
Worktree: [all_worktrees[full_story.id].worktree_path]

Read the prototype file at the path above. Compare each visual element of the prototype against the changed files listed. Report PASS / DIVERGES / KNOWN-GAP verdicts with a brief diagnosis per element.

Output your full structured review under the heading '## Design Implementation Review'."
                        )

                        # 4. Store per-story buffer for Step 5 aggregation
                        DESIGN_REVIEW_BUFFERS[full_story.id] = {
                            title: full_story.title,
                            output: DESIGN_REVIEW_OUTPUT
                        }

                # Post-completion gate logging
                if full_story.gate:
                    if full_story.gate.type == "action" and full_story.gate.status == "pending":
                        Report: "Action required for [full_story.id]: [full_story.gate.prompt]"
                        Report: "  Dependents will wait until gate is resolved."
                    if full_story.gate.type == "verify" and full_story.gate.status == "pending":
                        Report: "Verification pending for [full_story.id]: [full_story.gate.prompt]"
                        Report: "  Dependents proceed immediately (non-blocking)."

    # Remove all worktrees from this wave (per project group, EXEC_ROOT[wt.group_key]
    # — see container-execution.md's Execution Context: EXEC_ROOT, EXEC_BRANCH,
    # EXEC_OWNS_ROOT, EXEC_KEEPS_BRANCH). Branch deletion
    # here is unconditional in every mode (no --keep-branch) — container mode's
    # own teardown (outline:08) is the only removal call that preserves branchName.
    for full_story_id, wt in all_worktrees:
        cd EXEC_ROOT[wt.group_key]
        $WORKTREE_MGR remove [wt.worktree_name]

    # Count gate statuses for wave summary
    action_gates = [s for s in succeeded_stories if s.gate and s.gate.type == "action" and s.gate.status == "pending"]
    verify_gates = [s for s in succeeded_stories if s.gate and s.gate.type == "verify" and s.gate.status == "pending"]

    wave_summary = "Wave [wave] complete: [len(succeeded_stories)] succeeded, [len(failed_stories)] failed"
    if len(action_gates) > 0:
        wave_summary += ", [len(action_gates)] action gate(s) pending"
    if len(verify_gates) > 0:
        wave_summary += ", [len(verify_gates)] verify gate(s) pending"
    Report: wave_summary
    wave += 1
```

### Post-Loop Cleanup

After the wave loop ends (all stories processed or deadlock):

**Phase and container mode (`EXEC_OWNS_ROOT=true`):** cleanup runs per project group with CWD = `EXEC_ROOT[group_key]`, matching worktrees named `"[EXEC_BRANCH[group_key]]-US-*"` — the same derivation rule as `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md`'s Execution Context: EXEC_ROOT, EXEC_BRANCH, EXEC_OWNS_ROOT, EXEC_KEEPS_BRANCH subsection (`PHASE_CONTAINER_PATH`/`PHASE_BRANCH` in phase mode, `CONTAINER_PATHS[group_key]`/`branchName` in container mode). Step 4's own wave loop rebuilds `EXEC_ROOT`/`EXEC_BRANCH` fresh each wave, scoped to that wave's own stories; Post-Loop Cleanup runs after the loop ends, so it re-derives them here across every unique `group_key` with at least one story scheduled this run, rather than reading a stale, single-wave-scoped copy. In phase mode every `group_key` resolves to the same `PHASE_CONTAINER_PATH`/`PHASE_BRANCH` — in the common case of a single group_key this degenerates to exactly the single iteration today's phase-only cleanup already runs; on the rarer phase-mode wave that grouped stories under more than one `group_key`, the loop below repeats that same pass once per group_key, each an idempotent no-op against the worktrees the first pass already swept, never a different path or branch. The main working tree (`AIMI_ROOT`) is never `cd`'d into by this step.

```
for each unique group_key with at least one story scheduled this run:
    cd [EXEC_ROOT[group_key]]
    $WORKTREE_MGR list
    # For each worktree matching "[EXEC_BRANCH[group_key]]-US-*":
    $WORKTREE_MGR remove [worktree_name]
```

**One-time migration safeguard (flat/container mode only):** additionally run one sweep pass per project group with CWD = `[project_root]` itself — the pre-upgrade, un-containerized location — scanning the same `"[branchName]-US-*"` pattern:

```
for each unique project_root (including CWD for the DEFAULT group):
    cd [project_root]
    $WORKTREE_MGR list
    # For each worktree matching "[branchName]-US-*":
    $WORKTREE_MGR remove [worktree_name]
```

Once this step's container-mode branch scans only `CONTAINER_PATHS[group_key]`, a story worktree stranded directly under `project_root/.worktrees/` by an execution from before container mode shipped would otherwise never be swept by either cleanup pass again. This extra pass closes that gap; it is a no-op once no such pre-upgrade worktrees remain.

**Removal marker:** this safeguard exists only to catch worktrees stranded by runs that predate container mode (introduced in 1.105.0). Delete this subsection outright once the plugin reaches **1.110.0** — five minor releases is enough runway for any pre-existing stray worktrees to have been swept, and an unbounded extra list-and-parse pass per project group on every future run stops paying for itself after that.

**Flat/inline mode (`PHASE_MODE=false`, `CONTAINER_MODE=false`):** unchanged.

```
# Remove any remaining worktrees (safety cleanup)
# Per-project cleanup rule — see Multi-Repo Handling section.
for each unique project_root (including CWD for DEFAULT group):
    cd [project_root]
    $WORKTREE_MGR list
    # For each worktree matching "[branchName]-US-*":
    $WORKTREE_MGR remove [worktree_name]

# When no stories have project fields, use current directory (backwards compatible):
$WORKTREE_MGR list
# For each worktree matching "[branchName]-US-*":
$WORKTREE_MGR remove [worktree_name]
```

### Visual Follow Session — Keep Open

See the Visual Follow Lifecycle section (Phase 4 — Keep Open on Completion).

If `VISUAL_FOLLOW=true`, do NOT close the `visual-follow` session.

Report: `"Visual follow session still open — close manually when done: agent-browser --session visual-follow close"`

## Console Error Attribution

Defines `attribute_console_errors()`, called by the per-story post-merge visual verification step above. Pure orchestrator-side reasoning — no new CLI calls, no new subagents. Adds ≤ 1 turn of orchestrator inference per wave (typically far less because most stories have 0 errors).

### Inputs

- `console_json` — JSON returned by `agent-browser console --json` for this story's verification page-load. Shape: `{"data":{"messages":[{"type":"log|warning|error|info","text":"...","args":[...]}]}}`. Messages with `type == "error"` and `type == "warning"` are the only ones considered; `log` / `info` are ignored.
- `errors_json` — JSON from `agent-browser errors --json`. Uncaught exceptions and unhandled promise rejections. Shape: `{"data":{"errors":[{"message":"...","stack":"..."}]}}`.
- `wave_stories` — the wave's `succeeded_stories` array, each carrying `id`, `title`, and `implementation.files[]`.

### Procedure

1. **Merge** the `messages` (filtered to type `error`/`warning`) and `errors` arrays into a flat list of `{kind, text, stack}` records where `kind ∈ {error, warning, exception}`.
2. **Drop the noise** — ignore well-known browser/extension noise that does not indicate code defects:
   - Lines matching `/extension:|chrome-extension:|moz-extension:/`
   - Lines matching `/DevTools failed to load source map/`
   - Lines matching `/Download the React DevTools/`
   - Lines whose `text` is empty after trim
3. **For each remaining record, attribute** by trying these strategies in order; first match wins, no fallthrough:
   - **a. Stack-trace file match**: parse `stack` for tokens that look like project paths (anything matching `/[A-Za-z0-9_./-]+\.(tsx?|jsx?|vue|svelte|rb|py|go|rs|java|kt)/`). For each path token, check whether it appears in any `wave_stories[*].implementation.files[]`. First story whose `files[]` contains the token → attributed.
   - **b. Text component-name match**: when no stack-trace match, scan the `text` for `PascalCase` identifiers (`/\b[A-Z][a-zA-Z0-9]+\b/`). For each, check whether any `wave_stories[*].implementation.files[]` contains a path with that identifier as a basename component (e.g., text mentions `ContributorsCard` → match story with `…/ContributorsCard/index.tsx`). First match → attributed.
   - **c. Wave-shared**: when neither matches, attribute to the wave as a whole with reason `"shared module or ambiguous origin"`.
4. **Build the `ATTRIBUTION` object**:
   ```
   ATTRIBUTION = {
     has_errors: <bool — true when any error|exception remains after de-noising>,
     summary: <one-line string: e.g., "2 errors, 1 warning (1 attributed: US-003)"
              when this is the per-story output; or "2 errors, 1 warning, 1 wave-shared">,
     attributed: [{kind, text, story_id, attribution_method: "stack-file"|"text-component"|"wave-shared"}],
   }
   ```
5. **Per-story output** (when called from the post-merge step):
   - Filter `attributed` to entries where `story_id == full_story.id` for the `Report` line.
   - Push the full per-story attribution object into `CONSOLE_BUFFER[full_story.id]` so the wave summary can emit a consolidated view.

### Confidence and policy

- Attribution is **advisory only**. It NEVER toggles `verification.status` and NEVER triggers a cascade-skip. A failed visual story stays failed only when the screenshot does not match `verification.expect` — console errors are reported in parallel.
- When attribution method is `text-component` or `wave-shared`, the report line MUST include the word "likely" (e.g., `"likely US-004 (FooComponent ref)"`) so the user knows it is heuristic.

### Wave summary section (rendered at end of wave)

After the per-story post-merge loop finishes, if `CONSOLE_BUFFER` has any entries for the wave just completed, append to the wave summary report:

```
Console (advisory):
  - US-003: 2 errors (attributed via stack: ContributorsCard/index.tsx)
  - US-005: 1 error (likely from text match: UserProfile)
  - wave-shared: 1 warning (could not attribute to a single story)
```

This is ADDITIVE to the existing `Wave [wave] complete: ...` line — does not replace it.

## Phase Completion

Runs once, and before Step 5. Its trigger point depends on whether this phase used a full-stack split:

- **Single-file phase (`PHASE_SPLIT_MODE=false`, unchanged):** immediately after Post-Loop Cleanup and the Visual Follow Session note above.
- **Full-stack split phase (`PHASE_SPLIT_MODE=true`):** from Phase-Mode Paired Split's **Continue to Phase Completion** step, after **every** split sub-orchestrator has returned (`PHASE_ACTIVE_COUNT` of them, for any N — not a fixed two), all their branches have been merged into `$PHASE_BRANCH` in the single `merge-all` call, and all their worktrees have been cleaned up.

It fires only when **both** are true:

- `PHASE_MODE == true` (see Phase Mode Detection in Step 1)
- the phase's own pending count is zero — see **Multi-File Pending Count** immediately below for how this is computed; when it is greater than 0, the wave loop (or, in split mode, one or more of the sub-orchestrators) broke on deadlock or a gate-blocked wave, not true completion — release the claim (see Release the Claim on Abort; this section runs only in the top-level orchestrator that itself claimed the phase, so `$PHASE_ID` is always set here) and skip this entire section, going straight to Step 5 (single-file) or the Aggregated Completion Report (split mode, already produced by Phase-Mode Paired Split before this section was reached):

  ```bash
  AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
  : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
  $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
  ```

### Multi-File Pending Count

**When `PHASE_SPLIT_MODE=false` (unchanged):**
```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI count-pending
```
(`count-pending` reads the session's tracked tasks file, which Step 1.7 already repointed at `PHASE_TASKS_PATH`.)

**When `PHASE_SPLIT_MODE=true`:** `count-pending`'s session-state read does not apply — Step 1.7's Detect a Full-Stack Split Inside This Phase step never pointed this session's state at a single governing file, because a split phase has none. Sum pending stories across **every** member of the split directly, by path, instead — a loop over `$PHASE_SPLIT_FILES` (the full member list resolved in Step 1.7, not just the active subset), never a fixed pair of named variables:
```bash
PHASE_PENDING=0
while IFS= read -r split_file; do
  [ -n "$split_file" ] || continue
  SPLIT_FILE_PENDING=$(jq '[.userStories[]? | select((.status // "pending") != "completed")] | length' "$split_file")
  PHASE_PENDING=$((PHASE_PENDING + ${SPLIT_FILE_PENDING:-0}))
done <<< "$PHASE_SPLIT_FILES"
```
The phase's split work only counts as complete when `PHASE_PENDING` is `0` — i.e. **every** member reports zero outstanding stories, not just the first two. Summing over the full member list rather than `$PHASE_ACTIVE_SPLIT_FILES` is deliberate: a member skipped as inactive contributes `0` either way, but reading the full list keeps this count correct even if a sibling session touched a member between Step 1.7's filter and now.

The predicate is `(.status // "pending") != "completed"` — **not** `.status == "pending"` — so that this count and Step 1.7's **Active Split Files** filter answer the same question over the same file. The two must agree: Active Split Files decides which members get spawned, and this count decides whether the phase may close. Counting only `"pending"` here would treat `in_progress` (and any status a future story adds, and a story with no `status` field at all) as finished, letting a phase reach `roadmap-set-status --status completed` with a story still mid-flight — while Active Split Files, using `!= "completed"`, would have kept that same member active. `completed` is the only terminal status, so testing against it directly is what makes both sites correct by the same rule instead of by two lists of non-terminal statuses that can drift apart.

**For legacy flat v3.3 tasks.json files (`PHASE_MODE=false`): skip this entire section.** Step 5 runs completely unchanged only for inline-mode executions (`CONTAINER_MODE=false`, the default) — exactly as it does today. Container-mode flat executions (`CONTAINER_MODE=true`, still `PHASE_MODE=false`) also skip this Phase Completion section — a claimed phase's own container is a separate concept from a flat container-mode container — but Step 5 itself runs an additional completion path for them; see the CONTAINER_MODE scope note under Step 5: Completion below.

Every Bash call in this section that touches the phase container's git state or filesystem passes `$PHASE_CONTAINER_PATH` explicitly (`cd "$PHASE_CONTAINER_PATH"`, `git -C "$PHASE_CONTAINER_PATH"`, or an absolute path built from it) — never a bare relative path, and never anything derived from `find_aimi_root()`'s own CWD. `find_aimi_root()` (invoked internally by every `$AIMI_CLI` call) `cd`s to `PROJECT_ROOT` — the *main* repo root — as a side effect, so by the time any code here runs, CWD cannot be trusted to be `PHASE_CONTAINER_PATH`. This is the same rule Step 1.7's Path and State Notes already established for the rest of phase mode.

Fetch the claimed phase's roadmap object once, reused by every subsection below:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
PHASE_JSON=$($AIMI_CLI roadmap-get --feature "$FEATURE" --phase "$PHASE_ID")
PHASE_NAME=$(printf '%s' "$PHASE_JSON" | jq -r '.name')
```

### Creates Verification

For every entry the phase declared in `roadmap.json`'s `creates[]`, confirm the artifact is actually present in the phase branch's code — not merely that some other phase's `needs` resolved against it. This is a distinct, stricter check than `validate-contracts`: `validate-contracts` (outline 03) answers "does a `needs` entry have a completed, handoff-documented provider," using `roadmap.json` and `handoff.md` as its only inputs, and never inspects source code. This check answers "does this phase's own promised artifact exist," by inspecting the phase container's actual tracked files.

**Split-mode timing (`PHASE_SPLIT_MODE=true`):** this check always runs against `$PHASE_CONTAINER_PATH`'s tracked files, unchanged — but by the time this section is reached in split mode, Phase-Mode Paired Split's Merge Split Branches Into the Phase Branch step has already landed **all N** of this phase's active split branches onto `$PHASE_BRANCH` in a single `merge-all` call, so `$PHASE_CONTAINER_PATH`'s checkout already reflects every split's combined work. This check therefore verifies the merged phase branch state as a natural consequence of running after that merge — never any one split branch in isolation — with no special-casing needed in the procedure below, and no dependence on how many splits there were.

> **Cross-story flag for the auditor:** this story's brief describes creates verification as invoking "the outline:03 contract-validation CLI surface... in its phase-closure mode" (e.g. `validate-contracts <phase-id> --root <path>`) as an illustrative example. The landed `validate-contracts` (outline 03) has no `--root` flag or code-existence mode, and its own notes scope it exclusively to needs-vs-creates delivery resolution ("wiring validate-contracts and roadmap-sweep into plan.md and execute.md is owned by outline 08 and outline 11" — this story). Extending `validate-contracts`'s jq-only, roadmap.json-only logic to also grep real source files would be new scope outline 03 never claimed. Creates verification therefore ships as **its own CLI verb, `verify-creates`** — not as an extension of `validate-contracts`, and no longer as executable prose here. It was prose until this section was rewritten: five hand-written steps built on `[ -f ]` and a bare `git grep -l -F`, which no Bash suite could reach and which was wrong in five of nine measured scenarios (a docs-only mention, a `TODO` comment and a test-file mention each closed a phase; a directory identity could never verify, because `[ -f ]` is false on a directory; and a project that committed its own `.aimi/` found the identity inside the very `roadmap.json` that declared it). Reconcile if a future story wants to fold `verify-creates` into `validate-contracts` instead.

#### Inputs

- `FEATURE` and `PHASE_ID` — the claimed phase. The verb reads that phase's `creates[]` out of `roadmap.json` itself, applying the one existing identity definition (`_cv_identity`: the substring before the first `(`, trimmed), so no `creates` array is extracted here and no second copy of that rule exists in this file.
- `PHASE_CONTAINER_PATH` — from Step 1.7, absolute, never CWD-derived. Passed as `--dir`; it is the checkout whose **tracked** files are searched.

#### Procedure

Exactly one call. `verify-creates` (`cmd_verify_creates` in `aimi-cli.sh`) runs four deterministic steps per `creates[]` entry — a tracked-path match via `git ls-files`, which matches a **directory** as well as a file; leading-HTTP-method extraction, so `POST /api/notifications` is searched as `/api/notifications`, which is what route code actually contains; a `git grep -n -I -F` over tracked source that excludes documentation, tests and `.aimi/`; and a filter that drops hits which are only a `TODO`/`FIXME`/`XXX`/`HACK` comment. Identity kinds are not dispatched on: every identity runs the same four steps.

It is a **query, not a gate** — any verdict array exits `0`, including one where every entry is `missing` — so branch on the JSON below, never on a `missing` verdict having "failed". A non-zero exit means the verb could not run at all (unknown flag, absent or malformed `roadmap.json`, a `--dir` that is not a directory) and its stderr says which.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
CREATES_REPORT=$($AIMI_CLI verify-creates --feature "$FEATURE" --phase "$PHASE_ID" --dir "$PHASE_CONTAINER_PATH")
CREATES_EXIT=$?
if [ "$CREATES_EXIT" -ne 0 ]; then CREATES_REPORT='[]'; fi
VERIFIED_ARTIFACTS=$(printf '%s' "$CREATES_REPORT" | jq -r '.[] | select(.status == "verified") | "\(.identity) — \(.evidence)"')
MISSING_CREATES=$(printf '%s' "$CREATES_REPORT" | jq -r '.[] | select(.status == "missing") | "\(.identity) — \(.evidence)"')
ERROR_CREATES=$(printf '%s' "$CREATES_REPORT" | jq -r '.[] | select(.status == "error") | "\(.identity) — \(.evidence) [git exit \(.gitStatus)]"')
MISSING_COUNT=$(printf '%s' "$CREATES_REPORT" | jq '[.[] | select(.status == "missing")] | length')
ERROR_COUNT=$(printf '%s' "$CREATES_REPORT" | jq '[.[] | select(.status == "error")] | length')
printf 'verify-creates exit=%s missing=%s error=%s\n' "$CREATES_EXIT" "$MISSING_COUNT" "$ERROR_COUNT"
printf -- '--- verified ---\n%s\n--- missing ---\n%s\n--- tooling errors ---\n%s\n' "$VERIFIED_ARTIFACTS" "$MISSING_CREATES" "$ERROR_CREATES"
```

Every list is derived from that one result with a `jq` select on `.status`, inside the same block that assigns it — jq is the loop, deliberately instead of a shell `while` that accumulates a variable read after the loop has closed (`test-command-blocks.sh` check 3 catches exactly that shape). Each verdict object is `{identity, status, method, evidence, gitStatus}`: `status` is `verified` | `missing` | `error`, `method` is `"path"` | `"text"` | `null`, and `evidence` names the tracked path or `file:line` that decided it — or, on a `missing`, what was found and rejected.

`VERIFIED_ARTIFACTS` keeps its line shape `"<identity> — <location>"`, identity verbatim and first, one line per verified entry in `creates[]` order, with the verb's `evidence` string as the location (`tracked path: db/migrations`, `tracked source: src/routes/notifications.ts:14`). Identity-first is load-bearing, not cosmetic: this list becomes handoff.md's `## Artifacts Created`, which `_cv_handoff_lists_artifact` substring-matches with `grep -qF` to resolve a downstream phase's `needs`.

#### Which branch to take

`status: "error"` is **git failing**, not an artifact failing to exist — and a non-zero `CREATES_EXIT` is the same class one level up: the verb never ran. Both decide the branch **before** `MISSING_COUNT` does:

- `CREATES_EXIT` non-zero **or** `ERROR_COUNT > 0` → **Verification tooling failed** below. No status transition.
- otherwise `MISSING_COUNT > 0` → **On any missing entry** below. `verification_failed`.
- otherwise → **Write Handoff**.

Error entries are already absent from `MISSING_CREATES` and from `MISSING_COUNT` — both select on `.status == "missing"` — so a tool failure can never be counted or reported as an undelivered artifact.

#### Verification tooling failed

The phase's status is left exactly where it already was (`in_progress`) — do **not** call `roadmap-set-status`. Release the claim only (see Release the Claim on Abort), the same shape the handoff-write-failure path below uses, because `in_progress` is re-claimable once unclaimed:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
```

Transitioning to `verification_failed` here would tell the user their phase failed to deliver when the tool is what failed — and would block next-phase planning on evidence that was never gathered.

Report:
```
## Phase [PHASE_ID] Creates Verification Could Not Run

Verification tooling failed: git broke. This is NOT a finding that the phase
failed to deliver — nothing was proven either way.

[if CREATES_EXIT != 0:]
verify-creates itself exited [CREATES_EXIT] and produced no verdicts. Its stderr
above names the cause (unknown flag, absent or malformed roadmap.json, or a
--dir that is not a directory).

[if ERROR_COUNT > 0:]
[ERROR_COUNT] creates entr(y|ies) could not be checked because git exited above 1:

[for each line of ERROR_CREATES:]
  - [line]

Phase status is unchanged (in_progress) and the claim is released. Nothing was
marked verification_failed, because a broken tool is not a missing artifact.
Fix git in [PHASE_CONTAINER_PATH], then re-run /aimi:execute — creates
verification re-runs from scratch on the next pass.

[if MISSING_COUNT > 0:]
[MISSING_COUNT] further entr(y|ies) came back missing on this same run. They are
reported as unconfirmed rather than failed, because a run in which git broke is
not a run whose other verdicts can be trusted, and they are re-checked next pass.
```

Do **not** write `handoff.md`, do **not** offer a PR, do **not** run the Next Phase step below. Skip directly to Step 5.

#### On any missing entry

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI roadmap-set-status --feature "$FEATURE" --phase "$PHASE_ID" --status verification_failed
$AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
```

Release the claim (see Release the Claim on Abort) right after the status transition above — `verification_failed` is one of the statuses `roadmap-claim`'s auto-mode branch treats as re-claimable once unclaimed, so releasing here is what lets "re-run `/aimi:execute` to re-verify" below actually work on the next attempt, self-session or otherwise.

Report — print each missing line **with the evidence `verify-creates` returned for it**, verbatim. That evidence is the difference between "this name appears nowhere" and "this name appears only in prose", and the user cannot tell those apart from a bare "not found under [PHASE_CONTAINER_PATH]":
```
## Phase [PHASE_ID] Verification Failed

[MISSING_COUNT] declared creates entr(y|ies) could not be confirmed in the phase branch:

[for each line of MISSING_CREATES:]
  - [line]

Each line carries what was searched and, when something was found, the file and
line that was found and rejected. "Found and rejected ... documentation or test
path" means the name exists only in prose or in a test — a mention of the work,
not the work. "Found and rejected ... TODO/FIXME marker comment" means the code
says the work is still owed.

git ls-files and git grep see tracked (committed) files only, so work that is
written but committed nowhere reads as missing here. If that is what happened,
commit it on branch [PHASE_BRANCH] and re-run to re-verify — nothing else is
needed.

Phase status set to verification_failed. Fix the missing artifact(s) on branch
[PHASE_BRANCH], then re-run /aimi:execute to re-verify — creates verification
re-runs from scratch on the next pass. Next-phase planning stays blocked
until this phase re-verifies successfully (verification_failed is excluded
from next-eligible-phase selection, the same way pending/in_progress are).
```

Do **not** write `handoff.md`, do **not** offer a PR, do **not** run the Next Phase step below. Skip directly to Step 5 (which still reports this phase's own story-level completion, unaffected by the roadmap-level failure).

### Write Handoff

Only reached when `verify-creates` exited 0 and returned neither a `missing` nor an `error` entry — i.e. every `creates` entry verified. Build the five-section payload:

- **Decisions Made** — one bullet per notable implementation decision surfaced by this phase's stories (their `implementation.approach` text, gate resolutions, or explicit deviations the story-executor agents reported). Empty array if nothing stood out.
- **Artifacts Created** — exactly `VERIFIED_ARTIFACTS` from Creates Verification above, unmodified. This is the section `validate-contracts`'s `_cv_handoff_lists_artifact` searches when a downstream phase's `needs` references this phase — every identity must appear verbatim.
- **Deviations** — one bullet per `.aimi/known-gaps/*.md` file belonging to this phase's stories (same source Step 5's "Known Gaps" aggregation reads), summarizing the story id and gap. Empty array if none.
- **Deferred Items** — one bullet per this phase's own story left in `skipped` status, if any. Empty array if none.
- **Contracts Delivered** — one bullet per `creates` entry restating the identity now available to dependent phases (`"<identity> — contract fulfilled, available to phases depending on [PHASE_ID]"`), mirroring Artifacts Created's identities but phrased for downstream `needs` resolution.

Write via the guard-protected CLI call only — **never** a direct Write or Edit tool call on `handoff.md`'s path (`guard-runtime-state.py` blocks that and points back at this verb):

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
HANDOFF_PAYLOAD=$(jq -n \
  --argjson decisions "$DECISIONS_JSON" \
  --argjson artifacts "$ARTIFACTS_JSON" \
  --argjson deviations "$DEVIATIONS_JSON" \
  --argjson deferred "$DEFERRED_JSON" \
  --argjson contracts "$CONTRACTS_JSON" \
  '{decisions: $decisions, artifacts: $artifacts, deviations: $deviations, deferred: $deferred, contracts: $contracts}')
HANDOFF_RESULT=$(printf '%s' "$HANDOFF_PAYLOAD" | $AIMI_CLI roadmap-write-handoff --feature "$FEATURE" --phase "$PHASE_ID" 2>&1)
HANDOFF_EXIT=$?
```
`DECISIONS_JSON` / `ARTIFACTS_JSON` / `DEVIATIONS_JSON` / `DEFERRED_JSON` / `CONTRACTS_JSON` are each a JSON array of strings built from the bullets above (e.g. `jq -Rn '[inputs]'` fed one bullet per line, or a literal JSON array). `ARTIFACTS_JSON` is `VERIFIED_ARTIFACTS` converted to a JSON array directly.

**On failure (`HANDOFF_EXIT != 0`):** the phase's status is left exactly where it already was (`in_progress` — the write failure means the status-mutating call below is never reached, so there is nothing to revert). Release the claim (see Release the Claim on Abort) — `in_progress` is re-claimable once unclaimed, the same as any other phase-mode abort:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
```

Report:
```
Handoff write failed for phase [PHASE_ID]: [HANDOFF_RESULT]

Phase status remains in_progress. Retry with:
  $AIMI_CLI roadmap-write-handoff --feature [FEATURE] --phase [PHASE_ID]
  (same payload as above)

Re-running /aimi:execute re-enters this section and re-verifies creates
harmlessly — the retry above does not require repeating that step by hand.
```
Skip directly to Step 5.

### Mark Phase Completed

Only reached when `handoff.md` is confirmed on disk (the CLI call above returned `{"handoff": "<path>"}`). Exactly one call — sets status to `completed` **and** releases the phase's claim in the same atomic write (no window where status reads completed while still claimed; see `cmd_roadmap_set_status`'s completed-branch in aimi-cli.sh, which also refuses this transition when no `handoff.md` is on disk — a second, CLI-enforced guarantee behind the check above):

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI roadmap-set-status --feature "$FEATURE" --phase "$PHASE_ID" --status completed
```

Report: `"Phase [PHASE_ID] ([PHASE_SLUG]) completed. Claim released."`

Stop this phase's own dev server, if one is still running, before the branch is offered for a PR below — an orphaned server would otherwise keep holding its port after the phase's container is later removed by some future step. This call is unconditional (never gated on `PHASE_SPLIT_MODE`): a single-file phase's server, if any, was started against `PHASE_BRANCH` by Phase Container Dev Server Bootstrap in Step 1.7; a split phase's own two split servers were already stopped earlier, immediately before their worktrees were removed (see Merge Split Branches Into the Phase Branch's Clean Up Split Worktrees and its merge-conflict path) — `PHASE_BRANCH` itself never had a server running against it in split mode, so this call is a harmless no-op there:

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
cd "$AIMI_ROOT"
$WORKTREE_MGR serve stop "$PHASE_BRANCH"
```

CWD is `$AIMI_ROOT`, the same CWD Phase Container Dev Server Bootstrap used for its own `serve start "$PHASE_BRANCH"` in Step 1.7 — never `$PHASE_CONTAINER_PATH` — since `serve stop` resolves its dev-server.json key from CWD (see `_dev_server_key` in `worktree-manager.sh`); a mismatched CWD here would silently miss the registered entry instead of stopping it.

`serve stop` kills the dev server's full process group and clears its state entry; it exits 0 and reports "No dev server registered" when no server was ever started — identical to container-execution.md's Container Mode: Stop the Dev Server contract (invoked from Step 5). This only runs on the `completed` path reached here: every non-completion exit above it in Phase Completion (the pending-count guard, Creates Verification's `verification_failed` branch, and Write Handoff's failure branch) returns before this subsection, so a phase that ends on deadlock, a gate-blocked wave, or `verification_failed` never calls `serve stop` — its dev server stays alive between waves and across a paused session, resumable via `serve status` on the next `/aimi:execute` run against the same phase, exactly like the flat container's own resumable contract.

### Offer a Pull Request

Best-effort only — never reverts or changes the already-`completed` status on failure or refusal.

```bash
if command -v gh >/dev/null 2>&1; then
  cd "$PHASE_CONTAINER_PATH"
  git push -u origin "$PHASE_BRANCH"
  gh pr create --base "$DEFAULT_BRANCH" --head "$PHASE_BRANCH" \
    --title "Phase [PHASE_ID]: [PHASE_NAME]" \
    --body "Completes phase [PHASE_ID] of [FEATURE]. See [PHASE_DIR]/handoff.md for details."
else
  echo "gh not found — create the PR manually:"
  echo "  git -C \"$PHASE_CONTAINER_PATH\" push -u origin $PHASE_BRANCH"
  echo "  Then open a PR: $DEFAULT_BRANCH...$PHASE_BRANCH"
fi
```

If `git push` or `gh pr create` fails (no permissions, offline, branch already has an open PR, etc.), report the failure verbatim and continue — do not retry, do not prompt interactively, and never revert the phase's `completed` status.

### Next Phase

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
NEXT_ELIGIBLE_JSON=$($AIMI_CLI roadmap-get --feature "$FEATURE" --next-eligible 2>&1)
NEXT_ELIGIBLE_EXIT=$?
```

**When `NEXT_ELIGIBLE_EXIT != 0`** (no phase remains pending/planned, unclaimed, and dependency-complete — the roadmap-exhaustion case; a phase stuck in `verification_failed` also falls here since it is neither `pending` nor `planned`, matching outline 02's landed `roadmap-get --next-eligible` contract): skip both the interactive offer and the agent-mode auto-continue branch entirely. Run the residual sweep exactly once and hand its report to Step 5:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
ROADMAP_SWEEP_REPORT=$($AIMI_CLI roadmap-sweep "$FEATURE")
```
`ROADMAP_SWEEP_REPORT` is rendered as a `## Roadmap Sweep` section in Step 5's final summary (see below). No next-phase offer of any kind is shown.

**Otherwise**, `NEXT_ELIGIBLE_JSON` is the next eligible phase object; extract `NEXT_PHASE_ID=$(printf '%s' "$NEXT_ELIGIBLE_JSON" | jq -r '.id')`.

- **Interactive mode** (`$AIMI_CLI detect-interactivity` = `picker`): use **AskUserQuestion** with exactly two options:
  ```
  Phase [PHASE_ID] is complete. Plan phase [NEXT_PHASE_ID] now?

  A — Plan it now
  B — Plan it later
  ```
  **Option A:** set `NEXT_PHASE_HANDOFF=$NEXT_PHASE_ID` (consumed after Step 5's report — see below).
  **Option B:** report `"Resume with: /aimi:plan --phase [NEXT_PHASE_ID]"` and end the session after Step 5's report.

- **Agent mode** (`detect-interactivity` = `agent`): skip AskUserQuestion. Log exactly:
  ```
  agent-mode: phase-complete auto-continue [PHASE_ID]
  ```
  (`[PHASE_ID]` is the phase that **just completed**, not `NEXT_PHASE_ID`.) Set `NEXT_PHASE_HANDOFF=$NEXT_PHASE_ID`.

After Step 5's report is shown, if `NEXT_PHASE_HANDOFF` is set, proceed immediately into `/aimi:plan --phase [NEXT_PHASE_HANDOFF]`'s command flow — no further prompt, no waiting on additional user input.

## Step 5: Completion

When execution ends (all stories complete, or deadlock detected):

> **PHASE_MODE scope note:** this step's reporting is written for the flat-mode case (CWD = `AIMI_ROOT`, `HEAD` on `branchName`). In phase mode, run this step's commands with CWD inside `PHASE_CONTAINER_PATH` and substitute `PHASE_BRANCH` for `branchName` / `CONTAINER_BASE` for `DEFAULT_BRANCH` where used below. Phase-level completion — verifying the claimed phase's `creates`, writing `handoff.md`, updating roadmap status, offering a PR, and offering or auto-continuing to the next phase — is handled entirely by the **Phase Completion** section above, which runs before this step whenever `PHASE_MODE=true` and the phase's own pending count reaches zero. This step still runs afterward, in both modes, to report story-level completion for the phase's own tasks file.

> **CONTAINER_MODE scope note:** when `CONTAINER_MODE=true` and `PHASE_MODE=false` (flat container-mode execution — see Execution Mode Detection in Step 1), the **If all stories complete** branch below runs three additional ordered steps before its existing report: stop each project group's dev server, confirm and (unless declined or not opted into) push `[branchName]` to `origin`, then remove each project group's container while preserving its branch. Read `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Container Mode: Stop the Dev Server, § Container Mode: Push the Branch, and § Container Mode: Remove the Container immediately below — the order there is load-bearing; removing a container before its dev server is stopped orphans that server, still holding its port with no backing directory. When `CONTAINER_MODE=false` (inline mode, the default and unchanged), none of the three apply: no `git push` is invoked, no container is removed, and `serve stop` is never called.
>
> **Container removal is completion-path-only.** The reference's **Container Mode: Remove the Container** step is the only place in flat container mode that `$WORKTREE_MGR remove <branchName>` is ever called against the feature container itself — as opposed to a per-story worktree nested inside it. The **If deadlock detected** branch below, the per-wave merge-conflict report path (Step 4), and the reference's **Abandoning a Containerized Run** procedure never call it outside of this completion path or that explicit, user-initiated abandonment — every other exit leaves the feature container (and any dev server inside it) exactly as it was. (Phase mode's own container, `PHASE_CONTAINER_PATH`, is never removed anywhere in this document — see Phase Completion's **Mark Phase Completed**, which updates roadmap status only — so the same guarantee holds there trivially; the phase-mode split-merge conflict report below states it explicitly anyway, for parity with the flat case.)

### If all stories complete:

**When `CONTAINER_MODE=true`:** read `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Container Mode: Stop the Dev Server, § Container Mode: Push the Branch, and § Container Mode: Remove the Container, and run all three, in that order, before continuing below. When `CONTAINER_MODE=false` (inline mode), skip all three and continue directly below.

Count commits on this branch:

**When `CONTAINER_MODE=false` (inline mode, unchanged):**
```bash
git log --oneline $DEFAULT_BRANCH..HEAD | wc -l
```

**When `CONTAINER_MODE=true`:** the main working tree's `HEAD` was never checked out to `[branchName]` during container-mode execution (the same invariant Phase Mode's Main Working Tree Untouched Invariant establishes for `PHASE_BRANCH`, applied here by analogy), and the container that held it has just been removed above — count against the branch itself instead of `HEAD`, scoped per project group. A single global `$AIMI_ROOT`/`$DEFAULT_BRANCH` git log is wrong here: in a multi-repo layout (`AIMI_ROOT_IS_GIT_REPO=false`) there is no repo at `$AIMI_ROOT` and `$DEFAULT_BRANCH` was never set. For each unique `group_key` with a container from this run (see Container Paths Per Project Group), mirroring the same "for each unique `group_key`" loop **Container Mode: Push the Branch** and **Container Mode: Remove the Container** above already use. Read and validate `branchName` again — each Bash call is an isolated shell:
```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
BRANCH_NAME=$(jq -r '.metadata.branchName' "$AIMI_ROOT/$TASKS_PATH")
if ! [[ "$BRANCH_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
  echo "Invalid branchName: $BRANCH_NAME" >&2
  exit 1
fi
if [ "[group_key]" = "DEFAULT" ]; then
  GROUP_ROOT="$AIMI_ROOT"
  GROUP_DEFAULT="$DEFAULT_BRANCH"
else
  GROUP_ROOT="$AIMI_ROOT/[group_key]"
  GROUP_DEFAULT=$($AIMI_CLI detect-default-branch --project "$GROUP_ROOT")
fi
git -C "$GROUP_ROOT" log --oneline "$GROUP_DEFAULT".."$BRANCH_NAME" | wc -l
```

When exactly one `group_key` was scheduled this run (the common single-repo case, `group_key = "DEFAULT"`), report its count on today's single `Commits: [count]` line below — no format change for that case. When more than one `group_key` was scheduled (multi-repo), report one `Commits (project_path): [count]` line per group instead, in place of the single line.

Check for any remaining pending gates across all stories:
```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI status
```

Parse gate summary from status output:
- `pending_action_gates`: count of stories with gate.type == "action" and gate.status == "pending"
- `pending_verify_gates`: count of stories with gate.type == "verify" and gate.status == "pending"
- `pending_decision_gates`: count of stories with gate.type == "decision" and gate.status == "pending"

```
## Execution Complete

All stories completed successfully!

Branch: [branchName]
Waves: [total_waves]
Commits: [count]
```

In flat container mode with more than one `group_key` scheduled this run, replace the single `Commits: [count]` line above with one line per group instead:
```
Commits (project_path): [count]
Commits (project_path): [count]
```

Aggregate known-gap files from this run:
```bash
if [ -d .aimi/known-gaps ] && [ -n "$(ls .aimi/known-gaps/ 2>/dev/null)" ]; then
  echo ""
  echo "## Known Gaps"
  for gap_file in .aimi/known-gaps/*.md; do
    [ -f "$gap_file" ] || continue
    story_id=$(basename "$gap_file" .md | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//')
    echo ""
    echo "### $story_id"
    cat "$gap_file"
  done
fi
```

If `DESIGN_REVIEW_BUFFERS` is non-empty, append:
```
## Design Review

For each entry in DESIGN_REVIEW_BUFFERS (keyed by story id, insertion order):

### [story_id]: [entry.title]

[entry.output]
```

If `DESIGN_REVIEW_BUFFERS` is empty, omit the `## Design Review` section entirely.

If `CONSOLE_BUFFER` is non-empty, append:
```
## Console (advisory)

For each entry in CONSOLE_BUFFER (keyed by story id, insertion order):

### [story_id]
- [N] errors, [M] warnings, [E] exceptions
[For each entry in attributed where story_id matches:]
  - [kind] [text] (attribution: [attribution_method])

If any record was attributed via "text-component" or "wave-shared", prefix the
record's line with "likely:" so the user knows the call is heuristic.

[After per-story groups, if any wave-shared entries exist:]
### wave-shared
- [N] message(s) could not be attributed to a single story
  - [kind] [text]

Reminder: Console output is advisory. It does NOT change `verification.status`
and never blocks the wave — failed visual stories still fail on screenshot
mismatch only.
```

If `CONSOLE_BUFFER` is empty, omit the `## Console` section entirely.

If `ROADMAP_SWEEP_REPORT` is set (only ever set by Phase Completion's Next Phase step, roadmap-exhaustion branch), append:
```
## Roadmap Sweep

No phase remains ready to plan or claim — every phase in [FEATURE]'s roadmap
is completed, verification_failed, or otherwise not pending/planned.
Residual report from `roadmap-sweep`:

[If ROADMAP_SWEEP_REPORT.orphanCreates is non-empty:]
Orphan creates (declared but never consumed by any needs):
  For each: "  - phase [entry.phase]: [entry.creates]"

[If ROADMAP_SWEEP_REPORT.deferredNeeds is non-empty:]
Deferred needs (a provider exists but has not completed):
  For each: "  - phase [entry.phase] needs \"[entry.need]\", provided by phase [entry.deferred] (not yet completed)"

[If ROADMAP_SWEEP_REPORT.warnings is non-empty:]
Warnings:
  For each: "  - phase [entry.phase] field '[entry.field]': [entry.message]"

[If orphanCreates, deferredNeeds, and warnings are all empty:]
No residual gaps — every declared creates entry is consumed and every need is satisfied.
```

If `ROADMAP_SWEEP_REPORT` is unset, omit the `## Roadmap Sweep` section entirely.

If any pending gates exist, append:
```
### Pending Gates

[If pending_action_gates > 0:]
Action gates ([pending_action_gates]):
  For each: "  - [story.id]: [story.gate.prompt]"

[If pending_verify_gates > 0:]
Verify gates ([pending_verify_gates]):
  For each: "  - [story.id]: [story.gate.prompt]"

[If pending_decision_gates > 0:]
Decision gates ([pending_decision_gates]):
  For each: "  - [story.id]: [story.gate.prompt]"

Resolve gates with: $AIMI_CLI gate-pass <story-id> [--option 'value']
```

**When `CONTAINER_MODE=false` (inline mode, unchanged):**
```
### Next Steps

- Review commits: `git log --oneline -[count]`
- Run `/aimi:review` for code review
- Create PR when ready: `gh pr create`
```

**When `CONTAINER_MODE=true`:** the container was already removed above and nothing is checked out anywhere, so use the argument forms that work for a branch checked out nowhere instead:
```
### Next Steps

- Review commits: `git log --oneline -[count]`
- Open a PR: `/aimi:open-pr --branch [branchName]`
- Run `/aimi:review [branchName]` for code review
```

### If deadlock detected:

This branch also fires for the gate-blocked case above (Step 4's Gate-Blocked Story Detection reports its own "blocked by gates" message inline and then breaks the loop into this same completion path) — "none ready" is never caused only by cascade-skip.

```
## Execution Stopped - Deadlock

[N] stories remain pending but none are ready for execution.
This may be caused by failed stories whose dependents were cascade-skipped, or by a
permanently pending action gate blocking every remaining dependent story.

Run `/aimi:status` to see the dependency state.
Review failed stories and either retry or adjust dependencies.
```

**Container mode (`CONTAINER_MODE=true` or `PHASE_MODE=true`):** this branch never runs Container Mode: Stop the Dev Server / Push the Branch / Remove the Container — those only run in the **If all stories complete** branch above. The feature or phase container and its `.aimi/state/dev-server.json` entry are left exactly as they were; append to the report above:

```
The feature container and any dev server inside it are untouched — inspect the
branch there directly, or resume with a plain /aimi:execute re-run (see Resuming
Execution).
```

## Resuming Execution

The tasks file preserves all state. Re-running `/aimi:execute` will:

1. Detect the schema version again
2. Skip completed stories automatically
3. Pick up from the next ready wave
4. Failed stories remain as "failed" -- use `/aimi:status` to review them

**Flat container mode (`CONTAINER_MODE=true`, `PHASE_MODE=false`):** re-running `/aimi:execute` after a run stopped short of full completion (deadlock, a gate-blocked wave, a per-wave merge conflict, or an unexpected session crash) needs no new resumption mechanism. Step 2's Flat Container Mode `$WORKTREE_MGR create [branchName] --from "$CONTAINER_BASE"` call (see Create or Reuse the Container) is already idempotent — it reuses `CONTAINER_PATHS[group_key]`'s existing directory silently instead of recreating it — so the container, its branch, any dev server still running inside it, and every story already merged onto `[branchName]` all survive the stop untouched, and the re-run simply picks up in the next ready wave exactly as points 1–4 above describe.

**Phase mode:** re-running `/aimi:execute` for a phase this session already claimed and left `in_progress` does not error. `roadmap-claim`'s self-reclaim path (Step 1.7) reports the same phase again instead of a contention failure, and `$WORKTREE_MGR create "$PHASE_BRANCH" --from "$CONTAINER_BASE"` reuses the existing container directory silently since the target already exists — no separate reuse-detection logic is needed beyond calling both idempotently on every claim.

**Phase mode with a split (`PHASE_SPLIT_MODE=true`):** the same idempotency extends to Phase-Mode Paired Split — `$WORKTREE_MGR create "$split_branch" --from "$PHASE_BRANCH"`, run once per active split branch, reuses each split worktree silently if a prior run left one in place, and re-spawning the sub-orchestrators is harmless: each one's own `init-session --file` points at a split file whose already-completed stories are skipped automatically (points 1–4 above), so a sub-orchestrator with nothing left pending returns immediately. A member that completed entirely on the prior run is dropped by Step 1.7's Active Split Files filter and never re-spawned at all. This is also what makes retrying after a Merge Split Branches Into the Phase Branch conflict safe — re-running does not re-execute any story, only retries the merge and the Multi-File Pending Count / Creates Verification checks that follow it.

### After /clear

If context was cleared (via `/clear`), the CLI maintains state:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI get-state
```

Returns:
```json
{
  "tasks": ".aimi/tasks/...",
  "branch": "feat/...",
  "story": null,
  "last": "success"
}
```

- If `story` is set, there's an interrupted story
- If `last` is "success", continue with next story
- If `last` is "failed", ask user how to proceed

## Error Recovery

If execution is interrupted unexpectedly:

1. Tasks file preserves state (completed stories stay completed, in-progress stories can be retried)
2. State files in `.aimi/` track current position
3. User can run `/aimi:execute` again to resume
4. Orphaned worktrees are cleaned up on next run (safety cleanup in Post-Loop Cleanup)

The loop will automatically skip completed stories and continue from the next pending/ready one.

### Abandoning a Containerized Run

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Abandoning a Containerized Run — container mode (flat or phase) never removes the feature/phase container or stops its dev server outside the completion path, so giving up on a run for good (rather than resuming it) needs its own manual teardown; the reference defines the order (stop the dev server, then remove the container) and the pid-identity guarantees that make it safe.
