# Plan: Step 4.6 and Step 5: Research GC and Aimi-Branded Report

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.
>
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

## Step 4.6: Research GC (advisory, non-fatal)

After all validations pass, invoke research-gc once to prune orphaned research files older than 30 days. This must run **after** Phase 4 writes metadata (so newly registered researchPaths are not pruned), and only once per session.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI research-gc || true
```

If `research-gc` fails or prints an error, log it but continue to Step 5 — GC failure is never blocking.

## Step 5: Aimi-Branded Report

```
Tasks generated successfully!

Tasks: .aimi/tasks/[tasks-filename].json

[If ROADMAP_MODE]: Phase: [SELECTED_PHASE_ID] ([PHASE_NAME]) — status: planned
Stories: [X] total
Schema version: 3.3
Waves: [N] total
Outline: [N] stories (edits: [M])
[If gates found]: Gates: [N] (verify: [X], decision: [Y], action: [Z])
[If brainstorm used]: Context: .aimi/brainstorms/[brainstorm-file]
[If reusedPaths non-empty]: Research reused: [N] file(s) from brainstorm
[If prototypePaths non-empty]: Prototypes: [N] variant file(s) registered
[If structural-vocabulary measured]: Vocabulary: [N] missing, [M] unsourced (advisory)
Verify probe: [N] unlabelled non-discriminating, [M] unmeasured, [K] not probed
[If gaps found]: Gaps identified: [N] (captured as criteria/notes)
[If auditFailed]: Audit: shipped unaudited
[If audit unresolved non-empty AND Unresolved Gate outcome is "applied"]: Audit warnings: [N] cross-story issue(s) — reviewed, applied
[If audit unresolved non-empty AND Unresolved Gate outcome is "deferred"]: Audit deferred: [N] item(s) — flagged on affected stories, review before execution
[If metadata.smellWarnings non-empty]: Smell warnings: [N] finding(s)
[If 10+ stories]: Warning: [N] stories generated. Consider splitting into smaller feature sets.
[If parallel stories detected]: Parallel groups: [N] stories can run concurrently (max concurrency: [maxConcurrency])

Next steps:
1. **Run `/aimi:deepen`** - Enrich stories with research (optional)
2. **Run `/aimi:status`** - View task list
3. **Run `/aimi:execute`** - Begin autonomous execution
```

**Tasks line:** render one `Tasks:` line per file in `MERGE_RETURN` (Phase 3e), in the returned order — one line on the legacy path, two on the SIDE axis, N on the PROJECT axis. On the PROJECT axis, suffix each line with its entry's own `project` and `storyCount` (e.g. `Tasks: .aimi/tasks/2026-07-27-checkout-apps-web-tasks.json (apps/web, 4 stories)`) so the reader can tell which repo each file drives. Never print a filename that is not in the returned list.

**Verify probe line:** `Verify probe: N unlabelled non-discriminating, M unmeasured, K not probed` — always present, fed by the counts the Phase 4.5 Step 3 block printed (summed across every file in `VALIDATE_FILES`). A non-zero `K` means some file's verifies were never measured, which is a different statement from zero findings; list each `not probed` and `unmeasured` line beneath it as bullets.

**Outline line:** `Outline: N stories (edits: M)` where `N` is the number of stories in the approved outline (from `outline.json`) and `M` is `outlineEditCount` (the number of edits applied during the Phase 3c gate — rename, add, remove, and reorder each count as one edit).

**IMPORTANT:** Output the "Next steps" block EXACTLY as shown above — use `/aimi:` prefix (e.g., `/aimi:deepen`), NOT the fully-qualified plugin name (e.g., `/aimi-engineering:deepen`). Copy the block verbatim.

**Audit line:** `Audit: shipped unaudited` is printed exactly when the Failure Fallback stub fired in this run (`auditFailed`); story-merge confirms it with a stderr line containing `plan shipped unaudited`. A run whose audit never failed prints nothing here.

**Audit warnings / Audit deferred line:** present only when Phase 3d.5 ran, `unresolved[]` was non-empty, and the Phase 3d.5 Unresolved Gate above resolved it via **Apply anyway** or **Defer with reason** — never via Abort, since Step 5 is never reached on that path. `N` is the count of items in `unresolved[]`. The two lines are mutually exclusive, keyed by the gate's outcome:
- **Apply anyway:** `Audit warnings: [N] cross-story issue(s) — reviewed, applied`
- **Defer with reason** (chosen interactively, or auto-selected by the agent-mode fallback): `Audit deferred: [N] item(s) — flagged on affected stories, review before execution`

Either way, render each item as a bullet immediately after that line:
- `[storyIdx]: [sanitized message]` — `storyIdx` and `message` come from the `unresolved[]` entry schema `{storyIdx, message}`.

**Sanitization before rendering** — auditor-emitted `message` strings carry text that originated (transitively) from sub-agent output and may contain hostile characters. Before rendering each bullet, apply this sanitization to the `message` field in order:
1. Replace newlines and carriage returns with single spaces.
2. Strip any `$(` sequences.
3. Remove backtick characters.
4. Truncate to 200 characters; append `…` when truncation fires.

The `storyIdx` field is already constrained by the schema (`^[0-9]{2}$` or the `_audit` sentinel) and requires no sanitization. When `unresolved[]` is empty, Phase 3d.5 was skipped (fewer than 2 stories), or the gate resolved via Abort (in which case Step 5 is never reached at all), omit both lines and the bullet list entirely — do not render an empty section.

**Smell warnings line:** present only when the merged tasks.json has a non-empty `metadata.smellWarnings` array. `N` is the count of entries. Render each item as a bullet immediately after the `Smell warnings` line, choosing the case that matches its `type`:

- `type == "orphan-symbol"` — written by `story-merge` Phase 4.2 when one or more stories introduce a named symbol that no sibling story references: `[storyId] [type]: [symbols joined by comma] — [message]` — fields come from the entry schema `{type, storyId, symbols, message}`.
- `type == "field-overlap"` — advisory, written by story-merge when a story's `tasks[]` restates its `implementation.approach`: `[storyId] field-overlap ([ratio] of [ngram]-word sequences): [message]`, from the entry schema `{type, storyId, ratio, ngram, message}`.
- `type == "story-oversize"` — advisory, written when a story serializes far above the plan median or the byte floor: `[storyId] story-oversize ([bytes] bytes, median [medianBytes], floor [floorBytes]): [message]`, from the entry schema `{type, storyId, bytes, medianBytes, floorBytes, message}`. After either bullet, a reader who has reviewed the finding can record that with `acknowledge-smell <story-id> --type <type> --reason <text>` (named once here; it refuses in agent mode, and nothing waits on it for these types).
- `type == "audit-duplication"` — advisory, written when an audit patch changed both `tasks` and `implementation.approach` of a story and `tasks[]` now restates the approach: `[storyId] audit-duplication ([ratio] of [ngram]-word sequences): [message]`, from the entry schema `{type, storyId, ratio, ngram, message}`.
- `type == "stale-sibling-note"` — advisory, written when a paragraph of `notes` before the last audit separator cites another story of the plan: `[storyId] stale-sibling-note (cites [cited joined by comma]): [message]`, from the entry schema `{type, storyId, cited, message}`, where `cited` is the sorted list of cited story ids.
- `type == "leftover-outline-token"` — advisory, written when an `outline:` token followed by digits survived the remap in a string field other than `dependsOn`: `[storyId] leftover-outline-token ([fields joined by comma]): [message]`, from the entry schema `{type, storyId, fields, message}`, where `fields` names each affected field.
- `type == "ac-test-enumeration"` — advisory, written for an acceptance criterion that lists three or more distinct test names (that coverage belongs in `tasks[]`): `[storyId] ac-test-enumeration (criterion [index], [count] tests): [message]`, from the entry schema `{type, storyId, index, count, message}`; one entry per offending criterion.
- `type == "cross-file-dep-dropped"` — written when `--split full-stack` drops a `dependsOn` edge that crosses an output-file boundary. The split axis decides which key names the owning group, and the two keys are mutually exclusive per entry:
  - **SIDE axis** (`_story_merge_write_split`, the single-repo/monorepo fallback — fewer than 2 distinct normalized `.project` values): entry schema `{type, storyId, side, becameRoot, droppedDeps[], message}`, where `side` is `"frontend"`/`"backend"` (and `"unknown"` for an unresolvable target) and each `droppedDeps[]` element is `{id, side, title}`.
  - **PROJECT axis** (`_story_merge_write_project_split`, the multi-repo N-file writer — 2 or more distinct normalized `.project` values): entry schema `{type, storyId, project, becameRoot, droppedDeps[], message}`, where `project` is the owning group's routing key (e.g. `"apps/web"`, `"services/api"`, `"."` for the root group) and each `droppedDeps[]` element is `{id, project, title, foundationEdge}`. `foundationEdge` is `true` exactly when the dropped edge's pre-remap target is a story some `--foundation` value named, in **any** project group — computed by membership against the full set of resolved foundation ids, not against one shared foundation. It can never mark an edge the merge itself injected: injection is **per project group**, so both endpoints of an injected edge share one routing key and therefore one per-block idmap, and the remap never drops it. Every `true` reading is consequently a **hand-authored** dependency reaching into another group's foundation — one repository's Foundation Gate resolved Accept while a sibling's resolved Skip, or a story predating the per-repo split — which is the opposite of what this field meant while one foundation was shared by the whole run, and is worth flagging apart from an ordinary cross-project drop because of what it targets rather than where it came from. story-merge emits one stderr note line for these, separate from the ordinary drop-count banner. It is `false` on every other edge, and on every edge of a run without `--foundation`.

  Render either shape as `[storyId] ([side-or-project value]): [message]` — read whichever of `.side`/`.project` the entry actually carries (never both). `droppedDeps[]` may optionally be rendered as a nested sub-bullet listing the dropped target(s), using that same key; it is not required in the one-line form.

Sanitization differs by type. For `orphan-symbol`: no sanitization required — `type` and `message` are CLI-emitted literals (not derived from sub-agent output), and `storyId`/`symbols` are already filtered through the Phase 4.2 regex (`^[A-Za-z][A-Za-z0-9_]*$` for symbols, `^US-[0-9]{3}[a-z]?$` for storyId).

For `field-overlap`, `story-oversize`, `audit-duplication`, `stale-sibling-note`, `leftover-outline-token` and `ac-test-enumeration` (all six advisory types): the numeric fields, `storyId` and `cited` are CLI-computed, but `message` and each `fields` entry (a field name taken from the staged story, so not a closed set) are run through the same four steps below before rendering.

For `cross-file-dep-dropped`: **nothing in this variant is literal-safe.** `message` and `droppedDeps[].title` embed a sub-agent-authored story title, and `project` / `droppedDeps[].project` carry a sub-agent-authored `.project` value — free text, not a closed-set CLI literal. The CLI's `_rm_sanitize` pass is a 200-char cap applied to titles before write, not a rendering guard, and it covers neither the project keys nor the shell metacharacters this renderer's output can reach. Before rendering a bullet, apply the same four steps the `Audit warnings` bullets use above, in order, to **each** of `message`, `droppedDeps[].title`, `project`, `side`, and `droppedDeps[].project`:

1. Replace newlines and carriage returns with single spaces.
2. Strip any `$(` sequences.
3. Remove backtick characters.
4. Truncate to 200 characters; append `…` when truncation fires.

This holds identically on both axes. When `metadata.smellWarnings` is absent or empty, omit the section entirely.

For split-file output (`--split full-stack`), `metadata.smellWarnings` is written to EVERY file the split produces — both frontend and backend on the SIDE axis, all N project files on the PROJECT axis. Render it once per file in the `MERGE_RETURN` list (Phase 3e), alongside that file's own `Tasks:` line, so each per-file summary stays self-contained. Drive the repetition off the returned list's length — never off a fixed count of two.
