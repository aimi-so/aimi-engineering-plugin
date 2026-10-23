# Plan: Phase 3c: Outline Gate

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.

## Phase 3c: Outline Gate

Present the outline to the user and allow iterative editing before any expansion sub-agent is dispatched.

### Non-Interactive Fast Path

When `INTERACTIVE_MODE` is `agent` or `--non-interactive` was passed:
- Skip AskUserQuestion entirely.
- If `outlineWarnings` is non-empty, emit each warning as a chat log line **before** the auto-approve line:
  ```
  [warn] outline:<idx>: summary too short (<N> chars) — expand to clarify scope.
  [warn] outline:<idx>: path token '<token>' not found in File References — verify coverage.
  [warn] ... and N more entries with potential outline gaps.
  ```
  (emit only the lines present in `outlineWarnings` — the examples above show the possible formats)
- Emit **exactly** this chat line (substitute actual N):
  ```
  [plan] outline auto-approved (non-interactive): N stories
  ```
  where `N` is the number of entries in `outline.json`.
- Proceed directly to Phase 3d.

### Interactive Outline Gate Loop

Render the current outline as a numbered list:

```
Outline (N stories):
01. <title> — <summary>
02. <title> — <summary>
…
```

When the outline contains more than 15 entries, prepend a warning line:
```
Warning: N stories in outline. Consider splitting into smaller feature sets.
```

When `outlineWarnings` is non-empty, prepend each line from `outlineWarnings` as preamble text before the AskUserQuestion picker. Emit these lines in order, one per line, immediately before the picker options (after the N>15 warning when both apply):
```
[warn] outline:<idx>: summary too short (<N> chars) — expand to clarify scope.
[warn] outline:<idx>: path token '<token>' not found in File References — verify coverage.
[warn] ... and N more entries with potential outline gaps.
```
(emit only the lines present in `outlineWarnings` — the examples above show the possible formats)

Present via AskUserQuestion with these options:

```
Approve — proceed to expansion
Rename <idx> — change a story title/summary
Add — insert a new story at a position
Remove <idx> — remove a story from the outline
Reorder — change story order
```

**Foundation carve-out (when the outline carries at least one foundation entry, Phase 3b's Foundation-first rule):** the **protected set** is every current outline entry whose own `foundationEntry` field is `true` — identify them by that field, never by position alone, though the Foundation-first rule guarantees they occupy the contiguous front block `"01"` … `"0M"`, where `M` is the number of protected entries. Each protected entry is the foundation story of the repository named by its own `foundationProject` and is immutable through this gate. Reject the operation and re-present the gate when the user selects:

- **Remove `<idx>`** where the entry at `<idx>` has `foundationEntry: true`;
- an **Add** whose requested insertion point would place the new entry at or before the `M`-th protected entry — i.e. its resulting `idx` would be `<= M`, pushing a protected entry out of the protected front block (generalizing "at position `01`, pushing it out of first place");
- a **Reorder** whose new order's first `M` `idx` values are not exactly the original protected entries, in their original relative order.

Branch the rejection message on `M`, the number of protected entries at the moment of rejection — never on whether the layout is literally single-repo.

**When `M` is 1** — a genuine single-repo run, and equally a multi-repo run where only one repository's gate accepted — re-present the gate with this exact message, verbatim:
```
foundation story is fixed — to discard it, re-run /aimi:plan and choose Skip in the Foundation Gate
```

**When `M >= 2`** — re-present the gate with the same shape, naming the repositories the rejected edit would have disturbed. For a **Remove**, name that one entry's own `foundationProject`:
```
foundation story for <foundationProject> is fixed — to discard it, re-run /aimi:plan and choose Skip in that repository's Foundation Gate
```
For an **Add** or a **Reorder**, which displace the protected block as a whole, name every protected entry's `foundationProject`, comma-separated, in outline order:
```
foundation stories for <foundationProject>, <foundationProject>, … are fixed — to discard one, re-run /aimi:plan and choose Skip in that repository's Foundation Gate
```

No `oqDecisions[]` entry is recorded for a rejected edit. **Rename** of a protected entry, and any Add/Remove/Reorder operation that does not touch or displace a protected entry, proceed normally.

**For each edit operation:**

- **Approve**: exit the loop, proceed to Phase 3d.
- **Rename `<idx>`**: ask for the new title and summary; update `outline.json` entry at `idx`. Record in `oqDecisions[]`:
  ```json
  {
    "anchor": "outline:edit:<idx>",
    "source": "outline",
    "text": "User renamed outline entry <idx>",
    "resolution": "title: '<new-title>' / summary: '<new-summary>'"
  }
  ```
  Increment `outlineEditCount`. Re-present the gate.
- **Add**: ask for position (after which `idx`) and the new title/summary; insert the entry, renumber all subsequent `idx` values. Record in `oqDecisions[]`:
  ```json
  {
    "anchor": "outline:edit:<new-idx>",
    "source": "outline",
    "text": "User added outline entry at position <new-idx>",
    "resolution": "title: '<title>' / summary: '<summary>'"
  }
  ```
  Increment `outlineEditCount`. Rewrite `outline.json`. Re-present the gate.
- **Remove `<idx>`**: remove the entry; renumber subsequent `idx` values. Record in `oqDecisions[]`:
  ```json
  {
    "anchor": "outline:edit:<idx>",
    "source": "outline",
    "text": "User removed outline entry <idx>",
    "resolution": "removed: '<title>'"
  }
  ```
  Increment `outlineEditCount`. Rewrite `outline.json`. Re-present the gate. If removing an entry causes zero stories remaining, present an error and ask the user to add at least one story before approving.
- **Reorder**: ask for the new order as a comma-separated list of `idx` values; rebuild the array in the specified order, renumber `idx` from `01`. Record in `oqDecisions[]`:
  ```json
  {
    "anchor": "outline:edit:reorder",
    "source": "outline",
    "text": "User reordered outline",
    "resolution": "new order: <comma-separated original idx values>"
  }
  ```
  Increment `outlineEditCount`. Rewrite `outline.json`. Re-present the gate.

Loop until the user selects **Approve**.

### Phase 3c.5: Payload Estimate (Advisory)

**When `ROADMAP_MODE=true`, runs once immediately after the outline gate approves** (either the non-interactive auto-approve above or the interactive loop's Approve option), before any Phase 3d expansion Task is spawned. **When `ROADMAP_MODE=false`: skip entirely — no log line, no CLI call.**

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
PAYLOAD_JSON=$($AIMI_CLI estimate-payload \
  --outline "$RUN_DIR/outline.json" \
  [--research <path> for each path in metadata.researchPaths so far this run] \
  [--spec <path> for businessSpecPath and/or designSpecPath, each when non-null] \
  [--prototype <path> for each entry in resolvedPrototypePaths] \
  2>&1)
```

The ceiling `estimate-payload` resolves and reports `overBudget` against is the **advisory payload budget**. This is purely advisory — `estimate-payload` always exits 0 for valid input and never blocks, trims, or otherwise alters the pipeline. Read `PAYLOAD_JSON.overBudget`:

- **`false`:** proceed silently to Phase 3d. An `overBudget` of `false` does not mean nothing was dropped — the aggregate prototype drop cap in Phase 0 may already have removed whole prototype blocks before this estimate was taken, so the advisory payload budget can only vouch for what reached it.
- **`true`:** surface the CLI's own generic warning (`PAYLOAD_JSON.warning`) plus a concrete, phase-specific split hint the CLI cannot compute on its own (it has no visibility into individual outline entries): take the **second half** of `outline.json`'s entries (rounded down; e.g. 7 entries → last 3) and name them as split candidates:
  ```
  Payload estimate for phase [SELECTED_PHASE_ID] exceeds budget ([PAYLOAD_JSON.totalBytes] bytes > [PAYLOAD_JSON.budgetBytes] byte budget).
  [PAYLOAD_JSON.warning]

  Suggested split: move outline entries [idx]–[idx] ("[title]", "[title]", ...) into a new decimal sub-phase [SELECTED_PHASE_ID].1 at the next /aimi:brainstorm roadmap-gate pass.
  ```
  This never blocks — after printing it, proceed to Phase 3d unchanged. The suggestion is advice for a *future* roadmap edit, not an action this run takes automatically.
