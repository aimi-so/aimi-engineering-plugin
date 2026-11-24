# Brainstorm: Step 0.7 Post-Processing: Bundle Prototype Generation Gate

> Loaded by `commands/brainstorm.md` when its `Applies when:` condition holds.
>
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

### Step 0.7 Post-Processing: Bundle Prototype Generation Gate

**Check render bundle flag (at bundle-detection gate):** Immediately after deriving `bundleDetected`, check whether the topic text or any user reply so far contains `render bundle` (case-insensitive substring). If matched and not already emitted this session, set `renderBundlePending = true` and emit `render-bundle override active — regenerating prototype from specs` once to chat.

**Generation condition:** When `bundleDetected=true` AND (the `prototypes[]` array in `bundlePayload` is empty OR `renderBundlePending = true`), run bundle prototype generation:

1. **Check status:**
   ```bash
   AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
   : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
   STATUS_JSON=$($AIMI_CLI bundle-prototype-status \
     --bundle "<bundlePath>" \
     --topic "<topic-slug>" \
     $([ "$renderBundlePending" = "true" ] && echo "--force"))
   ```
   Parse `STATUS_JSON` for:
   - `needs_generation` (bool)
   - `view_list` (array of `{name, source_section}`)
   - `view_source` (`"designSpec"` | `"businessSpec"` | `"none"`)
   - `output_path` (string)

2. **When `view_source` is `"none"`:** Emit exactly:
   `bundle prototype generation skipped — no view list in DesignSpec § 4 or BusinessSpec § 5/§ 6`
   This is `cmd_bundle_prototype_status`'s own hardcoded fallback probe order (DesignSpec § 4, then BusinessSpec § 5, then § 6) for placeholder-prototype generation — distinct from `BusinessSpec § 2` (Screens), the canonical screen-list section `commands/references/spec-section-contract.md` documents for story decomposition.
   Then proceed without generation. Do not set `bundleGeneratedPrototypePath`. Skip the remaining sub-steps.

3. **When `needs_generation` is `true`:** Create the output directory and spawn the author agent:
   ```bash
   mkdir -p .aimi/brainstorms/prototypes
   ```
   Parse additional fields from `STATUS_JSON`:
   - `sidecar_path` — the sidecar JSON path returned by `bundle-prototype-status`
   Extract from `bundlePayload`:
   - `designSpec` → `designSpecPath` (may be null)
   - `businessSpec` → `businessSpecPath` (may be null)
   - `chats[]` → `chatPaths` (may be empty)

   **Path guard:** Resolve `output_path` to an absolute path and verify it starts with `AIMI_ROOT`. If it does not, log one warning line (`bundle prototype generation skipped — output path outside project root: <output_path>`) and abort generation for this session without clearing `renderBundlePending`.

   Spawn the bundle prototype author agent:
   ```
   Task subagent_type="aimi-engineering:research:aimi-bundle-prototype-author"
     [model: <AGENT_MODELS.research when not "inherit">]
     [effort: <AGENT_EFFORTS.research when not "inherit">]
     prompt: "Generate a prototype HTML for the design bundle.
              bundlePath=<bundlePath>
              viewList=<view_list as JSON array of name strings>
              viewSource=<view_source>
              designSpecPath=<designSpecPath or empty>
              businessSpecPath=<businessSpecPath or empty>
              chatPaths[]=<chatPaths as JSON array>
              outputPath=<output_path>"
   ```

   After the agent completes, verify the file was written:
   ```bash
   ls "<output_path>" 2>/dev/null
   ```
   If the file is missing, log one warning line (`bundle prototype generation failed — agent did not write output: <output_path>`) and proceed without a generated prototype.

4. **When generation succeeds** (file confirmed on disk):

   a. **Finalize the sidecar:** Compute hashes and call:
      ```bash
      AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
      : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
      BUNDLE_HASH=$(sha256sum "<bundlePath>/README.md" 2>/dev/null | awk '{print $1}' || echo "")
      DESIGN_HASH=$([ -n "<designSpecPath>" ] && sha256sum "<designSpecPath>" 2>/dev/null | awk '{print $1}' || echo "")
      BUSINESS_HASH=$([ -n "<businessSpecPath>" ] && sha256sum "<businessSpecPath>" 2>/dev/null | awk '{print $1}' || echo "")
      $AIMI_CLI bundle-prototype-finalize \
        --topic "<topic-slug>" \
        --bundle-hash "$BUNDLE_HASH" \
        --design-spec-hash "$DESIGN_HASH" \
        --business-spec-hash "$BUSINESS_HASH" \
        --view-list '<view_list as JSON array>' \
        --source-command brainstorm
      ```

   b. **Register the generated prototype:** Store `output_path` as `bundleGeneratedPrototypePath` in working memory. Append one entry to `prototype_entries`:
      ```
      { path: "<output_path>", question_category: "Bundle", branch: "bundle-generated" }
      ```
      This entry uses the same YAML key ordering as variant-derived entries (path, question_category, branch) so that plan.md Phase 0 can parse it uniformly.

   c. **Clear the flag:** Set `renderBundlePending = false`.

5. **When `needs_generation` is `false`** (and `renderBundlePending` was not `true`): Generation is not needed — the sidecar already records an up-to-date prototype. Use the `output_path` from `STATUS_JSON` as a reference for downstream phases if the file exists on disk. Do not append to `prototype_entries` here — the path will be picked up through `bundlePayload.prototypes[]` in Phase 4 as a normal bundle-derived entry.

**Tag-breakout sanitization:** Before writing `bundleGeneratedPrototypePath` into any YAML frontmatter key (see Phase 4 `prototype:` frontmatter rules), replace `</prototype_html` with `&lt;/prototype_html` and `<prototype_html` with `&lt;prototype_html` in the path string. (In practice a file path will never contain these sequences, but the guard must be on the rail per security policy.)
