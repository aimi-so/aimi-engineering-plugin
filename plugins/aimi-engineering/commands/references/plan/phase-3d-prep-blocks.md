# Plan: Phase 3d: Pass 2 Story Expansion, block preparation

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.

## Phase 3d: Pass 2 — Parallel Story Expansion

Dispatch one Task sub-agent per approved outline entry, wave by wave (see Wave Dispatch and Producer Slice Block Preparation at the end of this file). Each sub-agent writes a single-story staging file. Collect each wave's results before the next wave starts.

### Staging File Naming

Each sub-agent writes to:
```
<RUN_DIR>/<idx>-<slug>.json
```

Where `<idx>` is the zero-padded outline index (`01`, `02`, …) and `<slug>` is the story title sanitized to lowercase-hyphenated form (spaces → hyphens, strip non-alphanumeric, truncate to 40 chars).

### Foundation Proposal Block Preparation (one block per accepted root)

Phase 1.9 records one accepted proposal **per foundation root** — `foundationProposalPathByRoot`, its Working-Memory Shape — holding 0, 1, or N entries. Prepare one wrapped block per key in that map and route each one only to the sub-agents that belong to that repository.

For **each** key in `foundationProposalPathByRoot`, read that root's own proposal file **once** for this Phase 3d invocation (not once per sub-agent — reuse the same read across every spawn this run; N accepted roots means N reads for the whole run, never N per spawn). Escape any literal `</foundation_proposal` or `<foundation_proposal` sequences in its contents to their HTML-entity forms (`&lt;/foundation_proposal`, `&lt;foundation_proposal`), mirroring the `research_file`/`prototype_html` wrapper-escape pattern used elsewhere in this command. Cap the wrapped content at **50 KB**; when the file exceeds the cap, truncate to the first 50 KB and append `\n…[truncated; original is intact on disk]`. **The 50 KB cap is per proposal and never pooled across the run** — N proposals get N independent budgets, so a small proposal in one repository is never truncated because a large one exists in a sibling. With one accepted root this is textually the same single 50 KB cap it has always been.

Store the result as `foundationProposalBlockByRoot`: a map from the same routing key `foundationRoots` uses (`"."` for the single-repo/`AIMI_ROOT` case, otherwise the key `foundationRoots` assigned that child repository) to `{path, block}` — `path` being that root's `foundationProposalPathByRoot` value and `block` its escaped, capped content. When `foundationProposalPathByRoot` is empty — the gate never fired, or every root declined — `foundationProposalBlockByRoot` is empty too, which is byte-for-byte today's `foundationAccepted: false` outcome: no sub-agent receives a `<foundation_proposal>` block at all.

**Per-entry proposal routing — which block a given spawn receives.** Before rendering the template below for outline entry `<idx>`, resolve that entry's own `entryProject`, the routing key of the repository it belongs to:

- **A foundation entry** (its own `foundationEntry` field is `true`): its own `foundationProject` field, as Phase 3b's Foundation-first rule set it. Authoritative — never re-derived and never inferred.
- **Every other entry**: the routing key of the repository this entry's own work lands in — the same value the spawn is told to write into its story's `project` field below, and the same key convention `foundationRoots` uses. When `foundationRoots` has exactly one entry that key is `"."` for every entry, which is the single-repo case unchanged.

Render the template's proposal block from `foundationProposalBlockByRoot[entryProject]` — **that** entry's own `{path, block}` pair, never a sibling repository's. **When `foundationProposalBlockByRoot` has no entry for `entryProject`, omit the `<foundation_proposal>` block entirely for that sub-agent:** the story simply receives no foundation context, and no other project's block is ever substituted in its place. That covers the mixed multi-repo run — one repository's gate resolved Accept while a sibling's resolved Skip — as well as, unchanged, the single-repo run where the gate never fired.

**Reading the template's `foundationAccepted` guards below.** `foundationAccepted` is Phase 1.9's collapsed scalar, deliberately left unset when `foundationRoots` holds two or more entries. Wherever the template below still reads `[If foundationAccepted (Phase 1.9)]`, read it as **"at least one root accepted this run"** — i.e. `foundationProposalBlockByRoot` is non-empty. On a single-repo run the collapse makes the two conditions identical, which is why those guards are left worded as they are.

### Per-Entry Section-Scoped Research Block Preparation

Replaces the full-corpus `researchFileBlocks` broadcast (previously inlined verbatim into every sub-agent spawn — see the old `[If researchFileBlocks is non-empty]` block this template used to carry) with a per-outline-entry slice, so token cost scales with what each entry actually needs rather than with the size of the entire research corpus. Wires in the `extract-sections` verb (`scripts/aimi-cli.sh` `cmd_extract_sections`, delivered by story outline:01) as the slicing mechanism. Phase 1.7's on-disk ingestion (above) is unchanged and remains the fallback source this step slices from — `researchFileBlocks` itself is untouched and keeps feeding Phase 3b (outline generation) only; only the per-expander broadcast below is replaced.

The Phase 3d.5 auditor reads the research files from disk, by the paths its prompt lists (`phase-3d5-audit-spawn.md`); no block from this step reaches it.

**Trigger:** only when `allResearchPaths` (defined at the end of Phase 1.6 above) is non-empty. When it is empty, skip this entire step — every sub-agent's section-scoped block is simply empty, the same outcome an empty `researchFileBlocks` produced before.

**Step 1 — Build the sections index.** For each file in `allResearchPaths`, determine its available `## `/`### `/`#### ` (h2-h4) heading anchors (bare heading text, `#` markers and surrounding whitespace stripped):
- **Freshly spawned this run**, with its researcher's pointer-block return still in working memory from Phase 1 / Phase 1.5b: use that return's `sections` list directly — it already enumerates every h2-h4 anchor in document order (`agents/research/aimi-codebase-researcher.md:117-130`). Strip each entry's leading `#` markdown prefix (any depth) before use — the pointer block carries it (e.g. `"## Architecture & Structure"`), but `extract-sections --anchors` matches against bare heading text.
- **Reused, or the pointer block is no longer in context** (Phase 1.6's "Reused research files" path has no Task summary to draw on): derive the same list by scanning the file's own `## ` to `#### ` heading lines directly — structurally identical output to what the pointer's `sections` field would contain, since that field is defined as exactly this enumeration.

Store the result as `researchSectionsIndex`, a map of `<file path> → [<bare anchor text>, ...]`.

**Step 2 — Select anchors per outline entry.** For each entry in `outline.json`, and for each file in `researchSectionsIndex`, compare the entry's `title` + `summary` against that file's anchor list and select the anchors whose heading text (or, when the heading text alone is ambiguous, the section's known subject from the Phase 1.6 consolidated summary) relates to the entry's subject matter. Favor precision but do not starve the story: when relevance is genuinely unclear for a candidate anchor, include it — the read-on-demand fallback (Step 4 below) exists precisely to cover whatever this heuristic selection misses, so mild over-inclusion here is a soft token cost, not a correctness risk. Typical selections run 2–5 anchors per file per entry; there is no hard cap.

**Sanitize every selected anchor before Step 3 uses it.** Anchors come from untrusted sources — the researcher agent's returned `sections` list, or a direct scan of the research file's own heading lines — and Step 3 interpolates them into a double-quoted Bash argument passed to `$AIMI_CLI`; `$(...)` and backticks evaluate **before** the CLI runs, so an unsanitized anchor is a command-injection vector. Before an anchor is added to the selection: replace newlines/CRs with spaces, remove any `$(` sequences, remove backtick characters, remove `"` and `\` characters, and truncate to 200 characters (same sanitization regime this file already applies at ~line 1001, ~1057, ~1083, ~1137, ~1245). **After sanitization, DROP any anchor that still contains `$`, a backtick, `"`, or `\`** — do not pass it to Step 3 at all, and print one line per drop, `dropped anchor: <anchor> (<file path>)`, so the loss is visible. A dropped anchor is simply not requested from `extract-sections`; the entry degrades to the Step 4 read-on-demand path for that heading — this never aborts the entry or the run. Note that `&`, `,`, `(`, `)`, `:`, `/`, `-`, `_`, and `.` are inert inside a double-quoted Bash argument and MUST be preserved unchanged — real headings routinely contain them (e.g. `## Testing, Linting, and CI`, `## API (v2)`).

**Step 3 — Slice via `extract-sections`.** For each outline entry, for each file with ≥1 selected (and sanitized) anchor:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
"$AIMI_CLI" extract-sections "<file path>" --anchors "<newline-joined selected anchors for this file+entry>"
```

Anchors are joined with **newlines**, not commas — a heading may itself contain a comma (e.g. `## Testing, Linting, and CI`), which a comma delimiter would shred into non-matching fragments and silently return nothing for. Newlines cannot occur inside a heading, and the sanitization step above already strips any newline out of each anchor, so a newline delimiter is unambiguous by construction.

Wrap the returned excerpt exactly as Phase 1.7 wraps a full file — same tag, same escaping:

```
<research_file path="<relative-path-from-project-root>">
…sanitized excerpt…
</research_file>
```

Apply the identical sanitization Phase 1.7 already applies (escape any literal `</research_file` sequence to `&lt;/research_file`, and any literal `<research_file` sequence to `&lt;research_file`, before wrapping — the same rule at plan.md:1038, applied here to a slice instead of the whole file). Concatenate all of an entry's file excerpts (in `researchSectionsIndex` order) into that entry's `researchSectionBlock` variable, capping the concatenated result at **20 KB**; when the concatenation exceeds the cap, truncate to the first 20 KB and append `\n…[truncated; original is intact on disk]`. An entry whose every file yields zero selected anchors gets an empty `researchSectionBlock` — a normal, non-error outcome (the entry's subject matter may simply not be covered by any research file); Step 4's read-on-demand path remains available regardless. `extract-sections` itself is silent-skip on a miss (an anchor with no matching heading is dropped, not an error — see the CLI helper's own doc comment above `cmd_extract_sections`), so a zero-anchor result never aborts this step.

**Step 4 — Read-on-demand fallback.** Regardless of whether `researchSectionBlock` is empty or populated, every sub-agent also receives the full `allResearchPaths` list plus an explicit instruction to Read any of those files in full when the section excerpt is insufficient for a needed acceptance-criterion detail. This is the "no hard information loss" guarantee required of this design: the excerpt is a lazy-loading optimization, never a hard cap on what the expander can see — Phase 1.7's on-disk ingestion remains the durable fallback source, exactly as before this change.

### Wave Dispatch and Producer Slice Block Preparation

An outline entry may consume a name another entry produces (the `produces`/`consumes` contract Phase 3b validated). The expander of the consumer is dispatched after the producer's story is staged and validated, and is handed a slice of that story, so a sibling reference names a real file or symbol instead of a guess.

**Step 1 — Get the waves and the producer-to-consumer pairs from the verb, never from prose.** Run it on the approved `outline.json`:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI validate-outline --outline "$RUN_DIR/outline.json"
```

On exit 0 keep `waves` (the same list Phase 3b stored as `outlineWaves`) and `edges` (`{from, to, name}`, `from` the producer). Any other exit is an invalid outline Phase 3c should not have approved: stop and surface the verb's message. Never re-derive either list yourself. A name carrying the `ext:` marker has no producer in the plan and no edge.

**Step 2 — Dispatch wave by wave.** Dispatch the expanders of `waves[0]`, then `waves[1]`, in the order the verb printed them, at most 8 expanders at once inside a wave; the rest of that wave start as slots free (specFlow:ImportantQ17). A wave starts only after every earlier wave has passed Schema Validation and Retry, so every producer's staged file is on disk and validated when its consumer is spawned. An outline whose entries all declare empty contracts is one wave with no edges: it renders no `<producer_story>` block. Every batch of expander spawns, a wave or a retry, runs inside the Working Tree Guard (its own phase file, `phase-3d-tree-guard.md`).

**Step 3 — Build `producerStoryBlock` for each entry**, immediately before spawning it. The producers are the distinct `from` of the edges whose `to` is this entry's idx. For each producer, in ascending idx, read its validated staging file `<RUN_DIR>/<idx>-*.json` (a Read is not blocked by the staging guard, which denies only Edit and Write) and emit:

```
<producer_story idx="NN">
title: <title>
produces: <the producer's outline `produces` names, comma-joined>
files: <implementation.files paths, comma-joined>
</producer_story>
```

Take only structured fields: the idx, the title, the contract names and the `implementation.files` paths that are relative and free of `..` (drop any other path). Never copy `description`, `acceptanceCriteria`, `approach`, `tasks`, `notes` or any other free story text into the slice; that is what keeps the DATA boundary structural. Escape literal `</producer_story` and `<producer_story` sequences inside the emitted text to `&lt;/producer_story` and `&lt;producer_story`. Cap each producer's block at **8 KB per producer** and the concatenation at **24 KB per consumer**; past a cap, truncate and append `\n…[truncated; original is intact on disk]`. An entry with no producer gets an empty `producerStoryBlock`, a normal outcome.

**A producer that failed permanently never reaches this step:** its dependent closure is held back, see Held-Back Dependents of a Failed Producer in the validate-and-retry file.
