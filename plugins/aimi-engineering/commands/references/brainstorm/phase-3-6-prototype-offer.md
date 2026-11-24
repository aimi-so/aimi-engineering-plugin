# Brainstorm: Phase 3.6: Prototype Offer Gate

> Loaded by `commands/brainstorm.md` when its `Applies when:` condition holds.
>
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

## Phase 3.6: Prototype Offer Gate

This is a **gate**, not a roadmap phase. It produces at most one in-conversation design artifact — a prototype HTML persisted through the existing Visual Variant Rendering machinery — and it never writes to the in-memory `phases[]` array or to any file under `.aimi/tasks/`. Nothing in this section materializes a roadmap phase or a task file.

### Step 1: Fire-Condition Check

The gate fires only when **both** of the following hold:

1. **`prototype_entries` is empty.** If an entry already exists — from a Phase 2 Aesthetic Direction/Differentiation question (Visual Variant Rendering Step 7) or from the bundle early-exit (Step 0a above) — skip this entire phase: emit no log line, present no offer, proceed straight to Phase 4.
2. **A ui-signals.md signal is present**, checked in this order:
   - **Primary — Structural Signal:** When Phase 3.5 ran (2 or more scope contexts, so an approved in-memory `phases[]` array exists), scan every phase's `creates`, `areas`, and `goal` fields against the Structural Signals defined in `${CLAUDE_PLUGIN_ROOT}/commands/references/ui-signals.md` (file-extension, path-segment, and lexical markers). Apply that file's rules as written — do not restate them here. The first phase that matches becomes the "matched phase" named in the offer below.
   - **Fallback — Phase 1.7 fired without a prototype:** When Phase 3.5 was skipped entirely (0 or 1 scope contexts, Phase 3.5 Step 1 — no `phases[]` array was ever built), check instead whether Phase 1.7 (UI Feature Detection) marked the feature UI-relevant. If it did, and `prototype_entries` is still empty, this fallback signal counts as present, and the feature description itself (not a phase name) is what gets named in the offer below.

If neither signal is present, skip this phase silently: emit no log line, present no offer, proceed straight to Phase 4 exactly as if this phase did not exist.

*(Optional debug: if `AIMI_BRAINSTORM_DEBUG=1`, emit `[brainstorm-debug] phase-3.6: <fired|skipped> (reason: <structural-signal|phase-1.7-fallback|no-signal|prototype-entries-non-empty>)` to chat.)*

Set the `phase36Verdict` working-memory variable to the same `<fired|skipped>` token computed above — read back, never recomputed, by Phase 3.8's classification summary line.

### Step 2: Non-Interactive Fast Path

When `INTERACTIVE_MODE=agent`:

- Skip AskUserQuestion entirely — do not present the offer, do not ask anything.
- Log exactly one line to the brainstorm document's working memory: `agent-mode: prototype-offer-gate skipped (no user to prototype with)`.
- Proceed to Phase 4 with `prototype_entries` left unchanged (still empty).

### Step 3: Interactive Offer

Name the concrete UI surface the signal matched — the matched phase's `name` for the Structural Signal case, or the feature itself for the Phase 1.7 fallback case. Present via **AskUserQuestion** (picker mode) with exactly three options:

```
Phase "<name>" delivers screens operators use — want to prototype before moving to Phase 4?

Prototype — generate visual variants now
I have a reference — point to a style or example first
Skip — go straight to Phase 4
```

- **[Skip]:** Proceed to Phase 4 unchanged. `prototype_entries` remains exactly as it was (still empty, per the fire condition). No artifact is produced.

- **[Prototype]:** Set `visualOverridePending = true` and present one Aesthetic Direction question (same format as the "Design Questions" example above, e.g. "What visual tone fits this interface best?"). Because `visualOverridePending = true`, the existing **#### Visual Variant Rendering** machinery's override check (Phase 2 above, "`show variants` override check") treats this question as Aesthetic Direction and runs Steps 0a through 7 completely unchanged — authoring variants, opening the preview, and persisting the chosen variant into `prototype_entries` via Step 7. No part of that machinery is re-implemented here.

- **[I have a reference]:** First run the Reference Intake flow defined in `${CLAUDE_PLUGIN_ROOT}/commands/references/visual-variants.md` under `## Reference Intake` (accepts a local path, a URL, or a free-text style directive; sanitizes it; establishes it as Probe #0 ahead of every project-source probe in Token Extraction). Apply that section's rules as written — do not restate them here. Then proceed identically to the [Prototype] branch above: set `visualOverridePending = true`, present one Aesthetic Direction question, and let Visual Variant Rendering run unchanged. A Reference Intake failure does not abort this gate — it degrades to the plain [Prototype] flow with that section's single warning line (`⚠ Reference intake: ...`) and continues from there.

### Cross-Reference: Prototype Persistence

A prototype produced by this gate lands in `prototype_entries` through the exact same Visual Variant Rendering Step 7 persistence path a Phase 2 Aesthetic Direction/Differentiation question uses. Phase 4 therefore emits it into the `prototype:` frontmatter via the existing "`prototype:` frontmatter rules" below with no new Phase 4 plumbing required.
