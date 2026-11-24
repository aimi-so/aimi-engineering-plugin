# Brainstorm: Phase 3.5: Roadmap Definition Gate

> Loaded by `commands/brainstorm.md` when its `Applies when:` condition holds.
>
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

## Phase 3.5: Roadmap Definition Gate

Detect whether the feature is large enough to need a phase/milestone roadmap, and if so, gate an approved, coverage-checked phase cut before Phase 4 writes the document. This phase never creates `.aimi/tasks/<feature>/roadmap.json` or any file under `.aimi/tasks/` — materializing a roadmap from the `phases:` frontmatter this step writes is owned by `/aimi:plan` (see `outline:07`), not brainstorm.

### Step 1: Scope-Context Trigger Check

Classify the feature into scope contexts using the Cut Criteria in `${CLAUDE_PLUGIN_ROOT}/commands/references/scope-contexts.md` — read that file and apply its criteria as written; do not restate them here. (The `${CLAUDE_PLUGIN_ROOT}` prefix is required: it is the only form `install.sh` rewrites to `${AIMI_PLUGIN_DIR}` for OpenCode. A bare relative path does not resolve there, which would silently degrade the phase cut to improvisation.) Consider the full feature description, the consolidated research summary (Step 1c), and every answer gathered across Phase 2 and Phase 3.

- **0 or 1 scope contexts identified:** Skip this entire phase — emit no log line, propose no phase cut, present no gate. Proceed directly to Phase 4 exactly as today. No `phases:` frontmatter is written and nothing about the document changes.
- **2 or more scope contexts identified:** Continue to Step 2.

*(Optional debug: if `AIMI_BRAINSTORM_DEBUG=1`, emit `[brainstorm-debug] phase-3.5: <fired|skipped> (reason: scope-contexts=<N>)` to chat, where `<N>` is the scope-context count this step classified — `fired` when `<N>` is 2 or more (Step 2 proposes a phase cut), `skipped` when `<N>` is 0 or 1 (collapse — no `phases:` frontmatter, document unchanged).)*

Set the `phase35Verdict` working-memory variable to the same `<fired|skipped>` token computed above — read back, never recomputed, by Phase 3.8's classification summary line.

### Step 2: Propose the Phase Cut

For each identified scope context, draft one phase entry in an in-memory `phases` array (no staging file is written — unlike `/aimi:plan`'s `outline.json`, this array never touches disk until Phase 4's frontmatter write):

```json
{
  "id": 1,
  "name": "Checkout",
  "slug": "checkout",
  "goal": "Users can complete a purchase end to end.",
  "successCriteria": [
    "Cart totals reflect tax and shipping before payment.",
    "Payment confirmation is shown on success."
  ],
  "dependsOn": [],
  "creates": [{"identity": "orders", "description": "stores completed purchase records"}],
  "needs": [],
  "areas": ["app/checkout/**"]
}
```

`name`, `goal`, and `successCriteria` are persisted into `roadmap.json`, a plugin-owned artifact — per the artifact-language rule (`commands/references/user-communication.md`), author them in English.

- `id` — plain number, 1-based in cut order. Kept as a plain number (never a zero-padded string) so a later insertion can use a decimal value (e.g. `2.1`) without renumbering every phase — see `outline:07` for where that matters.
- `name` — short phase name.
- `slug` — derived from `name` via the five-step algorithm in `commands/references/topic-slug.md`.
- `goal` — an outcome statement, not a task list, per the "Goal and Success Criteria" section of `scope-contexts.md`.
- `successCriteria` — 2 to 5 observable criteria per `scope-contexts.md`. A criterion that states a number must carry the command that produced it — see Step 4's numeric-criteria check, which blocks Approve until it does.
- `dependsOn` — list of other phases' `id` values this phase's stories cannot start before.
- `creates` / `needs` — artifact contracts per the "Creates/Needs Contracts" section of `scope-contexts.md`.
- `areas` — coarse top-level directories/globs per the "Coarse File-Area Declaration" section of `scope-contexts.md`.

Alongside `id`, assign each phase a transient `idx` equal to its zero-padded 1-based position in the in-memory `phases` array (`"01"`, `"02"`, …). `idx` exists only for gate anchors (Step 3 below), is recomputed after every edit that changes array order or length, and is never written to disk — do not confuse it with the persisted numeric `id` field.

**Shared-foundation detection (run once, before the gate is first presented):** Apply the "Shared-Foundation Detection" rule from `scope-contexts.md`. For any artifact **identity** appearing in more than one phase's `creates` (compare the `identity` field alone — two phases may describe the same artifact differently and still collide):

- If no consuming phase is a clean "first mover" for the artifact, **promote** it: insert a new phase whose sole `creates` entry is that artifact; every originally-consuming phase adds the new phase's `id` to `dependsOn` and moves the artifact from its `creates` to its `needs`.
- Otherwise, **consolidate**: keep the artifact in the `creates` list of whichever phase comes first in dependency order; remove it from every other phase's `creates` and add it to those phases' `needs` instead.

After this step, no artifact identity may appear in `creates` for more than one phase in the proposed cut.

### Step 3: Interactive Gate

#### Non-Interactive Fast Path

When `INTERACTIVE_MODE=agent`:

- Skip AskUserQuestion entirely — do not present the gate, do not run the Step 4 coverage check (there is no user available to resolve an orphan).
- Auto-approve the `phases` array exactly as proposed in Step 2 (post shared-foundation detection, pre any edits).
- Log exactly one line to the brainstorm document's working memory: `agent-mode: roadmap-gate auto-approved <N> phases`, where `<N>` is the final phase count.
- Proceed to Step 6 (frontmatter emission) with the approved array.

#### Interactive Roadmap Gate Loop

Render the current `phases` array as a numbered list:

```
Roadmap (N phases):
01. <name> — <goal>
02. <name> — <goal>
…
```

Present via AskUserQuestion (picker mode) with these options:

```
Approve — proceed to Phase 4 with this roadmap
Merge <idx1>+<idx2> — combine two phases into one
Split <idx> — divide one phase into two
Reorder — change phase order
Rename <idx> — change a phase's name, goal, or other fields
Add — insert a new phase at a position
Remove <idx> — remove a phase from the roadmap
```

**For each edit operation, append one entry to a `phaseEditDecisions[]` working-memory list** (distinct from `oqDecisions[]` — this list is local to Phase 3.5) using the anchor form `phase:edit:<idx>` (the zero-padded 2-digit `idx` of the affected position **at edit time**) and `source: "phaseGate"`. **This list is intentionally session-local and is never persisted.** It exists only to let the loop below reason about what changed during gating; once Approve is accepted, only the final `phases` array survives — as the `phases:` frontmatter block Phase 4 emits (see "phases frontmatter rules") — and `phaseEditDecisions[]` itself is discarded at session end, unlike `oqDecisions[]`/`metadata.decisions[]` which flow into the tasks.json written downstream:

- **Approve**: run the Step 4 coverage check first.
  - If it reports zero orphans, exit the loop and continue to Step 5.
  - If it reports one or more orphans, **reject this selection** — do not exit the loop. List the orphans to the user and re-present the gate; Approve remains unavailable until every orphan is resolved via Merge, Rename, or Add.
- **Merge `<idx1>+<idx2>`**: ask which two phases to merge if not already specified; union their `successCriteria`, `creates`, `needs`, `areas`, and `dependsOn` (de-duplicated), keep the first phase's `name`/`goal` unless the user supplies replacements, drop the second phase, and renumber `idx`. Any other phase that referenced the removed phase's `id` in `dependsOn` is repointed to the surviving phase's `id`. Record:
  ```json
  {
    "anchor": "phase:edit:<idx>",
    "source": "phaseGate",
    "text": "User merged phases <idx1> and <idx2>",
    "resolution": "merged into: '<surviving name>'"
  }
  ```
  If this merge reduces the array to exactly 1 phase, do not error — continue the loop; Step 5 handles the collapse silently once Approve is finally selected.
- **Split `<idx>`**: ask which `successCriteria`/`creates` entries belong to each resulting phase and the name/goal for the new second phase; partition the original phase's fields accordingly, insert the new phase immediately after the original, and renumber `idx`. Record:
  ```json
  {
    "anchor": "phase:edit:<idx>",
    "source": "phaseGate",
    "text": "User split phase <idx>",
    "resolution": "into: '<name A>' / '<name B>'"
  }
  ```
- **Reorder**: ask for the new order as a comma-separated list of `idx` values; rebuild the array in that order and renumber both `idx` and `id` from 1. Record:
  ```json
  {
    "anchor": "phase:edit:reorder",
    "source": "phaseGate",
    "text": "User reordered phases",
    "resolution": "new order: <comma-separated original idx values>"
  }
  ```
- **Rename `<idx>`**: ask which field(s) to change (name, goal, successCriteria, dependsOn, creates, needs, areas); update the entry. If `name` changes, re-derive `slug` via `commands/references/topic-slug.md`. Record:
  ```json
  {
    "anchor": "phase:edit:<idx>",
    "source": "phaseGate",
    "text": "User renamed/edited phase <idx>",
    "resolution": "<field>: '<new value>'"
  }
  ```
- **Add**: ask for position (after which `idx`), name, goal, successCriteria, dependsOn, creates, needs, and areas; insert the entry and renumber `idx`. Record:
  ```json
  {
    "anchor": "phase:edit:<new-idx>",
    "source": "phaseGate",
    "text": "User added phase at position <new-idx>",
    "resolution": "name: '<name>' / goal: '<goal>'"
  }
  ```
- **Remove `<idx>`**: remove the entry and renumber `idx`. Any other phase's `dependsOn`/`needs` that referenced the removed phase's `id`/`creates` becomes a candidate orphan, surfaced by the next coverage check. If removal would reduce the array to **zero** phases, reject the selection — present an error and require the user to Add at least one phase before Approve is offered again. If removal reduces the array to exactly 1 phase, do not error — continue the loop; Step 5 handles the collapse. Record:
  ```json
  {
    "anchor": "phase:edit:<idx>",
    "source": "phaseGate",
    "text": "User removed phase <idx>",
    "resolution": "removed: '<name>'"
  }
  ```

Loop until the user selects **Approve** and the coverage check passes with zero orphans.

### Step 4: Coverage Check (Hard Block)

Before Approve can be accepted, verify that every accumulated session decision or requirement is covered by the current `phases` array.

**Session requirements set:** every distinct requirement or decision the user has stated so far this session — the per-topic-category answers gathered across Phase 2 rounds (Purpose, Users, Constraints, Success, Edge Cases, Existing Patterns, Approach, and Aesthetic Direction/Differentiation when Phase 1.7 detected UI features), the Phase 3 approach resolution (if it ran), and any explicit Key Decision already accumulated in working memory. **Foundation answers are EXEMPT** from this set and from the orphan hard-block below: stack, architecture, folder-convention, lint/format, and language decisions captured when Phase 1.8 detected greenfield structural signals describe the repository itself, not a slice of feature work, so they never belong in any phase's `goal`, `successCriteria`, `creates`, `needs`, or `areas` fields — Foundation answers are therefore never checked for orphans in this step.

For each item in the session requirements set, check whether it is referenced — verbatim or as a clear restatement — in some phase's `goal`, `successCriteria`, `creates`, `needs`, or `areas` fields, across the **whole current `phases` array**. An item with no match in any phase is an **orphan**.

- **Zero orphans:** the check passes; Approve proceeds (Step 3).
- **One or more orphans:** list each orphan to the user by its source (e.g., "Constraints: rate limiting on the public API") and block Approve — the option is rejected and the gate is re-presented (Step 3) until the user resolves every orphan via Add, Rename, or Merge.

This is a **hard block**, stricter than the advisory-only `outlineWarnings` pattern in `commands/plan.md` Phase 3b/3c (which surfaces warnings but never rejects Approve).

**Numeric criteria carry the command that produced them.** Run this as part of
the same check, under the same hard block — it is not a second gate. For every
`successCriteria` string in the current `phases` array that states a number (a
count, a byte size, a percentage, a duration), the criterion is not acceptable
until the number is backed by the command that produced it, recorded in the
criterion's own ` ```measure ` block per
`${CLAUDE_PLUGIN_ROOT}/commands/references/sanitization.md` §
*Measure-Block Execution Allowlist*:

```measure
$ grep -rlc '^---$' commands/ | wc -l
31
```

- **Backed** — the number matches the block's recorded output. The criterion
  passes; nothing is asked.
- **Unbacked** — ask the user for the command, once, in the same AskUserQuestion
  turn that lists orphans, and offer a third answer beside supplying it: restate
  the criterion without the number. A criterion the user cannot measure is
  observable prose, which is what `scope-contexts.md` asked for in the first
  place. Approve stays unavailable until every numeric criterion is either
  backed or restated.

This exists because of a concrete failure, not a hypothetical: a phase criterion
asserted that **35** preambles would stop existing when only **31** were ever
convertible, no step in the pipeline compared the two, the roadmap carried the
wrong target into planning, and a human found it by re-counting at the end. The
command was cheap; nobody was asked for it.

**Agent mode:** when `INTERACTIVE_MODE=agent` this check does not prompt — the
Non-Interactive Fast Path skips Step 4 entirely. Each unbacked numeric criterion
is instead written through to the `phases:` frontmatter with the number marked
`UNVERIFIED` inline, so `/aimi:plan` inherits the doubt rather than a figure
that looks checked.

### Step 5: Collapse Rule

Once Approve is accepted with zero orphans, check the final phase count:

- **2 or more phases:** continue to Step 6 — the `phases:` frontmatter is emitted.
- **Exactly 1 phase** (only reachable when a Merge or Remove edit reduced the original ≥2-phase proposal down to one): omit the `phases:` frontmatter key **entirely** — never emit it as a single-entry list. The rest of the document is written exactly as it would be if Phase 3.5 had never run (as in the 0/1 scope-context skip in Step 1). This collapse is silent to the document body — no note, no warning, no mention that a roadmap was considered and dropped.

### Step 6: Hand Off to Phase 4

Pass the final approved `phases` array (2 or more entries) to Phase 4, which sanitizes and emits it as the `phases:` frontmatter key — see "phases frontmatter rules" under Phase 4 below.
