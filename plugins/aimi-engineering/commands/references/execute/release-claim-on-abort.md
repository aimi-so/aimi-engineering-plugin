# Execute: Release the Claim on Abort

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

## Release the Claim on Abort

This section is the single source of truth for releasing a phase's `roadmap-claim` when a phase-mode session (Step 1.7 onward) stops without reaching the normal completion path (**Mark Phase Completed** in Phase Completion, which already releases the claim atomically as part of its `completed` status write). Every other STOP/abort in phase mode, once this session has successfully claimed a phase, releases the claim first. There are no exceptions: a session that has stopped acting on a phase is no longer "actively working" it, and `roadmap-claim`'s own auto-mode branch already treats any *unclaimed* `pending`/`planned`/`in_progress`/`verification_failed` phase as re-claimable (among dependency-eligible candidates, ordered by remaining work first and lowest id second) — so an unclaimed phase, whatever its status, is cleanly recoverable by a plain `/aimi:execute` re-run, self or otherwise. Holding the claim past this session's own stop only forces that recovery to wait on PID-liveness staleness instead of being immediate. The work-first ordering **demotes, never excludes**: a phase with nothing left to run — a `verification_failed` phase awaiting re-verification, or a session that crashed after its last story — waits behind any phase that still has pending work, and is claimed as soon as it is the only dependency-eligible candidate. That wait is bounded by the with-work phases completing; a dependency-eligible phase that keeps failing keeps its work and can starve the stuck phase indefinitely in auto mode, in which case `/aimi:execute --phase <N>` reaches it directly, unranked.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI roadmap-release-claim --feature "$FEATURE" --phase "$PHASE_ID"
```

**Guard — only the session that itself ran Step 1.7 calls this.** A Phase-Mode Paired Split sub-orchestrator never runs Step 1.7 (its spawn prompt pre-sets `PHASE_MODE`/`PHASE_BRANCH`/`PHASE_CONTAINER_PATH`/`PHASE_TASKS_PATH` directly and explicitly skips Step 1.7 entirely), so it never learns `$PHASE_ID` and must never call this — doing so would release the *parent's* claim on the whole phase out from under the sibling split still running. Every call site below is therefore written as "when `PHASE_MODE=true` **and** `$PHASE_ID` is set" — true only in the top-level orchestrator that itself claimed the phase, never in a spawned split sub-orchestrator.

---
