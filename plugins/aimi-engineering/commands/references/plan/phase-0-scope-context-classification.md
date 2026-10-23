# Plan: Phase 0: Scope-Context Classification and Summary Line

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.

### Scope-Context Classification (Inline Fallback)

**Trigger.** Runs when EITHER no brainstorm was loaded in Phase 0, OR a brainstorm was loaded but its YAML frontmatter has no `phases:` key (legacy brainstorm). When the loaded brainstorm's frontmatter DOES contain a `phases:` key, skip this subsection entirely, with no log line — that feature's phase cut was already produced by `/aimi:brainstorm`'s Phase 3.5 roadmap-definition gate and is materialized by Roadmap Materialization above; it is never reclassified here. Set the `scopeContextClassificationVerdict` working-memory variable to `not-run` on this branch — Step 1's own classification never runs this session.

**Additional guard.** Also skip entirely, with no log line, when `ROADMAP_MODE` is already `true` (set by Rolling-Wave Phase Selection above). An existing `.aimi/tasks/<feature>/roadmap.json` for this feature already resolved a phase cut in an earlier session; Rolling-Wave Phase Selection has already selected and is expanding one of its phases this invocation. Proposing a new cut here would conflict with that phase. Set `scopeContextClassificationVerdict` to `not-run` on this branch too, for the identical reason — Step 1's own classification never runs.

**Step 1 — Classify.** Read `${CLAUDE_PLUGIN_ROOT}/commands/references/scope-contexts.md` (the `${CLAUDE_PLUGIN_ROOT}` prefix is required — it is the only form `install.sh` rewrites to `${AIMI_PLUGIN_DIR}` for OpenCode) and apply its Cut Criteria, Collapse Rule, and Anti-Patterns — the same shared reference `/aimi:brainstorm`'s Phase 3.5 Step 1 applies, exactly as written there; do not restate them here — to the feature description plus any `businessSpecContent`, `designSpecContent`, or already-loaded prototype content this session. The question this step answers is *which scope contexts exist in this feature*, never *how many stories does this need*; no numeric story-count threshold applies anywhere in this subsection.

- **0 or 1 scope contexts identified:** stop here. No `.aimi/tasks/<feature>/` folder is created, no roadmap CLI verb is called, no gate is shown — fall straight through to Phase 0.5 exactly as if this subsection did not exist. This is the default, most common path; emit no log line.
- **2 or more scope contexts identified:** continue to Step 2.

*(Optional debug: if `AIMI_PLAN_DEBUG=1`, emit `[plan-debug] scope-context-classification: <fired|skipped> (reason: scope-contexts=<N>)` to chat, where `<N>` is the scope-context count Step 1 classified — `fired` when `<N>` is 2 or more (Step 2 proposes a phase cut), `skipped` when `<N>` is 0 or 1 (fall straight through to Phase 0.5).)*

Set the `scopeContextClassificationVerdict` working-memory variable to the same `<fired|skipped>` token computed above — read back, never recomputed, by the Classification Summary Line subsection below. (Step 1 itself ran and classified 0 or 1 scope contexts here — that is `skipped`, distinct from the `not-run` set at this subsection's Trigger/Additional Guard above where Step 1 never ran at all.)

**Step 2 — Propose the cut.** Draft one phase entry per identified scope context in an in-memory `phases` array, using the identical field set, `id`/`idx` semantics, and JSON shape as `commands/brainstorm.md` Phase 3.5 Step 2 — `id`, `name`, `slug`, `goal`, `successCriteria`, `dependsOn`, `creates`, `needs`, `areas` (coarse file-area declaration), each derived per the matching section of `scope-contexts.md` exactly as that step does; see there for the full shape, not restated here. Before the gate is first presented, run the same Shared-Foundation Detection pass `scope-contexts.md` defines: for any artifact **identity** appearing in more than one proposed phase's `creates` (compare the `identity` field alone — two phases may describe the same artifact differently and still collide), promote it into its own foundation phase or consolidate it into whichever consuming phase comes first in dependency order, exactly as `commands/brainstorm.md` Phase 3.5 Step 2 does.

`name`, `goal`, and `successCriteria` are persisted into `roadmap.json`, a plugin-owned artifact, the same as when `commands/brainstorm.md` authors them — per the artifact-language rule (`commands/references/user-communication.md`), author them in English here too; a reader who lands in this fallback never opens `brainstorm.md` to learn that.

**Step 3 — Compact interactive gate.**

*Non-interactive fast path.* When `INTERACTIVE_MODE=agent` or `--non-interactive` was passed:
- Skip AskUserQuestion entirely — no gate, no Step 4 coverage check (no user is available to resolve an orphan).
- Auto-approve the `phases` array exactly as proposed in Step 2.
- Emit exactly one log line: `agent-mode: plan-roadmap-gate auto-approved <N> phases`, where `<N>` is the final phase count.
- Continue to Step 5.

*Interactive gate.* Render the current `phases` array as a numbered list:

```
Roadmap (N phases):
01. <name> — <goal>
02. <name> — <goal>
…
```

Present via AskUserQuestion with **exactly two options** — deliberately narrower than both the Phase 3c outline gate (Approve/Rename/Add/Remove/Reorder) and `/aimi:brainstorm`'s Phase 3.5 gate (Approve/Merge/Split/Reorder/Rename/Add/Remove): this is a compact fallback, not the primary authoring surface for a phase cut.

```
Approve — proceed with this roadmap
Edit — describe changes in free form
```

- **Approve**: run the Step 4 coverage check first.
  - Zero orphans → exit the loop, continue to Step 5.
  - One or more orphans → reject the selection, do not exit the loop; list the orphans to the user and re-present the gate. Approve stays unavailable until every orphan is resolved via Edit.
- **Edit**: ask one open free-text question — "What would you like to change about this phase cut?" — and apply the user's described restructuring (merge, split, reorder, rename, add, remove, or any combination, in a single round) to the `phases` array. Re-derive `slug` (via `commands/references/topic-slug.md`) for any phase whose `name` changed. Renumber `idx` when the edit changes array order or length. Append one entry to `oqDecisions[]`:
  ```json
  {
    "anchor": "phase:edit:<idx>",
    "source": "phase",
    "text": "User requested free-form edit to the proposed phase cut",
    "resolution": "<one-line summary of what changed>"
  }
  ```
  where `<idx>` is the zero-padded 1-based position, at edit time, of the lowest-indexed phase the edit touches — mirroring the `outline:edit:<idx>` convention's "position at edit time" semantics. Re-present the gate.

Loop until the user selects Approve and the coverage check passes with zero orphans.

**Step 4 — Coverage check (hard block).** Before Approve is accepted, verify that every distinct element of the feature description — plus, when loaded, every requirement named in `businessSpecContent`/`designSpecContent` and every distinct capability visible in loaded prototype content — maps to exactly one phase's `goal`, `successCriteria`, `creates`, `needs`, or `areas` field (verbatim or as a clear restatement), across the whole current `phases` array. An element with no match in any phase is an orphan.

- Zero orphans: the check passes.
- One or more orphans: name each orphan to the user and block Approve — re-present the gate (Step 3) until every orphan is resolved via Edit.

This mirrors `commands/brainstorm.md` Phase 3.5 Step 4, scoped to the feature description and loaded specs/prototypes in place of that gate's accumulated brainstorm-session Q&A.

**Step 5 — Materialize and hand off.** Once approved (interactively, or via the agent-mode fast path above):

1. Reuse `CANDIDATE_SLUG` — already computed and validated against the `--feature` pattern by Rolling-Wave Phase Selection's "Resolve `featureSlug` and detect roadmap mode" step above — as `featureSlug`. Do not re-derive it a second time.
2. Apply the Roadmap Materialization section's "Sanitize every phase field" and "Derive and validate each phase's directory segment" steps above, verbatim, to the approved `phases` array in place of that section's brainstorm-frontmatter entries, producing `sanitizedPhases`.
3. Call `roadmap-init` in creation mode — the identical CLI verb Roadmap Materialization's `absent` branch uses, not a parallel implementation — with `--feature "$featureSlug"`, no `--brainstorm-path` (no brainstorm exists on this path), and no `--sync` (the Additional Guard above already rules out an existing roadmap for this feature):
   ```bash
   AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
   : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
   $AIMI_CLI roadmap-init --feature "$featureSlug" <<'PHASES_JSON'
   <sanitizedPhases as a JSON array>
   PHASES_JSON
   ```
   On a non-zero exit whose stderr begins with either `Error: roadmap-init: malformed creates/needs entry` or `Error: roadmap-init: malformed creates/needs identity`, apply Roadmap Materialization's repair-and-retry-once rule above — the entries came from this command's own `sanitizedPhases` and the diagnostic names each one — before considering the run failed. On any other non-zero exit, or when that single retry also fails, surface the CLI's stderr as a single warning line and continue the rest of the plan pipeline as a flat, non-phased run — exactly the 0/1-scope-context fallback in Step 1 — rather than aborting the whole `/aimi:plan` invocation over a materialization failure. As above, when the feature had more than one phase, the warning line says so: the downgrade from a phased rollout to one flat plan is never left for the user to infer.
4. Set `ROADMAP_MODE=true` and continue at Rolling-Wave Phase Selection's "Load the roadmap and compute eligible pending phases" step above, treating the roadmap this step just wrote exactly as an existing one. Since every phase in a freshly created roadmap is `pending` with no live claim, the bare-invocation branch of "Select the target phase" selects the lowest eligible id automatically — confining this invocation to exactly one phase, per Rolling-Wave Phase Selection's rule; every other phase remains an outline-only entry in `roadmap.json` until a later `/aimi:plan` invocation selects it.

No parallel roadmap-write or phase-selection logic is implemented in this subsection — every step above re-enters an existing section by name rather than reimplementing it.

### Classification Summary Line

Emit exactly one line to chat, unconditionally — on every run, never gated behind `AIMI_PLAN_DEBUG` or any other environment variable — after both Roadmap Materialization and Scope-Context Classification (Inline Fallback) above have reached their own verdict. Read `roadmapMaterializationVerdict` and `scopeContextClassificationVerdict` back from working memory; this step never recomputes either.

```
[classification] roadmap-materialization=<roadmapMaterializationVerdict> scope-context-classification=<scopeContextClassificationVerdict>
```

Each token distinguishes the gate's own trigger check never running from the trigger check running and deciding not to fire:

- **`roadmap-materialization`** reads `not-run` when no brainstorm was loaded in Phase 0 (Roadmap Materialization's own "only runs when a brainstorm was loaded" guard means its `phases:` frontmatter parse never evaluates this run), and reads `skipped` — never `not-run` — when a brainstorm WAS loaded but its frontmatter's `phases:` key was absent or held fewer than 2 entries (the section's own debug line's `skipped` case).
- **`scope-context-classification`** reads `not-run` when either its Trigger guard (a loaded brainstorm's frontmatter already carries a `phases:` key) or its Additional Guard (`ROADMAP_MODE` already `true` on entry) short-circuits before Step 1's own classification ever runs, and reads `skipped` — never `not-run` — only when Step 1 itself ran and classified 0 or 1 scope contexts (that subsection's own debug line's `skipped` case).

This line carries only the two gate-name=token pairs above — no free-text classification content, scope-context names, phase names or goals, and no `reason:` detail. The two `[plan-debug]` lines above remain the only place that detail is carried, unchanged and still opt-in behind `AIMI_PLAN_DEBUG`; this line is an always-on summary above them, not a replacement.
