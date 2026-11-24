# Brainstorm: Phase 3.7: Foundation Synthesis (Fire-Condition Check)

> Loaded by `commands/brainstorm.md` when its `Applies when:` condition holds.
>
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

## Phase 3.7: Foundation Synthesis

This is a **gate**, not a roadmap phase. It produces at most one artifact under `.aimi/research/` — a synthesized foundation proposal, authored inline from the Foundation-category answers Phase 2 already gathered — and it never spawns `aimi-foundation-architect` or any other sub-agent. Brainstorm's own reasoning does the synthesis; the agent stays reserved for `/aimi:plan`'s Phase 1.9 Greenfield Foundation Gate.

### Step 1: Fire-Condition Check

The gate fires only when **both** of the following hold:

1. **Phase 1.8 (Greenfield Foundation Detection) marked the session greenfield-relevant.** If Structural Signals did not classify the repository as greenfield, this condition is false.
2. **Phase 2 gathered answers for both load-bearing Foundation sub-topics.** "Answered" means the user (or agent-mode auto-pick) actually selected an option — including an "Other: ..." free-text pick — and this condition requires answers for **at least** the two sub-topics Step 5's validation gate hard-checks: **folder/convention structure** (Step 5 check 3 requires a real multi-line folder tree) and **lint/format tooling** (check 4 requires a concrete tool or config filename). Answers to stack/runtime, architecture pattern, and language contribute to the synthesis when present but do not substitute for the two required ones. Merely being eligible for the category is not enough; if Adaptive Rounds never reached those Foundation questions this session, this condition is false.
   - **Why these two are mandatory:** Step 5's gate cannot pass without concrete content for them, so firing with fewer answers would force the synthesis to either fail routinely or fabricate folder/lint decisions the user never made — and a fabricated `## Folder Layout`/`## Lint and Format Config` becomes real files and acceptance criteria via `aimi-story-expander`'s `foundationEntry` handling. Partial Foundation answers are not lost: they remain in the brainstorm document's `## Key Decisions`, which `/aimi:plan` loads as context, and `/aimi:plan`'s `aimi-foundation-architect` — the prescriptive owner of defaults — proposes the rest.

If either condition is false, skip this entire phase silently: no log line, no artifact, no picker prompt. Proceed straight to Phase 4 exactly as if this phase did not exist.

*(Optional debug: if `AIMI_BRAINSTORM_DEBUG=1`, emit `[brainstorm-debug] phase-3.7: <fired|skipped> (reason: <not-greenfield|no-foundation-answers|missing-load-bearing-answers|fire>)` to chat — `missing-load-bearing-answers` when some Foundation sub-topic was answered but folder/convention structure or lint/format tooling was not.)*

Set the `phase37Verdict` working-memory variable to the same `<fired|skipped>` token computed above — read back, never recomputed, by Phase 3.8's classification summary line.
