# Execute: Phase Completion: Multi-File Pending Count

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

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

