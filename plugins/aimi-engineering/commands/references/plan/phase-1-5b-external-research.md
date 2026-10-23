# Plan: Phase 1.5b: External Research

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.
>
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

## Phase 1.5b: External Research (Conditional, Parallel)

Only if Phase 1.5 decides external research is needed, run the applicable agents in parallel:

Both researchers below are covered by Phase 1 § Confirm Each Research File Landed — apply that same check once per researcher as each Task returns, and append to the same `researchWritten` list. Do not restate the predicate here; one definition, two spawn sites.

**If `reusedResearch["best-practices"]` is unset** (no valid best-practices research from brainstorm):

```
Task subagent_type="aimi-engineering:research:aimi-best-practices-researcher"
  [model: <AGENT_MODELS.research when not "inherit">]
  prompt: "Research current best practices for: [feature description].
           researchDepth: [computed researchDepth from Phase 1.5]
           topicSlug: [topicSlug]
           [If ROADMAP_MODE]: Phase scope — this research is scoped to phase
           [SELECTED_PHASE_ID] ([PHASE_NAME]): goal: [PHASE_GOAL].
           outputPath: .aimi/research/YYYY-MM-DD-[topicSlug]-[RUN_TS]-best-practices.md"
```

**If `reusedResearch["best-practices"]` is set**: skip the best-practices researcher Task entirely. The existing file at `reusedResearch["best-practices"]` will be read directly in Phase 1.6.

**If `reusedResearch["framework-docs"]` is unset** — and Phase 1.5 heuristic triggers framework-docs research:

```
Task subagent_type="aimi-engineering:research:aimi-framework-docs-researcher"
  [model: <AGENT_MODELS.research when not "inherit">]
  prompt: "Research framework documentation for: [feature description].
           researchDepth: [computed researchDepth from Phase 1.5]
           topicSlug: [topicSlug]
           [If ROADMAP_MODE]: Phase scope — this research is scoped to phase
           [SELECTED_PHASE_ID] ([PHASE_NAME]): goal: [PHASE_GOAL].
           outputPath: .aimi/research/YYYY-MM-DD-[topicSlug]-[RUN_TS]-framework-docs.md"
```

**If `reusedResearch["framework-docs"]` is set**: skip the framework-docs researcher Task entirely. The existing file at `reusedResearch["framework-docs"]` will be read directly in Phase 1.6. Note: `reusedResearch["framework-docs"]` reuse is informational only — it only skips the spawn when the Phase 1.5 heuristic would have triggered framework-docs research; when the heuristic says to skip entirely, this entry is irrelevant.
