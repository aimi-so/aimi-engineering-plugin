# Plan: Phase 3c: Outline Gate

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.

## Phase 3c: Outline Gate

Present the outline to the user and allow iterative editing before any expansion sub-agent is dispatched.

### Non-Interactive Fast Path

When `INTERACTIVE_MODE` is `agent` or `--non-interactive` was passed:
- Skip AskUserQuestion entirely.
- `outlineContractErrors` is empty here: the Phase 3b Outline Contract Check already repaired once or stopped the run.
- If `outlineWarnings` is non-empty, emit each warning as a chat log line **before** the auto-approve line:
  ```
  [warn] outline:<idx>: summary too short (<N> chars) — expand to clarify scope.
  [warn] outline:<idx>: path token '<token>' not found in File References — verify coverage.
  [warn] ... and N more entries with potential outline gaps.
  ```
  (emit only the lines present in `outlineWarnings` — the examples above show the possible formats)
- Emit the wave summary line **before** the auto-approve line (`W` is the number of `outlineWaves`; entries of one wave are space-separated, waves are separated by ` | `; no contracts at all reads as one wave):
  ```
  [plan] outline waves (W): 01 02 | 03 | 04
  ```
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

Append `[produces P, consumes C]` to each line from `outlineCounts`, then one wave line below the list (same format as above, `W` is the number of `outlineWaves`):

```
Waves (W): 01 02 | 03 | 04
```

When `outlineContractErrors` is non-empty (see the Phase 3b Outline Contract Check), show each as `[error] <code>: <message>` before the picker. **Approve is refused while any stands**: re-present the gate with the errors, and the wave line is omitted because there are no waves.

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
- **Rename `<idx>`**: ask for the new title and summary, and for the entry's `produces` and `consumes` (offer the current ones as the default); update `outline.json` entry at `idx`. Record in `oqDecisions[]`:
  ```json
  {
    "anchor": "outline:edit:<idx>",
    "source": "outline",
    "text": "User renamed outline entry <idx>",
    "resolution": "title: '<new-title>' / summary: '<new-summary>'"
  }
  ```
  Increment `outlineEditCount`. Rewrite `outline.json`. Re-run the contract check. Re-present the gate.
- **Add**: ask for position (after which `idx`), the new title/summary and the entry's `produces` and `consumes`; insert the entry, renumber all subsequent `idx` values. Record in `oqDecisions[]`:
  ```json
  {
    "anchor": "outline:edit:<new-idx>",
    "source": "outline",
    "text": "User added outline entry at position <new-idx>",
    "resolution": "title: '<title>' / summary: '<summary>'"
  }
  ```
  Increment `outlineEditCount`. Rewrite `outline.json`. Re-run the contract check. Re-present the gate.
- **Remove `<idx>`**: remove the entry; renumber subsequent `idx` values. Contracts are kept by name, never by position: every other entry keeps its own `produces`/`consumes` arrays unchanged, because a token names a thing and not an `idx`, so nothing goes stale when `idx` moves. Record in `oqDecisions[]`:
  ```json
  {
    "anchor": "outline:edit:<idx>",
    "source": "outline",
    "text": "User removed outline entry <idx>",
    "resolution": "removed: '<title>'"
  }
  ```
  Increment `outlineEditCount`. Rewrite `outline.json`. Re-run the contract check. Re-present the gate. If removing an entry causes zero stories remaining, present an error and ask the user to add at least one story before approving.
- **Reorder**: ask for the new order as a comma-separated list of `idx` values; rebuild the array in the specified order, renumber `idx` from `01` and nothing else: each entry carries its own `produces`/`consumes` along, by name. Record in `oqDecisions[]`:
  ```json
  {
    "anchor": "outline:edit:reorder",
    "source": "outline",
    "text": "User reordered outline",
    "resolution": "new order: <comma-separated original idx values>"
  }
  ```
  Increment `outlineEditCount`. Rewrite `outline.json`. Re-run the contract check. Re-present the gate.

Loop until the user selects **Approve**.

### Edit Outline After Expansion

Reached from the `Edit outline` option of the Failure Budget (Phase 3d) and of the Phase 3d.5 Unresolved Gate, never otherwise. **Interactive only**: the option is not offered when `INTERACTIVE_MODE=agent` (specFlow:CriticalQ3). It lets the outline change after stories were expanded without throwing the expansion away: a pure index shift is renamed by a verb, and only the stories the edit really affects are expanded again.

1. **Keep the outline as it was.** Copy it under a name that ends in `-outline.json`, so `story-merge` reads it as a sidecar and the staging guard's `NN-` pattern never meets it:

   ```bash
   cp "$RUN_DIR/outline.json" "$RUN_DIR/pre-edit-outline.json"
   ```

2. **Re-open the gate.** Run the Interactive Outline Gate Loop above on `outline.json` until the user approves: the foundation carve-out, the `oqDecisions[]` records and the contract check apply unchanged. The staged story files are not touched while the user edits.

3. **Shift the staged files.** On Approve, run the verb. It matches entries by exact title, renames the shifted `NN-<slug>.json` files, rewrites their `outline:NN` tokens in one pass, deletes the file of a removed entry, deletes `audit-result.json` when anything changed, and prints `{renamed[{from,to,file}], removed[], reexpand[{idx,reason}], expand[], auditInvalidated}` (`removed` and `renamed[].from` are `pre-edit-outline.json` idx; every other idx is in the new numbering):

   ```bash
   AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
   : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
   SHIFT_REPORT=$($AIMI_CLI outline-shift --staging-dir "$RUN_DIR" --old "$RUN_DIR/pre-edit-outline.json" --new "$RUN_DIR/outline.json") || exit 1
   printf '%s' "$SHIFT_REPORT" | jq -c '{renamed, removed, reexpand, expand, auditInvalidated}'
   ```

   A non-zero exit changed nothing: surface the verb's message, copy `pre-edit-outline.json` back over `outline.json`, and return to the gate that offered `Edit outline`.

4. **Delete before re-spawning.** For every idx in `reexpand`, delete its staged file with Bash `rm -f "$RUN_DIR/<idx>-<slug>.json"` (the name is `renamed[].file` when the file moved, otherwise unchanged) before its expander is spawned: the staging guard denies a Write over an existing `NN-*.json`, and a kept file still carries a token to a removed entry that the new numbering now aliases. Never Edit or Write a staged file by hand. An `expand` idx has no file to delete.

5. **Expand what is left.** Take the waves from `validate-outline` on the new `outline.json` (Wave Dispatch, Step 1), then expand the `reexpand` and `expand` idx in wave order, with the producer slices of Wave Dispatch Step 3 read from the kept, validated files. Each goes through the Working Tree Guard and Schema Validation and Retry in full, step 2b included. **At most one automatic pass per story**: a story that fails its retries is permanently failed and goes to the Failure Budget; it is not expanded again here, and expanding it does not queue its dependents. A failed producer holds back its closure as usual.

6. **Audit again, from a clean slate.** Clear the Phase 3d.5 working-memory state (`unresolved[]`, `auditFailed`, the interim counts) and re-run Phase 3d.5 in full: Skip Condition, auditor spawn, `audit-result.json`, `apply-audit-patches`, Unresolved Gate. The pre-edit audit is never reused, which is why the verb deleted it.

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
