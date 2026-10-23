# Plan: Phase 3a and 3b: Run Setup and Pass 1 Outline Generation

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.
>
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

## Phase 3a: Run Setup

### Create Run ID and Staging Directory

Generate the per-run staging directory path from `topicSlug` and `RUN_TS` (both set during Phase 1):

```bash
RUN_DIR=".aimi/.tasks-staging/${topicSlug}-${RUN_TS}"
mkdir -p "$RUN_DIR"
```

Store `RUN_DIR` for use in all subsequent Phase 3 steps and in Phase 3e.

Also derive the final output path for `story-merge --output`:

**When `ROADMAP_MODE=true`:** the output path is phase-scoped, not date-scoped, and lives under the feature's roadmap directory rather than the flat `.aimi/tasks/` root — this is what makes rolling-wave expansion write into the phase's own container instead of a new top-level file:

```bash
TASKS_PATH=".aimi/tasks/${featureSlug}/${PHASE_DIR}/${featureSlug}-phase-${SELECTED_PHASE_ID}-tasks.json"
mkdir -p "$AIMI_ROOT/.aimi/tasks/${featureSlug}/${PHASE_DIR}"
```

The `*-tasks.json` basename convention is preserved — only the directory and the date-vs-phase discriminator in the filename differ from the flat form. `--split full-stack` composes on top of this: story-merge derives every split output path from whatever `--output` base it is given (directory plus basename) — `-frontend-tasks.json`/`-backend-tasks.json` on the SIDE axis, one `-<project-slug>-tasks.json` per project on the PROJECT axis. Which set it produced is reported back on stdout (see Phase 3e's Return Contract); this command never re-derives those names itself. The one piece of special-casing needed is basename shape: this `--output` base already ends in `-tasks` (`${featureSlug}-phase-${SELECTED_PHASE_ID}-tasks.json`), so appending directly would double that segment (`...-tasks-frontend-tasks.json`, matching the flat/legacy shape). Phase 3e passes story-merge's `--phase-aware` flag whenever `ROADMAP_MODE=true` and `implementationScope == "full-stack"` so it strips the trailing `-tasks` once first, producing single-`tasks`-segment split basenames (`${featureSlug}-phase-${SELECTED_PHASE_ID}-frontend-tasks.json` / `-backend-tasks.json`) instead — see Phase 3e below.

**When `ROADMAP_MODE=false` (unchanged):**

```bash
TASKS_PATH=".aimi/tasks/YYYY-MM-DD-${topicSlug}-tasks.json"
```

When `implementationScope` is set, the split path is derived by story-merge (see Phase 3e). Store `TASKS_PATH` for Phase 3e and Phase 4.5.

## Phase 3b: Pass 1 — Outline Generation

Using consolidated research (Phase 1.6), research file blocks (Phase 1.7), spec-flow output (Phase 2), resolved OQs (`oqDecisions[]`), and any `prototypeBlocks` and `researchFileBlocks` in context, generate a numbered outline of story titles and one-line summaries.

**Outline format** — produce a JSON array and persist it immediately:

Each entry:
```json
{
  "idx": "01",
  "title": "Story title (≤ 200 chars, imperative)",
  "summary": "One-line description of what this story delivers (≤ 120 chars)",
  "produces": ["sym:parseConfig", "path:src/config.ts"],
  "consumes": ["ext:sym:Logger"],
  "foundationEntry": false,
  "foundationMode": "greenfield",
  "foundationProject": null
}
```

Rules for outline authoring:
- Each entry represents one vertical slice: a single user-observable outcome bundled across all layers needed to deliver it.
- Use the same dependency reasoning as the final decomposition — entries that unlock others come first.
- `idx` is zero-padded, 1-based, matching position in the array (`"01"`, `"02"`, …).
- Do not assign `US-NNN` IDs yet — IDs are assigned by `story-merge` after approval.
- Target 3–15 entries. Entries beyond 15 are allowed but surface a warning at the outline gate.
- `produces` and `consumes` are arrays of contract tokens, `[]` when an entry neither introduces nor relies on a named thing. Author them from the research: `produces` names what this entry introduces, `consumes` names what another entry introduces. A token is `[ext:]<kind>:<name>` with kind `sym:`, `path:`, `cli:` or `http:`. A name holds no whitespace, except `http:`, which is exactly `METHOD /path` (one space). No `..` segment, no leading `/`, no shell metacharacters. `ext:` goes only in `consumes` and marks a name that already exists in the repository, so it needs no producer. Errors: a name produced by two entries, a consumed name nobody produces (and not `ext:`), an entry consuming its own product, `ext:` on a name some entry produces, and a cycle.
- `foundationEntry` is `false` on every entry except the ones designated by the Foundation-first rule below (present only where Phase 1.9 recorded an accepted verdict — see its Working-Memory Shape) — it tells Phase 3d's sub-agent which entries are foundation stories themselves versus consumers of an accepted proposal. **This field is the only way to identify a foundation entry:** every downstream reader tests it on the entry itself, never the entry's position.
- `foundationMode` is `"greenfield"` (the default) on every entry except the ones designated by the Foundation-first rule below, each of which instead carries whatever value Phase 1.9's gate resolved **for its own repository** (`foundationModeByRoot[<root>]` — `"greenfield"` or `"brownfield"`) — it tells Phase 3d's sub-agent, and in turn `aimi-story-expander`, whether that foundation entry should scaffold a fresh skeleton or document an existing repo in place.
- `foundationProject` is `null` (the default) on every entry except the ones designated by the Foundation-first rule below, each of which carries **its own** repository's routing key — that root's key in Phase 1.9's `foundationRoots` map: `"."` for the single-repo/`AIMI_ROOT` case, otherwise that child repository's relative path from `AIMI_ROOT` (no leading `./`, no `..` components), reusing the same `.project`/`metadata.splitGroup.project` routing-key convention. It tells Phase 3c's carve-out and Phase 3d's sub-agent which repository a foundation entry belongs to. A non-foundation entry keeps `null`: this is a foundation-entry marker, **not** a general per-story project router.

**Foundation-first rule (Phase 1.9):** let `M` be the number of roots whose `foundationAcceptedByRoot[<root>]` entry is `true` (Phase 1.9's Working-Memory Shape). This is a single rule for every layout — a single-repo run is simply its `M == 1` case, never a separately maintained path.

**When `M` is 0** — the gate never fired, every root declined, or a single-repo run whose one `foundationAccepted` verdict is `false` — this whole rule is a no-op: generate the outline unmodified, exactly as today.

**When `M >= 1`:** the first `M` outline entries (`idx` `"01"` … `"0M"`) MUST be exactly those `M` repositories' own foundation stories, one entry per accepted root, in `foundationRoots` order — Phase 1.9's own iteration order, itself derived from the Phase 1 Auto-Scan for Git Repos discovery order; do **not** invent a new ordering rule. This overrides normal outline-authoring order. On each of those entries set:

- `foundationEntry: true` (every other entry keeps `false`);
- `foundationMode` to that root's own `foundationModeByRoot[<root>]` value, `"greenfield"` or `"brownfield"` (every other entry keeps the `"greenfield"` default);
- `foundationProject` to that root's own `foundationRoots` key (every other entry keeps `null`).

Derive each such entry's `title` and `summary` from **its own** repository's proposal file at `foundationProposalPathByRoot[<root>]` — never from another root's — using the sections **both** artifact kinds are guaranteed to carry: condense the summary from `## Folder Layout` and `## CLAUDE.md Draft` (a brainstorm-authored artifact — see `commands/brainstorm.md` Phase 3.7 — carries exactly the 4 shared sections and deliberately has no `## Stack`/`## Layering`); when the artifact additionally carries `## Stack` and `## Layering` (architect-authored, 9-section contract), prefer those two for a richer title/summary (e.g. "Establish <stack> architecture foundation"). When `M >= 2`, additionally name each entry's own `foundationProject` in its title so the `M` foundation entries are distinguishable from one another; when `M` is 1 the title and summary are derived exactly as they are today, with no repository qualifier.

Every non-foundation entry is numbered starting at `"0(M+1)"` — `"02"` when `M` is 1, exactly as today. Because nothing precedes the foundation block in the outline, normal dependency reasoning already yields `dependsOn: []` for each of its entries when Phase 3d expands them — no extra instruction is needed there.

**If one accepted root's `foundationProposalPathByRoot[<root>]` is unreadable at this point:** drop **only that root** from the foundation set — treat it exactly as if its own Phase 1.9 gate had resolved to Skip. Set `foundationAcceptedByRoot[<root>] = false` for the rest of this run (and, when `foundationRoots` has exactly one entry, the collapsed `foundationAccepted` scalar with it, which is today's behavior verbatim) so every downstream consumer of that root's verdict treats that repository as declined; decrement `M`; and emit exactly one warning line, carrying the same ` [<root>]` discriminator convention Phase 1.9's own lines use — absent for the `.` root, present for every other:
```
[plan] foundation entry skipped: proposal file unreadable (<path>)
```
— or, for a non-`.` root:
```
[plan] foundation entry skipped [<root>]: proposal file unreadable (<path>)
```
Then continue deriving the remaining `M` entries from the roots whose proposals did read — never reset the whole rule, or the whole run, for one bad file. When every accepted root's proposal is unreadable `M` reaches 0 and the rule degrades to the no-op above, generating the outline unmodified exactly as if the gate had never fired (see Error Handling).

Persist the outline immediately after generation:

```bash
# Write outline.json to staging dir
# Content: JSON array of {idx, title, summary, produces, consumes, foundation*} objects
```

Use the Write tool to write the array to `<RUN_DIR>/outline.json`. This file is the checkpoint for Phase 3c; it is also consumed by Phase 3d sub-agents as their ordered work list.

Initialize `outlineEditCount = 0` to track user edits during the gate.

### Phase 3b Outline Validation

After writing `outline.json`, run a non-blocking validator over the entries. Produce an in-memory list `outlineWarnings` (used in Phase 3c). Warnings do NOT block approval and are NOT recorded in `oqDecisions[]`.

**Step 1 — Extract File References from consolidated research.**

Scan the consolidated research string (produced by Phase 1.6) for an `## File References` h2 heading. Collect every bullet line (lines starting with `-` or `*`) that appears directly beneath that heading, stopping at the next h2 (`##`) or end-of-string. Store these lines as `fileRefLines`.

```bash
# Pseudo-code: extract ## File References bullet lines from consolidatedResearch string
# fileRefLines = lines in consolidatedResearch between "## File References" h2 and next "## " heading
# If "## File References" is absent OR fileRefLines is empty → set fileRefsPresent = false
# Otherwise → set fileRefsPresent = true
```

When `fileRefsPresent` is `false`, the file-reference check is **suppressed entirely** — no path-token warnings fire for any entry regardless of content.

**Step 2 — Check each outline entry.**

For each entry in `outline.json` (in order), apply the checks below. Collect **at most one warning string per entry** (stop at the first failing check):

1. **Short-summary check**: if `entry.summary` has fewer than 40 characters, produce:
   ```
   [warn] outline:<idx>: summary too short (<N> chars) — expand to clarify scope.
   ```
   where `<idx>` is the entry's `idx` field and `<N>` is the actual character count. Skip the file-reference check for this entry (already warned).

2. **File-reference check** (only when `fileRefsPresent` is `true` and the entry did **not** trigger the short-summary warning): split the concatenation of `entry.title` and `entry.summary` on whitespace. For each token, test whether it contains `/` **and** does **not** contain `://` (i.e. it is path-like but not a URL). For the **first** such token that does not appear as a substring in any line of `fileRefLines`, produce:
   ```
   [warn] outline:<idx>: path token '<token>' not found in File References — verify coverage.
   ```
   Stop checking further tokens for this entry once one warning is produced.

```bash
# Pseudo-code: outline validation loop
# outlineWarnings=()
# for entry in outline_entries:
#   warn=""
#   if len(entry.summary) < 40:
#     warn="[warn] outline:${entry.idx}: summary too short (${#entry.summary} chars) — expand to clarify scope."
#   elif fileRefsPresent:
#     tokens = split(entry.title + " " + entry.summary, whitespace)
#     for token in tokens:
#       if "/" in token and "://" not in token:
#         matched = false
#         for line in fileRefLines:
#           if token in line: matched=true; break
#         if not matched:
#           warn="[warn] outline:${entry.idx}: path token '${token}' not found in File References — verify coverage."
#           break
#   if warn != "": outlineWarnings.append(warn)
```

**Step 3 — Cap warnings and compute overflow.**

```bash
# Pseudo-code: cap at 10 and compute overflow
# overflow = max(0, len(outlineWarnings) - 10)
# if overflow > 0:
#   outlineWarnings = outlineWarnings[0:10]
#   outlineWarnings.append("[warn] ... and ${overflow} more entries with potential outline gaps.")
```

When `outlineWarnings` is empty after this step, no preamble is rendered at the Phase 3c gate — the gate proceeds identically to the current behavior.

### Phase 3b Outline Contract Check

Run after `outline.json` is written, and again from Phase 3c after every outline rewrite. Unlike the warnings above it blocks approval. Read the exit status and JSON it prints.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
CONTRACT_JSON=$($AIMI_CLI validate-outline --outline "$RUN_DIR/outline.json")
CONTRACT_EXIT=$?
printf '%s\n' "$CONTRACT_EXIT" "$CONTRACT_JSON"
```

- **Exit 0:** keep `waves` as `outlineWaves` and `counts` as `outlineCounts`; `outlineContractErrors` is empty. An outline with every contract empty is one wave.
- **Exit 1 with JSON:** keep `errors[]` (`{code, idx, message}`) as `outlineContractErrors`; `outlineWaves` is empty.
- **Exit 1, nothing on stdout:** a refusal. Keep its stderr line as the only error.

While `outlineContractErrors` is non-empty Phase 3c refuses Approve. In agent mode, repair once: rewrite only the `produces`/`consumes` of the entries the errors name, from the research, re-write `outline.json`, and run the check again. If it still exits non-zero, stop with `[plan] outline contract invalid (non-interactive): <first message>`. An invalid contract is never auto-approved.
