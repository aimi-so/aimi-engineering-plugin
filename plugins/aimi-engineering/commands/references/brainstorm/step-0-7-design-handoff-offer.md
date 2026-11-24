# Brainstorm: Step 0.7 Design Handoff Offer

> Loaded by `commands/brainstorm.md` when its `Applies when:` condition holds.
>
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

### Step 0.7 Design Handoff Offer

Offers to generate a BusinessSpec/DesignSpec bundle now, for a UI-bearing
feature with no bundle on hand, and re-enters bundle detection on
acceptance — so the bundle-aware branches below (the Post-Processing
prototype-generation gate immediately following, and every other
`bundleDetected`-gated branch downstream) run against the bundle just
written, in this same brainstorm invocation, instead of the session ending
with `bundleDetected` permanently `false`.

#### Step 1: Fire-Condition Check

The gate fires only when **both** of the following hold:

1. **`bundleDetected` is `false`** — the result derived above.
2. **The feature description matches a UI signal.** Scan `$FEATURE_DESCRIPTION` against the "Keyword Signals" section of `${CLAUDE_PLUGIN_ROOT}/commands/references/ui-signals.md` — read that file and apply its keyword list, its case-insensitive whole-word matching rule (regex word boundaries `\b`), and its "design" co-occurrence rule, as written; do not restate them here. **Structural Signals do not apply here** — no `creates`/`areas`/`phases[]` array exists yet at this point in the flow, since Phase 3.5 has not run. This matches ui-signals.md's own "How to Combine" section, which names exactly this case as valid: the keyword signal "can flag a plain-text feature description ... as UI-relevant before a structural artifact list exists."

Phase 1.7 (UI Feature Detection) applies the identical keyword scan to the identical `$FEATURE_DESCRIPTION` text later in this same session. The two calls necessarily agree — this is expected redundancy, not a second, diverging detector; this gate reads and writes no Phase-1.7-owned variable.

If either condition is false, skip this entire gate silently: no log line, no offer, proceed straight to Step 0.7 Post-Processing below exactly as if this gate did not exist.

#### Step 2: Non-Interactive Fast Path (Agent Mode)

When `INTERACTIVE_MODE=agent`, skip AskUserQuestion entirely — there is no user to generate a bundle with. Log exactly one line to the brainstorm document's working memory:

```
agent-mode: design-handoff-offer skipped (no bundle to generate without a user)
```

Proceed to Step 0.7 Post-Processing with `bundleDetected` unchanged (still `false`).

#### Step 3: Interactive Offer

When `INTERACTIVE_MODE=picker`, present via **AskUserQuestion** (picker mode) with exactly two options, the escape hatch (`Skip`) last, per `commands/references/interactivity.md`'s Option Format. Compose the question and option text in the same language `$FEATURE_DESCRIPTION` is written in, per the Adaptive Language Rule (`commands/references/user-communication.md` § Adaptive Language Rule) — the English wording below is an illustration for a reader of this file, not a fixed string to emit verbatim:

```
No design bundle was found for this UI-bearing feature — want to generate a BusinessSpec/DesignSpec now?

Generate now — run the design handoff interview and write a bundle
Skip — proceed without a bundle
```

- **[Skip]:** Proceed to Step 0.7 Post-Processing with `bundleDetected` unchanged (still `false`). No artifact is produced.
- **[Generate now]:** Follow Step 4 below.

#### Step 4: Accept — Run Design Handoff and Re-Detect

1. **Derive the topic slug.** From `$FEATURE_DESCRIPTION`, derive a topic slug using the five-step algorithm in `${CLAUDE_PLUGIN_ROOT}/commands/references/topic-slug.md`. Phase 1's own topic-slug derivation (Step 1b below) has not run yet at this point in the flow, so this gate derives it here; the same deterministic algorithm applied to the same `$FEATURE_DESCRIPTION` necessarily produces the same slug, so Step 1b's later derivation is expected redundancy, not a conflict.

2. **Run the skill.** Read `${CLAUDE_PLUGIN_ROOT}/skills/aimi-design-handoff/SKILL.md` and follow its instructions exactly — inline read-and-follow, never a Task-spawned sub-agent. Pass the feature description (`$FEATURE_DESCRIPTION`), the topic slug just derived, and an explicit `outputRoot: .aimi/design-bundles/<topic-slug>` so the bundle it writes lands exactly where this gate re-detects it in the next step. This story does not re-derive the skill's own `README.md`/`BusinessSpec.md`/`DesignSpec.md` authoring or the spec-section contract's numbering — that is the skill's own job.

3. **Re-detect.** After the skill returns, re-resolve `$AIMI_CLI` with the same per-call cache-read boilerplate already used three times in Step 0.7 above, then run:

   ```bash
   AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
   : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
   BUNDLE_ERR_FILE=$(mktemp)
   BUNDLE_RESULT=$($AIMI_CLI detect-design-bundle --bundle ".aimi/design-bundles/<topic-slug>" 2>"$BUNDLE_ERR_FILE")
   BUNDLE_STATUS=$?
   BUNDLE_STDERR=$(cat "$BUNDLE_ERR_FILE" 2>/dev/null)
   rm -f "$BUNDLE_ERR_FILE"
   ```

   `--bundle` is mandatory here — never a bare `detect-design-bundle` call,
   and never `--root`: `--bundle` reads the named path directly as the bundle
   itself (per `outline:01`/D4's "fails loudly if it is not a bundle"), which
   is simpler than `--root`'s former child-scan workaround (that scan used to
   skip any directory literally named `.aimi`, so pointing `--root` at the
   parent directory was needed to reach a pre-check that treated the
   generated directory itself as a candidate before any child-scan ran) and
   needs no explanation tied to that `.aimi`-skip case at all.

4. **Re-derive.** Re-derive `bundleDetected`, `bundlePayload`, and `bundlePath` from this fresh result using the exact same rule stated in the bullet list above (`BUNDLE_STATUS` must be `0` and `BUNDLE_RESULT` non-null for `bundleDetected=true`) — no second test is written here, and no branch reads the generated `BusinessSpec.md`/`DesignSpec.md` directly outside this re-detection path. `--bundle` never produces its own ambiguity (it names exactly one directory), so any non-zero `BUNDLE_STATUS` here is simply "no detectable bundle", the same as step 5 below.

5. **When `bundleDetected` is still `false`** after re-detection (the skill did not produce a detectable bundle), log exactly one warning line to the brainstorm document's working memory:

   ```
   design-handoff skill did not produce a detectable bundle — proceeding without one
   ```

   and continue exactly as if the offer had been declined — never abort the brainstorm session.

Whether accepted or skipped, this gate runs to completion before Step 0.7 Post-Processing below, so a bundle generated here is seen by the Post-Processing prototype-generation gate and by every other `bundleDetected`-gated branch downstream, in the same brainstorm invocation.
