# Plan: Phase 0: Prototype Context and Brainstorm Reuse

> Loaded by `commands/plan.md` when its `Applies when:` condition holds. The section below moved here from `plan.md` verbatim.
>
> Artifacts written under `.aimi/` follow the Artifact Language Rule in `${CLAUDE_PLUGIN_ROOT}/commands/references/user-communication.md`.

### Prototype Context

After reading the brainstorm (if one was found), parse it for referenced prototype HTML files and load them into context:

1. **Parse frontmatter** — look for a `prototype:` key; its value is a path string or a YAML list of path strings.
2. **Parse `## Prototypes` / `## Prototype` section** — scan the brainstorm body for a `## Prototypes` or `## Prototype` heading (accept either form); extract any file paths that appear in that section (lines starting with `-` or table cells containing `.html`).
3. **Also parse sidecar tokens JSON** — if the brainstorm directory contains `.aimi/brainstorms/prototypes/<topic-slug>-tokens.json`, read it and stash as `prototypeTokens` (JSON object) for threading alongside HTML blocks.
4. **Deduplicate** the collected paths and assign sequential labels starting at `A`.
5. **For each path** (resolve relative to the brainstorm file's directory):
   - If the file is **missing from disk**: log warning line `prototype <path> missing — brainstorm references stale artifact` and skip.
   - **Validate path is within project root**: resolve the absolute path (accounting for `../` traversal and symlink targets) and verify it starts with `AIMI_ROOT`. If it does not, log warning line `prototype <path> rejected — path outside project root` and skip — do not abort plan for a bad path.
   - Otherwise: read the file verbatim and sanitize: replace any literal `</prototype_html` or `<prototype_html` sequences in the file contents with their HTML-entity forms (`&lt;/prototype_html` and `&lt;prototype_html`) so a malicious or unlucky variant cannot break out of the wrapper tag. Then wrap as:
     ```
     <prototype_html label="<letter>" path="<relative-path>">
     …sanitized file contents…
     </prototype_html>
     ```
6. **Aggregate size cap — the aggregate prototype drop cap:** after loading, measure the total byte size of all wrapped blocks. If the total exceeds **200 KB**, drop blocks in reverse label order (Z → A) until the aggregate fits under the cap. The aggregate prototype drop cap **removes whole wrapped blocks and never truncates one** — a block that does not fit is gone in its entirety, so a prototype that survives this step is present in full and one that does not is absent altogether, with no partial block left behind to suggest otherwise. Log one warning line per removed block: `prototype <path> removed entirely — aggregate prototype drop cap of 200KB exceeded`. Alongside that warning line — never in place of it — append one record per removed block to a working-memory list `prototypeDropped`, each entry the object `{path, reason, bytes}`: `path` is the same `AIMI_ROOT`-relative path the warning line names, `reason` is the literal string `aggregate-cap`, and `bytes` is that block's wrapped byte size **as already measured for the aggregate above** — reuse the number that made the drop decision rather than measuring a second time, so the record can never disagree with the cap that produced it. The warning and the record are owed to different readers and neither substitutes for the other: the warning reaches an operator watching this run, the record reaches whoever opens the tasks.json weeks later, by which time the chat log is gone.
7. Collect all successfully loaded blocks into a variable `prototypeBlocks` (empty string if none loaded). This variable, together with `prototypeTokens`, is threaded into Phase 1 and Pass 2 sub-agent prompts below. Also collect the resolved absolute paths of every successfully loaded prototype HTML file (those not dropped by the size cap and not missing on disk) into a variable `resolvedPrototypePaths` (empty list if none); append the tokens-sidecar JSON path (`.aimi/brainstorms/prototypes/<topic-slug>-tokens.json`) to `resolvedPrototypePaths` when `prototypeTokens` loaded successfully. `prototypeDropped` from step 6 is this list's complement, and the two disagree by design: `resolvedPrototypePaths` deliberately excludes every block the aggregate prototype drop cap removed, which is exactly why the `metadata.prototypePaths` derived from it looks complete for a run that dropped something — only the pair says what the planner actually read. A prototype a later `oqDecisions[]` entry changes something of is never regenerated; Phase 4 records it in `metadata.prototypeSuperseded`.

### Reuse Brainstorm Research

After reading the brainstorm (if one was found), parse its YAML frontmatter for a `researchPaths` key:

1. **Parse `researchPaths`** from the brainstorm frontmatter — the value is a YAML list of path strings (relative to `AIMI_ROOT`). If the key is absent (legacy brainstorm), skip this entire sub-step and leave `reusedResearch` unset (no error).
2. **Validate each path**:
   - Resolve the absolute path by joining `AIMI_ROOT` + the listed path.
   - Verify the file exists on disk.
   - Check mtime: the file must have been written within the last **14 days**. Files older than 14 days are treated as stale and excluded from reuse.
3. **Classify valid paths by filename suffix** into the `reusedResearch` flat-object map `{kind: path}`. Use the first valid match per kind; emit only non-null keys; omit the key entirely when no path for that kind is found:
   - Path ending with `-codebase.md` → `reusedResearch.codebase`
   - Path ending with `-best-practices.md` → `reusedResearch["best-practices"]`
   - Path ending with `-framework-docs.md` → `reusedResearch["framework-docs"]` (informational only — Phase 1.5b still applies its normal heuristic gate)
   - Path ending with `-learnings.md` → `reusedResearch.learnings`
   - Paths with other suffixes (e.g., `-design-bundle.md`) → ignore
4. **Log findings** (one line per classification):
   - Valid reuse: `Research reuse: [kind] → [path] (mtime OK)`
   - Stale skip: `Research reuse: [path] skipped — older than 14 days`
   - Missing skip: `Research reuse: [path] skipped — file not found`
5. **Collect `reusedPaths`**: a list of all path values in `reusedResearch` (i.e., the successfully classified, non-skipped paths). This list is used in Phase 4 metadata and Phase 5 report.

If no brainstorm was found, or the brainstorm has no `researchPaths` key, `reusedResearch` remains unset and behaviour is unchanged (backward-compatible with legacy brainstorms).

### Reuse Brainstorm Foundation Proposal

After reading the brainstorm (if one was found), parse its YAML frontmatter for a `foundationProposalPath` key — gated on the **same condition** as `### Reuse Brainstorm Research` above (a brainstorm must have been loaded this session):

1. **Parse `foundationProposalPath`** from the brainstorm frontmatter — the value is a single path string (relative to `AIMI_ROOT`, no leading `./` or `..` components, per the brainstorm-side contract in `commands/brainstorm.md`'s "foundationProposalPath frontmatter rules"). If no brainstorm was loaded this session, or the loaded brainstorm's frontmatter has no `foundationProposalPath` key, skip this entire subsection with no error and leave the working-memory `foundationProposalPath` variable unset — mirroring exactly how step 1 above treats a missing `researchPaths` key.
2. **Resolve and confine the path.** Join `AIMI_ROOT` + the frontmatter value (the value is relative to `AIMI_ROOT` per step 1 — never resolve it relative to the brainstorm file's directory, which is `### Prototype Context`'s base and would be wrong here), then resolve the joined path with `realpath` — accounting for `../` traversal and symlink targets — and verify the **resolved** result (a) starts with `AIMI_ROOT/.aimi/research/` **and** (b) ends with `-foundation.md`. This is the **STRICT** confinement regime (`realpath`-based, like `### Prototype Context` and `### Bundle Prototype Auto-Generation`), narrowed further to the only directory and filename shape a legitimate foundation proposal can have — not the weaker join-and-check-exists regime `researchPaths` uses in step 2 above, and not a bare `AIMI_ROOT` prefix check (which would admit any readable in-repo file, e.g. `.git/config`, into Phase 3d's prompt inlining).
   - **Why STRICT here, not the `researchPaths` regime:** the Phase 1 review of this same feature (commit `9e7208d`) already hardened this exact `foundationProposalPath` variable once — pinning it to the orchestrator-supplied deterministic `outputPath` instead of the `aimi-foundation-architect` agent's returned `research_file` string, because trusting an agent-controlled value there could redirect the variable to an arbitrary readable file that Phase 3d then inlines into every sub-agent prompt. A brainstorm-authored frontmatter value is a **different input vector** into that same variable — validating it the weaker `researchPaths` way (join-and-check-exists, no traversal/symlink accounting) would reopen a materially similar gap, so this subsection applies the stricter regime, narrowed to the foundation-artifact directory and suffix.
   - **On confinement failure** (either check): emit exactly one warning line — `foundationProposalPath <path> rejected — must resolve inside .aimi/research/ and end with -foundation.md` — treat the pointer as absent (working-memory `foundationProposalPath` remains unset), and continue without aborting the plan, mirroring `### Prototype Context`'s non-fatal treatment.
3. **Validate existence and freshness** (only when confinement passed): verify the file exists on disk and check its mtime is within the last **14 days** — the same threshold `### Reuse Brainstorm Research` above uses. A missing or stale file simply disables reuse (no error):
   - Missing file: log `foundationProposalPath reuse: <path> skipped — file not found` and leave `foundationProposalPath` unset.
   - Stale file (mtime older than 14 days): log `foundationProposalPath reuse: <path> skipped — older than 14 days` and leave `foundationProposalPath` unset.
4. **When confinement, existence, and freshness all pass**, populate the working-memory `foundationProposalPath` variable with the validated path and log `foundationProposalPath reuse: <path> (mtime OK)`. This is the **same** working-memory variable that Phase 1.9 below reads, confirms, or resets — not a parallel variable — so a value populated here already counts toward satisfying Phase 1.9 Step 1 condition (d) before that gate runs (see below). **Ownership:** this subsection sets **only** `foundationProposalPath`; `foundationAccepted` is written exclusively by Phase 1.9 (its reuse branch or its gate steps) and is never set here.

If no brainstorm was found, or the loaded brainstorm has no `foundationProposalPath` key, this subsection is a no-op and Phase 1.9's fire-condition check behaves exactly as it did before this feature.

### Reuse Brainstorm Design Bundle

After reading the brainstorm (if one was found), parse its YAML frontmatter for a `designBundle:` object — gated on the **same condition** as `### Reuse Brainstorm Research` above (a brainstorm must have been loaded this session). The object has the five fields `commands/brainstorm.md`'s "designBundle frontmatter rules" emit: `root`, `readme`, `chats`, `businessSpec`, `designSpec` (the last two are always present and `null` when absent).

1. **Parse `designBundle.root`** — a path to the bundle directory, relative to `AIMI_ROOT` (an absolute path is kept as written). If no brainstorm was loaded, or its frontmatter has no `designBundle:` key (legacy brainstorm, or one with no bundle), skip this entire subsection with no error and leave the working-memory `brainstormBundleRoot` variable unset.
2. **Store it** in working memory as `brainstormBundleRoot` (empty until a `designBundle.root` is parsed):

   ```bash
   brainstormBundleRoot=""   # replaced by the parsed designBundle.root when present
   ```

   and log `designBundle reuse: <root>`. This subsection reads and stores only; it resolves, confines and imports nothing — `### Design Bundle Detection` below applies the same `realpath` confinement to it that it applies to a typed `--bundle`.
3. **Precedence:** `brainstormBundleRoot` feeds `BUNDLE_ARG` in `### Design Bundle Detection` only when no `--bundle <path>` token was typed on the command line. An explicit flag always wins over frontmatter, the same precedence explicit research paths take over `researchPaths`.

If the brainstorm has no `designBundle:` key, behaviour is unchanged (backward-compatible with legacy brainstorms).
