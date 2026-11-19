# Brainstorm: Phase 4: Capture the Design

> Loaded by `commands/brainstorm.md` when its `Applies when:` condition holds.
>
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

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
