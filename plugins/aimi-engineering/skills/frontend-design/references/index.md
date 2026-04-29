# References Index

Registry that maps brainstorm reply keywords to design reference files. The
/aimi:brainstorm skill lazy-loads only the files matched by the user's reply,
keeping context small and guidance relevant.

---

## Keyword → File Mapping

| User reply contains... | Load |
|---|---|
| typography, font, fonts, type, hierarchy of text | `./typography.md` |
| color, palette, contrast, accent, brand color, theme, dark, light | `./color-and-contrast.md` |
| spacing, layout, rhythm, alignment, density, padding, margin, grid | `./spatial-design.md` |
| motion, animation, transition, hover, micro-interaction, scroll | `./motion-design.md` |
| responsive, mobile, tablet, breakpoint, viewport | `./responsive-design.md` |
| copy, label, error, microcopy, voice, tone of writing | `./ux-writing.md` |
| hierarchy, scan, focus, attention, cognitive load | `./cognitive-load.md` |
| affordance, feedback, state, form, input, validation | `./interaction-design.md` |
| critique, score, audit, heuristic | `./heuristics-scoring.md` |

Multiple keywords matched → load all matched files. Cap at 3 files per round.

---

## Brand vs. Product Resolver

| Topic contains... | Register | Load |
|---|---|---|
| landing, marketing, brand site, campaign, hero, portfolio, long-form | brand | `./brand.md` |
| dashboard, admin, app, tool, settings, in-app form, table, list, console, panel | product | `./product.md` |
| no match | (default) | `./product.md` |

User override: typing **brand** or **product** mid-brainstorm switches the
register and reloads the appropriate file immediately.

---

## Loading Rules

- **3-file cap per round** — match at most 3 reference files per brainstorm
  turn. If more than 3 keywords match, load the first 3 by table order.
- **No re-load** — a file already loaded in the current session is not loaded
  again even if re-matched in a later round.
- **Override switch** — typing `brand` or `product` at any point replaces the
  active register file (`./brand.md` or `./product.md`) regardless of earlier
  topic detection.
