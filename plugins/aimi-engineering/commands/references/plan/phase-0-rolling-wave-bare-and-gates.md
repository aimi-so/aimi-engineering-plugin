# Plan: Phase 0: Rolling-Wave Phase Selection, bare invocation, working memory and the pre-expansion gates

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.
>
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

**Bare invocation (no `--phase`):**

```bash
SELECTED_PHASE_ID=$(printf '%s' "$PHASE_VERDICTS_JSON" | jq -r '.eligible[0] // ""')
if [ -n "$SELECTED_PHASE_ID" ]; then
  SELECTED_PHASE_JSON=$(printf '%s' "$ROADMAP_JSON" | jq ".phases[] | select(.id == $SELECTED_PHASE_ID)")
fi
```

- **`SELECTED_PHASE_ID` non-empty** → it is the eligible phase with the lowest numeric id, and `SELECTED_PHASE_JSON` is that phase's full object from the roadmap document — again the document, for the same reason as the override path above.
- **`SELECTED_PHASE_ID` empty** (`eligible[]` was `[]`, on an exit-0 call) → no phase is ready. Enumerate **every** phase in the roadmap with its own reason (mirrors `/aimi:execute` Step 1.7's "No phase is ready to claim" style):
  ```bash
  PENDING_PHASE_COUNT=$(printf '%s' "$PHASE_VERDICTS_JSON" | jq '[.phases[] | select(.status == "pending")] | length')
  printf '%s' "$PHASE_VERDICTS_JSON" | jq -c '.phases[]'
  ```
  **Every phase, not only the `pending` ones — this listing has no filter and no fall-through, because both were how it came to print a heading above an empty list.** The old form selected `.status == "pending"` and then branched on `.unmet`/`.claim` with an `else` that emitted nothing, so a `completed` phase was dropped twice over: once by the filter, and again by the `else`, since a completed phase has met dependencies and carries no claim. On the real 7-of-7-completed roadmap that left the heading with nothing under it. Widening the filter alone would not have fixed it — the reason vocabulary has to have a **status-keyed** category, or the widened rows fall straight through the same `else`.

  So `jq` emits one verdict record per line for every phase, and each record yields exactly one composed line. Take the first category that applies:

  - `.status` is `"completed"` → this phase is finished; nothing here to expand.
  - `.status` is `"cancelled"` → this phase was cancelled; nothing here to expand.
  - `.status` is `"planned"` → already expanded by an earlier `/aimi:plan`; run `/aimi:execute` to work it, and note that re-expanding it would overwrite the stories that invocation already wrote.
  - `.status` is `"in_progress"` → being worked right now.
  - `.status` is `"verification_failed"` → expanded and run, but its verification did not pass; `/aimi:execute` re-verifies it.
  - `.status` is `"pending"` and `.unmet` is non-empty → blocked; name **every** unmet entry by `id` and its current `status`, never just the first.
  - `.status` is `"pending"` and `.claim` is non-null → claimed by `[claim.claimedBy]`.
  - anything else → name the status verbatim. This catch-all exists so that no record can produce zero lines, whatever a hand-edited roadmap carries in `status`.

  `PENDING_PHASE_COUNT` picks the heading, and the split it draws is the one `op_claim` already draws in `roadmap.py` between "nothing remains in a claimable status at all" (its exit 4) and "some remain, but every one of them is blocked" (its exit 3) — a reader has to act differently on the two, so the report must not blur them.

  **`PENDING_PHASE_COUNT` is `0`** — there is nothing to block; the roadmap is simply out of expandable phases, and telling this reader to resolve a dependency would send them looking for one that does not exist:
  ```
  Nothing left to expand in [featureSlug]'s roadmap — no phase is pending:
  [one composed line per phase]

  Every phase is already expanded, in progress, or completed. Run /aimi:execute to work them, or start a new feature with a fresh description.
  ```
  **`PENDING_PHASE_COUNT` is non-zero** — phases remain and every one of them is held up by something the reader can act on:
  ```
  No eligible pending phase in [featureSlug]'s roadmap — [PENDING_PHASE_COUNT] are pending, and all of them are blocked:
  [one composed line per phase]

  Run /aimi:plan --phase <N> to override, or resolve the blocking dependency first.
  ```
  Both are shapes, not strings: compose them here, in the reader's own language, per the Adaptive Language Rule referenced above.

  STOP the entire `/aimi:plan` invocation — do not fall back to the flat pipeline (that would silently create an unrelated top-level tasks.json instead of expanding this roadmap).

#### Extract selected-phase working memory

```bash
SELECTED_PHASE_ID=$(printf '%s' "$SELECTED_PHASE_JSON" | jq -r '.id')
PHASE_NAME=$(printf '%s' "$SELECTED_PHASE_JSON" | jq -r '.name')
PHASE_SLUG=$(printf '%s' "$SELECTED_PHASE_JSON" | jq -r '.slug // ""')
PHASE_DIR=$(printf '%s' "$SELECTED_PHASE_JSON" | jq -r '.dir')
PHASE_GOAL=$(printf '%s' "$SELECTED_PHASE_JSON" | jq -r '.goal')
PHASE_AREAS_JSON=$(printf '%s' "$SELECTED_PHASE_JSON" | jq -c '.areas // []')
```

`PHASE_DIR` is the `phase-<id>[-<slug>]` directory segment `roadmap-init` already computed and validated at materialization time — reuse it verbatim here; never re-derive it.

`SELECTED_PHASE_ID` is re-read from the selected phase object here rather than carried over from whatever the selection step matched on, and that is what canonicalizes it: `--phase 2.10` leaves this block holding `2.1`, the roadmap's own spelling of that id. Everything downstream depends on it — the tasks-file path, every `--phase` argument passed back to the CLI, and the slugified branch name — and all of them must name what `roadmap.json` actually contains, not what the user typed.

#### Pre-Expansion Contract Gate

Runs once, immediately after selection, before Phase 1 research begins — so a rejected phase never pays for research it cannot use:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
if [ "$INTERACTIVE_MODE" = "agent" ]; then
  CONTRACTS_JSON=$($AIMI_CLI validate-contracts "$featureSlug" --phase "$SELECTED_PHASE_ID" --agent-mode 2>&1)
else
  CONTRACTS_JSON=$($AIMI_CLI validate-contracts "$featureSlug" --phase "$SELECTED_PHASE_ID" 2>&1)
fi
CONTRACTS_EXIT=$?
```

`validate-contracts` performs **two distinct checks in a single call**, and only one of them is demotable:

1. **Duplicate creates** (status-agnostic — scans every phase in the roadmap regardless of `pending`/`planned`/`completed`, since two phases can each declare the same artifact identity long before either is `completed`): when the selected phase's `creates[]` collides with another phase's `creates[]` identity, this is reported. **Interactive mode (no `--agent-mode`): the CLI itself hard-blocks — it exits 1 before even evaluating needs.** **`--agent-mode`: demoted to a warning in the CLI's own JSON output (`duplicateWarnings[]`), and the call proceeds** to the needs check below. This satisfies the "collision surfaces before Pass 2 expansion begins, distinct from and additional to the needs-unmet check" requirement — both checks live inside this one CLI call, and duplicate-creates is evaluated first.
2. **Needs resolution** (scoped to `--phase`, walking the transitive `dependsOn` closure): a `needs[]` entry with no `completed` phase whose `handoff.md` lists it under `## Artifacts Created` is reported in `missing[]`. **This check always blocks — interactive and agent-mode alike. `--agent-mode` never demotes an unmet need** — only the duplicate-creates finding above is demotable, per `validate-contracts`'s own contract.

**On `CONTRACTS_EXIT = 0`:** proceed. If `CONTRACTS_JSON` contains a non-empty `duplicateWarnings[]` (only possible in agent-mode), log each entry:
```
[plan] agent-mode: duplicate creates proceeding — phase [id] and phase [id]: both declare "[identity]"
```

**On `CONTRACTS_EXIT != 0`:** parse the CLI's stderr (captured above via `2>&1`).
- **Duplicate-creates block (interactive only):** surface the CLI's own collision message verbatim — it already names both phases and the colliding identity. STOP before any research or expansion Task is spawned.
- **Unmet needs (either mode):** surface each `missing[]` entry:
  ```
  Phase [SELECTED_PHASE_ID] cannot be expanded — unmet need(s):
    needs "[need]" — no completed phase delivers it (reason: [no-provider|not-delivered])
    ...
  ```
  STOP. Do not spawn any research or expansion Task.

#### Prior Phase Handoff Ingestion

For every phase in `ROADMAP_JSON` with `status == "completed"`, read its `handoff.md` (written by `/aimi:execute`'s `roadmap-write-handoff` step) into planning context, so Pass 2 story expansion reuses prior decisions and artifacts instead of recreating them:

```bash
COMPLETED_DIRS=$(printf '%s' "$ROADMAP_JSON" | jq -r '.phases[] | select(.status == "completed") | "\(.id)\t\(.name)\t\(.dir)"')
```

For each `id / name / dir` line (ascending phase-id order, matching `roadmap-get`'s natural ordering):

1. Compute `HANDOFF_PATH="$AIMI_ROOT/.aimi/tasks/$featureSlug/$dir/handoff.md"`.
2. If missing on disk, skip silently — a phase can be `completed` without a handoff only in a pre-`roadmap-write-handoff` legacy state; do not error.
3. Read the file verbatim and wrap it (mirrors the `<research_file>` escape used at Phase 1.7):
   ```
   <phase_handoff id="<id>" name="<name>">
   …contents, with any literal </phase_handoff or <phase_handoff sequence replaced by
   &lt;/phase_handoff / &lt;phase_handoff…
   </phase_handoff>
   ```
4. Append to `phaseHandoffBlocks` (empty string when no completed phase has a handoff, or `ROADMAP_MODE=false`).

**Aggregate cap:** after collecting all blocks, if the total size exceeds **150 KB**, drop the OLDEST completed phase's block first (lowest id — its content is most likely already superseded by later decisions) and continue dropping in ascending-id order until under the cap. Emit one warning line per dropped block: `[plan] phase [id] handoff dropped — aggregate handoff context exceeded 150KB`.

`phaseHandoffBlocks` is threaded into the Phase 3d sub-agent prompt template's **Prior Phase Handoff** section (see below); it is not read by Phase 1 researchers.

#### Phase-Scoped Topic Slug

```bash
PHASE_SUFFIX="-phase-${SELECTED_PHASE_ID}"
PHASE_TOPIC_SLUG="${featureSlug}${PHASE_SUFFIX}${PHASE_SLUG:+-$PHASE_SLUG}"
# Apply the same five-step normalization as commands/references/topic-slug.md
# (lowercase, hyphenate, dedupe hyphens, truncate 50, strip trailing hyphens) —
# featureSlug and PHASE_SLUG are already lowercase-hyphenated, so this mainly
# applies the 50-char truncation.
if [ "${#PHASE_TOPIC_SLUG}" -gt 50 ]; then
  # A plain truncation of a long featureSlug cuts the phase id off, and every
  # phase of the feature then shares one slug (and one research file glob).
  # Keep the phase id and shorten the feature part instead.
  PHASE_BASE=$(printf '%s' "$featureSlug" | cut -c1-$((50 - ${#PHASE_SUFFIX})) | sed 's/-*$//')
  PHASE_TOPIC_SLUG="${PHASE_BASE}${PHASE_SUFFIX}"
fi
```

The slug stays unique per phase even when `featureSlug` alone is 50 characters; the descriptive `PHASE_SLUG` words are the part dropped to make room.

Phase 1's **Derive Topic Slug** step below substitutes `PHASE_TOPIC_SLUG` for a fresh derivation whenever `ROADMAP_MODE=true`. This is what keeps research filenames, `RUN_DIR`, and every other `topicSlug`-keyed artifact phase-scoped automatically, with no further changes needed anywhere else in the pipeline that already references `topicSlug` generically.
