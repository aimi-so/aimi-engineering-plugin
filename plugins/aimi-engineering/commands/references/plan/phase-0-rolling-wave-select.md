# Plan: Phase 0: Rolling-Wave Phase Selection, load the roadmap and select the target phase

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.

#### Load the roadmap and ask the CLI which phases may be expanded

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
ROADMAP_JSON=$($AIMI_CLI roadmap-get --feature "$featureSlug")
PHASE_VERDICTS_JSON=$($AIMI_CLI roadmap-eligible --feature "$featureSlug" --statuses pending)
```

Two reads of the same `roadmap.json`, each answering a different question, and both are needed. `ROADMAP_JSON` is the document itself — the only place `slug`, `dir`, `goal`, `areas` and `creates` exist, which is why the selection below still takes the chosen phase's full object out of it, and why the Prior Phase Handoff Ingestion step further down walks it too. `PHASE_VERDICTS_JSON` is the eligibility answer, and it comes from the CLI precisely so that this command and `roadmap.py` cannot drift into disagreeing about which phase is next.

**Payload shape** (`roadmap-eligible`): one JSON object — `{phases: [{id, name, status, claim, eligible, unmet: [{id, status}]}], eligible: [ids], eligibleCount: N}`. `phases[]` carries a verdict for **every** phase in the roadmap, not only the eligible ones, so this single call serves both the by-id lookup the `--phase` override needs and the whole-list rendering the blocked report needs. `eligible[]` holds the ids of the eligible ones, already ordered.

**Branch on the payload, never on the exit code.** `roadmap-eligible` exits **0** when nothing is eligible and says so in the payload (`eligible: []`, `eligibleCount: 0`) — deliberately unlike `roadmap-get --next-eligible`, which exits 1 for that case. An empty list is the STOP-with-report path below, and it must stay distinguishable from a broken CLI: a non-zero exit, or stdout that does not parse as JSON, is a genuine failure and is reported as one rather than as "no phase is ready".

**`--statuses pending` is passed explicitly and is not optional here.** The verb defaults to `pending,planned`, which is what `/aimi:execute`'s claim wants — it consumes phases that are either awaiting expansion or already expanded-but-not-yet-run. `/aimi:plan` must never adopt that default: re-expanding a phase already marked `planned` would overwrite the stories a previous invocation wrote.

**Ordering is a choice this command makes when it calls the verb, not a property it inherits.** `roadmap-eligible` orders by numeric `id` alone — `2`, `2.1`, `3` ascending, decimal ids in their true position rather than a lexicographic one, and ties impossible because `roadmap-init` rejects duplicate ids. Two reasons that is what `/aimi:plan` asks for. First, expansion order is a narrative a human reads: phases are cut so each one builds on the one before it, and offering them out of numeric order asks the reader to follow a story told out of sequence. Second, an id-only request reads no tasks file at all, so the answer depends on `roadmap.json` alone and does not move between two reads of the same roadmap while a concurrent `/aimi:execute` is rewriting those files underneath it.

That is a deliberate divergence from a sibling call site, not an oversight. `/aimi:execute`'s end-of-phase "Plan phase [N] now?" prompt (`references/execute/phase-completion-next-phase.md`) consumes `roadmap-get --next-eligible`, which ranks by remaining work first and ascending id only second — so it can offer a higher-numbered phase that still has work ahead of a lower-numbered one whose stories are all complete. The two orders coincide whenever every eligible phase has work; where they part, each is right for its own caller, because `/aimi:execute` is choosing what to *run* next while `/aimi:plan` is choosing what to *narrate* next.

**No new python3 dependency on this path.** `roadmap-get` on the line directly above already shells out to `scripts/roadmap.py`, so this block required python3 before `roadmap-eligible` was added to it and requires exactly as much now.

**Every user-facing sentence in this section is composed here, in plan.md.** The verb emits structured fields only — not one of them carries a sentence — because the plugin's output follows whatever language the person is writing in, and a sentence composed inside `roadmap.py` cannot be re-worded from the command layer. Read `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md` (the `${CLAUDE_PLUGIN_ROOT}` prefix is required — it is the only form `install.sh` rewrites to `${AIMI_PLUGIN_DIR}` for OpenCode) and apply its **Adaptive Language Rule** to every refusal and every report below.

#### Select the target phase

**With `--phase <N>` override:**

```bash
case "$PHASE_OVERRIDE" in
  ''|*[!0-9.]*|.*|*.|*.*.*)
    echo "PHASE_GATE_OUTCOME=INVALID_SHAPE PHASE_OVERRIDE=$PHASE_OVERRIDE MAX_DECIMAL_LEVELS=1" >&2
    exit 1
    ;;
esac
PHASE_VERDICT_JSON=$(printf '%s' "$PHASE_VERDICTS_JSON" | jq -ce ".phases[] | select(.id == $PHASE_OVERRIDE)")
PHASE_VERDICT_RC=$?
SELECTED_PHASE_JSON=$(printf '%s' "$ROADMAP_JSON" | jq -e ".phases[] | select(.id == $PHASE_OVERRIDE)")
SELECTED_PHASE_RC=$?
if [ "$PHASE_VERDICT_RC" = 0 ] && [ "$SELECTED_PHASE_RC" = 0 ]; then
  PHASE_GATE_OUTCOME=PRESENT
else
  PHASE_GATE_OUTCOME=ABSENT
fi
echo "PHASE_GATE_OUTCOME=$PHASE_GATE_OUTCOME"
```

The id is interpolated from the shell rather than bound as a jq variable, and the `case` above is the gate that makes that safe **in this same block** — blocks are executed one per isolated shell, so the `^[0-9]+(\.[0-9]+)?$` check in the argument-parsing step near the top of this file cannot protect this one. The gate stays a `case` rather than a `grep -E` because `grep` matches line by line and would admit a multi-line value whose first line is all digits, while a `case` pattern is tested against the whole string — the same reasoning `check_argument_gate_same_block` in `scripts/test-command-blocks.sh` already records for numeric identifiers.

**Digits and dots are enough for injection safety and not enough for parseability — which is what the five arms are for.** A value made only of digits and dots leaves nothing for jq or the shell to interpret, and that half was always true. But `1.1.1` is made only of digits and dots and is not a JSON number: jq refuses to **compile** the program at all (`jq: error: Invalid numeric literal at EOF ... (while parsing '1.1.1')`, exit 3), and the `$( )` around it swallows that status into an empty string — so the reader used to be told a phase they never typed was missing from the roadmap. The arms above admit at most one dot, so what reaches jq is both uninterpretable *and* a literal jq can compile. That is also what makes `jq -e`'s status readable below: exit 3 is unreachable from here, so a non-zero status means "no phase carries that id" and nothing else.

Matching is therefore **numeric**, against the phase id as a JSON number: `--phase 2.10` selects phase `2.1`, and `--phase 02` selects phase `2`. That is correct — `2.10` and `2.1` are the same number — and it is the same reading every other `--phase` consumer in the CLI already applies.

Branch on `PHASE_GATE_OUTCOME`, the block's own last line — three outcomes, one of which used to be indistinguishable from another:

- **`PHASE_GATE_OUTCOME=INVALID_SHAPE`** — the `case` refused the value before jq ran and the block exited 1, having emitted `PHASE_GATE_OUTCOME=INVALID_SHAPE PHASE_OVERRIDE=<the value> MAX_DECIMAL_LEVELS=1` on stderr. Compose the refusal from exactly those three fields per the Adaptive Language Rule above: name the value the person typed, and name the ceiling it broke — a phase id carries at most one decimal level, so `1.1` is one and `1.1.1` is not. This outcome has a branch of its own because it used to have none: an id like `1.1.1` reached jq, jq failed to compile the program, the `$( )` swallowed the error, and the person was told a phase they never typed was not in the roadmap.
- **`PHASE_GATE_OUTCOME=ABSENT`** — the shape was legal and no phase in the roadmap carries that id (`jq -e` produced no value for the verdict select, the roadmap select, or both). This outcome forks rather than dead-ends: in a picker session it becomes an offer to author it into the roadmap, and in agent mode it reports and STOPs. Take *The `ABSENT` outcome* below — it is the whole of this branch — and return to the `PRESENT` bullet only once the phase exists.
- **`PHASE_GATE_OUTCOME=PRESENT`** — both selects produced a record, `PHASE_VERDICT_JSON` carries the phase's verdict and `SELECTED_PHASE_JSON` its full object from the roadmap document. The phase exists; the two bullets below continue this outcome and decide whether it may be expanded.
- **Found but not eligible** (`PHASE_VERDICT_JSON`'s `.eligible` is `false`): refuse **before any research or expansion Task is spawned**. Compose the refusal from that record's own fields — never a generic message — taking the first reason that applies:
  - `.status` is not `pending`:
    ```
    Phase [id] ([name]) is not eligible for expansion: status is '[status]' (expected 'pending').
    ```
  - `.claim` is non-null:
    ```
    Phase [id] ([name]) is not eligible for expansion — already claimed by [claim.claimedBy].
    ```
  - `.unmet` is non-empty:
    ```
    Phase [id] ([name]) is not eligible for expansion — unmet dependencies:
      phase [unmet[].id]: status '[unmet[].status]' (expected 'completed')
      ...
    ```
  List **every** `.unmet` entry, not just the first. STOP — never fall through to a different phase.
- **Eligible:** `SELECTED_PHASE_JSON`, assigned above, is the phase to expand. Note where it comes from: the **roadmap document**, not the verdict record. The verdict carries `{id, name, status, claim, eligible, unmet}` and no `slug`, `dir`, `goal`, `areas` or `creates` — the very fields the working-memory extraction below and the `frontendBearing` signal read out of it.
