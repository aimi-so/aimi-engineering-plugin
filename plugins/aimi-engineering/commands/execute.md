---
name: aimi:execute
description: Execute all pending stories autonomously with wave-based parallelism
argument-hint: "[--phase <N>] [--base <branch>] [--container|--inline]"
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash(git:*), Bash(mkdir:*), Bash(AIMI_CLI=*), Bash($AIMI_CLI:*), Bash(WORKTREE_MGR=*), Bash($WORKTREE_MGR:*), Task
---

# Aimi Execute

Execute all pending stories autonomously using wave-based fan-out.

Each wave uses pointer-only handoff to keep the orchestrator's working memory slim:
- **Wave selection:** `list-ready --brief` returns lightweight story stubs `{id, title, priority, dependsOn, project}` for scheduling decisions.
- **Spawn prompt:** carries only a `task_pointer` section with the story id — no inlined story body, no inlined prototype context. Each subagent fetches its own full context via `$AIMI_CLI get-story-context $STORY_ID` as its first action.

Every story runs in its own git worktree spawned as a fresh-context Task subagent. Within a wave, stories execute in parallel up to metadata.maxConcurrency; selection order follows $AIMI_CLI list-ready output (tasks.json file order, deterministic).

## Step Files

Everything before Step 3 is a router: a heading, an `Applies when:` condition evaluable from state this file already holds (with the default for the skipped case beside it, so every variable a later step reads is still set), an optional `Covers:` line, and a `Read` line naming the step's file under `${CLAUDE_PLUGIN_ROOT}/commands/references/execute/`. When the condition holds, Read that file in full before running the step, and follow it as written. When it does not, skip the file and apply the default stated beside the condition. Entries appear in document order, which is not always execution order: "above" and "below" in a file's prose refer to this order. If a Read of a listed file fails, STOP and report the path; never treat a failed Read as the condition being false. **When the conversation resumes after a context compaction, re-read this router and the current step's file, and re-derive every value an earlier block echoed (`PLAN_DISC`, `PHASE_ID`, `PHASE_BRANCH`, `SPLIT_PLAN`, `BASE_BRANCH` and the like) by re-running the block that echoes it, before continuing.** A step file's text does not survive compaction; this router does.

The blocks that read `$ARGUMENTS` stay in this file rather than in a step file: `$ARGUMENTS` is substituted only in a command body, so a bash block under `commands/references/` that read it would see the literal text instead of what the user typed.

Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

## Step 0: Resolve CLI Path

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/cli-path-resolution.md` and follow the **Resolve CLI Path** and **Version Check** sections to set `$AIMI_CLI`. Each layer is a separate Bash call.

If resolution fails, report error and STOP.

**Each Bash tool call is an isolated shell — `$AIMI_CLI` does not persist.** Re-read the cache at the top of every subsequent Bash call that needs `$AIMI_CLI` or `$WORKTREE_MGR`. See the **Per-Call Resolution** section of `commands/references/cli-path-resolution.md` for the one-liner and shell guard to prepend.

### Resolve Agent Models

Read and follow the **Resolve Agent Models** section of `commands/references/cli-path-resolution.md` to populate `AGENT_MODELS`. When resolution fails, treat every category as `"inherit"` and continue.

### Parse --base Override

Scan `$ARGUMENTS` for an explicit `--base <branch>` token (mirrors the `--phase <N>` extraction style used by Step 1.7's Parse --phase Override, and the `--base` extraction `/aimi:next` already uses):

Parse and validate in the **same** block, and echo the result — the validation cannot run in a fence of its own, because each Bash tool call is an isolated shell and a separate fence would test an unset variable against the regex and pass vacuously. The echo is what makes the value readable to every later step, mirroring Step 1.5's **Detect Git Repo Layout**, which echoes `AIMI_ROOT_IS_GIT_REPO` for exactly this reason:

```bash
case " $ARGUMENTS " in
  *" --base "*)
    BASE_BRANCH=$(echo "$ARGUMENTS" | sed -n 's/.*--base[[:space:]]\+\([^ ]*\).*/\1/p')
    ;;
  *)
    BASE_BRANCH=""
    ;;
esac
if [ -n "$BASE_BRANCH" ] && ! echo "$BASE_BRANCH" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9/_-]*$'; then
  echo "Invalid --base value: $BASE_BRANCH" >&2
  exit 1
fi
echo "BASE_BRANCH=$BASE_BRANCH"
```

A non-zero exit here stops the run before any git, worktree, or CLI call consumes the value.

**Carrying `$BASE_BRANCH` forward.** The echoed value does not survive into any later Bash call — each one is its own shell. Every block below that reads `$BASE_BRANCH` must re-assign it at the top of that block with the literal value echoed here (`BASE_BRANCH=""` when `--base` was absent), the same way Step 0.9 Pass 2 re-assigns `SPLIT_PLAN` from Pass 1's printed stdout rather than assuming it persisted. The reading blocks are Step 0.9's split loop, Step 1.7's phase-container group loop, Step 2's Flat Container Mode, Main Repo Branch Setup, and Per-Project Branch Setup.

When `--base` was not passed, `$BASE_BRANCH` stays empty and every `resolve-base-branch`/`setup-branch` call below omits `--base` — or passes it empty, which those verbs treat identically to omission — falling back to the verb's own resolution order. When it was passed, this runs in Step 0, before Step 0.9's split loop and Step 1.6's picker, so the value is available to be carried into every call site that threads it, including the multi-repo split path that has no other opportunity to learn it before its own worktrees are created. An explicit `--base` also short-circuits Step 1.6's own gating and any per-repo picker Step 2 would otherwise run: `resolve-base-branch` reports `reason: "explicit-base"` and `promptNeeded: false` whenever `--base` is supplied, so no `AskUserQuestion` fires on top of a choice the user already made — see Step 1.6 below.

`--base` is matched on its own literal token, independently of `--phase`'s (numeric-only) and `--container`/`--inline`'s (bare-token) extractions above and below — passing several of these flags in one invocation is unaffected, exactly as `--container` and `--inline` already coexist without either stripping the raw `$ARGUMENTS` string.

### Refuse --push

`--push` was removed. It is not accepted, not ignored and not deprecated: an invocation still carrying it STOPS here, in Step 0, before `init-session` mutates any state. The contract that removal enforces — what counts as publishing, why nothing in a file or on a command line is consent, and why agent mode therefore has no flag that re-enables a push — is defined in `${CLAUDE_PLUGIN_ROOT}/commands/references/publish-confirmation.md` and is not restated here.

Scan and exit in the **same** block, for the same reason the `--base` validation above does: each Bash tool call is an isolated shell, so a gate living in a fence of its own would test an unset variable and pass vacuously. The bare-token `case` is the shape Parse --container/--inline Override below already uses:

```bash
case " $ARGUMENTS " in
  *" --push "*) PUSH_REFUSED=true ;;
  *) PUSH_REFUSED=false ;;
esac
if [ "$PUSH_REFUSED" = "true" ]; then
  echo "Removed flag: --push. An agent-mode run never publishes to origin, and no flag re-enables it. Publish with /aimi:open-pr --branch <branchName>." >&2
  exit 1
fi
```

The non-zero exit is the whole point, not a side effect. A pipeline that passed `--push` on the previous version got a published branch out of it; accepting the flag and quietly doing nothing would hand that same pipeline silence instead — the one outcome nobody notices. Failing is the only result that cannot be misread. Report the refusal to the person in whatever language they are writing in, never a hardcoded one (`${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`'s Adaptive Language Rule), and STOP.

## Multi-Repo Handling

Applies when: every run. Step 1.5 derives `AIMI_ROOT_IS_GIT_REPO` by the rule this section defines, and Steps 0.9, 1.7 and 2 route stories per project by it.
Covers: `### AIMI_ROOT_IS_GIT_REPO Branching Rule`, `### Per-Story Project-Grouping Pattern`, `### Plan Discriminator`, `### Per-Project Cleanup Rule`, `### Container Paths Per Project Group (Container Mode)`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/multi-repo-handling.md in full.


## Step 0.5: Archival Check

Applies when: every run; it is the first thing after Step 0 and asks whether finished task files should be archived before a session starts.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-0-5-archival-check.md in full.


## Step 0.7: Visual Follow Prompt

Applies when: every run; it counts the visual stories, aborts on a malformed `verification` field and sets `VISUAL_FOLLOW`.
After the count, when `VISUAL_STORIES` is greater than 0, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/visual-follow-lifecycle.md in full before the prompt, since the answer feeds the lifecycle it defines. When `VISUAL_STORIES` is 0 or empty skip it: `VISUAL_FOLLOW=false`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-0-7-visual-follow-prompt.md in full.


## Step 0.9: Multi-File Auto-Detection

Applies when: every run; `split-detect` is a query whose answer (`mode`, `activeCount`) decides every file below it in Step 0.9.
Covers: `### Split Detection`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-0-9-split-detection.md in full.


### Per-Repo Branch and Container Setup for the Split

Applies when: `split-detect` answered a `mode` of `project-split` or `paired-split` with `activeCount` of 2 or more. When it did not, skip this file and the aggregated-completion file below: the run is a single-file run, so continue with Single-File Fallback.
Covers: `#### Pass 1 — Derive and Validate Per-Repo Roots and Branches`, `#### Pass 2 — Create Worktrees or Containers`, `### Parallel Execution for Split Files`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-0-9-split-flow.md in full.


### Single-File Fallback

When `split-detect` reports `mode` = `single`, or reports a split whose `activeCount` is `1`, proceed with the standard single-file execution flow (Step 1 onward) unchanged — but pass that one file explicitly (`$AIMI_CLI init-session --file [the anchor, or the one active member's path]`) instead of letting Step 1's mtime auto-discovery pick a sibling that has nothing pending. When `mode` is `none`, run Step 1 with no `--file` and let `init-session` report the error.

### Aggregated Completion (Split Mode)

Applies when: the split flow above ran (`mode` of `project-split` or `paired-split` with `activeCount` of 2 or more) and its parallel Tasks have all completed. Otherwise skip this file: there is no split to report on, and Step 1 follows Single-File Fallback.
Covers: `#### Pass 3 — Aggregated Completion Report`, `#### Pass 4 — Clean Up Split Worktrees`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-0-9-aggregated-completion.md in full.


## Step 1: Initialize Session

Applies when: every run on the single-file path; it runs `init-session` and sets `PHASE_MODE`.
Covers: `### Phase Mode Detection`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-1-initialize-session.md in full.


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

### Execution Mode Detection

Applies when: every run; it sets `EXECUTION_MODE`/`CONTAINER_MODE`, recovers orphaned stories and validates the tasks file content.
Covers: `### Orphaned Story Recovery`, `### Content Validation`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-1-execution-mode.md in full.


## Step 1.5: Branch Freshness Check

Applies when: every run; it derives `AIMI_ROOT_IS_GIT_REPO`, `DEFAULT_BRANCH` and fetches origin.
Covers: `### Detect Git Repo Layout`, `### Default Branch and Origin Fetch`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-1-5-branch-freshness.md in full.


## Step 1.6: Branch Base Selection

Applies when: `AIMI_ROOT_IS_GIT_REPO` is true. When it is false (a multi-repo layout) the four gating conditions have nothing to evaluate: skip this file and leave `BASE_BRANCH` unset, exactly as the file's own When Prompt Is Not Needed branch does.
Covers: `### Resolve Interactivity Mode`, `### Compute Gating Conditions`, `### Picker Prompt (when prompt is needed AND INTERACTIVE_MODE=picker)`, `### Agent-Mode Fallback (when prompt is needed AND INTERACTIVE_MODE=agent)`, `### When Prompt Is Not Needed`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-1-6-branch-base-selection.md in full.


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

Applies when: `PHASE_MODE=true`. When `PHASE_MODE=false` skip every Step 1.7 file below and go straight to Step 2, with `PHASE_SPLIT_MODE=false`.
Covers: `### Claim the Phase`, `### Report Stale Claim Releases`, `### Reconcile Roadmap/Tasks Divergence`, `### Overlap Guard`.
Before claiming the phase, and before any STOP after the claim, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/release-claim-on-abort.md in full: it defines the Release the Claim on Abort procedure every abort in this step and the next invokes.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-1-7-claim-the-phase.md in full.


### Create or Reuse the Phase Container

Applies when: `PHASE_MODE=true`. When `PHASE_MODE=false` skip this file (default `PHASE_SPLIT_MODE=false`). Its Unsupported Combination Guard runs first and stops a phase run in a multi-repo layout.
Covers: `#### Unsupported Combination Guard: Phase Mode + Multi-Repo`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-1-7-phase-container.md in full.


### Detect a Full-Stack Split Inside This Phase

Applies when: `PHASE_MODE=true`. This file sets `PHASE_SPLIT_MODE`; when `PHASE_MODE=false` skip it and treat `PHASE_SPLIT_MODE` as `false`.
Covers: `` #### Pass 1 — Project-Split Detection (`metadata.splitGroup`) ``, `#### Pass 2 — Legacy Paired Split (fallback)`, `#### Active Split Files`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-1-7-detect-split.md in full.


### Create Phase Containers Per Project Group

Applies when: `PHASE_MODE=true`, after the split detection above has set `PHASE_SPLIT_MODE`. When `PHASE_MODE=false` skip it.
Covers: `#### Derive Participating Project Groups`, `#### Resolve and Create Each Group's Container`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-1-7-per-group-containers.md in full.


### Phase Container Dev Server Bootstrap

Applies when: `PHASE_MODE=true`. The dev-server bootstrap in it skips itself when `PHASE_SPLIT_MODE` is true; its closing Path and State Notes describe every phase-mode run. When `PHASE_MODE=false` skip it.
Covers: `### Path and State Notes`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-1-7-dev-server-and-notes.md in full.


## Phase-Mode Paired Split

Applies when: `PHASE_MODE=true` and `PHASE_SPLIT_MODE=true`. Otherwise skip this file and the two paired-split files below, with `PHASE_SPLIT_MODE=false` as the default, and continue with Step 2. A sub-orchestrator that Spawn Split Sub-Orchestrators started begins at Step 2 with these values already set and does not re-evaluate this entry.
Covers: `### Derive and Validate Split Branch Names`, `### Create Split Worktrees`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/paired-split-branches-and-worktrees.md in full.


### Split Container Dev Server Bootstrap

Applies when: `PHASE_MODE=true` and `PHASE_SPLIT_MODE=true`, after the worktrees above exist. Otherwise skip it (default `PHASE_SPLIT_MODE=false`).
Covers: `### Spawn Split Sub-Orchestrators`, `#### Nested Concurrency`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/paired-split-dev-server-and-spawn.md in full.


### Aggregated Completion Report (Phase-Mode Paired Split)

Applies when: `PHASE_MODE=true` and `PHASE_SPLIT_MODE=true`, once the spawned split sub-orchestrators have finished. Otherwise skip it (default `PHASE_SPLIT_MODE=false`).
Covers: `### Merge Split Branches Into the Phase Branch`, `### Clean Up Split Worktrees`, `### Continue to Phase Completion`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/paired-split-merge-and-continue.md in full.


## Step 2: Branch Setup

Applies when: `CONTAINER_MODE=true` and `AIMI_ROOT_IS_GIT_REPO=true` (phase mode forces `CONTAINER_MODE` to false). Otherwise skip this file; Main Repo Branch Setup below then decides whether the main repository gets its branch here.
Covers: `### Flat Container Mode: Create or Reuse the Feature Container`, `#### Create or Reuse the Container`, `#### Plan Base Freshness (advisory)`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-2-flat-container.md in full.


### Main Repo Branch Setup

Applies when: `AIMI_ROOT_IS_GIT_REPO=true`, `PHASE_MODE=false` and `CONTAINER_MODE=false`. When any of the three differs, skip this file: the phase container (phase mode), the feature container (container mode) or the per-project setup (multi-repo layout) creates the branch instead.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-2-main-repo-branch-setup.md in full.


### Per-Project Branch Setup

Applies when: `PHASE_MODE=false`. The file keeps its own test for whether any story carries a non-null `project` field, or the layout is multi-repo (`AIMI_ROOT_IS_GIT_REPO=false`). When `PHASE_MODE=true` skip it: the phase container Step 1.7 created is the only branch-creating operation for the phase.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-2-per-project-branch-setup.md in full.


## Step 3: Check for Pending Stories

Resolve this run's own tasks file explicitly — `$PHASE_TASKS_PATH` when `PHASE_MODE=true` (already set by Step 1.7, or pre-set here for a split sub-orchestrator — see Spawn Split Sub-Orchestrators), `$AIMI_ROOT/$TASKS_PATH` otherwise — rather than letting `count-pending` fall through to its shared current-tasks fallback. Every remaining call in this step and in Step 4 below reuses the same formula, resolved fresh in each call's own isolated shell:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
AIMI_ROOT="$PWD"
while [ "$AIMI_ROOT" != "/" ] && [ ! -d "$AIMI_ROOT/.aimi" ]; do AIMI_ROOT=$(dirname "$AIMI_ROOT"); done
[ -d "$AIMI_ROOT/.aimi" ] || AIMI_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
if [ "$PHASE_MODE" = "true" ]; then
  RUN_TASKS_FILE="$PHASE_TASKS_PATH"
else
  RUN_TASKS_FILE="$AIMI_ROOT/$TASKS_PATH"
fi
$AIMI_CLI count-pending --tasks-file "$RUN_TASKS_FILE"
```

If result is `0`:

**Re-verify branch — a phase that entered `verification_failed` with nothing left to execute.** Evaluate this branch **first**, before the release-and-STOP below. It fires only when **all five** of these hold together:

1. `count-pending` returned `0` (this is the `If result is 0` case, so it already holds here);
2. `PHASE_MODE=true`;
3. `$PHASE_ID` is set — the session itself ran Step 1.7, which is never true inside a Phase-Mode Paired Split sub-orchestrator, since one never learns `$PHASE_ID`;
4. `PHASE_SPLIT_MODE=false`;
5. `PHASE_ENTRY_STATUS` equals the literal string `verification_failed` (captured in Step 1.7's on-success extraction block — the only surviving witness of the entry status, since the `in_progress` transition in that same step overwrote it in `roadmap.json`).

**If any single one of the five is false, fall through to the unchanged path below** — flat mode, flat container mode, a phase entered as `pending`/`planned`/`in_progress`, and a split sub-orchestrator with no `$PHASE_ID` all behave exactly as they do today, with no observable difference.

When it fires: do **not** release the claim, do **not** print `All stories already complete!`, and do **not** STOP. Report the block below, then **skip Validate Dependencies, Steps 3.1, 3.2, 3.3 and 3.4, and all of Step 4**, and continue directly into the **Phase Completion** section.

```
Phase [PHASE_ID] has 0 pending stories but entered this run as
verification_failed — every story is done, the phase's creates verification
is what failed.

Re-verifying branch [PHASE_BRANCH] instead of stopping. Skipping the wave
loop (nothing to execute) and continuing straight to phase verification.
```

**Why this is not a STOP, and why the claim stays held.** Phase Completion owns the release on *both* of its outcomes: Mark Phase Completed releases atomically on success, and Creates Verification's `On any missing entry` path sets `verification_failed` again and releases on a repeat failure. Releasing here would hand the phase to a racing session in the middle of its own verification. Every *other* phase-mode STOP in Step 3 — the `All stories already complete!` STOP below and Validate Dependencies' failure STOP — keeps its existing release-first call unchanged.

**Why skipping those steps is safe.** Phase Completion consumes nothing they produce: it re-fetches `PHASE_JSON`/`PHASE_NAME` from its own `roadmap-get` call, Creates Verification derives `PARTICIPATING_GROUP_KEYS` fresh from the phase's own tasks file and recomputes each participating repository's container as that repository's toplevel plus `.worktrees/$PHASE_BRANCH` rather than reusing anything from Step 1.7, and `$WORKTREE_MGR` is re-resolved inline where Mark Phase Completed needs it. `MAX_CONCURRENCY` (Step 3.2), the project guidelines (Step 3.3) and `VISUAL_URL` (Step 3.4) have no reader in Phase Completion or Step 5 on this path.

**No `init-session` re-run is added here.** Step 1.7's **Point the session at this phase's own tasks file** already pointed session state at `$PHASE_TASKS_PATH`, and the `count-pending` that just returned `0` is the proof that it did — Phase Completion's own bare `count-pending` (Multi-File Pending Count, `PHASE_SPLIT_MODE=false` branch) reads that same session state, gets the same `0`, and its "pending count is greater than 0" abort branch is therefore not taken.

This mirrors an already-supported route rather than inventing a new one: Phase-Mode Paired Split already continues to Phase Completion with `PHASE_ACTIVE_COUNT` of `0` — every member already completed, nothing spawned — precisely because Phase Completion is what re-runs the pending-count and creates-verification checks. This branch extends that same behavior to the non-split path. Condition 4 is belt-and-braces: a split phase's top-level orchestrator never reaches Step 3 at all (Step 1.7 routes `PHASE_SPLIT_MODE=true` to Phase-Mode Paired Split instead of Step 2), so the load-bearing conditions here are 3 and 5.

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

Same resolution as this step's own `count-pending` above — a fresh `AIMI_ROOT` derivation feeding the identical `PHASE_MODE`-conditioned formula:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
AIMI_ROOT="$PWD"
while [ "$AIMI_ROOT" != "/" ] && [ ! -d "$AIMI_ROOT/.aimi" ]; do AIMI_ROOT=$(dirname "$AIMI_ROOT"); done
[ -d "$AIMI_ROOT/.aimi" ] || AIMI_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
if [ "$PHASE_MODE" = "true" ]; then
  RUN_TASKS_FILE="$PHASE_TASKS_PATH"
else
  RUN_TASKS_FILE="$AIMI_ROOT/$TASKS_PATH"
fi
$AIMI_CLI validate-deps --tasks-file "$RUN_TASKS_FILE"
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
  AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
  : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
  if [ "$PHASE_MODE" = "true" ]; then
    VISUAL_SOURCE="$PHASE_TASKS_PATH"
  else
    VISUAL_SOURCE="$AIMI_ROOT/$TASKS_PATH"
  fi
  FIRST_VISUAL=$($AIMI_CLI verification-report --tasks-file "$VISUAL_SOURCE" | jq -c '.visual[0]')
  VISUAL_URL=$(printf '%s' "$FIRST_VISUAL" | jq -r '.url')
  VISUAL_GROUP_KEY=$(printf '%s' "$FIRST_VISUAL" | jq -r '.project // "DEFAULT"')
  ```

  **When `PHASE_MODE` is true** (the top-level single-file phase orchestrator, or a Phase-Mode Paired Split sub-orchestrator whose spawn prompt pre-set `PHASE_BRANCH`/`PHASE_CONTAINER_PATH` to its own split — see Spawn Split Sub-Orchestrators — so this branch applies unmodified in either case, keyed by whichever branch this session owns): resolve `EXEC_ROOT` from `VISUAL_GROUP_KEY` just computed above — never the unconditional `$AIMI_ROOT` — since a visual story's own `project` field may resolve to a repository distinct from `AIMI_ROOT`'s own (see Create Phase Containers Per Project Group). This CWD must exactly match whichever group's dev server Phase Container Dev Server Bootstrap started for that same `VISUAL_GROUP_KEY` (container-execution.md:100/:111/:134's CWD-must-match requirement — a mismatched CWD silently misses the registered entry). Read `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Rewrite a Verification URL Origin and apply it with `EXEC_ROOT` resolved as follows, `EXEC_BRANCH="$PHASE_BRANCH"`, and `RAW_URL="$VISUAL_URL"` — never a value cached from Phase Container Dev Server Bootstrap or Split Container Dev Server Bootstrap earlier in this run, since each Bash call is an isolated shell (Step 0):

  ```bash
  WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
  : "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"; [ -x "$WORKTREE_MGR" ] || { echo "WORKTREE_MGR is stale: $WORKTREE_MGR does not exist — re-run check-version --quiet --fix" >&2; exit 1; }
  if [ "$VISUAL_GROUP_KEY" = "DEFAULT" ]; then
    VISUAL_GROUP_ROOT="$AIMI_ROOT"
  else
    VISUAL_GROUP_ROOT="$AIMI_ROOT/$VISUAL_GROUP_KEY"
  fi
  EXEC_ROOT=$(git -C "$VISUAL_GROUP_ROOT" rev-parse --show-toplevel 2>/dev/null) || EXEC_ROOT="$VISUAL_GROUP_ROOT"
  cd "$EXEC_ROOT"
  SERVE_URL_JSON=$($WORKTREE_MGR serve url "$PHASE_BRANCH" "$VISUAL_URL")
  VISUAL_URL=$(printf '%s' "$SERVE_URL_JSON" | jq -r '.url')
  ```

  `VISUAL_URL` is simply reassigned to `.url` either way — the reference's degrade-safely contract (never fails, falls back to the raw URL unchanged) applies here unconditionally, with no gating on `.rewritten`.

  **When `CONTAINER_MODE` is true and `CONTAINER_DEV_URL[VISUAL_GROUP_KEY]` resolved** (see Container Dev Server Bootstrap above; `PHASE_MODE` and `CONTAINER_MODE` are mutually exclusive — see Execution Mode Detection — so at most one of these two branches ever applies): apply the same reference section with `EXEC_BRANCH` = this run's `branchName`, scoped to the FIRST visual story's OWN project group. This resolves the port of that group only — a second visual story from a different project group is unaffected by this rewrite and is instead resolved independently at its own post-merge verification step (Step 4). `EXEC_ROOT` is the same project root Container Dev Server Bootstrap (Step 3.3) already used for `VISUAL_GROUP_KEY` — `$AIMI_ROOT` for `"DEFAULT"`, otherwise `$AIMI_ROOT/[VISUAL_GROUP_KEY]`:

  ```bash
  AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
  : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
  WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
  : "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"; [ -x "$WORKTREE_MGR" ] || { echo "WORKTREE_MGR is stale: $WORKTREE_MGR does not exist — re-run check-version --quiet --fix" >&2; exit 1; }
  BRANCH_NAME=$($AIMI_CLI metadata | jq -r '.branchName')
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

# WAVE_TASKS_FILE — this run's own tasks file, resolved once here with the
# same PHASE_MODE-conditioned formula Step 3 above already applied ($PHASE_TASKS_PATH
# when PHASE_MODE=true, else $AIMI_ROOT/$TASKS_PATH — both already resolved by
# this point in every flow, including a split sub-orchestrator, which pre-sets
# PHASE_TASKS_PATH before it ever reaches here). Every CLI call in this loop
# passes it explicitly as --tasks-file instead of falling through to the
# shared current-tasks pointer, which is what let two concurrent split
# orchestrators silently read and mutate each other's file.
WAVE_TASKS_FILE = PHASE_TASKS_PATH if PHASE_MODE else (AIMI_ROOT + "/" + TASKS_PATH)

# PLAN_DISC — this run's own plan identity, the sanitized stem of the file
# above. Derived by the block in Multi-Repo Handling's `### Plan Discriminator`;
# run that block in the Bash call that needs the value and read it back from
# the PLAN_DISC= line it echoes, since every Bash call is an isolated shell.
PLAN_DISC = sanitized stem of WAVE_TASKS_FILE

while true:
    # ========================================
    # RE-POINT THE CLI — TOP OF THE WAVE, NEVER MID-WAVE
    # ========================================
    # Step 0 resolves $AIMI_CLI once, at the start of the run, and nothing in
    # this loop has ever revisited it. A wave loop outlives that resolution:
    # a `cleanup-versions` run in another session prunes the cache directory
    # this run's path points into, and every later call answers "No such file
    # or directory" through a path that was correct when it was written.
    #
    # The POSITION is the load-bearing part, not the call. The same --fix run
    # between spawn and merge is what broke a mark-complete mid-wave: the
    # cached path moved while N workers already held the old one, so the
    # orchestrator wrote through a CLI its own workers had never seen. Here,
    # between the last merge of wave N and the first spawn of wave N+1,
    # nothing is in flight and a re-point can strand no one. Do not move this
    # call further down for symmetry with anything.
    #
    # Every Bash call in this file re-reads $AIMI_CLI from the cache --fix
    # rewrites (Step 0's Per-Call Resolution note), so the repointing reaches
    # the next call on its own; nothing is reassigned here. Read `status` and
    # not the exit code alone — `unknown` exits 0 and means no plugin is
    # installed at all (see cli-path-resolution.md's Version Check table).
    $AIMI_CLI check-version --quiet --fix

    # Check remaining work
    pending = $AIMI_CLI count-pending --tasks-file [WAVE_TASKS_FILE]
    if pending == 0: break

    # Get ready stories (brief mode — returns {id, title, priority, dependsOn, project, gate} only)
    # NOTE: The CLI's list-ready already filters out:
    #   - Stories with pending decision gates (blocked before start)
    #   - Stories whose dependencies have pending action gates (blocked until gate resolved)
    ready_stories = $AIMI_CLI list-ready --brief --tasks-file [WAVE_TASKS_FILE]
    if ready_stories is empty:
        if pending > 0:
            # ========================================
            # GATE-BLOCKED STORY DETECTION
            # ========================================
            # Before reporting deadlock, check if stories are blocked by gates.
            # Use $AIMI_CLI status to get all stories and identify gate-blocked ones.
            all_stories = $AIMI_CLI status --tasks-file [WAVE_TASKS_FILE]
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
        $AIMI_CLI mark-in-progress [story.id] --tasks-file [WAVE_TASKS_FILE]

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
            # PHASE_CONTAINER_PATHS[group_key] is populated for every
            # participating group by Create Phase Containers Per Project
            # Group (Step 1.7) in the top-level orchestrator. A Phase-Mode
            # Paired Split sub-orchestrator never runs Step 1.7 — its spawn
            # prompt pre-sets only the scalar PHASE_CONTAINER_PATH to its own
            # split's worktree (see Spawn Split Sub-Orchestrators), so the map
            # is empty there and this falls back to that scalar unchanged.
            EXEC_ROOT[group_key] = PHASE_CONTAINER_PATHS[group_key] if group_key in PHASE_CONTAINER_PATHS else PHASE_CONTAINER_PATH
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

        # PLAN_DISC comes from Multi-Repo Handling's `### Plan Discriminator`,
        # derived once from WAVE_TASKS_FILE above. worktree_base is deliberately
        # NOT redefined: it is read a second time below as `--from [worktree_base]`
        # and must keep naming a branch that really exists, so the discriminator
        # goes into a separate prefix rather than being folded into the base.
        worktree_prefix = PLAN_DISC + "-" + worktree_base

        for full_story in stories:
            # The story id stays LAST. skills/story-executor/SKILL.md requires in
            # two places that the branch an executor finds checked out END in
            # "-<STORY_ID>", and treats a mismatch as a refusal to stage or commit.
            worktree_name = worktree_prefix + "-" + full_story.id

            # cd to this group's execution root (see Execution Context above)
            cd [worktree_cwd]
            create_output = $WORKTREE_MGR create [worktree_name] --from [worktree_base]

            # ========================================
            # READ BOTH CREATE SENTINELS — OR FAIL THE STORY HERE
            # ========================================
            # worktree-manager.sh's create emits two unprefixed lines on BOTH
            # of its branches, fresh creation and silent reuse alike:
            #     WORKTREE_PATH=<absolute path>
            #     WORKTREE_BASE=<full 40-char sha of the new tree's own HEAD>
            # Take the LAST occurrence of each: the fresh-creation branch
            # prints a `cd <path>` hint after them, and everything else create
            # writes is ANSI-coloured progress text carrying neither prefix.
            # The sha is deliberately full-length — an abbreviated one is
            # ambiguous exactly when two bases are close enough to confuse.
            worktree_path = value of the last WORKTREE_PATH= line in create_output
            worktree_base_sha = value of the last WORKTREE_BASE= line in create_output

            # Either sentinel missing is a FAILURE OF THIS STORY, decided
            # BEFORE the executor is spawned. There is no useful recovery
            # after that point: by the time a wrong tree announces itself the
            # work is already written onto it. The usual cause is a
            # worktree-manager.sh predating the sentinels, which is a host
            # problem and not this story's — say so and stop.
            if worktree_path is absent or worktree_base_sha is absent:
                $AIMI_CLI mark-failed [full_story.id] "Worktree create emitted no WORKTREE_PATH/WORKTREE_BASE sentinel" --tasks-file [WAVE_TASKS_FILE]
                $AIMI_CLI cascade-skip [full_story.id] --tasks-file [WAVE_TASKS_FILE]
                Report: "[full_story.id] failed: create printed no WORKTREE_PATH/WORKTREE_BASE (worktree-manager.sh too old?). Dependent stories cascade-skipped."
                drop full_story from full_stories, do not spawn it, continue with the next story

            # ========================================
            # THE TREE MUST STAND ON THE BASE WE ASKED FOR
            # ========================================
            # base_sha[group_key] is this group's EXEC_BRANCH HEAD, captured
            # above before any worktree was cut — the base every story in this
            # wave is meant to stand on. worktree_base_sha is what the tree
            # ACTUALLY stands on. Divergence is a FAILURE, not a warning.
            #
            # Measured, in this repository's own phase 2: a story worktree cut
            # from main instead of from its phase branch announced nothing at
            # creation. It surfaced three levels downstream as a CLI verb
            # answering "Unknown command", a pytest suite short by the phase's
            # own new cases, and a golden file still holding the previous
            # value — three symptoms pointing at three different places, none
            # of them at the base. This comparison is what turns that into one
            # line, before a single file is written.
            #
            # Equality is the fresh-creation case. The one other ACCEPTED
            # shape is a reused worktree that already carries commits of its
            # own: a story that committed and then failed keeps both worktree
            # and branch (see the merge-conflict cleanup below), so a re-run
            # legitimately finds a tree AHEAD of the base. Accept exactly that
            # — base_sha[group_key] reachable from worktree_base_sha — and
            # nothing else. A tree cut from a different branch fails this,
            # which is the whole point; a strict equality test would instead
            # fail every resumed run, and a check that cries wolf on the
            # normal path is a check someone deletes.
            if worktree_base_sha != base_sha[group_key] and not (git -C [worktree_path] merge-base --is-ancestor [base_sha[group_key]] [worktree_base_sha]):
                $AIMI_CLI mark-failed [full_story.id] "Worktree base [worktree_base_sha] does not descend from [base_sha[group_key]]" --tasks-file [WAVE_TASKS_FILE]
                $AIMI_CLI cascade-skip [full_story.id] --tasks-file [WAVE_TASKS_FILE]
                Report: "[full_story.id] failed: worktree stands on [worktree_base_sha], expected [EXEC_BRANCH[group_key]] at [base_sha[group_key]]. Dependent stories cascade-skipped."
                drop full_story from full_stories, do not spawn it, continue with the next story

            all_worktrees[full_story.id] = {
                worktree_name: worktree_name,
                worktree_path: worktree_path,
                worktree_base_sha: worktree_base_sha,
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
                - TASKS_FILE_PATH = WAVE_TASKS_FILE  ← this wave's own resolved tasks file. The
                  story-executor SKILL.md <task_pointer> template substitutes TASKS_FILE_PATH onto
                  its own get-story-context call, so the spawned executor reads this orchestrator's
                  file even when a sibling split orchestrator's init-session call last wrote the
                  shared pointer
                - AIMI_ROOT = this run's already-resolved AIMI_ROOT (the directory holding `.aimi/`)
                  ← passed in, never re-derived inside a worktree, which has no `.aimi/` of its own;
                  the executor exports it beside TASKS_FILE_PATH for both verify runs
                - SCRATCH_PREFIX = PLAN_DISC + "-" + full_story.id  ← the executor's scratchpad
                  namespace, handed over ALREADY COMPOSED rather than left to be chosen. `PLAN_DISC`
                  is READ here and never recomposed nor re-sanitized: `### Plan Discriminator` under
                  Multi-Repo Handling derived it once from WAVE_TASKS_FILE, its sanitization is
                  load-bearing (`validate_branch_name` refuses a single dot), and a second derivation
                  is only a second chance to disagree with the first.
                  The axis is the PLAN and the story id comes SECOND, which is why that order is
                  not arbitrary. The collision measured on 2026-09-08 was not
                  sibling-against-sibling: a `verify-US-002.sh` left in the shared scratchpad by an
                  EARLIER plan's run was read by this run's US-002, whose id happened to be the same
                  string. A prefix keyed on the story id alone composes the identical name for both
                  and would have separated nothing — only the plan's own identity does.
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
    # STALLED EXECUTOR DETECTION — the executor that went idle
    # ========================================
    # This happened for real, twice in phase 1 of this feature: a spawned
    # executor finished its work, ran its own verify suite, and went idle
    # without ever emitting <result_json> and without running `git commit`.
    # Both times the only way it surfaced was the orchestrator going and
    # looking at `ps` / the agent roster by hand — nothing in this loop told
    # anyone to. The fallback above (missing or malformed <result_json> —
    # falling back to Task exit signal) presupposes the Task returned with
    # SOMETHING usable; a stalled executor's Task call still returns in this
    # same turn (every Task here is foreground — see "Spawn ALL workers"
    # above), but its own exit signal says nothing about whether real work
    # got left behind uncommitted, because it never looked.
    #
    # No clock, no liveness probe of the agent — this crosses three facts
    # the loop already captures for every story with no valid result_json:
    #   1. missing or malformed result_json (payload is None, from the loop above)
    #   2. HEAD in the worktree is unchanged from base_sha (no commit landed)
    #   3. the worktree is dirty (the executor wrote SOMETHING before going idle)
    # All three together is a stalled story. Any one of them alone is not:
    # (1) alone is the existing fallback, untouched, trusting Task's own
    # signal; (2)+(3) without (1) is the ordinary ok-but-no-commit case the
    # COMMIT VERIFICATION step below already walks through result_payload_by_id.
    #
    # Detection runs over EVERY story with no result_json, whichever bucket
    # the fallback above placed it in — a stalled executor's own Task exit
    # signal can read as a success (nothing errored, it just never reported)
    # or as a failure (it ran out of turns going idle), and the fallback has
    # no way to tell those apart. A stalled story found sitting in
    # failed_stories is moved into succeeded_stories so it reaches the SAME
    # commit-verification / commit-rescue pass below as every other
    # no-commit story — this never adds a third resolution path, it only
    # widens which stories reach the two that already exist.
    stalled_story_ids = []
    for full_story in (succeeded_stories + failed_stories):
        if result_payload_by_id.get(full_story.id) is not None:
            continue    # Task returned a valid block — not this case
        wt = all_worktrees[full_story.id]
        worktree_head = git -C [wt.worktree_path] rev-parse HEAD
        tree_is_dirty = (`git -C [wt.worktree_path] status --porcelain` output is non-empty)
        if worktree_head == base_sha[wt.group_key] and tree_is_dirty:
            stalled_story_ids.append(full_story.id)
            if full_story in failed_stories:
                failed_stories.remove(full_story)
                succeeded_stories.append(full_story)
            Report: "[full_story.id] stalled — executor went idle without <result_json> and without committing (dirty tree, no new commit). Routing through commit verification / commit rescue below."

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

    # ========================================
    # COMMIT RESCUE — BEFORE mark-failed, AND ONLY ON THE SUBSET
    # ========================================
    # A story that reached here reported ok and left a dirty tree with no
    # commit on it. That is a mechanics defect, not a bad story: the work
    # exists and the only thing missing is the `git commit` the executor owed.
    # Failing it discards a finished implementation and cascade-skips
    # everything downstream of it, which is a far larger loss than the defect.
    # This happened for real — a story in this very phase finished its work
    # and returned without committing.
    #
    # THE SUBSET IS THE GUARD, and it is the only thing making this safe to do
    # on someone else's behalf. `implementation.files` is what the planner said
    # this story would touch. When every modified path is inside that list, the
    # orchestrator knows exactly what it is committing and to which story it
    # belongs. One path outside the list means the tree holds something nobody
    # declared — a stray edit, a half-finished second concern, another story's
    # leftovers — and the orchestrator has no basis to attribute it. That case
    # takes the unchanged failure flow below; it is never rescued, never
    # partially staged, and never trimmed down to the declared subset to make
    # it fit.
    rescued_stories = []
    for full_story in no_commit_stories:
        wt = all_worktrees[full_story.id]
        pre_rescue_head = git -C [wt.worktree_path] rev-parse HEAD

        # 1. Is there anything to rescue? A clean tree means the executor wrote
        #    nothing at all; the failure is real and stands.
        dirty_paths = paths from `git -C [wt.worktree_path] status --porcelain`
                      (both sides of a rename count as modified paths)
        if dirty_paths is empty:
            continue    # falls through to the failure flow below

        # 2. The subset guard. `implementation.files` comes from the CLI, not
        #    from a raw read of the tasks file — get-story-context is the same
        #    verb the executor itself bootstraps with, so orchestrator and
        #    worker read one document through one reader.
        declared_files = $AIMI_CLI get-story-context [full_story.id] --tasks-file [WAVE_TASKS_FILE]
                         → .story.implementation.files
        # `implementation` is optional in schema v3.3. Absent or empty declares
        # nothing, so nothing can be inside it — no list, no rescue. Do not
        # read an absent list as "anything is allowed"; that inverts the guard.
        if declared_files is absent or empty:
            continue    # falls through to the failure flow below
        if any path in dirty_paths is not in declared_files:
            Report: "[full_story.id] not rescued — modified files outside implementation.files: [the offending paths]"
            continue    # falls through to the failure flow below

        # 3. Subset holds. Commit on the executor's behalf, staging the
        #    modified declared paths BY NAME — never `-A`, never `.`, the same
        #    rule the story executor itself follows.
        cd [wt.worktree_path]
        git add [each path in dirty_paths]
        git commit -m "feat([full_story.id]): [full_story.title]" -m "Committed by the wave orchestrator: the executor finished the work and returned without committing it."

        # 4. Trust the tree, not the exit code — a pre-commit hook can refuse
        #    after `git commit` has already printed. If HEAD did not move, the
        #    rescue did not happen and the story takes the failure flow.
        rescued_head = git -C [wt.worktree_path] rev-parse HEAD
        if rescued_head == pre_rescue_head:
            Report: "[full_story.id] not rescued — the rescue commit did not land (hook refused?)"
            continue    # falls through to the failure flow below

        rescued_stories.append(full_story)
        stalled_note = " (stalled executor — resolved by commit rescue)" if full_story.id in stalled_story_ids else ""
        Report: "[full_story.id] rescued[stalled_note] — executor left [len(dirty_paths)] modified file(s), all inside implementation.files; committed as [rescued_head]:"
        Report: git -C [wt.worktree_path] show --stat --format= [rescued_head]

    # Move the stories that were NOT rescued to failed
    for full_story in no_commit_stories and not in rescued_stories:
        $AIMI_CLI mark-failed [full_story.id] "No commit detected after execution" --tasks-file [WAVE_TASKS_FILE]
        $AIMI_CLI cascade-skip [full_story.id] --tasks-file [WAVE_TASKS_FILE]
        stalled_note = " (stalled executor — resolved by mark-failed + cascade-skip)" if full_story.id in stalled_story_ids else ""
        Report: "[full_story.id] failed (no commit detected)[stalled_note]. Dependent stories cascade-skipped."

    # Replace succeeded_stories with the ones carrying a commit — verified by
    # the worker itself, or rescued above. A rescued story is a SUCCESS from
    # here on: it merges with the wave and reaches mark-complete like any
    # other, because its work is on its branch exactly as if the executor had
    # committed it. The rescue is reported so the human sees the diff someone
    # else committed; it is not tracked as a separate story state.
    succeeded_stories = verified_stories + rescued_stories

    # Handle failures first
    for full_story in failed_stories:
        # Prefer the structured failureCause over generic message when available
        payload = result_payload_by_id.get(full_story.id)
        cause = (payload.get("failureCause") if payload else None) or "Failed during parallel wave [wave]"
        $AIMI_CLI mark-failed [full_story.id] "[cause]" --tasks-file [WAVE_TASKS_FILE]
        $AIMI_CLI cascade-skip [full_story.id] --tasks-file [WAVE_TASKS_FILE]
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
                "[merge_cwd] itself — this group's execution root, whichever mode created it — and any live dev server running inside it are left untouched by this failure, so the conflict can be resolved directly in the still-live working tree."
                "Merged story worktrees were removed; the ones that did NOT merge keep both their worktree and their branch, so the retry has something to retry."

                # Cleanup this wave's worktrees -- but ONLY the ones whose work
                # is already reachable from the merge target. merge_all_worktrees
                # processes its argv in order and stops at the first conflict
                # without attempting the rest, so a story from the conflicting
                # one onward has NOT been merged: removing it without
                # --keep-branch would run `git branch -D` on the only ref naming
                # its commits, stranding them. This is the same rule the
                # Phase-Mode Paired Split conflict path already applies to its
                # own members (see "Merge Split Branches Into the Phase Branch"),
                # and the two must not disagree about the same scenario.
                for full_story_id, wt in all_worktrees:
                    cd EXEC_ROOT[wt.group_key]
                    if git -C [EXEC_ROOT[wt.group_key]] merge-base --is-ancestor [wt.worktree_name] [EXEC_BRANCH[wt.group_key]]:
                        # Merged: its commits live on the target branch, so the
                        # branch ref has no remaining consumer.
                        $WORKTREE_MGR remove [wt.worktree_name]
                    else:
                        # Unmerged -- the conflicting story, anything after it
                        # merge-all never reached, and every story that failed
                        # earlier in this wave. Leave the worktree AND the branch
                        # in place; report the branch so the user can find it.
                        Report: "  kept (unmerged): [wt.worktree_name]"

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
                # KNOWN-GAP trailers from the commit body for backward compat. Two spellings
                # are matched -- bare "KNOWN-GAP:" and "KNOWN-GAP (US-NNN):" with the story id
                # folded in -- because a worker legitimately writes either one, and a
                # single-spelling grep silently drops whichever it does not cover. Both stay
                # anchored to line start so a KNOWN-GAP mention inside a paragraph is never
                # extracted as if it were a trailer.
                ```bash
                mkdir -p .aimi/known-gaps
                # Pseudo: prefer payload; fall back to commit grep
                payload_gaps="${result_payload_by_id[full_story.id].knownGaps or []}"
                if [ -n "$payload_gaps" ] && [ "$payload_gaps" != "[]" ]; then
                  WORKER_GAPS=$(printf '%s\n' "$payload_gaps")
                else
                  WORKER_GAPS=$(git -C "[all_worktrees[full_story.id].worktree_path]" log -1 --format=%B | grep -E '^KNOWN-GAP( \([^)]+\))?:' || true)
                fi
                # Discriminated by PLAN_DISC, this run's own plan identity (see
                # `### Plan Discriminator` under Multi-Repo Handling) — two plans
                # that both produce a gap for the same story id on the same day
                # would otherwise compose the same path and silently truncate
                # each other's finding.
                if [ -n "$WORKER_GAPS" ]; then
                  GAP_DATE=$(date +%Y-%m-%d)
                  GAP_FILE=".aimi/known-gaps/${GAP_DATE}-[full_story.id]-[PLAN_DISC].md"
                  printf '%s\n' "$WORKER_GAPS" > "$GAP_FILE"
                fi
                # --- Extract verify evidence: the FOURTH result_json field this
                # command consumes, beside .commit, .failureCause and .knownGaps ---
                # The story-executor Result Contract carries `verify`
                # ({exit, preExit, segments, discriminating}) — the count of verify
                # segments that behaved differently before the story's work than
                # after. Empty here is a real answer and a common one: an executor
                # whose payload predates that contract, a payload recovered by the
                # fallback parse rather than read as JSON, or a story whose verify
                # never ran. It is NOT the same as a zeroed evidence object, and the
                # call below is written so the two can never collapse into each other.
                VERIFY_EVIDENCE_JSON="${result_payload_by_id[full_story.id].verify or ''}"
                ```

                $AIMI_CLI mark-complete [full_story.id] --tasks-file [WAVE_TASKS_FILE] --evidence "$VERIFY_EVIDENCE_JSON"

                # Pass `--evidence` ONLY when `VERIFY_EVIDENCE_JSON` is non-empty. When it is empty the flag is omitted ENTIRELY — the call is exactly `mark-complete [full_story.id] --tasks-file [WAVE_TASKS_FILE]`, never `--evidence ""`, never `--evidence {}`, and never `--verify-evidence`: the flag is spelled `--evidence` and `cmd_mark_complete` parses no other spelling, so a `--verify-evidence` reached for on the strength of the variable name falls through to the positional parser and is read as a second story id.
                # Two reasons the flagless argv has to stay byte-identical rather than
                # gaining an always-passed empty flag. It is the argv the pre-existing
                # golden `mark-complete` recordings replay, so a flag that is always
                # present rewrites all of them for nothing. And an empty evidence object
                # would persist at `verification.evidence` as "we looked and found
                # nothing" — precisely the conflation this reporting exists to remove:
                # `tasks.py`'s `_report_discriminating` routes a missing count to
                # `unrecorded` and a real 0 to `blind`, and those are two different
                # statements about the same run.

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
                        # verification-report already normalizes a non-string
                        # url to the empty string, so no `// empty` is needed
                        # here — see the closed jq -r non-string hazard note
                        # above Container Dev Server Bootstrap.
                        STORY_TASKS_FILE="$AIMI_ROOT/$TASKS_PATH"
                        STORY_VERIFICATION_URL=$($AIMI_CLI verification-report --tasks-file "$STORY_TASKS_FILE" | jq -r --arg id "[full_story.id]" '.visual[] | select(.id == $id) | .url')
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
                            : "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"; [ -x "$WORKTREE_MGR" ] || { echo "WORKTREE_MGR is stale: $WORKTREE_MGR does not exist — re-run check-version --quiet --fix" >&2; exit 1; }
                            cd "$AIMI_ROOT"
                            STORY_TASKS_FILE="$PHASE_TASKS_PATH"
                            STORY_VERIFICATION_URL=$($AIMI_CLI verification-report --tasks-file "$STORY_TASKS_FILE" | jq -r --arg id "[full_story.id]" '.visual[] | select(.id == $id) | .url')
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
                                $AIMI_CLI set-verification [full_story.id] skipped --reason "no dev server running for [PHASE_BRANCH]" --tasks-file [WAVE_TASKS_FILE]
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
                                $AIMI_CLI set-verification [full_story.id] skipped --reason "no dev server resolved for project group [group_key]" --tasks-file [WAVE_TASKS_FILE]
                                Report: "[full_story.id] visual verification skipped — no dev server resolved for project group [group_key]."
                                SKIP_VISUAL=true
                            else:
                                ```bash
                                WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
                                : "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"; [ -x "$WORKTREE_MGR" ] || { echo "WORKTREE_MGR is stale: $WORKTREE_MGR does not exist — re-run check-version --quiet --fix" >&2; exit 1; }
                                BRANCH_NAME=$(jq -r '.metadata.branchName' "$AIMI_ROOT/$TASKS_PATH")
                                if [ "[group_key]" = "DEFAULT" ]; then
                                  cd "$AIMI_ROOT"
                                else
                                  cd "$AIMI_ROOT/[group_key]"
                                fi
                                STORY_TASKS_FILE="$AIMI_ROOT/$TASKS_PATH"
                                STORY_VERIFICATION_URL=$($AIMI_CLI verification-report --tasks-file "$STORY_TASKS_FILE" | jq -r --arg id "[full_story.id]" '.visual[] | select(.id == $id) | .url')
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
                                $AIMI_CLI set-verification [full_story.id] passed --tasks-file [WAVE_TASKS_FILE]
                                Report: "[full_story.id] visual verification passed."
                            else:
                                $AIMI_CLI set-verification [full_story.id] failed --tasks-file [WAVE_TASKS_FILE]
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
                                    $AIMI_CLI set-verification [full_story.id] passed --tasks-file [WAVE_TASKS_FILE]
                                else:
                                    $AIMI_CLI set-verification [full_story.id] failed --tasks-file [WAVE_TASKS_FILE]
                                    Report: "[full_story.id] visual verification failed — [reason]. (advisory)"

                                if ATTRIBUTION.has_errors:
                                    Report: "[full_story.id] console: \(ATTRIBUTION.summary)"
                                    CONSOLE_BUFFER[full_story.id] = ATTRIBUTION

                                agent-browser close
                            else:
                                $AIMI_CLI set-verification [full_story.id] skipped --reason "agent-browser not installed" --tasks-file [WAVE_TASKS_FILE]
                                Report: "[full_story.id] visual verification skipped — agent-browser not installed."

                # Non-visual stories: the verdict now comes from the verify evidence
                # mark-complete already persisted above (see VERIFY_EVIDENCE_JSON) —
                # a blanket rewrite to "passed" here claimed success whether or not
                # this story's own check ever ran, which is exactly the dishonesty
                # judge-verification exists to close. It is a safe no-op (writes
                # nothing, reports why) for a story already judged, so the pending
                # check below is an optimization, not a correctness requirement.
                elif full_story.verification and full_story.verification.status == "pending":
                    $AIMI_CLI judge-verification [full_story.id] --tasks-file [WAVE_TASKS_FILE]

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

**Phase and container mode (`EXEC_OWNS_ROOT=true`):** cleanup runs per project group with CWD = `EXEC_ROOT[group_key]`, matching worktrees named `"[PLAN_DISC]-[EXEC_BRANCH[group_key]]-US-*"` — the same derivation rule as `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md`'s Execution Context: EXEC_ROOT, EXEC_BRANCH, EXEC_OWNS_ROOT, EXEC_KEEPS_BRANCH subsection (`PHASE_CONTAINER_PATHS[group_key]`/`PHASE_BRANCH` in phase mode, `CONTAINER_PATHS[group_key]`/`branchName` in container mode). Step 4's own wave loop rebuilds `EXEC_ROOT`/`EXEC_BRANCH` fresh each wave, scoped to that wave's own stories; Post-Loop Cleanup runs after the loop ends, so it re-derives them here across every unique `group_key` with at least one story scheduled this run, rather than reading a stale, single-wave-scoped copy. In phase mode every `group_key` resolves to its own `PHASE_CONTAINER_PATHS[group_key]` — the same `PHASE_BRANCH` name, but each group's own repository's own container — so in the common case of a single group_key this degenerates to exactly the single iteration today's phase-only cleanup already runs; on a genuinely multi-repo phase that grouped stories under more than one `group_key`, the loop below runs once per group_key against that group's own container, sweeping each participating repository in turn rather than repeating a pass against the one the first iteration already covered. The main working tree (`AIMI_ROOT`) is never `cd`'d into by this step.

```
for each unique group_key with at least one story scheduled this run:
    cd [EXEC_ROOT[group_key]]
    $WORKTREE_MGR list
    # For each worktree matching "[PLAN_DISC]-[EXEC_BRANCH[group_key]]-US-*":
    $WORKTREE_MGR remove [worktree_name]

    # Legacy pass — the un-prefixed shape a run predating the plan discriminator
    # left inside this same container. Same list, same CWD; only the pattern
    # differs, and no run can create another one.
    # For each worktree matching "[EXEC_BRANCH[group_key]]-US-*":
    $WORKTREE_MGR remove [worktree_name]
```

**Flat/inline mode (`PHASE_MODE=false`, `CONTAINER_MODE=false`):** unchanged.

```
# Remove any remaining worktrees (safety cleanup)
# Per-project cleanup rule — see Multi-Repo Handling section.
for each unique project_root (including CWD for DEFAULT group):
    cd [project_root]
    $WORKTREE_MGR list
    # For each worktree matching "[PLAN_DISC]-[branchName]-US-*":
    $WORKTREE_MGR remove [worktree_name]

# When no stories have project fields, use current directory (backwards compatible):
$WORKTREE_MGR list
# For each worktree matching "[PLAN_DISC]-[branchName]-US-*":
$WORKTREE_MGR remove [worktree_name]
```

### Visual Follow Session — Keep Open

See the Visual Follow Lifecycle section (Phase 4 — Keep Open on Completion).

If `VISUAL_FOLLOW=true`, do NOT close the `visual-follow` session.

Report: `"Visual follow session still open — close manually when done: agent-browser --session visual-follow close"`

### Finalize Step

Runs once, immediately after Post-Loop Cleanup above and before **Phase Completion** below — so the closing commit is already on the branch by the time **Offer a Pull Request** and Step 5 read it. It exists for the one commit no story can structurally make: the version bump, the CHANGELOG entry, the regenerated index. Their content *is* this run's own diff, so they cannot be written until every story has merged, and a story that wrote them anyway would be racing every sibling story for the same file — which is exactly the collision `validate-tasks` warns about when a story's `implementation.files` claims a path this key declares.

**Only the top-level orchestrator runs it.** A Phase-Mode Paired Split sub-orchestrator reaches Post-Loop Cleanup too and must skip this section outright: its parent runs the step once, from **Continue to Phase Completion**, after every member branch has merged into `$PHASE_BRANCH`. The discriminator is the one this file already uses for every claim-releasing call — `PHASE_MODE=true` with `$PHASE_ID` unset is a sub-orchestrator, and nothing else is. Two orchestrators each writing a closing commit would put two of them on one branch, which is the one shape a later reverter cannot undo by naming a single sha.

The step is **declared, never inferred**: it runs only when this run's own tasks file carries `metadata.finalize` — the `{intent, files[], commitSubject}` object `${CLAUDE_PLUGIN_ROOT}/commands/plan.md`'s metadata contract writes and explicitly leaves to its consumer to run. This is that consumer. Read the key with the same `metadata` verb idiom Step 5 already uses for `verification-report`: `--tasks-file "$PHASE_TASKS_PATH"` in phase mode, the flag omitted in flat mode, where `init-session` has long since pointed session state at the file this run executed.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
if [ "${PHASE_MODE:-false}" = "true" ]; then
  FINALIZE_JSON=$($AIMI_CLI metadata --tasks-file "$PHASE_TASKS_PATH" 2>/dev/null | jq -c '.finalize // empty')
else
  FINALIZE_JSON=$($AIMI_CLI metadata 2>/dev/null | jq -c '.finalize // empty')
fi
FINALIZE_STATUS=skipped
FINALIZE_COMMIT=""
FINALIZE_REASON="metadata.finalize not declared"
FINALIZE_INTENT=$(printf '%s' "$FINALIZE_JSON" | jq -r '.intent // empty' 2>/dev/null)
FINALIZE_SUBJECT=$(printf '%s' "$FINALIZE_JSON" | jq -r '.commitSubject // empty' 2>/dev/null)
FINALIZE_FILES=$(printf '%s' "$FINALIZE_JSON" | jq -r '.files[]?' 2>/dev/null)
printf 'finalize: status=%s (%s)\n' "$FINALIZE_STATUS" "$FINALIZE_REASON"
```

`// empty` is what makes an absent key silent, the same reason Step 2's `baseRef` read spells it that way: `.finalize` answers `null` for a key that is not there, and the word `null` in `$FINALIZE_JSON` would read downstream as a declared step.

**An absent key takes zero of the path below.** When `$FINALIZE_JSON` is empty the section is over at the line above: no worktree is created, no executor is spawned, nothing is committed, and the run continues into Phase Completion byte-for-byte as it did before this section existed. Every tasks file written before the key entered the schema takes this branch, and so does every plan that simply has no closing step. The only trace is the streamed status line, which is a report and not a change to the branch.

**More than one project group is `skipped` too, and on purpose.** When this run scheduled stories under more than one `group_key` (the multi-repo layout Multi-Repo Handling describes), record `FINALIZE_STATUS=skipped` with `FINALIZE_REASON` naming the count, and run nothing. `metadata.finalize` names **one** repository's closing step — `plan.md`'s patch rule gives each PROJECT-axis file its own — so a single key cannot be spread across N repositories, and inventing N closing commits from one declaration would put a version bump written for one repository onto every other repository's branch. Reporting the skip is the honest answer; guessing is not.

**One worktree, cut from this group's own tip, exactly as Step 4 cuts a story's.** Same `cd` to that group's execution root, same `create`, and the same two sentinels read from its output — this section invents no second mechanism for something Step 4 already does:

```
FINALIZE_WORKTREE = EXEC_BRANCH[group_key] + "-finalize"

cd EXEC_ROOT[group_key]
create_output = $WORKTREE_MGR create [FINALIZE_WORKTREE] --from [EXEC_BRANCH[group_key]]

# Same two unprefixed lines Step 4 reads, same last-occurrence rule.
WORKTREE_PATH = value of the last WORKTREE_PATH= line in create_output
WORKTREE_BASE = value of the last WORKTREE_BASE= line in create_output

if WORKTREE_PATH is absent or WORKTREE_BASE is absent:
    FINALIZE_STATUS = failed
    FINALIZE_REASON = "worktree create printed no WORKTREE_PATH/WORKTREE_BASE sentinel"
    skip the rest of this section and continue to Phase Completion

# The commits this closing step is written ABOUT: everything the run merged.
FINALIZE_COMMITS = git -C [EXEC_ROOT[group_key]] log --oneline [CONTAINER_BASE]..[EXEC_BRANCH[group_key]]
```

The `-finalize` suffix is chosen so the name does **not** match the `"[PLAN_DISC]-[EXEC_BRANCH[group_key]]-US-*"` pattern Post-Loop Cleanup sweeps — nor the un-prefixed legacy pattern in the pass beside it, since `[EXEC_BRANCH[group_key]]-finalize` fails the `-US-*` tail of both globs alike, which is what carries this invariant across the rename unchanged in substance. Post-Loop Cleanup has already run by the time this section starts, but the two must not overlap even on a re-entry: this section removes its own worktree below, and a sweep that also claimed it would be racing for the same tree.

**One executor, not a fixed command.** The step needs judgment — deciding the increment, writing a CHANGELOG entry that says what *this* set of commits did — which is why it gets the merged-commit list alongside the key's own intent rather than a hardcoded recipe:

```
Task(
    subagent_type: "general-purpose",
    model: <AGENT_MODELS.executor when not "inherit">,
    description: "Finalize [EXEC_BRANCH[group_key]]",
    prompt: [
        - WORKTREE_PATH = the path read from create_output above
        - INTENT = metadata.finalize.intent          ← what this closing step is for
        - FILES = metadata.finalize.files[]          ← the only paths it may write
        - COMMITS = FINALIZE_COMMITS                 ← what this run actually did
        - COMMIT_SUBJECT = metadata.finalize.commitSubject
        - Make exactly ONE commit, whose subject line is COMMIT_SUBJECT verbatim
        - Stage only paths listed in FILES; never `git add -A` and never `.`
        - Never amend, rebase, revert or otherwise rewrite a story's commit
        - Report the short sha of the commit made, or that none was made
    ]
)
```

**Merge it the way a story merges, then remove it.** Same primitive, same target, same CWD rule — `merge-all` issues a bare `git checkout` against whatever repository its CWD belongs to, so this runs from the group's execution root like every other merge in this file:

```
cd EXEC_ROOT[group_key]
merge_result = $WORKTREE_MGR merge-all [FINALIZE_WORKTREE] --into [EXEC_BRANCH[group_key]]

if merge_result is non-zero:
    FINALIZE_STATUS = failed
    FINALIZE_REASON = "merge of [FINALIZE_WORKTREE] into [EXEC_BRANCH[group_key]] conflicted"
    Report the conflict output verbatim, keep the worktree and its branch so the
    closing commit is not stranded, and continue to Phase Completion
else:
    FINALIZE_COMMIT = git -C [EXEC_ROOT[group_key]] rev-parse --short [EXEC_BRANCH[group_key]]
    FINALIZE_STATUS = ran
    $WORKTREE_MGR remove [FINALIZE_WORKTREE]
```

**The commit is separate and trivially reversible.** It is the branch's last commit, its subject is `metadata.finalize.commitSubject` and nothing else, and `FINALIZE_COMMIT` carries its sha into the report so a reader has the one argument `git revert` needs. No story commit is touched, amended, reordered or rewritten by any path in this section — the executor above is told so explicitly, and this section never calls anything that could.

**Nothing here can fail the run, and that is a rule rather than a default.** `FINALIZE_STATUS` takes exactly one of `ran`, `skipped` or `failed`; `failed` is reported and never propagated to `/aimi:execute`'s own exit status, and no branch of this section aborts the command. By the time it runs, every story has already been executed, verified and merged: turning a whole completed run red over a version bump would throw away work that is finished and correct, and would leave the operator with a branch that is fine and a command that says otherwise. A `failed` finalize is a line in the report and a worktree left in place to retry from.

Emit the status line on **every** path through this section, including the two that do nothing:

```
finalize: status=[FINALIZE_STATUS] ([FINALIZE_REASON or FINALIZE_COMMIT])
```

Step 5's `## Finalize` report section renders these same variables — see **If all stories complete** below.

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
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
PHASE_DIR_PATH="$AIMI_ROOT/.aimi/tasks/$FEATURE/$PHASE_DIR"
# Hoisted once, above the loop -- never re-called per split_file. Reads the
# same pendingCount split-detect already computes from the identical
# `(.status // "pending") != "completed"` predicate the paragraph below names.
PHASE_MEMBERS_JSON=$($AIMI_CLI split-detect --dir "$PHASE_DIR_PATH" | jq -c '.members[]')
PHASE_PENDING=0
while IFS= read -r split_file; do
  [ -n "$split_file" ] || continue
  SPLIT_FILE_PENDING=$(printf '%s\n' "$PHASE_MEMBERS_JSON" | jq -r --arg p "$split_file" 'select(.path == $p) | .pendingCount')
  PHASE_PENDING=$((PHASE_PENDING + ${SPLIT_FILE_PENDING:-0}))
done <<< "$PHASE_SPLIT_FILES"
```
The phase's split work only counts as complete when `PHASE_PENDING` is `0` — i.e. **every** member reports zero outstanding stories, not just the first two. Summing over the full member list rather than `$PHASE_ACTIVE_SPLIT_FILES` is deliberate: a member skipped as inactive contributes `0` either way, but reading the full list keeps this count correct even if a sibling session touched a member between Step 1.7's filter and now.

The predicate excludes the two TERMINAL statuses — `completed` and `skipped` — and treats everything else as outstanding. It is **not** `.status == "pending"`, so that this count and Step 1.7's **Active Split Files** filter answer the same question over the same file. The two must agree: Active Split Files decides which members get spawned, and this count decides whether the phase may close. Counting only `"pending"` here would treat `in_progress` (and any status a future story adds, and a story with no `status` field at all) as finished, letting a phase reach `roadmap-set-status --status completed` with a story still mid-flight.

Testing against the terminal pair rather than against `completed` alone is what makes both sites correct by one rule instead of by two lists of non-terminal statuses that can drift apart — and the pair is what the rest of the plugin already means by "done": `tasks.py`'s `_dep_status_done` unblocks a dependent on either, and `roadmap.py`'s `ground_truth` closes a phase on either. Excluding only `completed` was issue #112 surviving here after `ground_truth` had been fixed: a member whose remaining stories were all deliberately skipped stayed active on every run, and this gate never reached zero.

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

For every entry the phase declared in `roadmap.json`'s `creates[]`, confirm the artifact is actually present in at least one participating repository's own phase branch — not merely that some other phase's `needs` resolved against it. This is a distinct, stricter check than `validate-contracts`: `validate-contracts` (outline 03) answers "does a `needs` entry have a completed, handoff-documented provider," using `roadmap.json` and `handoff.md` as its only inputs, and never inspects source code. This check answers "does this phase's own promised artifact exist, somewhere among its participating repositories," by inspecting each repository's own phase container's actual tracked files.

**Union across repositories, not per-repository attribution.** An identity is `verified` for the phase when **any** participating repository's own call reports it `verified`; it is `missing` only when **every** participating repository reports it `missing`. This is a union, never a per-repository assignment, because a phase's `creates[]` contract is declared once, at the phase level: `scope-contexts.md`'s naming table (§ Creates/Needs Contracts) names every artifact by kind — endpoint, table, service, file — with no repository qualifier, so a phase never declares which repository will deliver a given artifact. There is no per-repository slot to attribute a verdict against; the only question this check can ask of an identity is whether it exists **anywhere** among the phase's own participating repositories, and the answer is the union of every repository's own answer.

**Split-mode timing (`PHASE_SPLIT_MODE=true`):** this check runs once per participating repository, against that repository's own container — and for a given repository, it never runs before **that repository's own merge** has landed. Merge Split Branches Into the Phase Branch (above) issues one `merge-all` call per repository, not one phase-wide call, so a repository's own `$PHASE_BRANCH` reflects that repository's split work only once **its own** `merge-all` call has returned successfully — a sibling repository's merge still being pending, or having conflicted, has no bearing on whether this repository is safe to check. Merge Split Branches Into the Phase Branch already STOPs (and releases the claim) on any repository's merge conflict before Phase Completion is ever reached, so every participating repository's container is guaranteed merged by the time this section runs — this note documents why that guarantee holds per repository, not a new gate this section itself enforces.

> **Cross-story flag for the auditor:** this story's brief describes creates verification as invoking "the outline:03 contract-validation CLI surface... in its phase-closure mode" (e.g. `validate-contracts <phase-id> --root <path>`) as an illustrative example. The landed `validate-contracts` (outline 03) has no `--root` flag or code-existence mode, and its own notes scope it exclusively to needs-vs-creates delivery resolution ("wiring validate-contracts and roadmap-sweep into plan.md and execute.md is owned by outline 08 and outline 11" — this story). Extending `validate-contracts`'s jq-only, roadmap.json-only logic to also grep real source files would be new scope outline 03 never claimed. Creates verification therefore ships as **its own CLI verb, `verify-creates`** — not as an extension of `validate-contracts`, and no longer as executable prose here. It was prose until this section was rewritten: five hand-written steps built on `[ -f ]` and a bare `git grep -l -F`, which no Bash suite could reach and which was wrong in five of nine measured scenarios (a docs-only mention, a `TODO` comment and a test-file mention each closed a phase; a directory identity could never verify, because `[ -f ]` is false on a directory; and a project that committed its own `.aimi/` found the identity inside the very `roadmap.json` that declared it). Reconcile if a future story wants to fold `verify-creates` into `validate-contracts` instead.

#### Inputs

- `FEATURE` and `PHASE_ID` — the claimed phase. Every repository's own `verify-creates` call reads that phase's `creates[]` out of `roadmap.json` itself and takes each entry's own `identity` field, so no `creates` array is extracted here and no second copy of that rule exists in this file, in any repository's call. Because every call reads the same phase-level `creates[]`, every repository's own verdict array covers the identical, identically-ordered identity set.
- `PARTICIPATING_GROUP_KEYS` — every project group with at least one story (non-split phase) or `$PHASE_SPLIT_FILES` member (split phase) scheduled for this phase, derived fresh in this block by the same rule that populated `PHASE_CONTAINER_PATHS[group_key]` for this phase run (Create Phase Containers Per Project Group's Derive Participating Project Groups, above) — branching on `PHASE_SPLIT_MODE` exactly as the adjacent Multi-File Pending Count block already does. Split mode sums over the **full** `$PHASE_SPLIT_FILES` member list, not just this run's active subset — the same reason Multi-File Pending Count does: a repository whose split member already completed on a prior run still delivered artifacts there, and still needs checking. For each participating group, its own container — `<repo toplevel>/.worktrees/$PHASE_BRANCH` (`${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Phase Container Paths Per Project Group), recomputed fresh via `git -C ... rev-parse --show-toplevel`, never read from a value assumed to survive from Step 1.7 — is passed as that repository's own `--dir`; it is the checkout whose **tracked** files are searched there. With exactly one participating group — today's single-repo case — this is exactly today's single `PHASE_CONTAINER_PATH` value, unchanged.

#### Procedure

One `verify-creates` call **per participating repository** — never a single call regardless of how many repositories are involved, and never a path assumed to survive from Step 1.7 or from a prior loop iteration, since each Bash call is an isolated shell. `verify-creates` (`cmd_verify_creates` in `aimi-cli.sh`, **unmodified by this story** — it already accepts `--dir`, so N calls with N different `--dir` values need no verb change) runs four deterministic steps per `creates[]` entry — a tracked-path match via `git ls-files`, which matches a **directory** as well as a file; leading-HTTP-method extraction, so `POST /api/notifications` is searched as `/api/notifications`, which is what route code actually contains; a `git grep -n -I -F` over tracked source that excludes documentation, tests and `.aimi/`; and a filter that drops hits which are only a `TODO`/`FIXME`/`XXX`/`HACK` comment. Identity kinds are not dispatched on: every identity, in every repository's call, runs the same four steps.

It is a **query, not a gate**, for each repository's own call — any verdict array exits `0`, including one where every entry is `missing` — so branch on the JSON below, never on a `missing` verdict having "failed". A non-zero exit from any one repository's call means that repository's tooling could not run at all (unknown flag, absent or malformed `roadmap.json`, a `--dir` that is not a directory) and its stderr says which; per the union rule above, one repository's tooling failure fails the whole phase's check, so this is decided before any repository's missing count is ever consulted.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"

# Derive PARTICIPATING_GROUP_KEYS fresh in this block — Step 1.7's populated
# PHASE_CONTAINER_PATHS map does not persist across Bash calls. Same rule,
# same source files, as Create Phase Containers Per Project Group's own
# Derive Participating Project Groups — except split mode sums over the FULL
# member list, $PHASE_SPLIT_FILES, exactly like the adjacent Multi-File
# Pending Count block, not just this run's active subset.
if [ "$PHASE_SPLIT_MODE" = true ]; then
  PHASE_DIR_PATH="$AIMI_ROOT/.aimi/tasks/$FEATURE/$PHASE_DIR"
  # Hoisted once, above the loop -- never re-called per split_file.
  PHASE_MEMBERS_JSON=$($AIMI_CLI split-detect --dir "$PHASE_DIR_PATH" | jq -c '.members[]')
  CV_GROUP_RAW=""
  while IFS= read -r split_file; do
    [ -n "$split_file" ] || continue
    CV_PROJECT=$(printf '%s\n' "$PHASE_MEMBERS_JSON" | jq -r --arg p "$split_file" 'select(.path == $p) | .project // "."')
    CV_GROUP_RAW="${CV_GROUP_RAW}${CV_PROJECT}"$'\n'
  done <<< "$PHASE_SPLIT_FILES"
  PARTICIPATING_GROUP_KEYS=$(printf '%s\n' "$CV_GROUP_RAW" | grep -v '^$' | sort -u)
  [ -n "$PARTICIPATING_GROUP_KEYS" ] || PARTICIPATING_GROUP_KEYS="."
else
  # project-groups now owns the jq, the sort-unique pipeline and the
  # empty-fallback this branch used to run inline. A refusal here (an
  # invalid project value) is new: this site never validated before.
  CV_GROUPS_JSON=$($AIMI_CLI project-groups --tasks-file "$PHASE_TASKS_PATH") || {
    $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
    exit 1
  }
  PARTICIPATING_GROUP_KEYS=$(printf '%s' "$CV_GROUPS_JSON" | jq -r '.groups[]')
fi

# One verify-creates call per participating repository. Each repository's own
# container is recomputed fresh here — <repo toplevel>/.worktrees/$PHASE_BRANCH,
# the identical formula container-execution.md's Phase Container Paths Per
# Project Group contract uses — never read from a value assumed to survive
# from Step 1.7. Each call's own exit status is captured with a pre-initialized
# variable plus an || assignment, never a bare $? read, so one repository's
# tooling failure can never abort the loop before the remaining repositories
# are checked.
PHASE_CV_RESULTS=""
while IFS= read -r CV_PROJECT; do
  [ -n "$CV_PROJECT" ] || continue
  case "$CV_PROJECT" in
    .)
      CV_GROUP_KEY="DEFAULT"
      CV_GROUP_ROOT="$AIMI_ROOT"
      ;;
    /*|..|../*|*/..|*/../*)
      echo "Invalid project \"$CV_PROJECT\" for phase $PHASE_ID" >&2
      $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
      exit 1
      ;;
    *)
      if ! [[ "$CV_PROJECT" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$ ]]; then
        echo "Invalid project \"$CV_PROJECT\" for phase $PHASE_ID" >&2
        $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
        exit 1
      fi
      CV_GROUP_KEY="$CV_PROJECT"
      CV_GROUP_ROOT="$AIMI_ROOT/$CV_PROJECT"
      ;;
  esac

  CV_GROUP_TOPLEVEL=$(git -C "$CV_GROUP_ROOT" rev-parse --show-toplevel 2>/dev/null) || CV_GROUP_TOPLEVEL=""
  if [ -z "$CV_GROUP_TOPLEVEL" ]; then
    echo "Not a git repository: $CV_GROUP_ROOT (project \"$CV_PROJECT\" for phase $PHASE_ID)" >&2
    $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
    exit 1
  fi
  CV_CONTAINER="$CV_GROUP_TOPLEVEL/.worktrees/$PHASE_BRANCH"

  # Judge with the CLI the phase itself produced, when this repository's own
  # container carries one: a phase that changes aimi-cli.sh's own logic (e.g.
  # a filter verify-creates itself relies on) must be judged by that changed
  # code, not by whatever the global cache still has installed. This is only
  # ever true for a repository that is this plugin's own source tree; every
  # other participating repository's container has no
  # plugins/aimi-engineering of its own, and CV_CLI falls back to today's
  # resolution there. Either way the fallback is named on one stderr line, so
  # the report never leaves silent which code judged this repository.
  CV_CONTAINER_CLI="$CV_CONTAINER/plugins/aimi-engineering/scripts/aimi-cli.sh"
  if [ -x "$CV_CONTAINER_CLI" ]; then
    CV_CLI="$CV_CONTAINER_CLI"
  else
    CV_CLI="$AIMI_CLI"
    echo "creates-verification: $CV_GROUP_KEY: no executable aimi-cli.sh in container ($CV_CONTAINER_CLI) -- judging with the resolved CLI ($AIMI_CLI) instead" >&2
  fi

  CV_CALL_EXIT=0
  CV_CALL_OUTPUT=$($CV_CLI verify-creates --feature "$FEATURE" --phase "$PHASE_ID" --dir "$CV_CONTAINER") || CV_CALL_EXIT=$?
  [ "$CV_CALL_EXIT" -eq 0 ] || CV_CALL_OUTPUT='[]'

  PHASE_CV_RESULTS="${PHASE_CV_RESULTS}$(jq -nc \
    --arg gk "$CV_GROUP_KEY" --arg dir "$CV_CONTAINER" \
    --argjson exit "$CV_CALL_EXIT" --argjson verdicts "$CV_CALL_OUTPUT" \
    '{group_key: $gk, dir: $dir, exit: $exit, verdicts: $verdicts}')"$'\n'
done <<< "$PARTICIPATING_GROUP_KEYS"

# Tooling-failure tallies — computed unconditionally, from every repository's
# own RAW verdicts, before any union is attempted. status:"error" is git
# failing inside one repository's call, not an artifact failing to exist; a
# non-zero CV_CALL_EXIT is the same class one level up — that repository's
# call never ran at all. Either one, in ANY repository, dominates the branch
# decision below, before MISSING_COUNT is ever computed.
CV_REPO_COUNT=$(printf '%s\n' "$PARTICIPATING_GROUP_KEYS" | grep -c .)
CV_MULTI=$([ "$CV_REPO_COUNT" -gt 1 ] && echo true || echo false)
CV_EXIT_FAILURES=$(printf '%s\n' "$PHASE_CV_RESULTS" | jq -s '[.[] | select(.exit != 0)] | length')
# Each jq filter below is kept on a single physical line, even though it
# reads dense. A jq-internal name bound with "as" is easy to misread as an
# unassigned bash variable once the filter wraps past one source line, so
# every filter here stays on the line that opens its own quote — a plain
# formatting constraint, not a logic change.
CV_EXIT_LINES=$(printf '%s\n' "$PHASE_CV_RESULTS" | jq -s -r --argjson multi "$CV_MULTI" '.[] | select(.exit != 0) | if $multi then "\(.group_key) (\(.dir)): verify-creates exited \(.exit) and produced no verdicts." else "verify-creates exited \(.exit) and produced no verdicts." end')
ERROR_COUNT=$(printf '%s\n' "$PHASE_CV_RESULTS" | jq -s '[.[] | .verdicts[]? | select(.status == "error")] | length')
ERROR_CREATES=$(printf '%s\n' "$PHASE_CV_RESULTS" | jq -s -r --argjson multi "$CV_MULTI" '.[] as $r | ($r.verdicts[]? | select(.status == "error")) as $v | if $multi then "\($r.group_key): \($v.identity) — \($v.evidence) [git exit \($v.gitStatus)]" else "\($v.identity) — \($v.evidence) [git exit \($v.gitStatus)]" end')
# `unconfirmed` is counted here beside `missing` because both mean the same
# thing to a reader: the artifact was not proven to exist. verify-creates
# returns it for a documentation identity that resolved only through the text
# search -- some tracked file writes the page's name, which is what a table of
# contents does, and is not the page. Counting only `missing` here would let a
# tooling-failed run report "0 further entries" while every doc identity in the
# phase came back mention-only.
CV_RAW_MISSING_COUNT=$(printf '%s\n' "$PHASE_CV_RESULTS" | jq -s '[.[] | .verdicts[]? | select(.status == "missing" or .status == "unconfirmed")] | length')

if [ "$CV_EXIT_FAILURES" -gt 0 ] || [ "$ERROR_COUNT" -gt 0 ]; then
  CV_BRANCH="tooling-failed"
else
  # Union: an identity is verified for the phase when ANY repository verified
  # it; missing only when EVERY repository reported it missing. This step
  # never runs on a set missing a repository's own verdicts — reached only
  # once every repository's own call is confirmed clean above.
  CREATES_REPORT=$(printf '%s\n' "$PHASE_CV_RESULTS" | jq -s --argjson multi "$CV_MULTI" '(.[0].verdicts | map(.identity)) as $order | ([.[] as $r | $r.verdicts[] | {group_key: $r.group_key, identity, status, method, evidence, gitStatus}]) as $flat | [ $order[] | . as $id | ($flat | map(select(.identity == $id))) as $grp | ($grp | map(select(.status == "verified")) | sort_by(.group_key)) as $ver | ($grp | map(select(.status == "missing" or .status == "unconfirmed")) | sort_by(.group_key)) as $und | if ($ver | length) > 0 then {identity: $id, status: "verified", method: $ver[0].method, evidence: $ver[0].evidence, gitStatus: $ver[0].gitStatus} else (if ($und | length) > 0 then $und else ($grp | sort_by(.group_key)) end) as $mis | (if $multi then ($mis | map("\(.group_key): \(.evidence)") | join("; ")) else $mis[0].evidence end) as $ev | {identity: $id, status: "missing", method: $mis[0].method, evidence: $ev, gitStatus: $mis[0].gitStatus} end ]')
  VERIFIED_ARTIFACTS=$(printf '%s' "$CREATES_REPORT" | jq -r '.[] | select(.status == "verified") | "\(.identity) — \(.evidence)"')
  MISSING_CREATES=$(printf '%s' "$CREATES_REPORT" | jq -r '.[] | select(.status == "missing") | "\(.identity) — \(.evidence)"')
  MISSING_COUNT=$(printf '%s' "$CREATES_REPORT" | jq '[.[] | select(.status == "missing")] | length')
  # Which of those undelivered identities are undelivered because they were
  # found ONLY as a mention. Derived from the RAW per-repository verdicts, not
  # from CREATES_REPORT: the union deliberately collapses `unconfirmed` into
  # `missing` so one branch handles both, and this is the one place that still
  # needs to tell them apart -- for the report, never for the branch decision.
  # An identity qualifies when no repository verified it and at least one
  # reported it `unconfirmed`; an identity every repository reported `missing`
  # does not, and neither does one some other repository verified.
  MENTION_ONLY_CREATES=$(printf '%s\n' "$PHASE_CV_RESULTS" | jq -s -r '(.[0].verdicts | map(.identity)) as $order | ([.[] | .verdicts[]?]) as $flat | $order[] | . as $id | ($flat | map(select(.identity == $id))) as $grp | select(($grp | map(.status) | index("verified")) == null) | select(($grp | map(.status) | index("unconfirmed")) != null) | $id')
  MENTION_ONLY_COUNT=$(printf '%s\n' "$PHASE_CV_RESULTS" | jq -s '(.[0].verdicts | map(.identity)) as $order | ([.[] | .verdicts[]?]) as $flat | [ $order[] | . as $id | ($flat | map(select(.identity == $id))) as $grp | select(($grp | map(.status) | index("verified")) == null) | select(($grp | map(.status) | index("unconfirmed")) != null) ] | length')
  if [ "$MISSING_COUNT" -gt 0 ]; then
    CV_BRANCH="missing"
  else
    CV_BRANCH="ok"
  fi
fi

printf 'creates-verification: branch=%s repos=%s exit_failures=%s error_count=%s missing_count=%s mention_only_count=%s\n' \
  "$CV_BRANCH" "$CV_REPO_COUNT" "$CV_EXIT_FAILURES" "$ERROR_COUNT" "${MISSING_COUNT:-0}" "${MENTION_ONLY_COUNT:-0}"
printf -- '--- verified ---\n%s\n--- missing ---\n%s\n--- mention only ---\n%s\n--- tooling exit failures ---\n%s\n--- tooling errors ---\n%s\n' \
  "${VERIFIED_ARTIFACTS:-}" "${MISSING_CREATES:-}" "${MENTION_ONLY_CREATES:-}" "$CV_EXIT_LINES" "$ERROR_CREATES"
```

Every value is still derived with a `jq` select on `.status` — jq is the loop, deliberately instead of a shell `while` that accumulates a variable read after the loop has closed (`test-command-blocks.sh` check 3 catches exactly that shape) — now in two passes: `ERROR_COUNT`/`ERROR_CREATES` are computed from every repository's own **raw**, pre-union verdicts (so a tool failure is visible before any union is attempted), and `CREATES_REPORT`/`VERIFIED_ARTIFACTS`/`MISSING_CREATES`/`MISSING_COUNT` are computed from the **unioned** per-identity array, reached only once every repository's own call is confirmed clean. Each unioned verdict object keeps the existing shape, `{identity, status, method, evidence, gitStatus}`: `status` is `verified` | `missing` (never `error` — an error anywhere already routed the phase to Verification tooling failed before this point), `method` is `"path"` | `"text"` | `null`, and `evidence` names the tracked path or `file:line` that decided it, or, on a `missing`, what was found and rejected.

**`verify-creates` returns a third verdict, `unconfirmed`, and this section treats it as NOT DELIVERED — the same branch as `missing`, on purpose.** Two searches reach it, and both report the same thing — the name was found, the artifact was not. A documentation identity that resolved only through the text search gets it because some tracked file writes the string `docs/api.md`, which is what a table of contents does and is not the page; only that identity's own tracked path verifies it. ANY identity gets it when every line matching it is a comment, because a note describing an artifact is not the artifact — the defect that closed two verifications in this roadmap's own phase 3, both times on comments an author had written to explain it (`${CLAUDE_PLUGIN_ROOT}/commands/references/scope-contexts.md` § What verification looks for). The union names it beside `missing` in its own `$und` binding rather than leaving it to the `else` that used to catch every non-`verified` status unnamed: a verdict handled only by a catch-all is a verdict nobody can see is handled, and this file's own vocabulary sentence claimed for three releases that `missing` was the only undelivered status there was. Its **evidence is carried through unchanged**, so the report says the artifact was found only by mention rather than not found at all — the whole difference between "nobody wrote this page" and "three files link to a page nobody wrote". The unioned `status` still reads `missing`, which is what keeps `MISSING_COUNT`, `MISSING_CREATES` and the branch decision below identical to what they were: one undelivered branch, not two. `MENTION_ONLY_CREATES`/`MENTION_ONLY_COUNT` are the one place that still tells the two apart, computed from the raw per-repository verdicts and used only by the report.

`VERIFIED_ARTIFACTS` keeps its line shape `"<identity> — <location>"`, identity verbatim and first, one line per verified entry in `creates[]` order, with the winning repository's own `evidence` string as the location — never tagged with that repository's `group_key`, and never a concatenation of every repository that verified it: when more than one repository verifies the same identity, the location is the evidence from the first repository, in sorted `group_key` order, that verified it. Identity-first is load-bearing, not cosmetic: this list becomes handoff.md's `## Artifacts Created`, which `roadmap.py`'s `handoff_lists_artifact` substring-matches to resolve a downstream phase's `needs`.

`MISSING_CREATES` keeps the same `"<identity> — <evidence>"` shape, but with **more than one** participating repository its `evidence` names every repository that was searched: `"<group_key>: <that repository's own evidence>"`, joined with `"; "` in sorted `group_key` order, so a reader can tell "this name appears nowhere in any repository" from "this name appears only in prose in repository X" instead of one arbitrary repository's evidence standing in for all of them. Both the rejected-location detail and the tracked-files-only limitation `verify-creates` already returns per call (scope-contexts.md § What verification looks for) are preserved, once per repository, inside that combined string. With **exactly one** participating repository the tag is omitted — `MISSING_CREATES`, like `CREATES_REPORT`, `VERIFIED_ARTIFACTS`, `ERROR_CREATES` and `MISSING_COUNT`, is then byte-identical to today's single-call output: the union of one set is that set.

#### Which branch to take

Read the `creates-verification:` line the Procedure block printed above.

- `branch=tooling-failed` → **Verification tooling failed** below. No status transition. This fires when `CV_EXIT_FAILURES > 0` (at least one repository's own `verify-creates` call never ran) or `ERROR_COUNT > 0` (git broke while checking at least one identity in at least one repository) — decided before `MISSING_COUNT` is ever computed, so a single repository's tooling failure can never be silently read as that repository contributing zero verified identities to the union.
- `branch=missing` → **On any missing entry** below. `verification_failed`. An `unconfirmed` verdict routes here too, and is counted in `MISSING_COUNT` like any other undelivered entry — see the paragraph above for why the union collapses the two into one branch and where the distinction survives (`mention_only_count` on the same printed line, and the `--- mention only ---` block beneath it).
- `branch=ok` → **Write Handoff**.

Error entries are never part of `CREATES_REPORT`: `ERROR_COUNT`/`ERROR_CREATES` are computed from every repository's own raw verdicts, before the union step runs, and the union itself is reached only once `CV_EXIT_FAILURES` and `ERROR_COUNT` are both confirmed zero across every participating repository — so a tool failure in one repository can never be counted or reported as an undelivered artifact, and no repository's data is ever silently dropped from the union because a sibling repository's call failed.

#### Verification tooling failed

The phase's status is left exactly where it already was (`in_progress`) — do **not** call `roadmap-set-status`. Release the claim only (see Release the Claim on Abort), the same shape the handoff-write-failure path below uses, because `in_progress` is re-claimable once unclaimed:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
```

Transitioning to `verification_failed` here would tell the user their phase failed to deliver when the tool is what failed — and would block next-phase planning on evidence that was never gathered for every repository, including the ones whose own call succeeded.

Report:
```
## Phase [PHASE_ID] Creates Verification Could Not Run

Verification tooling failed in at least one participating repository. This is
NOT a finding that the phase failed to deliver — nothing was proven either
way, for any repository, including ones whose own call succeeded cleanly.

[if CV_EXIT_FAILURES > 0, for each line of CV_EXIT_LINES:]
  - [line]

[if ERROR_COUNT > 0:]
[ERROR_COUNT] creates entr(y|ies) could not be checked because git exited above 1:

[for each line of ERROR_CREATES:]
  - [line]

Phase status is unchanged (in_progress) and the claim is released. Nothing was
marked verification_failed, because a broken tool is not a missing artifact.
Fix git in the repositor(y|ies) named above, then re-run /aimi:execute --
creates verification re-runs from scratch, against every participating
repository, on the next pass.

[if CV_RAW_MISSING_COUNT > 0:]
[CV_RAW_MISSING_COUNT] further entr(y|ies) came back missing, counted across
every repository's own raw verdicts rather than deduplicated per identity.
They are reported as unconfirmed rather than failed, because a run in which
git broke in even one repository is not a run whose other verdicts can be
trusted — no cross-repository union was computed — and they are re-checked
next pass.
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

Report — print each missing line **with the evidence `verify-creates` returned for it**, verbatim, tagged by every repository that was searched when more than one repository participated in this phase. That evidence is the difference between "this name appears nowhere in any participating repository" and "this name appears only in prose in repository X", and the user cannot tell those apart from a bare "not found":
```
## Phase [PHASE_ID] Verification Failed

[MISSING_COUNT] declared creates entr(y|ies) could not be confirmed in any
participating repository's phase branch:

[for each line of MISSING_CREATES:]
  - [line]

[if more than one participating repository:]
Each line names every repository searched for that identity and what was
found and rejected there, tagged by that repository's own group_key. An
identity reads missing here only when every participating repository
reported it missing — an identity delivered in even one repository verifies
for the whole phase, so this list is genuinely undelivered everywhere it was
looked for.
[otherwise:]
Each line carries what was searched and, when something was found, the file and
line that was found and rejected. "Found and rejected ... documentation or test
path" means the name exists only in prose or in a test — a mention of the work,
not the work. "Found and rejected ... TODO/FIXME marker comment" means the code
says the work is still owed.

[if MENTION_ONLY_COUNT > 0:]
[MENTION_ONLY_COUNT] of those entr(y|ies) came back as a MENTION, not as an
absence — the name is written somewhere in tracked source, but the artifact
it names was never found:

[for each line of MENTION_ONLY_CREATES:]
  - [line]

For a documentation identity, a text hit is a link to the page, not the page.
Confirm one of these by committing the file its identity names — the tracked
path is the only thing that verifies it. If the identity is not documentation,
it is named wrongly in `creates[]`: fix the entry with
`$AIMI_CLI roadmap-amend-phase --feature [FEATURE] --phase [PHASE_ID]` rather
than writing a file to satisfy the check.

git ls-files and git grep see tracked (committed) files only, in every
participating repository, so work that is written but committed nowhere in
any of them reads as missing here. If that is what happened, commit it on
the relevant repository's own [PHASE_BRANCH] and re-run to re-verify —
nothing else is needed.

Phase status set to verification_failed. Fix the missing artifact(s) on
branch [PHASE_BRANCH] in whichever repositor(y|ies) should have delivered
them, then re-run /aimi:execute to re-verify — creates verification re-runs
from scratch, against every participating repository, on the next pass.
Next-phase planning stays blocked until this phase re-verifies successfully
(verification_failed is excluded from next-eligible-phase selection, the same
way pending/in_progress are).
```

Do **not** write `handoff.md`, do **not** offer a PR, do **not** run the Next Phase step below. Skip directly to Step 5 (which still reports this phase's own story-level completion, unaffected by the roadmap-level failure).

### Phase Visual Gate

Reached only when Creates Verification's `branch=ok`. It runs here, before Write Handoff and before Mark Phase Completed's dev-server stop, because the comparison needs the phase's own dev server still up. A phase that shipped UI must never reach `completed` with an unjudged visual comparison; the completed-phase gate refuses one whose `visualGate` is absent or unjudged, and this section is what records it. It never writes `handoff.md` itself and never sets the phase to `completed`.

#### Is a comparison owed

One `roadmap-visual-gate-required` call, read-only. `.required` is true only when the phase's tasks file(s) carry a prototype **and** at least one completed visual story. `.groups` counts resolved tasks-file members (1 for any non-split phase) — it is **not** the participating-project-group count the checks below derive.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
VG_JSON=$($AIMI_CLI roadmap-visual-gate-required --feature "$FEATURE" --phase "$PHASE_ID") || {
  echo "visual-gate: tooling-failed — roadmap-visual-gate-required exited non-zero" >&2
  $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
  exit 1
}
VG_REQUIRED=$(printf '%s' "$VG_JSON" | jq -r '.required')
VG_REASON=$(printf '%s' "$VG_JSON" | jq -r '.reason')
if [ "$VG_REQUIRED" = "true" ]; then
  printf 'visual-gate-required: required=true groups=%s\n' "$(printf '%s' "$VG_JSON" | jq -r '.groups')"
else
  printf 'visual-gate: not-required — %s\n' "$VG_REASON"
fi
```

**`.required` false:** record nothing — no `roadmap-record-visual-gate` call — and keep the printed `visual-gate: not-required — <reason>` line verbatim for Write Handoff's deviations. Fall through to Write Handoff. If the call itself failed, the claim is released and the phase's status stays `in_progress`; report the tooling failure the way Verification tooling failed above does and skip directly to Step 5 — `handoff.md` is not written.

#### Environment checks and the live URLs

When `.required` is true, three deterministic checks run in this fixed order. Each one that fails records its own `skipped` verdict and the phase still reaches `completed`; none of them spawns the reviewer or calls `write-review`:

1. **More than one participating project group, or a split phase** — reason names "per-repository servers": each repository serves its own phase branch, so one comparison cannot cover them. A split phase is `PHASE_SPLIT_MODE=true`; the group count is `project-groups` over `$PHASE_TASKS_PATH`, the same derivation Mark Phase Completed uses, not `.groups`.
2. **`agent-browser` not installed.**
3. **No dev server resolved for that group's own `$PHASE_BRANCH`** — any visual story URL whose `serve url` comes back `rewritten:false`.

When all three pass, every completed visual story's URL is rewritten through `$WORKTREE_MGR serve url`, following `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Rewrite a Verification URL Origin: `EXEC_ROOT` is the one group's own resolved toplevel — the same `EXEC_ROOT` Phase Container Dev Server Bootstrap `cd`s to before its `serve start` — and `EXEC_BRANCH="$PHASE_BRANCH"`, re-queried here and never a value cached from the bootstrap.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
VG_JSON=$($AIMI_CLI roadmap-visual-gate-required --feature "$FEATURE" --phase "$PHASE_ID") || exit 1
VG_STORY_LINES=""
VG_CONTAINER=""
VG_MULTI=false
VG_GROUP_PROJECTS=""
if [ "$PHASE_SPLIT_MODE" = true ]; then
  VG_MULTI=true
else
  VG_GROUPS_JSON=$($AIMI_CLI project-groups --tasks-file "$PHASE_TASKS_PATH") || exit 1
  VG_GROUP_PROJECTS=$(printf '%s' "$VG_GROUPS_JSON" | jq -r '.groups[]')
  [ "$(printf '%s\n' "$VG_GROUP_PROJECTS" | grep -c .)" -gt 1 ] && VG_MULTI=true
fi
VG_STATE=compare
if [ "$VG_MULTI" = true ]; then
  VG_STATE=skipped
  VG_SKIP_REASON="split phase or more than one participating project group: each repository serves its own phase branch (per-repository servers), so one comparison cannot cover them"
  $AIMI_CLI roadmap-record-visual-gate --feature "$FEATURE" --phase "$PHASE_ID" --status skipped --reason "$VG_SKIP_REASON"
elif ! command -v agent-browser >/dev/null 2>&1; then
  VG_STATE=skipped
  VG_SKIP_REASON="agent-browser is not installed"
  $AIMI_CLI roadmap-record-visual-gate --feature "$FEATURE" --phase "$PHASE_ID" --status skipped --reason "$VG_SKIP_REASON"
else
  WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
  : "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"; [ -x "$WORKTREE_MGR" ] || { echo "WORKTREE_MGR is stale: $WORKTREE_MGR does not exist — re-run check-version --quiet --fix" >&2; exit 1; }
  VG_PROJECT=$(printf '%s\n' "$VG_GROUP_PROJECTS" | grep -v '^$' | head -1)
  if [ -z "$VG_PROJECT" ] || [ "$VG_PROJECT" = "." ]; then
    VG_ROOT="$AIMI_ROOT"
  else
    VG_ROOT="$AIMI_ROOT/$VG_PROJECT"
  fi
  EXEC_ROOT=$(git -C "$VG_ROOT" rev-parse --show-toplevel 2>/dev/null) || EXEC_ROOT="$VG_ROOT"
  EXEC_BRANCH="$PHASE_BRANCH"
  VG_CONTAINER="$EXEC_ROOT/.worktrees/$EXEC_BRANCH"
  cd "$EXEC_ROOT"
  VG_UNREWRITTEN=0
  while IFS= read -r VG_STORY; do
    [ -n "$VG_STORY" ] || continue
    VG_STORY_ID=$(printf '%s' "$VG_STORY" | jq -r '.id')
    VG_RAW_URL=$(printf '%s' "$VG_STORY" | jq -r '.url // ""')
    SERVE_URL_JSON=$($WORKTREE_MGR serve url "$EXEC_BRANCH" "$VG_RAW_URL")
    VG_REWRITTEN=$(printf '%s' "$SERVE_URL_JSON" | jq -r '.rewritten')
    [ "$VG_REWRITTEN" = "true" ] || VG_UNREWRITTEN=$((VG_UNREWRITTEN + 1))
    # roadmap-visual-gate-required emits {id, url}; the reviewer takes {storyId, url}.
    VG_STORY_ENTRY=$(printf '%s' "$SERVE_URL_JSON" | jq -c --arg id "$VG_STORY_ID" '{storyId: $id, url: .url}')
    VG_STORY_LINES="${VG_STORY_LINES}${VG_STORY_ENTRY}"$'\n'
  done <<< "$(printf '%s' "$VG_JSON" | jq -c '.visualStories[]')"
  cd "$AIMI_ROOT"
  if [ "$VG_UNREWRITTEN" -gt 0 ]; then
    VG_STATE=skipped
    VG_SKIP_REASON="no dev server resolved for $PHASE_BRANCH"
    $AIMI_CLI roadmap-record-visual-gate --feature "$FEATURE" --phase "$PHASE_ID" --status skipped --reason "$VG_SKIP_REASON"
  fi
fi
if [ "$VG_STATE" = skipped ]; then
  printf 'visual-gate: skipped — %s\n' "$VG_SKIP_REASON"
else
  VG_STORIES_JSON=$(printf '%s' "$VG_STORY_LINES" | jq -s -c '.')
  VG_INPUT=$(printf '%s' "$VG_JSON" | jq -c --arg root "$AIMI_ROOT" --arg container "$VG_CONTAINER" --argjson stories "$VG_STORIES_JSON" '{prototypePaths: [.prototypePaths[] | "\($root)/\(.)"], designSpecPath: (if .designSpec then "\($root)/\(.designSpec)" else null end), stories: $stories, containerPath: $container}')
  printf 'visual-gate-input: %s\n' "$VG_INPUT"
fi
```

A `visual-gate: skipped — <reason>` line means the gate recorded its `skipped` verdict and the phase continues to Write Handoff unchanged; keep that line verbatim for its deviations. A `visual-gate-input:` line means the environment can compare: continue below.

#### Run the comparison

Spawn `aimi-engineering:design:aimi-design-implementation-reviewer` via the Task tool **exactly once for the whole phase** — never once per story, unlike Step 4's per-story design review. The prompt's **first line is the literal `MODE: phase-close-visual-gate`**; without it the agent falls back to per-story mode and never emits a `visual_gate_verdict` block. After it, give the agent the parsed `visual-gate-input:` object's fields: `prototypePaths` (every prototype path), `designSpecPath` (only when non-null), `stories` (the full `{storyId, url}` list) and `containerPath`.

Persist the reviewer's raw final response with `write-review --kind visual-gate` **before** the verdict is parsed — the suffix gives this review its own file, `.aimi/reviews/<feature>-phase-<N>-visual-gate.md`, so Step 5's design review, which names the same feature and phase, cannot overwrite the file `--review` points at — so a malformed verdict still leaves the transcript on disk, then parse **only the LAST** fenced `visual_gate_verdict` block, strictly. The fence is built with `printf` rather than typed, so this block carries no literal fence line of its own:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
VG_REVIEW_BODY=$(cat <<'VG_REVIEW_EOF'
[paste the reviewer's raw final response here, verbatim]
VG_REVIEW_EOF
)
VG_REVIEW_JSON=$(printf '%s\n' "$VG_REVIEW_BODY" | $AIMI_CLI write-review --feature "$FEATURE" --phase "$PHASE_ID" --kind visual-gate) || VG_REVIEW_JSON=""
REVIEW_PATH=$(printf '%s' "$VG_REVIEW_JSON" | jq -r '.review // empty' 2>/dev/null)
VG_FENCE=$(printf '\140\140\140')
VG_VERDICT_JSON=$(printf '%s\n' "$VG_REVIEW_BODY" | awk -v fence="$VG_FENCE" 'BEGIN { open = fence "visual_gate_verdict" } $0 == open { inb = 1; buf = ""; next } inb && $0 == fence { inb = 0; last = buf; have = 1; next } inb { buf = buf $0 "\n" } END { if (have) printf "%s", last }')
VG_VERDICT=$(printf '%s' "$VG_VERDICT_JSON" | jq -r '.verdict' 2>/dev/null) || VG_VERDICT=""
VG_SUMMARY=$(printf '%s' "$VG_VERDICT_JSON" | jq -r '.summary // ""' 2>/dev/null)
case "$VG_VERDICT" in
  pass)
    $AIMI_CLI roadmap-record-visual-gate --feature "$FEATURE" --phase "$PHASE_ID" --status passed --review "$REVIEW_PATH"
    printf 'visual-gate: passed — %s\n' "$VG_SUMMARY"
    ;;
  diverges)
    printf 'visual-gate-verdict: diverges review=%s\n' "${REVIEW_PATH:-<not written>}"
    printf '%s' "$VG_VERDICT_JSON" | jq -r '.divergences[]? | "  - \(.storyId): \(.element) — expected \(.expected), observed \(.observed) [\(.source)]"'
    ;;
  *)
    $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
    printf 'visual-gate: tooling-failed — no parseable visual_gate_verdict block with a pass or diverges verdict (review=%s)\n' "${REVIEW_PATH:-<not written>}"
    ;;
esac
```

- **`visual-gate: passed — <summary>`** — recorded; the phase falls through to Write Handoff.
- **`visual-gate-verdict: diverges`** — see below.
- **`visual-gate: tooling-failed`** — a missing block, a JSON parse failure, or a `.verdict` outside `pass`/`diverges`. Nothing was recorded via `roadmap-record-visual-gate` and the claim is released (the call above did it); the phase's status is left exactly where it was (`in_progress`), the same shape as Verification tooling failed above. Report:

  ```
  ## Phase [PHASE_ID] Visual Gate Could Not Run

  The design reviewer did not return a usable visual_gate_verdict block. This is
  NOT a finding that the UI diverges — nothing was proven either way.

  Raw review: [REVIEW_PATH, or "not written"]

  Phase status is unchanged (in_progress) and the claim is released. Re-run
  /aimi:execute -- the visual gate re-runs on the next pass.
  ```

  Do **not** write `handoff.md`, do **not** offer a PR, do **not** run the Next Phase step below. Skip directly to Step 5.

#### On a diverges verdict

Resolve interactivity fresh — each Bash call is an isolated shell (Step 0):

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
INTERACTIVE_MODE=$($AIMI_CLI detect-interactivity)
echo "visual-gate: interactivity=$INTERACTIVE_MODE"
```

- **`INTERACTIVE_MODE=picker`:** ask exactly one `AskUserQuestion`, showing the reviewer's `divergences[]`. Option A, the default and least disruptive, is **Leave the phase failing**; the trailing "Other" option is **Accept the divergences**, answered with a typed reason. Anything that is not an explicit Other answer carrying a reason — a decline, silence, any other option — leaves the phase failing. A typed reason is sanitized per `${CLAUDE_PLUGIN_ROOT}/commands/references/sanitization.md`'s Base Rules before it reaches `--reason`.
- **`INTERACTIVE_MODE=agent`:** never ask this question and never record `accepted` — an unattended run cannot own an acceptance. The phase is left failing unconditionally.

**Accepting** records the verdict, satisfies the gate and falls through to Write Handoff. Compose the sanitized reason in the quoted heredoc so its bytes reach the verb unexpanded:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
VG_ACCEPT_REASON=$(cat <<'VG_ACCEPT_EOF'
[the typed reason, sanitized per sanitization.md Base Rules]
VG_ACCEPT_EOF
)
$AIMI_CLI roadmap-record-visual-gate --feature "$FEATURE" --phase "$PHASE_ID" --status accepted --reason "$VG_ACCEPT_REASON" --review "$REVIEW_PATH"
printf 'visual-gate: accepted — %s\n' "$VG_ACCEPT_REASON"
```

**Leaving it failing** (every decline, and unconditionally in agent mode) records `diverges`, transitions the phase to `verification_failed` and releases the claim, so re-running `/aimi:execute` re-enters Phase Completion and re-runs this gate:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
VG_DIVERGE_REASON=$(cat <<'VG_DIVERGE_EOF'
[the reviewer's one-line summary, sanitized per sanitization.md Base Rules]
VG_DIVERGE_EOF
)
$AIMI_CLI roadmap-record-visual-gate --feature "$FEATURE" --phase "$PHASE_ID" --status diverges --reason "$VG_DIVERGE_REASON" --review "$REVIEW_PATH"
$AIMI_CLI roadmap-set-status --feature "$FEATURE" --phase "$PHASE_ID" --status verification_failed
$AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
```

Report the reviewer's `divergences[]` (the lines the verdict block printed) and the raw review path, and say the phase is `verification_failed` and that re-running `/aimi:execute` re-runs the gate. Do **not** write `handoff.md`, do **not** run Mark Phase Completed, do **not** offer a PR, do **not** run the Next Phase step below. Skip directly to Step 5.

### Write Handoff

Only reached when `verify-creates` exited 0 and returned neither a `missing` nor an `error` entry — i.e. every `creates` entry verified. This payload is written to `handoff.md`, a plugin-owned artifact — per the artifact-language rule (`commands/references/user-communication.md`), author all five sections below in English. Build the five-section payload:

- **Decisions Made** — one bullet per notable implementation decision surfaced by this phase's stories (their `implementation.approach` text, gate resolutions, or explicit deviations the story-executor agents reported). Empty array if nothing stood out.
- **Artifacts Created** — exactly `VERIFIED_ARTIFACTS` from Creates Verification above, unmodified. This is the section `validate-contracts`'s `handoff_lists_artifact` (in `roadmap.py`) searches when a downstream phase's `needs` references this phase — every identity must appear verbatim.
- **Deviations** — one bullet per `.aimi/known-gaps/*.md` file belonging to this phase's stories (same source Step 5's "Known Gaps" aggregation reads), summarizing the story id and gap, **plus exactly one line carrying this phase's verification-evidence fraction**, spelled the way Step 5 prints it: `verification-evidence: discriminating=<n> completed=<m>`. That line is present on **every** run — full, partial or zero — for the same reason Step 5's own `## Verification Evidence` section is unconditional, and `handoff.md` is where it matters most: the handoff is the durable per-phase record a later phase reads, and a record that only mentions evidence when there was some cannot tell a checked phase from an unchecked one. One line, never a table, and never omitted at zero. So this array is no longer empty when no gap file exists — it holds that one line alone. When the tasks file carries `metadata.evidenceAcknowledged` (any split member's), add one more free-prose bullet, `evidence-acknowledged: <reason> (<acknowledgedAt>)` — not a locked token.
  - **It rides in `deviations` rather than in a key of its own because a sixth key would be silently dropped.** `roadmap.py`'s `HANDOFF_FIELDS` is a fixed five — `decisions`, `artifacts`, `deviations`, `deferred`, `contracts` — and a payload carrying a sixth writes successfully while the number simply never reaches `handoff.md`. Widening that tuple is `roadmap.py`'s change to make, not this command's.
  - **The two counts come from the payloads this run already has, not from a second CLI call.** Sum the per-story `VERIFY_EVIDENCE_JSON` values Step 4 read off each worker's `result_json`: `m` is the number of this phase's stories marked complete this run, and `n` is how many of them carried a `verify` object whose `discriminating` is 1 or more (an empty `VERIFY_EVIDENCE_JSON` counts toward `m` only — it is unrecorded evidence, not a recorded zero). This step runs **before** Step 5 captures `COMPLETION_VERIF_REPORT`, and it deliberately does not open a `verification-report` call of its own to fetch a number already in hand. The consequence is worth knowing when the two lines differ: the handoff counts what THIS run completed, Step 5's section counts every completed story in the file, so a resumed phase legitimately reports a smaller `m` here than the report prints below.
  - **One `verification-skipped: <id> — <reason or "no reason recorded">` line per this phase's own skipped verification** — every entry of `verification-report --tasks-file "$PHASE_TASKS_PATH"`'s `.skipped` array, read via a **dedicated call made at this point in the flow**, scoped to every COMPLETED story in this phase's own tasks file whose `verification.status` is literally `skipped` (`verification_report`'s own `skipped` key already carries exactly that scope). This is the one divergence from the `verification-evidence:` line immediately above, and it runs the opposite way on purpose: Step 4 accumulated `VERIFY_EVIDENCE_JSON`'s `{exit, preExit, segments, discriminating}` per completed story and nothing about skip status or reason, so there is no run-scoped accumulator here for this call to be a redundant second read of — it is the FIRST read of this data, not a second one, and the reason a fresh `verification-report` call is warranted here where the evidence line's own comment warns against exactly that. Its scope is `verification_report`'s own completed-story definition (every completed story in this phase's tasks file), not Step 4's THIS-RUN accumulation, since no incremental per-run tracking of skip status exists to restrict it to — a resumed phase's handoff can legitimately report a skip an EARLIER run of this same phase recorded, which the `m`/`n` evidence counts above never can. Present only when at least one such story exists: zero skipped means zero lines, never an empty placeholder — unlike the evidence fraction, which always prints its one line whatever the numbers are.
  - **Exactly one `visual-gate: <status> — <reason>` line, present on every run that reaches Write Handoff** — the Phase Visual Gate section above always leaves one printed line: `visual-gate: not-required — <reason>` when no comparison was owed, or the required branch's own line (`visual-gate: skipped — <reason>`, `visual-gate: passed — <summary>`, `visual-gate: accepted — <sanitized reason>`). Copy that line verbatim. A phase left failing never reaches Write Handoff, so `diverges` never appears here.
- **Deferred Items** — one bullet per this phase's own story left in `skipped` status, if any. Empty array if none.
- **Contracts Delivered** — one bullet per `creates` entry restating the identity now available to dependent phases (`"<identity> — contract fulfilled, available to phases depending on [PHASE_ID]"`), mirroring Artifacts Created's identities but phrased for downstream `needs` resolution.

**Nine tokens in this payload are locked tokens, never translated, regardless of the English mandate above — because something downstream greps for the literal string.** The five heading labels above (`Decisions Made`, `Artifacts Created`, `Deviations`, `Deferred Items`, `Contracts Delivered`) are hard-locked in `scripts/roadmap.py`'s `HANDOFF_FIELDS`/`HANDOFF_SECTIONS` tuples (`scripts/roadmap.py:2055-2064`), and `roadmap-write-handoff` refuses the entire write when one breaks (`scripts/roadmap.py:3589-3597`). The artifact identity copied verbatim into `## Artifacts Created` is the sixth: `handoff_lists_artifact`'s fixed-substring lookup (`scripts/roadmap.py:3048`) is what `validate-contracts` uses to resolve a downstream phase's `needs`, so translating that identity makes the contract report not-delivered and blocks the dependent phase. A seventh, the `verification-evidence: discriminating=<n> completed=<m>` line two bullets above, is a locked LINE sitting inside this otherwise-prose `deviations` array — the surrounding bullets are free prose, only that one line is not. An eighth, the `verification-skipped: <id> — <reason or "no reason recorded">` line the bullet immediately above describes, is a second locked line inside that same array, for the identical reason: a skip an operator or a later phase greps for by this exact prefix must find it spelled the same way every time. A ninth, the `visual-gate: <status> — <reason>` line the bullet below describes, is a third locked line inside that same array, for the same reason: the visual-gate verdict an operator or a later phase greps for by this prefix must read the same way every time.

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

`roadmap-set-status` and `roadmap-write-handoff` (Write Handoff above) are otherwise unchanged by this story: each is exactly one call, each makes zero git calls, and each operates on `$AIMI_ROOT/.aimi/` regardless of single-repo or multi-repo layout. The claim, this phase's `status`, and `handoff.md` all stay singular for the phase — one status, one handoff file — no matter how many repositories participated. What multiplies per repository below is only the dev-server stop and the completion report's branch listing, never roadmap state.

Stop every participating repository's own phase dev server before the report below is composed — never just `$AIMI_ROOT`'s — so no server is left orphaned, still holding its port: phase mode's own container is never removed anywhere in this document (see Step 5's Container removal is completion-path-only note), so an un-stopped server here would stay alive indefinitely, not just until some later cleanup step. Derive this phase's participating project groups the same way **Create Phase Containers Per Project Group**'s Derive Participating Project Groups above already did when this phase's containers were created — `$PHASE_TASKS_PATH`'s own `userStories[].project` in single-file mode, or every member of `$PHASE_SPLIT_FILES`'s own `metadata.splitGroup.project` in split mode. Reading the **full** `$PHASE_SPLIT_FILES` member list, not just this run's active subset, mirrors Multi-File Pending Count's own reasoning above: a repository whose split member completed in an earlier session still had its own phase container and must still be named and stopped here, even though this run never touched it:

```bash
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
  done <<< "$PHASE_SPLIT_FILES"
  PHASE_GROUP_PROJECTS=$(printf '%s\n' "$PHASE_GROUP_RAW" | grep -v '^$' | sort -u)
  [ -n "$PHASE_GROUP_PROJECTS" ] || PHASE_GROUP_PROJECTS="."
else
  # project-groups now owns the jq, the sort-unique pipeline and the
  # empty-fallback this branch used to run inline. Status is already
  # `completed` and the claim already released by this point (roadmap-set-
  # status above), so a refusal here is a plain stop rather than a release --
  # there is nothing left to release.
  PHASE_GROUPS_JSON=$($AIMI_CLI project-groups --tasks-file "$PHASE_TASKS_PATH") || exit 1
  PHASE_GROUP_PROJECTS=$(printf '%s' "$PHASE_GROUPS_JSON" | jq -r '.groups[]')
fi
PHASE_GROUP_COUNT=$(printf '%s\n' "$PHASE_GROUP_PROJECTS" | grep -c .)
```

**The pairing rule:** for each participating group, `serve stop` must run with the exact same CWD that same group's own `serve start "$PHASE_BRANCH"` used in **Phase Container Dev Server Bootstrap** (Step 1.7) — bootstrap CWD and stop CWD must match, per repository. The `DEFAULT` group (project `.`) uses `$AIMI_ROOT`; a named group uses `$AIMI_ROOT/[group]` — because `serve stop` resolves its `dev-server.json` key from CWD (see `_dev_server_key` in `worktree-manager.sh`), the identical "CWD must exactly match the CWD used for that branch's own `serve start` call" reasoning `container-execution.md`'s Bootstrap a Container Dev Server and Container Mode: Stop the Dev Server sections both state; a mismatched CWD here would silently miss the registered entry instead of stopping it. The call is issued unconditionally for every group, with no per-repo existence gate: `serve stop`'s documented contract (below) already exits 0 and reports "No dev server registered" when no server was ever started for that repository, so the loop needs no branching beyond iterating the group set:

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"; [ -x "$WORKTREE_MGR" ] || { echo "WORKTREE_MGR is stale: $WORKTREE_MGR does not exist — re-run check-version --quiet --fix" >&2; exit 1; }
PHASE_REPORT_LINES=""
while IFS= read -r GROUP_PROJECT; do
  [ -n "$GROUP_PROJECT" ] || continue
  if [ "$GROUP_PROJECT" = "." ]; then
    GROUP_KEY="DEFAULT"
    GROUP_ROOT="$AIMI_ROOT"
    GROUP_LABEL="$AIMI_ROOT"
  else
    GROUP_KEY="$GROUP_PROJECT"
    GROUP_ROOT="$AIMI_ROOT/$GROUP_PROJECT"
    GROUP_LABEL="$GROUP_PROJECT"
  fi
  cd "$GROUP_ROOT"
  $WORKTREE_MGR serve stop "$PHASE_BRANCH"
  PHASE_REPORT_LINES="${PHASE_REPORT_LINES}${GROUP_LABEL}: ${PHASE_BRANCH}"$'\n'
done <<< "$PHASE_GROUP_PROJECTS"
cd "$AIMI_ROOT"
```

`serve stop` kills the dev server's full process group and clears its state entry — identical to container-execution.md's Container Mode: Stop the Dev Server contract (invoked from Step 5). For a phase that ran **Phase-Mode Paired Split**, each participating repository's own split servers were already stopped by that repository's own **Clean Up Split Worktrees** step, immediately before its split worktree was removed — and that repository's own `$PHASE_BRANCH` ref never had a server started directly against it in split mode, since Phase Container Dev Server Bootstrap skips entirely when `PHASE_SPLIT_MODE=true` — so this loop's call is a harmless, correctly-idempotent no-op for every participating repository in split mode, the same reasoning that already held once, globally, for today's single-repo split case, now verified to hold independently per repository rather than just once. This only runs on the `completed` path reached here: every non-completion exit above it in Phase Completion (the pending-count guard, Creates Verification's `verification_failed` branch, and Write Handoff's failure branch) returns before this subsection, so a phase that ends on deadlock, a gate-blocked wave, or `verification_failed` never calls `serve stop` — its dev server(s) stay alive between waves and across a paused session, resumable via `serve status` on the next `/aimi:execute` run against the same phase, exactly like the flat container's own resumable contract.

This stop loop runs — and completes — before the completion report below is composed, and before **Offer a Pull Request** further down: a server must never outlive its container, and neither of those next two steps removes or touches `PHASE_CONTAINER_PATH` (phase mode's own container is never removed anywhere in this document — see Step 5's Container removal is completion-path-only note), so stopping first here keeps that invariant reading consistently top-to-bottom.

Report:
```
Phase [PHASE_ID] ([PHASE_SLUG]) completed. Claim released.

[if PHASE_GROUP_COUNT > 1:]
[PHASE_GROUP_COUNT] repositories participated in this phase — open one pull request per repository, each from its own [PHASE_BRANCH]:

[for each line of PHASE_REPORT_LINES:]
  - [line]
```

With exactly one participating group — today's only supported case — `PHASE_GROUP_PROJECTS` resolves to exactly `.`, `PHASE_GROUP_COUNT` is `1`, the conditional block above never fires, and the report is exactly `Phase [PHASE_ID] ([PHASE_SLUG]) completed. Claim released.` — byte-for-byte identical to today's text — with the single `serve stop` call above run with CWD `$AIMI_ROOT`, identical to today's unconditional `cd "$AIMI_ROOT"`. When more than one group participates, each additional line names that repository (its project root for the `DEFAULT` group, its `project` value for a named group) and the one `$PHASE_BRANCH` name every group shares (see container-execution.md's Phase Container Paths Per Project Group: `EXEC_BRANCH[group_key]` is not a per-group map — it is the same `PHASE_BRANCH` scalar, reused by every group), so a human reading the report knows to open one pull request per repository.

### Offer a Pull Request

Best-effort only — never reverts or changes the already-`completed` status on failure or refusal. Runs once per participating repository — the same project groups **Mark Phase Completed**'s report above already derived. Re-derived fresh in this block, since each Bash call is an isolated shell and nothing from that earlier block persists here:

```bash
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
  done <<< "$PHASE_SPLIT_FILES"
  PHASE_GROUP_PROJECTS=$(printf '%s\n' "$PHASE_GROUP_RAW" | grep -v '^$' | sort -u)
  [ -n "$PHASE_GROUP_PROJECTS" ] || PHASE_GROUP_PROJECTS="."
else
  # project-groups now owns the jq, the sort-unique pipeline and the
  # empty-fallback this branch used to run inline. A refusal here just skips
  # this best-effort step -- the already-`completed` status above is never
  # reverted.
  PHASE_GROUPS_JSON=$($AIMI_CLI project-groups --tasks-file "$PHASE_TASKS_PATH") || exit 1
  PHASE_GROUP_PROJECTS=$(printf '%s' "$PHASE_GROUPS_JSON" | jq -r '.groups[]')
fi
```

#### Select the acting forge account per repository

Before any of those repositories is pushed or gets a pull request, settle which account will author those writes — once per repository ever, and **separately per repository**, since a multi-repo phase can legitimately span two repositories that want two different accounts. Resolve interactivity once (re-resolved here when still unset, the same cheap idempotent safety net the per-repo base-branch picker above uses, since each Bash call is an isolated shell) and ask the CLI, per group, whether the question is warranted:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
if [ -z "$INTERACTIVE_MODE" ]; then
  INTERACTIVE_MODE=$($AIMI_CLI detect-interactivity)
fi
echo "$INTERACTIVE_MODE"
while IFS= read -r ACCOUNT_GROUP_PROJECT; do
  [ -n "$ACCOUNT_GROUP_PROJECT" ] || continue
  if [ "$ACCOUNT_GROUP_PROJECT" = "." ]; then
    ACCOUNT_GROUP_ROOT="$AIMI_ROOT"
  else
    ACCOUNT_GROUP_ROOT="$AIMI_ROOT/$ACCOUNT_GROUP_PROJECT"
  fi
  ACCOUNT_GROUP_TOPLEVEL=$(git -C "$ACCOUNT_GROUP_ROOT" rev-parse --show-toplevel 2>/dev/null) || ACCOUNT_GROUP_TOPLEVEL=""
  [ -n "$ACCOUNT_GROUP_TOPLEVEL" ] || continue
  ACCOUNT_CHECK_JSON=$($AIMI_CLI forge-account-select --check --project "$ACCOUNT_GROUP_TOPLEVEL") || ACCOUNT_CHECK_JSON=""
  [ -n "$ACCOUNT_CHECK_JSON" ] || continue
  printf '%s\t%s\t%s\n' "$ACCOUNT_GROUP_PROJECT" "$ACCOUNT_GROUP_TOPLEVEL" "$ACCOUNT_CHECK_JSON"
done <<< "$PHASE_GROUP_PROJECTS"
```

Each printed line is one repository: its group key, its repository root, and its `forge-account-select --check` verdict. `detect-interactivity` prints exactly `picker` or `agent`, and `picker` is the default — `agent` comes only from an explicit opt-out (`--non-interactive`, `AIMI_AGENT_MODE=true`, `CI=true`); a non-TTY shell is **not** a signal for agent mode. `commands/references/interactivity.md` is the arbiter for mode resolution, option format and the agent-mode rule at this site.

Ask for a given repository **only** when `INTERACTIVE_MODE` is `picker` AND that line's `.decision` is `"ask"` — the same two-condition AND the first-run model prompt uses (`commands/references/cli-path-resolution.md`). `forge-account-select --check` owns the second condition entirely: it reports `"ask"` only when that repository has no recorded answer *for its own host* and that project's git identity and the active forge account actually diverge. It decides on that repository's own entry, never on the store file's existence, so a store already holding other repositories' answers still asks here. Every other `.basis` — `answer_recorded`, `identity_override`, `no_repository`, `no_host`, `single_account`, `identity_matches_active`, `not_authenticated`, `cli_missing`, `no_adapter` — reports `"skip"`: that repository gets no picker and no output. `--check` writes nothing, so evaluating it never changes what a later run asks.

**When `INTERACTIVE_MODE=picker` and a line's `.decision == "ask"`:** Use **AskUserQuestion** once for that repository, naming it so a multi-repo run's separate prompts stay distinguishable — the same discipline the per-repo `resolve-base-branch` picker above follows:

```
Which account should author the pull request for [project_path] on [host]?

A — Always use the active account ([activeAccount])
B — [the divergence candidate]
C/D/E — [further logged-in accounts, in the order .accounts lists them]
Other — Enter a different account login
```

- **Option A** is deliberately the least disruptive answer, and it is the one agent mode auto-picks below: every write for that repository stays on whichever account is active.
- **Option B** is the divergence candidate — the login in that line's `.accounts` that the repository's own git identity points at and that is not `.activeAccount`. Derive it from `.identity.email`: a `…@users.noreply.github.com` address encodes the login exactly (dropping any leading `<digits>+`); otherwise use the address's local-part with the same leading `<digits>+` dropped. When no `.accounts` entry matches, option B is the first `.accounts` entry other than `.activeAccount`.
- **C/D/E** are the remaining `.accounts` entries in gh's own order, and **Other** is the free-form escape hatch, always last. Never fewer than 2 options and never more than 6 in total, so at most five accounts are listed; when gh reports more than fit, keep option A and the divergence candidate and drop the remainder — `Other` already covers them.

Record the answer once per repository that was actually answered — picker mode only. Both the repository and the chosen value cross into this call as literals the orchestrator substitutes, never as shell variables carried over from the enumeration fence above:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
FORGE_ACCOUNT_PROJECT="[the repository root printed for the group just answered]"
FORGE_ACCOUNT_CHOICE="[the account chosen above — the literal word active for option A, otherwise the login]"
if [ "$FORGE_ACCOUNT_CHOICE" = "active" ]; then
  $AIMI_CLI forge-account-select --record-active --project "$FORGE_ACCOUNT_PROJECT"
elif echo "$FORGE_ACCOUNT_CHOICE" | grep -qE '^[A-Za-z0-9][A-Za-z0-9-]*$'; then
  $AIMI_CLI forge-account-select --record "$FORGE_ACCOUNT_CHOICE" --project "$FORGE_ACCOUNT_PROJECT"
else
  echo "Not a forge login: $FORGE_ACCOUNT_CHOICE — nothing recorded for $FORGE_ACCOUNT_PROJECT." >&2
fi
```

Option A records the permanent "always use the active account" opt-out — a real stored answer, not the absence of one, which is why it stops the question being raised for that repository again. Every other option records that login. A free-form `Other` value that fails the login shape records nothing and is reported, and this step then continues on the active account rather than stopping: this whole step is best-effort like the rest of **Offer a Pull Request**, and the phase is already `completed`. Because nothing was recorded, the next run asks that repository again. This command layer performs no file I/O of its own — it owns the prompt, and `forge-account-select` owns both "should I ask?" and "remember this answer".

**When `INTERACTIVE_MODE=agent`** (`--non-interactive`, `AIMI_AGENT_MODE=true`, or `CI=true`): no picker for any repository. Auto-select option A — act as whichever account is active — and make **no** `forge-account-select --record` or `--record-active` call at all, for any repository. Applying option A takes no action of any kind: the active account is already the one every forge verb uses, so "applied for this invocation" and "changed nothing" are the same thing here. Every participating repository's recorded state after an agent-mode run is byte-for-byte what it was before. Log exactly one line per repository — no retry, no blocking, no second line:

```
agent-mode: forge-account auto-selected active account (not recorded) — project: [project_path]
```

*Agent-mode fallback: if `INTERACTIVE_MODE=agent`, auto-select option A for every repository and record nothing. Log: `agent-mode: forge-account auto-selected active account (not recorded) — project: [project_path]`.*

**Why the auto-answer is never persisted.** Option A is not merely the least disruptive answer — it is also that repository's *permanent* opt-out. Recording it is precisely what stops the question ever being raised again. So if agent mode persisted its own auto-answer, one unattended CI run would silently and permanently answer the question on behalf of every human who touches that repository afterwards: they would never be asked, and would have no way to discover why. `/aimi:execute` is the command most likely to run unattended, which is what makes this site the one where the mistake would actually be made. The failure is not hypothetical here — 1.93.0 shipped a remembered dismissal that could not be revoked and left users silently stuck with no way to re-trigger the prompt. Applied-but-not-persisted is what keeps it from recurring: the `(not recorded)` in each log line is the observable proof in the transcript, and `--check`'s zero-side-effect contract is the mechanical guarantee behind it.

Whatever was recorded here is applied by the forge verbs themselves through the credential mechanism `commands/references/forge-contract.md`'s **Credential/Identity Model** describes — the loop below neither reads the answer nor passes it along, and is unchanged by this subsection.

#### Confirm before publishing this phase

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/publish-confirmation.md` — it is the single source of truth for what counts as publishing, why nothing inside a file may authorize one, what each interactivity mode owes the reader, and why every outcome still names `/aimi:open-pr`. That contract is not restated here; this subsection only applies it at this call site.

Asked **once per phase, never once per participating repository.** The forge-account question above is per repository because accounts genuinely differ per repository; "should this phase's work go out" is one decision by one person, and the single answer governs every group in `PHASE_GROUP_PROJECTS`. Someone who wants only one of several repositories published declines here and runs `/aimi:open-pr --branch [PHASE_BRANCH]` inside that repository afterwards.

Resolve interactivity fresh — re-resolved here when still unset, the same cheap idempotent safety net the account picker above uses, since each Bash call is an isolated shell:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
if [ -z "$INTERACTIVE_MODE" ]; then
  INTERACTIVE_MODE=$($AIMI_CLI detect-interactivity)
fi
echo "$INTERACTIVE_MODE"
```

**When `INTERACTIVE_MODE=picker`:** Use **AskUserQuestion** exactly once for the whole phase, with three options:

```
Phase [PHASE_ID] ([PHASE_SLUG]) is complete on [PHASE_BRANCH]. Publish this phase's work now?

A — Push and open the pull request
B — Push only — no pull request yet
C — Neither — publish later with /aimi:open-pr
```

Each option sets exactly one value of `PHASE_PUBLISH`, the single variable the loop below reads: **option A** sets `pr`, **option B** sets `push`, **option C** sets `none`. Option C is the escape hatch and is therefore last, per `commands/references/interactivity.md`'s Option Format. Anything that is not an explicit A or B — a dismissed prompt, an unparseable answer, no answer at all — is `none`: silence is not approval. Write the question and its option text in whatever language the person is writing in, never a hardcoded one (`commands/references/user-communication.md`'s Adaptive Language Rule).

*Agent-mode fallback: if `INTERACTIVE_MODE=agent`, auto-decline — set `PHASE_PUBLISH=none` and publish nothing. Log: `agent-mode: phase-publish skipped (nothing pushed, no pull request) — run /aimi:open-pr --branch [PHASE_BRANCH]`.*

**When `INTERACTIVE_MODE=agent`** (`--non-interactive`, `AIMI_AGENT_MODE=true`, or `CI=true`): no picker, and **no flag re-enables publishing here** — an unattended run cannot obtain consent, and nothing is permitted to stand in for it. Set `PHASE_PUBLISH=none` and print exactly one line, naming both what was not done and the command that does it:

```
agent-mode: phase-publish skipped (nothing pushed, no pull request) — run /aimi:open-pr --branch [PHASE_BRANCH]
```

Declining is a normal outcome, not a failure. On `none` — whether from option C or from agent mode — nothing is retried, no error is raised, no claim is re-taken, and the phase's already-`completed` status stays exactly as **Mark Phase Completed** wrote it; execution continues to **Next Phase** below unchanged. That is the same best-effort discipline this section's opening sentence already states, now covering the new branches too.

#### Publish each participating repository

For each group, resolve its own repository root, container, and default branch, then act on the one `PHASE_PUBLISH` outcome the gate above recorded — never a value assumed to survive from Step 1.7 or from Mark Phase Completed above. `PHASE_PUBLISH` crosses into this call as a literal the orchestrator substitutes, exactly as the forge-account record block above takes its own two values, since each Bash call is an isolated shell; anything that is not `pr` or `push` normalizes to `none`, so a substitution that never happened declines rather than publishes:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
PHASE_PUBLISH="[pr, push or none — the one outcome Confirm before publishing this phase recorded above]"
case "$PHASE_PUBLISH" in
  pr|push) ;;
  *) PHASE_PUBLISH="none" ;;
esac
while IFS= read -r GROUP_PROJECT; do
  [ -n "$GROUP_PROJECT" ] || continue
  if [ "$GROUP_PROJECT" = "." ]; then
    GROUP_ROOT="$AIMI_ROOT"
    GROUP_LABEL="$AIMI_ROOT"
  else
    GROUP_ROOT="$AIMI_ROOT/$GROUP_PROJECT"
    GROUP_LABEL="$GROUP_PROJECT"
  fi
  GROUP_TOPLEVEL=$(git -C "$GROUP_ROOT" rev-parse --show-toplevel 2>/dev/null) || GROUP_TOPLEVEL=""
  if [ -z "$GROUP_TOPLEVEL" ]; then
    echo "Skipping PR for $GROUP_LABEL — not a git repository at $GROUP_ROOT."
    continue
  fi
  GROUP_CONTAINER="$GROUP_TOPLEVEL/.worktrees/$PHASE_BRANCH"
  GROUP_DEFAULT=$($AIMI_CLI detect-default-branch --project "$GROUP_TOPLEVEL") || GROUP_DEFAULT=""

  if [ "$PHASE_PUBLISH" = "none" ]; then
    echo "Nothing published for $GROUP_LABEL — no push, no pull request. Publish it when you are ready:"
    echo "  /aimi:open-pr --branch $PHASE_BRANCH"
    continue
  fi

  GROUP_FORGE_STATUS=$($AIMI_CLI forge-auth-status --project "$GROUP_TOPLEVEL" | jq -r '.status // empty')
  if [ "$GROUP_FORGE_STATUS" != "found" ]; then
    echo "No usable forge for $GROUP_LABEL — skipping the push and the pull request. Do both manually:"
    echo "  git -C \"$GROUP_CONTAINER\" push -u origin $PHASE_BRANCH"
    echo "  Then open a PR: $GROUP_DEFAULT...$PHASE_BRANCH"
    echo "  Once a forge CLI is installed and authenticated for this repository, run this from $GROUP_TOPLEVEL instead: /aimi:open-pr --branch $PHASE_BRANCH"
    continue
  fi

  cd "$GROUP_CONTAINER"
  git push -u origin "$PHASE_BRANCH"
  if [ "$PHASE_PUBLISH" = "push" ]; then
    echo "Pushed $PHASE_BRANCH for $GROUP_LABEL — no pull request opened. Open one when you are ready:"
    echo "  /aimi:open-pr --branch $PHASE_BRANCH"
    continue
  fi
  GROUP_PR_JSON=$($AIMI_CLI forge-pr-create --base "$GROUP_DEFAULT" --head "$PHASE_BRANCH" \
    --title "Phase [PHASE_ID]: [PHASE_NAME]" \
    --body "Completes phase [PHASE_ID] of [FEATURE]. See [PHASE_DIR]/handoff.md for details." \
    --project "$GROUP_TOPLEVEL") || GROUP_PR_JSON=""
  if [ -n "$GROUP_PR_JSON" ]; then
    GROUP_PR_STATUS=$(printf '%s' "$GROUP_PR_JSON" | jq -r '.status // empty')
    GROUP_PR_URL=$(printf '%s' "$GROUP_PR_JSON" | jq -r '.data.url // empty')
    if [ "$GROUP_PR_STATUS" = "created" ]; then
      echo "Opened pull request for $GROUP_LABEL: $GROUP_PR_URL"
    elif [ "$GROUP_PR_STATUS" = "unchanged" ]; then
      echo "Pull request already exists for $GROUP_LABEL: $GROUP_PR_URL"
    fi
  else
    echo "Pull request not opened for $GROUP_LABEL — see forge-pr-create's error above."
  fi
done <<< "$PHASE_GROUP_PROJECTS"
cd "$AIMI_ROOT"
```

`PHASE_PUBLISH` is the only thing in this loop that decides **whether** to publish, and it decides nothing else. On `none` the repository's own decline line is printed with the `/aimi:open-pr --branch` command that publishes it later, and the iteration ends before `forge-auth-status` is even consulted — no forge is queried, no `origin` is contacted, and the branch stays exactly where the container left it. On `push` the branch is pushed and the iteration ends before `forge-pr-create`, printing the same `/aimi:open-pr --branch` command, which is safe to suggest for an already-pushed branch precisely because `/aimi:open-pr` re-attempts the push itself (`${CLAUDE_PLUGIN_ROOT}/commands/references/publish-confirmation.md` § Always Name /aimi:open-pr). On `pr` the loop body runs end to end exactly as it did before this gate existed. Every other decision in the loop is untouched by all three: the not-a-git-repository skip, the `forge-auth-status` pre-push check and its recovery block, the `created`/`unchanged` reporting, the blank-`GROUP_PR_JSON` else branch, and the closing `cd "$AIMI_ROOT"` — which still runs after the loop no matter which branch each repository took. No branch here reverts, re-reads or rewrites the phase's `completed` status, and none re-claims the phase.

`forge-auth-status` is this loop's own actionability check, and it deliberately runs **before** the push rather than after it. It reports `status: "found"` if and only if the repository's remote resolves to a forge that has a working write adapter **and** that adapter's CLI is present on `PATH` — precisely the two conditions `forge-pr-create` gates its own write on (`commands/references/forge-contract.md`). This loop therefore reads that one `status` field and never re-derives the forge type or probes for a CLI binary itself, which is also why the check extends for free: the moment a GitLab or Gitea write adapter makes `forge-auth-status` report `found` for those remotes, they start pushing and opening PRs here with no change to this file. `data.authenticated` is deliberately **not** consulted — an installed-but-unauthenticated CLI still reaches the create call and fails there, which is an ordinary per-repository failure this loop already reports, not a reason to withhold the branch. Any status other than `found` means nothing here can open a pull request for that repository, so its branch is not published either: the loop prints that repository's own recovery block — its label, the container-scoped `git push -u origin` command, the `$GROUP_DEFAULT...$PHASE_BRANCH` compare range, and the `/aimi:open-pr --branch` line to run from that repository's own root once a forge CLI is installed and authenticated there — and moves to the next repository without ever touching `origin`. That last line is deliberately conditional: this branch fires precisely because no forge adapter or CLI is usable here, and `/aimi:open-pr` routes through the same forge verbs, so it would stop on the same condition if it were run right now. The push command and the compare range above it are the fallback that works with no forge at all, which is why both stay.

**This is stricter than the binary-presence gate phase 1 deleted, not a restoration of it.** That gate tested only whether a GitHub CLI existed on `PATH`, so a GitLab or Gitea remote on a machine that happened to have one installed *did* get its branch pushed; only the PR call failed, leaving a merge request openable from the forge's web UI. Routing the decision through `forge-auth-status` withdraws that push, on the principle that whether a branch reaches `origin` should not depend on an unrelated binary being installed. The recovery block above is what keeps that a defensible change rather than a regression — those users lose one pasted command, not the push itself.

`forge-pr-create` owns the presence check for whichever forge CLI this repository's remote needs, independently of the pre-push check above. When the forge is unsupported, its CLI is missing, or the create call itself fails, `forge-pr-create` prints the manual push/PR-URL fallback instructions itself (mandatory-print degrade mode, `commands/references/forge-contract.md`), emits a `status: "degraded"` envelope, and exits non-zero; this loop does not reimplement or duplicate that guidance — the non-zero exit blanks `GROUP_PR_JSON`, so neither the "opened" nor the "already exists" echo can be reached, and the `else` branch instead echoes one line naming that repository. That line is the attribution `_forge_pr_write_print_manual` cannot supply on its own: it has no repository context to name, so its banner is unattributed by construction, and a phase with N failing repositories would otherwise produce N indistinguishable banners. `forge-pr-create` checks for an existing open PR on `$PHASE_BRANCH` before ever creating one (its own check-then-create contract, matching open-pr.md's pre-existing "PR already exists" behavior) — a retried or re-entered phase reuses that PR (`status: "unchanged"`, `forge-contract.md`'s Write-Verb Status Convention: no new PR number was minted) rather than opening a duplicate.

If `git push` or `forge-pr-create` fails for a given repository (no permissions, offline, branch already has an open PR the tool itself cannot read, etc.), that repository's failure is what `forge-pr-create` already reported on stderr — report it verbatim, echo the loop's own per-repository line naming it, and continue on to the next repository — do not retry, do not prompt interactively, and never revert the phase's `completed` status. The `forge-auth-status` skip above obeys the same isolation contract: it is reported for that one repository, it consumes no other repository's turn, and the phase stays `completed` no matter how many of the participating repositories are skipped or fail.

With exactly one participating group — today's only previously-supported case — `PHASE_GROUP_PROJECTS` resolves to exactly `.`, `GROUP_TOPLEVEL` resolves to the same repository `$PHASE_CONTAINER_PATH` was built from, so `GROUP_CONTAINER` equals `$PHASE_CONTAINER_PATH` exactly, and `GROUP_DEFAULT` — detected fresh via the identical `--project`-scoped call Step 1.5's own `$DEFAULT_BRANCH` detection uses — equals `$DEFAULT_BRANCH`. Under the approving `pr` answer the push and the forge call issued are therefore the same single-repository push and PR creation as before, now routed through `forge-pr-create` instead of a direct GitHub-CLI invocation. That single repository is subject to the `forge-auth-status` check like any other: when its own status is not `found`, neither the push nor the PR call runs at all — the one group prints its recovery block, the loop body ends there, and the phase still finishes `completed`, exactly as the skip behaves for one repository out of many. When more than one group participates, the loop runs once per repository, each against its own container, its own default branch, its own actionability check, and its own pull request.

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

The phase named here is whichever one `roadmap-get --next-eligible` selects, and that is **not necessarily the lowest-numbered** eligible phase: the verb ranks dependency-eligible candidates by remaining work first — every candidate with pending stories ahead of every candidate without — and only then by ascending id. A phase whose stories are all complete is therefore offered *after* a higher-numbered phase that still has work, even though its id is lower. When every eligible candidate has work the ordering collapses to ascending id, which is why this offer is unchanged for the common case. Do not reword this prompt to promise the "next" or "lowest" phase.

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

**When `CONTAINER_MODE=true`:** read `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Container Mode: Stop the Dev Server, § Container Mode: Push the Branch, and § Container Mode: Remove the Container, and run all three, in that order, before continuing below — raising the push confirmation immediately below in between, after every dev-server stop has completed and before anything is pushed. When `CONTAINER_MODE=false` (inline mode), skip all three, skip the confirmation with them, and continue directly below.

**Confirm before this container's branch reaches `origin`.** The contract this question satisfies is defined once in `${CLAUDE_PLUGIN_ROOT}/commands/references/publish-confirmation.md` and is not restated here. The question itself lives in this command body rather than in that reference — or in `container-execution.md`, which owns the push it gates — because reference files reach OpenCode through a verbatim whole-tree copy that never translates the interactive-question tool's name, so a picker written into one would name a tool that host does not have. Resolve interactivity fresh — each Bash call is an isolated shell:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
INTERACTIVE_MODE=$($AIMI_CLI detect-interactivity)
echo "$INTERACTIVE_MODE"
```

**When `INTERACTIVE_MODE=picker`:** Use **AskUserQuestion** exactly once for the whole run, with exactly two options:

```
All stories are complete. Push [branchName] to origin now?

A — Push now
B — Skip (push it yourself later, or run /aimi:open-pr)
```

**Option A:** proceed to the push in § Container Mode: Push the Branch. **Option B:** set `SKIP_PUSH=true` — the same variable that reference's own push block gates on — and skip straight to § Container Mode: Remove the Container. Anything that is not an explicit A — a dismissed prompt, an unparseable answer, no answer at all — is B: silence is not approval. Ask once for the whole run, not once per project group; one answer governs every participating group (`publish-confirmation.md`). Write the question and its option text in whatever language the person is writing in, never a hardcoded one (`${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`'s Adaptive Language Rule).

*Agent-mode fallback: if `INTERACTIVE_MODE=agent`, raise no question at all — § Container Mode: Push the Branch's own `INTERACTIVE_MODE=agent` branch decides whether that run pushes and logs its own `agent-mode: container-push …` line.*

Count commits on this branch:

**When `CONTAINER_MODE=false` (inline mode, unchanged):**
```bash
git log --oneline $DEFAULT_BRANCH..HEAD | wc -l
```

**When `CONTAINER_MODE=true`:** the main working tree's `HEAD` was never checked out to `[branchName]` during container-mode execution (the same invariant Phase Mode's Main Working Tree Untouched Invariant establishes for `PHASE_BRANCH`, applied here by analogy), and the container that held it has just been removed above — count against the branch itself instead of `HEAD`, scoped per project group. A single global `$AIMI_ROOT`/`$DEFAULT_BRANCH` git log is wrong here: in a multi-repo layout (`AIMI_ROOT_IS_GIT_REPO=false`) there is no repo at `$AIMI_ROOT` and `$DEFAULT_BRANCH` was never set. For each unique `group_key` with a container from this run (see Container Paths Per Project Group), mirroring the same "for each unique `group_key`" loop **Container Mode: Push the Branch** and **Container Mode: Remove the Container** above already use. Read and validate `branchName` again — each Bash call is an isolated shell:
```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
BRANCH_NAME=$($AIMI_CLI metadata | jq -r '.branchName')
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

A gate is not the only thing that can still be open at this point. A story whose `verification.status` is still the literal `pending` declared a check nobody has judged — it is neither passed nor failed, and until this section it left no trace in the report at all, so a phase could close in silence with every one of its verifications unlooked-at. `verification-report`'s `pending` partition answers that from the same one read the malformed scan uses (see Step 0.7), scoped to the object branch so a story that never declared a verification never enters — the partition counts what was declared and not looked at, never what was never declared:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
if [ "${PHASE_MODE:-false}" = true ]; then
  COMPLETION_VERIF_REPORT=$($AIMI_CLI verification-report --tasks-file "$PHASE_TASKS_PATH" 2>/dev/null)
else
  COMPLETION_VERIF_REPORT=$($AIMI_CLI verification-report 2>/dev/null)
fi
# `.pending // []` is deliberate, not defensive habit: a CLI predating this
# partition answers {visual, malformed} with no `pending` key at all, and a
# bare `.pending | length` would abort the whole completion report over a
# section that is meant to be additive. An older CLI reports zero pending
# verifications, which is exactly what it knew.
PENDING_VERIF_COUNT=$(printf '%s' "$COMPLETION_VERIF_REPORT" | jq '.pending // [] | length' 2>/dev/null)
PENDING_VERIF_IDS=$(printf '%s' "$COMPLETION_VERIF_REPORT" | jq -r '.pending // [] | join(", ")' 2>/dev/null)
printf 'pending-verification: count=%s ids=%s\n' "${PENDING_VERIF_COUNT:-0}" "${PENDING_VERIF_IDS:-}"
# The `discriminating` partition is read off the SAME captured payload, never a
# second `verification-report` call: one read cannot disagree with itself about
# one file, and two reads across a phase this long can. `// 0` carries the same
# meaning `.pending // []` carries above — a CLI predating the partition answers
# {visual, pending, malformed} with no `discriminating` key, and it must report
# zero rather than abort a completion report over an additive section.
# `completed` is the whole partition (checked + blind + unrecorded), not
# `fraction`'s denominator: `unrecorded` stays out of that denominator on
# purpose, and leaving it out here too would hide exactly the legacy run this
# section exists to make visible — every story completed, nothing recorded.
EVIDENCE_CHECKED=$(printf '%s' "$COMPLETION_VERIF_REPORT" | jq '(.discriminating.checked | length) // 0' 2>/dev/null)
EVIDENCE_COMPLETED=$(printf '%s' "$COMPLETION_VERIF_REPORT" | jq '((.discriminating.checked | length) + (.discriminating.blind | length) + (.discriminating.unrecorded | length)) // 0' 2>/dev/null)
# Unconditional. Printed on every run, whatever the numbers are.
printf 'verification-evidence: discriminating=%s completed=%s\n' "${EVIDENCE_CHECKED:-0}" "${EVIDENCE_COMPLETED:-0}"
if [ "${EVIDENCE_CHECKED:-0}" -eq 0 ] && [ "${EVIDENCE_COMPLETED:-0}" -gt 0 ]; then
  printf 'verification-evidence: completion refused — %s completed stor(y|ies), not one of them carrying a discriminating assertion; a human records why with acknowledge-evidence --reason <text>, and it lapses if the completed count changes\n' "${EVIDENCE_COMPLETED:-0}"
fi
# Echo the acknowledgement that let an unchecked phase close, when one is recorded.
if [ "${PHASE_MODE:-false}" = true ]; then
  EVIDENCE_ACK_JSON=$($AIMI_CLI metadata --tasks-file "$PHASE_TASKS_PATH" 2>/dev/null | jq -c '.evidenceAcknowledged // empty' 2>/dev/null)
else
  EVIDENCE_ACK_JSON=$($AIMI_CLI metadata 2>/dev/null | jq -c '.evidenceAcknowledged // empty' 2>/dev/null)
fi
if [ -n "$EVIDENCE_ACK_JSON" ]; then
  printf 'evidence-acknowledged: %s (%s)\n' "$(printf '%s' "$EVIDENCE_ACK_JSON" | jq -r '.reason')" "$(printf '%s' "$EVIDENCE_ACK_JSON" | jq -r '.acknowledgedAt')"
fi
# `skipped` is read off the SAME captured payload too, for the identical
# one-read-cannot-disagree-with-itself reason the discriminating comment
# above gives. `// []` carries the same meaning `.pending // []` carries —
# a CLI predating this key answers {visual, pending, malformed,
# discriminating} with no `skipped` key at all, and it must report zero
# rather than abort a completion report over an additive section.
SKIPPED_VERIF_COUNT=$(printf '%s' "$COMPLETION_VERIF_REPORT" | jq '.skipped // [] | length' 2>/dev/null)
SKIPPED_VERIF_LINES=$(printf '%s' "$COMPLETION_VERIF_REPORT" | jq -r '.skipped // [] | map("  " + .id + " — " + (.reason // "no reason recorded")) | join("\n")' 2>/dev/null)
printf 'skipped-verification: count=%s\n' "${SKIPPED_VERIF_COUNT:-0}"
# `verdicts` is read off the SAME captured payload too, for the identical
# one-read-cannot-disagree-with-itself reason the two comments above give.
# Each `// 0` carries the same meaning every other default on this payload
# carries — a CLI predating this key answers {visual, pending, malformed,
# discriminating, skipped} with no `verdicts` key at all, and each of its
# five counts must report zero rather than abort a completion report over
# an additive section.
VERDICT_PASSED=$(printf '%s' "$COMPLETION_VERIF_REPORT" | jq '.verdicts.passed // 0' 2>/dev/null)
VERDICT_FAILED=$(printf '%s' "$COMPLETION_VERIF_REPORT" | jq '.verdicts.failed // 0' 2>/dev/null)
VERDICT_SKIPPED=$(printf '%s' "$COMPLETION_VERIF_REPORT" | jq '.verdicts.skipped // 0' 2>/dev/null)
VERDICT_PENDING=$(printf '%s' "$COMPLETION_VERIF_REPORT" | jq '.verdicts.pending // 0' 2>/dev/null)
VERDICT_OTHER=$(printf '%s' "$COMPLETION_VERIF_REPORT" | jq '.verdicts.other // 0' 2>/dev/null)
# Unconditional, like `verification-evidence:` above and for the identical
# reason — see that printf's own comment.
printf 'verdicts: passed=%s failed=%s skipped=%s pending=%s other=%s\n' \
  "${VERDICT_PASSED:-0}" "${VERDICT_FAILED:-0}" "${VERDICT_SKIPPED:-0}" "${VERDICT_PENDING:-0}" "${VERDICT_OTHER:-0}"
```

In phase mode the file named is this phase's own tasks file, the same one Step 5 already scopes its story-level reporting to. In flat mode the flag is omitted so the wrapper resolves the session-bound file itself — the one case in this command where `verification-report`'s `get_tasks_file` fallback is the right answer, because by Step 5 `init-session` has long since pointed session state at the file this run executed.

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
    story_id=$(basename "$gap_file" .md | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//; s/^(US-[0-9]+).*/\1/')
    echo ""
    echo "### $story_id"
    cat "$gap_file"
  done
fi
```

If `PENDING_VERIF_COUNT` > 0, append:
```
## Pending Verification

[PENDING_VERIF_COUNT] stor(y|ies) declared a verification that has not been
judged — not passed, not failed, still `pending`:

  [PENDING_VERIF_IDS]

These stories are complete as work and open as verification. Nothing here
blocks the branch or the PR; it is named because the alternative is a phase
that closes with its checks unlooked-at and says nothing about it.
```

If `PENDING_VERIF_COUNT` is 0 (or the section's own command produced nothing — an older CLI with no `pending` partition reads as zero), omit the `## Pending Verification` section entirely.

If `SKIPPED_VERIF_COUNT` > 0, append:
```
## Skipped Verification

[SKIPPED_VERIF_COUNT] completed stor(y|ies) recorded a verification that was
short-circuited rather than judged — not passed, not failed, deliberately
`skipped`:

[SKIPPED_VERIF_LINES]

Each line is the story id and the reason recorded for skipping it, or the
literal "no reason recorded" for a legacy skip that predates this field.
Nothing here blocks the branch or the PR; it is named so a skip is never
silent about why it happened.
```

If `SKIPPED_VERIF_COUNT` is 0 (or the section's own command produced nothing — an older CLI with no `skipped` key reads as zero), omit the `## Skipped Verification` section entirely — the identical omit-at-zero rule `## Pending Verification` takes immediately above, and for the identical reason: both report a POSITIVE fact (a story did something worth naming), so zero of either is genuinely nothing to report, no story declared-and-unjudged, no story short-circuited its own verdict. This is deliberately the SAME rule `## Verification Evidence` immediately below refuses to take — see the reasoned paragraph beside that section for why zero *discriminating* evidence is the one silence this report must never allow, unlike zero pending or zero skipped, which are both silences this report is glad to have nothing to say about.

Append, on **every** run — never omitted, never conditional on the numbers being good:
```
## Verification Evidence

discriminating=[EVIDENCE_CHECKED] completed=[EVIDENCE_COMPLETED]
verdicts: passed=[VERDICT_PASSED] failed=[VERDICT_FAILED] skipped=[VERDICT_SKIPPED] pending=[VERDICT_PENDING] other=[VERDICT_OTHER]

[EVIDENCE_CHECKED] of [EVIDENCE_COMPLETED] completed stor(y|ies) recorded a
verify that discriminated — at least one assertion that behaved differently
before the story's work than after it. The rest either recorded an honest zero
or recorded nothing at all.
```

When `EVIDENCE_CHECKED` is 0 and `EVIDENCE_COMPLETED` is greater than 0, append this paragraph to that same section — the identical condition the `completion refused` printf above carries, restated here so the streamed line and the written section can never disagree about one run:
```
This phase closed unchecked. Every story is complete and not one of them left
evidence that anything was actually verified.
```

When `EVIDENCE_ACK_JSON` is non-empty, add one more line to that section: `Acknowledged: <reason> (<acknowledgedAt>)`.

**This section deliberately does NOT take `## Pending Verification`'s omit-at-zero rule, and a later edit must not tidy the two into consistency.** They look like neighbours and they are opposites. Zero pending verifications is genuinely nothing to report — nobody declared a check that nobody judged, so the section has no subject. Zero *discriminating* verifications is the single loudest thing this report can say: it means the phase closed with no evidence that anything was checked, and that is exactly the run a silent report makes indistinguishable from a flawless one. "33/33 completed, 0 unmet" is equally compatible with both, which is the defect this section exists to remove; a line that only prints when the number is good would rebuild it. The absence has to be as visible as the presence, so the numbers print whatever they are.

**The `verdicts:` line beside it is deliberately kept OUT of `handoff.md`'s `## Deviations` array and out of the locked-token list two bullets above it (Write Handoff, `verification-evidence:`/`verification-skipped:`), and a later edit must not "complete the set" by adding it there — and not for the reason it first looks like.** Write Handoff already makes its own dedicated `verification-report` call at that point in the flow (the one that reads `.skipped` for the `verification-skipped:` line) and that same response already carries `.verdicts` too, at no extra cost — so "it would take a second, possibly-disagreeing call" is not why this stays out; that call already exists. The real reason is what a handoff exists to preserve. `verification-evidence:`'s `m`/`n` counts THIS RUN's own contribution, computed from Step 4's own per-run accumulator — a fact no later read of the tasks file can recover, because nothing in the document records which run completed which story, so the handoff is the only place that fact survives at all. `verdicts` carries no such unrecoverable fact: it is a pure function of the finished tasks file, answerable by re-running `verification-report` for as long as that file exists — forever, for a completed phase. The one piece of the distribution worth writing down permanently — WHY a story was short-circuited — is already itemized, one line per story, in `verification-skipped:` above; the rest is a summary a later reader can always ask for again, never information that would otherwise be gone.

Append, on **every** run, immediately after `## Verification Evidence` above — the **Finalize Step** (Step 4, after Post-Loop Cleanup) always leaves `FINALIZE_STATUS` set, so there is always something to say:
```
## Finalize

status: [FINALIZE_STATUS]
commit: [FINALIZE_COMMIT]
subject: [FINALIZE_SUBJECT]
reason: [FINALIZE_REASON]
```

Render exactly the lines that carry a value: on `status: ran`, print `commit:` and `subject:` and omit `reason:`; on `status: skipped` or `status: failed`, print `reason:` — the step's own recorded sentence, verbatim, whether it is `metadata.finalize not declared`, a project-group count, or a merge conflict — and omit `commit:` and `subject:`, which name a commit that was never made.

This section takes `## Verification Evidence`'s print-whatever-it-is rule rather than `## Pending Verification`'s omit-at-zero one, for the same reason: `skipped` is the answer a reader most needs and the one a conditional section would hide. A run whose closing commit never happened looks, in a report that omits the section, exactly like a run whose closing commit landed — and the operator finds out at release time. `ran` with no commit sha is likewise impossible by construction: the Finalize Step only reaches `ran` after `merge-all` returns and `rev-parse` has answered.

If `DESIGN_REVIEW_BUFFERS` is non-empty, append:
```
## Design Review

For each entry in DESIGN_REVIEW_BUFFERS (keyed by story id, insertion order):

### [story_id]: [entry.title]

[entry.output]
```

If `DESIGN_REVIEW_BUFFERS` is empty, omit the `## Design Review` section entirely.

**Persist that section, then name the file it was written to.** Until this step the design reviews existed only in the transcript: the reviewer agent ran per story in Step 4, its output was buffered, printed once here, and lost with the session — so a review nobody read in the hour it was printed was a review nobody could read at all. `write-review` writes it to `.aimi/reviews/<feature>-phase-<N>.md` under the same `mktemp`-then-`mv` discipline every other document writer in this CLI uses, and returns `{review: "<path>"}`. Run this when `DESIGN_REVIEW_BUFFERS` is non-empty **and** `PHASE_MODE=true` and `$PHASE_ID` is set — the verb takes a feature and a phase, and those are the only two values that name the file. Compose the whole section body first (every `### [story_id]: [entry.title]` block and its `[entry.output]`, in insertion order, exactly as printed above) and pipe it in one call: the path is derived from feature and phase alone, so one call per story would have every story overwrite the last and leave only the final review on disk.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
DESIGN_REVIEW_BODY=$(cat <<'DESIGN_REVIEW_EOF'
[paste the composed ## Design Review section body here, verbatim — every
### [story_id]: [entry.title] heading and its [entry.output], insertion order]
DESIGN_REVIEW_EOF
)
DESIGN_REVIEW_JSON=$(printf '%s\n' "$DESIGN_REVIEW_BODY" | $AIMI_CLI write-review --feature "$FEATURE" --phase "$PHASE_ID") || DESIGN_REVIEW_JSON=""
DESIGN_REVIEW_PATH=$(printf '%s' "$DESIGN_REVIEW_JSON" | jq -r '.review // empty' 2>/dev/null)
printf 'design-review: %s\n' "${DESIGN_REVIEW_PATH:-<not written>}"
```

The heredoc delimiter is quoted, so review prose carrying `$`, backticks or `$(` reaches the verb as the bytes the reviewer wrote rather than as something this shell tries to expand. `|| DESIGN_REVIEW_JSON=""` is what keeps a refusal advisory: `write-review` refuses an empty stdin at exit 1 rather than leaving a zero-byte file that reads on disk exactly like a review that was never written, and a completion report is not the place to abort over a document that was already printed in full two paragraphs above.

When `DESIGN_REVIEW_PATH` is non-empty, append the path to the `## Design Review` section as its last line, so the reader is told where the section they just read now lives:
```

Written to: [DESIGN_REVIEW_PATH]
```

When the write did not happen, say which of the two reasons applies rather than printing nothing:

- **`PHASE_MODE=false`** (flat execution, no roadmap and so no `FEATURE`/`PHASE_ID` pair): append `Not written to disk — flat execution has no feature/phase pair to name a review file.` The verb is not called at all here; inventing a phase id to satisfy it would put a review under a phase that does not exist.
- **The call ran and returned nothing** (`DESIGN_REVIEW_PATH` empty at exit): append `Not written to disk — write-review returned no path; the review above is the only copy.` Say it plainly; a reader who believes a file was written and finds none is worse off than one who was told the transcript is it.

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

**When `CONTAINER_MODE=false` (inline mode):** no container was ever created and nothing was torn down, so the branch is still checked out right here — use the bare form, with no `--branch`, so that `/aimi:open-pr` still runs its uncommitted-changes check (it skips that check whenever `--branch` names a branch, since that branch is checked out elsewhere or nowhere). Naming the command at all is the obligation `${CLAUDE_PLUGIN_ROOT}/commands/references/publish-confirmation.md` § Always Name /aimi:open-pr states.
```
### Next Steps

- Review commits: `git log --oneline -[count]`
- Run `/aimi:review` for code review
- Open a PR when ready: `/aimi:open-pr`
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

**Phase mode with a split (`PHASE_SPLIT_MODE=true`):** the same idempotency extends to Phase-Mode Paired Split — `$WORKTREE_MGR create "$split_branch" --from "$PHASE_BRANCH"`, run once per active split branch, reuses each split worktree silently if a prior run left one in place, and re-spawning the sub-orchestrators is harmless: each one's own `init-session --file` points at a split file whose already-completed stories are skipped automatically (points 1–4 above), so a sub-orchestrator with nothing left pending returns immediately. A member that completed entirely on the prior run is dropped by Step 1.7's Active Split Files filter and never re-spawned at all. This is also what makes retrying after a Merge Split Branches Into the Phase Branch conflict safe, for any number N of participating repositories: re-running does not re-execute any story, and it re-issues **every** repository's own `merge-all` call in full — never a partial resume from a saved per-repository position — because a branch already merged onto its own repository's `$PHASE_BRANCH` merges again idempotently ("Already up to date", exit 0), whether this run merged it moments ago or a human resolved a different repository's conflict by hand inside that repository's own phase container first (per that section's own report instruction to do so). Retrying therefore only retries the merge and the Multi-File Pending Count / Creates Verification checks that follow it.

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
