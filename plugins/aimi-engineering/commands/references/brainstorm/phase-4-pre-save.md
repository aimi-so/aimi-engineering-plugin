# Brainstorm: Phase 4: Pre-Save Rules and Gates

> Loaded by `commands/brainstorm.md` when its `Applies when:` condition holds.
>
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

### researchPaths frontmatter rules

- **Emit only when non-empty:** Include the `researchPaths:` key in frontmatter only when the working-memory `researchPaths` list collected in Step 1c contains at least one entry. When the list is empty (all researchers were skipped or failed), omit the key entirely — do **not** emit `researchPaths: []`.
- **Four reusable kinds:** Include entries for any of the four reusable research kinds that succeeded this session — `codebase` (`-codebase.md`), `best-practices` (`-best-practices.md`), `framework-docs` (`-framework-docs.md`), and `learnings` (`-learnings.md`). Entries for kinds whose agents were skipped or failed are simply absent from the list (not emitted as empty or null). Other research kinds (e.g., `-design-bundle.md`) are not included in `researchPaths` — they are not reusable by plan.
- **Relative paths:** Each entry is a path relative to AIMI_ROOT. Use no leading `./` and no `..` components (e.g., `.aimi/research/2026-05-06-my-topic-143022-codebase.md`).
- **Deduplicate:** If the same path was collected more than once, include it only once.
- **Validate before emission:** Confirm each path exists on disk under AIMI_ROOT. Drop entries that fail this check with one warning line each: `warning: researchPaths entry not found on disk — dropping: <path>`. If validation drops all entries, omit the key entirely.
- **Backward compatibility:** Brainstorm documents that do not have the `researchPaths` key (written before this feature) are still valid. When `/aimi:plan` reads such a legacy brainstorm, it silently disables research reuse for that session — no error or warning is emitted. New brainstorms always emit this key when at least one researcher succeeds.

### foundationProposalPath frontmatter rules

- **Emit only when validated:** Include the `foundationProposalPath:` key in frontmatter only when Phase 3.7 (Foundation Synthesis) reports that the foundation artifact was written and passed its validation gate — including the case where an existing fresh proposal was reused instead of freshly synthesized. When Phase 3.7 did not fire, or its validation gate failed, omit the key entirely: no placeholder value, and no companion boolean flag (explicitly: no `foundationAccepted` key is introduced). The key's bare presence is the only signal a downstream consumer needs.
- **Single path, not a list:** Unlike `researchPaths` above — a list because it tracks four distinct research kinds — `foundationProposalPath` is a single relative path string. One repository has at most one active foundation proposal, so a list shape would be misleading here.
- **Relative paths:** The value is a path relative to AIMI_ROOT. Use no leading `./` and no `..` components — the same normalization already documented for each `researchPaths` entry above.
- **Tag-breakout sanitization:** Before writing the value into the frontmatter, replace any literal `</foundation_proposal` with `&lt;/foundation_proposal` and `<foundation_proposal` with `&lt;foundation_proposal` in the path string — `/aimi:plan`'s Phase 3d later interpolates this value into a `<foundation_proposal path="…">` wrapper attribute. (In practice a file path will never contain these sequences, but the guard must be on the rail per security policy — the same rule the `prototype:` and `phases:` frontmatter emissions above already apply.)
- **Reuse contract for plan:** `/aimi:plan`'s Phase 1.9 Greenfield Foundation Gate reads this key when present and reuses the referenced artifact instead of spawning `aimi-foundation-architect`. It falls back silently — no error, no warning — to its own architect-spawn path when the key is absent, the referenced file is missing on disk, or the file is stale.
- **Backward compatibility:** Brainstorm documents written before this feature (lacking `foundationProposalPath`) remain valid. When `/aimi:plan` reads such a legacy brainstorm, it silently disables foundation-proposal reuse for that session and degrades to its existing Phase 1.9 behavior — no error or warning is emitted, mirroring the legacy-brainstorm-without-`researchPaths` precedent above.

### Resolve Open Questions

**Before proceeding to handoff**, check the Open Questions section. If there are unresolved questions:

1. Ask the user about each open question using AskUserQuestion
2. File each answered question under a "Resolved Questions" section
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
