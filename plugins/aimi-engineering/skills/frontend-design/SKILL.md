---
name: frontend-design
description: >
  Use when the user wants to design, redesign, shape, critique, audit, polish, clarify,
  distill, harden, optimize, adapt, animate, colorize, extract, or otherwise improve a
  frontend interface. Covers websites, landing pages, dashboards, product UI, app shells,
  components, forms, settings, onboarding, and empty states. Handles UX review, visual
  hierarchy, information architecture, cognitive load, accessibility, performance,
  responsive behavior, theming, anti-patterns, typography, fonts, spacing, layout,
  alignment, color, motion, micro-interactions, UX copy, error states, edge cases, i18n,
  and reusable design systems or tokens. Also use for bland designs that need to become
  bolder or more delightful, loud designs that should become quieter, live browser
  iteration on UI elements, or ambitious visual effects that should feel technically
  extraordinary. Trigger keywords: design, UI, interface, frontend, visual, layout,
  typography, color, spacing, motion, responsive, component, theme, palette, animation,
  accessibility, UX, wireframe, prototype. Not for backend-only or non-UI tasks.
version: 1.0.0
license: Apache-2.0 (NOTICE.md)
---

Designs and iterates production-grade frontend interfaces. Real working code, committed
design choices, exceptional craft.

## Setup

If the user's task references a clear product context (brand voice, target users, existing
design tokens), ask once for that context if it's genuinely absent and would change the
answer. Do not gate on PRODUCT.md — soft prompt only. If context is missing and the task
is narrow enough to proceed without it, proceed.

## Register

Every design task is **brand** (marketing, landing, campaign, long-form content, portfolio
— design IS the product) or **product** (app UI, admin, dashboard, tool — design SERVES
the product).

Identify before designing. Priority: (1) cue in the task itself ("landing page" vs
"dashboard"); (2) the surface in focus (the page, file, or route being worked on); (3)
any register field or equivalent in project context. First match wins.

Load the matching reference on demand:
- Brand tasks: `references/brand.md`
- Product tasks: `references/product.md`

The shared design laws below apply to both registers.

## Shared Design Laws

Apply to every design, both registers. Match implementation complexity to the aesthetic
vision — maximalism needs elaborate code, minimalism needs precision. Interpret
creatively. Vary across projects; never converge on the same choices.

### Color

- Use OKLCH. Reduce chroma as lightness approaches 0 or 100 — high chroma at extremes
  looks garish.
- Never use `#000` or `#fff`. Tint every neutral toward the brand hue (chroma 0.005–0.01
  is enough).
- Pick a **color strategy** before picking colors. Four steps on the commitment axis:
  - **Restrained** — tinted neutrals + one accent ≤10%. Product default; brand minimalism.
  - **Committed** — one saturated color carries 30–60% of the surface. Brand default for
    identity-driven pages.
  - **Full palette** — 3–4 named roles, each used deliberately. Brand campaigns; product
    data viz.
  - **Drenched** — the surface IS the color. Brand heroes, campaign pages.
- The "one accent ≤10%" rule is Restrained only. Committed / Full palette / Drenched
  exceed it on purpose. Do not collapse every design to Restrained by reflex.

### Theme

Dark vs. light is never a default. Not dark "because tools look cool dark." Not light "to
be safe."

Before choosing, write one sentence of physical scene: who uses this, where, under what
ambient light, in what mood. If the sentence doesn't force the answer, it's not concrete
enough — add detail until it does.

"Observability dashboard" does not force an answer. "SRE glancing at incident severity on
a 27-inch monitor at 2am in a dim room" does. Run the sentence, not the category.

### Typography

- Cap body line length at 65–75ch.
- Hierarchy through scale + weight contrast (≥1.25 ratio between steps). Avoid flat
  scales.
- Choose fonts that are characterful. Avoid generic defaults (Inter, Roboto, Arial,
  system-ui) unless the design brief calls for invisible infrastructure typography.

### Layout

- Vary spacing for rhythm. Same padding everywhere is monotony.
- Cards are the lazy answer. Use them only when they're truly the best affordance. Nested
  cards are always wrong.
- Do not wrap everything in a container. Most things don't need one.

### Motion

- Do not animate CSS layout properties.
- Ease out with exponential curves (ease-out-quart / quint / expo). No bounce, no elastic.
- Prioritize high-impact moments: one well-orchestrated page load with staggered reveals
  creates more delight than scattered micro-interactions.

### Absolute Bans

Match-and-refuse. If you are about to write any of these, rewrite the element with
different structure.

- **Side-stripe borders.** `border-left` or `border-right` greater than 1px as a colored
  accent on cards, list items, callouts, or alerts. Never intentional. Rewrite with full
  borders, background tints, leading numbers/icons, or nothing.
- **Gradient text.** `background-clip: text` combined with a gradient background.
  Decorative, never meaningful. Use a single solid color. Emphasis via weight or size.
- **Glassmorphism as default.** Blurs and glass cards used decoratively. Rare and
  purposeful, or nothing.
- **The hero-metric template.** Big number, small label, supporting stats, gradient
  accent. SaaS cliché.
- **Identical card grids.** Same-sized cards with icon + heading + text, repeated
  endlessly.
- **Modal as first thought.** Modals are usually laziness. Exhaust inline / progressive
  alternatives first.

### Copy Rules

- Every word earns its place. No restated headings, no intros that repeat the title.
- **No em dashes.** Use commas, colons, semicolons, periods, or parentheses. Also not
  `--`.

### The AI-Slop Test

If someone could look at this interface and say "AI made that" without doubt, it has
failed. Cross-register failures are the absolute bans above. Register-specific failures
live in each reference file.

**Category-reflex check.** If someone could guess the theme and palette from the category
name alone — "observability → dark blue", "healthcare → white + teal",
"finance → navy + gold", "crypto → neon on black" — it's the training-data reflex.
Rework the scene sentence and color strategy until the answer is no longer obvious from
the domain.

## References

Load these on demand, not eagerly. Read the relevant file only when the task requires that
depth.

| File | When to load |
|---|---|
| `references/brand.md` | Brand-register tasks |
| `references/product.md` | Product-register tasks |
| `references/typography.md` | Typography deep-dives, font pairing, type scale |
| `references/color-and-contrast.md` | Color system work, contrast audits, token design |
| `references/spatial-design.md` | Layout systems, spacing, rhythm, grid |
| `references/motion-design.md` | Animation implementation, timing, choreography |
| `references/interaction-design.md` | Micro-interactions, states, affordances |
| `references/responsive-design.md` | Breakpoint strategy, adaptive layouts |
| `references/ux-writing.md` | Copy, labels, error messages, onboarding text |
| `references/cognitive-load.md` | Information architecture, progressive disclosure |
| `references/heuristics-scoring.md` | Structured UX audits with scoring |
| `references/personas.md` | User archetypes for context-setting |

See `references/index.md` for a lazy-load index (useful when brainstorming or when an
agent needs to discover what's available without loading everything).
