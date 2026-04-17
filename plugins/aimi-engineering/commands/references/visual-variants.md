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

## Token Extraction

The brainstorm agent attempts to extract design tokens (colors, fonts, radii, spacing) from the target project before generating variant HTML. Extraction is **best-effort**: parse errors on any source are silently swallowed and that source is skipped — extraction failures never abort the brainstorm.

### Probe Order (fixed precedence)

For each token family, the agent probes sources in this order and stops at the **first source that yields non-empty tokens** for that family. Different families may resolve from different sources (e.g., colors from `tailwind.config`, fonts from `theme.ts`).

1. **`tailwind.config.{js,ts,mjs,cjs}`** — Read the file and extract values under `theme.extend` (preferred) or `theme` keys: `colors`, `fontFamily`, `borderRadius`, `spacing`. Pattern: look for object literals following those key names. If the file imports or requires another module for its config, skip and continue to the next source.

2. **`theme.{ts,js,tsx,jsx}`** — Read the file and look for exported objects or constants named `theme`, `colors`, `typography`, `radii`, `space`, or `spacing`. Extract values from matching keys. Works for hand-rolled design-system theme files.

3. **CSS custom properties in global stylesheets** — Probe these filenames in the project root and `src/` directory (check both): `app.css`, `global.css`, `index.css`, `styles.css`. Scan for lines matching `--[a-z][a-z0-9-]*:\s*[^;]+;`. Classify tokens by name prefix: `--color-*` → colors; `--font-*` → fonts; `--radius-*` → radii; `--spacing-*` or `--space-*` → spacing. Also accept bare `--primary`, `--secondary`, `--background`, `--foreground` as color tokens.

4. **`_variables.scss`** — Probe `src/`, `styles/`, and project root. Extract SCSS variable declarations matching `\$[a-z][a-z0-9-]*:\s*[^;]+;`. Apply the same name-based classification as CSS custom properties (substitute `$color-` for `--color-`, etc.).

5. **MUI `createTheme` calls** — Search for files importing from `@mui/material` or `@mui/system` that call `createTheme(`. Read those files and extract the argument object's `palette` (→ colors), `typography` (→ fonts), `shape.borderRadius` (→ radii), and `spacing` (→ spacing) fields.

6. **Chakra `extendTheme` calls** — Search for files importing `extendTheme` from `@chakra-ui/react` or `@chakra-ui/system`. Read those files and extract `colors`, `fonts`, `radii`, and `space` keys from the argument object.

### Per-Family Resolution

Token families resolve independently:

| Family   | Extracted from keys / patterns                                      |
|----------|---------------------------------------------------------------------|
| colors   | `colors`, `palette`, `--color-*`, `$color-*`, `--primary`, etc.    |
| fonts    | `fontFamily`, `typography.fontFamily`, `fonts`, `--font-*`          |
| radii    | `borderRadius`, `shape.borderRadius`, `radii`, `--radius-*`         |
| spacing  | `spacing`, `space`, `--spacing-*`, `--space-*`                      |

Once a family is resolved from a source, that source wins for that family. The agent does not merge partial results across sources for the same family.

### Fallback Behavior

If no source yields tokens for a given family after exhausting all six sources, the agent uses **generic Tailwind Play CDN defaults** for that family (the built-in Tailwind color palette, `font-sans`/`font-mono`, standard radius scale, standard spacing scale).

When fallback is used, the brainstorm document MUST include a warning line immediately after the variant header, formatted as:

```
⚠ Token extraction: [family] tokens not found — using Tailwind CDN defaults.
```

One warning line per family that fell back. If all four families fall back, emit four warning lines.

### Error Handling

- Any file read error, syntax ambiguity, or pattern mismatch on a source → skip that source for the affected family, continue to the next source. Do not emit an error or warning for skipped sources — only warn when all sources are exhausted and fallback is used.
- Never abort the brainstorm due to token extraction failure.
- Never attempt to execute or import source files — read them as plain text and apply grep-level pattern matching only.
