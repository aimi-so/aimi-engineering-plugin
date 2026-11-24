# Plan: Phase 3d: Pass 2 Story Expansion, prototype handoff section blocks

> Loaded by `commands/plan.md` when its `Applies when:` condition holds.
>
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

### Per-Entry Prototype Handoff Section Block Preparation

Phase 0 (`### Reuse Brainstorm Prototype Handoff`) loads, confines and wraps the whole kit handoff documents as `prototypeHandoffBlocks`, and Phase 1 researchers still read that whole block. Pass 2 does not broadcast it: the approved outline exists only now, so each outline entry receives the heading sections of the handoff it draws on, as its own `prototypeHandoffSectionBlock`, plus every path of `prototypeHandoffPaths` for on-demand reading. This mirrors the per-entry research slicing in `phase-3d-prep-blocks.md` and uses the same `extract-sections` verb, with `--all-headings` so a level 1 heading and a setext heading are sections too.

**Trigger:** only when `prototypeHandoffPaths` is non-empty. When it is empty, skip this entire step: every entry's `prototypeHandoffSectionBlock` is empty and no path list is rendered.

**Slice from the files, never from the Phase 0 blocks.** Read each file at its `prototypeHandoffPaths` entry (already confined to `.aimi/sources/` by Phase 0). The Phase 0 blocks are capped and wrapped, so a heading cut off by that cap would be lost from the index; the files are the source of truth.

**Step 1 — Index each handoff's headings.** For each file in `prototypeHandoffPaths`, list its heading anchors in document order, as bare heading text (the `#` markers and surrounding whitespace stripped). A heading is any of:
- an ATX heading of any level, level 1 included (`# Title`, `## Section`, ...);
- a setext heading: a non-blank text line underlined by a line made only of `=` (level 1) or only of `-` (level 2). The underline is never a heading of its own.

Never index a line inside a fenced code block (opened by a line starting with three backticks or three tildes) and never a line of a leading YAML front matter block (the block opened by a first line of `---` and closed by the next `---` or `...`, delimiters included). Store the result as `handoffSectionsIndex`, a map of `<file path> → [<bare anchor text>, ...]`.

A file whose index is empty has no heading of any kind. It goes **whole**, as Phase 0 already wrapped it: its `<prototype_handoff>` block from `prototypeHandoffBlocks` is every entry's excerpt of that file, within the 50 KB aggregate cap Phase 0 already applied, and Steps 2 and 3 skip it.

**Step 2 — Select anchors per outline entry.** For each entry in `outline.json`, and for each file in `handoffSectionsIndex` with at least one anchor, compare the entry's `title` + `summary` against the anchor list and select the headings whose text (or, when the text alone is ambiguous, the subject of the section) relates to the entry's subject matter. Favor precision but do not starve the story: when relevance is genuinely unclear, include the heading, because the read-on-demand path in Step 4 covers whatever this selection misses. A file whose headings match nothing for an entry gives that entry no slice of it.

**Sanitize every selected anchor before Step 3 uses it.** Anchors come from an untrusted file's own heading lines, and Step 3 interpolates them into a double-quoted Bash argument passed to `$AIMI_CLI`; `$(...)` and backticks evaluate **before** the CLI runs, so an unsanitized anchor is a command-injection vector. Before an anchor is added to the selection: replace newlines/CRs with spaces, remove every `$` (not only `$(`), remove backtick characters, remove `"` and `\` characters, and truncate to 200 characters. Nothing is dropped after that: a heading that carries one of those characters still yields its section, because `extract-sections` strips the same four characters from the heading before comparing it with the anchor. `&`, `,`, `(`, `)`, `:`, `/`, `-`, `_` and `.` are inert inside a double-quoted Bash argument and MUST be preserved unchanged.

**Step 3 — Slice via `extract-sections`.** For each outline entry, for each file with at least one selected (and sanitized) anchor:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
"$AIMI_CLI" extract-sections "<file path>" --anchors "<newline-joined selected anchors for this file+entry>" --all-headings
```

Anchors are joined with **newlines**, not commas: a heading may itself contain a comma, which a comma delimiter would shred into fragments that match nothing. Newlines cannot occur inside a heading, and the sanitization above already strips them from every anchor.

Re-apply the Phase 0 escaping to **every slice** before wrapping it: replace each literal `</prototype_handoff` with `&lt;/prototype_handoff` and each literal `<prototype_handoff` with `&lt;prototype_handoff`. Then wrap the escaped excerpt exactly as Phase 0 wraps a whole file:

```
<prototype_handoff path="<relative-path-from-project-root>">
…escaped excerpt…
</prototype_handoff>
```

**Step 4 — Cap and assemble.** Concatenate all of an entry's file excerpts (in `handoffSectionsIndex` order) into that entry's `prototypeHandoffSectionBlock`, capping the concatenated slices at **20 KB**; when the concatenation exceeds the cap, truncate to the first 20 KB and append `\n…[truncated; original is intact on disk]`. An entry whose every file yields no selected anchor gets an empty `prototypeHandoffSectionBlock`, a normal, non-error outcome, and `extract-sections` itself skips an anchor with no matching heading without failing, so a miss never aborts this step.

**The path list never depends on the block.** Whether `prototypeHandoffSectionBlock` is populated, whole-file or empty, every expander also receives every path of `prototypeHandoffPaths`, with the instruction to Read the full file when the section excerpt is insufficient (`phase-3d-expander-prompt.md`). The excerpt is a lazy-loading optimization, never a cap on what the expander can see.

`prototypeHandoffSectionBlock` stays inline in each spawn prompt, with its path list, because it differs per outline entry (`phase-3d-context-files.md`).
