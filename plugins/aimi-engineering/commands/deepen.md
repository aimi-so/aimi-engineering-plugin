---
name: aimi:deepen
description: Enrich tasks.json stories with research insights
argument-hint: "[path to tasks.json (optional)]"
---

# Aimi Deepen

Enrich tasks.json stories directly with research insights, better acceptance criteria, and story splitting when needed.

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

Filter stories where `passes == false` and `skipped != true`. These are the stories to enrich.

If no pending stories:
```
All stories are already complete. Nothing to deepen.
```
STOP.

**CRITICAL:** Never modify or split completed stories (`passes: true`). Only enrich pending stories.

## Step 3: Research Per Story (Parallel)

For each pending story, spawn a research agent **in parallel**:

```
Task subagent_type="aimi-engineering:research:aimi-codebase-researcher"
  prompt: "Find codebase patterns relevant to this story:
           Title: [story.title]
           Description: [story.description]
           Acceptance Criteria: [story.acceptanceCriteria]

           Look for: relevant files, existing patterns, potential conflicts,
           edge cases, and anything that would help an agent implement this."
```

Collect all results.

## Step 4: Enrich Stories

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

### 4c: Add Research Notes
Populate the `notes` field with useful context:
- Relevant file paths discovered by research
- Patterns to follow
- Gotchas or warnings

## Step 5: Write Updated Tasks File

Write the enriched tasks.json back to the **same file path**. Preserve:
- `schemaVersion` (unchanged)
- `metadata` (unchanged)
- Completed stories (unchanged — `passes: true`)
- Skipped stories (unchanged — `skipped: true`)

Only pending stories should have updated `acceptanceCriteria`, `notes`, and potentially be split.

Validate the JSON is well-formed before writing.

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

**NEVER mention:**
- compound-engineering
- /deepen-plan
- workflows:*
- Any command without the `aimi:` prefix

## Error Handling

If research agents fail:
- Proceed with available results
- Report: "Some research agents failed. Enrichment may be partial."

If tasks file write fails:
- Report the error
- Original file is unchanged (write uses temp file pattern)
