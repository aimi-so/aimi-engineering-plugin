# Brainstorm: Phase 1.7: UI Feature Detection

> Loaded by `commands/brainstorm.md` when its `Applies when:` condition holds.

## Phase 1.7: UI Feature Detection

Scan the feature description for visual/UI keywords using the "Keyword Signals" section of `${CLAUDE_PLUGIN_ROOT}/commands/references/ui-signals.md` — read that file and apply its keyword list and case-insensitive whole-word matching rule (regex word boundaries `\b`) as written; the keyword vocabulary is defined there and should not be restated inline here.

**Co-occurrence rule:** The keyword "design" alone does not trigger detection — it requires co-occurrence with at least one other keyword from the list. This prevents false positives from phrases like "system design" or "API design."

| Bucket | Signals | Action |
|--------|---------|--------|
| **Detect** | Feature description contains at least one keyword (with "design" requiring co-occurrence) | Mark the feature as UI-relevant; Phase 2 includes design-thinking questions covering visual hierarchy, interaction patterns, responsive behavior, and accessibility |
| **Skip** | No keywords match, or "design" appears alone without another keyword | Proceed unchanged — no design-category questions injected into Phase 2 |

If the feature description contains UI keywords, Phase 2 generates additional questions targeting design categories (visual hierarchy, interaction patterns, responsive behavior, accessibility) alongside the standard topic categories. These design questions follow the same format rules: 3-4 options, under 20 words question text, under 15 words per option, "Other" escape hatch.

When no keywords match, brainstorm proceeds unchanged — Phase 2 covers only the standard topic categories with no mention of design categories.
