# Brainstorm: Phase 1.8: Greenfield Foundation Detection

> Loaded by `commands/brainstorm.md` when its `Applies when:` condition holds.

## Phase 1.8: Greenfield Foundation Detection

Determine whether the target repository is greenfield using the "Structural Signals" section of `${CLAUDE_PLUGIN_ROOT}/commands/references/foundation-signals.md` — read that file and apply its detection rules as written; they are defined there and must not be restated inline here. Apply the Structural Signals only (the file's Keyword Signals section is additive-only and currently has no active consumer — `/aimi:plan`'s Phase 1.9 likewise applies Structural Signals only; see that file's "How to Combine" section).

| Bucket | Signals | Action |
|--------|---------|--------|
| **Detect** | Structural Signals classify the repository as greenfield | Mark the session as greenfield-relevant; Phase 2 includes the conditional Foundation question category |
| **Skip** | Structural Signals do not classify the repository as greenfield | Proceed unchanged — no Foundation category injected into Phase 2 |

Brainstorm does **not** spawn any dedicated foundation-synthesis agent to perform this detection or to act on it — that stays exclusive to `/aimi:plan`'s Phase 1.9 Greenfield Foundation Gate. When this phase detects greenfield structural signals, brainstorm captures the user's stack, architecture, folder-convention, and lint/format decisions through its own batched-question machinery instead (Phase 2's Foundation category, below).

If the repository is greenfield-relevant, Phase 2 generates additional questions targeting the Foundation category (stack/runtime, architecture pattern, folder/convention structure, lint/format tooling, language) alongside the standard topic categories. These Foundation questions follow the same format rules: 3-4 options, under 20 words question text, under 15 words per option, "Other" escape hatch.

When structural signals do not classify the repository as greenfield, brainstorm proceeds unchanged — Phase 2 covers only the standard topic categories (plus any UI categories from Phase 1.7) with no mention of Foundation.
