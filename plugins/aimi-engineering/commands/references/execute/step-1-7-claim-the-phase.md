# Execute: Step 1.7: Session Identity, Claim and Overlap Guard

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

### Resolve Session Identity

`roadmap-claim`'s stale-claim recovery needs a PID that stays alive for the whole `/aimi:execute` session, not the PID of one isolated Bash call (`$$` would be a different, already-dead process by the time any other session checks liveness). `$PPID` inside a Bash tool call is the PID of the process that spawns each isolated shell — the persistent host process for this session — so it stays constant across calls even though `$$` does not.

```bash
SESSION_ID="${CLAUDE_SESSION_ID:-execute-$PPID}"
SESSION_PID=$PPID
```

Compute this once; both `$CLAUDE_SESSION_ID` and `$PPID` re-derive identically on every subsequent Bash call within the same session, so re-running the two lines above anywhere this document calls `roadmap-claim` or `roadmap-release-claim` yields the same `SESSION_ID`/`SESSION_PID` values.

### Claim the Phase

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
if [ -n "$PHASE_OVERRIDE" ]; then
  CLAIM_JSON=$($AIMI_CLI roadmap-claim --feature "$FEATURE" --session-id "$SESSION_ID" --session-pid "$SESSION_PID" --phase "$PHASE_OVERRIDE" 2>&1)
else
  CLAIM_JSON=$($AIMI_CLI roadmap-claim --feature "$FEATURE" --session-id "$SESSION_ID" --session-pid "$SESSION_PID" 2>&1)
fi
CLAIM_EXIT=$?
```

`roadmap-claim` is a single atomic, flock-guarded check-and-set (mirrors the atomic-write pattern already documented for `story-merge`). It auto-releases any claim whose recorded PID fails a liveness probe, then:

- **No `--phase` (auto mode):** claims the lowest-numeric-id phase that is `pending`/`planned`, unclaimed, and whose `dependsOn` phases are all `completed` or `cancelled`. If the top candidate loses a claim race to a concurrent session, the CLI falls through internally to the next eligible phase and returns that one — this step contains no retry loop of its own, it consumes whatever phase the single call reports back as claimed.
- **With `--phase <N>` (explicit override):** claims phase `N` only if it is eligible. If phase `N` is ineligible, the call never falls through to a different phase.
- **Self-reclaim:** if this exact session already owns an unreleased claim on a phase still in `pending`/`planned`/`in_progress` (matching `--phase N` when an override was given, or any such phase in auto mode), the call returns that same phase again instead of erroring — this is what makes re-running `/aimi:execute` on an already-claimed phase idempotent (see Resuming Execution).

**On success (`CLAIM_EXIT=0`):** `CLAIM_JSON` is the claimed phase object. Extract:

```bash
PHASE_ID=$(printf '%s' "$CLAIM_JSON" | jq -r '.id')
PHASE_DIR=$(printf '%s' "$CLAIM_JSON" | jq -r '.dir')
PHASE_SLUG=$(printf '%s' "$CLAIM_JSON" | jq -r '.slug // ""')
PHASE_BRANCH=$(printf '%s' "$CLAIM_JSON" | jq -r '.branch // ""')
PHASE_ENTRY_STATUS=$(printf '%s' "$CLAIM_JSON" | jq -r '.status // ""')
```

`PHASE_ENTRY_STATUS` is the phase's **entry status** — its `roadmap.json` status as it stood at claim time, before this session touched it. It must be captured here, in this block, and nowhere else. `roadmap-claim` mutates only the `.claim` sub-object and never drives status itself (see the transition call further down this same step, which is the one and only status-mutating call), so the `.status` field on the returned phase object is the pre-claim value and is trustworthy. Moments later that same step transitions the phase to `in_progress`, so **every** later `roadmap-get` — including Phase Completion's own — reports `in_progress`, and the entry status is permanently unrecoverable from that point on. A phase re-entered after a failed creates verification is the case that needs it: `verification_failed` survives only in this variable. The `// ""` default keeps a roadmap object with no `status` field yielding an empty string rather than the literal text `null`, so a comparison against `verification_failed` can never accidentally match a stringified absence. Like `PHASE_ID`, it does not survive across Bash tool calls; the orchestrator carries it forward the same way it carries every other value this step extracts.

`FEATURE_TYPE` must come from this phase's own tasks file, not the mtime-discovered `$TASKS_PATH` from Step 1 — a feature with multiple materialized phase tasks files could have a more-recently-touched sibling phase file win that mtime race, leaking the sibling's `type` into this phase's branch prefix. `PHASE_TASKS_PATH` itself isn't resolved until **Point the session at this phase's own tasks file** below, so read directly from the same path that section computes, tolerating the file not existing yet (a not-yet-planned phase, or a full-stack split phase with no single governing file):

```bash
FEATURE_TYPE=$(jq -r '.metadata.type // "feat"' "$AIMI_ROOT/.aimi/tasks/$FEATURE/$PHASE_DIR/$FEATURE-phase-$PHASE_ID-tasks.json" 2>/dev/null)
FEATURE_TYPE="${FEATURE_TYPE:-feat}"
```

If `PHASE_BRANCH` is empty (the phase carries no pre-assigned `.branch`), compute it from the `type/<feature>-phase-<N>-<slug>` convention. `PHASE_SLUG` can itself be empty (a phase with no slug); when it is, drop the trailing `-` rather than emitting a branch name that ends in one.

The branch name is built from a **dot-slugified copy** of the phase id (`.` → `-`), never from the raw `$PHASE_ID`. Phase ids are legitimately decimal — `roadmap-init` accepts `5.5` and composes `.dir` from the raw value, and `/aimi:plan` renders the id exactly as its numeric frontmatter value — but the validation regex directly below has no dot in its character class, and neither does aimi-cli.sh's own `_ROADMAP_BRANCH_REGEX`, which enforces that same shape on a roadmap's `.branch` at write time. Interpolating the raw id here yielded `...-phase-5.5-...`, which this section then rejected seven lines later, released the claim and STOPped — so every decimal-id phase whose `.branch` was null could not be executed at all.

The slugifying is confined to this one derivation. Every filesystem path (`$FEATURE-phase-$PHASE_ID-tasks.json`, and the split-basename prefix strip that mirrors it) and every `--phase "$PHASE_ID"` argument keeps the **raw** id: those name real on-disk files that carry the dot, and match `roadmap.json`'s own numeric id. An id with no dot slugifies to itself, so every integer-id phase keeps the exact branch name it has today. The slugified copy is derived inside the same block that interpolates it — blocks run in isolated shells and do not share state, so it cannot be computed in an earlier one.

```bash
if [ -z "$PHASE_BRANCH" ]; then
  PHASE_ID_SLUG=$(printf '%s' "$PHASE_ID" | tr '.' '-')
  if [ -z "$PHASE_SLUG" ]; then
    PHASE_BRANCH="${FEATURE_TYPE}/${FEATURE}-phase-${PHASE_ID_SLUG}"
  else
    PHASE_BRANCH="${FEATURE_TYPE}/${FEATURE}-phase-${PHASE_ID_SLUG}-${PHASE_SLUG}"
  fi
fi
```

Validate `PHASE_BRANCH` against `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$` (the same regex Step 1.6 already enforces for user-supplied base branches). If it fails, release the claim (see Release the Claim on Abort) and report the invalid branch name, then STOP:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
```

### Report Stale Claim Releases

`CLAIM_JSON.staleReleased` is a (possibly empty) array the CLI populates whenever this exact `roadmap-claim` call auto-released one or more dead-PID claims before evaluating eligibility (see the PID-alive check described above). Report each released entry with this exact line, substituting the real values:

```bash
STALE_COUNT=$(printf '%s' "$CLAIM_JSON" | jq '.staleReleased | length')
if [ "$STALE_COUNT" -gt 0 ]; then
  while IFS=$'\t' read -r sr_id sr_sid sr_pid; do
    [ -z "$sr_id" ] && continue
    echo "released stale claim on phase $sr_id (session $sr_sid pid $sr_pid not alive)"
  done < <(printf '%s' "$CLAIM_JSON" | jq -r '.staleReleased[] | [(.id|tostring), .sessionId, (.pid|tostring)] | @tsv')
fi
```

This is a report of automatic recovery that already happened inside the atomic `roadmap-claim` call above — it never changes the outcome of this session's own claim.

### Reconcile Roadmap/Tasks Divergence

Immediately after a successful claim — before the `in_progress` status transition below — run `roadmap-reconcile` once as an advisory health check across the whole roadmap. This is the only call site in the command flow; `roadmap-reconcile` is otherwise defined and tested but never invoked, so drift between a phase's `status` in `roadmap.json` and its own tasks file's actual story statuses would otherwise go unnoticed until it surfaces as the `in_progress` transition failure below.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
RECONCILE_JSON=$($AIMI_CLI roadmap-reconcile --feature "$FEATURE" 2>/dev/null)
```

If the call fails or returns malformed JSON, skip silently — this is advisory only and never blocks the claim or the transition that follows. Otherwise, count each array and surface non-empty ones to the user without stopping:

```bash
CORRECTIONS_COUNT=$(printf '%s' "$RECONCILE_JSON" | jq '.corrections | length' 2>/dev/null || echo 0)
BLOCKED_COUNT=$(printf '%s' "$RECONCILE_JSON" | jq '.blocked | length' 2>/dev/null || echo 0)
```

```
[If CORRECTIONS_COUNT > 0:]
Roadmap reconcile corrected [CORRECTIONS_COUNT] phase(s) whose status had drifted from its tasks file:
  For each entry in RECONCILE_JSON.corrections: "  - phase [entry.id]: [entry.from] → [entry.to]"

[If BLOCKED_COUNT > 0:]
Roadmap reconcile found [BLOCKED_COUNT] phase(s) that should be completed but can't be corrected yet:
  For each entry in RECONCILE_JSON.blocked: "  - phase [entry.id]: [entry.from] → [entry.to] ([entry.reason])"
```

This is healing, not gating — it never aborts this session's claim, even when it reports corrections or blocked entries for phases other than the one just claimed.

### Overlap Guard

Before transitioning the newly claimed phase to `in_progress`, check whether any other phase in this roadmap is currently `in_progress` (in a sibling `/aimi:execute` session) and, if so, whether the two phases' declared work overlaps. This guard is **soft in both interactive and agent mode** — it never blocks or fails the claim itself, since `roadmap-claim`'s atomic check-and-set already succeeded before this section runs. Every read of a sibling phase's state below goes through `$AIMI_CLI roadmap-get` / `$AIMI_CLI phase-overlap` — never a direct Read of a phase directory this session does not own.

`roadmap-get` is used only to list which siblings are currently `in_progress`; the overlap answer itself always comes from `phase-overlap`'s exact `implementation.files` intersection — there is no coarser pre-filter gating it. A coarse `areas`-array comparison was tried first and dropped: `areas` are declared as broad globs (e.g. `app/checkout/**` vs. `app/checkout/cart/**`), so two phases that provably share files could still compare as disjoint under exact string equality, silently skipping the real check it was meant to gate — and a phase with no `areas` at all disabled the guard entirely. Calling `phase-overlap` unconditionally for every `in_progress` sibling has no such gap:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
ROADMAP_ALL_JSON=$($AIMI_CLI roadmap-get --feature "$FEATURE")

OVERLAP_WARNINGS_JSON='[]'
while IFS= read -r y_id; do
  [ -z "$y_id" ] && continue
  # phase-overlap failing here (e.g. the sibling has not been rolling-wave
  # expanded yet, no tasks.json) is not an error for this soft guard -- skip
  # that sibling.
  if OVERLAP_JSON=$($AIMI_CLI phase-overlap "$FEATURE" "$PHASE_ID" "$y_id" 2>/dev/null); then
    FILES_COUNT=$(printf '%s' "$OVERLAP_JSON" | jq '.overlapping_files | length')
    if [ "$FILES_COUNT" -gt 0 ]; then
      FILES_ARR=$(printf '%s' "$OVERLAP_JSON" | jq -c '.overlapping_files')
      OVERLAP_WARNINGS_JSON=$(printf '%s' "$OVERLAP_WARNINGS_JSON" | jq --argjson y "$y_id" --argjson files "$FILES_ARR" '. + [{phaseId: $y, files: $files}]')
    fi
  fi
done < <(printf '%s' "$ROADMAP_ALL_JSON" | jq -r --argjson x "$PHASE_ID" '[.phases[] | select(.status == "in_progress" and .id != $x)] | .[].id')
```

**When `OVERLAP_WARNINGS_JSON` is `[]`** (no `in_progress` sibling, or `phase-overlap` found no shared file with any sibling it could evaluate): skip silently — no prompt, no log line. Proceed straight to the status transition below.

**When `OVERLAP_WARNINGS_JSON` is non-empty**, for each `{phaseId: Y_ID, files}` entry in order:

- **`INTERACTIVE_MODE=picker`:** use **AskUserQuestion**:
  ```
  Phase [PHASE_ID] and in-progress phase [Y_ID] both touch:
  [one line per path in files]

  A — Proceed in parallel anyway
  B — Wait for phase [Y_ID] to finish before claiming
  C — Abort this claim attempt
  ```
  - **Option A:** continue to the next entry (or, if this was the last entry, proceed to the status transition below).
  - **Option B or C:** release the claim this session just took, and STOP — do not evaluate any remaining entries:
    ```bash
    AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
    : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
    $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
    ```
    Report `Claim on phase [PHASE_ID] released — [waiting for phase [Y_ID] to finish | claim attempt aborted] per user choice.` and STOP.
- **`INTERACTIVE_MODE=agent`:** log a one-line warning per entry and proceed automatically — never release the claim:
  ```
  Warning: phase [PHASE_ID] and in-progress phase [Y_ID] share file(s): [comma-joined files] (agent-mode: proceeding in parallel)
  ```
  After logging every entry, continue to the status transition below.

**Immediately after a successful claim, transition the phase to `in_progress`.** This is a SEPARATE call — `roadmap-claim` manages only the claim sub-object (`claimedBy`/`claimedAt`/`claimedPid`) and never drives status itself, so this step contains exactly one roadmap-status-mutating call beyond the claim:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
if ! SET_STATUS_ERR=$($AIMI_CLI roadmap-set-status --feature "$FEATURE" --phase "$PHASE_ID" --status in_progress 2>&1); then
  echo "ERROR: could not transition phase $PHASE_ID to in_progress:" >&2
  echo "$SET_STATUS_ERR" >&2
  echo "roadmap.json and this phase's tasks file disagree. Run: $AIMI_CLI roadmap-reconcile --feature \"$FEATURE\"" >&2
  $AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
  exit 1
fi
```

Do **not** swallow this call's exit status. Every state a claim can hand back — `pending`, `planned`, `in_progress` (crashed-session resume) and `verification_failed` (re-verify retry) — has an explicit `→ in_progress` transition, including the idempotent `in_progress → in_progress`. So a rejection here is never routine: it means the phase is in a state the claim should not have returned, i.e. roadmap.json has diverged from the phase's tasks file. Failing loudly and pointing at `roadmap-reconcile` is the recovery path; an earlier `|| true` hid this and let the phase run to completion only to fail at the final `completed` transition. The claim is released (see Release the Claim on Abort) before exiting — `roadmap-reconcile` heals the divergence, and the reconcile call above already ran once for this claim, so a retry (self or otherwise) after running it manually re-claims cleanly instead of piling onto a claim this session can no longer make progress on.

**On failure (`CLAIM_EXIT` is 3 or 4):** `CLAIM_JSON` holds the CLI's stderr.

- **Auto mode, `CLAIM_EXIT=4` (no phase remains pending/planned):** report `No eligible phase — every phase in [FEATURE]'s roadmap is already claimed, completed, or terminal.` and STOP.
- **Auto mode, `CLAIM_EXIT=3` (all remaining phases blocked):** list every ineligible phase with its specific reason, taken verbatim from `CLAIM_JSON`'s `phase N: <reason>` lines (mirrors the "Deadlock detected" reporting style in Step 4):
  ```
  No phase is ready to claim:
  [one line per blocked phase, from CLAIM_JSON]

  Resolve the blocking dependency, or run /aimi:execute --phase <N> to override.
  ```
  STOP.
- **Explicit override, either exit code:** report the specific reason `CLAIM_JSON` gives for phase `PHASE_OVERRIDE` (unmet dependency, still claimed by a live session, wrong status, or not found) — never a generic "not ready" message — and STOP. Do not fall through to a different phase.
