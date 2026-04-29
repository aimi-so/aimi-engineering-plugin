---
name: aimi:design:critique
description: Design critique for frontend interfaces — visual hierarchy, information architecture, anti-patterns, and Nielsen's heuristics scoring. Use when you want a design director's honest assessment of a UI.
argument-hint: "[target: URL, file, or component path]"
allowed-tools: Read, Bash(find:*), Bash(ls:*)
disable-model-invocation: false
---

> **Soft context**: If project design context is available (e.g. a `## Design Context` section in CLAUDE.md), read it for brand register, audience, and design principles before starting.

# Aimi Design Critique

Evaluate the design quality of the target interface and produce an actionable report. Think like a design director — direct, specific, honest.

## Target

$ARGUMENTS

If no target is specified, ask the user what to critique before proceeding.

## Step 1: Load References

Read these references before beginning — they are consulted throughout the critique:

- `${CLAUDE_PLUGIN_ROOT}/skills/frontend-design/references/heuristics-scoring.md` — Nielsen's 10 heuristics scoring rubric and severity definitions

Only load additional references if the critique surfaces a specific need (e.g. cognitive-load or typography detail).

## Step 2: Gather Assessments

Perform two independent assessments. Run them as separate sequential passes — do not cross-reference them until synthesis.

### Assessment A: Design Review

Read the relevant source files (HTML, CSS, JS/TS components). Think like a design director. Evaluate:

**AI Slop Detection (CRITICAL)**: Does this look like every other AI-generated interface? Check for: AI color palette, gradient text, dark glows, glassmorphism, hero metric layouts, identical card grids, generic fonts. **The test**: If someone said "AI made this," would they be believed immediately?

**Holistic Design Review**:
- Visual hierarchy — eye flow, primary action clarity
- Information architecture — structure, grouping, cognitive load
- Emotional resonance — does it match brand and audience?
- Discoverability — are interactive elements obvious?
- Composition — balance, whitespace, rhythm
- Typography — hierarchy, readability, font choices
- Color — purposeful use, cohesion
- States and edge cases — empty, loading, error, success
- Microcopy — clarity, tone, helpfulness

**Nielsen's Heuristics** (consult `${CLAUDE_PLUGIN_ROOT}/skills/frontend-design/references/heuristics-scoring.md`):
Score each of the 10 heuristics 0-4. These scores appear in the report.

Return structured findings: AI slop verdict, heuristic scores, what's working (2-3 items), priority issues (3-5 with what/why/fix), minor observations, and provocative questions.

### Assessment B: Pattern Scan

Read source files for deterministic pattern detection. Flag:
- Hard-coded colors not using design tokens
- Inconsistent spacing (random pixel values outside a scale)
- Missing interaction states (hover, focus, active, disabled, loading, error, success)
- Fixed widths that may break on mobile
- Touch targets under 44x44px
- Missing ARIA labels or semantic HTML issues (covered more deeply in `/aimi:design:audit`)
- Any AI slop tells (glassmorphism, gradient text, hero metrics, card-grid sameness)

Return: list of flagged patterns with file locations.

## Step 3: Generate Combined Critique Report

Synthesize both assessments into a single report. Do NOT simply concatenate. Weave findings together, noting where both assessments agree, where Assessment B caught issues Assessment A missed, and where pattern flags are false positives.

### Design Health Score

Consult `${CLAUDE_PLUGIN_ROOT}/skills/frontend-design/references/heuristics-scoring.md` for the scoring rubric.

Present Nielsen's 10 heuristics scores as a table:

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | ? | [specific finding or "n/a" if solid] |
| 2 | Match System / Real World | ? | |
| 3 | User Control and Freedom | ? | |
| 4 | Consistency and Standards | ? | |
| 5 | Error Prevention | ? | |
| 6 | Recognition Rather Than Recall | ? | |
| 7 | Flexibility and Efficiency | ? | |
| 8 | Aesthetic and Minimalist Design | ? | |
| 9 | Error Recovery | ? | |
| 10 | Help and Documentation | ? | |
| **Total** | | **??/40** | **[Rating band]** |

Be honest with scores. A 4 means genuinely excellent. Most real interfaces score 20-32.

### Anti-Patterns Verdict

**Start here.** Does this look AI-generated?

**Design review**: Your own evaluation of AI slop tells. Cover overall aesthetic feel, layout sameness, generic composition, missed opportunities for personality.

**Pattern scan**: Summarize what the automated pass found, with counts and file locations. Note any additional issues caught, and flag any false positives.

### Overall Impression

A brief gut reaction: what works, what doesn't, and the single biggest opportunity.

### What's Working

Highlight 2-3 things done well. Be specific about why they work.

### Priority Issues

The 3-5 most impactful design problems, ordered by importance.

For each issue, tag with **P0-P3 severity** (consult `${CLAUDE_PLUGIN_ROOT}/skills/frontend-design/references/heuristics-scoring.md` for severity definitions):
- **[P?] What**: Name the problem clearly
- **Why it matters**: How this hurts users or undermines goals
- **Fix**: What to do about it (be concrete)
- **Suggested command**: Which command could address this (from: `/aimi:design:audit`, `/aimi:design:critique`, `/aimi:design:polish`)

### Persona Red Flags

Auto-select 2-3 personas most relevant to this interface type. For each, walk through the primary user action and list specific red flags found.

Be specific. Name the exact elements and interactions that fail each persona. Don't write generic persona descriptions — write what broke for them.

### Minor Observations

Quick notes on smaller issues worth addressing.

### Questions to Consider

Provocative questions that might unlock better solutions:
- "What if the primary action were more prominent?"
- "Does this need to feel this complex?"
- "What would a confident version of this look like?"

**Remember**:
- Be direct. Vague feedback wastes everyone's time.
- Be specific. "The submit button," not "some elements."
- Say what's wrong AND why it matters to users.
- Give concrete suggestions, not just "consider exploring..."
- Prioritize ruthlessly. If everything is important, nothing is.
- Don't soften criticism. Developers need honest feedback to ship great design.

## Step 4: Ask the User

**After presenting findings**, ask targeted questions based on what was actually found. These answers will shape the action plan. Keep to 2-4 questions maximum.

Ask along these lines (adapt to specific findings — do NOT ask generic questions):

1. **Priority direction**: "I found problems with [X, Y, Z]. Which area should we tackle first?" Offer the top 2-3 issue categories as options.
2. **Design intent**: If a tonal mismatch was found, ask whether it was intentional. Offer 2-3 tonal directions.
3. **Scope**: "I found N issues. Want to address everything, or focus on the top 3?" Offer scope options.
4. **Constraints** (optional, only if relevant): "Should any sections stay as-is?"

Every question must reference specific findings. Never ask generic "who is your audience?" questions.

## Step 5: Recommended Actions

**After receiving the user's answers**, present a prioritized action summary.

List recommended commands in priority order based on the user's answers:

1. **`/aimi:design:audit`**: Brief description (specific context from critique findings)
2. **`/aimi:design:polish`**: Brief description (specific context)
...

Rules:
- Order by the user's stated priorities first, then by impact
- Each item's description should carry enough context that the command knows what to focus on
- End with `/aimi:design:polish` as the final step if any fixes were recommended
- If the user chose limited scope, only include items within that scope

After presenting the summary, tell the user:

> You can ask me to run these one at a time, all at once, or in any order you prefer.
>
> Re-run `/aimi:design:critique` after fixes to see your score improve.
