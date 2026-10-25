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

Applies when: `PHASE_SPLIT_MODE=false` (the default when Step 1.7 was skipped, so a flat run always reads it). When `PHASE_SPLIT_MODE=true` skip it: the split sub-orchestrators and Phase Completion own the pending count there.
Covers: `### Validate Dependencies`, and the Re-verify branch.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-3-check-pending.md in full.


## Steps 3.1 and 3.2: Resolve Worktree Manager, Read Concurrency Setting

Applies when: `PHASE_SPLIT_MODE=false` and Step 3 did not report its Re-verify block. When Step 3 reported it, skip this file (default: Step 3 did not fire the re-verify branch).
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-3-1-3-2-worktree-and-concurrency.md in full.


## Step 3.3: Load Project Guidelines

Applies when: `PHASE_SPLIT_MODE=false` and Step 3 did not report its Re-verify block. When Step 3 reported it, skip this file (default: Step 3 did not fire the re-verify branch). The Container Dev Server Bootstrap in it skips itself unless `CONTAINER_MODE` is true.
Covers: `### Per-Project Guidelines`, `### Container Dev Server Bootstrap`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-3-3-guidelines-and-dev-server.md in full.


## Step 3.4: Open Visual Follow Session

Applies when: `VISUAL_FOLLOW=true`, `PHASE_SPLIT_MODE=false` and Step 3 did not report its Re-verify block. Otherwise skip this file (default `VISUAL_FOLLOW=false`; Step 3 cites this entry as Step 3.4).
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-3-3-open-visual-follow.md in full.


## Step 4: Wave Execution Loop

Applies when: `PHASE_SPLIT_MODE=false`, Step 3 did not report its Re-verify block and the pending count was above zero. Otherwise skip this file (default: Step 3 did not fire the re-verify branch).
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-4-wave-execution-loop.md in full.


### Post-Loop Cleanup

Applies when: `PHASE_SPLIT_MODE=false` and Step 3 did not report its Re-verify block, once the wave loop has ended. Otherwise skip this file (default: Step 3 did not fire the re-verify branch).
Covers: `### Visual Follow Session — Keep Open`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-4-post-loop-cleanup.md in full.


### Finalize Step

Applies when: every top-level run that reached Post-Loop Cleanup, immediately after it. Otherwise skip this file and treat `FINALIZE_STATUS=skipped` as the default: a Phase-Mode Paired Split sub-orchestrator, a run whose Step 3 reported its Re-verify block, and a run with no `metadata.finalize` all leave `FINALIZE_STATUS=skipped`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-4-finalize.md in full.


## Console Error Attribution

Applies when: at least one story of the run is a visual story, so the per-story post-merge visual verification in Step 4 calls `attribute_console_errors()`. Otherwise skip this file (default: no visual story, no console buffer).
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/console-error-attribution.md in full.


## Phase Completion

Applies when: `PHASE_MODE=true` outside a spawned split task (the top-level orchestrator, where `$PHASE_ID` is set). Otherwise skip this entry and the five Phase Completion files below (default `PHASE_MODE=false`).
Covers: `### Multi-File Pending Count`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/phase-completion-pending-count.md in full.


### Creates Verification

Applies when: `PHASE_MODE=true` outside a spawned split task, and the phase's pending count was zero. Otherwise skip this file (default `PHASE_MODE=false`).
Covers: `#### Inputs`, `#### Procedure`, `#### Which branch to take`, `#### Verification tooling failed`, `#### On any missing entry`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/phase-completion-creates-verification.md in full.


### Phase Visual Gate

Applies when: `PHASE_MODE=true` outside a spawned split task, and the pending count was zero after Creates Verification. Otherwise skip this file (default `PHASE_MODE=false`).
Covers: `#### Is a comparison owed`, `#### Environment checks and the live URLs`, `#### Run the comparison`, `#### On a diverges verdict`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/phase-completion-visual-gate.md in full.


### Write Handoff

Applies when: `PHASE_MODE=true` outside a spawned split task, and the pending count was zero. Otherwise skip this file (default `PHASE_MODE=false`).
Covers: `### Mark Phase Completed`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/phase-completion-handoff-and-mark.md in full.


### Offer a Pull Request

Applies when: `PHASE_MODE=true` outside a spawned split task, and the pending count was zero. Otherwise skip this file (default `PHASE_MODE=false`).
Covers: `#### Select the acting forge account per repository`, `#### Confirm before publishing this phase`, `#### Publish each participating repository`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/phase-completion-offer-pull-request.md in full.


### Next Phase

Applies when: `PHASE_MODE=true` outside a spawned split task, and the pending count was zero. Otherwise skip this file (default `PHASE_MODE=false`).
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/phase-completion-next-phase.md in full.


## Step 5: Completion

Applies when: `PHASE_SPLIT_MODE=false` (the default when Step 1.7 was skipped), on every run that finished its wave loop or Phase Completion without a deadlock. When `PHASE_SPLIT_MODE=true` skip it.
Covers: `### If all stories complete:`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-5-completion.md in full.


### If deadlock detected:

Applies when: `PHASE_SPLIT_MODE=false` and the wave loop stopped with stories still pending that are not ready. Otherwise skip this file (default: no deadlock).
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/step-5-deadlock.md in full.


## Resuming Execution

Applies when: every run, when the conversation resumes after `/clear` or a run must be abandoned or recovered. Otherwise skip this file.
Covers: `### After /clear`, `## Error Recovery`, `### Abandoning a Containerized Run`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/execute/resuming-and-error-recovery.md in full.
