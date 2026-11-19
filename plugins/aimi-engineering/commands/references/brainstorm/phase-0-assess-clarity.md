# Brainstorm: Phase 0: Assess Requirements Clarity

> Loaded by `commands/brainstorm.md` when its `Applies when:` condition holds.

## Phase 0: Assess Requirements Clarity

Decide from the feature description whether brainstorming is needed.

**Clear requirements signals:**
- Specific acceptance criteria provided
- Referenced existing patterns to follow
- Described exact expected behavior
- Constrained, well-defined scope

**If requirements are already clear:**
Use **AskUserQuestion** to suggest: "The requirements already look detailed enough to plan. Run `/aimi:plan` now, or keep exploring the idea first?"

*Agent-mode fallback: if `INTERACTIVE_MODE=agent`, auto-proceed to `/aimi:plan` (the non-disruptive default). Log: `agent-mode: phase-0-plan-redirect auto-proceeded to plan`.*

**If unclear or vague:** proceed to Phase 1.
