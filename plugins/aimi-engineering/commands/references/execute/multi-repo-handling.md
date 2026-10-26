# Execute: Multi-Repo Handling

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

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

Two shell consumers embed it: Step 1.5's **Detect Git Repo Layout** (which echoes the value so the agent can read it) and the phase container's **Unsupported Combination Guard: Phase Mode + Multi-Repo**. Every other consumer below — Step 2's container/branch-setup skips, Step 4's per-group commit counting — is an agent-level branch that references this rule by name and reads the value Step 1.5 echoed; no shell is involved, so none of them needs its own derivation.

When **true**, AIMI_ROOT is itself a git repository — all inline logic (default-branch detection, fetch, branch setup, worktree creation) runs directly against AIMI_ROOT. When **false**, this is a **multi-repo layout**: Claude Code runs from a parent folder containing multiple git repos as subfolders. In this layout:

- Default-branch detection and `git fetch origin` are skipped at the AIMI_ROOT level and happen per-project instead.
- Step 1.6 (Branch Base Selection) has no repository at AIMI_ROOT to select a base for, so it never fires there — but base selection itself is not skipped: it happens once per project group, inside Step 2's Per-Project Branch Setup, where each group calls `resolve-base-branch --project [resolved_project_path]` against its own checked-out repo and prompts (picker) or logs (agent) independently, exactly as Step 1.6 does for a single repo.
- Step 2 "Main Repo Branch Setup" is skipped entirely; all branch setup is handled per-project.
- All stories must carry a `project` field (the per-project path).

### Per-Story Project-Grouping Pattern

Stories are grouped by their `project` field:

- Stories with a non-null `project` field are routed to `AIMI_ROOT / story.project` (resolved to an absolute path).
- Stories without a `project` field (null/absent) form the DEFAULT group, routed to the current working directory (CWD).

**Path validation rules:** `project` field values must match `^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$`. No leading `./` and no `..` path components are allowed.

Each project group operates independently: its own default-branch detection, `git fetch origin`, branch setup, worktree creation, merge, and cleanup all run against that project's git root.

### Plan Discriminator

`PLAN_DISC` is this run's own plan identity, and it is what makes a story worktree name unique across PLANS rather than only across stories. Story ids restart at `US-001` in every plan, `branchName` is chosen by the plan author and is routinely reused, and `.aimi/tasks/` is shared — so two runs over two different tasks files that happen to share one `branchName` compose the same worktree name for their own `US-001` and are handed the same tree. Step 4's base-sha check does not catch that: it deliberately ACCEPTS a reused tree that is AHEAD of its base, so a story which committed and then failed can be re-run, and the other plan's leftover tree sitting on a base branch that has not moved IS a descendant of `base_sha` — the guard passes, the story runs on the other plan's commits, and the only thing printed is `Worktree already exists at:`, which is indistinguishable from a legitimate same-plan resume. Prefixing the name with the plan's own identity makes that collision impossible instead of merely detectable; widening the guard would require it to know which plan a tree belongs to, which is precisely the identity added here. The same root cause has a louder second symptom this closes at the same time: when the base branch HAS moved, the same stale tree fails the descendancy check and the story is mark-failed and cascade-skipped with `Worktree base ... does not descend from ...`.

The identity is the **tasks file's own stem** — the basename of the file Step 4 resolves as `WAVE_TASKS_FILE`, minus `.json`. Nothing is invented: that stem is already dated and slugged per plan, which is exactly why `probe_verify()` in `scripts/tasks.py` keys its artifact names to the same stem and says so in its docstring. Derive it inside the Bash call that needs it — every Bash call is an isolated shell, so the `echo` on the last line is functional and not decorative: a value that is not printed does not reach the orchestrator.

The stem is **sanitized**, and the sanitization is load-bearing rather than defensive. `worktree-manager.sh`'s `validate_branch_name` accepts only `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$` and `create` runs it on the composed worktree name, so a single DOT refuses the whole create — and decimal-phase tasks files exist in this repository today (`.aimi/archive/forge-abstraction-phase-1.1-tasks.json` and its `-phase-1.2-` sibling), whose raw stems carry that dot. Unsanitized, every story of every decimal phase would fail, and fail MISATTRIBUTED: Step 4's missing-sentinel branch would report `Worktree create emitted no WORKTREE_PATH/WORKTREE_BASE sentinel (worktree-manager.sh too old?)`, blaming the tool instead of the name it was handed. `probe_verify()`'s precedent needs no such step because it names a FILE, where a dot is legal; a git ref under this validator is the narrower namespace, and that is the one place the precedent does not transfer intact.

```bash
WAVE_TASKS_FILE="[the tasks file this run resolved — see Step 4]"
PLAN_DISC=$(basename "$WAVE_TASKS_FILE" .json | sed 's/[^A-Za-z0-9_-]/-/g')
case "$PLAN_DISC" in [A-Za-z0-9]*) ;; *) PLAN_DISC="p$PLAN_DISC" ;; esac
echo "PLAN_DISC=$PLAN_DISC"
```

The `case` guard prepends `p` when the sanitized stem would not start alphanumerically — the validator refuses a leading `-` or `_` as firmly as it refuses a dot. `basename`, `sed` and `case` are POSIX, so the block behaves identically whether the session's shell is bash or zsh, and both variables it reads are assigned inside it.

`PLAN_DISC` is a **PREFIX** and the story id stays LAST: the composed name is `[PLAN_DISC]-[branchName]-[story.id]` in flat and container mode, `[PLAN_DISC]-[PHASE_BRANCH]-[story.id]` in phase mode. The suffix position of the id is a hard external constraint rather than a preference — `${CLAUDE_PLUGIN_ROOT}/skills/story-executor/SKILL.md` requires in two places that the branch a story executor finds checked out END in `-<STORY_ID>`, and classifies a mismatch as a refusal to stage or commit. Appending the discriminator after the id would break both at once, silently, at the moment an executor refuses to commit finished work.

`PLAN_DISC` governs one more shared namespace, and that one is not a git namespace at all: the **scratchpad directory**. Every agent in a session is handed the same scratchpad path, and it outlives the session — it is shared across runs and therefore across PLANS, so a filename chosen for what it MEANS rather than for who owns it is a filename two writers pick independently. Measured in the 2026-09-08 known-gap `orq-scratchpad-compartilhado-entre-executores`: two of five executors in one wave ran a sibling's file believing it was their own, and this orchestrator was itself one of the writers — it left a `v.sh` in that same directory. A rule that reaches only the spawned executors would leave the polluter out, so it reaches here too: **every file this orchestrator writes into the scratchpad is named `[PLAN_DISC]-orch-<whatever>`.** The executors' half of the same rule is `SCRATCH_PREFIX`, composed in Step 4's spawn block below and carried into `${CLAUDE_PLUGIN_ROOT}/skills/story-executor/SKILL.md`'s `<task_pointer>`.

Every cleanup sweep in this document scans the prefixed pattern, because no placement of a discriminator preserves the old glob — measured in both directions, `feat/a-STEM-US-001` and `STEM-feat/a-US-001` both fail `feat/a-US-*`. The un-prefixed shape is legacy and keeps exactly one home: the legacy pass beside Post-Loop Cleanup's phase/container sweep, for the `EXEC_BRANCH` shape inside a container. The flat-mode sweep of `project_root` for that shape was retired in 1.151.1, as its own removal marker scheduled.

`PLAN_DISC` governs a THIRD shared namespace, after the worktree name and the scratchpad directory above: **`.aimi/known-gaps/`**, one flat directory shared by every plan. A known-gap file is named `${GAP_DATE}-[full_story.id]-[PLAN_DISC].md` (Step 4, mark-stories-complete) for the identical reason the other two are prefixed/suffixed — story ids restart at `US-001` in every plan, so `<date>-<story.id>.md` is a path two plans compose identically on the same day, and the writer is a plain `>` redirect that truncates whichever run loses the race with no error and no trace. Measured at 3b871aa on 2026-09-10: 33 of the 121 `.md` files already under `.aimi/known-gaps/` carry the collidable `<YYYY-MM-DD>-US-NNN.md` shape. The same defect was fixed once already, on a sibling artifact, in exactly this way: `.aimi/known-gaps/2026-09-07-US-002-nome-do-probe-colide-entre-planos.md` records `verify-probe`'s own artifact colliding the same way in `.aimi/tasks/`, fixed by keying the name on the tasks file's own stem — `probe_verify()` in `scripts/tasks.py` does exactly that, and this reuses the same identity rather than inventing a second scheme.

Unlike the worktree case, the discriminator here is a **SUFFIX**, and a parser forces the inversion rather than a preference choosing it. `_GAP_FILENAME` in `scripts/tasks.py` anchors `date` at position 0 and an optional `US-NNN` immediately after it — prefixing `PLAN_DISC` would leave both `date` and `story` null, and every `--since` call drops an entry whose date is null. Appended, the stem lands in the pattern's optional `slug` group instead, where `known_gap_entries()` believes a slug only when it names a feature that already exists; a tasks-file stem is never a feature name, so the entry falls through to the same date index a slug-less name already falls through to today, and the attribution every entry already gets is unchanged. No existing file under `.aimi/known-gaps/` is renamed by this — `<date>-US-NNN-<feature>.md` admits one file per story, date and feature, so renaming two same-day gaps for one story id onto that shape would collide on the rename itself and lose one of them.

### Per-Project Cleanup Rule

After each wave (and in Post-Loop safety cleanup), for each unique `project_root` (including CWD for the DEFAULT group):

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"; [ -x "$WORKTREE_MGR" ] || { echo "WORKTREE_MGR is stale: $WORKTREE_MGR does not exist — re-run check-version --quiet --fix" >&2; exit 1; }
cd [project_root]
$WORKTREE_MGR list
# For each worktree matching "[PLAN_DISC]-[branchName]-US-*":
$WORKTREE_MGR remove [worktree_name]
```

This rule is unchanged apart from the plan discriminator now leading the pattern, and does not apply in phase mode — see `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Phase Mode: Worktree Naming and CWD, which supersedes `project_root` with that claimed phase's own container and branch for the duration of its execution — one phase container and one phase branch per participating repository, never a single pair for the whole phase regardless of how many repositories it spans — nor does it apply, in the same way, to container mode (`PHASE_MODE=false`, `CONTAINER_MODE=true`; see Execution Mode Detection in Step 1), which supersedes `project_root` with `CONTAINER_PATHS[group_key]` for the duration of that project group's container-mode execution. See that same reference's Execution Context: EXEC_ROOT, EXEC_BRANCH, EXEC_OWNS_ROOT, EXEC_KEEPS_BRANCH subsection for the contract that replaces this per-consumer branching.

### Container Paths Per Project Group (Container Mode)

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Container Paths Per Project Group — defines `CONTAINER_PATHS[group_key]`, populated by Step 2's Flat Container Mode / Per-Project Branch Setup and consumed by Step 4's wave loop and both cleanup passes via `EXEC_ROOT`/`EXEC_BRANCH`.

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Phase Mode: Worktree Naming and CWD — the single source of truth for how `PHASE_MODE=true` and `CONTAINER_MODE=true` each change worktree naming, CWD, and the `EXEC_ROOT`/`EXEC_BRANCH`/`EXEC_OWNS_ROOT`/`EXEC_KEEPS_BRANCH` execution context that Step 4's wave loop, its cleanup passes, and the post-merge visual-verification origin rewrite all consume. When both modes are false (inline, the default), every rule there reduces to exactly today's flat-mode behavior — no new variable is read, no new conditional branch is taken.

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/container-execution.md` § Create or Reuse a Container and § Bootstrap a Container Dev Server — the shared mechanisms every container, phase-container, and split-container creation and dev-server bootstrap call site below delegates to.

---
