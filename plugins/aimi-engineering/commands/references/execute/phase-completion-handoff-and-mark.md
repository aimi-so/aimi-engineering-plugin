# Execute: Phase Completion: Write Handoff and Mark Completed

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

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
  PHASE_SPLIT_JSON=$($AIMI_CLI split-detect --dir "$PHASE_DIR_PATH" --include-completed) || {
    echo "split-detect --include-completed failed for $PHASE_DIR_PATH" >&2
    exit 1
  }
  PHASE_MEMBERS_JSON=$(printf '%s' "$PHASE_SPLIT_JSON" | jq -c '.members[]')
  PHASE_GROUP_RAW=""
  while IFS= read -r split_file; do
    [ -n "$split_file" ] || continue
    GROUP_PROJECT=$(printf '%s\n' "$PHASE_MEMBERS_JSON" | jq -r --arg p "$split_file" 'select(.path == $p) | .project // "."')
    PHASE_GROUP_RAW="${PHASE_GROUP_RAW}${GROUP_PROJECT}"$'\n'
  done <<< "$PHASE_SPLIT_FILES"
  PHASE_GROUP_PROJECTS=$(printf '%s\n' "$PHASE_GROUP_RAW" | grep -v '^$' | sort -u)
  [ -n "$PHASE_GROUP_PROJECTS" ] || PHASE_GROUP_PROJECTS="."
  # A member's project is a git/serve target below: refuse a traversal-shaped
  # value or one outside the project character class, as creates-verification does.
  while IFS= read -r GROUP_PROJECT; do
    case "$GROUP_PROJECT" in
      ''|.) ;;
      /*|..|../*|*/..|*/../*)
        echo "Invalid project \"$GROUP_PROJECT\" for phase $PHASE_ID" >&2
        exit 1
        ;;
      *)
        if ! [[ "$GROUP_PROJECT" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$ ]]; then
          echo "Invalid project \"$GROUP_PROJECT\" for phase $PHASE_ID" >&2
          exit 1
        fi
        ;;
    esac
  done <<< "$PHASE_GROUP_PROJECTS"
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

