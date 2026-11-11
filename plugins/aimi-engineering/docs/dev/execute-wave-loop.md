# Execute Wave Loop: Why

The reasoning behind the comments in `commands/references/execute/step-4-wave-execution-loop.md`, moved out of that file so the orchestrator does not carry it in context on every turn of a run. Read this when you change the wave loop; the loop itself keeps one line of instruction where each passage was.

## WAVE_TASKS_FILE

WAVE_TASKS_FILE — this run's own tasks file, resolved once here with the
same PHASE_MODE-conditioned formula Step 3 above already applied ($PHASE_TASKS_PATH
when PHASE_MODE=true, else $TASKS_PATH (absolute) — both already resolved by
this point in every flow, including a split sub-orchestrator, which pre-sets
PHASE_TASKS_PATH before it ever reaches here). Every CLI call in this loop
passes it explicitly as --tasks-file instead of falling through to the
shared current-tasks pointer, which is what let two concurrent split
orchestrators silently read and mutate each other's file.

## Re-point the CLI at the top of the wave

Step 0 resolves $AIMI_CLI once, at the start of the run, and nothing in
this loop has ever revisited it. A wave loop outlives that resolution:
a `cleanup-versions` run in another session prunes the cache directory
this run's path points into, and every later call answers "No such file
or directory" through a path that was correct when it was written.

The POSITION is the load-bearing part, not the call. The same --fix run
between spawn and merge is what broke a mark-complete mid-wave: the
cached path moved while N workers already held the old one, so the
orchestrator wrote through a CLI its own workers had never seen. Here,
between the last merge of wave N and the first spawn of wave N+1,
nothing is in flight and a re-point can strand no one. Do not move this
call further down for symmetry with anything.

Every Bash call in this file re-reads $AIMI_CLI from the cache --fix
rewrites (Step 0's Per-Call Resolution note), so the repointing reaches
the next call on its own; nothing is reassigned here. Read `status` and
not the exit code alone — `unknown` exits 0 and means no plugin is
installed at all (see cli-path-resolution.md's Version Check table).

## Derive EXEC_ROOT / EXEC_BRANCH per project group

DERIVE EXEC_ROOT / EXEC_BRANCH PER PROJECT GROUP — see container-
execution.md's Execution Context: EXEC_ROOT, EXEC_BRANCH, EXEC_OWNS_ROOT,
EXEC_KEEPS_BRANCH. This is the only place in the wave loop
and its cleanup passes that checks PHASE_MODE/CONTAINER_MODE directly —
every consumer below reads EXEC_ROOT[group_key]/EXEC_BRANCH[group_key]
instead (project_roots itself still survives untouched for the four
consumers that need it independently of EXEC_ROOT — see that section).

## Phase container paths in a split sub-orchestrator

PHASE_CONTAINER_PATHS[group_key] is populated for every
participating group by Create Phase Containers Per Project
Group (Step 1.7) in the top-level orchestrator. A Phase-Mode
Paired Split sub-orchestrator never runs Step 1.7 — its spawn
prompt pre-sets only the scalar PHASE_CONTAINER_PATH to its own
split's worktree (see Spawn Split Sub-Orchestrators), so the map
is empty there and this falls back to that scalar unchanged.

## The worktree prefix

PLAN_DISC comes from Multi-Repo Handling's `### Plan Discriminator`,
derived once from WAVE_TASKS_FILE above. worktree_base is deliberately
NOT redefined: it is read a second time below as `--from [worktree_base]`
and must keep naming a branch that really exists, so the discriminator
goes into a separate prefix rather than being folded into the base.

## Create sentinels

worktree-manager.sh's create emits two unprefixed lines on BOTH
of its branches, fresh creation and silent reuse alike:
    WORKTREE_PATH=<absolute path>
    WORKTREE_BASE=<full 40-char sha of the new tree's own HEAD>
Take the LAST occurrence of each: the fresh-creation branch
prints a `cd <path>` hint after them, and everything else create
writes is ANSI-coloured progress text carrying neither prefix.
The sha is deliberately full-length — an abbreviated one is
ambiguous exactly when two bases are close enough to confuse.

Either sentinel missing is a FAILURE OF THIS STORY, decided
BEFORE the executor is spawned. There is no useful recovery
after that point: by the time a wrong tree announces itself the
work is already written onto it. The usual cause is a
worktree-manager.sh predating the sentinels, which is a host
problem and not this story's — say so and stop.

## The tree must stand on the base we asked for

base_sha[group_key] is this group's EXEC_BRANCH HEAD, captured
above before any worktree was cut — the base every story in this
wave is meant to stand on. worktree_base_sha is what the tree
ACTUALLY stands on. Divergence is a FAILURE, not a warning.

Measured, in this repository's own phase 2: a story worktree cut
from main instead of from its phase branch announced nothing at
creation. It surfaced three levels downstream as a CLI verb
answering "Unknown command", a pytest suite short by the phase's
own new cases, and a golden file still holding the previous
value — three symptoms pointing at three different places, none
of them at the base. This comparison is what turns that into one
line, before a single file is written.

Equality is the fresh-creation case. The one other ACCEPTED
shape is a reused worktree that already carries commits of its
own: a story that committed and then failed keeps both worktree
and branch (see the merge-conflict cleanup below), so a re-run
legitimately finds a tree AHEAD of the base. Accept exactly that
— base_sha[group_key] reachable from worktree_base_sha — and
nothing else. A tree cut from a different branch fails this,
which is the whole point; a strict equality test would instead
fail every resumed run, and a check that cries wolf on the
normal path is a check someone deletes.

## Spawn field notes

- TASKS_FILE_PATH = WAVE_TASKS_FILE  ← this wave's own resolved tasks file. The
brief's <task_pointer> passes TASKS_FILE_PATH to its own get-story-context call,
so the worker reads this orchestrator's file even when a sibling split
orchestrator's init-session call last wrote the shared pointer

- SCRATCH_PREFIX = PLAN_DISC + "-" + full_story.id  ← the executor's scratchpad
namespace, handed over ALREADY COMPOSED. `PLAN_DISC` is READ here and never
recomposed nor re-sanitized (`### Plan Discriminator` under Multi-Repo Handling
derived it once). The plan comes FIRST: the measured collision was an earlier
plan's file for a story with the same `US-NNN`, which a story-id-only prefix
cannot separate.

## Why the orchestrator reads only result_json

Reading the structured block keeps the next orchestrator turn's input
token cost down — empirically a worker returns ~600 tokens of prose where
the orchestrator only consumes ~50-200 tokens of structured signal.

## Stalled executor detection

This happened for real, twice in phase 1 of this feature: a spawned
executor finished its work, ran its own verify suite, and went idle
without ever emitting <result_json> and without running `git commit`.
Both times the only way it surfaced was the orchestrator going and
looking at `ps` / the agent roster by hand — nothing in this loop told
anyone to. The fallback above (missing or malformed <result_json> —
falling back to Task exit signal) presupposes the Task returned with
SOMETHING usable; a stalled executor's Task call still returns in this
same turn (every Task here is foreground — see "Spawn ALL workers"
above), but its own exit signal says nothing about whether real work
got left behind uncommitted, because it never looked.

No clock, no liveness probe of the agent — this crosses three facts
the loop already captures for every story with no valid result_json:
  1. missing or malformed result_json (payload is None, from the loop above)
  2. HEAD in the worktree is unchanged from base_sha (no commit landed)
  3. the worktree is dirty (the executor wrote SOMETHING before going idle)
All three together is a stalled story. Any one of them alone is not:
(1) alone is the existing fallback, untouched, trusting Task's own
signal; (2)+(3) without (1) is the ordinary ok-but-no-commit case the
COMMIT VERIFICATION step below already walks through result_payload_by_id.

Detection runs over EVERY story with no result_json, whichever bucket
the fallback above placed it in — a stalled executor's own Task exit
signal can read as a success (nothing errored, it just never reported)
or as a failure (it ran out of turns going idle), and the fallback has
no way to tell those apart. A stalled story found sitting in
failed_stories is moved into succeeded_stories so it reaches the SAME
commit-verification / commit-rescue pass below as every other
no-commit story — this never adds a third resolution path, it only
widens which stories reach the two that already exist.

## Commit rescue

A story that reached here reported ok and left a dirty tree with no
commit on it. That is a mechanics defect, not a bad story: the work
exists and the only thing missing is the `git commit` the executor owed.
Failing it discards a finished implementation and cascade-skips
everything downstream of it, which is a far larger loss than the defect.
This happened for real — a story in this very phase finished its work
and returned without committing.

THE SUBSET IS THE GUARD, and it is the only thing making this safe to do
on someone else's behalf. `implementation.files` is what the planner said
this story would touch. When every modified path is inside that list, the
orchestrator knows exactly what it is committing and to which story it
belongs. One path outside the list means the tree holds something nobody
declared — a stray edit, a half-finished second concern, another story's
leftovers — and the orchestrator has no basis to attribute it. That case
takes the unchanged failure flow below; it is never rescued, never
partially staged, and never trimmed down to the declared subset to make
it fit.

2. The subset guard. `implementation.files` comes from the CLI, not
   from a raw read of the tasks file — get-story-context is the same
   verb the executor itself bootstraps with, so orchestrator and
   worker read one document through one reader.

`implementation` is optional in schema v3.3. Absent or empty declares
nothing, so nothing can be inside it — no list, no rescue. Do not
read an absent list as "anything is allowed"; that inverts the guard.

Replace succeeded_stories with the ones carrying a commit — verified by
the worker itself, or rescued above. A rescued story is a SUCCESS from
here on: it merges with the wave and reaches mark-complete like any
other, because its work is on its branch exactly as if the executor had
committed it. The rescue is reported so the human sees the diff someone
else committed; it is not tracked as a separate story state.

## Why merge-all runs from EXEC_ROOT

cd to this group's execution root before merging (see container-
execution.md's Execution Context: EXEC_ROOT, EXEC_BRANCH,
EXEC_OWNS_ROOT, EXEC_KEEPS_BRANCH) -- merge-all issues a bare
`git checkout <target-branch>` against whatever repo its CWD belongs
to, so running it from AIMI_ROOT in phase mode would check the phase
branch out onto the main working tree, violating the Main Working
Tree Untouched Invariant.

## Conflict cleanup keeps unmerged branches

Cleanup this wave's worktrees -- but ONLY the ones whose work
is already reachable from the merge target. merge_all_worktrees
processes its argv in order and stops at the first conflict
without attempting the rest, so a story from the conflicting
one onward has NOT been merged: removing it without
--keep-branch would run `git branch -D` on the only ref naming
its commits, stranding them. This is the same rule the
Phase-Mode Paired Split conflict path already applies to its
own members (see "Merge Split Branches Into the Phase Branch"),
and the two must not disagree about the same scenario.

## knownGaps extraction

When result_payload_by_id[full_story.id].knownGaps is a non-empty array,
use those entries (one line each). Otherwise, fall back to grepping
KNOWN-GAP trailers from the commit body for backward compat. Two spellings
are matched -- bare "KNOWN-GAP:" and "KNOWN-GAP (US-NNN):" with the story id
folded in -- because a worker legitimately writes either one, and a
single-spelling grep silently drops whichever it does not cover. Both stay
anchored to line start so a KNOWN-GAP mention inside a paragraph is never
extracted as if it were a trailer.

Absolute, never relative to the CWD: the merge above cd'd into
EXEC_ROOT, which in container and phase mode is the container,
and a relative .aimi/known-gaps would land inside it and be
deleted with it (it would also leave a stray .aimi/ there that
find_aimi_root stops at). AIMI_ROOT is this run's carried value,
never re-derived from the container's CWD.

Discriminated by PLAN_DISC, this run's own plan identity (see
`### Plan Discriminator` under Multi-Repo Handling) — two plans
that both produce a gap for the same story id on the same day
would otherwise compose the same path and silently truncate
each other's finding.

## Verify evidence

--- Extract verify evidence: the FOURTH result_json field this
command consumes, beside .commit, .failureCause and .knownGaps ---
The story-executor Result Contract carries `verify`
({exit, preExit, segments, discriminating}) — the count of verify
segments that behaved differently before the story's work than
after. Empty here is a real answer and a common one: an executor
whose payload predates that contract, a payload recovered by the
fallback parse rather than read as JSON, or a story whose verify
never ran. It is NOT the same as a zeroed evidence object, and the
call below is written so the two can never collapse into each other.

## Why the flagless mark-complete argv stays

Two reasons the flagless argv has to stay byte-identical rather than
gaining an always-passed empty flag. It is the argv the pre-existing
golden `mark-complete` recordings replay, so a flag that is always
present rewrites all of them for nothing. And an empty evidence object
would persist at `verification.evidence` as "we looked and found
nothing" — precisely the conflation this reporting exists to remove:
`tasks.py`'s `_report_discriminating` routes a missing count to
`unrecorded` and a real 0 to `blind`, and those are two different
statements about the same run.

## Visual verification modes

--- Post-merge visual verification origin rewrite / degradation gate ---
`group_key` is already in scope here from the enclosing "for
group_key, stories in succeeded_by_project" loop above — this
story's own project group. Discriminates on EXEC_OWNS_ROOT (see
container-execution.md's Execution Context: EXEC_ROOT,
EXEC_BRANCH, EXEC_OWNS_ROOT, EXEC_KEEPS_BRANCH) rather
than checking PHASE_MODE/CONTAINER_MODE separately at this top
level: false only for inline mode (no shared server exists to
rewrite against), true for both phase and container mode, which
keep their own distinct port-acquisition mechanisms below.

Inline mode — identical to today's inline branch: the
story's own verification.url, no rewrite, no gate.
verification-report already normalizes a non-string
url to the empty string, so no `// empty` is needed
here — see the closed jq -r non-string hazard note
above Container Dev Server Bootstrap.

EXEC_OWNS_ROOT is true for both phase and container mode.
PHASE_MODE is read here too, but only to pick between the
two modes' own distinct port-acquisition mechanisms — never
again as a top-level EXEC_ROOT/EXEC_BRANCH mode gate.

Apply container-execution.md's § Rewrite a Verification
URL Origin with EXEC_ROOT="$AIMI_ROOT", EXEC_BRANCH=
"$PHASE_BRANCH" — never a value cached from Phase/Split
Container Dev Server Bootstrap or Step 3.3 earlier in
this run. Inside a split sub-orchestrator, PHASE_BRANCH
is already that split's own branch (see Spawn Split
Sub-Orchestrators), so this applies unmodified one level
deeper too.

No dev server running for this phase's (or split's) own
branch. Degrade to skipped — this is also the expected,
non-bug outcome for a full-stack split story whose page
depends on the sibling split's API (no proxy exists between
the two split servers — see Split Container Dev Server
Bootstrap). mark-complete already ran above; this never
blocks it, never blocks the wave, and never retries.

CONTAINER_MODE — EXEC_OWNS_ROOT is true and PHASE_MODE is
false, so this is the only remaining case. Gates on the
Step 3.3 cache before applying container-execution.md's
§ Rewrite a Verification URL Origin, keyed by this story's
own project group.

No dev server ever resolved a port for this group (see Container
Dev Server Bootstrap in Step 3.3) — degrade to skipped. mark-complete
already ran above; this never blocks it or the wave loop.

## Non-visual verdicts

Non-visual stories: the verdict now comes from the verify evidence
mark-complete already persisted above (see VERIFY_EVIDENCE_JSON) —
a blanket rewrite to "passed" here claimed success whether or not
this story's own check ever ran, which is exactly the dishonesty
judge-verification exists to close. It is a safe no-op (writes
nothing, reports why) for a story already judged, so the pending
check below is an optimization, not a correctness requirement.

## Wave worktree removal

Remove all worktrees from this wave (per project group, EXEC_ROOT[wt.group_key]
— see container-execution.md's Execution Context: EXEC_ROOT, EXEC_BRANCH,
EXEC_OWNS_ROOT, EXEC_KEEPS_BRANCH). Branch deletion
here is unconditional in every mode (no --keep-branch) — container mode's
own teardown (outline:08) is the only removal call that preserves branchName.
