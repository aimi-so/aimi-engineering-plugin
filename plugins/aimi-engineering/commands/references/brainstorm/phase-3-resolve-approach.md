# Brainstorm: Phase 3: Resolve Approach (Fallback)

> Loaded by `commands/brainstorm.md` when its `Applies when:` condition holds.

## Phase 3: Resolve Approach (Fallback)

This phase activates **only** when the Approach topic category was **not** addressed during Phase 2 rounds. It is a lightweight fallback, not a repeat of Phase 2.

### Skip Conditions

Skip Phase 3 when **either** condition is true:

1. **Approach resolved in Phase 2** — The user selected or expressed an approach preference during any Phase 2 round (via an approach question or free-form response). Carry that selection forward as the chosen direction for the Phase 4 document.
2. **One obvious direction** — Research and answers point to a single clear path with no viable alternatives.

When skipped, proceed directly to Phase 4. If the approach was resolved in Phase 2, use that selection as the chosen direction in the "Why This Approach" section of the design document.

### When Phase 3 Triggers

If the Approach category remains unaddressed after all Phase 2 rounds complete, present 2-3 approaches with:
- Brief description (2-3 sentences)
- Pros and cons
- When it's best suited

Say which option you recommend and why, and favor the simplest one that meets the need.

Keep output sections concise (200-300 words max). After presenting approaches or key decisions, pause to validate: "Is this the direction you want? Should anything change before we go on?"

Use **AskUserQuestion** to ask which approach the user prefers.

*Agent-mode fallback: if `INTERACTIVE_MODE=agent`, auto-select the first approach recommended by the preceding analysis (option A). Log: `agent-mode: phase-3-approach auto-selected option A`.*
