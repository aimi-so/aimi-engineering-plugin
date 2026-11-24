# Brainstorm: Phase 2: Visual Variant Rendering

> Loaded by `commands/brainstorm.md` when its `Applies when:` condition holds.
>
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

#### Visual Variant Rendering (Aesthetic Direction and Differentiation only)

> Full authoring contract — HTML skeleton, slug sanitization, HTML-escaping rules, token extraction, switcher wiring, and browser session lifecycle — lives in `commands/references/visual-variants.md`. This sub-step is the integration point; do not re-implement any detail here.

**`show variants` override check (runs before category classification):** Before evaluating whether a question is Aesthetic Direction or Differentiation, check whether `visualOverridePending = true` (set when the user's topic or latest reply contained `show variants` — see "Override Keywords" section above). If the flag is set, treat this question as **Aesthetic Direction** for the purpose of visual rendering, then clear the flag (`visualOverridePending = false`). This bypass applies only to the single next question; all subsequent questions revert to normal category classification.

When the agent reaches an **Aesthetic Direction** or **Differentiation** question (and only those two categories, or when the `show variants` override is active), execute the following steps **before** presenting the question to the user. If `AIMI_BRAINSTORM_DEBUG=1`: emit `[brainstorm-debug] category: <category-name> — visual rendering path triggered` to chat (or `[brainstorm-debug] category: <category-name> — visual rendering skipped` when the question does not fall into either category). All slug sanitization, HTML-escaping, and token extraction rules are defined in `references/visual-variants.md`; this sub-step is the call sequence only.

**Step 0a — Bundle early-exit check**

Before any other step in Visual Variant Rendering, check override flags and bundle state:

1. **Override check (takes precedence):** If `visualOverridePending = true` OR `varyUIPending = true`, skip this entire Step 0a and proceed to Step 0b — the normal Steps 0–7 flow runs regardless of bundle state (see Override Keywords section for the precedence rule).

2. **Bundle early-exit:** If `bundleDetected=true` (and neither override flag is set):

   a. **Select the bundle HTML:** Check whether `bundleGeneratedPrototypePath` is set in working memory (populated by Step 0.6 Post-Processing when `prototypes[]` was empty at detection time and generation succeeded). If set, use `bundleGeneratedPrototypePath` as the selected HTML path and use `question_category: "Bundle"` with `branch: "bundle-generated"`. Otherwise, among `.html` files in the bundle's `project/` directory (within `bundlePath`), prefer files whose basename contains `standalone` (case-insensitive); if none match, use the first non-standalone `.html` file alphabetically (and use `question_category: "Aesthetic Direction"` with `branch: "bundle"`).

   b. **Wrap as prototype entry:** Store one entry in `prototype_entries` working memory using the path and metadata resolved in sub-step (a):
      - When sourced from `bundleGeneratedPrototypePath`:
        ```
        { path: "<bundleGeneratedPrototypePath>", question_category: "Bundle", branch: "bundle-generated" }
        ```
      - When sourced from the bundle's `project/` directory:
        ```
        { path: "<selected html path>", question_category: "Aesthetic Direction", branch: "bundle" }
        ```

   c. **Agent-mode log (emitted at most once per session):** Log one line to the brainstorm document's working memory: `agent-mode: bundle-detected — skipped variant authoring, using bundle HTML <path>`. Then invoke the once-per-session echo helper with flag `echoedBundleEarlyExit` and message `agent-mode: bundle-detected — skipped variant authoring, using bundle HTML <path>`. Initialize `echoedBundleEarlyExit = false` when Step 0b initializes working memory.

   d. **Return from Visual Variant Rendering:** Skip Steps 0b through 7 entirely for this question. Proceed directly to presenting the (text-only) question.

3. **When `bundleDetected=false`:** Step 0a is a no-op — proceed to Step 0b as normal.

**Step 0b — Pre-flight browser availability (run once per brainstorm session)**

Before processing the very first Aesthetic Direction or Differentiation question, run this check **exactly once**. On all subsequent visual questions, skip directly to Step 0 — the cached result is already in working memory.

1. **Predict visual questions.** Based on the brainstorm topic and the question-category plan assembled in Phase 2, determine whether any Aesthetic Direction or Differentiation questions are expected. If none are predicted, skip this entire step — emit nothing to chat, set `browserAvailable = false`, `browserSkipReason = "no visual questions"`, and proceed. This prevents false alarms on non-visual brainstorms.

2. **If visual questions are expected, run the availability check:**

   ```bash
   command -v agent-browser
   ```

   Apply the same heuristic used in Step 4:
   - `agent-browser` not found → reason: `agent-browser not installed`
   - `DISPLAY` unset **and** not running under a known GUI host (macOS / Windows) → reason: `DISPLAY unset`
   - `CI=true` is set → reason: `CI mode`

3. **Emit exactly one line to chat** (not to the brainstorm document):
   - On success: `Visual preview: ready`
   - On failure: `Visual preview: disabled (<reason>)` where `<reason>` is the short cause from step 2 (e.g., `Visual preview: disabled (agent-browser not installed)`)

4. **Cache the outcome in working memory:**
   - `browserAvailable` (bool): `true` if the check passed, `false` otherwise.
   - `browserSkipReason` (string): empty string on success; the short cause string on failure.
   - `echoedBrowserUnavailable` (bool): `false` — guards the once-per-session chat echo for the "agent-browser unavailable" event.
   - `echoedSessionLost` (bool): `false` — guards the once-per-session chat echo for the "agent-browser session lost" event.
   - `echoedPickerUnavailable` (bool): `false` — guards the once-per-session chat echo for the "picker unavailable — auto-selected variant A" event.

   Step 4 and all subsequent visual-question handling must read `browserAvailable` from working memory — do **not** re-run `command -v agent-browser` or re-evaluate the DISPLAY / CI heuristic on later questions.

**Once-per-session echo helper:** Given a flag name `F` and a message `M`: if `F` is `false`, emit `M` to chat and set `F = true`. Subsequent invocations with the same `F` in the same session are silent. This helper is used at all four `echoed*` call sites below — only the chat-echo+flag-set pattern is consolidated; the separate lines that write to the brainstorm document's working memory are not affected.

**Step 0 — Component-shell scan (best-effort)**

Sample 2–3 representative component files from the target project to extract the structural idioms variants should mimic. Scan is optional; skip silently on any failure.

**DesignSpec § 1 preference:** When `bundleDetected=true` and the design-bundle researcher returned a non-null `designSpec` path, read the component-shell structural idioms from `DesignSpec § 1` first (design-token and component-skeleton section). Use those definitions as `component_shell_notes` directly — do not scan project component files for this step. Fall back to the file-scan below only if `DesignSpec § 1` is absent or unreadable.

1. Look under `src/components/`, `app/components/`, `components/`, or `src/app/` (first directory that exists) for `.tsx`, `.jsx`, `.vue`, or `.svelte` files.
2. Select up to 3 files: prefer one matching a form-like name (`Form.*`, `Input.*`, `Login.*`), one matching a layout-like name (`Layout.*`, `Sidebar.*`, `Page.*`), and one matching a card-like name (`Card.*`, `Item.*`, `List.*`). Fall back to any 1–3 components if the name hints fail.
3. Read each file as plain text (do not execute or import). Extract:
   - The outermost wrapper element (tag + top-level classes/structure idioms).
   - Class recipes that recur across components (e.g., `rounded-xl shadow-sm border` combinations, spacing scales like `p-6 gap-4`).
   - Primary-action class recipes (styles applied to `<button type="submit">` or elements named like `PrimaryButton`).
4. Store findings as `component_shell_notes` in working memory. These are passed as structural constraints into Step 3 below (see `references/visual-variants.md` → Structural Guidance → Step 4).

Any read error, missing directory, or inability to parse cleanly → skip silently; no warning. Component-shell guidance is additive, never a precondition.

**Step 1 — Validate topic slug**

Use the slug derived in Phase 1 Step 1b and apply the Topic-Slug Sanitization algorithm from `references/visual-variants.md`. **Order matters:** run the sanitization algorithm first (lowercase → replace whitespace → strip non-alphanumeric → collapse dashes → trim), then validate the result against `^[a-z0-9][a-z0-9-]*$` and the traversal checks (`..`, leading `/`, any `/`).

If the slug fails validation: log a warning ("Visual path skipped — invalid topic slug: `<raw>`"), skip Steps 2–5 for this question, and fall back to text-only (present the question normally without any HTML output).

**Step 2 — Token extraction (best-effort)**

**DesignSpec § 1 preference:** When `bundleDetected=true` and the design-bundle researcher returned a non-null `designSpec` path, extract colors, fonts, radii, spacing, shadows, transitions, screens, and dark-mode tokens exclusively from `DesignSpec § 1` (design tokens section). Write the token sidecar JSON with `"fallbacks": []` — tokens sourced from DesignSpec are explicitly authoritative; no family falls back to Tailwind CDN defaults. Skip the project-source probe order below for this case.

When `designSpec` is null or unavailable, probe project sources in the fixed precedence order defined in `references/visual-variants.md` (Token Extraction section). Extract colors, fonts, radii, spacing, shadows, transitions, screens, and dark-mode tokens. Any probe failure is silently skipped. Use Tailwind CDN defaults for any family that yields no tokens, and emit the required warning line per family that fell back.

Write the token sidecar JSON to `.aimi/brainstorms/prototypes/<topic-slug>-tokens.json` (shape and rules in `references/visual-variants.md` → Token Sidecar JSON).

**Step 2.5 — Variant branch decision**

Immediately after the token sidecar JSON is written (read-after-write is synchronous), read `.aimi/brainstorms/prototypes/<topic-slug>-tokens.json` from disk and compute the branch.

1. **Compute `tokensFallbackAll`:** Inspect the `fallbacks` array in the sidecar JSON. Set `tokensFallbackAll = true` if and only if all three of `"colors"`, `"fonts"`, and `"radii"` appear in that array; otherwise `tokensFallbackAll = false`.

2. **Assign `variantBranch` and record reason:**
   - If `varyUIPending` is `true` (flag was set by a prior interaction): set `variantBranch = "ui-variation"`, record `variantBranchReason = "vary-ui-override"`, then **clear `varyUIPending` (set it to `false`)** — this is a one-shot consumption; the flag must not trigger again for subsequent questions in the same session.
   - Else if `tokensFallbackAll` is `true`: set `variantBranch = "ui-variation"`, record `variantBranchReason = "auto-fallback"`.
   - Otherwise: set `variantBranch = "ux-only"`, record `variantBranchReason = "default"`.

3. **Store in working memory:** `variantBranch` and `variantBranchReason` are retained for use in Step 3 and Step 6 below.

4. **Debug emission:** If `AIMI_BRAINSTORM_DEBUG=1`, emit the following line to chat (not to the brainstorm document):
   ```
   [brainstorm-debug] variant-branch: <ux-only|ui-variation> (reason: <auto-fallback|vary-ui-override|default>)
   ```
   Replace the angle-bracket placeholders with the actual values of `variantBranch` and `variantBranchReason`.

**Step 3 — Author variant HTML**

Create the prototype directory:

```bash
mkdir -p .aimi/brainstorms/prototypes
```

For the **first** visual question, write the full file using the Switcher Skeleton from `references/visual-variants.md`, emitting resolved tokens as CSS custom properties on `:root` per the Structural Guidance section. For **subsequent** visual questions, **append** a new `<section data-question="...">` block to the existing file — do not truncate.

Follow the Structural Guidance section of `references/visual-variants.md`: infer the dominant UI pattern, pick a canonical shape (form/card/nav/hero/modal/table/layout-with-sidebar), and author every variant in that shape. Apply `component_shell_notes` from Step 0 as additional structural constraints.

**Apply the design axes determined by `variantBranch` (set in Step 2.5):**
- **`variantBranch == "ux-only"`:** Apply the UX-branch axes from Step 2 of `references/visual-variants.md` — vary layout, information hierarchy, interaction flow, and content structure. Do not change brand color, typography family, or border-radius between variants; those tokens remain constant across all variants in this question.
- **`variantBranch == "ui-variation"`:** Apply the UI-branch axes from Step 2 of `references/visual-variants.md` — vary color palette, typography pairing, border-radius, surface treatment, and visual weight in addition to layout. Resolved token CSS custom properties may differ across variants in this question.

Author **2–4 variants** per question based on the design axes available (default 2 for binary contrast; add 3–4 only when additional directions genuinely add value).

HTML-escape every user-supplied string before interpolation per `references/visual-variants.md` (HTML-Escaping section). Do not duplicate the escaping table here.

Output path: `.aimi/brainstorms/prototypes/<topic-slug>-variants.html`

**Step 4 — Open or reload browser session**

Consult the `browserAvailable` flag set by Step 0b (pre-flight check). Do **not** re-run `command -v agent-browser` or re-evaluate the DISPLAY / CI heuristic here — that check ran once at session start.

- **`browserAvailable` is `false`** (any reason captured in `browserSkipReason`): Skip all browser calls. Log exactly one warning line to the brainstorm document: `agent-browser unavailable — variants at .aimi/brainstorms/prototypes/<topic-slug>-variants.html`. Then invoke the once-per-session echo helper with flag `echoedBrowserUnavailable` and message `agent-browser unavailable — variants at .aimi/brainstorms/prototypes/<topic-slug>-variants.html`. Continue text-only for all visual questions.
- **First visual question (session open, idempotent):** If a session named `brainstorm-<topic-slug>` already exists, reload it; otherwise open a new headed session:
  ```bash
  agent-browser --headed --session brainstorm-<topic-slug> open file://$(pwd)/.aimi/brainstorms/prototypes/<topic-slug>-variants.html
  ```
  Re-runs of the brainstorm for the same topic reuse the existing session instead of erroring on a duplicate session name.
- **Subsequent visual questions:** Reuse the same session name and reload:
  ```bash
  agent-browser --session brainstorm-<topic-slug> reload
  ```
- **Session call fails (reload returns non-zero):** Retry once with a fresh session name by appending `-2` suffix:
  ```bash
  agent-browser --headed --session brainstorm-<topic-slug>-2 open file://$(pwd)/.aimi/brainstorms/prototypes/<topic-slug>-variants.html
  ```
  If the retry also fails, degrade to text-only for all remaining visual questions — stop attempting any further `agent-browser` calls for this brainstorm session. Log the file path once at the point of degradation: `agent-browser session lost — variants at .aimi/brainstorms/prototypes/<topic-slug>-variants.html`. Then invoke the once-per-session echo helper with flag `echoedSessionLost` and message `agent-browser session lost — variants at .aimi/brainstorms/prototypes/<topic-slug>-variants.html`. (See `references/visual-variants.md` "Fallback: mid-session crash" section for the canonical description of this two-step flow.)

If `AIMI_BRAINSTORM_DEBUG=1`: emit `[brainstorm-debug] browser-attempt: <outcome>` to chat, where `<outcome>` is one of `skipped (browserAvailable=false, reason: <browserSkipReason>)`, `opened new session brainstorm-<topic-slug>`, `reloaded session brainstorm-<topic-slug>`, `retried with session brainstorm-<topic-slug>-2`, or `degraded to text-only after retry failure`.

**Step 5 — Present the question**

Present the Aesthetic Direction or Differentiation question to the user as normal (numbered item with lettered options, "Other" escape hatch). The rendered HTML gives the user a live visual preview alongside the text question.

**Step 6 — Variant Selection**

After the browser session is open and variants are visible, ask the user which variant best fits their vision. Use **AskUserQuestion** with one option per authored variant, labeled in the format `A — <short name>`, `B — <short name>`, etc. (one letter per variant), plus a final option `None — show again / revise`. The question text is: `Which variant best fits your vision?`

For 3 authored variants named "Brutally minimal", "Retro-futuristic", "Luxury/refined", the offered options are: `A — Brutally minimal`, `B — Retro-futuristic`, `C — Luxury/refined`, `None — show again / revise`.

**Agent-mode fallback (non-interactive):**

If the picker tool is unavailable (running under a host that does not support it) or the session is explicitly non-interactive (`AIMI_AGENT_MODE=true` or equivalent), auto-select Variant A deterministically. Log one line to the brainstorm document: `agent-mode: picker unavailable — auto-selected variant A`. Then invoke the once-per-session echo helper with flag `echoedPickerUnavailable` and message `agent-mode: picker unavailable — auto-selected variant A`. Skip the `None — show again / revise` branch entirely in this mode.

If `AIMI_BRAINSTORM_DEBUG=1`: emit `[brainstorm-debug] variant-choice: <chosen-option>` to chat immediately after AskUserQuestion returns (or after the agent-mode auto-pick), where `<chosen-option>` is the full option string the user selected (e.g., `A — Brutally minimal`) or `agent-mode: auto-selected variant A`.

**Handling the `None — show again / revise` branch:**

If the user selects `None — show again / revise`:
1. Use **AskUserQuestion** a second time to ask the user to describe what they want changed or refined. Question text: `What would you like changed or refined about the variants?`
2. Author a replacement variant set and append it as a new `<section data-question="...">` block in the existing HTML file — do **not** discard or truncate prior sections. Use the `variantBranch` value recorded in working memory at Step 2.5 to govern the design axes for the replacement set (UX-branch or UI-branch per the Step 3 rules above). Do **not** re-evaluate `varyUIPending` here — that flag was already consumed (one-shot) at Step 2.5 and must not be re-applied.
3. Reload the browser session (Step 4 reload path).
4. Re-offer the lettered variant options for the new variant set via **AskUserQuestion**.

**Handling a free-form (non-option) reply:**

If the user's response does not match any offered option (i.e., it is a free-form reply), treat it as additional context about their preferences and re-offer the same lettered options via **AskUserQuestion**. Never silently pick a variant based on a free-form reply.

**Storing the chosen variant label:**

Once the user selects a lettered option (or the agent-mode fallback picks Variant A), normalize the chosen label to a slug for persistence and for the Phase 5 Cleanup guard.

1. Extract the letter prefix and short name (e.g., `A — Brutally minimal`).
2. Apply the same sanitization algorithm used for topic slugs in `references/visual-variants.md` (Topic-Slug Sanitization): lowercase → replace whitespace with `-` → strip non-`[a-z0-9-]` → collapse consecutive `-` → trim.
3. Prepend the letter prefix, e.g., `a-brutally-minimal`.
4. Validate the result matches `^[a-z0-9][a-z0-9-]*$`. If it does not, fall back to the bare letter (e.g., `a`).

Store the normalized slug in the agent's working memory as `chosen_variant_slug`. Phase 5 Cleanup's scratch-file removal uses the **topic-slug** (not the variant slug) when composing the `rm -f` path — the scratch filename is `<topic-slug>-variants.html` and was validated at Step 1.

**Step 7 — Variant Persistence**

After storing `chosen_variant_slug`, persist the chosen variant as a standalone HTML artifact. Execute for each visual question after the user selects a variant.

**7a — Sanitize and validate the variant label:**

Use the `chosen_variant_slug` stored in working memory. Validate it matches `^[a-z0-9][a-z0-9-]*$`.

- If the label **fails validation**: log a warning to the brainstorm document (`Variant persistence skipped — invalid label: <raw>`), skip Steps 7b–7d for this question, and leave the scratch file (`.aimi/brainstorms/prototypes/<topic-slug>-variants.html`) as the canonical artifact.
- If the label **passes**: continue to Step 7b.

**7b — Resolve a unique output path:**

Construct the candidate path:
```
.aimi/brainstorms/prototypes/<topic-slug>-<chosen_variant_slug>.html
```

Check whether the file exists:
```bash
ls .aimi/brainstorms/prototypes/<topic-slug>-<chosen_variant_slug>.html 2>/dev/null
```

If it exists (re-run of same topic + same label), append a numeric suffix and retry: `-2`, `-3`, … until a path that does not exist is found.

**7c — Extract and write the standalone file:**

From the existing scratch file (`.aimi/brainstorms/prototypes/<topic-slug>-variants.html`), extract the HTML `<section data-variant="...">` block that corresponds to the chosen variant. Wrap it in a self-contained HTML page with Tailwind CDN inline (no switcher UI, no other variants):

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title><topic-slug> — <chosen_variant_slug></title>
  <script src="https://cdn.tailwindcss.com"></script>
</head>
<body>
  <!-- chosen variant section content only -->
</body>
</html>
```

Write this file to the resolved unique path from Step 7b.

**7d — Record in working memory:**

Append an entry to a `prototype_entries` list in working memory:
```
{ path: "<resolved path>", question_category: "<Aesthetic Direction | Differentiation>", branch: "<ux-only | ui-variation>" }
```

The `branch` value is taken directly from the `variantBranch` recorded at Step 2.5 (`"ux-only"` or `"ui-variation"`). This list is consumed when writing the brainstorm document in Phase 4.

**Non-visual categories** (Purpose, Users, Constraints, Success, Edge Cases, Existing Patterns, Approach) remain text-only — Steps 1–4 above do NOT execute for them.

When the brainstorm completes normally, the browser session is closed and the variant scratch file is pruned in Phase 5 Cleanup (see below).
