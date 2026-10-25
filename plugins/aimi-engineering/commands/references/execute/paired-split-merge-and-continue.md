# Execute: Phase-Mode Paired Split: Merge and Continue

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

### Aggregated Completion Report (Phase-Mode Paired Split)

Report — computed against `$PHASE_BRANCH`, never `$DEFAULT_BRANCH`. Exactly one block per **active** split file; a member skipped for having no pending stories contributes no block and no "0 stories completed" line anywhere:

```
## Execution Complete (Phase [PHASE_ID] — Split Mode)

For each active split file, one block:

[split_file]
  Project: [SPLIT_PROJECT]
  Branch: [SPLIT_BRANCH]
  Repo: [SPLIT_TOPLEVEL]
  Stories completed: [count from that member's Task result]
  Commits: git -C "[SPLIT_TOPLEVEL]" log --oneline [PHASE_BRANCH]..[SPLIT_BRANCH] | wc -l

Total stories: [sum of every active split file's completed count]
Total commits: [sum of every active split file's commit count]
```

Both `Total` lines are sums across **all** active split files, not two named Frontend/Backend slots. This report is computed **before** the merge below, while every split branch is still ahead of `$PHASE_BRANCH` — after the merge the same `git log` ranges would all read zero and the counts would no longer be informative.

`Commits` is read from that member's own resolved repository root — `SPLIT_TOPLEVEL`, straight from its own `SPLIT_PLAN` record — rather than the single `$PHASE_CONTAINER_PATH` scalar the single-repo case used to read: **Create Phase Containers Per Project Group** deliberately leaves that scalar unset once more than one repository participates (see that section's own note), so it is not a reliable read here for any N. `git log` only needs to run inside *some* worktree of the branch's own repository — unlike `merge-all`'s own checkout below, it does not need to be the specific worktree `$PHASE_BRANCH` is checked out in — so `SPLIT_TOPLEVEL` is sufficient here even in the cases where it is not the same path **Merge Split Branches Into the Phase Branch**'s own `merge-all` call requires.

### Merge Split Branches Into the Phase Branch

One `merge-all` call **per participating repository** — never one call listing every active split branch regardless of repo, and never a hardcoded two-call special case for the legacy pair. Active split members are grouped by the repository each one already resolved to in **Derive and Validate Split Branch Names** — `SPLIT_PLAN`'s own `toplevel` field, read as one JSON object per line per Step 0.9 Pass 1's rule (a tasks-file path may contain spaces) — never by a second detection mechanism, and never by repo *count*. Re-assign `SPLIT_PLAN` from that section's own printed stdout, pasted back verbatim (each Bash tool call is an isolated shell, Step 0):

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"; [ -x "$WORKTREE_MGR" ] || { echo "WORKTREE_MGR is stale: $WORKTREE_MGR does not exist — re-run check-version --quiet --fix" >&2; exit 1; }
SPLIT_PLAN=$(cat <<'SPLIT_PLAN_EOF'
[paste Derive and Validate Split Branch Names' printed SPLIT_PLAN here, verbatim — one JSON record per line]
SPLIT_PLAN_EOF
)

ALL_MEMBER_TOPLEVELS=""
while IFS= read -r member; do
  [ -n "$member" ] || continue
  ALL_MEMBER_TOPLEVELS="${ALL_MEMBER_TOPLEVELS}$(printf '%s' "$member" | jq -r '.toplevel')"$'\n'
done <<< "$SPLIT_PLAN"
MERGE_REPO_TOPLEVELS=$(printf '%s' "$ALL_MEMBER_TOPLEVELS" | grep -v '^$' | sort -u)

MERGE_CONFLICT_TOPLEVEL=""
MERGE_CONFLICT_ROOT=""
MERGE_CONFLICT_LABEL=""
while IFS= read -r REPO_TOPLEVEL; do
  [ -n "$REPO_TOPLEVEL" ] || continue

  set --
  REPO_PROJECTS=""
  while IFS= read -r member; do
    [ -n "$member" ] || continue
    MEMBER_TOPLEVEL=$(printf '%s' "$member" | jq -r '.toplevel')
    [ "$MEMBER_TOPLEVEL" = "$REPO_TOPLEVEL" ] || continue
    set -- "$@" "$(printf '%s' "$member" | jq -r '.branch')"
    REPO_PROJECTS="${REPO_PROJECTS}$(printf '%s' "$member" | jq -r '.project')"$'\n'
  done <<< "$SPLIT_PLAN"
  REPO_LABEL=$(printf '%s' "$REPO_PROJECTS" | grep -v '^$' | sort -u | tr '\n' ',' | sed 's/,$//')

  if [ "$#" -eq 0 ]; then
    echo "Internal error: repository $REPO_TOPLEVEL ($REPO_LABEL) was selected from SPLIT_PLAN's own distinct toplevels, so it cannot legitimately have zero branches -- the positional-parameter read that builds this repo's argv failed. Not merging (see the portability note below)." >&2
    exit 1
  fi

  MERGE_TARGET_ROOT="$REPO_TOPLEVEL/.worktrees/$PHASE_BRANCH"
  if [ ! -d "$MERGE_TARGET_ROOT" ] || [ ! -e "$MERGE_TARGET_ROOT/.git" ]; then
    MERGE_TARGET_ROOT="$REPO_TOPLEVEL"
  fi

  cd "$MERGE_TARGET_ROOT"
  if ! $WORKTREE_MGR merge-all "$@" --into "$PHASE_BRANCH"; then
    MERGE_CONFLICT_TOPLEVEL="$REPO_TOPLEVEL"
    MERGE_CONFLICT_ROOT="$MERGE_TARGET_ROOT"
    MERGE_CONFLICT_LABEL="$REPO_LABEL"
    break
  fi
done <<< "$MERGE_REPO_TOPLEVELS"

if [ -n "$MERGE_CONFLICT_TOPLEVEL" ]; then
  echo "MERGE_CONFLICT_TOPLEVEL=$MERGE_CONFLICT_TOPLEVEL"
  echo "MERGE_CONFLICT_ROOT=$MERGE_CONFLICT_ROOT"
  echo "MERGE_CONFLICT_LABEL=$MERGE_CONFLICT_LABEL"
  exit 1
fi
echo "Every repository's active split branches are merged onto its own \$PHASE_BRANCH."
```

Both loops are built exclusively with positional parameters (`set --`, `set -- "$@" "$x"`) and the `while IFS= read -r ... done <<<` pattern — **never bash 4's read-into-array builtin (`mapfile`/`readarray`), and never an associative array (`declare -A`)**, in either the outer per-repository grouping loop or the inner per-repository branch-list build. Neither exists in zsh, nor in the bash 3.2 that ships as `/bin/bash` on macOS; where either is missing, the read silently fails and produces an empty result. This story multiplies the number of argv builds from one to N, which multiplies this hazard by exactly as much — which is why the arity guard above treats `$# -eq 0` as a hard failure (stderr message, `exit 1`) rather than a silent `continue` to the next repository: `REPO_TOPLEVEL` on every iteration is drawn from `MERGE_REPO_TOPLEVELS`, itself derived only from toplevels that actually appear in `SPLIT_PLAN`, so a repository reached by the outer loop can never legitimately have zero members. An empty `$@` there is proof the inner read failed, never proof there was nothing to merge for that repository — verified under zsh: substituting either forbidden construct here makes the read fail silently, and without this hard-failure guard the block would exit 0 having merged nothing while every split branch stayed unmerged and the phase went on to report success.

**Why `MERGE_TARGET_ROOT` is not simply `$REPO_TOPLEVEL`.** `merge-all` issues a bare `git checkout "$PHASE_BRANCH"`, which fails outright when `$PHASE_BRANCH` is already checked out in a *different* worktree of the same repository — exactly the state **Create Phase Containers Per Project Group** already put every participating repository in during Step 1.7, before this section ever runs. With exactly one participating repository, `REPO_TOPLEVEL` already **is** that container (a linked worktree's own `git rev-parse --show-toplevel` returns its own path, not the main repo's — see container-execution.md's CWD For Every Worktree Operation section), so the existence check above falls through to `MERGE_TARGET_ROOT="$REPO_TOPLEVEL"` and reproduces today's `cd "$PHASE_CONTAINER_PATH"` byte-for-byte. In a genuine multi-repo split, `REPO_TOPLEVEL` is instead that sibling repository's own main root (the value **Derive and Validate Split Branch Names** resolves when `AIMI_ROOT_IS_GIT_REPO=false`), and its phase branch's own container is the child directory Create Phase Containers Per Project Group already created there — `<REPO_TOPLEVEL>/.worktrees/<PHASE_BRANCH>` — which the existence check above detects and uses instead.

**Sequential, not concurrent.** Every repository's `merge-all` call fully resolves — success or conflict — before the next repository's call starts, mirroring Step 4's own per-project-group merge loop ("MERGE PER PROJECT GROUP," `for group_key, stories in succeeded_by_project`), which already merges one project group at a time with no parallel dispatch. True concurrency here would need explicit job control (background processes plus `wait`), and its interleaved stdout/stderr would make a conflict report ambiguous about which repository it belongs to — for a negligible wall-clock gain, since every `git merge` here is a local, network-free operation. Concurrent per-repository merges are out of scope for this story.

This is the same `merge-all ... --into` primitive Step 4's own wave loop already uses for individual story branches, now issued once per repository for the split branches: each call's target is that repository's own `$PHASE_BRANCH`, executed with CWD inside that repository's own phase container — never `$DEFAULT_BRANCH`, never `AIMI_ROOT`, and never another repository's container. Centralizing every merge in this parent step (rather than having each sub-orchestrator merge into its own `$PHASE_BRANCH` mid-flight, from its own worktree) avoids N parallel Tasks racing a `git checkout`/`git merge` against the same working directory; running them here, after every Task has already returned, is what makes that safe by construction, for any number of repositories. This step is also what makes Phase Completion's Creates Verification (below) meaningful: it inspects a phase container's actual tracked files, which only reflect a repository's split work once that repository's own merge has landed.

**On merge conflict**, the block above exits non-zero having printed `MERGE_CONFLICT_TOPLEVEL`, `MERGE_CONFLICT_ROOT`, and `MERGE_CONFLICT_LABEL` — carry those three values forward into the next block by the same read-and-retype convention `$PHASE_BRANCH`/`$PHASE_ID` already use elsewhere in this file (each is a single-line string, not a multi-record blob, so no heredoc paste is needed). Classify the conflicting repository's own branches, gather every other repository's status, and clean up only what is confirmed merged:

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"; [ -x "$WORKTREE_MGR" ] || { echo "WORKTREE_MGR is stale: $WORKTREE_MGR does not exist — re-run check-version --quiet --fix" >&2; exit 1; }
SPLIT_PLAN=$(cat <<'SPLIT_PLAN_EOF'
[paste Derive and Validate Split Branch Names' printed SPLIT_PLAN here, verbatim — one JSON record per line]
SPLIT_PLAN_EOF
)
MERGE_CONFLICT_TOPLEVEL="[from the merge block's own stdout above]"
MERGE_CONFLICT_ROOT="[from the merge block's own stdout above]"
MERGE_CONFLICT_LABEL="[from the merge block's own stdout above]"

ALL_MEMBER_TOPLEVELS=""
while IFS= read -r member; do
  [ -n "$member" ] || continue
  ALL_MEMBER_TOPLEVELS="${ALL_MEMBER_TOPLEVELS}$(printf '%s' "$member" | jq -r '.toplevel')"$'\n'
done <<< "$SPLIT_PLAN"
MERGE_REPO_TOPLEVELS=$(printf '%s' "$ALL_MEMBER_TOPLEVELS" | grep -v '^$' | sort -u)

CONFLICT_LINE=$(printf '%s\n' "$MERGE_REPO_TOPLEVELS" | grep -nxF "$MERGE_CONFLICT_TOPLEVEL" | head -1 | cut -d: -f1)
PROCESSED_TOPLEVELS=$(printf '%s\n' "$MERGE_REPO_TOPLEVELS" | head -n "$((CONFLICT_LINE - 1))")
REMAINING_TOPLEVELS=$(printf '%s\n' "$MERGE_REPO_TOPLEVELS" | tail -n "+$((CONFLICT_LINE + 1))")

set --
while IFS= read -r member; do
  [ -n "$member" ] || continue
  MEMBER_TOPLEVEL=$(printf '%s' "$member" | jq -r '.toplevel')
  [ "$MEMBER_TOPLEVEL" = "$MERGE_CONFLICT_TOPLEVEL" ] || continue
  set -- "$@" "$(printf '%s' "$member" | jq -r '.branch')"
done <<< "$SPLIT_PLAN"

CONFLICT_MERGED=""
CONFLICT_UNMERGED=""
for split_branch in "$@"; do
  if git -C "$MERGE_CONFLICT_ROOT" merge-base --is-ancestor "$split_branch" "$PHASE_BRANCH" 2>/dev/null; then
    CONFLICT_MERGED="${CONFLICT_MERGED}${split_branch}"$'\n'
  else
    CONFLICT_UNMERGED="${CONFLICT_UNMERGED}${split_branch}"$'\n'
  fi
done

echo "Conflicting repository: $MERGE_CONFLICT_LABEL ($MERGE_CONFLICT_TOPLEVEL)"
echo "Already merged onto $PHASE_BRANCH: $(printf '%s' "$CONFLICT_MERGED" | grep -v '^$' | tr '\n' ' ')"
echo "Not yet merged: $(printf '%s' "$CONFLICT_UNMERGED" | grep -v '^$' | tr '\n' ' ')"
echo "Already-merged sibling repositories, not rolled back:"
printf '%s\n' "$PROCESSED_TOPLEVELS" | grep -v '^$'
echo "Untouched-this-run repositories, still pending:"
printf '%s\n' "$REMAINING_TOPLEVELS" | grep -v '^$'

while IFS= read -r REPO_TOPLEVEL; do
  [ -n "$REPO_TOPLEVEL" ] || continue
  cd "$REPO_TOPLEVEL"
  while IFS= read -r member; do
    [ -n "$member" ] || continue
    MEMBER_TOPLEVEL=$(printf '%s' "$member" | jq -r '.toplevel')
    [ "$MEMBER_TOPLEVEL" = "$REPO_TOPLEVEL" ] || continue
    MEMBER_BRANCH=$(printf '%s' "$member" | jq -r '.branch')
    $WORKTREE_MGR serve stop "$MEMBER_BRANCH"
    $WORKTREE_MGR remove "$MEMBER_BRANCH"
  done <<< "$SPLIT_PLAN"
done <<< "$PROCESSED_TOPLEVELS"

cd "$MERGE_CONFLICT_TOPLEVEL"
while IFS= read -r split_branch; do
  [ -n "$split_branch" ] || continue
  $WORKTREE_MGR serve stop "$split_branch"
  $WORKTREE_MGR remove "$split_branch"
done <<< "$CONFLICT_MERGED"
```

`git -C "$MERGE_CONFLICT_ROOT" merge-base --is-ancestor` recovers exactly what `merge_all_worktrees` did and did not reach: it processes its argv strictly in order and exits on the first conflict without attempting the rest (`worktree-manager.sh:684-689`), so every branch before the conflicting one is already an ancestor of `$PHASE_BRANCH` and every branch from the conflicting one onward is not. Cleanup above stops the dev server for, and removes with branch deletion, only what that check (plus every already-fully-merged sibling repository) confirms is merged — `$MERGE_CONFLICT_TOPLEVEL`'s own unmerged branches (the conflicted one, and anything after it merge-all never attempted) keep both their worktree and their branch ref, so the retry below has something to retry; deleting them would strand their commits with no ref left to name them by. Cleanup runs with CWD at each repository's own `.toplevel` (the same root **Create Split Worktrees** used to create these exact worktrees), never at that repository's phase-branch container: `$WORKTREE_MGR remove`/`serve stop` resolve their target from `$(git rev-parse --show-toplevel)/.worktrees/<name>` computed from CWD (`worktree-manager.sh`'s own `GIT_ROOT`/`WORKTREE_DIR`), and the phase-branch container is a *different* path from `.toplevel` in a genuine multi-repo split (see `MERGE_TARGET_ROOT` above) — using it here would make `remove` silently report the worktree "not found" instead of actually removing it.

Report:

```
MERGE CONFLICT while merging phase [PHASE_ID]'s split branches into [PHASE_BRANCH].

Repository: [MERGE_CONFLICT_LABEL] ([MERGE_CONFLICT_TOPLEVEL])
  Already merged onto [PHASE_BRANCH]: [CONFLICT_MERGED, one per line, or "none"]
  Not yet merged: [CONFLICT_UNMERGED, one per line — the conflicted branch first]
Conflicting files:
[conflict output from merge-all]

Other repositories in this split:
  Already merged, not rolled back: [PROCESSED_TOPLEVELS, each with its own branch list, or "none"]
  Untouched this run, still pending: [REMAINING_TOPLEVELS, each with its own branch list, or "none"]

Resolve the conflict on branch [PHASE_BRANCH] in [MERGE_CONFLICT_ROOT] and re-run
`/aimi:execute` to continue. Every split file's stories are already marked complete —
re-running will not re-execute any of them. It re-issues every repository's own
merge-all call in full, including the repositories already merged above: that is
safe because `git merge` is idempotent for a branch already merged ("Already up to
date", exit 0), whether this run merged it moments ago or a human resolved
[MERGE_CONFLICT_LABEL]'s conflict by hand inside [MERGE_CONFLICT_ROOT] first.

Every already-merged repository's own [PHASE_BRANCH] — and any live dev server
running inside its container — is left untouched by this failure; those repositories'
merges are not rolled back, only not-yet-attempted ones are still pending.
[MERGE_CONFLICT_LABEL]'s own not-yet-merged branches — worktree and branch ref both
— are left in place too, so the retry above has something to retry.
```

Exactly one claim release, since the claim is phase-scoped rather than per-repository — release it once regardless of how many repositories have or have not merged — then STOP, mirroring both Release the Claim on Abort and Step 4's own per-project-group conflict STOP:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
```

### Clean Up Split Worktrees

Only reached once **every** repository's `merge-all` call above has succeeded. Iterates per repository — stopping each split's own dev server, then removing its worktree — never a single flat loop over every active split branch with CWD fixed at one repository's path:

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"; [ -x "$WORKTREE_MGR" ] || { echo "WORKTREE_MGR is stale: $WORKTREE_MGR does not exist — re-run check-version --quiet --fix" >&2; exit 1; }
SPLIT_PLAN=$(cat <<'SPLIT_PLAN_EOF'
[paste Derive and Validate Split Branch Names' printed SPLIT_PLAN here, verbatim — one JSON record per line]
SPLIT_PLAN_EOF
)

ALL_MEMBER_TOPLEVELS=""
while IFS= read -r member; do
  [ -n "$member" ] || continue
  ALL_MEMBER_TOPLEVELS="${ALL_MEMBER_TOPLEVELS}$(printf '%s' "$member" | jq -r '.toplevel')"$'\n'
done <<< "$SPLIT_PLAN"
CLEANUP_REPO_TOPLEVELS=$(printf '%s' "$ALL_MEMBER_TOPLEVELS" | grep -v '^$' | sort -u)

while IFS= read -r REPO_TOPLEVEL; do
  [ -n "$REPO_TOPLEVEL" ] || continue
  cd "$REPO_TOPLEVEL"
  while IFS= read -r member; do
    [ -n "$member" ] || continue
    MEMBER_TOPLEVEL=$(printf '%s' "$member" | jq -r '.toplevel')
    [ "$MEMBER_TOPLEVEL" = "$REPO_TOPLEVEL" ] || continue
    MEMBER_BRANCH=$(printf '%s' "$member" | jq -r '.branch')
    $WORKTREE_MGR serve stop "$MEMBER_BRANCH"
    $WORKTREE_MGR remove "$MEMBER_BRANCH"
  done <<< "$SPLIT_PLAN"
done <<< "$CLEANUP_REPO_TOPLEVELS"
```

CWD for each repository is that repository's own `.toplevel` — the same root **Create Split Worktrees** used to create these exact worktrees (`$PHASE_CONTAINER_PATH` itself in today's single-repo case, since `.toplevel` and the phase container coincide there; a sibling repository's own main root in a genuine multi-repo split) — never a repository's phase-branch container, for the same CWD-resolution reason **Merge Split Branches Into the Phase Branch** documents above. `serve stop` exits 0 and reports "No dev server registered" when no server was ever started for a split (its own gate in Split Container Dev Server Bootstrap never passed) — so every call above is always safe to issue, identical to container-execution.md's Container Mode: Stop the Dev Server contract (invoked from Step 5).

Removes only the split worktrees this run created. Every repository's own phase-branch container is left intact — its removal is a separate, later-timed operation owned entirely by Phase Completion's own lifecycle (a phase container is only ever torn down once the *phase* — not just this split — is fully done), never by this section.

**Why no `--keep-branch` here, unlike Step 0.9's Aggregated Completion (Split Mode).** The flat flow passes `--keep-branch` when it cleans up *its* split worktrees; this section deliberately does not, so `remove` also runs `git branch -D` on each split branch. The difference is what the branch still owes: a flat split branch is the run's final deliverable that the user is told to open a PR from, whereas a phase split branch is an intermediate that Merge Split Branches Into the Phase Branch — which this section only runs *after every repository's own call has succeeded* — has already merged into that repository's own `$PHASE_BRANCH`. Its commits are reachable from that repository's phase branch, so the branch ref itself has no remaining consumer and keeping it would only accumulate one dead ref per member per phase, per repository. Each repository's own `$PHASE_BRANCH` is what carries that repository's work forward from here, and nothing here deletes it.

### Continue to Phase Completion

Proceed to the **Phase Completion** section below with `PHASE_SPLIT_MODE=true` and `$PHASE_SPLIT_FILES` still in scope. Its "phase's own pending count is zero" gate and Creates Verification step both branch on `PHASE_SPLIT_MODE` — see **Multi-File Pending Count** in Phase Completion, which sums over every member of `$PHASE_SPLIT_FILES`, not a fixed pair. Once Phase Completion (if it ran) has produced its own report, the **Aggregated Completion Report** above is what replaces this file's normal Step 5 — do not additionally run Step 5's single-file reporting for any split file.
