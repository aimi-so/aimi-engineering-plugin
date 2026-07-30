# Visual Variant Authoring Reference

Shared reference for the `/aimi:brainstorm` agent when generating multi-variant HTML prototype files. This is the single source of truth for path patterns, HTML structure, safety rules, and append semantics.

## Output Path Pattern

Variant files MUST be written to:

```
.aimi/brainstorms/prototypes/[topic-slug]-variants.html
```

Example: topic "login flow" → `.aimi/brainstorms/prototypes/login-flow-variants.html`

The `[topic-slug]` is derived from the brainstorm topic using the slug-sanitization rule below. The directory `.aimi/brainstorms/prototypes/` must exist before writing; create it with `mkdir -p` if absent.

## Topic-Slug Sanitization

Apply before constructing any file path. Reject or abort if the slug does not pass all checks.

**Algorithm:**

1. Lowercase the raw topic string.
2. Replace runs of whitespace and underscores with `-`.
3. Strip all characters that are not `[a-z0-9-]`.
4. Collapse consecutive `-` into one.
5. Trim leading and trailing `-`.

**Validation — reject slugs that:**

- Match `..` anywhere in the result (directory traversal).
- Start with `/` (absolute-path injection).
- Contain `/` at any position (subdirectory traversal).
- Do NOT match regex `^[a-z0-9][a-z0-9-]*$` (must start with alphanumeric, only lowercase alphanumeric and hyphens allowed).

**Prototype paths MUST pass this check before any file write.** If the slug fails, report the invalid topic to the user and stop — do not fall back to an unvalidated path.

## HTML-Escaping User-Supplied Strings

Every user-supplied string (option label, question text, description, any free-form input) MUST be HTML-escaped before interpolation into the variant HTML. Apply these substitutions in order:

| Character | Escaped form |
|-----------|-------------|
| `&`       | `&amp;`     |
| `<`       | `&lt;`      |
| `>`       | `&gt;`      |
| `"`       | `&quot;`    |
| `'`       | `&#39;`     |

No raw user content may appear unescaped inside any HTML attribute, text node, or Alpine.js expression.

**Alpine.js `x-data` / string-literal contexts:** if a future extension embeds user-supplied strings inside an `x-data` JavaScript expression or any other JavaScript string literal, HTML-escaping alone is insufficient — JavaScript-escape (`\\` → `\\\\`, `'` → `\\'`, `"` → `\\"`, newline → `\\n`) **before** HTML-escaping. The current switcher keeps all user-supplied strings in HTML text nodes and attributes only; variants that add inline JS must apply both escape passes.

## Switcher Skeleton

Each variant file uses this skeleton. The switcher bar is always rendered at the top of `<body>` and must not depend on Tailwind for its functional structure — only class names are Tailwind; the switcher works unstyled if the CDN is unreachable.

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>[Escaped Topic] — Variants</title>
  <!-- Tailwind Play CDN: styling only. Switcher functions without it. -->
  <script src="https://cdn.tailwindcss.com"></script>
  <!--
    OFFLINE NOTE: If this page renders unstyled, the Tailwind CDN is unavailable.
    All variant switching still works — no JavaScript depends on Tailwind.
  -->
  <noscript>JavaScript is required for variant switching.</noscript>
</head>
<body>
  <!-- Switcher bar -->
  <div x-data="{ active: 'A' }" id="variant-root">
    <nav>
      <template x-for="v in variants" :key="v.id">
        <button
          @click="active = v.id"
          :aria-pressed="active === v.id"
          x-text="v.id + ': ' + v.label">
        </button>
      </template>
    </nav>

    <!-- Variant slots: 2–4 per question, added by agent -->
    <section data-question="[escaped-question-text]">
      <div x-show="active === 'A'" data-variant="A">
        <!-- Variant A content -->
      </div>
      <div x-show="active === 'B'" data-variant="B">
        <!-- Variant B content -->
      </div>
      <!-- Additional variants C, D added only when agent determines they add value -->
    </section>

    <!-- Subsequent questions appended as additional <section> blocks below -->

  </div>

  <script>
    // Alpine.js x-data state bootstrap
    document.addEventListener('alpine:init', () => {
      // variants list is populated per question section
    });
  </script>
  <script defer src="https://unpkg.com/alpinejs@3.x.x/dist/cdn.min.js"></script>
</body>
</html>
```

## Alpine.js x-data / x-show Switcher Rules

- Root `x-data` holds `{ active: 'A' }` — tracks selected variant letter.
- Each variant `<div>` uses `x-show="active === 'X'"` where `X` is `A`, `B`, `C`, or `D`.
- Switcher buttons use `@click="active = v.id"` and `:aria-pressed="active === v.id"` for accessibility.
- The `x-data` scope MUST be on the outermost wrapper element (`#variant-root`) so all child `x-show` directives share the same reactive state.
- No `x-if` — use `x-show` so all variant DOM nodes are pre-rendered (avoids flicker on switch).

## Tailwind CDN Offline Behavior

- Include `<script src="https://cdn.tailwindcss.com"></script>` for styling.
- Place an HTML comment immediately after the tag warning that the page renders unstyled if the CDN is unavailable but switching still works.
- Include `<noscript>` tag informing the viewer that JavaScript is required for variant switching.
- **The switcher MUST NOT depend on Tailwind classes for its logical behavior.** Tailwind classes are cosmetic only; removing them must not break button click → content switch behavior.

## Variant Count and Append Semantics

**Variant count:** The agent decides 2–4 variants per question based on the meaningful design axes available. Default to 2 when the question has a clear binary contrast; add 3 or 4 only when distinct additional directions genuinely add value. Never generate a single variant (no comparison value) or more than 4 (cognitive overload).

**Append semantics:** Each visual question gets one `<section data-question="[escaped-question-text]">` block. When the brainstorm session produces multiple questions:

- Write the first question's section when creating the file.
- **Append** each subsequent question's `<section>` block to the existing file — do NOT overwrite or truncate the file.
- The switcher `x-data` state is shared across all sections; all sections respond to the same `active` variable so changing the variant letter switches all questions simultaneously.
- The `data-question` attribute value MUST be the HTML-escaped question string.

## Structural Guidance

Variants exist to show the user *directions* for the feature they described, rendered as they would feel inside the target project. Tokens carry color, font, and spacing; **structural guidance** covers the HTML shape the variant should use so the mockup looks like it belongs in the target app — not a generic Tailwind demo page.

### Step 1 — Infer the dominant UI pattern

From the feature description and the specific question being answered, classify the dominant UI pattern into one of the canonical shapes below. When unsure, pick the shape that most closely matches the nouns in the feature description ("a login page" → form, "a settings dashboard" → layout-with-sidebar).

| Canonical shape     | Use when the feature involves…                                  | Dominant elements                              |
|---------------------|-----------------------------------------------------------------|------------------------------------------------|
| `form`              | user input, auth, filing, submit-style interactions             | `<form>`, labels, inputs, primary submit button |
| `card`              | listing items, previewing records, dashboard tiles              | `<article>` per item, heading, body, actions   |
| `nav`               | top/side navigation, menus, routing between views               | `<nav>`, logo area, links, active state        |
| `hero`              | landing, marketing, empty-state, onboarding first screen        | large heading, supporting copy, primary CTA    |
| `modal`             | focused task, confirmation, inline editing overlays             | centered panel, backdrop, close affordance     |
| `table`             | tabular/row data, admin views, reports                          | `<table>`, column headers, rows, row actions   |
| `layout-with-sidebar` | settings/dashboard shells with persistent nav + main content | sidebar, main content area, optional header    |

A single variant MAY combine shapes (e.g., a `layout-with-sidebar` containing a `table`). Do not invent shapes outside this list — extend the file if a new canonical shape is repeatedly needed.

### Step 2 — Express each variant using the canonical shape

Each `<div data-variant="X">` block uses the HTML shape selected in Step 1. Keep the structure consistent across variants so the user compares **direction**, not **layout**.

**Invariants — hold constant across all variants regardless of branch:**

- Same canonical shape across all variants in the same question.
- Same primary-action label text across variants (e.g., all variants' submit button reads "Sign in", not "Sign in" / "Log in" / "Continue").
- Same content density (rough count of items, fields, links) across variants.

**What varies between A/B/C/D depends on the active branch** (see `brainstorm.md` Phase 2 Step 2.5 — Branch Decision for the selection rule):

- **When UX branch is active (default):** vary layout structure inside the canonical shape, primary-action placement within the form or container, content arrangement (e.g., single-column vs. two-column, label above vs. inline), and progressive-disclosure pattern (e.g., collapsed vs. expanded secondary fields). Token values are identical across UX variants — the CSS custom properties on `:root` do not change between A/B/C/D.

- **When UI branch is active** (activates only when token extraction falls back fully with no extractable design tokens, or when the user supplies the `vary ui` override): vary typography weight and rhythm, color-weighted vs. monochrome palette, density (airy vs. compact spacing), border-radius (sharp vs. soft), shadow depth, and accent placement. Layout structure inside the canonical shape remains fixed.

### Step 3 — Emit tokens as CSS custom properties on `:root`

Resolved tokens (Token Extraction, below) are emitted once at the top of the authored HTML as CSS custom properties on `:root`, and variants reference them via Tailwind arbitrary-value syntax (e.g., `bg-[var(--color-primary)]`, `rounded-[var(--radius-md)]`). Dark-mode tokens go on `.dark :root` (when strategy is `class`) or inside a `@media (prefers-color-scheme: dark)` block (when strategy is `media`).

```html
<style>
  :root {
    --color-primary: #0066ff;
    --color-background: #ffffff;
    --font-sans: 'Inter', system-ui, sans-serif;
    --radius-md: 0.5rem;
    --shadow-sm: 0 1px 2px rgba(0,0,0,0.05);
  }
  .dark :root {
    --color-background: #0b0b0b;
    --color-primary: #4d8bff;
  }
</style>
```

This makes tokens both visible to the user (one block to scan) and trivially translatable at implementation time — the target project's native CSS stack swaps the literal values back in.

### Step 4 — Component-shell scan (optional)

If `references/visual-variants.md` is being read from a brainstorm that already performed a component-shell scan (see `brainstorm.md` Phase 2 "Component Shell Scan"), use the extracted structural patterns (wrapper tags, spacing idioms, primary-action class recipes) as additional structural constraints alongside the canonical shape. Component-shell findings *narrow* structural choices; they do not replace the canonical shape selection.

## Reference Intake

At the Phase 3.6 gate, the brainstorm agent may offer the user an optional opportunity to supply an external visual reference before Token Extraction (below) runs. Intake is entirely optional: if the user declines or offers nothing, the agent proceeds straight to Token Extraction using only the project-source probes. When a reference is supplied, it resolves as **Probe #0** — the highest-precedence token source in the whole extraction chain (see "Precedence — Probe #0" below).

### Input Kinds

Exactly three input kinds are accepted:

1. **Local file path** — an image (`.png`, `.jpg`, `.jpeg`, `.webp`, `.gif`, `.svg`), an `.html` file, or a `.css` file, read via the Read tool. This is a **read-only reference path**, and unlike written prototype/output paths governed by "## Output Path Pattern" and "## Topic-Slug Sanitization" above, it MAY resolve **outside AIMI_ROOT** — the user is pointing at an existing design artifact anywhere on disk, not asking the agent to write one. Path traversal into system directories (e.g. `/etc`, `/proc`, `/sys`, or other absolute paths outside any reasonable project or home boundary) is still forbidden, and the file is **never executed** — it is read as plain data only (pixels, markup, or CSS text), identically to every project-source probe below.

2. **URL** — opened via the existing `agent-browser` session described in "## Browser Session Lifecycle" below. The agent takes a screenshot of the rendered page and extracts palette, typography, and spacing cues from what renders. This reuses that lifecycle's open/reload/close/fallback mechanics as-is — intake does not open a second browser or invent a new fetch mechanism; if the Browser Session Lifecycle's own fallback rules are already engaged (e.g. `agent-browser` unavailable), URL intake degrades the same way (see "Sanitization and Failure Degradation" below).

3. **Free-text style directive** — a short natural-language description of a desired look (e.g. "estilo Linear, dark, tipografia densa"). This kind yields no extracted token files at all; it is an **authoring directive** that biases variant generation (Structural Guidance, Step 2) and is recorded as **provenance only** in the token sidecar.

### Precedence — Probe #0

When a reference is supplied, it resolves as **Probe #0**, ahead of every project-source probe in "### Probe Order (fixed precedence)" below. Full precedence, highest to lowest:

```
Probe #0 (user reference) → Probes #1..#N (project code) → Tailwind CDN defaults
```

Probe #0 does not necessarily cover every token family — an image reference, for instance, yields color/font/spacing cues but rarely radii or transition timing. Any family the reference does not cover falls through to the existing project-source probes (Probe #1 onward) and, failing those, to Tailwind CDN defaults, exactly as if no reference had been supplied.

### Sanitization and Failure Degradation

The user-supplied path, URL, or free text is sanitized before being stored in working memory or written to the sidecar's `reference.source` field (see "### Token Sidecar JSON" below): apply the base rules in `commands/references/sanitization.md` (strip code fences, HTML/XML tags, instruction-override patterns), plus strip newlines/carriage-returns, remove `$(` sequences and backtick characters, and truncate (path/URL: 500 chars; free text: 280 chars).

Intake failure never aborts the brainstorm — mirroring "### Error Handling" below. On a missing or unreadable local path, a URL that will not open, or any other intake failure, the agent emits **exactly one** warning line, formatted as:

```
⚠ Reference intake: <kind> reference unavailable (<reason>) — using project tokens.
```

and degrades to the plain [Prototype] flow — project-source probes only (Probe #1 onward, then Tailwind CDN defaults) — as if no reference had been supplied.

## Token Extraction

The brainstorm agent attempts to extract design tokens (colors, fonts, radii, spacing, shadows, transitions, screens, dark-mode) from the target project before generating variant HTML. Extraction is **best-effort**: parse errors on any source are silently swallowed and that source is skipped — extraction failures never abort the brainstorm.

### Probe Order (fixed precedence)

For each token family, the agent probes sources in this order and stops at the **first source that yields non-empty tokens** for that family. Different families may resolve from different sources (e.g., colors from `tailwind.config`, fonts from `theme.ts`).

When a user reference was supplied via "## Reference Intake" above, it resolves first as **Probe #0**; the numbered probes below run only for families Probe #0 did not already cover.

1. **`tailwind.config.{js,ts,mjs,cjs}`** — Read the file and extract values under `theme.extend` (preferred) or `theme` keys: `colors`, `fontFamily`, `borderRadius`, `spacing`. Pattern: look for object literals following those key names. If the file imports or requires another module for its config, skip and continue to the next source.

2. **`theme.{ts,js,tsx,jsx}`** — Read the file and look for exported objects or constants named `theme`, `colors`, `typography`, `radii`, `space`, or `spacing`. Extract values from matching keys. Works for hand-rolled design-system theme files.

3. **CSS custom properties in global stylesheets** — Probe these filenames in the project root and `src/` directory (check both): `app.css`, `global.css`, `index.css`, `styles.css`. Scan for lines matching `--[a-z][a-z0-9-]*:\s*[^;]+;`. Classify tokens by name prefix: `--color-*` → colors; `--font-*` → fonts; `--radius-*` → radii; `--spacing-*` or `--space-*` → spacing. Also accept bare `--primary`, `--secondary`, `--background`, `--foreground` as color tokens.

4. **`_variables.scss`** — Probe `src/`, `styles/`, and project root. Extract SCSS variable declarations matching `\$[a-z][a-z0-9-]*:\s*[^;]+;`. Apply the same name-based classification as CSS custom properties (substitute `$color-` for `--color-`, etc.).

5. **MUI `createTheme` calls** — Search for files importing from `@mui/material` or `@mui/system` that call `createTheme(`. Read those files and extract the argument object's `palette` (→ colors), `typography` (→ fonts), `shape.borderRadius` (→ radii), and `spacing` (→ spacing) fields.

6. **Chakra `extendTheme` calls** — Search for files importing `extendTheme` from `@chakra-ui/react` or `@chakra-ui/system`. Read those files and extract `colors`, `fonts`, `radii`, and `space` keys from the argument object.

7. **`<bundle>/project/**/*.css`** *(only when `bundleDetected = true`)* — Glob all CSS files under the Claude Design bundle's `project/` subtree. Scan each file for `:root` blocks and extract custom property declarations matching `--[a-z][a-z0-9-]*:\s*[^;]+;` (same regex as Probe #3). Classify tokens by name prefix: `--color-*` → colors; `--font-*` → fonts; `--radius-*` → radii; `--spacing-*` or `--space-*` → spacing; `--shadow-*` → shadows; `--transition-*`, `--ease-*`, or `--duration-*` → transitions. When multiple CSS files match, later files in glob order win for conflicting property names.

8. **Inline `<style>` blocks in `<bundle>/project/**/*.html`** *(only when `bundleDetected = true`)* — Glob all HTML files under the bundle's `project/` subtree. For each file, extract the text content of every `<style>` tag and scan for `:root` blocks containing custom property declarations matching the same regex (`--[a-z][a-z0-9-]*:\s*[^;]+;`). Apply the same prefix-based classification as Probe #7. Inline styles declared directly on the `:root` element via a `style="..."` attribute are also accepted. When multiple HTML files match, later files in glob order win for conflicting property names.

### Per-Family Resolution

Token families resolve independently:

| Family      | Extracted from keys / patterns                                                       |
|-------------|--------------------------------------------------------------------------------------|
| colors      | `colors`, `palette`, `--color-*`, `$color-*`, `--primary`, `--background`, etc.      |
| fonts       | `fontFamily`, `typography.fontFamily`, `fonts`, `--font-*`                           |
| radii       | `borderRadius`, `shape.borderRadius`, `radii`, `--radius-*`                          |
| spacing     | `spacing`, `space`, `--spacing-*`, `--space-*`                                       |
| shadows     | `boxShadow`, `shadows`, `--shadow-*`, `$shadow-*`                                    |
| transitions | `transitionDuration`, `transitionTimingFunction`, `transitions`, `--transition-*`, `--ease-*`, `--duration-*` |
| screens     | `screens`, `breakpoints`, `--breakpoint-*`, `@media` width declarations              |
| dark-mode   | `darkMode` config flag, `@media (prefers-color-scheme: dark)` blocks, `.dark` class CSS variables (paired with color tokens via `--color-*` under `.dark` selector) |

Once a family is resolved from a source, that source wins for that family. The agent does not merge partial results across sources for the same family.

### Fallback Behavior

If no source yields tokens for a given family after exhausting all probes (six sources when no bundle is present; eight when `bundleDetected = true`), the agent uses **generic Tailwind Play CDN defaults** for that family (the built-in Tailwind color palette, `font-sans`/`font-mono`, standard radius scale, standard spacing scale, standard shadow scale, standard transition durations/easings, standard breakpoints; no dark-mode theming).

When fallback is used, the brainstorm document MUST include a warning line immediately after the variant header, formatted as:

```
⚠ Token extraction: [family] tokens not found — using Tailwind CDN defaults.
```

One warning line per family that fell back.

### Token Sidecar JSON

After extraction, write a machine-readable sidecar alongside the HTML variants file:

```
.aimi/brainstorms/prototypes/<topic-slug>-tokens.json
```

Shape:

```json
{
  "colors": { "primary": "#0066ff", "background": "#fff", "...": "..." },
  "fonts": { "sans": "Inter, system-ui, sans-serif", "mono": "..." },
  "radii": { "sm": "0.25rem", "md": "0.5rem", "...": "..." },
  "spacing": { "1": "0.25rem", "...": "..." },
  "shadows": { "sm": "0 1px 2px rgba(0,0,0,0.05)", "...": "..." },
  "transitions": { "default": "150ms ease-in-out", "...": "..." },
  "screens": { "sm": "640px", "md": "768px", "...": "..." },
  "darkMode": { "strategy": "class|media|none", "colors": { "background": "#0b0b0b", "...": "..." } },
  "sources": { "colors": "tailwind.config.ts", "fonts": "theme.ts", "...": "..." },
  "fallbacks": ["shadows", "transitions"],
  "reference": { "kind": "image|url|text", "source": "<sanitized path, URL, or truncated text>" }
}
```

- Include only families that were actually resolved or fell back; omit a family entirely if it was neither resolved nor required by the variant.
- `sources[family]` names the file that won for that family (relative path from project root). Omit the key for families that fell back.
- `fallbacks[]` lists every family that fell back to Tailwind defaults.
- `reference` is present only when a reference was supplied via "## Reference Intake" above; `kind` is `image`, `url`, or `text`; `source` is the sanitized path, URL, or truncated free text (see "Sanitization and Failure Degradation" in that section). Omit the key entirely when no reference was supplied.
- `/aimi:plan` reads this sidecar to thread token context into implementation stories. `/aimi:review` reads it to verify generated mockups match the target project's tokens. Both can read `reference` to know the visual target had an external reference.

### Error Handling

- Any file read error, syntax ambiguity, or pattern mismatch on a source → skip that source for the affected family, continue to the next source. Do not emit an error or warning for skipped sources — only warn when all sources are exhausted and fallback is used.
- Never abort the brainstorm due to token extraction failure.
- Never attempt to execute or import source files — read them as plain text and apply grep-level pattern matching only.

## Browser Session Lifecycle

Visual questions (Aesthetic Direction, Differentiation) open an `agent-browser` session to render variant HTML in a live browser window. The session is advisory — its absence or failure never blocks the brainstorm.

### Opening (lazy)

The session is opened on the **first** Aesthetic Direction or Differentiation question, not at brainstorm start. Open with:

```bash
agent-browser --headed --session brainstorm-<topic-slug> open file://$(pwd)/.aimi/brainstorms/prototypes/<topic-slug>-variants.html
```

`<topic-slug>` is the sanitized topic slug (same value used for the file path). The `--headed` flag opens a visible browser window so the user can observe variants as they are appended.

### Reusing (subsequent visual questions)

Pass the **same `--session` name** on every subsequent visual question — do not open a new session. After each variant section is appended to the HTML file, reload the page so the new section is visible:

```bash
agent-browser --session brainstorm-<topic-slug> reload
```

The existing Alpine.js switcher state is preserved across reloads; all variant sections remain in the DOM.

### Closing (normal completion)

When the brainstorm completes normally (all questions answered, summary written), close the session:

```bash
agent-browser --session brainstorm-<topic-slug> close
```

Do not close the session mid-brainstorm (e.g., between questions). Only close on completion or confirmed user exit.

### Fallback: `agent-browser` skill unavailable

If `agent-browser` is not installed or the skill is missing (`command -v agent-browser` fails), skip all open/reload/close calls. Still write the HTML file to disk normally. Log exactly one warning line to the brainstorm document:

```
agent-browser unavailable — variants at .aimi/brainstorms/prototypes/<topic-slug>-variants.html
```

Continue the brainstorm in text-only mode — all variant content is still written to the HTML file; the user opens it manually.

### Fallback: mid-session crash (browser dies after successful open)

If the session opened successfully but a later `reload` or other call fails (non-zero exit, connection error):

1. **Retry once** with a fresh session name by appending `-2` suffix:
   ```bash
   agent-browser --headed --session brainstorm-<topic-slug>-2 open file://$(pwd)/.aimi/brainstorms/prototypes/<topic-slug>-variants.html
   ```
2. If the retry also fails, **degrade to text-only** for all remaining visual questions — stop attempting any further `agent-browser` calls for this brainstorm session. Log the file path once at the point of degradation:
   ```
   agent-browser session lost — variants at .aimi/brainstorms/prototypes/<topic-slug>-variants.html
   ```

HTML files are always written to disk regardless of browser session state; degradation affects only the live preview, not the artifact.
