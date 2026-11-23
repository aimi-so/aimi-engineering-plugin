# Brainstorm: Phase 5: Handoff

> Loaded by `commands/brainstorm.md` when its `Applies when:` condition holds.
>
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

## Phase 5: Handoff

Display the brainstorm summary and next steps:

```
Brainstorm complete!

Document: .aimi/brainstorms/[filename].md

Key decisions:
- [Decision 1]
- [Decision 2]

Next steps:
1. **Run `/aimi:plan`** - Create implementation plan and tasks.json
2. **Continue brainstorming** - Run `/aimi:brainstorm` to explore further
3. **Review document** - Open the brainstorm file to refine manually
4. **Done for now** - Return later
```

**IMPORTANT:** Output the "Next steps" block EXACTLY as shown above — use `/aimi:` prefix (e.g., `/aimi:plan`), NOT the fully-qualified plugin name (e.g., `/aimi-engineering:plan`). Copy the block verbatim.

**Fresh session hint:** After the block, tell the person, in one sentence in their language, that this run's state is saved under `.aimi/` and that starting the next command in a fresh session (`/clear`) loses nothing and makes each of its turns cheaper. Skip it in agent mode.

**If user selects "Continue brainstorming":** Return to Phase 2 with the existing document as context. Generate targeted follow-up questions about areas not yet explored.

**If user selects "Done for now":** End the session. Display:
```
Brainstorm saved. To resume later: `/aimi:brainstorm [topic]`
To start planning: `/aimi:plan`
```

### Cleanup

Execute this sub-step **only** after Phase 5 completes successfully (brainstorm document written and user has acknowledged the handoff). Skip entirely on abnormal termination: agent crash, user abort before reaching Phase 5, or any Pre-Save Checklist failure that was not overridden.

**Step 1 — Close agent-browser session**

If a browser session was opened during Phase 2 visual variant rendering, close it now (before deleting the scratch file so no open tab references a deleted path):

```bash
agent-browser --session brainstorm-<topic-slug> close
```

If `agent-browser` was unavailable or no visual questions were rendered, skip this step silently.

**Step 2 — Prune the variant scratch file**

The scratch file (`.aimi/brainstorms/prototypes/<topic-slug>-variants.html`) is a multi-variant working file created during visual exploration. Once brainstorm completes cleanly, prune it so only the chosen per-question standalone artifacts (US-006 output) remain under `.aimi/brainstorms/prototypes/`.

Guard: only prune if at least one chosen-variant standalone file was successfully written (i.e., `prototype_entries` in working memory is non-empty). This ensures the scratch file is never the last surviving artifact.

```bash
rm -f .aimi/brainstorms/prototypes/<topic-slug>-variants.html
```

If the scratch file does not exist (e.g., no visual questions were rendered), this is a no-op — do not warn.

**Preservation guarantee:** All chosen-variant standalone files (e.g., `<topic-slug>-a-brutally-minimal.html`) and all bundle-generated prototype files (e.g., `<topic-slug>-bundle.html`) are never touched by this step. They are preserved regardless of pruning outcome.

**Skip conditions (do NOT prune):**

- Abnormal termination (crash, user abort before Phase 5, unresolved checklist failure)
- `prototype_entries` is empty (no standalone variants were written — scratch file may be the only artifact)
- Scratch file was never created (no visual questions rendered)

Note: The browser session close that previously appeared inline in Phase 2 ("When the brainstorm completes normally (Phase 5)") is now handled exclusively here in Phase 5 Cleanup. Do not close the session earlier.
