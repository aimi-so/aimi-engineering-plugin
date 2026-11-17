# Execute: Wave Reconcile

> Loaded by `commands/execute.md` through its Step 4 entry, before the integrated check that follows each group's merge.
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

## Inputs and outcomes

Each group's merge, clean or resolved, hands this procedure the state below. The caller derives it; this file never re-derives it.

```
label                  # "wave N"
group_key, merge_cwd, merge_target, base_sha
merged_stories         # the orchestrator's own list for THIS group: id, title, worktree_name
WAVE_TASKS_FILE, AIMI_ROOT, PLAN_DISC
result_payload_by_id   # each story's executor result, with its verify evidence
other_groups           # state of the wave's other groups: already complete, or not yet merged
                       # (derived from succeeded_by_project and the current group_key)
```

The procedure ends in exactly one reported status:

- `passed`: the union ran green.
- `skipped`: the skip rule held.
- `reconciled after N rounds`: a reconcile round made the union green.
- the integration stop: see the last section.

The first three become the wave summary line only: no tasks.json change and no new evidence field. Only the stop forbids the caller from marking any story of the group complete.

## Skip rule

```
if len(merged_stories) == 1:
    story = merged_stories[0]
    tree_head  = git -C [merge_cwd] rev-parse HEAD^{tree}
    tree_story = git -C [merge_cwd] rev-parse [story.worktree_name]^{tree}   # the story's verified commit
    if tree_head == tree_story and result_payload_by_id[story.id].verify.exit == 0:
        Report: "wave [wave] ([group_key]): integrated check skipped, one story merged and the tree equals its verified commit."
        status = skipped; return
```

A wave with one merged story out of several launched is the same case. Anything else runs the check.

## Select the union

```
ids = [s.id for s in merged_stories]          # never tasks.json `wave`
union = $AIMI_CLI wave-verify-commands [ids...] --tasks-file [WAVE_TASKS_FILE]
        # JSON array of {command, project, stories}, deduplicated
```

A story enters the union only when its executor recorded verify evidence. List every other story as `not re-verified` in the report. No command is skipped because the in-place conflict loop already ran it. The orchestrator never runs a command the reconcile worker proposes.

## Prepare

```
PRE_RECONCILE_SHA = git -C [merge_cwd] rev-parse HEAD
# Re-run the dependency install in the form this group's setup used (as step-1-7 and step-2 call it):
$WORKTREE_MGR install-deps ...   # the same arguments as that group's setup
export AIMI_ROOT=[AIMI_ROOT]
export TASKS_FILE_PATH=[WAVE_TASKS_FILE]     # the run's own tasks file, for every command below
```

A command's `project` is its cwd under merge_cwd. It must be relative, free of `..` and inside merge_cwd; otherwise stop the check, naming it.

## Run the union

Run the commands one at a time, each in its own Bash call under the 600 s tool cap, from merge_cwd or its project subfolder. Print each command with the stories that own it.

```
mkdir -p [AIMI_ROOT]/.aimi/wave-verify
log = [AIMI_ROOT]/.aimi/wave-verify/[PLAN_DISC]-wave-[wave]-g[g]-c[k]-r[round].log
[command] > [log] 2>&1; echo exit=$?; tail -n 40 [log]
```

Only the tail reaches your context. Never echo the environment.

- A command that times out stops the wave without reconcile, naming it.
- After each command run `git -C [cwd] status --porcelain`. A dirty tree stops the wave, naming the command that dirtied it.

`failing = commands with a non-zero exit`. When it is empty: status `passed`.

## Flaky filter

Before the first reconcile round, re-run each failing command once, unchanged, in its own Bash call, with the same checks. A command that then passes is reported as flaky and is not reconciled. When every failure was flaky the check passes and the report names the flaky commands.

## Reconcile rounds

```
RECONCILE_BRIEF: resolve it as EXECUTOR_BRIEF is resolved at the top of step 4, with the tail
  skills/story-executor/references/reconcile-worker.md; echo RECONCILE_BRIEF or RECONCILE_BRIEF_MISSING.
  On RECONCILE_BRIEF_MISSING, stop and report the path: never spawn a worker without its brief.

summaries = []
for round in 1..2:
    round_start_sha = git -C [merge_cwd] rev-parse HEAD
    tasks_hash      = sha256 of [WAVE_TASKS_FILE]
    before          = len(failing)
    if flat inline mode and git -C [merge_cwd] status --porcelain is non-empty:
        stop (integration stop), saying merge_cwd holds uncommitted changes the wave did not make; spawn no worker

    Task(
        subagent_type: "general-purpose",
        model: <AGENT_MODELS.executor when not "inherit">,
        effort: <AGENT_EFFORTS.executor when not "inherit">,
        description: "Reconcile [label], round [round]",
        prompt: a POINTER, never a pasted copy: "You are a reconcile worker for aimi-engineering.
                Before any other action, read [RECONCILE_BRIEF] in full with the Read tool and
                follow it exactly." then, each inside its own delimited block:
            FAILING_COMMANDS  = each failing command, its log tail and the log path
            STORIES           = involved stories' id, title, acceptanceCriteria, implementation.files
            MERGE_DIFF_STAT   = git -C [merge_cwd] diff --stat [base_sha]..HEAD
            MERGE_CWD         = [merge_cwd]
            PREVIOUS_ROUNDS   = summaries so far, oldest first
    )   # the worker creates no worktree
```

The worker answers with `{outcome, summary}`. Append the summary to `summaries`.

Round check, the orchestrator's own act, before anything else:

```
changed   = git -C [merge_cwd] diff --name-only [round_start_sha]
untracked = git -C [merge_cwd] status --porcelain --ignored
# with the tasks_hash comparison, this covers .aimi/, tasks-file and verify-text edits
if changed or untracked touches .aimi/, a tasks file (hash differs), any story's
   implementation.verify text, or .git/:
    git -C [merge_cwd] reset --hard [round_start_sha]   # plus deleting only the untracked paths the round created
    stop (integration stop), naming the forbidden edit
files outside the involved stories' implementation.files and the files the failing output names:
    list them in the report; do not undo them
```

Then re-run the whole union yourself (all commands, not only the failing ones, each in its own Bash call as above) and never trusts the worker's report.

Round accounting:

- A round that makes no commit counts as spent.
- When more commands fail after a round than before it, reconcile ends at once: integration stop.
- The outcomes `requirements-conflict`, `stale-verify` and `environmental` stop at once: integration stop with the outcome and summary reported.
- When the union is green after a round: status `reconciled after [round] rounds`, naming the reconcile commits.
- When round 2 ends with failures left: integration stop.

## Integration stop

Its own heading and message, distinct from MERGE CONFLICT. Only this stop offers reconcile.

```
Report:
"INTEGRATION CHECK FAILED during [label] in project [group_key]."
"Failing commands, with their owning stories:"
"  [command] — [story ids]"
"PRE_RECONCILE_SHA: [PRE_RECONCILE_SHA]"
"To return the branch to the merged state, run: git -C [merge_cwd] reset --hard [PRE_RECONCILE_SHA]"
"Reconcile commits: [list, or none]"
"Uncommitted worker edits: [list, or none]"
"Other groups of this wave: [already complete | not yet merged], per other_groups"
"Stories not re-verified: [ids, or none]"
if the wave's diff ([base_sha]..HEAD) touches none of the failing area:
    "The failure may predate the wave: the wave's diff does not touch the failing area."
"Fix the branch [merge_target] in [merge_cwd] and re-run `/aimi:execute` to continue."
```

Cleanup differs from MERGE CONFLICT: nothing is removed for this group's merged stories. Keep their worktrees and branches, and leave their stories `in_progress`: no story of the group is marked complete.

In phase mode release the claim, then STOP:

```
$AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
```

In every mode, then STOP. The caller reports nothing further for this group.
