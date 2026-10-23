# Plan: Phase 2.5: Spec-Flow Gap Gate

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.

## Phase 2.5: Spec-Flow Gap Gate

Collect open questions surfaced by the spec-flow analyzer before story decomposition begins.

**Source set — the spec-flow analyzer output from Phase 2:**

1. **`### Missing Elements & Gaps` section.** Locate this heading in the spec-flow analyzer's output. Each list entry (lines starting with `-` or `*`) becomes an OQ entry with:
   - `source: specFlow`
   - `anchor: specFlow:Gap<n>` where `<n>` is the 1-based index of the entry within the section.
2. **`### Critical Questions Requiring Clarification` section.** Locate this heading in the spec-flow analyzer's output. Each list entry becomes an OQ entry with:
   - `source: specFlow`
   - `anchor: specFlow:CriticalQ<n>` where `<n>` is the 1-based index of the entry within the section.

Note: the spec-flow analyzer does **not** emit a `## Open Questions` heading — do not look for one. Only the two sections named above are valid sources for this gate.

Merge all collected entries into the shared `openQuestions[]` accumulator.

**Dedup by anchor:** before adding any entry, check `oqDecisions[]` for an existing entry with the same anchor. If a matching entry exists and already carries a resolution, skip it.

**Sanitize OQ text** before passing to AskUserQuestion: strip newlines, remove any `$(` sequences, remove backtick characters, and truncate to 500 characters (same sanitization regime applied to Path Hints earlier in this pipeline).

**20-OQ aggregate cap with priority sort:** if the combined count of new (unresolved, post-dedup) OQs from this phase exceeds 20, sort by severity — `Critical` entries first, then `Important`, then `Nice-to-have` (using the severity labels the spec-flow analyzer annotates in its output) — and present only the first 20. Emit a single warning line listing the anchors of any entries dropped by the cap.

**For each new entry in `openQuestions[]`** without a resolution:
- Call AskUserQuestion with the OQ text. Include `source` and `anchor` in the question header (e.g., `OQ · specFlow Gap3` or `OQ · specFlow CriticalQ1`) so the user knows exactly what they are deciding on.
- Record the resolution in working memory `oqDecisions[]` keyed by anchor, using `specFlow:CriticalQ<n>` or `specFlow:Gap<n>` as the `source` field.

**Do NOT write sentinels back to the spec-flow analyzer output** — that output is a read-only artifact from this gate's perspective. Only `oqDecisions[]` is mutated.

Block Phase 3a until every new entry carries a resolution or `[deferred: ...]`.

**Agent-mode fallback:** when `INTERACTIVE_MODE=agent`, auto-defer all entries with reason `agent-mode auto-defer` — do not block. Emit exactly one log line:

```
agent-mode: phase-2.5-oq-gate deferred <N> questions
```

where `<N>` is the count of questions deferred this phase.
