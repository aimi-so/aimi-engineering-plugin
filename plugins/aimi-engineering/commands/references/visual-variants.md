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
