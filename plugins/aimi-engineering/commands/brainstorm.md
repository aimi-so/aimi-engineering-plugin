---
name: aimi:brainstorm
description: Explore ideas through guided brainstorming with batched questions and codebase research
argument-hint: "[feature description]"
allowed-tools: Read, Glob, Grep, AskUserQuestion, Task, Write, Bash($AIMI_CLI:*)
---

# Aimi Brainstorm

Clarify **WHAT** to build through collaborative dialogue before planning **HOW** to build it.

## Feature Description

<feature_description> $ARGUMENTS </feature_description>

**If the feature description above is empty, ask the user:** "What would you like to explore? Describe the feature, problem, or improvement you're thinking about."

Do not proceed until you have a feature description from the user.

## Step 0: Resolve CLI Path

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/cli-path-resolution.md` and follow the **Resolve CLI Path**
section to set `$AIMI_CLI`. Each layer is a separate Bash call.

If resolution fails, fall back to the legacy prose-only path for questions —
do not abort the brainstorm. Log: `warning: aimi-cli.sh unresolved — forcing
INTERACTIVE_MODE=picker`.

## Step 0.5: Resolve Interactivity Mode

Before any question is presented, resolve which mode applies:

```bash
INTERACTIVE_MODE=$($AIMI_CLI detect-interactivity)
```

The result is one of:

- `picker` — interactive user. All question sites below use **AskUserQuestion**
  (Claude Code) or the native `question` tool (OpenCode, wired by the
  translator). One question per tool call, lettered options.
- `agent` — `AIMI_AGENT_MODE=true`, `CI=true`, or non-TTY. At every question
  site, auto-pick the first non-escape option and log one line into the
  brainstorm document's working memory. Never block, never prompt.

See `references/interactivity.md` for the full contract. Every question site
below includes an agent-mode fallback note describing its specific auto-pick
behavior.

## Step 0.6: Detect Claude Design Bundle

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

Run detection (failure is silent and non-blocking):

```bash
if [ -n "$BUNDLE_ARG" ]; then
  BUNDLE_RESULT=$($AIMI_CLI detect-design-bundle --root "$BUNDLE_ARG" 2>/dev/null) || BUNDLE_RESULT=""
else
  BUNDLE_RESULT=$($AIMI_CLI detect-design-bundle 2>/dev/null) || BUNDLE_RESULT=""
fi
```

Derive working-memory values from the result:

- `bundleDetected` — `true` if `BUNDLE_RESULT` is non-empty and contains `"detected":true`; otherwise `false`.
- `bundlePayload` — the full JSON string from `BUNDLE_RESULT` when `bundleDetected=true`; empty string otherwise.
- `bundlePath` — the `path` field extracted from `bundlePayload` when `bundleDetected=true`; the value of `BUNDLE_ARG` if set and detection succeeded; empty string otherwise.

When `bundleDetected=false`, all downstream phases degrade gracefully — no
error, no warning, no change to existing behavior.

### Step 0.6 Post-Processing: Bundle Prototype Generation Gate

**Check render bundle flag (at bundle-detection gate):** Immediately after deriving `bundleDetected`, check whether the topic text or any user reply so far contains `render bundle` (case-insensitive substring). If matched and not already emitted this session, set `renderBundlePending = true` and emit `render-bundle override active — regenerating prototype from specs` once to chat.

**Generation condition:** When `bundleDetected=true` AND (the `prototypes[]` array in `bundlePayload` is empty OR `renderBundlePending = true`), run bundle prototype generation:

1. **Check status:**
   ```bash
   STATUS_JSON=$($AIMI_CLI bundle-prototype-status \
     --bundle "<bundlePath>" \
     --topic "<topic-slug>" \
     $([ "$renderBundlePending" = "true" ] && echo "--force"))
   ```
   Parse `STATUS_JSON` for:
   - `needs_generation` (bool)
   - `view_list` (array of `{name, source_section}`)
   - `view_source` (`"designSpec"` | `"businessSpec"` | `"none"`)
   - `output_path` (string)

2. **When `view_source` is `"none"`:** Emit exactly:
   `bundle prototype generation skipped — no view list in DesignSpec § 4 or BusinessSpec § 5/§ 6`
   Then proceed without generation. Do not set `bundleGeneratedPrototypePath`. Skip the remaining sub-steps.

3. **When `needs_generation` is `true`:** Create the output directory and spawn the author agent:
   ```bash
   mkdir -p .aimi/brainstorms/prototypes
   ```
   Parse additional fields from `STATUS_JSON`:
   - `sidecar_path` — the sidecar JSON path returned by `bundle-prototype-status`
   Extract from `bundlePayload`:
   - `designSpec` → `designSpecPath` (may be null)
   - `businessSpec` → `businessSpecPath` (may be null)
   - `chats[]` → `chatPaths` (may be empty)

   **Path guard:** Resolve `output_path` to an absolute path and verify it starts with `AIMI_ROOT`. If it does not, log one warning line (`bundle prototype generation skipped — output path outside project root: <output_path>`) and abort generation for this session without clearing `renderBundlePending`.

   Spawn the bundle prototype author agent:
   ```
   Task subagent_type="aimi-engineering:research:aimi-bundle-prototype-author"
     prompt: "Generate a prototype HTML for the design bundle.
              bundlePath=<bundlePath>
              viewList=<view_list as JSON array of name strings>
              viewSource=<view_source>
              designSpecPath=<designSpecPath or empty>
              businessSpecPath=<businessSpecPath or empty>
              chatPaths[]=<chatPaths as JSON array>
              outputPath=<output_path>"
   ```

   After the agent completes, verify the file was written:
   ```bash
   ls "<output_path>" 2>/dev/null
   ```
   If the file is missing, log one warning line (`bundle prototype generation failed — agent did not write output: <output_path>`) and proceed without a generated prototype.

4. **When generation succeeds** (file confirmed on disk):

   a. **Finalize the sidecar:** Compute hashes and call:
      ```bash
      BUNDLE_HASH=$(sha256sum "<bundlePath>/README.md" 2>/dev/null | awk '{print $1}' || echo "")
      DESIGN_HASH=$([ -n "<designSpecPath>" ] && sha256sum "<designSpecPath>" 2>/dev/null | awk '{print $1}' || echo "")
      BUSINESS_HASH=$([ -n "<businessSpecPath>" ] && sha256sum "<businessSpecPath>" 2>/dev/null | awk '{print $1}' || echo "")
      $AIMI_CLI bundle-prototype-finalize \
        --topic "<topic-slug>" \
        --bundle-hash "$BUNDLE_HASH" \
        --design-spec-hash "$DESIGN_HASH" \
        --business-spec-hash "$BUSINESS_HASH" \
        --view-list '<view_list as JSON array>' \
        --source-command brainstorm
      ```

   b. **Register the generated prototype:** Store `output_path` as `bundleGeneratedPrototypePath` in working memory. Append one entry to `prototype_entries`:
      ```
      { path: "<output_path>", question_category: "Bundle", branch: "bundle-generated" }
      ```
      This entry uses the same YAML key ordering as variant-derived entries (path, question_category, branch) so that plan.md Phase 0 can parse it uniformly.

   c. **Clear the flag:** Set `renderBundlePending = false`.

5. **When `needs_generation` is `false`** (and `renderBundlePending` was not `true`): Generation is not needed — the sidecar already records an up-to-date prototype. Use the `output_path` from `STATUS_JSON` as a reference for downstream phases if the file exists on disk. Do not append to `prototype_entries` here — the path will be picked up through `bundlePayload.prototypes[]` in Phase 4 as a normal bundle-derived entry.

**Tag-breakout sanitization:** Before writing `bundleGeneratedPrototypePath` into any YAML frontmatter key (see Phase 4 `prototype:` frontmatter rules), replace `</prototype_html` with `&lt;/prototype_html` and `<prototype_html` with `&lt;prototype_html` in the path string. (In practice a file path will never contain these sequences, but the guard must be on the rail per security policy.)

## Environment Variables

| Variable | Value | Effect |
|----------|-------|--------|
| `AIMI_AGENT_MODE` | `true` | Non-interactive fallback — auto-selects Variant A at every picker site, never blocks. Detected by `aimi-cli detect-interactivity` and reflected in `INTERACTIVE_MODE=agent`. |
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

Evaluate whether brainstorming is needed based on the feature description.

**Clear requirements signals:**
- Specific acceptance criteria provided
- Referenced existing patterns to follow
- Described exact expected behavior
- Constrained, well-defined scope

**If requirements are already clear:**
Use **AskUserQuestion** to suggest: "Your requirements seem detailed enough to proceed directly to planning. Should I run `/aimi:plan` instead, or would you like to explore the idea further?"

*Agent-mode fallback: if `INTERACTIVE_MODE=agent`, auto-proceed to `/aimi:plan` (the non-disruptive default). Log: `agent-mode: phase-0-plan-redirect auto-proceeded to plan`.*

**If unclear or vague:** proceed to Phase 1.

## Phase 1: Research (Conditional, Parallel)

### Step 1a: Specificity Assessment

Before spawning research agents, assess the feature description against **two independent criteria** — one for codebase research, one for best-practices research. Each agent may be independently skipped or run.

#### Codebase Research Assessment

| Bucket | Signals | Action |
|--------|---------|--------|
| **Skip** | Description references specific file paths, names technologies/frameworks, or describes exact patterns to follow | Skip codebase researcher |
| **Run** | Description is vague, conceptual, or exploratory (e.g., "improve performance", "add a settings page") | Run codebase researcher |
| **Run** | Uncertain whether description is specific enough | Run codebase researcher |

#### Best-Practices Research Assessment

| Bucket | Signals | Action |
|--------|---------|--------|
| **Skip** | User explicitly says "follow existing pattern exactly" or description is purely internal refactoring (renaming, moving files, deleting dead code) | Skip best-practices researcher |
| **Run** | Feature involves new functionality, external integrations, user-facing behavior, or architectural decisions | Run best-practices researcher |
| **Run** | Uncertain whether external practices are relevant | Run best-practices researcher |

Do not mention skip decisions to the user — just proceed seamlessly.

**When both researchers are skipped:** Phase 2 generates topic-based questions that reference the specific technologies, file paths, or patterns the user already mentioned in their description. These are not generic fallback questions — they are informed by the concrete details the user provided.

**When only codebase researcher is skipped:** Phase 2 questions are informed by external best practices plus the concrete details the user provided.

**When only best-practices researcher is skipped:** Phase 2 questions are informed by codebase patterns plus the concrete details the user provided.

### Step 1b: Preparation and Research (Parallel)

#### Derive Topic Slug

From the feature description, derive a topic slug (needed for research output paths)
using the five-step algorithm in `commands/references/topic-slug.md`.

If `AIMI_BRAINSTORM_DEBUG=1`: emit `[brainstorm-debug] topic-slug: <derived-slug>` to chat.

#### Generate Run Discriminator

Generate a single timestamp for this brainstorm run to prevent same-day re-runs from overwriting prior research files:

```bash
RUN_TS=$(date +%H%M%S)
```

Store `RUN_TS` and use it in **all** research agent prompts for this run.

#### Create Research Directory

```bash
mkdir -p .aimi/research
```

#### Extract Path Hints

Before spawning research agents, extract file-path hints from the feature description so the codebase researcher can scope its search rather than globbing the entire repo.

**Regex:** Match tokens that look like file paths or directory globs — tokens containing `/` or `*` that do not start with a URL scheme (`http://`, `https://`, `ftp://`).

Concretely, scan `$ARGUMENTS` for whitespace-delimited tokens that satisfy **all** of these:

1. Contains at least one `/` or `*` character.
2. Does not start with `http://`, `https://`, or `ftp://`.
3. Does not start with `/etc/`.
4. Does not contain `..` (any path traversal component).
5. Is not inside a code fence (skip tokens between `` ``` `` or `` ` `` delimiters).
6. Does not contain an HTML tag (`<` or `>`).

**Sanitize each surviving token** using the base rules plus the path-hints extension defined in
`commands/references/sanitization.md`.

Store the surviving tokens as `pathHints` (a list). If no tokens survive, set `pathHints` to an empty list.

#### Run Research Agents

Spawn the selected research agents **in parallel** using the Task tool:

```
Task subagent_type="aimi-engineering:research:aimi-codebase-researcher"
  prompt: "Understand existing patterns related to: [feature description].
           Look for: similar features, established patterns, CLAUDE.md guidance,
           relevant file paths, technology choices.
           researchDepth=standard
           topicSlug=<topic-slug>
           [If pathHints is non-empty]: paths: [<comma-joined pathHints>]
           outputPath: .aimi/research/YYYY-MM-DD-<topic-slug>-[RUN_TS]-codebase.md"

Task subagent_type="aimi-engineering:research:aimi-best-practices-researcher"
  prompt: "Research current best practices for: [feature description].
           Look for: industry standards, community conventions, recommended
           patterns, common pitfalls, and authoritative guidance.
           researchDepth=standard
           topicSlug=<topic-slug>
           outputPath: .aimi/research/YYYY-MM-DD-<topic-slug>-[RUN_TS]-best-practices.md"

Task subagent_type="aimi-engineering:research:aimi-design-bundle-researcher"
  prompt: "Analyse the Claude Design bundle to extract design intent and chat
           context relevant to: [feature description].
           bundlePath=<bundlePath>
           topicSlug=<topic-slug>
           RUN_TS=[RUN_TS]
           outputPath: .aimi/research/YYYY-MM-DD-<topic-slug>-[RUN_TS]-design-bundle.md"
```

Spawn the design-bundle researcher **only when `bundleDetected=true`**. When
`bundleDetected=false`, omit this Task call entirely — no error, no log entry.

Only spawn the agents that were not skipped in Step 1a.

**Input sanitization:** Before interpolating the feature description into **each** research agent
prompt, apply the base rules from `commands/references/sanitization.md` identically to both
agent prompts.

### Step 1c: Research Consolidation

Merge the results from whichever agents completed successfully into a structured summary. Handle all four permutations:

| Codebase Result | Best-Practices Result | Action |
|-----------------|----------------------|--------|
| **Success** | **Success** | Merge both into structured summary; surface conflicts between internal patterns and external best practices as candidate questions for Phase 2 |
| **Success** | **Failed/Skipped** | Use codebase findings only; populate Key Patterns and File References sections |
| **Failed/Skipped** | **Success** | Use best-practices findings only; populate Key Patterns and External Insights sections |
| **Failed/Skipped** | **Failed/Skipped** | Proceed with no research context; Phase 2 falls back to generic topic-based questions (existing behavior) |

#### Structured Consolidation Schema

Organize the merged findings into these sections:

1. **Key Patterns**: Relevant codebase patterns, naming conventions, architectural decisions, and best-practice patterns discovered by either agent
2. **Conflicts**: When both agents succeed, compare their findings. If internal codebase patterns diverge from external best practices (e.g., the codebase uses pattern A but best practices recommend pattern B), capture each conflict as a candidate question for Phase 2. Present these as explicit choices: "The codebase currently uses [X], but industry best practices recommend [Y]. Which approach should we follow?"
3. **File References**: Specific file paths, modules, and code locations relevant to the feature (from codebase researcher)
4. **External Insights**: Industry standards, community conventions, recommended patterns, common pitfalls (from best-practices researcher)
5. **Design Intent** _(populated only when `bundleDetected=true` and the design-bundle researcher succeeded)_: Chat-transcript themes, stated design rationale, visual preferences, and UX intent extracted from the Claude Design bundle. Store the list of addressed topic categories from the bundle as `bundleAddressedTopics` in working memory — this list is consumed by the Phase 2 topic-coverage gate. When the design-bundle researcher failed or was skipped, omit this section entirely; do not write a placeholder.

This structured summary feeds into Phase 2 question generation and Phase 4 design document capture.

#### Collect researchPaths

After merging findings, collect the output paths of every researcher that succeeded into a `researchPaths` working-memory list:

1. For each researcher that completed successfully (codebase and/or best-practices), record the `outputPath` that was passed to that agent's prompt (e.g., `.aimi/research/YYYY-MM-DD-<topic-slug>-[RUN_TS]-codebase.md`).
2. Paths are relative to AIMI_ROOT (no leading `./`, no `..` components).
3. Deduplicate: if the same path appears more than once, keep only one entry.
4. Validate each path exists on disk under AIMI_ROOT before adding it to the list. Drop any path that fails this check and emit one warning line per dropped entry: `warning: researchPaths entry not found on disk — dropping: <path>`.
5. If all researchers were skipped or failed (the "Failed/Skipped + Failed/Skipped" row), the list remains empty.

Store the final list in working memory as `researchPaths`. It is consumed when writing the brainstorm document in Phase 4.

### Quality Gate: Research Adequacy

Before generating questions, review the research output from Phase 1.

**Check:** Did research produce at least one **actionable finding** — a specific file path, pattern name, technology reference, or best practice?

- **If yes:** Proceed to Phase 2 normally. Research findings inform question generation.
- **If no (and research was run):** Use a conversational nudge before continuing:
  > "Before we continue, I notice the research didn't surface concrete patterns or references in the codebase. Could you point me to any relevant files or existing features I should look at? Or if you'd prefer, we can proceed with general exploration."
  Accept the user's response (additional context or confirmation to proceed) and continue to Phase 2.
- **If research was skipped by specificity logic (Step 1a):** This gate is **advisory only** — the user already provided specific details that made research unnecessary. Proceed to Phase 2 without prompting.

## Phase 1.7: UI Feature Detection

Scan the feature description for visual/UI keywords using case-insensitive whole-word matching (regex word boundaries `\b`).

**Keyword list:** page, modal, dashboard, form, component, layout, ui, design

**Co-occurrence rule:** The keyword "design" alone does not trigger detection — it requires co-occurrence with at least one other keyword from the list. This prevents false positives from phrases like "system design" or "API design."

| Bucket | Signals | Action |
|--------|---------|--------|
| **Detect** | Feature description contains at least one keyword (with "design" requiring co-occurrence) | Mark the feature as UI-relevant; Phase 2 includes design-thinking questions covering visual hierarchy, interaction patterns, responsive behavior, and accessibility |
| **Skip** | No keywords match, or "design" appears alone without another keyword | Proceed unchanged — no design-category questions injected into Phase 2 |

If the feature description contains UI keywords, Phase 2 generates additional questions targeting design categories (visual hierarchy, interaction patterns, responsive behavior, accessibility) alongside the standard topic categories. These design questions follow the same format rules: 3-4 options, under 20 words question text, under 15 words per option, "Other" escape hatch.

When no keywords match, brainstorm proceeds unchanged — Phase 2 covers only the standard topic categories with no mention of design categories.

## Phase 2: Batched Questions

Using the user's feature description and consolidated research findings (from Step 1c), generate **3-5 batched multiple-choice questions**. Include any conflict-based questions surfaced during consolidation.

### Question Generation Rules

- Questions are informed by research findings when available (contextual options)
- Fall back to generic topic-based questions when research is empty
- Cover topic categories: Purpose, Users, Constraints, Success, Edge Cases, Existing Patterns, Approach (and when UI features detected: Aesthetic Direction, Differentiation)
- 3-4 options per question (not more)
- Question text under 20 words
- Option text under 15 words
- Every question includes an "Other: [please specify]" escape hatch
- When research returns findings, make option A the "follow existing pattern" choice and reference specific patterns found by the research agent in the question text
- **Design Intent coverage gate:** When `bundleDetected=true` and Step 1c populated `bundleAddressedTopics`, treat every category present in that list as already addressed. Do not generate questions for those categories — the bundle's chat transcript has already surfaced the user's intent. Use the Design Intent section from Step 1c as a distinct context block when authoring questions for any remaining categories.

#### Approach Questions

When consolidated research (Step 1c) reveals **multiple valid approaches**, include **one** approach selection question in the current batch. Rules:

- Options are derived from research findings, each with a brief tradeoff hint (e.g., "Event-driven — scales independently, more complex")
- Follow standard format: 3-4 options, under 20 words question text, under 15 words per option, last option is "Other: [please specify]"
- Maximum **1 approach question per batch** — do not crowd out other topic categories
- **Do NOT generate an approach question when:**
  - Research context is insufficient (both agents failed/skipped or returned no approach-relevant findings) — rely on Phase 3 fallback instead
  - Research reveals a clearly superior single approach — skip the question and let Phase 3 handle it (or skip entirely)

#### Design Questions (When UI Features Detected in Phase 1.7)

When UI features were detected in Phase 1.7, include design-category questions in the batch alongside standard topic questions. These follow the same format rules.

**Example Aesthetic Direction question:**

```
N. What visual tone fits this interface best?
   A. Brutally minimal — clean, sparse, essential
   B. Retro-futuristic — nostalgic yet forward
   C. Luxury/refined — elegant, premium feel
   D. Other: [please specify]
```

**Example Differentiation question:**

```
N. What should make this interface memorable?
   A. Distinctive animation or motion
   B. Bold typography choices
   C. Unique layout composition
   D. Other: [please specify]
```

#### Visual Variant Rendering (Aesthetic Direction and Differentiation only)

> Full authoring contract — HTML skeleton, slug sanitization, HTML-escaping rules, token extraction, switcher wiring, and browser session lifecycle — lives in `commands/references/visual-variants.md`. This sub-step is the integration point; do not re-implement any detail here.

**`show variants` override check (runs before category classification):** Before evaluating whether a question is Aesthetic Direction or Differentiation, check whether `visualOverridePending = true` (set when the user's topic or latest reply contained `show variants` — see "Override Keywords" section above). If the flag is set, treat this question as **Aesthetic Direction** for the purpose of visual rendering, then clear the flag (`visualOverridePending = false`). This bypass applies only to the single next question; all subsequent questions revert to normal category classification.

When the agent reaches an **Aesthetic Direction** or **Differentiation** question (and only those two categories, or when the `show variants` override is active), execute the following steps **before** presenting the question to the user. If `AIMI_BRAINSTORM_DEBUG=1`: emit `[brainstorm-debug] category: <category-name> — visual rendering path triggered` to chat (or `[brainstorm-debug] category: <category-name> — visual rendering skipped` when the question does not fall into either category). All slug sanitization, HTML-escaping, and token extraction rules are defined in `references/visual-variants.md`; this sub-step is the call sequence only.

**Step 0a — Bundle early-exit check**

Before any other step in Visual Variant Rendering, check override flags and bundle state:

1. **Override check (takes precedence):** If `visualOverridePending = true` OR `varyUIPending = true`, skip this entire Step 0a and proceed to Step 0b — the normal Steps 0–7 flow runs regardless of bundle state (see Override Keywords section for the precedence rule).

2. **Bundle early-exit:** If `bundleDetected=true` (and neither override flag is set):

   a. **Select the bundle HTML:** Check whether `bundleGeneratedPrototypePath` is set in working memory (populated by Step 0.6 Post-Processing when `prototypes[]` was empty at detection time and generation succeeded). If set, use `bundleGeneratedPrototypePath` as the selected HTML path and use `question_category: "Bundle"` with `branch: "bundle-generated"`. Otherwise, among `.html` files in the bundle's `project/` directory (within `bundlePath`), prefer files whose basename contains `standalone` (case-insensitive); if none match, use the first non-standalone `.html` file alphabetically (and use `question_category: "Aesthetic Direction"` with `branch: "bundle"`).

   b. **Wrap as prototype entry:** Store one entry in `prototype_entries` working memory using the path and metadata resolved in sub-step (a):
      - When sourced from `bundleGeneratedPrototypePath`:
        ```
        { path: "<bundleGeneratedPrototypePath>", question_category: "Bundle", branch: "bundle-generated" }
        ```
      - When sourced from the bundle's `project/` directory:
        ```
        { path: "<selected html path>", question_category: "Aesthetic Direction", branch: "bundle" }
        ```

   c. **Agent-mode log (emitted at most once per session):** Log one line to the brainstorm document's working memory: `agent-mode: bundle-detected — skipped variant authoring, using bundle HTML <path>`. Then invoke the once-per-session echo helper with flag `echoedBundleEarlyExit` and message `agent-mode: bundle-detected — skipped variant authoring, using bundle HTML <path>`. Initialize `echoedBundleEarlyExit = false` when Step 0b initializes working memory.

   d. **Return from Visual Variant Rendering:** Skip Steps 0b through 7 entirely for this question. Proceed directly to presenting the (text-only) question.

3. **When `bundleDetected=false`:** Step 0a is a no-op — proceed to Step 0b as normal.

**Step 0b — Pre-flight browser availability (run once per brainstorm session)**

Before processing the very first Aesthetic Direction or Differentiation question, run this check **exactly once**. On all subsequent visual questions, skip directly to Step 0 — the cached result is already in working memory.

1. **Predict visual questions.** Based on the brainstorm topic and the question-category plan assembled in Phase 2, determine whether any Aesthetic Direction or Differentiation questions are expected. If none are predicted, skip this entire step — emit nothing to chat, set `browserAvailable = false`, `browserSkipReason = "no visual questions"`, and proceed. This prevents false alarms on non-visual brainstorms.

2. **If visual questions are expected, run the availability check:**

   ```bash
   command -v agent-browser
   ```

   Apply the same heuristic used in Step 4:
   - `agent-browser` not found → reason: `agent-browser not installed`
   - `DISPLAY` unset **and** not running under a known GUI host (macOS / Windows) → reason: `DISPLAY unset`
   - `CI=true` is set → reason: `CI mode`

3. **Emit exactly one line to chat** (not to the brainstorm document):
   - On success: `Visual preview: ready`
   - On failure: `Visual preview: disabled (<reason>)` where `<reason>` is the short cause from step 2 (e.g., `Visual preview: disabled (agent-browser not installed)`)

4. **Cache the outcome in working memory:**
   - `browserAvailable` (bool): `true` if the check passed, `false` otherwise.
   - `browserSkipReason` (string): empty string on success; the short cause string on failure.
   - `echoedBrowserUnavailable` (bool): `false` — guards the once-per-session chat echo for the "agent-browser unavailable" event.
   - `echoedSessionLost` (bool): `false` — guards the once-per-session chat echo for the "agent-browser session lost" event.
   - `echoedPickerUnavailable` (bool): `false` — guards the once-per-session chat echo for the "picker unavailable — auto-selected variant A" event.

   Step 4 and all subsequent visual-question handling must read `browserAvailable` from working memory — do **not** re-run `command -v agent-browser` or re-evaluate the DISPLAY / CI heuristic on later questions.

**Once-per-session echo helper:** Given a flag name `F` and a message `M`: if `F` is `false`, emit `M` to chat and set `F = true`. Subsequent invocations with the same `F` in the same session are silent. This helper is used at all four `echoed*` call sites below — only the chat-echo+flag-set pattern is consolidated; the separate lines that write to the brainstorm document's working memory are not affected.

**Step 0 — Component-shell scan (best-effort)**

Sample 2–3 representative component files from the target project to extract the structural idioms variants should mimic. Scan is optional; skip silently on any failure.

**DesignSpec § 1 preference:** When `bundleDetected=true` and the design-bundle researcher returned a non-null `designSpec` path, read the component-shell structural idioms from `DesignSpec § 1` first (design-token and component-skeleton section). Use those definitions as `component_shell_notes` directly — do not scan project component files for this step. Fall back to the file-scan below only if `DesignSpec § 1` is absent or unreadable.

1. Look under `src/components/`, `app/components/`, `components/`, or `src/app/` (first directory that exists) for `.tsx`, `.jsx`, `.vue`, or `.svelte` files.
2. Select up to 3 files: prefer one matching a form-like name (`Form.*`, `Input.*`, `Login.*`), one matching a layout-like name (`Layout.*`, `Sidebar.*`, `Page.*`), and one matching a card-like name (`Card.*`, `Item.*`, `List.*`). Fall back to any 1–3 components if the name hints fail.
3. Read each file as plain text (do not execute or import). Extract:
   - The outermost wrapper element (tag + top-level classes/structure idioms).
   - Class recipes that recur across components (e.g., `rounded-xl shadow-sm border` combinations, spacing scales like `p-6 gap-4`).
   - Primary-action class recipes (styles applied to `<button type="submit">` or elements named like `PrimaryButton`).
4. Store findings as `component_shell_notes` in working memory. These are passed as structural constraints into Step 3 below (see `references/visual-variants.md` → Structural Guidance → Step 4).

Any read error, missing directory, or inability to parse cleanly → skip silently; no warning. Component-shell guidance is additive, never a precondition.

**Step 1 — Validate topic slug**

Use the slug derived in Phase 1 Step 1b and apply the Topic-Slug Sanitization algorithm from `references/visual-variants.md`. **Order matters:** run the sanitization algorithm first (lowercase → replace whitespace → strip non-alphanumeric → collapse dashes → trim), then validate the result against `^[a-z0-9][a-z0-9-]*$` and the traversal checks (`..`, leading `/`, any `/`).

If the slug fails validation: log a warning ("Visual path skipped — invalid topic slug: `<raw>`"), skip Steps 2–5 for this question, and fall back to text-only (present the question normally without any HTML output).

**Step 2 — Token extraction (best-effort)**

**DesignSpec § 1 preference:** When `bundleDetected=true` and the design-bundle researcher returned a non-null `designSpec` path, extract colors, fonts, radii, spacing, shadows, transitions, screens, and dark-mode tokens exclusively from `DesignSpec § 1` (design tokens section). Write the token sidecar JSON with `"fallbacks": []` — tokens sourced from DesignSpec are explicitly authoritative; no family falls back to Tailwind CDN defaults. Skip the project-source probe order below for this case.

When `designSpec` is null or unavailable, probe project sources in the fixed precedence order defined in `references/visual-variants.md` (Token Extraction section). Extract colors, fonts, radii, spacing, shadows, transitions, screens, and dark-mode tokens. Any probe failure is silently skipped. Use Tailwind CDN defaults for any family that yields no tokens, and emit the required warning line per family that fell back.

Write the token sidecar JSON to `.aimi/brainstorms/prototypes/<topic-slug>-tokens.json` (shape and rules in `references/visual-variants.md` → Token Sidecar JSON).

**Step 2.5 — Variant branch decision**

Immediately after the token sidecar JSON is written (read-after-write is synchronous), read `.aimi/brainstorms/prototypes/<topic-slug>-tokens.json` from disk and compute the branch.

1. **Compute `tokensFallbackAll`:** Inspect the `fallbacks` array in the sidecar JSON. Set `tokensFallbackAll = true` if and only if all three of `"colors"`, `"fonts"`, and `"radii"` appear in that array; otherwise `tokensFallbackAll = false`.

2. **Assign `variantBranch` and record reason:**
   - If `varyUIPending` is `true` (flag was set by a prior interaction): set `variantBranch = "ui-variation"`, record `variantBranchReason = "vary-ui-override"`, then **clear `varyUIPending` (set it to `false`)** — this is a one-shot consumption; the flag must not trigger again for subsequent questions in the same session.
   - Else if `tokensFallbackAll` is `true`: set `variantBranch = "ui-variation"`, record `variantBranchReason = "auto-fallback"`.
   - Otherwise: set `variantBranch = "ux-only"`, record `variantBranchReason = "default"`.

3. **Store in working memory:** `variantBranch` and `variantBranchReason` are retained for use in Step 3 and Step 6 below.

4. **Debug emission:** If `AIMI_BRAINSTORM_DEBUG=1`, emit the following line to chat (not to the brainstorm document):
   ```
   [brainstorm-debug] variant-branch: <ux-only|ui-variation> (reason: <auto-fallback|vary-ui-override|default>)
   ```
   Replace the angle-bracket placeholders with the actual values of `variantBranch` and `variantBranchReason`.

**Step 3 — Author variant HTML**

Create the prototype directory:

```bash
mkdir -p .aimi/brainstorms/prototypes
```

For the **first** visual question, write the full file using the Switcher Skeleton from `references/visual-variants.md`, emitting resolved tokens as CSS custom properties on `:root` per the Structural Guidance section. For **subsequent** visual questions, **append** a new `<section data-question="...">` block to the existing file — do not truncate.

Follow the Structural Guidance section of `references/visual-variants.md`: infer the dominant UI pattern, pick a canonical shape (form/card/nav/hero/modal/table/layout-with-sidebar), and author every variant in that shape. Apply `component_shell_notes` from Step 0 as additional structural constraints.

**Apply the design axes determined by `variantBranch` (set in Step 2.5):**
- **`variantBranch == "ux-only"`:** Apply the UX-branch axes from Step 2 of `references/visual-variants.md` — vary layout, information hierarchy, interaction flow, and content structure. Do not change brand color, typography family, or border-radius between variants; those tokens remain constant across all variants in this question.
- **`variantBranch == "ui-variation"`:** Apply the UI-branch axes from Step 2 of `references/visual-variants.md` — vary color palette, typography pairing, border-radius, surface treatment, and visual weight in addition to layout. Resolved token CSS custom properties may differ across variants in this question.

Author **2–4 variants** per question based on the design axes available (default 2 for binary contrast; add 3–4 only when additional directions genuinely add value).

HTML-escape every user-supplied string before interpolation per `references/visual-variants.md` (HTML-Escaping section). Do not duplicate the escaping table here.

Output path: `.aimi/brainstorms/prototypes/<topic-slug>-variants.html`

**Step 4 — Open or reload browser session**

Consult the `browserAvailable` flag set by Step 0b (pre-flight check). Do **not** re-run `command -v agent-browser` or re-evaluate the DISPLAY / CI heuristic here — that check ran once at session start.

- **`browserAvailable` is `false`** (any reason captured in `browserSkipReason`): Skip all browser calls. Log exactly one warning line to the brainstorm document: `agent-browser unavailable — variants at .aimi/brainstorms/prototypes/<topic-slug>-variants.html`. Then invoke the once-per-session echo helper with flag `echoedBrowserUnavailable` and message `agent-browser unavailable — variants at .aimi/brainstorms/prototypes/<topic-slug>-variants.html`. Continue text-only for all visual questions.
- **First visual question (session open, idempotent):** If a session named `brainstorm-<topic-slug>` already exists, reload it; otherwise open a new headed session:
  ```bash
  agent-browser --headed --session brainstorm-<topic-slug> open file://$(pwd)/.aimi/brainstorms/prototypes/<topic-slug>-variants.html
  ```
  Re-runs of the brainstorm for the same topic reuse the existing session instead of erroring on a duplicate session name.
- **Subsequent visual questions:** Reuse the same session name and reload:
  ```bash
  agent-browser --session brainstorm-<topic-slug> reload
  ```
- **Session call fails (reload returns non-zero):** Retry once with a fresh session name by appending `-2` suffix:
  ```bash
  agent-browser --headed --session brainstorm-<topic-slug>-2 open file://$(pwd)/.aimi/brainstorms/prototypes/<topic-slug>-variants.html
  ```
  If the retry also fails, degrade to text-only for all remaining visual questions — stop attempting any further `agent-browser` calls for this brainstorm session. Log the file path once at the point of degradation: `agent-browser session lost — variants at .aimi/brainstorms/prototypes/<topic-slug>-variants.html`. Then invoke the once-per-session echo helper with flag `echoedSessionLost` and message `agent-browser session lost — variants at .aimi/brainstorms/prototypes/<topic-slug>-variants.html`. (See `references/visual-variants.md` "Fallback: mid-session crash" section for the canonical description of this two-step flow.)

If `AIMI_BRAINSTORM_DEBUG=1`: emit `[brainstorm-debug] browser-attempt: <outcome>` to chat, where `<outcome>` is one of `skipped (browserAvailable=false, reason: <browserSkipReason>)`, `opened new session brainstorm-<topic-slug>`, `reloaded session brainstorm-<topic-slug>`, `retried with session brainstorm-<topic-slug>-2`, or `degraded to text-only after retry failure`.

**Step 5 — Present the question**

Present the Aesthetic Direction or Differentiation question to the user as normal (numbered item with lettered options, "Other" escape hatch). The rendered HTML gives the user a live visual preview alongside the text question.

**Step 6 — Variant Selection**

After the browser session is open and variants are visible, ask the user which variant best fits their vision. Use **AskUserQuestion** with one option per authored variant, labeled in the format `A — <short name>`, `B — <short name>`, etc. (one letter per variant), plus a final option `None — show again / revise`. The question text is: `Which variant best fits your vision?`

For 3 authored variants named "Brutally minimal", "Retro-futuristic", "Luxury/refined", the offered options are: `A — Brutally minimal`, `B — Retro-futuristic`, `C — Luxury/refined`, `None — show again / revise`.

**Agent-mode fallback (non-interactive):**

If the picker tool is unavailable (running under a host that does not support it) or the session is explicitly non-interactive (`AIMI_AGENT_MODE=true` or equivalent), auto-select Variant A deterministically. Log one line to the brainstorm document: `agent-mode: picker unavailable — auto-selected variant A`. Then invoke the once-per-session echo helper with flag `echoedPickerUnavailable` and message `agent-mode: picker unavailable — auto-selected variant A`. Skip the `None — show again / revise` branch entirely in this mode.

If `AIMI_BRAINSTORM_DEBUG=1`: emit `[brainstorm-debug] variant-choice: <chosen-option>` to chat immediately after AskUserQuestion returns (or after the agent-mode auto-pick), where `<chosen-option>` is the full option string the user selected (e.g., `A — Brutally minimal`) or `agent-mode: auto-selected variant A`.

**Handling the `None — show again / revise` branch:**

If the user selects `None — show again / revise`:
1. Use **AskUserQuestion** a second time to ask the user to describe what they want changed or refined. Question text: `What would you like changed or refined about the variants?`
2. Author a replacement variant set and append it as a new `<section data-question="...">` block in the existing HTML file — do **not** discard or truncate prior sections. Use the `variantBranch` value recorded in working memory at Step 2.5 to govern the design axes for the replacement set (UX-branch or UI-branch per the Step 3 rules above). Do **not** re-evaluate `varyUIPending` here — that flag was already consumed (one-shot) at Step 2.5 and must not be re-applied.
3. Reload the browser session (Step 4 reload path).
4. Re-offer the lettered variant options for the new variant set via **AskUserQuestion**.

**Handling a free-form (non-option) reply:**

If the user's response does not match any offered option (i.e., it is a free-form reply), treat it as additional context about their preferences and re-offer the same lettered options via **AskUserQuestion**. Never silently pick a variant based on a free-form reply.

**Storing the chosen variant label:**

Once the user selects a lettered option (or the agent-mode fallback picks Variant A), normalize the chosen label to a slug for persistence and for the Phase 5 Cleanup guard.

1. Extract the letter prefix and short name (e.g., `A — Brutally minimal`).
2. Apply the same sanitization algorithm used for topic slugs in `references/visual-variants.md` (Topic-Slug Sanitization): lowercase → replace whitespace with `-` → strip non-`[a-z0-9-]` → collapse consecutive `-` → trim.
3. Prepend the letter prefix, e.g., `a-brutally-minimal`.
4. Validate the result matches `^[a-z0-9][a-z0-9-]*$`. If it does not, fall back to the bare letter (e.g., `a`).

Store the normalized slug in the agent's working memory as `chosen_variant_slug`. Phase 5 Cleanup's scratch-file removal uses the **topic-slug** (not the variant slug) when composing the `rm -f` path — the scratch filename is `<topic-slug>-variants.html` and was validated at Step 1.

**Step 7 — Variant Persistence**

After storing `chosen_variant_slug`, persist the chosen variant as a standalone HTML artifact. Execute for each visual question after the user selects a variant.

**7a — Sanitize and validate the variant label:**

Use the `chosen_variant_slug` stored in working memory. Validate it matches `^[a-z0-9][a-z0-9-]*$`.

- If the label **fails validation**: log a warning to the brainstorm document (`Variant persistence skipped — invalid label: <raw>`), skip Steps 7b–7d for this question, and leave the scratch file (`.aimi/brainstorms/prototypes/<topic-slug>-variants.html`) as the canonical artifact.
- If the label **passes**: continue to Step 7b.

**7b — Resolve a unique output path:**

Construct the candidate path:
```
.aimi/brainstorms/prototypes/<topic-slug>-<chosen_variant_slug>.html
```

Check whether the file exists:
```bash
ls .aimi/brainstorms/prototypes/<topic-slug>-<chosen_variant_slug>.html 2>/dev/null
```

If it exists (re-run of same topic + same label), append a numeric suffix and retry: `-2`, `-3`, … until a path that does not exist is found.

**7c — Extract and write the standalone file:**

From the existing scratch file (`.aimi/brainstorms/prototypes/<topic-slug>-variants.html`), extract the HTML `<section data-variant="...">` block that corresponds to the chosen variant. Wrap it in a self-contained HTML page with Tailwind CDN inline (no switcher UI, no other variants):

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title><topic-slug> — <chosen_variant_slug></title>
  <script src="https://cdn.tailwindcss.com"></script>
</head>
<body>
  <!-- chosen variant section content only -->
</body>
</html>
```

Write this file to the resolved unique path from Step 7b.

**7d — Record in working memory:**

Append an entry to a `prototype_entries` list in working memory:
```
{ path: "<resolved path>", question_category: "<Aesthetic Direction | Differentiation>", branch: "<ux-only | ui-variation>" }
```

The `branch` value is taken directly from the `variantBranch` recorded at Step 2.5 (`"ux-only"` or `"ui-variation"`). This list is consumed when writing the brainstorm document in Phase 4.

**Non-visual categories** (Purpose, Users, Constraints, Success, Edge Cases, Existing Patterns, Approach) remain text-only — Steps 1–4 above do NOT execute for them.

When the brainstorm completes normally, the browser session is closed and the variant scratch file is pruned in Phase 5 Cleanup (see below).

### Present Questions

Branch on `INTERACTIVE_MODE` (resolved in Step 0.5):

**If `INTERACTIVE_MODE=picker`:**

Emit **one picker call per question**. Use **AskUserQuestion** (translator
rewrites to OpenCode's native `question` tool). Each call includes the
question header + up to 4 lettered options + a final `Other` option that
accepts free-form text.

```
Picker call:
  header: "[Question informed by research or topic category]"
  options:
    A — [Option]
    B — [Option]
    C — [Option]
    Other — [free-form]
```

Do not render the questions as a single prose block. Do not ask the user to
reply with `"1A, 2C, 3B"` shorthand — pickers return the selection directly.
If a question only has two viable options, still emit it as its own picker
call; never combine questions into one picker.

**Agent-mode fallback:** if `INTERACTIVE_MODE=agent`, auto-select option A for
every question. For each question, log one line to the brainstorm document's
working memory: `agent-mode: Q<n> auto-selected option A`. Never block.

### Adaptive Rounds

After each response, assess which topic categories remain unaddressed:

| Category | Signals It's Addressed |
|----------|----------------------|
| Purpose | Problem/goal stated clearly |
| Users | Target audience identified |
| Constraints | Technical limits discussed OR confirmed none |
| Success | Measurable outcome defined |
| Edge Cases | Error states/boundaries discussed |
| Existing Patterns | Codebase context available (from research or user) |
| Approach | At least one approach preference expressed by user via selection or free-form response |
| Aesthetic Direction | User expresses an aesthetic preference, tone, or visual direction |
| Differentiation | User identifies a memorable or distinguishing visual aspect |

- **If all key topics covered (7 standard, or 9 when UI features detected)** OR **user says "proceed"/"let's move on"** → advance to Phase 3
- **If topics remain uncovered** AND **under 4 rounds** → generate follow-up batch targeting uncovered topics
- **If 4 rounds completed** → advance to Phase 3 regardless

### Quality Gate: Topic Coverage

Before advancing to Phase 3, check whether the **minimum topic categories** have been addressed across all Phase 2 rounds:

**Required categories:** Purpose, Users, Success

Review the user's answers across all rounds. A category counts as addressed if the user provided any relevant information — even brief or partial.

**Bundle pre-fill:** When `bundleDetected=true` and `bundleAddressedTopics` is populated (set in Step 1c), any required category present in `bundleAddressedTopics` is considered addressed before this gate evaluates user answers. Apply this pre-fill silently — do not warn the user that a category was covered by the bundle.

**BusinessSpec auto-pass:** When `bundleDetected=true` and the design-bundle researcher returned a non-null `businessSpec` path, the following required categories are auto-passed **before** this gate evaluates user answers or bundle pre-fill:

| Category | Source section |
|----------|---------------|
| Purpose | `BusinessSpec § 1` |
| Users | `BusinessSpec § 7` |
| Success | `BusinessSpec § 9` |

For each auto-passed category, log: `agent-mode: topic-coverage <category> auto-passed (source: businessSpec § <n>)` (e.g., `agent-mode: topic-coverage Purpose auto-passed (source: businessSpec § 1)`). These log lines are written to the brainstorm document's working memory and never shown to the user.

**Aesthetic Direction and Differentiation skips:** When `bundleDetected=true` and the design-bundle researcher returned a non-null `designSpec` path, skip generating questions in the **Aesthetic Direction** and **Differentiation** categories entirely — `DesignSpec § 1` (design tokens), `§ 4` (reference maps), and `§ 5` (accessibility) constitute an authoritative statement of visual intent. For each skipped category, log: `agent-mode: phase-2 <category> skipped (source: designSpec present)` (e.g., `agent-mode: phase-2 Aesthetic Direction skipped (source: designSpec present)`). These log lines are written to the brainstorm document's working memory. Do not mention the skip to the user.

- **If all three are addressed (via user answers, bundle pre-fill, or both):** Proceed to Phase 3 (or skip it per its own rules).
- **If any are missing:** Issue a **one-time** conversational warning listing the gaps:
  > "Before we continue, I notice we haven't covered [list uncovered categories, e.g., 'who the target users are' or 'how we'd measure success']. Want to explore those, or should we proceed?"
  - If the user provides answers, incorporate them and proceed.
  - If the user says "proceed", "let's move on", or similar, accept the override and proceed.
  - **Do not repeat this warning** — it fires at most once per session.

**Precedence rules:**
- A user "proceed" directive always takes precedence over this gate.
- The 4-round limit takes precedence over this gate — if 4 rounds are completed, proceed regardless.

## Phase 3: Resolve Approach (Fallback)

This phase activates **only** when the Approach topic category was **not** addressed during Phase 2 rounds. It is a lightweight fallback, not a repeat of Phase 2.

### Skip Conditions

Skip Phase 3 when **either** condition is true:

1. **Approach resolved in Phase 2** — The user selected or expressed an approach preference during any Phase 2 round (via an approach question or free-form response). Carry that selection forward as the chosen direction for the Phase 4 document.
2. **One obvious direction** — Research and answers point to a single clear path with no viable alternatives.

When skipped, proceed directly to Phase 4. If the approach was resolved in Phase 2, use that selection as the chosen direction in the "Why This Approach" section of the design document.

### When Phase 3 Triggers

If the Approach category remains unaddressed after all Phase 2 rounds complete, present 2-3 approaches with:
- Brief description (2-3 sentences)
- Pros and cons
- When it's best suited

Lead with a recommendation and explain why. Apply YAGNI — prefer simpler solutions.

Keep output sections concise (200-300 words max). After presenting approaches or key decisions, pause to validate: "Does this match what you had in mind? Any adjustments before we continue?"

Use **AskUserQuestion** to ask which approach the user prefers.

*Agent-mode fallback: if `INTERACTIVE_MODE=agent`, auto-select the first approach recommended by the preceding analysis (option A). Log: `agent-mode: phase-3-approach auto-selected option A`.*

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

Use the design document template:

```markdown
---
date: YYYY-MM-DD
topic: <topic-slug>
# researchPaths: emitted only when at least one researcher succeeded (non-empty list)
researchPaths:
  - .aimi/research/YYYY-MM-DD-<topic-slug>-<RUN_TS>-codebase.md
  - .aimi/research/YYYY-MM-DD-<topic-slug>-<RUN_TS>-best-practices.md
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

**designBundle frontmatter rules:**
- Emit the `designBundle:` key only when `bundleDetected=true`.
- `root` — value of `bundlePath`.
- `readme` — path to the bundle's README or primary index file as returned by the design-bundle researcher; `null` if absent.
- `chats` — YAML sequence of chat transcript paths returned by the researcher; empty sequence `[]` if none.
- `businessSpec` — path string when the researcher found a BusinessSpec file; `null` otherwise. Always emit (with `null`) so consumers can branch deterministically.
- `designSpec` — path string when the researcher found a DesignSpec file; `null` otherwise. Always emit (with `null`) so consumers can branch deterministically.
- When `bundleDetected=false`, omit the entire `designBundle:` key.

## Open Questions
- [Any unresolved questions]

## Next Steps
> Run `/aimi:plan` to generate implementation tasks
```

### researchPaths frontmatter rules

- **Emit only when non-empty:** Include the `researchPaths:` key in frontmatter only when the working-memory `researchPaths` list collected in Step 1c contains at least one entry. When the list is empty (all researchers were skipped or failed), omit the key entirely — do **not** emit `researchPaths: []`.
- **Relative paths:** Each entry is a path relative to AIMI_ROOT. Use no leading `./` and no `..` components (e.g., `.aimi/research/2026-05-06-my-topic-143022-codebase.md`).
- **Deduplicate:** If the same path was collected more than once, include it only once.
- **Validate before emission:** Confirm each path exists on disk under AIMI_ROOT. Drop entries that fail this check with one warning line each: `warning: researchPaths entry not found on disk — dropping: <path>`. If validation drops all entries, omit the key entirely.

### Resolve Open Questions

**Before proceeding to handoff**, check the Open Questions section. If there are unresolved questions:

1. Ask the user about each open question using AskUserQuestion
2. Move resolved questions to a "Resolved Questions" section
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

