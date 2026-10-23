# Plan: Phase 0: Bundle Prototype Auto-Generation, Phase-Tier Spec Detail and Spec Ingestion

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.
>
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

### Bundle Prototype Auto-Generation

**Render-bundle override detection:** Scan `$ARGUMENTS` for the case-insensitive substring `render bundle`. If matched:
- Set `renderBundlePending = true`.
- Emit exactly one chat line: `render-bundle override active — regenerating prototype from specs`

When `designBundleMeta` is non-null AND (`designBundleMeta.prototypes` is empty OR `renderBundlePending = true`):

1. **Check generation status:**

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
STATUS_JSON=$($AIMI_CLI bundle-prototype-status \
  --bundle "<bundlePath>" \
  --topic "<topicSlug>" \
  [--force when renderBundlePending=true])
```

   Extract from the returned JSON:
   - `needs_generation` (bool)
   - `view_list` (array of `{name, source_section}`)
   - `view_source` (`'designSpec'` | `'businessSpec'` | `'none'`)
   - `output_path` (string — path where agent must write the HTML)
   - `sidecar_path` (string — path of the sidecar JSON)

2. **When `view_source` is `'none'`:** emit exactly one log line:

   ```
   bundle prototype generation skipped — no view list in DesignSpec § 4 or BusinessSpec § 5/§ 6
   ```

   This is `cmd_bundle_prototype_status`'s own hardcoded fallback probe order (DesignSpec § 4, then BusinessSpec § 5, then § 6) for placeholder-prototype generation — distinct from `BusinessSpec § 2` (Screens), the canonical screen-list section `commands/references/spec-section-contract.md` documents for story decomposition.

   Proceed to the prototypes[] merge below without generation.

3. **When `needs_generation` is `false` (sidecar matches, `view_source` is not `'none'`):** skip generation entirely. The sidecar at `.aimi/brainstorms/prototypes/<topicSlug>-bundle-sidecar.json` already matches all current hashes — reuse the existing file at `output_path`. Push `output_path` into `resolvedPrototypePaths` and proceed.

4. **When `needs_generation` is `true`:** ensure the output directory exists, then spawn the author agent:

```bash
mkdir -p "$(dirname "<output_path>")"
```

```
Task subagent_type="aimi-engineering:research:aimi-bundle-prototype-author"
  [model: <AGENT_MODELS.research when not "inherit">]
  prompt: "Generate a self-contained HTML prototype for the bundle.
           bundlePath: <bundlePath>
           viewList: <view_list extracted names as JSON array>
           viewSource: viewList
           designSpecPath: <designSpecPath or empty string when null>
           businessSpecPath: <businessSpecPath or empty string when null>
           chatPaths[]: <designBundleMeta.chats[] as JSON array>
           outputPath: <output_path>"
```

   After the agent writes `outputPath`, write the sidecar atomically:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI bundle-prototype-finalize \
  --topic "<topicSlug>" \
  --bundle-hash "<bundleHash>" \
  --design-spec-hash "<designSpecHash>" \
  --business-spec-hash "<businessSpecHash>" \
  --view-list "<view_list as JSON string>" \
  --source-command plan
```

   Push `output_path` into `resolvedPrototypePaths`.

When `designBundleMeta` is non-null:
- Extract the `prototypes` array from the bundle metadata (may be empty).
- For each path: resolve absolute path with `realpath`. Paths whose absolute resolution does not start with `AIMI_ROOT` are dropped with one-line warning `prototype <path> rejected — path outside project root` and excluded from `resolvedPrototypePaths`. For paths that pass validation, normalize to relative-to-`AIMI_ROOT` before merging. Deduplicate by relative path against paths already collected from the brainstorm frontmatter (insertion-order, first-occurrence wins).
- Stash the full bundle object as `designBundleMeta` for Phase 4 metadata derivation.

### Phase-Tier Spec Detail Authoring

Runs after `### Design Bundle Detection` has resolved `designBundleMeta` and before `### Phase 0.7: Spec Ingestion`. Fires only when ALL hold: `ROADMAP_MODE=true`, `designBundleMeta.businessSpec` is non-null, and that file contains the literal marker line `<!-- aimi:per-phase-detail-deferred -->` (a brainstorm of a phased feature writes it in each per-phase section; see `commands/references/business-spec-authoring.md` § Core vs per-phase). Otherwise skip with no output. It never fires when `ROADMAP_MODE=false` — a flat feature has no phase-tier location to author into. This subsection never prompts, in any mode.

The write path is always `$AIMI_ROOT/.aimi/tasks/$featureSlug/$PHASE_DIR/design-bundle` (`$featureSlug` and `$PHASE_DIR` from `#### Extract selected-phase working memory`), never any other location. Check for an existing bundle first:

```bash
PHASE_TIER_DIR="$AIMI_ROOT/.aimi/tasks/$featureSlug/$PHASE_DIR/design-bundle"
if [ -f "$PHASE_TIER_DIR/README.md" ]; then
  echo "phase-tier spec detail: $PHASE_TIER_DIR already authored — skipping"
fi
```

When `README.md` exists, authoring is skipped entirely and the existing phase-tier bundle is never overwritten; continue to the re-detection step below. Otherwise author:

1. **Core sections verbatim.** Copy BusinessSpec § 1, § 3, § 7 and § 11 from the feature-level BusinessSpec unchanged. Resolve each section number at run time from `commands/references/spec-section-contract.md`, as `business-spec-authoring.md`'s Write procedure directs, never from this text. A core section is never edited in place: when this phase's detail contradicts one, leave it as is and add the contradiction to § 11 as an open question.
2. **Evidence for § 4/§ 5.** Spawn the `aimi-spec-deriver` agent with `targets` taken from this phase's own `areas` (`PHASE_AREAS_JSON`) and its `creates`/`needs` identities, then render its `spec_derivation` block with `$AIMI_CLI spec-derivation --input <scratch file>`, exactly as `business-spec-authoring.md` § Propose-then-correct step 2 shows. Entity and endpoint rows come from the verb and nowhere else.
3. **Author § 2/§ 4/§ 5/§ 9** for this phase by following `business-spec-authoring.md`'s Write procedure, its Propose-then-correct and Absent-vs-unchecked rules, and its agent-mode behavior as written there: proposals are accepted as returned, and any item that would need an operator becomes a § 11 open question. Do not re-implement those rules here.
4. **Write the bundle.** `README.md` with the generated-bundle marker as `skills/aimi-design-handoff/references/spec-output-shape.md` § `README.md` directs (read from `aimi-cli.sh` at write time, never retyped), `project/BusinessSpec.md` with the sections above, and, when `designBundleMeta.designSpec` is non-null, `project/DesignSpec.md` copied verbatim from it.

**Re-detect.** After authoring, or after the skip-on-exists branch, re-run detection against the phase directory so `designBundleMeta` reflects the phase-tier bundle, which `_select_design_bundle` prefers over the scan tier:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
BUNDLE_STDOUT=$($AIMI_CLI detect-design-bundle --phase-dir "$AIMI_ROOT/.aimi/tasks/$featureSlug/$PHASE_DIR")
```

Overwrite `designBundleMeta` with the result (`null` or a JSON object); `### Phase 0.7: Spec Ingestion` then reads `businessSpecPath`/`designSpecPath` from it.

### Phase 0.7: Spec Ingestion

When `designBundleMeta` is non-null:
- Extract `businessSpec` path from `designBundleMeta` (may be `null`). Store as `businessSpecPath`.
- Extract `designSpec` path from `designBundleMeta` (may be `null`). Store as `designSpecPath`.

When `businessSpecPath` is non-null and the file exists on disk (within `AIMI_ROOT`):
- Read the file verbatim; enforce the **per-file spec truncation cap** of **200 KB** — truncate with a warning if exceeded.
- Store contents as `businessSpecContent`.

When `designSpecPath` is non-null and the file exists on disk (within `AIMI_ROOT`):
- Read the file verbatim; enforce the same **per-file spec truncation cap** of **200 KB** — truncate with a warning if exceeded.
- Store contents as `designSpecContent`.

Both bullets name the **same** ceiling: the per-file spec truncation cap is one ceiling applied once per file, not two independent ceilings, and it always shortens an oversized spec in place — it never removes one.

When either spec file is missing from disk, log a warning and set the corresponding content variable to `null`; continue — do not abort plan.
