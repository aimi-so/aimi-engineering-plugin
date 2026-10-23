# Plan: Phase 4: responseShape contract (frontend-only mode)

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.

### responseShape contract (frontend-only mode)

The `metadata.backendSpec.endpoints[].responseShape` field follows a strict flat-key contract because `validate-tasks` uses fixed-string substring matching against the cited BusinessSpec subsection text.

- **Top-level keys MUST be literal tokens** present in the cited BusinessSpec subsection. The validator does not parse dotted paths — it looks for the key as a single substring.
- **Dotted notation is rejected.** A key like `portfolio.totalUsinas` is treated as one opaque literal; if the substring `portfolio.totalUsinas` does not appear verbatim in the subsection, validation fails.
- **Nested structure goes inside the `type` field** as a TypeScript-style type string (e.g., `"{ totalUsinas: number; totalKWp: number }"`).
- **Value shape**: each top-level entry is `{ type: string, source: string }`. `source` must be either `BusinessSpec § N[.N] L<line>` (citation) or `derived: <rationale>` (computed from other fields).

**Example (accepted):**

```json
"responseShape": {
  "portfolio": {
    "type": "{ totalUsinas: number; totalKWp: number }",
    "source": "BusinessSpec § 5.3 L145"
  }
}
```

**Example (rejected by validate-tasks):**

```json
"responseShape": {
  "portfolio.totalUsinas": {
    "type": "number",
    "source": "BusinessSpec § 5.3 L145"
  }
}
```

**Notes:** `implementation`, `verification`, `gate`, `skills`, and `tasks` are optional per story. `wave` is required on all stories, but it is DERIVED and informational only — see its schema entry above; nothing in dispatch reads it, and a stale value is corrected with `normalize-waves`, never by hand. `metadata.splitGroup` is written by `story-merge` on the **PROJECT axis only** and preserved verbatim by Phase 4 — SIDE-axis, legacy, and frontend-only files have no `splitGroup` key and none should be invented for them. `/aimi:execute` Step 0.9 reads `metadata.splitGroup.project` to root each split's worktree/container at that project's own repo.

**`metadata.decisions[].source` field:** each entry records where the Open Question or outline edit originated. Thirteen valid source values:
- `<brainstorm-path>:L<line>` — an OQ line from the brainstorm doc (Phase 0.5)
- `businessSpec:L<line>` — a marker-style OQ scanned from `businessSpecContent` (Phase 0.5)
- `designSpec:L<line>` — a marker-style OQ scanned from `designSpecContent` (Phase 0.5)
- `researchFile:<basename>:OQ<n>` — an OQ entry from a researcher file's `## Open Questions` section or a `[PROMOTE-TO-OPEN-QUESTIONS]` tag, resolved at Phase 1.8
- `researchConflict` — a Phase 1.6 Conflicts entry tagged `[CONFLICT-ESCALATE]` that was escalated to the user via the Phase 1.6b Research Conflict Escalation Gate; anchor format `researchConflict:<n>` (1-based index within the escalated set)
- `specFlow:CriticalQ<n>` — an entry from the spec-flow analyzer's `### Critical Questions Requiring Clarification` section, resolved at Phase 2.5
- `specFlow:Gap<n>` — an entry from the spec-flow analyzer's `### Missing Elements & Gaps` section, resolved at Phase 2.5
- `scopeNegVerifier` — a scope-pruning-negative outcome recorded by the Phase 1.8 Scope-Pruning-Negative Gate (anchor `scopeNeg:<entity-slug>`); `resolution` is `confirmed-absent` | `refuted-restored` | `partial-surfaced`
- `scopePosVerifier` — a scope-pruning-positive outcome recorded by the Phase 1.8 Scope-Pruning-Positive Gate (anchor `scopePos:<entity-slug>`); `resolution` is `confirmed-present` | `refuted-corrected` | `partial-surfaced`
- `codebaseVerified` — auto-resolved by Phase 2.4 codebase cross-check; evidence field holds classified file:line hits
- `outline` — an outline-gate edit recorded in Phase 3c (rename, add, remove, reorder)
- `phase` — a phase-cut Edit round recorded by the Phase 0 Scope-Context Classification (Inline Fallback) gate; anchor format `phase:edit:<idx>` (zero-padded index into the proposed phase list at edit time). Distinct from `/aimi:brainstorm`'s own roadmap-gate edits, which are local to that command's `phaseEditDecisions[]` working memory and use `source: "phaseGate"` instead — the two never share a decisions array.
- `auditGate` — a decision recorded by the Phase 3d.5 Unresolved Gate (anchor `auditUnresolved:<storyIdx-or-_audit>`); `resolution` is `applied` | `deferred`

Consumers can branch on the prefix to distinguish decisions by origin.

**`metadata.decisions[].evidence` field** (optional, present only when `source` is `codebaseVerified`):

- Shape: `evidence: "<classification>:<path>:<line>,<classification>:<path>:<line>,..."`
- `<classification>` is one of `prod` | `test` | `migration` | `other` — assigned by Phase 2.4's hit classifier.
- Entries are joined in grep output order. Total string is capped at 2000 chars; when truncation fires, append `…` to indicate elision.
- Absent on every decision whose `source` is not `codebaseVerified`.
