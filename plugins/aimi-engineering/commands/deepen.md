---
name: aimi:deepen
description: Enrich tasks.json stories with research insights
argument-hint: "[path to tasks.json (optional)]"
allowed-tools: Read, Write, Task, Bash(AIMI_CLI=*), Bash($AIMI_CLI:*), Bash(ls:*), Bash(jq:*), Bash(mkdir:*), Bash(date:*)
---

# Aimi Deepen

Enrich tasks.json stories directly with research insights, better acceptance criteria, and story splitting when needed.

## Step 0: Resolve CLI Path and Agent Models

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/cli-path-resolution.md` and follow the **Resolve CLI Path** and **Version Check** sections to set `$AIMI_CLI`. Each layer is a separate Bash call.

If resolution fails, report error and STOP.

**Each Bash tool call is an isolated shell — `$AIMI_CLI` does not persist.** Re-read the cache at the top of every subsequent Bash call that needs `$AIMI_CLI`. See the **Per-Call Resolution** section of `commands/references/cli-path-resolution.md` for the one-liner to prepend.

### Resolve Agent Models

Read and follow the **Resolve Agent Models** section of `commands/references/cli-path-resolution.md` to populate `AGENT_MODELS`. When resolution fails, treat every category as `"inherit"` and continue.

## Step 1: Locate Tasks File

If `$ARGUMENTS` contains a path, use it. Otherwise, auto-discover:

```bash
ls -t .aimi/tasks/*-tasks.json 2>/dev/null | head -1
```

If no tasks file found:
```
No tasks file found. Run `/aimi:plan` to create a task list first.
```
STOP.

Read the tasks file using the Read tool.

## Step 2: Identify Pending Stories

Filter stories where `status == "pending"`.

If no pending stories:
```
All stories are already complete. Nothing to deepen.
```
STOP.

**CRITICAL:** Never modify or split completed stories (`status == "completed"`). Only enrich pending stories.

## Step 2b: Read Research Depth

Read `researchDepth` from the tasks file metadata:

```bash
jq -r '.metadata.researchDepth // "standard"' <tasks-file-path>
```

Store as `$RESEARCH_DEPTH`. This inherits the depth setting from planning without re-specifying it.

## Step 2c: Prepare Research Directory

```bash
mkdir -p .aimi/research
```

## Step 2d: Derive Shared Discriminators

Compute the filename discriminators once per invocation and reuse them for every parallel researcher. This mirrors `brainstorm.md` and `plan.md` so files written by all three commands share one canonical shape:

```
.aimi/research/YYYY-MM-DD-<topic-slug>-<RUN_TS>-<kind>.md
```

```bash
RUN_TS=$(date +%H%M%S)
TOPIC_SLUG=$(jq -r '.metadata.branchName' <tasks-file-path> | sed 's|^[a-z]*/||')
```

Validate `TOPIC_SLUG` against `^[a-z0-9][a-z0-9-]*$`. If it fails validation (empty, missing, or contains unexpected characters), fall back to the static slug `deepen` — never abort the command for a bad slug.

Store both values for use in Step 3.

## Step 2e: Build Coverage Set

Read `metadata.researchPaths` from the tasks file and, if a brainstorm document exists, its `researchPaths` frontmatter key. Merge these into a **coverage set** — a flat list of research file paths that plan or brainstorm has already produced for this feature.

```bash
# From tasks.json metadata
tasks_research_paths=$(jq -r '.metadata.researchPaths[]? // empty' <tasks-file-path>)

# From brainstorm document (when metadata.brainstormPath is set)
brainstorm_path=$(jq -r '.metadata.brainstormPath // empty' <tasks-file-path>)
```

When `brainstorm_path` is non-empty, read the brainstorm file and parse its YAML frontmatter for a `researchPaths:` list. Each entry is a path string relative to `AIMI_ROOT`. Add valid entries to the coverage set.

The merged, deduplicated list of these paths is the **coverage set** for this run. Store it in working memory as `COVERAGE_PATHS`.

**Legacy degrade path:** When `metadata.researchPaths` is absent from the tasks file and no brainstorm document is found (or the brainstorm has no `researchPaths` key), `COVERAGE_PATHS` is empty. In this case Step 3 behaves exactly as before this change — every pending story spawns an unconditional researcher. No error or warning is emitted for a legacy tasks file.

## Step 3: Research Per Story (Reuse-Gate)

For each pending story, apply the following gate before deciding whether to spawn a researcher. Spawn decisions may be made **in parallel** across all pending stories once the gate logic is resolved.

### 3a: Coverage Check

A story is **covered** when `COVERAGE_PATHS` contains at least one path that matches either condition:
1. The path matches `*-<story.id>-codebase.md` (per-story codebase research written by a prior deepen run), **OR**
2. The path ends with `-codebase.md` and does **not** contain a story-ID segment — i.e., it is a topic-level codebase research file. In this case, the story is covered only when every file in `story.implementation.files` (if present) is a subset of the file paths listed in that topic-level research file's `## File References` section.

When `COVERAGE_PATHS` is empty (legacy tasks file — see Step 2e), skip the gate and proceed directly to Step 3c for every pending story.

### 3b: Freshness Check

For each covered story, determine the matching research path (prefer the per-story path if both conditions apply). Confirm freshness via:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" \
           2>/dev/null || \
           cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
"$AIMI_CLI" research-lookup <matched-research-path>
```

- **Exit 0 (fresh):** Reuse the existing file. Record `research_path_for_story[story.id] = <matched-research-path>`. This story does **not** spawn a researcher — Step 4 will read the existing file.
- **Exit 1 (stale or file not found):** Treat as a cache miss; proceed to Step 3c for this story. Log: `[deepen] research stale for <story.id> — re-spawning`.

### 3c: Spawn Scoped Researcher (on miss or stale)

For stories that are uncovered or stale, spawn a codebase researcher **scoped** to the story's implementation files. Compute the per-story output path once and pass it as `outputPath:` in the prompt:

```
per_story_path = .aimi/research/YYYY-MM-DD-[TOPIC_SLUG]-[RUN_TS]-[story.id]-codebase.md
```

When a prior path for this story already exists in `COVERAGE_PATHS` (stale case), the new researcher **overwrites** that same per-story path — do **not** accumulate multiple per-story files. Use the computed `per_story_path` above (which shares the new `RUN_TS`) as the target; the old file is replaced.

```
Task subagent_type="aimi-engineering:research:aimi-codebase-researcher"
  [model: <AGENT_MODELS.research when not "inherit">]
  prompt: "Find codebase patterns relevant to this story:
           Title: [story.title]
           Description: [story.description]
           Acceptance Criteria: [story.acceptanceCriteria]
           Research Depth: $RESEARCH_DEPTH
           --paths [story.implementation.files joined as space-separated list]

           Look for: relevant files, existing patterns, potential conflicts,
           edge cases, and anything that would help an agent implement this.

           outputPath: .aimi/research/YYYY-MM-DD-[TOPIC_SLUG]-[RUN_TS]-[story.id]-codebase.md"
```

When `story.implementation.files` is absent or empty, omit the `--paths` line — the researcher scopes itself from the story context.

Every parallel agent in a single deepen invocation shares the same `YYYY-MM-DD-<TOPIC_SLUG>-<RUN_TS>-` prefix; the story ID is the per-agent discriminator.

### 3d: Collect Research Paths

After all researcher tasks complete (or are confirmed reused), collect the resolved research path for every pending story:

- **Reused story:** the fresh path returned by `research-lookup` (exit 0 printed the path to stdout).
- **Newly spawned story:** parse the researcher's return for a pointer-block. A pointer-block is a fenced code block or inline text containing `outputPath: <path>`. When present and the path exists on disk, use that path. **When the pointer-block is missing or malformed**, fall back to the `outputPath` value that was passed in the spawn prompt (`per_story_path`). Verify the fallback path exists on disk before recording it; log a warning if neither path is found: `[deepen] warning: no research file found for <story.id> — skipping enrichment`.

Record the resolved path as `research_path_for_story[story.id]` for use in Step 4.

## Step 4: Enrich Stories

For each pending story, **Read** the full research file at `research_path_for_story[story.id]` (resolved in Step 3d) using the Read tool. Use both the returned agent summary and the full file content for richer enrichment. When no research path was recorded for a story (all attempts failed), enrich from story text alone and note the missing research in the story's `notes`.

For each pending story, using the research results:

### 4a: Improve Acceptance Criteria
- Make vague criteria more specific (e.g., "Add column" → "Add `status` column as VARCHAR(20) with CHECK constraint")
- Add missing criteria discovered by research (edge cases, validation rules)
- Ensure "Typecheck passes" is present
- Ensure UI stories have "Verify in browser"

### 4b: Assess Story Size
If a story appears too large for one context window:
- Split into smaller stories
- **Split ID format:** US-003 becomes US-003 + US-003a
- **Split priority format:** If original priority is 3, split gets 3 and 3.5
- Each split story must be independently completable

### 4c: Enrich Implementation

For each pending story, populate or merge the `implementation` object:

- **If `implementation` is absent:** Create it from research results with `files`, `approach`, and `verify` fields.
- **If `implementation` already exists:**
  - `files`: Append newly discovered file paths. Deduplicate the array (no repeated entries).
  - `approach`: Overwrite only if the research yields a more specific or detailed approach. If the existing approach is already specific, keep it.
  - `verify`: Overwrite only if the research yields a more specific verification command. If the existing verify is already specific, keep it.

### 4d: Add Research Notes
Populate the `notes` field with useful context:
- Relevant file paths discovered by research
- Patterns to follow
- Gotchas or warnings

### 4e: Spec Cross-Reference

This phase activates only when `metadata.designBundle.businessSpec` or `metadata.designBundle.designSpec` is present in the loaded tasks.json. Read both fields once, before the per-story loop:

```bash
biz_spec=$(jq -r '.metadata.designBundle.businessSpec // empty' <tasks-file-path>)
design_spec=$(jq -r '.metadata.designBundle.designSpec // empty' <tasks-file-path>)
```

If both are empty (no bundle, or bundle without specs), skip Step 4e entirely — no edits, no warnings.

**Cross-reference is purely additive:** never remove existing acceptance criteria, never reorder the story array, never modify `dependsOn` or `wave`.

#### BusinessSpec cross-reference (when `biz_spec` is non-empty)

Read the BusinessSpec file at the path stored in `biz_spec`.

Parse section headings using the patterns:
- Top-level numbered sections: `^## (\d+)\.` (e.g., `## 2. Screens`, `## 3. Business Rules`, `## 9. Acceptance Criteria`)
- Sub-numbered sections: `^### (\d+)\.(\d+)` (e.g., `### 9.1`, `### 3.1`)

**Missing acceptance criteria (§ 9):**

For each pending story whose title matches a screen name found in BusinessSpec § 2:
1. Locate the corresponding acceptance criteria block in BusinessSpec § 9.
2. For each criterion in that block, check whether it is already present in the story's `acceptanceCriteria` array by matching either:
   - The rule-ID prefix (`RN-NN` form, e.g., `RN-01`, `RN-04`), or
   - Verbatim criterion text (case-insensitive substring match).
3. Add any criterion not already covered, verbatim with rule IDs preserved. Do not duplicate criteria already present.

**Rule-ID annotation (§ 3):**

For each pending story, scan all items in `acceptanceCriteria` for rule-ID patterns (`RN-\d+`) that appear in BusinessSpec § 3 (Business Rules). Collect the matched IDs (deduplicated, sorted). If any are found, append to the story's `notes` field:

```
Touches rules: RN-01, RN-04
```

Append to (do not overwrite) any existing `notes` content. If `notes` is absent, create it with this annotation. If no rule IDs are matched, leave `notes` unchanged.

#### DesignSpec cross-reference (when `design_spec` is non-empty)

Read the DesignSpec file at the path stored in `design_spec`.

**Component-mapping conflict detection (§ 6):**

Parse DesignSpec § 6 (Mapeamento para `@/components/ui`) — this section contains a table mapping component names to existing project component paths.

For each pending story whose `implementation.files` references a component path:
1. Check whether any referenced component is listed in the § 6 mapping table as one that already exists in the project.
2. If the story would create a component that the spec maps to an existing project component, surface the conflict as an `Open Questions` entry appended to the story's `notes`:

```
**Open Questions:** Component `<ComponentName>` conflicts with existing project component mapped in DesignSpec § 6 (`<existing-path>`). Reuse the existing component or override the mapping.
```

Append to (do not overwrite) any existing `notes` content.

**Prop-type signature enforcement (§ 2.2):**

For each pending component-creation story whose title matches an entry in DesignSpec § 2.2:
1. Locate the prop-type signature defined for that component in § 2.2.
2. Check whether the verbatim signature is already cited in the story's `acceptanceCriteria`.
3. If absent, add it as a new criterion verbatim. Do not modify criteria that already include the signature.

## Step 4.5: Append `researchPaths` to Metadata

Collect the resolved research paths from `research_path_for_story` (all entries recorded in Step 3d). This includes both **reused** paths (fresh files confirmed by `research-lookup`) and **newly written** paths (files produced by a spawned researcher this run). Append them to `metadata.researchPaths[]` in the tasks.json so `$AIMI_CLI archive-task` can clean them up when the tasks file is archived.

- If `metadata.researchPaths` is absent, create it as a new array.
- If present, append the new paths to the existing array.
- Deduplicate the final array (no repeated entries — useful when deepen is re-run on the same tasks file). First-occurrence wins; insertion order is preserved.
- Skip any story whose research path could not be confirmed on disk — do not record paths that do not exist.

**Legacy degrade (no `metadata.researchPaths` in tasks.json and no brainstorm researchPaths):** Step 3 spawned researchers unconditionally (one per pending story). This step appends all successfully written paths exactly as before this change — no behavioral difference for legacy tasks files.

## Step 5: Write Updated Tasks File

Write the enriched tasks.json back to the **same file path**. Preserve:
- `schemaVersion` (unchanged)
- `metadata` (unchanged except `researchPaths` — appended by Step 4.5)
- Completed stories (unchanged — `status: "completed"`)
- Skipped stories (unchanged — `status: "skipped"`)

Only pending stories should have updated `acceptanceCriteria`, `notes`, and potentially be split.

**Never modify, remove, or reorder `dependsOn` or `wave` on any story.**

Validate the JSON is well-formed before writing.

## Step 5.5: Post-Enrichment Validation

After writing the enriched tasks.json, run validation:

```bash
$AIMI_CLI init-session --file <tasks-file-path>
$AIMI_CLI validate-deps
$AIMI_CLI validate-stories
```

**If any validation fails (non-zero exit):**
1. Read the error output to identify the issues.
2. Fix the offending stories, `dependsOn` references, dependency cycles, or malformed fields.
3. Re-write the tasks.json using the Write tool.
4. Re-run all validations until they pass.

Do **not** proceed to the report step until all validations succeed.

## Step 5.6: Research GC (advisory, non-fatal)

After all validations pass, invoke research-gc once to prune orphaned research files older than 30 days. This must run **after** Step 5 writes updated metadata (so newly registered researchPaths are not pruned), and only once per session.

```bash
$AIMI_CLI research-gc || true
```

If `research-gc` fails or prints an error, log it but continue to Step 6 — GC failure is never blocking.

## Step 6: Aimi-Branded Report

```
Stories enriched successfully!

Tasks: .aimi/tasks/[tasks-filename].json

Changes:
- [X] stories enriched with research insights
- [Y] stories split (too large for one iteration)
- [Z] acceptance criteria added
- [W] completed stories preserved

Next steps:
1. **Run `/aimi:review`** - Get feedback from code reviewers
2. **Run `/aimi:status`** - View updated task list
3. **Run `/aimi:execute`** - Begin autonomous execution
```

**IMPORTANT:** Output the "Next steps" block EXACTLY as shown above — use `/aimi:` prefix (e.g., `/aimi:review`), NOT the fully-qualified plugin name (e.g., `/aimi-engineering:review`). Copy the block verbatim.

## Error Handling

If research agents fail:
- Proceed with available results
- Report: "Some research agents failed. Enrichment may be partial."

If tasks file write fails:
- Report the error
- Original file is unchanged (write uses temp file pattern)
