---
name: aimi:design:polish
description: Final-pass polish for frontend interfaces — catches the small details that separate good work from great work. Use after a feature is functionally complete and you want to align it to the design system, fix visual inconsistencies, and bring everything to a consistent quality level.
argument-hint: "[target: file, component path, or feature area] [--non-interactive]"
allowed-tools: Read, Write, Edit, Bash(find:*), Bash(ls:*), Bash(AIMI_CLI=*), Bash($AIMI_CLI:*), Task
disable-model-invocation: false
---

# Aimi Design Polish

Perform a meticulous final pass to catch all the small details that separate good work from great work. The difference between shipped and polished.

## Step 0: Environment Setup

### Resolve CLI Path

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/cli-path-resolution.md` and follow the **Resolve CLI Path** and **Version Check** sections to set `$AIMI_CLI`. Each layer is a separate Bash call.

If resolution fails, fall back to a default of `INTERACTIVE_MODE=picker` and log: `warning: aimi-cli.sh unresolved — forcing INTERACTIVE_MODE=picker`.

**Each Bash tool call is an isolated shell — `$AIMI_CLI` does not persist.** Re-read the cache at the top of every subsequent Bash call that needs `$AIMI_CLI`. See the **Per-Call Resolution** section of `commands/references/cli-path-resolution.md` for the one-liner and shell guard to prepend.

### Extract --non-interactive Flag

Before using `$ARGUMENTS` as a polish target, check whether the user passed `--non-interactive`:

```bash
NON_INTERACTIVE_FLAG=""
case "$ARGUMENTS" in
  *--non-interactive*)
    NON_INTERACTIVE_FLAG="--non-interactive"
    ;;
esac
```

Strip the token from `$ARGUMENTS` so it is not treated as a target path:

```bash
POLISH_TARGET=$(echo "$ARGUMENTS" | sed 's/--non-interactive//g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
```

Use `$POLISH_TARGET` wherever `$ARGUMENTS` would have been used as the polish target for the rest of this command.

### Detect Interactivity

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
INTERACTIVE_MODE=$($AIMI_CLI detect-interactivity $NON_INTERACTIVE_FLAG)
```

- `picker` — interactive user. Present questions using **AskUserQuestion** (one per tool call).
- `agent` — `--non-interactive`, `AIMI_AGENT_MODE=true`, or `CI=true`. At every question site, auto-pick the documented default and log one line. Never block, never prompt.

See `references/interactivity.md` for the full contract.

### Resolve Agent Models

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/cli-path-resolution.md` — **Resolve Agent Models** section — and follow it to populate `AGENT_MODELS`. Re-read `$AIMI_CLI` from cache in the same Bash call:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
AGENT_MODELS=$($AIMI_CLI resolve-models)
```

Store `AGENT_MODELS` for use by every `Task subagent_type="aimi-engineering:CATEGORY:NAME"` call in this command. At each spawn site, extract the model for the agent's `CATEGORY` and apply it per the **Applying the resolved model to a Task call** rules in `cli-path-resolution.md`. When resolution fails, treat every category as `"inherit"` and continue.

> **Soft context**: Ask the user for the quality bar (MVP vs flagship) if not clear from context.
>
> *Agent-mode fallback: if `INTERACTIVE_MODE=agent`, infer the quality bar from surrounding code context (commit messages, design-system tier, existing component polish level) and proceed without asking. Log: `agent-mode: quality-bar auto-inferred from codebase context`.*

## Target

$POLISH_TARGET

If no target is specified, ask the user what to polish before proceeding.

*Agent-mode fallback: if `INTERACTIVE_MODE=agent` and `$POLISH_TARGET` is empty, abort with: `agent-mode: no polish target specified and --non-interactive set — provide a target path or feature area`. If `$POLISH_TARGET` is non-empty, proceed with it as-is without asking for confirmation. Log: `agent-mode: target auto-accepted: $POLISH_TARGET`.*

**CRITICAL**: Polish is the last step, not the first. Don't polish work that's not functionally complete.

## Step 1: Design System Discovery

Aligning the feature to the design system is **not optional**. Polish without alignment is decoration on top of drift, and it makes the next person's job harder. Discovery comes before any other polish work.

1. **Find the design system**: Search for design system documentation, component libraries, style guides, or token definitions. Study the core patterns: design principles, target audience, color tokens, spacing scale, typography styles, component API, motion conventions.
2. **Note the conventions**: How are shared components imported? What spacing scale is used? Which colors come from tokens vs hard-coded values? What motion and interaction patterns are established? What flow shapes are used for comparable actions?
3. **Identify drift, then name the root cause**: For every deviation, classify it as a **missing token** (value should exist in the system but doesn't), a **one-off implementation** (a shared component already exists but wasn't used), or a **conceptual misalignment** (the feature's flow, IA, or hierarchy doesn't match neighboring features). The fix differs by category — patch the value, swap to the shared component, or rework the flow.

If a design system exists, polish **must** align the feature with it. If none exists, polish against the conventions visible in the codebase. **If anything about the system is ambiguous, ask — never guess at design system principles.**

## Step 2: Pre-Polish Assessment

Understand the current state and goals before touching anything:

1. **Review completeness**:
   - Is it functionally complete?
   - Are there known issues to preserve (mark with TODOs)?
   - What's the quality bar? (MVP vs flagship feature?)
   - When does it ship? (How much time for polish?)

2. **Think experience-first**: Who actually uses this, and what's the best possible experience for them? Effective design beats decorative polish — a feature that looks beautiful but fights the user's flow is not polished. Walk the path from their perspective before opening DevTools.

3. **Identify polish areas**:
   - Visual inconsistencies
   - Spacing and alignment issues
   - Interaction state gaps
   - Copy inconsistencies
   - Edge cases and error states
   - Loading and transition smoothness
   - Information architecture and flow drift

4. **Triage cosmetic vs functional**: Classify each issue as **cosmetic** (looks off, doesn't impede the user) or **functional** (breaks, blocks, or confuses the experience). When polish time is tight, functional issues ship first; cosmetic ones can land in a follow-up.

## Visual Iteration Pass (Optional)

> **Default path**: The manual polish checklist in Steps 3–6 is always the default. This section is an optional, additive pass that runs a screenshot-driven refinement loop *before* the manual checklist when a live preview is available. When the conditions below are not met, skip this section entirely and proceed directly to Step 3 — no error, no warning.

**Trigger conditions** — all three must be true to activate this pass:

1. The polish target renders in a browser (it is a UI component, page, or feature with visual output).
2. A running preview URL is available (e.g. `http://localhost:3000`, a staging URL, or any URL the browser can reach right now).
3. The `agent-browser` skill is available in the current session.

**When all three conditions are met**, spawn the design iterator as a Task subagent:

```
Task subagent_type="aimi-engineering:design:aimi-design-iterator"
  [model: <AGENT_MODELS.design when not "inherit">]

Pass to the agent:
- Design-system context discovered in Step 1: token names, spacing scale, component library, color palette, motion conventions, and any drift root-cause classifications identified.
- Quality bar established in Step 2: MVP vs flagship, known issues to preserve, time constraint, and the prioritised list of polish areas identified (cosmetic vs functional triage).
- The live preview URL.

Let the iterator run its screenshot-driven loop. When it finishes, review its output before proceeding.
```

After the iterator completes, continue with Step 3 to apply any remaining manual polish not covered by the automated pass. The iterator is additive — it does not replace the systematic checklist.

## Step 3: Polish Systematically

Work through these dimensions methodically:

### Visual Alignment and Spacing

- Pixel-perfect alignment: everything lines up to grid
- Consistent spacing: all gaps use spacing scale (no random 13px gaps)
- Optical alignment: adjust for visual weight (icons may need offset for optical centering)
- Responsive consistency: spacing and alignment work at all breakpoints
- Grid adherence: elements snap to baseline grid

### Information Architecture and Flow

Visual polish on a misshapen flow is wasted work. Match the *shape* of the experience to the system, not just the surface.

- **Progressive disclosure**: Match how much is revealed when, compared to neighboring features.
- **Established user flows**: Multi-step actions follow the same shape as comparable flows elsewhere — modal vs full-page, inline edit vs separate route, save-on-blur vs explicit submit.
- **Hierarchy and complexity**: The same conceptual weight gets the same visual weight throughout.
- **Naming and mental model**: The feature uses the same nouns and verbs as the rest of the system.

### Typography Refinement

- Hierarchy consistency: same elements use same sizes/weights throughout
- Line length: 45-75 characters for body text
- Line height: appropriate for font size and context
- Widows and orphans: no single words on last line
- Kerning: adjust letter spacing where needed (especially headlines)
- Font loading: no FOUT/FOIT flashes

### Color and Contrast

- Contrast ratios: all text meets WCAG standards
- Consistent token usage: no hard-coded colors, all use design tokens
- Theme consistency: works in all theme variants
- Color meaning: same colors mean same things throughout
- Accessible focus: focus indicators visible with sufficient contrast
- Tinted neutrals: no pure gray or pure black — add subtle color tint (0.01 chroma)
- Gray on color: never put gray text on colored backgrounds — use a shade of that color or transparency

### Interaction States

Every interactive element needs all states:

- **Default**: Resting state
- **Hover**: Subtle feedback (color, scale, shadow)
- **Focus**: Keyboard focus indicator (never remove without replacement)
- **Active**: Click/tap feedback
- **Disabled**: Clearly non-interactive
- **Loading**: Async action feedback
- **Error**: Validation or error state
- **Success**: Successful completion

**Missing states create confusion and broken experiences**.

### Micro-interactions and Transitions

- Smooth transitions: all state changes animated appropriately (150-300ms)
- Consistent easing: use ease-out-quart/quint/expo for natural deceleration. Never bounce or elastic — they feel dated.
- No jank: smooth animations; use atmospheric blur/filter/mask/shadow effects when they add polish, but bound expensive paint areas and avoid casual layout-property animation
- Appropriate motion: motion serves purpose, not decoration
- Reduced motion: respects `prefers-reduced-motion`

### Content and Copy

- Consistent terminology: same things called same names throughout
- Consistent capitalization: Title Case vs Sentence case applied consistently
- Grammar and spelling: no typos
- Appropriate length: not too wordy, not too terse
- Punctuation consistency: periods on sentences, not on labels (unless all labels have them)

### Icons and Images

- Consistent style: all icons from same family or matching style
- Appropriate sizing: icons sized consistently for context
- Proper alignment: icons align with adjacent text optically
- Alt text: all images have descriptive alt text
- Loading states: images don't cause layout shift, proper aspect ratios
- Retina support: 2x assets for high-DPI screens

### Forms and Inputs

- Label consistency: all inputs properly labeled
- Required indicators: clear and consistent
- Error messages: helpful and consistent
- Tab order: logical keyboard navigation
- Auto-focus: appropriate (don't overuse)
- Validation timing: consistent (on blur vs on submit)

### Edge Cases and Error States

- Loading states: all async actions have loading feedback
- Empty states: helpful empty states, not just blank space
- Error states: clear error messages with recovery paths
- Success states: confirmation of successful actions
- Long content: handles very long names, descriptions, etc.
- No content: handles missing data gracefully

### Responsiveness

- All breakpoints: test mobile, tablet, desktop
- Touch targets: 44x44px minimum on touch devices
- Readable text: no text smaller than 14px on mobile
- No horizontal scroll: content fits viewport
- Appropriate reflow: content adapts logically

### Code Quality

- Remove console logs: no debug logging in production
- Remove commented code: clean up dead code
- Remove unused imports: clean up unused dependencies
- Consistent naming: variables and functions follow conventions

## Step 4: Polish Checklist

Go through systematically:

- [ ] Aligned to the design system (drift named and resolved by root cause)
- [ ] Information architecture and flow shape match neighboring features
- [ ] Visual alignment perfect at all breakpoints
- [ ] Spacing uses design tokens consistently
- [ ] Typography hierarchy consistent
- [ ] All interactive states implemented
- [ ] All transitions smooth (60fps)
- [ ] Copy is consistent and polished
- [ ] Icons are consistent and properly sized
- [ ] All forms properly labeled and validated
- [ ] Error states are helpful
- [ ] Loading states are clear
- [ ] Empty states are welcoming
- [ ] Touch targets are 44x44px minimum
- [ ] Contrast ratios meet WCAG AA
- [ ] Keyboard navigation works
- [ ] Focus indicators visible
- [ ] No console errors or warnings
- [ ] No layout shift on load
- [ ] Works in all supported browsers
- [ ] Respects reduced motion preference
- [ ] Code is clean (no TODOs, console.logs, commented code)

**IMPORTANT**: Polish is about details. Zoom in. Squint at it. Use it yourself. The little things add up.

## Step 5: Final Verification

Before marking as done:

- **Use it yourself**: Actually interact with the feature
- **Test on real devices**: Not just browser DevTools
- **Compare to design**: Match intended design
- **Check all states**: Don't just test happy path

## Step 6: Clean Up

After polishing, ensure code quality:

- **Replace custom implementations**: If the design system provides a component you reimplemented, switch to the shared version.
- **Remove orphaned code**: Delete unused styles, components, or files made obsolete by polish.
- **Consolidate tokens**: If you introduced new values, check whether they should be tokens.
- **Verify DRYness**: Look for duplication introduced during polishing and consolidate.

**NEVER**:
- Polish before it's functionally complete
- Polish without aligning to the design system — that's decoration on drift
- Guess at design system principles instead of asking when something is ambiguous
- Spend hours on polish if it ships in 30 minutes (triage)
- Introduce bugs while polishing (test thoroughly)
- Ignore systematic issues (if spacing is off everywhere, fix the system, not just one screen)
- Perfect one thing while leaving others rough (consistent quality level)
- Create new one-off components when design system equivalents exist
- Hard-code values that should use design tokens
- Introduce new patterns or flows that diverge from established ones

Remember: You have impeccable attention to detail and exquisite taste. Polish until it feels effortless, looks intentional, and works flawlessly. Sweat the details — they matter.
