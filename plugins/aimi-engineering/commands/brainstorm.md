---
name: aimi:brainstorm
description: Explore ideas through guided brainstorming with batched questions and codebase research
argument-hint: "[feature description] [--non-interactive]"
allowed-tools: Read, Glob, Grep, AskUserQuestion, Task, Write, Bash($AIMI_CLI:*)
---

# Aimi Brainstorm

Clarify **WHAT** to build through collaborative dialogue before planning **HOW** to build it.

## Phase Files

Most phases below are routers: a heading, an `Applies when:` condition evaluable from state this file already holds, and a `Read` line naming the phase's file under `${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/`. When the condition holds, Read that file in full before running the phase, and follow it as written. When it does not, skip the file and apply the default stated beside the condition, so every variable a later phase reads is still set. If a Read of a listed file fails, STOP and report the path; never treat a failed Read as the condition being false. **When the conversation resumes after a context compaction, re-read this router and the current phase's file before continuing.** Its text does not survive compaction; this router does.

Steps 0.5, 0.6 and the detection part of Step 0.7 stay in this file, above the first `Read`, so interactivity, models and bundle detection always run before research; the blocks that read `$ARGUMENTS` stay here too, because `$ARGUMENTS` is substituted only in a command body.

Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

## Feature Description

<feature_description> $ARGUMENTS </feature_description>

> Note: the `--non-interactive` token (if present in `$ARGUMENTS`) is stripped from the feature description in Step 0.5 before any prompt or research uses it.

**If the feature description above is empty (after stripping `--non-interactive`), ask the user:** "What do you want to explore? Describe the feature, problem or change you have in mind."

Do not continue without a feature description from the user.

## Step 0: Resolve CLI Path

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/cli-path-resolution.md` and follow the **Resolve CLI Path**
section to set `$AIMI_CLI`: its Fast path block is one Bash call, and the layers after it run one at a time only when it prints `AIMI_CLI_UNRESOLVED`.

If resolution fails, fall back to the legacy prose-only path for questions —
do not abort the brainstorm. Log: `warning: aimi-cli.sh unresolved — forcing
INTERACTIVE_MODE=picker`.

**Each Bash tool call is an isolated shell — `$AIMI_CLI` does not persist.** Re-read the cache at the top of every subsequent Bash call that needs `$AIMI_CLI`. See the **Per-Call Resolution** section of `commands/references/cli-path-resolution.md` for the one-liner and shell guard to prepend.

## Step 0.5: Resolve Interactivity Mode

Before any question is presented, resolve which mode applies.

**Scan `$ARGUMENTS` for the `--non-interactive` token** (whitespace-delimited,
case-sensitive). When present:

1. Strip it from the working copy of the feature description so it is not
   treated as part of the feature being brainstormed.
2. Forward it to the `detect-interactivity` call so agent mode is explicitly
   engaged.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
# Detect --non-interactive token (whitespace-delimited, case-sensitive)
case " $ARGUMENTS " in
  *" --non-interactive "*) NON_INTERACTIVE_FLAG="--non-interactive" ;;
  *)                        NON_INTERACTIVE_FLAG="" ;;
esac
# Strip the token from the feature description before any downstream use
FEATURE_DESCRIPTION=$(echo "$ARGUMENTS" | sed 's/\(^\| \)--non-interactive\( \|$\)/ /g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
# Resolve mode; picker is the default
INTERACTIVE_MODE=$($AIMI_CLI detect-interactivity $NON_INTERACTIVE_FLAG)
```

Use `$FEATURE_DESCRIPTION` (not `$ARGUMENTS`) in all subsequent phases where
the feature description is consumed (research prompts, topic-slug derivation,
path-hint extraction, etc.).

The result is one of:

- `picker` — **default**. All question sites below use **AskUserQuestion**
  (Claude Code) or the native `question` tool (OpenCode, wired by the
  translator). One question per tool call, lettered options.
- `agent` — reached only via **explicit opt-out**: `--non-interactive` flag,
  `AIMI_AGENT_MODE=true`, or `CI=true`. At every question site, auto-pick the
  first non-escape option and log one line into the brainstorm document's
  working memory. Never block, never prompt.

See `references/interactivity.md` for the full contract. Every question site
below includes an agent-mode fallback note describing its specific auto-pick
behavior.

## Step 0.6: Resolve Agent Models

Read and follow the **Resolve Agent Models** section of `commands/references/cli-path-resolution.md` to populate `AGENT_MODELS` and `AGENT_EFFORTS`. When resolution fails, treat every category as `"inherit"` and continue.

## Step 0.7: Detect Claude Design Bundle

Extract an optional `--root <path>` flag from `$ARGUMENTS` (do not modify
existing feature-description handling — this extraction is local to this step
only):

```bash
BUNDLE_ARG=""
# Extract --root <path> from $ARGUMENTS if present
case "$ARGUMENTS" in
  *--root*)
    BUNDLE_ARG=$(echo "$ARGUMENTS" | sed -n 's/.*--root[[:space:]]\+\([^[:space:]]*\).*/\1/p')
    ;;
esac
```

Run detection, capturing stdout and the exit status separately from stderr —
never merged, and never swallowed into an empty default the way this call
used to be:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
BUNDLE_ERR_FILE=$(mktemp)
if [ -n "$BUNDLE_ARG" ]; then
  BUNDLE_RESULT=$($AIMI_CLI detect-design-bundle --root "$BUNDLE_ARG" 2>"$BUNDLE_ERR_FILE")
else
  BUNDLE_RESULT=$($AIMI_CLI detect-design-bundle 2>"$BUNDLE_ERR_FILE")
fi
BUNDLE_STATUS=$?
BUNDLE_STDERR=$(cat "$BUNDLE_ERR_FILE" 2>/dev/null)
rm -f "$BUNDLE_ERR_FILE"
```

Derive working-memory values from the result:

- `bundleDetected` — `true` only when `BUNDLE_STATUS` is `0` and `BUNDLE_RESULT` is non-empty and is not the literal string `null`; otherwise `false`. A `BUNDLE_STATUS` of `3` carries the ambiguity payload (`{"ambiguous":true,...}`) in `BUNDLE_RESULT`, never a real bundle — that case is resolved by the "Step 0.7 Ambiguous Bundle Resolution" section below, not by this bullet.
- `bundlePayload` — the full JSON string from `BUNDLE_RESULT` when `bundleDetected=true`; empty string otherwise.
- `bundlePath` — the `path` field extracted from `bundlePayload` when `bundleDetected=true`; empty string otherwise.

When `bundleDetected=false`, all downstream phases degrade gracefully — no
error, no warning, no change to existing behavior.

### Step 0.7 Ambiguous Bundle Resolution

Applies when: `BUNDLE_STATUS` from the detection call above is not `0`. When it is `0`, skip the file: `bundleDetected` stays as derived above and the run goes straight to the next entry.
Covers: `#### Interactive Picker (status 3)`, `#### Agent Mode (status 3)`, `#### Other Detection Failure (status neither 0 nor 3)`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/step-0-7-ambiguous-bundle-resolution.md in full.

### Step 0.7 Design Handoff Offer

Applies when: `bundleDetected=false`, evaluated after the entry above has run. When `bundleDetected=true`, skip the file: no offer is made and `bundleDetected`, `bundlePayload` and `bundlePath` stay as derived.
Covers: `#### Step 1: Fire-Condition Check`, `#### Step 2: Non-Interactive Fast Path (Agent Mode)`, `#### Step 3: Interactive Offer`, `#### Step 4: Accept — Run Design Handoff and Re-Detect`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/step-0-7-design-handoff-offer.md in full.

### Step 0.7 Post-Processing: Bundle Prototype Generation Gate

Applies when: `bundleDetected=true`, evaluated after the entry above has run, so a bundle generated by the offer is seen here. When `bundleDetected=false`, skip the file: no prototype is generated, `renderBundlePending` stays `false` and `bundleGeneratedPrototypePath` stays unset.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/step-0-7-bundle-prototype-gate.md in full.

## Environment Variables

| Variable | Value | Effect |
|----------|-------|--------|
| `AIMI_AGENT_MODE` | `true` | Non-interactive fallback — auto-selects Variant A at every picker site, never blocks. Detected by `aimi-cli detect-interactivity` and reflected in `INTERACTIVE_MODE=agent`. Prefer passing `--non-interactive` to the command directly; this env var is a secondary escape hatch for automation where flag injection is not possible. |
| `AIMI_BRAINSTORM_DEBUG` | `1` | Opt-in diagnostic output. When set, the agent emits a `[brainstorm-debug] <context>: <value>` line to chat at each decision point: topic-slug derivation, per-question category classification, browser-attempt result, and variant-selection picker result. Unset (or any value other than `1`) produces no diagnostic output. |

Diagnostic lines are prefixed with `[brainstorm-debug]` so they are trivially greppable and visually distinct from normal output. They are emitted **to chat only** — never written to the brainstorm document or research files.

## Override Keywords

Certain literal phrases typed in the topic or in a reply trigger one-shot rendering overrides regardless of how the agent classified the question category.

| Phrase | Match rule | Scope | Effect |
|--------|-----------|-------|--------|
| `show variants` | Case-insensitive substring match anywhere in the topic text or the user's latest reply | Next question only — flag clears after that one question is rendered | Force-treats the next question as **Aesthetic Direction** for visual variant rendering, even when the category was classified as Functional or Scope. On activation emit exactly: `Visual override active — rendering variants for next question` |
| `vary ui` | Case-insensitive substring match anywhere in the topic text or the user's latest reply | Next visual question only — flag clears after that one visual question is rendered | Forces the UI-variation branch on the next Aesthetic Direction or Differentiation question. Non-visual questions do not consume the flag. On activation emit exactly: `UI variation override active — next visual question will vary tokens` |
| `render bundle` | Case-insensitive substring match anywhere in the topic text or the user's latest reply | One-shot per session — flag clears after a single prototype re-generation | Forces bundle prototype (re-)generation even when `prototypes[]` already contains a user-authored HTML. Checked at the bundle-detection gate (Step 0.6 post-processing) so it fires for non-visual brainstorms too. On activation emit exactly: `render-bundle override active — regenerating prototype from specs` |

**Runtime rules (one row per keyword):**

| Trigger phrase | Flag name | Activation log line (emitted once to chat) | Scope / clear condition | Precedence over Step 0a |
|---|---|---|---|---|
| `show variants` | `visualOverridePending` | `Visual override active — rendering variants for next question` | Next question only — treat that question as Aesthetic Direction (Phase 2 category gate bypass), then clear (`visualOverridePending = false`). Does not persist to subsequent questions. | **Takes explicit precedence.** When `visualOverridePending = true` on entry to Visual Variant Rendering, Step 0a is bypassed entirely and the normal Steps 0–7 flow runs. |
| `vary ui` | `varyUIPending` | `UI variation override active — next visual question will vary tokens` | Next visual question only — select the UI-variation branch (varying colors, typography, spacing, radii) within the next Aesthetic Direction or Differentiation question, then clear (`varyUIPending = false`). Non-visual questions (Purpose, Users, Constraints, Success, Edge Cases, Existing Patterns, Approach) skip without consuming the flag. | **Takes explicit precedence.** When `varyUIPending = true` on entry to Visual Variant Rendering, Step 0a is bypassed entirely and the normal Steps 0–7 flow runs. |
| `render bundle` | `renderBundlePending` | `render-bundle override active — regenerating prototype from specs` | One-shot per session — checked at the bundle-detection gate (Step 0.6 post-processing, immediately after `bundleDetected` is derived). When `renderBundlePending = true` and `bundleDetected = true`, bundle prototype generation runs and re-generates the prototype even when `prototypes[]` already contains entries, then clear (`renderBundlePending = false`). | Operates independently at Step 0.6 (bundle-detection gate), before Visual Variant Rendering. Does **not** affect Step 0a's override logic. |

**Co-occurrence semantics:**

- **`show variants` × `vary ui`:** Both flags set independently. `show variants` forces the next question to be treated as Aesthetic Direction; `vary ui` selects the UI-variation branch within it. Both clear after that single question — `visualOverridePending = false` and `varyUIPending = false`. Net effect: the next question becomes an Aesthetic Direction question rendered with UI-token variation.
- **`show variants` × `render bundle`:** Independent — `show variants` clears after the next forced visual question; `render bundle` clears after bundle prototype generation. Neither flag prevents the other from firing.
- **`vary ui` × `render bundle`:** Independent — `vary ui` clears after the next visual question's branch decision; `render bundle` clears after bundle prototype generation. Neither flag prevents the other from firing.
- **All three together:** Each flag operates independently per its own scope and clear condition. No flag prevents another from firing.

## Phase 0: Assess Requirements Clarity

Applies when: every run, after the three Step 0.7 entries above. There is no skipped case.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/phase-0-assess-clarity.md in full.

## Phase 1: Research (Conditional, Parallel)

Applies when: every run that continues past Phase 0. When Phase 0 redirected to `/aimi:plan`, skip the file; no research runs and no research variable is set.
Covers: `### Step 1a: Specificity Assessment`, `### Step 1b: Preparation and Research (Parallel)`, `### Step 1c: Research Consolidation`, `### Quality Gate: Research Adequacy`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/phase-1-research.md in full.

## Phase 1.7: UI Feature Detection

Applies when: every run. There is no skipped case.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/phase-1-7-ui-detection.md in full.

## Phase 1.8: Greenfield Foundation Detection

Applies when: every run. There is no skipped case.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/phase-1-8-foundation-detection.md in full.

## Phase 2: Batched Questions

Applies when: every run. There is no skipped case.
Covers: `### Question Generation Rules`, `#### Approach Questions`, `#### Design Questions (When UI Features Detected in Phase 1.7)`, `#### Foundation Questions (When Greenfield Structural Signals Detected in Phase 1.8)`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/phase-2-questions.md in full.

### Phase 2 Visual Variant Rendering

Applies when: a Phase 2 question falls in the Aesthetic Direction or Differentiation category, or `visualOverridePending = true`. When neither holds, skip the file: those questions are not asked and no variant rendering runs, and every other category stays text-only.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/phase-2-visual-variant-rendering.md in full.

### Phase 2 Present Questions

Applies when: every run. There is no skipped case.
Covers: `### Present Questions`, `### Adaptive Rounds`, `### Quality Gate: Topic Coverage`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/phase-2-present-questions.md in full.

## Phase 3: Resolve Approach (Fallback)

Applies when: every run. The file states its own skip conditions.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/phase-3-resolve-approach.md in full.

## Phase 3.5: Roadmap Definition Gate

Applies when: every run. The file states its own skip conditions.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/phase-3-5-roadmap-gate.md in full.

## Phase 3.6: Prototype Offer Gate

Applies when: every run. The file states its own skip conditions.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/phase-3-6-prototype-offer.md in full.

## Phase 3.7: Foundation Synthesis

Applies when: every run. It computes `phase37Verdict`, so there is no skipped case.
Covers: `### Step 1: Fire-Condition Check`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/phase-3-7-fire-check.md in full.

### Phase 3.7 Foundation Synthesis Steps

Applies when: `phase37Verdict` is `fired`. When it is `skipped`, skip the file: no synthesis runs, no artifact is written and Phase 4 proceeds as if this phase did not exist.
Covers: `### Step 2: Reuse Check`, `### Step 3: Authoring-Time Sanitization`, `### Step 4: Synthesize the 4 Sections`, `### Step 5: Validation Gate`, `### Step 6: Write the Artifact`, `### Cross-Reference: Foundation Proposal Handoff`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/phase-3-7-foundation-synthesis.md in full.

## Phase 3.8: Classification Summary Line

Applies when: every run. There is no skipped case.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/phase-3-8-classification-summary.md in full.

## Phase 3.9: Business Contract Authoring

Applies when: every run. The file states its own fire and skip conditions.
Covers: `### Step 1: Fire/Skip Conditions`, `### Step 2: Derive Repository Facts`, `### Step 3: Author the Bundle`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/phase-3-9-business-contract.md in full.

## Phase 4: Capture the Design

Applies when: every run that reaches Phase 4. There is no skipped case.
Covers: `### Derive Filename`, `### Handle Filename Collision`, `### Create Directory`, `### Write Document`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/phase-4-capture.md in full.

### Phase 4 Pre-Save Rules and Gates

Applies when: every run that reaches Phase 4, after the document template is filled and before the document is written. There is no skipped case.
Covers: `### researchPaths frontmatter rules`, `### foundationProposalPath frontmatter rules`, `### Resolve Open Questions`, `### Pre-Save Checklist (Blocking with Override)`, `### Pre-Save Blocking Gate — Open Questions`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/phase-4-pre-save.md in full.

## Phase 5: Handoff

Applies when: every run that reaches Phase 5. There is no skipped case.
Covers: `### Cleanup`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/phase-5-handoff.md in full.

## Closing: Error Handling and Guidelines

Applies when: every run. There is no skipped case.
Covers: `## Error Handling`, `## Important Guidelines`.
Before running this step, Read ${CLAUDE_PLUGIN_ROOT}/commands/references/brainstorm/closing-error-handling-and-guidelines.md in full.
