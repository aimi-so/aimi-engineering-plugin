# Plan: Phase 1.7: Research File Ingestion

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.

## Phase 1.7: Research File Ingestion

**Trigger:** Only when `researchDepth` is `quick`, `standard`, or `deep`. For `skip` or unset, this phase is a no-op — proceed directly to Phase 2 with no change to Phase 1.6 output.

**Purpose:** Read the full on-disk content of every research file listed in `metadata.researchPaths` so that Pass 2 sub-agent acceptance-criteria authoring can draw on complete detail rather than the capped summary returns from Phase 1.6.

**File collection:**

1. Start with every path in `metadata.researchPaths`.
2. Deduplicate against the values in `reusedResearch` (the files Phase 1.6 already reads directly) — any path that appears as a value in the `reusedResearch` map is already in context; skip it.
3. For each remaining path: attempt to read the file. If the file is missing from disk, skip it and emit one warning line naming it — `warning: research file listed in researchPaths not found on disk - skipping: <path>` — then continue with the next path. Do not abort.
4. Apply **no per-file size cap and no aggregate cap** — ingest the full file contents.

**Wrapper format:**

Each successfully read file is wrapped as:

```
<research_file path="<relative-path-from-project-root>">
…sanitized file contents…
</research_file>
```

Light sanitization: replace any literal `</research_file` sequence in the file contents with `&lt;/research_file`, and any literal `<research_file` sequence with `&lt;research_file`. This prevents a file from breaking out of its wrapper tag (analogous to the `prototype_html` escape at the Prototype Context section above).

Collect all successfully wrapped blocks into a variable `researchFileBlocks` (empty string if no files were read). This variable is threaded into Pass 2 sub-agent prompts below.
