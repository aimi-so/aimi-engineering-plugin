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

### Derive Filename

From the feature description, derive a topic slug using the five-step algorithm in
`commands/references/topic-slug.md`.

**Filename:** `.aimi/brainstorms/YYYY-MM-DD-<topic-slug>-brainstorm.md`

### Handle Filename Collision

Check if the target file already exists:

```bash
ls .aimi/brainstorms/YYYY-MM-DD-<topic-slug>-brainstorm.md 2>/dev/null
```

If it exists, append a counter: `-2`, `-3`, etc.
Example: `2026-02-27-user-auth-brainstorm-2.md`

### Create Directory

```bash
mkdir -p .aimi/brainstorms
```

### Write Document

This document is a plugin-owned artifact under `.aimi/brainstorms/`, so per the artifact-language rule (`commands/references/user-communication.md`) it is written in English.

Use the design document template:

```markdown
---
date: YYYY-MM-DD
topic: <topic-slug>
# researchPaths: emitted only when at least one researcher succeeded (non-empty list)
# Covers all four reusable kinds (codebase, best-practices, framework-docs, learnings);
# include only the entries whose agents actually ran and succeeded this session.
researchPaths:
  - .aimi/research/YYYY-MM-DD-<topic-slug>-<RUN_TS>-codebase.md
  - .aimi/research/YYYY-MM-DD-<topic-slug>-<RUN_TS>-best-practices.md
  - .aimi/research/YYYY-MM-DD-<topic-slug>-<RUN_TS>-framework-docs.md
  - .aimi/research/YYYY-MM-DD-<topic-slug>-<RUN_TS>-learnings.md
# foundationProposalPath: emitted only when Phase 3.7's validation gate passed (or the
# reuse offer was accepted). Single relative path string — not a list, unlike researchPaths
# above, since one repository has one foundation proposal.
foundationProposalPath: .aimi/research/YYYY-MM-DD-<topic-slug>-<RUN_TS>-foundation.md
prototype:
  - path: .aimi/brainstorms/prototypes/<topic-slug>-<variant-label>.html
    question_category: Aesthetic Direction
    branch: ux-only
  - path: .aimi/brainstorms/prototypes/<topic-slug>-<variant-label>.html
    question_category: Differentiation
    branch: ui-variation
  - path: <bundle-prototype-path-sanitized>
    question_category: Bundle
    branch: bundle
  - path: .aimi/brainstorms/prototypes/<topic-slug>-bundle.html
    question_category: Bundle
    branch: bundle-generated
designBundle:
  root: <bundlePath>
  readme: <path to bundle README or index file>
  chats:
    - <path to chat transcript 1>
    - <path to chat transcript 2>
  businessSpec: <path to BusinessSpec file, or null>
  designSpec: <path to DesignSpec file, or null>
phases:
  - id: 1
    name: <phase name>
    slug: <phase-slug>
    goal: <outcome statement>
    successCriteria:
      - <observable criterion 1>
      - <observable criterion 2>
    dependsOn: []
    creates:
      - identity: <artifact name, a single searchable token>
        description: <one line of prose, or "" when there is none>
    needs: []
    areas:
      - <top-level directory or glob>
  - id: 2
    name: <phase name>
    slug: <phase-slug>
    goal: <outcome statement>
    successCriteria:
      - <observable criterion 1>
    dependsOn:
      - 1
    creates: []
    needs:
      - identity: <the identity phase 1 declared, byte-for-byte>
        description: <one line of prose, or "" when there is none>
    areas:
      - <top-level directory or glob>
---

# <Topic Title>

## What We're Building
[Concise description from brainstorm dialogue]

## Why This Approach
[Fill based on how the approach was resolved:
 - **Resolved in Phase 2 questions:** "User selected [approach] during exploration. Alternatives considered: [list from question options]. Rationale: [user's reasoning or tradeoff that drove the selection]."
 - **Resolved in Phase 3 fallback:** "Approaches compared: [list]. Recommendation was [approach] because [rationale]. User confirmed."
 - **Single obvious approach:** "Single obvious approach: [approach]. [Why alternatives were not viable or relevant — e.g., codebase already uses this pattern, only one technology fits the constraint, etc.]"]

## Key Decisions
- [Decision 1]: [Rationale]
- [Decision 2]: [Rationale]

When Phase 1.8 detected greenfield structural signals and Foundation questions were answered, add at least one further bullet per answered sub-topic (stack/runtime, architecture pattern, folder/convention structure, lint/format tooling, language) here, naming the user's choice and the rationale — this lightweight trace lives in the document body itself and is distinct from the full synthesized foundation proposal artifact written separately.

When UI features were detected in Phase 1.7, include this section:

## Design Decisions
- Aesthetic direction: [when `bundleDetected=true`: fill verbatim from the bundle's chosen variant label as used in the bundle's chat transcripts (e.g., `B · Denso`) — no AskUserQuestion call; when `bundleDetected=false`: fill from chosen tone selected during Phase 2 responses]
- Reference points: [products/styles the user referenced]
- Key visual element: [what makes it memorable, from Differentiation responses]

When `bundleDetected=true` and the design-bundle researcher returned non-empty values for the corresponding payload keys, append the following optional subsections after the three bullets above. Omit any subsection whose source data is empty or null — do not emit placeholders:

### Personas
(Render only when the bundle researcher returned a non-empty personas list — sourced from `BusinessSpec § 7` when present, otherwise from chat transcripts.)
- <Persona name> — <role> — view permissions: <permissions>
- …

### View Modes
(Render only when the bundle researcher returned a non-empty view-modes list.)
- <Toggle state label> — default: <yes|no>
- …

### Layout Variation Chosen
(Render only when the bundle researcher returned a non-empty chosen-variant value.)
<Variant label selected at claude.ai/design> — <one-line rationale>

When `bundleDetected=true` and at least one of `businessSpec` or `designSpec` is non-null, include the following section between Design Decisions and Prototypes:

## Specs

Navigation index of spec files included in the design bundle. Top-level section headings are parsed inline using the pattern `^## <n>. <title>$` (numbered h2 headings).

(Render one subsection per non-null spec file.)

**BusinessSpec** — `<businessSpec path>`
- § 1 — <heading text parsed from file>
- § 2 — <heading text>
- …

**DesignSpec** — `<designSpec path>`
- § 1 — <heading text parsed from file>
- § 2 — <heading text>
- …

When one or more variant prototype files were saved (Step 7 — Variant Persistence) OR when `bundleDetected=true` and (`bundlePayload.prototypes[]` is non-empty OR `bundleGeneratedPrototypePath` is set), include this section:

## Prototypes

Standalone prototype files available as design reference:

| Path | Source | Question Category |
|------|--------|------------------|
| `.aimi/brainstorms/prototypes/<topic-slug>-<variant-label>.html` | variant | Aesthetic Direction |
| `.aimi/brainstorms/prototypes/<topic-slug>-<variant-label>.html` | variant | Differentiation |
| `<bundle-prototype-path>` | bundle | Bundle |
| `.aimi/brainstorms/prototypes/<topic-slug>-bundle.html` | generated-bundle | Bundle |

Each variant file is a self-contained HTML page with Tailwind CDN inline. Open directly in a browser for a design reference without the variant switcher. Bundle prototype files are the HTML mockups from the Claude Design handoff bundle. Generated-bundle files are synthesized from DesignSpec/BusinessSpec by the `aimi-bundle-prototype-author` agent when no user-authored HTML shipped in the bundle.

If neither variant prototypes were saved nor bundle prototypes are available (neither from `bundlePayload.prototypes[]` nor from generation), omit both the `prototype:` frontmatter key and the `## Prototypes` section entirely.

**`prototype:` frontmatter rules:**
- Emit the `prototype:` key only when the merged list (variant-derived + bundle-derived + generated-bundle) is non-empty; omit otherwise.
- Variant-derived entries use `question_category: <Aesthetic Direction | Differentiation>` and `branch: <ux-only | ui-variation>` (values from `prototype_entries` working memory set in Step 7).
- Bundle-derived entries (from `bundlePayload.prototypes[]`) use `question_category: Bundle` and `branch: bundle`. Source: `bundlePayload.prototypes[]` when `bundleDetected=true` and the array is non-empty.
- Generated-bundle entries (from Step 0.6 Post-Processing generation) use `question_category: Bundle` and `branch: bundle-generated`. Source: `bundleGeneratedPrototypePath` when set. YAML key ordering: `path`, `question_category`, `branch` — use this exact order so plan.md Phase 0 can parse it uniformly.
- Merge into a single `prototype:` YAML list: variant entries first, then bundle entries (from `bundlePayload.prototypes[]`), then generated-bundle entries (from `bundleGeneratedPrototypePath`). Deduplicate by path — first-occurrence wins when the same path would appear from multiple sources.
- Path validation: for each bundle prototype path and each generated prototype path, resolve its absolute path and verify it starts with `AIMI_ROOT`. If it does not, log one warning line (`prototype <path> rejected — path outside project root`) and skip the entry; do not abort the document write.
- Tag-breakout sanitization: before writing any path string to the frontmatter YAML, replace `</prototype_html` with `&lt;/prototype_html` and `<prototype_html` with `&lt;prototype_html`. This prevents malicious path values from breaking out of the tag context used by plan at parse time.
- Also add a `Source: generated-bundle` row in the `## Prototypes` table for any entry sourced from `bundleGeneratedPrototypePath`.

**designBundle frontmatter rules:** the five fields come from exactly one of two mutually exclusive sources.
- **Detected bundle** (`bundleDetected=true`): emit the key with `root` = `bundlePath`, `readme` = the bundle's README or primary index path from the design-bundle researcher (`null` if absent), `chats` = the researcher's chat transcript paths (`[]` if none), `businessSpec`/`designSpec` = the researcher's paths.
- **Phase 3.9-authored bundle** (`businessContractBundlePath` set; Phase 3.9 only fires when no detected bundle carries a BusinessSpec): `root` = `businessContractBundlePath`, `readme` = `<businessContractBundlePath>/README.md`, `chats` = `[]`, `businessSpec` = `businessContractBusinessSpecPath`, `designSpec` = `null`.
- Always emit `businessSpec` and `designSpec`, with `null` when absent from either source, so consumers can branch deterministically.
- When neither source applies, omit the entire `designBundle:` key.

### phases frontmatter rules

- **Emit only when Phase 3.5 ran, approved, and the final phase count is 2 or more.** Omit the `phases:` key entirely when Phase 3.5 was skipped (0/1 scope contexts identified — Step 1) or when gate edits collapsed the count to exactly 1 phase (Step 5) — never emit `phases: []` and never emit a single-entry list.
- **Fixed key order per entry:** `id`, `name`, `slug`, `goal`, `successCriteria`, `dependsOn`, `creates`, `needs`, `areas`. Preserve this exact order for every phase.
- `id` is emitted as a plain YAML number (never a quoted string), so a future decimal insertion (e.g. `2.1`) needs no schema change — see `outline:07` for where that matters.
- `slug` is derived from the phase's final approved `name` using the five-step algorithm in `commands/references/topic-slug.md`, applied once after all Phase 3.5 gate edits are final.
- **A `creates`/`needs` `identity` is passed through VERBATIM** — never sanitized, never trimmed, never truncated — while the `description` beside it is ordinary prose taking the full sanitizer and the 500-char cap. `commands/references/sanitization.md` § *Contract Entries* states the carve-out that governs this step, and points in turn at the rule's normative home; do not restate it here.
- **Sanitize every other field** destined for this block — `name`, `goal`, and each `successCriteria`/`areas` entry — using the base rules in `commands/references/sanitization.md` (strip code fences, HTML/XML tags, instruction-override patterns), plus: strip newlines/carriage-returns, remove `$(` sequences and unwrap backticked spans to their inner text (the shell command-substitution guard applied elsewhere in this command), and truncate each field (`name`: 200 chars, `goal`: 2000 chars, each `successCriteria` entry: 2000 chars, each `creates`/`needs` **description** and each `areas` entry: 500 chars — these match the caps `roadmap.py` re-applies server-side, which are 2000 for `successCriteria` and 500 for descriptions and `areas`, not one shared cap for all four; authoring-time clipping below the CLI's own cap would be irrecoverable downstream, so this step must never clip tighter than the CLI does). An `identity` is not among these fields and is never truncated — the CLI refuses one over 500 characters rather than clipping it.
- **Tag-breakout sanitization:** after the above, apply the same escape pattern used for `prototype:` path emission above — replace `</phase_data` with `&lt;/phase_data` and `<phase_data` with `&lt;phase_data` in every field value. (In practice these strings will rarely contain such sequences, but the guard is on the rail per security policy, matching the `prototype_html` precedent.)
- `dependsOn` is a YAML list of the referenced phases' `id` values (plain numbers).
- `creates` / `needs` are YAML lists of `{identity, description}` mappings and `areas` is a YAML list of strings, each following the naming conventions in the "Creates/Needs Contracts" and "Coarse File-Area Declaration" sections of `commands/references/scope-contexts.md`. Emit `description: ""` when a phase has no prose for an artifact — never omit the key, and never write `null`.
- **An identity carries only what a search could resolve** — `scope-contexts.md` § *Two rulers: the identity and the description* is the one place that says which characters that excludes, and `roadmap-init` refuses the whole payload over one that breaks the rule. Text the identity may not hold belongs in the `description`, where it is allowed: identity `cmd_clean` with description `does x; then y` is legal. Do **not** "fix" such an entry by deleting the offending character — that silently produces a different identity than the one the phase will actually deliver, which is the failure mode this whole contract exists to prevent. Rename the artifact, or move the text into the description.
- This story writes only the `phases:` frontmatter block — it never creates `.aimi/tasks/<feature>/roadmap.json` or any file under `.aimi/tasks/`. Materializing a roadmap from this block is owned by `/aimi:plan` (`outline:07`).

## Open Questions
- [Any unresolved questions]

## Next Steps
> Run `/aimi:plan` to generate implementation tasks
```

### researchPaths frontmatter rules

- **Emit only when non-empty:** Include the `researchPaths:` key in frontmatter only when the working-memory `researchPaths` list collected in Step 1c contains at least one entry. When the list is empty (all researchers were skipped or failed), omit the key entirely — do **not** emit `researchPaths: []`.
- **Four reusable kinds:** Include entries for any of the four reusable research kinds that succeeded this session — `codebase` (`-codebase.md`), `best-practices` (`-best-practices.md`), `framework-docs` (`-framework-docs.md`), and `learnings` (`-learnings.md`). Entries for kinds whose agents were skipped or failed are simply absent from the list (not emitted as empty or null). Other research kinds (e.g., `-design-bundle.md`) are not included in `researchPaths` — they are not reusable by plan.
- **Relative paths:** Each entry is a path relative to AIMI_ROOT. Use no leading `./` and no `..` components (e.g., `.aimi/research/2026-05-06-my-topic-143022-codebase.md`).
- **Deduplicate:** If the same path was collected more than once, include it only once.
- **Validate before emission:** Confirm each path exists on disk under AIMI_ROOT. Drop entries that fail this check with one warning line each: `warning: researchPaths entry not found on disk — dropping: <path>`. If validation drops all entries, omit the key entirely.
- **Backward compatibility:** Brainstorm documents that do not have the `researchPaths` key (written before this feature) are still valid. When `/aimi:plan` reads such a legacy brainstorm, it silently disables research reuse for that session — no error or warning is emitted. New brainstorms always emit this key when at least one researcher succeeds.

### foundationProposalPath frontmatter rules

- **Emit only when validated:** Include the `foundationProposalPath:` key in frontmatter only when Phase 3.7 (Foundation Synthesis) reports that the foundation artifact was written and passed its validation gate — including the case where an existing fresh proposal was reused instead of freshly synthesized. When Phase 3.7 did not fire, or its validation gate failed, omit the key entirely: no placeholder value, and no companion boolean flag (explicitly: no `foundationAccepted` key is introduced). The key's bare presence is the only signal a downstream consumer needs.
- **Single path, not a list:** Unlike `researchPaths` above — a list because it tracks four distinct research kinds — `foundationProposalPath` is a single relative path string. One repository has at most one active foundation proposal, so a list shape would be misleading here.
- **Relative paths:** The value is a path relative to AIMI_ROOT. Use no leading `./` and no `..` components — the same normalization already documented for each `researchPaths` entry above.
- **Tag-breakout sanitization:** Before writing the value into the frontmatter, replace any literal `</foundation_proposal` with `&lt;/foundation_proposal` and `<foundation_proposal` with `&lt;foundation_proposal` in the path string — `/aimi:plan`'s Phase 3d later interpolates this value into a `<foundation_proposal path="…">` wrapper attribute. (In practice a file path will never contain these sequences, but the guard must be on the rail per security policy — the same rule the `prototype:` and `phases:` frontmatter emissions above already apply.)
- **Reuse contract for plan:** `/aimi:plan`'s Phase 1.9 Greenfield Foundation Gate reads this key when present and reuses the referenced artifact instead of spawning `aimi-foundation-architect`. It falls back silently — no error, no warning — to its own architect-spawn path when the key is absent, the referenced file is missing on disk, or the file is stale.
- **Backward compatibility:** Brainstorm documents written before this feature (lacking `foundationProposalPath`) remain valid. When `/aimi:plan` reads such a legacy brainstorm, it silently disables foundation-proposal reuse for that session and degrades to its existing Phase 1.9 behavior — no error or warning is emitted, mirroring the legacy-brainstorm-without-`researchPaths` precedent above.

### Resolve Open Questions

**Before proceeding to handoff**, check the Open Questions section. If there are unresolved questions:

1. Ask the user about each open question using AskUserQuestion
2. File each answered question under a "Resolved Questions" section
3. Only proceed when Open Questions is empty or user explicitly defers them

*Agent-mode fallback: if `INTERACTIVE_MODE=agent`, move every open question to a "Deferred Questions" section (one line per question) instead of asking. Log: `agent-mode: phase-4-open-questions deferred <N> questions`.*

### Pre-Save Checklist (Blocking with Override)

Body rules above are the source of truth. The checklist below surfaces only blocking gates and net-new constraints not already enforced by the body.

Before writing the document, verify **all** of the following criteria. If any criterion fails, pause and ask the user before saving — do not silently skip.

- [ ] All critical topics addressed (Purpose, Users, Success at minimum)
- [ ] Open Questions resolved or explicitly deferred (see gate below)

### Pre-Save Blocking Gate — Open Questions

Before writing the brainstorm document, count entries under `## Open Questions` that lack one of:

- a `[resolved: <choice>]` suffix
- a `[deferred: <reason>]` suffix

If count > 0: STOP. Loop AskUserQuestion until count == 0. Each answer appends `[resolved: <choice>]` (or `[deferred: <reason>]`) to the OQ line. Re-running save on a file whose OQ lines already carry `[resolved: ...]` or `[deferred: ...]` sentinels does not re-prompt — the sentinel suffix acts as the idempotency marker.

**Bundle-source clarification:** Bundle-sourced OQs (lines that originated from `BusinessSpec § 11` or `DesignSpec § 8`) are NOT exempt — `bundleAddressedTopics` covers question categories from chat, not spec pendencies.

**Agent-mode fallback:** When running in agent-mode, auto-mark every unresolved OQ as `[deferred: agent-mode auto-defer]` before save instead of blocking on AskUserQuestion.

- [ ] At least 2 approaches compared in the "Why This Approach" section **OR** explicit justification that only one viable approach exists (e.g., "Single obvious approach: [reason]")
- [ ] Document uses correct frontmatter (date, topic)
- [ ] Next Steps references `/aimi:plan`
- [ ] Directory `.aimi/brainstorms/` exists
- [ ] No filename collision (append counter if needed)
- [ ] YAGNI applied — no unnecessary complexity

**On failure:** Use a conversational nudge for each unmet criterion:
> "Before I save the document, I noticed [specific gap]. For example: 'we only explored one approach without noting why alternatives weren't considered.' Want to address that, or should I save as-is?"

Accept the user's override ("save as-is", "proceed", etc.) and continue. The goal is awareness, not obstruction.

## Phase 5: Handoff

Display the brainstorm summary and next steps:

```
Brainstorm complete!

Document: .aimi/brainstorms/[filename].md

Key decisions:
- [Decision 1]
- [Decision 2]

Next steps:
1. **Run `/aimi:plan`** - Create implementation plan and tasks.json
2. **Continue brainstorming** - Run `/aimi:brainstorm` to explore further
3. **Review document** - Open the brainstorm file to refine manually
4. **Done for now** - Return later
```

**IMPORTANT:** Output the "Next steps" block EXACTLY as shown above — use `/aimi:` prefix (e.g., `/aimi:plan`), NOT the fully-qualified plugin name (e.g., `/aimi-engineering:plan`). Copy the block verbatim.

**Fresh session hint:** After the block, tell the person, in one sentence in their language, that this run's state is saved under `.aimi/` and that starting the next command in a fresh session (`/clear`) loses nothing and makes each of its turns cheaper. Skip it in agent mode.

**If user selects "Continue brainstorming":** Return to Phase 2 with the existing document as context. Generate targeted follow-up questions about areas not yet explored.

**If user selects "Done for now":** End the session. Display:
```
Brainstorm saved. To resume later: `/aimi:brainstorm [topic]`
To start planning: `/aimi:plan`
```

### Cleanup

Execute this sub-step **only** after Phase 5 completes successfully (brainstorm document written and user has acknowledged the handoff). Skip entirely on abnormal termination: agent crash, user abort before reaching Phase 5, or any Pre-Save Checklist failure that was not overridden.

**Step 1 — Close agent-browser session**

If a browser session was opened during Phase 2 visual variant rendering, close it now (before deleting the scratch file so no open tab references a deleted path):

```bash
agent-browser --session brainstorm-<topic-slug> close
```

If `agent-browser` was unavailable or no visual questions were rendered, skip this step silently.

**Step 2 — Prune the variant scratch file**

The scratch file (`.aimi/brainstorms/prototypes/<topic-slug>-variants.html`) is a multi-variant working file created during visual exploration. Once brainstorm completes cleanly, prune it so only the chosen per-question standalone artifacts (US-006 output) remain under `.aimi/brainstorms/prototypes/`.

Guard: only prune if at least one chosen-variant standalone file was successfully written (i.e., `prototype_entries` in working memory is non-empty). This ensures the scratch file is never the last surviving artifact.

```bash
rm -f .aimi/brainstorms/prototypes/<topic-slug>-variants.html
```

If the scratch file does not exist (e.g., no visual questions were rendered), this is a no-op — do not warn.

**Preservation guarantee:** All chosen-variant standalone files (e.g., `<topic-slug>-a-brutally-minimal.html`) and all bundle-generated prototype files (e.g., `<topic-slug>-bundle.html`) are never touched by this step. They are preserved regardless of pruning outcome.

**Skip conditions (do NOT prune):**

- Abnormal termination (crash, user abort before Phase 5, unresolved checklist failure)
- `prototype_entries` is empty (no standalone variants were written — scratch file may be the only artifact)
- Scratch file was never created (no visual questions rendered)

Note: The browser session close that previously appeared inline in Phase 2 ("When the brainstorm completes normally (Phase 5)") is now handled exclusively here in Phase 5 Cleanup. Do not close the session earlier.

## Error Handling

| Phase | Failure | Action |
|-------|---------|--------|
| Pre-Phase 0 | No feature description | Prompt user for input |
| Phase 1 | Codebase description sufficiently specific | Skip codebase researcher; best-practices researcher assessed independently |
| Phase 1 | Best-practices not needed (follow existing pattern / internal refactoring) | Skip best-practices researcher; codebase researcher assessed independently |
| Phase 1 | Both researchers skipped | Phase 2 uses topic-based questions informed by description specifics |
| Phase 1 | Codebase researcher fails or times out | Proceed with best-practices results only (or generic if both fail) |
| Phase 1 | Best-practices researcher fails or times out | Proceed with codebase results only (or generic if both fail) |
| Phase 1 | Both researchers fail | Proceed with generic topic-based questions |
| Phase 1 | Greenfield project (no codebase) | Codebase researcher returns empty; best-practices results used if available |
| Phase 1→2 | Research Adequacy gate — no actionable findings | Conversational nudge asking user for context; accept response or override and proceed |
| Phase 2→3/4 | Topic Coverage gate — required categories missing | One-time warning listing gaps; accept user answers or override to proceed |
| Phase 4 | Pre-Save Checklist — criterion not met | Conversational nudge per unmet criterion; accept user override ("save as-is") and continue |
| Phase 4 | `.aimi/brainstorms/` directory creation fails | Report error with path |
| Phase 4 | File write fails | Report error; no document saved |
| Phase 4 | Filename collision | Append counter (-2, -3) to filename |

## Important Guidelines

- **Stay focused on WHAT, not HOW** — implementation details belong in the plan
- **Apply YAGNI** — prefer simpler approaches
- **Keep outputs concise** — 200-300 words per section max
- **Never code** — just explore and document decisions
- **Gate state persistence** — Gate state persists across "Continue brainstorming" re-entry. Topics covered in the original session remain covered and are not re-checked. The Topic Coverage warning does not fire again if it already fired once in the session.

