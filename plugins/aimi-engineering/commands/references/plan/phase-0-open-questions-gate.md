# Plan: Phase 0.5: Open Questions Resolution Gate

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.

### Phase 0.5: Open Questions Resolution Gate

Collect open questions from two sources:

1. **Brainstorm-sourced OQs.** When a brainstorm doc was loaded in Phase 0,
   parse its `## Open Questions` section. Each line without a
   `[resolved: ...]` or `[deferred: ...]` suffix becomes an OQ entry with
   `source: brainstorm` and `anchor: <brainstorm path>:L<line>`.

2. **Spec-marker OQs.** When `businessSpecContent` or `designSpecContent`
   is non-null, scan each file line-by-line for markers matching the
   regex (case-insensitive):
       \[(a confirmar|TBD|to confirm|to be confirmed|to be defined)[^\]]*\]
   For each match, create an OQ entry with:
       - text: the full line containing the marker (trimmed)
       - source: businessSpec | designSpec
       - anchor: <spec path>:L<line>
   Markers inside fenced code blocks (between triple backticks) are skipped.

Merge both lists into `openQuestions[]`. For each entry without a resolution:
- Call AskUserQuestion with the OQ text. Include `source` and `anchor` in
  the question header (e.g., `OQ · businessSpec L26`) so the user knows
  exactly what they are deciding on.
- Record the resolution in working memory `oqDecisions[]` keyed by anchor.
- For brainstorm-sourced OQs, also append `[resolved: <choice>]` to the
  line in the brainstorm file via Edit. Spec-marker OQs are NOT written
  back to the spec files (specs are source-of-truth artifacts owned by
  product/design, not editable plan state) — they are recorded only in
  `oqDecisions[]` and surfaced later in `metadata.decisions[]`.

Block Phase 1 until every entry has a resolution or `[deferred: ...]`.

Agent-mode fallback: auto-defer all entries (do not block).

**Aggregate cap:** if more than 20 marker-style OQs are detected, sort by
source (businessSpec before designSpec) then by line number, present the
first 20, and emit a single warning line listing the remaining anchors so
the user is aware they were skipped from interactive resolution.
