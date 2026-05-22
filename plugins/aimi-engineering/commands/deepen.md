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

## Step 3: Research Per Story (Parallel)

For each pending story, spawn a research agent **in parallel**. Pass the `outputPath:` as a structured field so the researcher writes to the exact canonical path (agents honor caller-supplied `outputPath:` per their Output Contract):

```
Task subagent_type="aimi-engineering:research:aimi-codebase-researcher"
  [model: <AGENT_MODELS.research when not "inherit">]
  prompt: "Find codebase patterns relevant to this story:
           Title: [story.title]
           Description: [story.description]
           Acceptance Criteria: [story.acceptanceCriteria]
           Research Depth: $RESEARCH_DEPTH

           Look for: relevant files, existing patterns, potential conflicts,
           edge cases, and anything that would help an agent implement this.

           outputPath: .aimi/research/YYYY-MM-DD-[TOPIC_SLUG]-[RUN_TS]-[story.id]-codebase.md"
```

Every parallel agent in a single deepen invocation shares the same `YYYY-MM-DD-<TOPIC_SLUG>-<RUN_TS>-` prefix; the story ID is the per-agent discriminator. Collect all results.

## Step 4: Enrich Stories

For each pending story, **Read** the full research file at `.aimi/research/YYYY-MM-DD-<TOPIC_SLUG>-<RUN_TS>-[story.id]-codebase.md` using the Read tool. Use both the returned agent summary and the full file content for richer enrichment.

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

Collect the paths of every research file that was successfully written in Step 3 (one per pending story, using the `YYYY-MM-DD-<TOPIC_SLUG>-<RUN_TS>-<story.id>-codebase.md` pattern). Append them to `metadata.researchPaths[]` in the tasks.json so `$AIMI_CLI archive-task` can clean them up when the tasks file is archived.

- If `metadata.researchPaths` is absent, create it as a new array.
- If present, append the new paths to the existing array.
- Deduplicate the final array (no repeated entries — useful when deepen is re-run on the same tasks file).
- Skip any story whose research file write failed — do not record paths that do not exist on disk.

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
