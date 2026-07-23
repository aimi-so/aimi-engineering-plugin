# UI Signals

Shared reference for detecting UI-bearing work — a feature description, a
brainstorm phase, or a roadmap phase whose deliverable includes a rendered
surface (a page, screen, dashboard, form, or component a user looks at and
interacts with). Apply the rules in this file wherever the caller says "scan
for UI signals" or "check whether this is UI-bearing."

**Consumed by:** brainstorm.md's Phase 1.7 (UI Feature Detection), brainstorm.md's Phase 3.6 (the prototype-offer gate), and plan.md.

All three cite this file instead of maintaining their own keyword or
structural detection lists, so the same feature description or roadmap phase
is classified identically regardless of which command runs the check.

## Keyword Signals

Scan the feature description (or a roadmap phase's goal/creates/areas text)
for visual/UI keywords using case-insensitive whole-word matching (regex word
boundaries `\b`).

**Keyword list:** page, modal, dashboard, form, component, layout, ui, design,
frontend, react, next, next.js, vue, svelte, sveltekit, angular, remix, nuxt,
solid

The keyword "design" alone does not trigger detection — it requires co-occurrence with at least one other keyword from the list. This prevents false positives from phrases like "system design" or "API design."

| Bucket | Signals | Action |
|--------|---------|--------|
| **Detect** | Text contains at least one keyword (with "design" requiring co-occurrence) | Mark the text as UI-relevant |
| **Skip** | No keywords match, or "design" appears alone without another keyword | Treat the text as non-UI for keyword-signal purposes |

## Structural Signals

Keyword matching is evaded by phrasing (a feature can be UI-bearing without
using any of the words above — e.g. "render account balances in the client").
Structural signals close that gap by inspecting what a phase actually
produces, not how its description is worded.

**File-extension markers** — a `creates`/`areas` path ending in one of these
extensions is a structural match:

| Extension |
|---|
| `.tsx` |
| `.jsx` |
| `.vue` |
| `.svelte` |

**Path-segment markers** — a `creates`/`areas` path containing one of these
segments is a structural match:

| Segment |
|---|
| `components/` |
| `pages/` |
| `views/` |
| `routes/` |
| `app/` route directories (e.g. Next.js `app/<route>/page.tsx`) |

**Lexical markers** — an artifact description containing one of these words
is a structural match:

| Word |
|---|
| screen |
| page |
| view |
| route |
| component |
| frontend |

**UI-bearing phase definition:** a phase is UI-bearing when any `creates` or
`areas` entry, or the phase `goal`, matches a file-extension, path-segment, or
lexical marker above (see the Roadmap File Schema note on `phases[].creates`/
`areas`/`goal` in the top-level CLAUDE.md).

## How to Combine

The structural signal is authoritative and cannot be evaded by phrasing: if
any `creates`/`areas` entry or the goal matches a structural marker, the
phase is UI-bearing regardless of what the keyword scan finds. The keyword
signal is additive — it can flag a plain-text feature description (which has
no `creates`/`areas` to inspect yet) as UI-relevant before a structural
artifact list exists. When both signals are absent, the text is non-UI.
