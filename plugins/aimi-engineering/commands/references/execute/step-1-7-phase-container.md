# Execute: Step 1.7: Phase Container

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

### Create or Reuse the Phase Container

#### Unsupported Combination Guard: Phase Mode + Multi-Repo

**This guard runs first — before the `cd "$AIMI_ROOT"` below, before any `$WORKTREE_MGR create`, and before any split detection.** Every phase-mode container and worktree in this file is created downstream of this point: the phase container itself, and every split worktree **Phase-Mode Paired Split** later nests inside it. One check here therefore covers all of them, including the case where a project split converges to a single distinct project (`story-merge`'s SIDE axis, by design) and lands as a two-file frontend/backend split under a root that is not a repository.

`AIMI_ROOT_IS_GIT_REPO` is re-derived here rather than carried over from Step 1.5's **Detect Git Repo Layout** — each Bash call is an isolated shell, so the canonical derivation from the **AIMI_ROOT_IS_GIT_REPO Branching Rule** (Multi-Repo Handling) is embedded verbatim below, `AIMI_ROOT` walk included. When the value is **true**, the guard passes trivially. When the value is **false**, `AIMI_ROOT` is a plain parent folder holding one git repository per subfolder, not a repository itself — but that no longer makes every non-git-root phase unroutable: **Create Phase Containers Per Project Group** below resolves each participating repository independently from its own `project` field, so a phase whose stories are properly project-tagged (or whose own directory holds a routable project-marked split) has somewhere to route every group and needs no refusal here. What remains genuinely unroutable is narrower: a story with no `project` field resolves to the root group (`.`), and there is no repository under `.` to execute in when `AIMI_ROOT` itself is not one — `cd` there followed by `$WORKTREE_MGR create` would exit **128** with a bare `fatal: not a git repository` (nothing is created, so no state is corrupted — but the message names neither the phase, nor the layout, nor the fix). That opaque failure is issue #73. The two checks below narrow refusal to exactly that residue: read-only reconnaissance via `$AIMI_CLI split-detect` (consuming its `degradedReason` rather than re-deriving the legacy-pair/marker resolution logic inline — that logic lives in `aimi-cli.sh` alone), then, only when `split-detect` did not already name the condition, a single count against this phase's own governing tasks file.

The decision and its consequence live in the same block: the claim release (see **Release the Claim on Abort** — this session ran Step 1.7's **Claim the Phase** itself, so `$PHASE_ID` is set and this call is the top-level orchestrator's to make) runs inside the failing branch, so a routable layout (single-repo, or a properly project-tagged multi-repo phase) never touches it and an unroutable one can never skip it.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
AIMI_ROOT="$PWD"
while [ "$AIMI_ROOT" != "/" ] && [ ! -d "$AIMI_ROOT/.aimi" ]; do AIMI_ROOT=$(dirname "$AIMI_ROOT"); done
[ -d "$AIMI_ROOT/.aimi" ] || AIMI_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
if git -C "$AIMI_ROOT" rev-parse --git-dir >/dev/null 2>&1; then AIMI_ROOT_IS_GIT_REPO=true; else AIMI_ROOT_IS_GIT_REPO=false; fi

GUARD_REFUSAL=""
if [ "$AIMI_ROOT_IS_GIT_REPO" != "true" ]; then
  PHASE_DIR_PATH="$AIMI_ROOT/.aimi/tasks/$FEATURE/$PHASE_DIR"
  GUARD_SPLIT_JSON=$($AIMI_CLI split-detect --dir "$PHASE_DIR_PATH")
  GUARD_DEGRADED_REASON=$(printf '%s' "$GUARD_SPLIT_JSON" | jq -r '.degradedReason // ""')

  case "$GUARD_DEGRADED_REASON" in
    *"is not a git repository"*)
      # split-detect itself named the condition: an unmarked legacy
      # frontend/backend pair in this phase's own directory would resolve to
      # the root group "." with nothing under "." to execute in.
      GUARD_REFUSAL="unroutable-pair"
      ;;
    *)
      # No pair-level refusal. Fall back to this phase's own governing tasks
      # file (same formula the split-detection block below uses) — "when
      # present on disk" is load-bearing: a phase fully routed by a project
      # split has no single governing file, and that is not a refusal case.
      PHASE_MAIN_TASKS="$PHASE_DIR_PATH/$FEATURE-phase-$PHASE_ID-tasks.json"
      if [ -f "$PHASE_MAIN_TASKS" ]; then
        # project-groups answers both this guard's question
        # (projectStoryCount) and Derive Participating Project Groups' own
        # question (groups) from one call -- see aimi-cli.sh's
        # cmd_project_groups. A refusal here is a genuinely malformed tasks
        # file (no userStories key, or an invalid project value) and is
        # handled directly rather than through $GUARD_REFUSAL, which names
        # only the two routability reasons below.
        GUARD_GROUPS_JSON=$($AIMI_CLI project-groups --tasks-file "$PHASE_MAIN_TASKS") || {
          $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
          exit 1
        }
        GUARD_PROJECT_STORIES=$(printf '%s' "$GUARD_GROUPS_JSON" | jq -r '.projectStoryCount')
        [ "${GUARD_PROJECT_STORIES:-0}" -eq 0 ] && GUARD_REFUSAL="no-project-anywhere"
      fi
      ;;
  esac

  if [ -n "$GUARD_REFUSAL" ]; then
    echo "Phase $PHASE_ID of $FEATURE is not routable under a non-git AIMI_ROOT ($AIMI_ROOT) — $GUARD_REFUSAL" >&2
    $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
    exit 1
  fi
fi
```

Exit 0 means the guard passed and this subsection continues below — true unconditionally when `AIMI_ROOT_IS_GIT_REPO=true`, and also when it is `false` but neither check above set `GUARD_REFUSAL`. **When the block exits non-zero,** the claim is already released — report and **STOP** without `cd`-ing to `AIMI_ROOT`, without computing `PHASE_CONTAINER_PATH`, and without creating any container, worktree, or branch. `$GUARD_REFUSAL` selects which message below to show:

**`GUARD_REFUSAL=unroutable-pair`** — split-detect itself named the git-repository condition:

```
Phase [PHASE_ID] of [FEATURE] cannot be routed to a repository under a
non-git AIMI_ROOT.

Detected layout: multi-repo — [AIMI_ROOT] is not a git repository. It is a
parent folder holding one repository per subfolder (see Multi-Repo Handling).

This phase's own directory holds an unmarked legacy frontend/backend pair —
neither file carries a `metadata.splitGroup` marker, so split-detect resolved
both to the root group (project "."), and there is no repository under "."
to execute in.

What you can do:
  - Re-plan this phase with a full-stack implementation scope
    (`/aimi:plan --phase [PHASE_ID]`, choosing full-stack when asked for
    implementation scope — internally `--split full-stack`) so every story
    carries its own `project` path and routes to the repository that owns it.
  - Or run /aimi:execute from inside a single repository that has its own
    .aimi/ directory, so AIMI_ROOT is that repository and phase mode applies
    to it alone. This forfeits the shared `roadmap.json` and the single phase
    lifecycle spanning every other repository under [AIMI_ROOT] — each repo
    would then need to plan and track this work under its own separate
    roadmap.

Phase [PHASE_ID]'s claim has been released. Nothing was created.
```

**`GUARD_REFUSAL=no-project-anywhere`** — split-detect found no pair-level refusal, but this phase's own governing tasks file has zero stories with a `project` field:

```
Phase [PHASE_ID] of [FEATURE] has no story with a `project` field, but
AIMI_ROOT is not a git repository: [AIMI_ROOT].

This is a multi-repo layout — AIMI_ROOT is a parent folder holding several
repos, so the root group (project ".") has no repository to execute this
phase in. A bare "." group is a legitimate routing key only when AIMI_ROOT is
itself a git repository (see `.aimi/known-gaps/2026-07-27-US-001.md`) — it is
not one here.

What you can do:
  - Give every story its own `project` path and re-plan
    (`/aimi:plan --phase [PHASE_ID]`), so each one routes to the repository
    that owns it.
  - Or run /aimi:execute from inside a single repository that has its own
    .aimi/ directory, so AIMI_ROOT is that repository and phase mode applies
    to it alone. This forfeits the shared `roadmap.json` and the single phase
    lifecycle spanning every other repository under [AIMI_ROOT] — each repo
    would then need to plan and track this work under its own separate
    roadmap.

Phase [PHASE_ID]'s claim has been released. Nothing was created.
```

**Reaching this point means the guard above passed — not that `AIMI_ROOT` itself is a repository.** When `AIMI_ROOT_IS_GIT_REPO` is true, `AIMI_ROOT` is guaranteed to be a repository, exactly as before. When it is false, passing means the guard already confirmed this phase is routable — either every active split member carries its own `metadata.splitGroup.project`, or at least one story in this phase's governing tasks file carries a `project` field — so every participating group resolves to its own repository even though `AIMI_ROOT` does not. Either way, that does not mean every participating story (or, once a split is detected, every split member) shares one common repository as its own toplevel: a `project` field can resolve to a nested repository whose own `git rev-parse --show-toplevel` differs from `AIMI_ROOT`'s own — and in a multi-repo layout it necessarily does for every non-root group. This phase's participating project groups cannot be derived until its split status is known, so **Detect a Full-Stack Split Inside This Phase** runs next; the phase container itself — one per participating repository — is created afterward, in **Create Phase Containers Per Project Group**, once that detection's result is available. **Phase-Mode Paired Split** below (untouched by this story) resolves each split member's own repository independently — through its own `SPLIT_ROOT`/`SPLIT_TOPLEVEL` derivation, not the single scalar `$PHASE_CONTAINER_PATH` — so a phase split spanning more than one repository is fully supported: each active member's worktree lands at its own repository's own toplevel, created from that repository's own phase branch, and merge and cleanup afterward run once per repository too (outline 07/08, landed).
