# Story Executor — why the brief says what it says

Plugin development notes for `skills/story-executor/SKILL.md`. The skill is the brief
every spawned story worker reads, so it states rules and keeps only the reason a worker
needs to apply them. The history behind those rules lives here. Read this before you
loosen, shorten or "tidy" a rule in the skill: most of them exist because the looser
version failed once.

## One brief, read by the worker

The skill used to carry two copies of the worker prompt: a full Prompt Template for the
first story of a session and a Compact Template for the rest. The orchestrator pasted
one of them into each spawn. Measured over 178 executor runs, 65% of workers then read
the 68 KB skill again on their own, and the other 35% worked from whatever the
orchestrator pasted, which was often a paraphrase. The compact copy had also drifted:
it left out the `implementation.guardRails` labelling, the "never stage or commit" rule
for `implementation.outputs` and the fail-fast on a failed commit, and it pointed at a
"step 1.5 above" its readers never received.

So the orchestrator now passes a short pointer prompt with the values, and the worker
reads the skill itself, once. There is one copy of every rule, and the worker always
reads the same text.

## Why `SCRATCH_PREFIX` is handed over composed

**`SCRATCH_PREFIX` is your scratchpad namespace and it arrives already composed: EVERY file you write into the scratchpad directory is named `[SCRATCH_PREFIX]-<whatever>`.** This is a prefix you are HANDED, never an invitation to pick a name you judge unique — picking a good name is precisely what failed. `verify.sh`, `verify.log`, `probe.sh`, `probe.err` and `v.sh` are real names that already collided in that directory, each one chosen by an agent who believed it was theirs; treat all five as non-examples rather than as a list to avoid and then improvise around. The scratchpad is shared with every sibling executor of this wave, with the orchestrator, and with every run that used it before yours, so before executing a script you believe you wrote, confirm the path you are running is the one you wrote. `SCRATCH_PREFIX` leads with the PLAN's identity and ends with your story id because the collision that was measured crossed PLANS rather than siblings: the file read by mistake belonged to an earlier plan's run whose story carried the same `US-NNN`, so a prefix keyed on the story id alone would have composed the same name twice. This rule does NOT reach the `verify-probe` artifact — that file lands beside the tasks file under a name the verb itself chooses and announces on stderr, and step 1.5 below tells you to read that path rather than compose one.

## The working-directory rule (issue #105)

Getting this wrong is issue #105: a monorepo story ran from the repository root while its `implementation.verify` was written for the project directory, so a bare `bun run typecheck` failed for want of a `package.json` one level down. The fix belongs here, in the cd — never in what a story author writes. A `verify` must not carry a `cd <project> &&` prefix; by the time it runs you are already there.

## Why a failed `cd` into the worktree stops the story

**When WORKTREE_PATH is set and that cd FAILS, stop and report — never fall through to whatever directory you happen to be in.** Until now this step had no failure branch at all for the worktree path, which is what made the bad outcome silent rather than loud. There is nothing to recover here and nowhere safe to continue from: the directory the orchestrator named does not exist or cannot be entered, so the CWD you are still holding belongs to someone else's tree — the orchestrator's own checkout, or a sibling story's worktree. Carrying on writes this story's commit into that tree, and the damage is invisible from both ends: the tasks file records a green story while the branch that was supposed to carry it stays empty, and a second story's branch acquires a change nobody wrote for it. Emit `<result_json>` with `"status":"failed"`, `"commit": null`, and a `failureCause` naming the exact path that could not be entered.

## The pre-run of `implementation.verify`

1.5. **Pre-run `story.implementation.verify` once, before implementing anything, and record the result.** Skip this step entirely when `implementation.verify` is absent or empty — it does not run and warns nothing, the same treatment step 4 gives the absent case (`implementation{}` is optional in schema v3.3). When present, run it exactly as written, from the working directory established in step 0c, with `TASKS_FILE_PATH` and `AIMI_ROOT` (exactly the value you were handed — never re-derived here, a worktree has no `.aimi/`) exported into its environment — a `verify` that needs its own tasks file (e.g. to read `metadata.baseRef`) can then resolve it directly rather than falling back to the shared `current-tasks` pointer a sibling split orchestrator's `init-session` may have since overwritten, and one that reads `"$AIMI_ROOT/.aimi/..."` finds it. If this pre-run exits ZERO — the verify already passes before any work exists — emit a warning, carried in the completion report, that the check does not discriminate the before-state from the after-state: a verify that passes both before and after proves nothing about what was done. This warning NEVER blocks, in any mode. Name its legitimate cause rather than accusing the verify of being broken: a story re-executed over partial work already done can genuinely pass this early run with nothing wrong — a warning that accuses wrongly gets ignored the third time it fires. Running the verify twice per story is a deliberate trade-off, accepted on purpose even though it doubles the run time of a story whose verify is a long suite: a verify that always passes reports success, and discovering that later costs more than the second run.

## Why the probing CLI is chosen and announced

**Choose the CLI that will do the probing before probing with it, and announce which one you chose.** Set `PROBE_TREE_CLI="$PWD/plugins/aimi-engineering/scripts/aimi-cli.sh"` — `$PWD` is the working directory step 0c established, and the path has to be absolute because `aimi-cli.sh` invoked by a relative path resolves its sibling Python modules against the directory it lands in after `find_aimi_root`, and can load another checkout's. When `[ -x "$PROBE_TREE_CLI" ]` — `-x`, never `-f` or `-e`, the same test `commands/execute.md`'s Creates Verification applies to its own container CLI, because a file that is present but not executable probes nothing — set `PROBE_CLI="$PROBE_TREE_CLI"` and print `probe-cli: $STORY_ID: probing with the aimi-cli.sh of the tree under test ($PROBE_TREE_CLI)` on stderr. Otherwise set `PROBE_CLI="$AIMI_CLI"` and print `probe-cli: $STORY_ID: no executable aimi-cli.sh in the tree under test ($PROBE_TREE_CLI) -- probing with the resolved CLI ($AIMI_CLI) instead`. **BOTH branches print** — a deliberate divergence from that precedent, which prints only on the fallback: there the silent branch is the rare one, here the tree under test is the COMMON case, so a silent preferred branch would hide precisely what this exists to show. On a feature branch the installed CLI is OLDER than the branch's own, and an old parser accepts an unknown flag in silence — so with no instrument named, two contradictory findings about the same flag are indistinguishable from each other. The prefix is `probe-cli: ` and not `verify-probe: ` because the verb itself writes `verify-probe: wrote <path>` to this same stream and you have to read that path back out of it; two producers under one prefix is confusion bought for nothing. **The preference is per-call and is NEVER persisted:** write it into no cli-path cache and teach no resolution layer about it. `write_global_cli_cache` and `_dev_dir_path` each refuse a path under `.worktrees/` on purpose, after a symlink bug that exited 127 — this stderr line is the substitute for persisting, not a complement to it.

## Why `implementation.approach` has a reader

Why this field has a reader at all, since the record says otherwise: audit finding #4 observed that `implementation.approach` had no reader in the executor and concluded it should be retired. That observation was right and the conclusion was wrong, and measurement is what inverted it. As of 2026-09-03, **nine** files across `agents/`, `commands/`, `skills/` and `scripts/` read or write the field — `aimi-cross-story-auditor.md`, `aimi-story-expander.md`, `deepen.md`, `execute.md`, `next.md`, `plan.md`, `story_merge.py`, `architecture-foundation/SKILL.md`, `typescript-node-conventions/SKILL.md` (`deepen.md` is the one that does not match a literal `implementation.approach` grep — it writes `approach` as a key under `implementation`). `/aimi:deepen` writes it, `next.md` renders it to the user, and four of the cross-story auditor's six concerns derive from it. The executor was the single place with no reader; retiring the field would have silently disabled the other nine to fix that one. So the missing reader was added instead — this step. Anyone re-reading finding #4 will reach the retire conclusion again unless they read this paragraph first.

## The branch check before staging

4.5. **When WORKTREE_PATH is set, confirm the checked-out branch is THIS story's before staging anything.** Run `git branch --show-current` and require the name to END in this story's id (`-<STORY_ID>` — e.g. a branch ending `-US-003` for story US-003). On a mismatch, stop: do NOT stage, do NOT commit, and report failure with both the branch actually found and the id expected. A worktree whose branch is not this story's is a worktree this story was never handed, and committing into it puts one story's work onto another story's branch — where the wave that merges them interleaves two unrelated changes with nothing marking the seam. This is the last moment at which that stays cheap to catch: once the commit lands, undoing it means rewriting a branch that belongs to someone else.

## What `notes` holds

The brief used to say that `story.notes` "carries notes from earlier attempts at this story". A first run never has an earlier attempt: `list-ready` selects only `pending` stories, so a story reaches a worker with whatever the plan wrote. The writers of the field, as of 1.158.1:

- `aimi-story-expander` writes it as residue: what no other field carries, planning measurements included (`agents/workflow/aimi-story-expander.md`).
- `/aimi:deepen` adds research file paths, patterns, gotchas, rule-id annotations and open questions, appending to what is there (`commands/deepen.md`).
- `apply-audit-patches` adds or replaces whole paragraphs, separated by `NOTES_SEPARATOR` (`\n\n---\n\n`), and `--annotate-deferred` appends `[audit-deferred: …]` paragraphs (`scripts/audit_patches.py`).
- `mark-failed`, `reset-orphaned` and `cascade-skip` replace the whole field with the cause they record (`scripts/tasks.py`), so a story set back to `pending` by hand reaches its next worker with that cause in place of the plan's notes.

`story-merge`'s `stale-sibling-note` smell exists because a paragraph before the last separator can cite a sibling as it stood before the audit (`docs/dev/planning-verbs.md` § Advisory smells), which is why the brief says the criteria and `implementation` win over `notes`.
