# Container Execution Mechanics

Shared reference for the container-only and managed-dev-server mechanics `/aimi:execute` uses in phase mode (`PHASE_MODE=true`) and flat container mode (`PHASE_MODE=false`, `CONTAINER_MODE=true`). Every section here matters only once one of those two booleans resolves `true` — an inline session (both false, the default and by far the most common path) never reads this file and its behavior is unchanged by anything below.

**Consumed by:** `commands/execute.md`, at Step 1's Phase Mode Detection (once `PHASE_MODE` resolves `true`) and Execution Mode Detection (once `CONTAINER_MODE` resolves `true`), and at each named call site that delegates to a section below.

## Container Paths Per Project Group (Container Mode)

When `CONTAINER_MODE=true` (see Execution Mode Detection in Step 1), each project group gets its own feature container instead of one shared across the whole run: `CONTAINER_PATHS[group_key] = project_roots[group_key] + "/.worktrees/" + branchName` for every group with at least one story scheduled this run — keyed identically to `project_roots[group_key]`, never a single global `CONTAINER_PATH` scalar. Step 2's Flat Container Mode (single-repo, `group_key = "DEFAULT"`) and Per-Project Branch Setup (multi-repo, one entry per project group) are what populate this map; Step 4's wave loop and both cleanup passes consume it via `EXEC_ROOT`/`EXEC_BRANCH` — see Execution Context: EXEC_ROOT, EXEC_BRANCH, EXEC_OWNS_ROOT, EXEC_KEEPS_BRANCH in Phase Mode: Worktree Naming and CWD below for how `EXEC_ROOT` derives from it.

## Phase Mode: Worktree Naming and CWD

This section is the single source of truth for how `PHASE_MODE=true` (see Step 1's Phase Mode Detection and Step 1.7's Phase Claim in `commands/execute.md`) and `CONTAINER_MODE=true` (flat container mode; see Execution Mode Detection in Step 1) each change worktree naming and working-directory handling in Step 4's wave loop and its cleanup passes. All call sites in `commands/execute.md` reference it by name. `PHASE_MODE`'s rules only apply once a phase has been claimed; `CONTAINER_MODE`'s rules apply for the whole run once Step 2 has created or reused the feature container(s) for every project group. When both are false (`EXECUTION_MODE` inline or absent — the byte-for-byte-unchanged default), every rule below reduces to exactly today's flat-mode behavior: no new variable is read and no new conditional branch is taken beyond evaluating a single `CONTAINER_MODE` check that is immediately false.

### Why Story Worktrees Are Phase-Qualified

Git branch names are repository-global. Two parallel `/aimi:execute` sessions each running their own phase container would otherwise mint identical unqualified story branches (e.g. both minting `US-003`) and collide. Story worktree/branch names in phase mode are therefore `<PHASE_BRANCH>-<story.id>` instead of `<branchName>-<story.id>` — qualified by the full phase branch, not just the phase id, so they stay collision-free even against a sibling phase container running concurrently for the same feature.

### CWD For Every Worktree Operation

Every `$WORKTREE_MGR create`/`merge-all`/`remove`/`list` call for a phase's stories runs with CWD set to `PHASE_CONTAINER_PATH`, never `AIMI_ROOT` and never a `project_root` from `commands/execute.md`'s Multi-Repo Handling grouping. Two reasons:

1. **`merge-all` checks out its target branch against whatever repo its CWD belongs to.** `worktree-manager.sh`'s `GIT_ROOT` is computed per-invocation from CWD (`git rev-parse --show-toplevel`), and `merge-all <story-worktree-names> --into <target-branch>` issues a bare `git checkout <target-branch>` against that root. Run from `AIMI_ROOT`, that would check the phase branch out onto the main working tree — forbidden by the Main Working Tree Untouched Invariant below. Run from `PHASE_CONTAINER_PATH`, `GIT_ROOT` resolves to the phase worktree's own root instead, and story worktrees nest at `PHASE_CONTAINER_PATH/.worktrees/<story-worktree-name>` — a pattern `worktree-manager.sh` already supports unmodified, since a linked worktree's own `git rev-parse --show-toplevel` returns its own path, not the main repo's.
2. **Every Bash call is an isolated shell** (Step 0). `PHASE_CONTAINER_PATH` does not persist across calls on its own — each call that needs it either `cd`s to it explicitly at the top of the call, or passes it via `git -C`/`$WORKTREE_MGR` arguments, exactly like `$AIMI_CLI`/`$WORKTREE_MGR` themselves are re-resolved per call.

### Execution Context: EXEC_ROOT, EXEC_BRANCH, EXEC_OWNS_ROOT, EXEC_KEEPS_BRANCH

Step 4's wave loop, both of its cleanup passes, and the post-merge visual-verification origin rewrite do not branch on `PHASE_MODE`/`CONTAINER_MODE` at each of their own call sites. Instead, Step 4 derives a four-part execution context **once per `group_key`**, immediately after the loop that populates `project_roots` (see GROUP STORIES BY PROJECT in Step 4) — every downstream consumer reads it directly instead of repeating the branch:

- **`EXEC_ROOT[group_key]`** — the path every `$WORKTREE_MGR create`/`merge-all`/`remove`/`list` call and every `git -C` invocation `cd`s to or targets for this group.
- **`EXEC_BRANCH[group_key]`** — the branch every worktree is created `--from`, every `merge-all --into` targets, and every cleanup scan pattern (`"[EXEC_BRANCH[group_key]]-US-*"`) matches.
- **`EXEC_OWNS_ROOT`** — a single run-wide scalar (not a map — it does not vary by `group_key` within one run), true when this run's own worktree-manager invocations created `EXEC_ROOT` as a container it is responsible for (container and phase mode), false when `EXEC_ROOT` is a pre-existing project checkout this run never created (inline mode). Consumed today only by the post-merge visual-verification origin rewrite (see Step 4).
- **`EXEC_KEEPS_BRANCH`** — a single run-wide scalar, `true` in all four modes today. No call site in `commands/execute.md` reads it yet; it exists so future per-mode teardown work (e.g. a container-mode `remove --keep-branch` step) has a documented place to branch on without reopening this contract.

The four bindings:

| Mode | `EXEC_ROOT[group_key]` | `EXEC_BRANCH[group_key]` |
|---|---|---|
| Inline (`PHASE_MODE=false`, `CONTAINER_MODE=false`) | `project_roots[group_key]` | `branchName` |
| Container, flat or per-project (`PHASE_MODE=false`, `CONTAINER_MODE=true`) | `CONTAINER_PATHS[group_key]` | `branchName` |
| Phase (`PHASE_MODE=true`) | `PHASE_CONTAINER_PATH` | `PHASE_BRANCH` |
| Split (a Phase-Mode Paired Split sub-orchestrator; `PHASE_MODE=true` with pre-set values — see Spawn Split Sub-Orchestrators) | `FRONTEND_WORKTREE_PATH` or `BACKEND_WORKTREE_PATH` | `FRONTEND_BRANCH` or `BACKEND_BRANCH` |

The split row is not a new derivation — it is exactly what `commands/execute.md`'s Phase-Mode Paired Split section (Create Split Worktrees and Spawn Split Sub-Orchestrators) already pre-assigns to `PHASE_CONTAINER_PATH`/`PHASE_BRANCH` before a split sub-orchestrator starts; the sub-orchestrator's own Step 4 then derives `EXEC_ROOT`/`EXEC_BRANCH` from the Phase row using those pre-set values, with no split-specific code path.

`EXEC_OWNS_ROOT = PHASE_MODE or CONTAINER_MODE` (true for phase, container, and split; false for inline). `EXEC_KEEPS_BRANCH = true` unconditionally, in every mode, today.

**`project_roots` is a distinct, orthogonal concept and is never absorbed into `EXEC_ROOT`.** Four consumers keep reading `project_roots[group_key]` (or the resolved project path it is built from) directly, independent of whichever mode's `EXEC_ROOT` a run is using:

1. `PROJECT_PATH` passed to each story-executor Task and its worktree boundary (Step 4's per-story spawn loop).
2. `PROJECT_GUIDELINES_MAP` keying (Step 3.3, Per-Project Guidelines).
3. `detect-default-branch`/`setup-branch` scoping (Step 2, Per-Project Branch Setup).
4. Post-Loop Cleanup's One-time migration safeguard, which must keep scanning `project_root` even in container/phase mode — it looks for worktrees stranded OUTSIDE the container by a run predating container mode.

None of these four reads `EXEC_ROOT` in its place: "which repository" (`project_roots`) and "which checkout of it this run is executing against" (`EXEC_ROOT`) are independent questions, and all four consumers above need the former regardless of the latter.

### Main Working Tree Untouched Invariant

For the entire span of a phase's execution — from the moment it is claimed (Step 1.7) through the last wave's merge — `AIMI_ROOT`'s `git rev-parse HEAD` and `git status --porcelain` never change. Every commit for the phase lands only on `PHASE_BRANCH` inside `PHASE_CONTAINER_PATH`. This holds automatically once every rule above is followed: nothing in phase mode ever `cd`s to `AIMI_ROOT` (or runs a mutating git command against it), and Step 2's Main Repo Branch Setup is skipped entirely in phase mode (see Step 2).

### Concurrency Source

`MAX_CONCURRENCY` (Step 3.2) is read from the claimed phase's own tasks file (`PHASE_TASKS_PATH`), not any feature-root or global file — this is the same per-phase value the worktree-budget guard hook enforces against nested story-worktree creation inside the container, so the phase's own setting (not a global default) governs how many story worktrees can exist under it at once.

## Create or Reuse a Container

This section is the single source of truth for creating (or reusing) a container worktree. Every call site sets three values first — `EXEC_ROOT` (the directory to `cd` into before calling `$WORKTREE_MGR create`: the project root, i.e. `AIMI_ROOT` or a resolved multi-repo project path — never the container path itself, which doesn't exist yet at creation time), `EXEC_BRANCH` (the `create`/worktree-name argument), and `CONTAINER_BASE` (the `--from` argument, already resolved by the caller's own `BASE_BRANCH`-vs-default selection) — then cites this section instead of restating the call or its reuse/idempotency behavior:

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
cd "$EXEC_ROOT"
$WORKTREE_MGR create "$EXEC_BRANCH" --from "$CONTAINER_BASE"
```

`$WORKTREE_MGR create` is branch-aware, not a blind idempotent create: it reuses the target directory silently when it's already a worktree there, creates `EXEC_BRANCH` fresh when the branch doesn't exist yet, attaches to the branch without recreating it when the branch exists but no worktree holds it (e.g. after a prior run's `remove --keep-branch`), and exits non-zero — naming the worktree that holds it, resolved from `git worktree list --porcelain` — when another worktree (including the main working tree) already has it checked out. Calling it on every claim (including a self-reclaim resume) is still safe, since the first two cases are exactly the reuse paths a resume needs. On non-zero exit, the caller reports the command's stderr verbatim (it already names the offending worktree) and STOPs — never remediate, never print a second, composed error on top of it. The resulting path is always deterministic: `$EXEC_ROOT/.worktrees/$EXEC_BRANCH`.

## Bootstrap a Container Dev Server

This section is the single source of truth for starting (or reusing) a container's dev server, once a caller has already computed its own `HAS_VISUAL_STORY` gate against its own tasks source (a phase's `PHASE_TASKS_PATH`, a split's `PHASE_FE_TASKS`/`PHASE_BE_TASKS`, or the flat/multi-repo `VISUAL_GROUP_KEYS` loop) — that jq query is legitimately site-specific and stays at each call site; only what happens once the gate passes is written here.

**When `HAS_VISUAL_STORY` is false:** skip entirely — no server is started, no `WORKTREE_MGR` resolution needed.

**Otherwise**, with `EXEC_ROOT` (the same project-root `cd` target Create or Reuse a Container above uses — never the container path itself, since `worktree-manager.sh` resolves its worktree-name argument against `$(git rev-parse --show-toplevel)/.worktrees/<name>` relative to CWD) and `EXEC_BRANCH` (the worktree-name argument) already set by the caller:

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
cd "$EXEC_ROOT"
$WORKTREE_MGR install-deps "$EXEC_BRANCH"
SERVE_URL=$($WORKTREE_MGR serve start "$EXEC_BRANCH")
```

`serve start`'s stdout, on both the reuse path and a successful fresh launch, is exactly the raw URL as its only line (all decorated narration goes to stderr) — so `SERVE_URL` is captured directly from it, and no immediate follow-up `serve status` call is made: a no-op status call right here would only ever race a concurrent `serve start`/`serve stop` for nothing, since it can't tell the caller anything this stdout didn't already say. A caller that needs the URL adopts `$SERVE_URL` into its own variable when non-empty; a caller that doesn't (this bootstrap alone is only ever about getting the server running, not about resolving a URL for later use) simply discards it. Empty `$SERVE_URL` means `serve start` degraded (no package.json, no dev script, port exhaustion, timeout, ownership mismatch, non-loopback bind) and reported nothing to adopt. No `package.json`/`scripts.dev` pre-check runs here, before or after this call — `install-deps` and `serve start` already perform that presence check internally and degrade to a clean, silent skip on their own, so re-checking it at the call-site layer would only duplicate work they already do.

**Degradation is advisory, never fatal.** A missing package manager, a failed install, port exhaustion, or a readiness-probe timeout never aborts the caller. This `EXEC_ROOT`/`EXEC_BRANCH` CWD choice is also what keeps two callers' `dev-server.json` entries distinct: `serve start`/`serve status`/`serve url` all key state by the container's absolute resolved path (`$EXEC_ROOT/.worktrees/$EXEC_BRANCH`, unique per caller), never by the branch name alone — so two callers whose container happens to share a branch name (e.g. two project groups, or two split branches) never collide. Every later consumer (Open Visual Follow Session, Step 4's post-merge visual verification) re-queries the server fresh via `serve url` at the point it needs the URL, rather than trusting a value cached here — a wave can run long after this bootstrap, and each Bash call is its own isolated shell (Step 0).

## Rewrite a Verification URL Origin

This section is the single source of truth for rewriting a verification URL's origin (scheme + host + port) to point at a running container or phase dev server, via `$WORKTREE_MGR serve url`. Every call site has already resolved its own `EXEC_ROOT` (the CWD to run this from — must exactly match the CWD used for that branch's own `serve start` call in Bootstrap a Container Dev Server above, since `serve url` resolves its `dev-server.json` key from CWD, see `_dev_server_key` in `worktree-manager.sh`) and its own branch key (`PHASE_BRANCH`, or the run's `branchName`), and passes both here along with the raw URL to rewrite:

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
cd "$EXEC_ROOT"
SERVE_URL_JSON=$($WORKTREE_MGR serve url "$EXEC_BRANCH" "$RAW_URL")
EFFECTIVE_URL=$(printf '%s' "$SERVE_URL_JSON" | jq -r '.url')
REWRITTEN=$(printf '%s' "$SERVE_URL_JSON" | jq -r '.rewritten')
```

`serve url` prints `{"url":...,"rewritten":bool}` and exits 0 in every case — no server running, and no partial/corrupt `dev-server.json` entry, both degrade to `rewritten:false` with `.url` echoing the raw input back unchanged (see `serve_status`'s own never-fails contract, which `serve url` reuses internally). A mismatched CWD silently misses the registered entry instead of reporting it stale, so the caller's own CWD selection above is load-bearing, not cosmetic.

**Never trust a value cached from an earlier bootstrap or an earlier call in the same run.** A wave can run long after the dev server was originally started, and each Bash call is its own isolated shell (Step 0 in `commands/execute.md`) — every consumer re-queries `serve url` fresh at the point it needs the URL, rather than reusing a `$SERVE_URL`/`$CONTAINER_DEV_URL` value captured during bootstrap.

Callers differ only in what they do with `$REWRITTEN`/`$EFFECTIVE_URL` once this returns: some (Open Visual Follow Session) simply adopt `.url` unconditionally, since a not-yet-running server degrading to the raw URL is an acceptable fallback there; others (Step 4's post-merge visual verification) gate on `$REWRITTEN` and skip that story's verification when it is `false`, since running a walkthrough against an un-rewritten origin would silently verify the wrong server. See each call site in `commands/execute.md` for its own gating logic.

## Container Mode: Stop the Dev Server

**Runs only when `CONTAINER_MODE=true`, before anything else in Step 5's completion list.** Stopping the dev server must complete before its container is removed further below — otherwise the server is orphaned, still holding its port, with no backing worktree directory left to serve it.

For each unique `group_key` with a container from this run (see Container Paths Per Project Group above):

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
if [ "[group_key]" = "DEFAULT" ]; then
  cd "$AIMI_ROOT"
else
  cd "$AIMI_ROOT/[group_key]"
fi
$WORKTREE_MGR serve stop [branchName]
```

CWD is the same project-root conditional Container Dev Server Bootstrap (Step 3.3 in `commands/execute.md`) already used before its `serve start [branchName]` for this group — never `cd [CONTAINER_PATHS[group_key]]` into the container itself — since `serve stop` resolves its dev-server.json key from CWD (see `_dev_server_key` in `worktree-manager.sh`); a mismatched CWD here would silently miss the registered entry instead of stopping it.

`serve stop` (outline 04's contract) kills the dev server's full process group and clears its state entry; it exits 0 and reports "No dev server registered" when no server was ever started for that container (no `package.json`, or the wave loop never launched one) — so this call is always safe to issue. Wait for it to finish before moving to the next subsection.

## Container Mode: Push the Branch

**Runs only when `CONTAINER_MODE=true`, after every dev-server stop above has completed.** Pushing publishes `[branchName]` to `origin` — an outward-facing action, and `CONTAINER_MODE` itself is just a field inside the tasks file, so a tasks file must never be able to trigger a publish on its own. Confirm before pushing, the same interactivity-gated pattern Phase Completion's **Next Phase** (in `commands/execute.md`) uses for its own AskUserQuestion/agent-mode branching. Resolve interactivity fresh — each Bash call is an isolated shell (Step 0):

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
INTERACTIVE_MODE=$($AIMI_CLI detect-interactivity)
```

- **`INTERACTIVE_MODE=picker`:** use **AskUserQuestion** with exactly two options:
  ```
  All stories are complete. Push [branchName] to origin now?

  A — Push now
  B — Skip (push it yourself later, or run /aimi:open-pr)
  ```
  **Option A:** proceed to the push below. **Option B:** set `SKIP_PUSH=true` and skip straight to **Container Mode: Remove the Container**.

- **`INTERACTIVE_MODE=agent`:** skip AskUserQuestion — an unattended run cannot answer a prompt. Push only when `--push` was passed on `$ARGUMENTS` (see Parse --push Override in Step 1 of `commands/execute.md`):
  ```bash
  if [ "$PUSH_FLAG" = "true" ]; then
    echo "agent-mode: container-push [branchName]"
  else
    echo "agent-mode: container-push skipped (no --push flag)"
    SKIP_PUSH=true
  fi
  ```

**When `SKIP_PUSH` is not set:** for each unique `group_key`, push `[branchName]` to `origin` from inside that group's container. Read and validate `branchName` first — defense in depth, mirroring `PHASE_BRANCH`'s validate-once-quote-everywhere discipline (`cmd_init_session` already rejected an invalid `branchName` in Step 1):

```bash
BRANCH_NAME=$(jq -r '.metadata.branchName' "$AIMI_ROOT/$TASKS_PATH")
if ! [[ "$BRANCH_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
  echo "Invalid branchName: $BRANCH_NAME" >&2
  exit 1
fi
cd [CONTAINER_PATHS[group_key]]
PUSH_OUTPUT=$(git push -u origin "$BRANCH_NAME" 2>&1)
PUSH_EXIT=$?
if [ "$PUSH_EXIT" -ne 0 ]; then
  echo "$PUSH_OUTPUT"
fi
```

If the push fails (offline, no remote permission, branch rejected, etc.), `$PUSH_OUTPUT` is reported verbatim in the completion report — do not retry, do not prompt interactively, and never roll back any story's completed status. Continue unconditionally to the next subsection regardless of `$PUSH_EXIT` or `$SKIP_PUSH`: neither a failed nor a skipped push here is fatal, because `/aimi:open-pr`'s own push step (outline 11) retries the push when the user later runs `/aimi:open-pr --branch [branchName]`, so the Next Steps suggestions stay safe to print either way.

## Container Mode: Remove the Container

**Runs only when `CONTAINER_MODE=true`, after the push above completes — regardless of its outcome.** A worktree cannot be removed while CWD sits inside it, so return to `$AIMI_ROOT` first:

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
BRANCH_NAME=$(jq -r '.metadata.branchName' "$AIMI_ROOT/$TASKS_PATH")
if ! [[ "$BRANCH_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
  echo "Invalid branchName: $BRANCH_NAME" >&2
  exit 1
fi
cd "$AIMI_ROOT"
$WORKTREE_MGR remove "$BRANCH_NAME" --keep-branch
```

Repeat once per `group_key` in a multi-repo run. `--keep-branch` (outline 02) preserves the local branch ref: this container is the deliverable the completion report is about to point the user at for review and a PR, not a throwaway per-story worktree, so removing it without `--keep-branch` would delete the very branch the Next Steps suggestions tell the user to open a PR from. This call must never run before **Container Mode: Stop the Dev Server** above.

## Abandoning a Containerized Run

Container mode (flat or phase) never removes the feature/phase container or stops its dev server outside the completion path (see `commands/execute.md` Step 5's Container removal is completion-path-only note) — a deadlock, a gate-blocked wave, a merge conflict, or a crash all leave both alive on disk for inspection or resumption. Before this feature existed, giving up on flat in-progress work was just switching branches; in container mode a stale container directory and possibly a still-running dev server survive instead, so abandoning a run for good — rather than resuming it — needs its own manual teardown, run from `$AIMI_ROOT` (or the relevant project root in a multi-repo layout, never from inside the container itself, since a worktree cannot be removed while CWD sits inside it) in this order:

1. **Stop the dev server first:** `$WORKTREE_MGR serve stop <branchName>` (or `<PHASE_BRANCH>` in phase mode). This kills the dev server's full process group — not just the pid recorded in `.aimi/state/dev-server.json` — and clears that state entry whether or not a live process was found.
2. **Then remove the container and its branch:** `$WORKTREE_MGR remove <branchName>`. Omitting `--keep-branch` here is intentional — unlike the completion-path removal above (which preserves the branch for review and a PR), abandonment discards the branch too. This is the container-mode replacement for what used to be a plain branch switch.

Never trust or reuse a `.aimi/state/dev-server.json` pid entry on a later resume based on liveness alone. A `kill -0` / `_is_pid_alive` probe (the same primitive `aimi-cli.sh` uses for stale-claim recovery) only proves *something* is running at that pid right now — pids get recycled by the OS, so a live pid is never by itself proof it is the dev server this tool started. The actual guarantee is `worktree-manager.sh`'s `dev_server_entry_is_ours`: it additionally compares the entry's recorded identity token (the process's `/proc/pid/stat` starttime, or `ps -o lstart=` as a portable fallback) against that pid's identity right now, and only a match counts. `serve start`'s reuse path and `serve stop`'s process-group kill both require that match before ever touching the pid — a live pid with a missing (pre-upgrade entry) or mismatched identity is treated exactly like a dead one: never reused, never signaled. (`$WORKTREE_MGR serve status <branchName>` still reports a dead-pid entry as `running:false` using the plain liveness probe alone, but — unlike a resume's reuse/kill decisions — never removes the stale entry itself: status is a true read-only verb now; only `serve start`'s own reuse path and `serve stop` ever write `dev-server.json`.)
