# Brainstorm: Phase 2: Present Questions, Adaptive Rounds and Topic Coverage

> Loaded by `commands/brainstorm.md` when its `Applies when:` condition holds.

### Present Questions

Branch on `INTERACTIVE_MODE` (resolved in Step 0.5):

**If `INTERACTIVE_MODE=picker`:**

Emit **one picker call per question**. Use **AskUserQuestion** (translator
rewrites to OpenCode's native `question` tool). Each call includes the
question header + up to 4 lettered options + a final `Other` option that
accepts free-form text.

```
Picker call:
  header: "[Question informed by research or topic category]"
  options:
    A — [Option]
    B — [Option]
    C — [Option]
    Other — [free-form]
```

Do not render the questions as a single prose block. Do not ask the user to
reply with `"1A, 2C, 3B"` shorthand — pickers return the selection directly.
If a question only has two viable options, still emit it as its own picker
call; never combine questions into one picker.

**Agent-mode fallback:** if `INTERACTIVE_MODE=agent`, auto-select option A for
every question. For each question, log one line to the brainstorm document's
working memory: `agent-mode: Q<n> auto-selected option A`. Never block.

### Adaptive Rounds

After each response, assess which topic categories remain unaddressed:

| Category | Signals It's Addressed |
|----------|----------------------|
| Purpose | Problem/goal stated clearly |
| Users | Target audience identified |
| Constraints | Technical limits discussed OR confirmed none |
| Success | Measurable outcome defined |
| Edge Cases | Error states/boundaries discussed |
| Existing Patterns | Codebase context available (from research or user) |
| Approach | At least one approach preference expressed by user via selection or free-form response |
| Aesthetic Direction | User expresses an aesthetic preference, tone, or visual direction |
| Differentiation | User identifies a memorable or distinguishing visual aspect |
| Foundation | User expresses a stack/runtime, architecture, folder-convention, lint/tooling, or language preference |

- **If all key topics covered (7 standard, plus 2 when UI features detected, plus 1 when Foundation detected in Phase 1.8)** OR **user says "proceed"/"let's move on"** → advance to Phase 3
- **If topics remain uncovered** AND **under 4 rounds** → generate follow-up batch targeting uncovered topics
- **If 4 rounds completed** → advance to Phase 3 regardless

### Quality Gate: Topic Coverage

Before advancing to Phase 3, check whether the **minimum topic categories** have been addressed across all Phase 2 rounds:

**Required categories:** Purpose, Users, Success

Review the user's answers across all rounds. A category counts as addressed if the user provided any relevant information — even brief or partial.

**Bundle pre-fill:** When `bundleDetected=true` and `bundleAddressedTopics` is populated (set in Step 1c), any required category present in `bundleAddressedTopics` is considered addressed before this gate evaluates user answers. Apply this pre-fill silently — do not warn the user that a category was covered by the bundle.

**BusinessSpec auto-pass:** When `bundleDetected=true` and the design-bundle researcher returned a non-null `businessSpec` path, the following required categories are auto-passed **before** this gate evaluates user answers or bundle pre-fill:

| Category | Source section |
|----------|---------------|
| Purpose | `BusinessSpec § 1` |
| Users | `BusinessSpec § 7` |
| Success | `BusinessSpec § 9` |

For each auto-passed category, log: `agent-mode: topic-coverage <category> auto-passed (source: businessSpec § <n>)` (e.g., `agent-mode: topic-coverage Purpose auto-passed (source: businessSpec § 1)`). These log lines are written to the brainstorm document's working memory and never shown to the user.

**Aesthetic Direction and Differentiation skips:** When `bundleDetected=true` and the design-bundle researcher returned a non-null `designSpec` path, skip generating questions in the **Aesthetic Direction** and **Differentiation** categories entirely — `DesignSpec § 1` (design tokens), `§ 4` (reference maps), and `§ 5` (accessibility) constitute an authoritative statement of visual intent. For each skipped category, log: `agent-mode: phase-2 <category> skipped (source: designSpec present)` (e.g., `agent-mode: phase-2 Aesthetic Direction skipped (source: designSpec present)`). These log lines are written to the brainstorm document's working memory. Do not mention the skip to the user.

- **If all three are addressed (via user answers, bundle pre-fill, or both):** Proceed to Phase 3 (or skip it per its own rules).
- **If any are missing:** Issue a **one-time** conversational warning listing the gaps:
  > "Before we continue, I notice we haven't covered [list uncovered categories, e.g., 'who the target users are' or 'how we'd measure success']. Want to explore those, or should we proceed?"
  - If the user provides answers, incorporate them and proceed.
  - If the user says "proceed", "let's move on", or similar, accept the override and proceed.
  - **Do not repeat this warning** — it fires at most once per session.

**Precedence rules:**
- A user "proceed" directive always takes precedence over this gate.
- The 4-round limit takes precedence over this gate — if 4 rounds are completed, proceed regardless.
