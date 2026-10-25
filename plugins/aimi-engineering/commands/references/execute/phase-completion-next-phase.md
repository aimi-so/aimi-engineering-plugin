# Execute: Phase Completion: Next Phase

> Loaded by `commands/execute.md` when its `Applies when:` condition holds. The section below moved here from `execute.md` verbatim.

### Next Phase

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
NEXT_ELIGIBLE_JSON=$($AIMI_CLI roadmap-get --feature "$FEATURE" --next-eligible 2>&1)
NEXT_ELIGIBLE_EXIT=$?
```

**When `NEXT_ELIGIBLE_EXIT != 0`** (no phase remains pending/planned, unclaimed, and dependency-complete — the roadmap-exhaustion case; a phase stuck in `verification_failed` also falls here since it is neither `pending` nor `planned`, matching outline 02's landed `roadmap-get --next-eligible` contract): skip both the interactive offer and the agent-mode auto-continue branch entirely. Run the residual sweep exactly once and hand its report to Step 5:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
ROADMAP_SWEEP_REPORT=$($AIMI_CLI roadmap-sweep "$FEATURE")
```
`ROADMAP_SWEEP_REPORT` is rendered as a `## Roadmap Sweep` section in Step 5's final summary (see below). No next-phase offer of any kind is shown.

**Otherwise**, `NEXT_ELIGIBLE_JSON` is the next eligible phase object; extract `NEXT_PHASE_ID=$(printf '%s' "$NEXT_ELIGIBLE_JSON" | jq -r '.id')`.

The phase named here is whichever one `roadmap-get --next-eligible` selects, and that is **not necessarily the lowest-numbered** eligible phase: the verb ranks dependency-eligible candidates by remaining work first — every candidate with pending stories ahead of every candidate without — and only then by ascending id. A phase whose stories are all complete is therefore offered *after* a higher-numbered phase that still has work, even though its id is lower. When every eligible candidate has work the ordering collapses to ascending id, which is why this offer is unchanged for the common case. Do not reword this prompt to promise the "next" or "lowest" phase.

- **Interactive mode** (`$AIMI_CLI detect-interactivity` = `picker`): use **AskUserQuestion** with exactly two options:
  ```
  Phase [PHASE_ID] is complete. Plan phase [NEXT_PHASE_ID] now?

  A — Plan it now
  B — Plan it later
  ```
  **Option A:** set `NEXT_PHASE_HANDOFF=$NEXT_PHASE_ID` (consumed after Step 5's report — see below).
  **Option B:** report `"Resume with: /aimi:plan --phase [NEXT_PHASE_ID]"` and end the session after Step 5's report.

- **Agent mode** (`detect-interactivity` = `agent`): skip AskUserQuestion. Log exactly:
  ```
  agent-mode: phase-complete auto-continue [PHASE_ID]
  ```
  (`[PHASE_ID]` is the phase that **just completed**, not `NEXT_PHASE_ID`.) Set `NEXT_PHASE_HANDOFF=$NEXT_PHASE_ID`.

After Step 5's report is shown, if `NEXT_PHASE_HANDOFF` is set, proceed immediately into `/aimi:plan --phase [NEXT_PHASE_HANDOFF]`'s command flow — no further prompt, no waiting on additional user input.

