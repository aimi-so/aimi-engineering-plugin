# Plan: Phase 1: Bundle Researcher (Bundle-Direct Mode)

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.
>
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

### Bundle Researcher (Bundle-Direct Mode)

**Guard:** When `designBundleMeta` is non-null AND no brainstorm was loaded in Phase 0 (plan invoked directly with a bundle, skipping the brainstorm step), spawn the bundle researcher. Otherwise skip — when a brainstorm WAS loaded, brainstorm already ran the bundle researcher and the OQs live in the brainstorm doc. When `designBundleMeta` is null, this block is skipped entirely — no log noise, no behavior change for non-bundle plan invocations.

```
Task subagent_type="aimi-engineering:research:aimi-design-bundle-researcher"
  [model: <AGENT_MODELS.research when not "inherit">]
  prompt: "Ingest the Claude Design handoff bundle and produce the
           16-section research doc, including § Open Questions with
           any spec-prototype coverage gaps marked
           [PROMOTE-TO-OPEN-QUESTIONS].
           topicSlug: [topicSlug]
           bundlePath: [designBundleMeta.path]
           designSpec: [designBundleMeta.designSpec or empty string]
           businessSpec: [designBundleMeta.businessSpec or empty string]
           chats: [designBundleMeta.chats[] as JSON array]
           prototypes: [designBundleMeta.prototypes[] as JSON array]
           outputPath: .aimi/research/YYYY-MM-DD-[topicSlug]-[RUN_TS]-design-bundle.md"
```

After the researcher completes, parse its `## Open Questions` section, extract every entry tagged `[PROMOTE-TO-OPEN-QUESTIONS]`, and merge them into the `openQuestions[]` list maintained by Phase 0.5 (introduced by US-001). Then re-enter Phase 0.5 to resolve the newly discovered OQs interactively (or auto-defer in agent-mode) before proceeding to Phase 1.5. The bundle researcher may surface spec×prototype contradictions that the line-scan in Phase 0.5 alone cannot detect.
