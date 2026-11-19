# Brainstorm: Phase 3.7: Foundation Synthesis (Steps 2 to 6)

> Loaded by `commands/brainstorm.md` when its `Applies when:` condition holds.
>
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

### Step 2: Reuse Check

Before doing any synthesis work, check whether a fresh foundation artifact already exists for this project — architecture decisions describe the repository as a whole, not one feature, so this check is deliberately **project-level, not topic-scoped** (unlike `researchPaths` freshness checks elsewhere in this pipeline).

Glob `.aimi/research/*-foundation.md` at `AIMI_ROOT` (no topic-slug segment in the pattern). A match is **fresh** when its mtime is within 14 days of the current run. When more than one match is fresh, the most recently modified file wins — mirroring the same tie-break `/aimi:plan`'s Phase 1.9 uses for its own (topic-scoped) reuse check.

**Pre-acceptance validation (both paths below).** A fresh match is a *candidate*, never "already validated" — a filename glob plus an mtime proves nothing about the file's origin or content. Before either path below may accept a candidate: (a) resolve it with `realpath` (accounting for symlink targets) and require the resolved path to start with `AIMI_ROOT/.aimi/research/` — a symlinked `*-foundation.md` pointing outside that directory is rejected; and (b) run Step 5's four validation checks against the file's contents as written there (presence of the 4 sections, non-empty/concrete, real folder tree, real lint identifier). A candidate that fails either (a) or (b) is treated exactly as if no fresh match existed — emit one warning line `warning: foundation-synthesis reuse candidate rejected (<matched-path>: <reason>) — proceeding to synthesis` and fall through to the no-match branch. A pointer is never emitted for an unvalidated artifact.

#### Non-Interactive Fast Path

When `INTERACTIVE_MODE=agent`, skip AskUserQuestion entirely and auto-resolve:

- **A fresh match exists and passes pre-acceptance validation:** set `foundationProposalPath` to the matched path and skip Step 3 (Sanitization) through Step 6 (Write) — the reused artifact already passed the same Step 5 checks a newly synthesized one must pass. Log exactly one line to the brainstorm document's working memory: `agent-mode: foundation-synthesis reusing existing proposal (<matched-path>)`.
- **No fresh match exists (or the candidate failed pre-acceptance validation):** proceed to Step 3. Log exactly one line to the brainstorm document's working memory: `agent-mode: foundation-synthesis no fresh proposal found — proceeding to synthesis`.

Either way, exactly one line is logged for this check — never both (the rejection warning from pre-acceptance validation, when it fires, is additional to and precedes this line).

#### Interactive Offer

When a fresh match exists **and passes pre-acceptance validation**, present it via **AskUserQuestion** (picker mode) with exactly two options:

```
A recent foundation proposal already exists (<matched-path>, modified <N> days ago) — want to reuse it?

Reuse existing — use the file found, without generating a new one
Create new — ignore the file found and synthesize a new one
```

- **[Reuse existing]:** skip sanitization (Step 3), synthesis (Step 4), and a second validation pass (Step 5) — pre-acceptance validation above already ran Step 5's checks against this file. Set `foundationProposalPath` to that existing path. Proceed to Phase 4.
- **[Create new]:** proceed to Step 3. The existing file is left untouched on disk; Step 6 writes a new file under a new `RUN_TS`-qualified name, it never overwrites the match found here.

When **no** fresh match exists (or the candidate failed pre-acceptance validation), skip this offer entirely — present no picker prompt — and proceed unprompted to Step 3.

### Step 3: Authoring-Time Sanitization

Before any raw Foundation-category answer (including "Other: ..." free text) is composed into a section in Step 4, sanitize it: apply the three base rules in `${CLAUDE_PLUGIN_ROOT}/commands/references/sanitization.md` (strip code fences/backtick content, HTML/XML tags, instruction-override patterns), then apply that same file's **Foundation-Synthesis Extension** (newline-to-space replacement, unconditional `$(` and backtick stripping, truncation to a stated per-answer max length, markdown-heading-marker stripping). Read that file and apply both the base rules and the Foundation-Synthesis Extension as written — do not restate them here. Only sanitized text may enter any of the four sections Step 4 synthesizes.

### Step 4: Synthesize the 4 Sections

Compose the sanitized Foundation answers into exactly these four `##` sections, in this order and no others (the same relative order these four hold inside the architect's nine-section Output Contract, so the two authoring paths' artifacts read alike):

- `## Folder Layout`
- `## Lint and Format Config`
- `## CLAUDE.md Draft`
- `## AGENTS.md Draft`

These headings are verbatim matches (case and punctuation) of 4 of the 9 `## Output Contract` sections defined in `agents/research/aimi-foundation-architect.md`, so `aimi-story-expander.md`'s `foundationEntry` special case (~L145) can consume either authoring path's artifact interchangeably. Do not add a `## Stack`, `## Layering`, `## Module Template`, `## Naming Conventions`, or `## Open Questions` section here — those five belong to the architect agent's own nine-section contract and have no consumer on this path.

Draft each section from the sanitized answers to the Foundation sub-topics gathered in Phase 2 (stack/runtime, architecture pattern, folder/convention structure, lint/format tooling, language):

- **`## Folder Layout`** — a concrete, real directory tree reflecting the chosen folder/convention structure — not a description of one.
- **`## Lint and Format Config`** — the specific linter/formatter the user picked (or its "Other" free-text equivalent), naming a real tool or config filename.
- **`## CLAUDE.md Draft`** — human-facing project conventions: the chosen stack, architecture pattern, and folder/convention structure, stated as decisions the way `aimi-foundation-architect.md`'s own `## CLAUDE.md Draft` section does. When the language sub-topic was answered, add one further line naming the project's own prose language as a decision. Per the artifact-language rule (`commands/references/user-communication.md`), that line governs only files the project owns — its own `CLAUDE.md`/`AGENTS.md`, `README`, `CHANGELOG`, source comments, and product copy — and every artifact under `.aimi/` stays English regardless of it.
- **`## AGENTS.md Draft`** — the same conventions restated for a spawned-agent audience, distinct from CLAUDE.md's human-facing scope, exactly as `aimi-foundation-architect.md`'s Output Contract distinguishes the two.

For the architectural reasoning behind `## CLAUDE.md Draft` and `## Folder Layout`, cite `agents/research/aimi-foundation-architect.md`'s `## Decision Rules` subsections — **Layering**, **Module Boundaries**, **Naming** — by reference (e.g., "per Layering: dependencies point inward") to keep this authoring path aligned with the architect agent's. Do not restate those rules' text here. This step never spawns `aimi-foundation-architect` or any other sub-agent — the synthesis is inline reasoning by `/aimi:brainstorm` itself, using only the sanitized Foundation answers already in hand.

### Step 5: Validation Gate

Before the artifact is considered usable, check all of the following:

1. **Presence:** all 4 sections from Step 4 are present.
2. **Non-empty and concrete:** none of the 4 sections is empty or reduces to placeholder/hedge text (e.g., "not sure yet", "TBD", "to be decided", "n/a", "undecided" — case-insensitive).
3. **Real folder tree:** `## Folder Layout` renders a multi-line directory tree (a fenced code block with at least 3 lines, at least 2 of which contain a path-like entry), not a one-line description.
4. **Real lint/config identifier:** `## Lint and Format Config` names at least one concrete tool (e.g., ESLint, Prettier, Biome, RuboCop, Black) or config filename (e.g., `.eslintrc`, `pyproject.toml`, `.rubocop.yml`) — a bare, generic mention ("some linter") does not satisfy this check.
5. **Exactly 4 `##` headings, matching the contract names:** the artifact contains exactly four level-2 headings and they are exactly the four Step 4 names — no extra, no duplicate. A fifth or duplicated heading means answer text survived sanitization as markdown structure (see `commands/references/sanitization.md` Foundation-Synthesis Extension rule 7) and must fail the gate, since `aimi-story-expander`'s `foundationEntry` handling derives real files from whichever `## Folder Layout`/`## Lint and Format Config` sections it finds.

- **All checks pass:** proceed to Step 6.
- **Any check fails:** do NOT write the artifact. Leave `foundationProposalPath` unset. Emit exactly one warning line: `warning: foundation-synthesis validation failed (<reason>) — foundationProposalPath left unset.` Proceed to Phase 4 exactly as if this phase had never fired. This degrades gracefully: `/aimi:plan`'s Phase 1.9 Greenfield Foundation Gate finds no fresh proposal on its own (topic-scoped) reuse check and falls back to its normal `aimi-foundation-architect` spawn path.

### Step 6: Write the Artifact

Once Step 5 passes, write the artifact using the exact filename convention `agents/research/aimi-foundation-architect.md` uses for its `outputPath`:

```bash
mkdir -p .aimi/research
```

**Filename:** `.aimi/research/YYYY-MM-DD-<topic-slug>-<RUN_TS>-foundation.md` (same `date`/`topic-slug`/`RUN_TS` values established for this session in Phase 1 — with two fallbacks, since Phase 1's research path can be skipped entirely: if `RUN_TS` was not generated this session, generate it now with `date +%H%M%S`; and validate the derived `<topic-slug>` against `^[a-z0-9][a-z0-9-]*$` before composing the path, falling back to the literal segment `foundation-proposal` when it does not match — the same validate-then-fallback discipline the Visual Variant Rendering slug path applies).

Write the 4 synthesized sections, in the order given in Step 4, to that path. Set the `foundationProposalPath` working-memory variable to the written path. Do not introduce a companion boolean flag (e.g., `foundationAccepted`) — the single variable's presence is the only signal a downstream consumer needs that a validated artifact exists.

### Cross-Reference: Foundation Proposal Handoff

Phase 3.7 itself emits no frontmatter. Phase 4 is the sole writer of the `foundationProposalPath:` frontmatter key, and reads this working-memory variable verbatim to do so — see the "foundationProposalPath frontmatter rules" subsection under Phase 4, the same way Phase 4's `prototype:` frontmatter reads `prototype_entries` per the Cross-Reference above.
