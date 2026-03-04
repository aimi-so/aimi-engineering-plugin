---
name: aimi:plan
description: Generate tasks.json directly from a feature description
argument-hint: "[feature description]"
---

# Aimi Plan

Generate `.aimi/tasks/YYYY-MM-DD-[feature]-tasks.json` directly from a feature description. Full pipeline: research, spec analysis, story decomposition, JSON output. No intermediate markdown plan.

## Feature Description

$ARGUMENTS

## Phase 0: Idea Refinement

Check `.aimi/brainstorms/` for a matching brainstorm (semantic match on topic, within 14 days):

```bash
ls -t .aimi/brainstorms/*.md 2>/dev/null | head -10
```

- **If relevant brainstorm found:** Read it, use as context, skip questions.
- **If multiple match:** Ask user which to use.
- **If none found:** Ask refinement questions via AskUserQuestion until the idea is clear.

## Phase 1: Local Research (Parallel)

Run these agents **in parallel** using the Task tool:

```
Task subagent_type="aimi-engineering:research:aimi-codebase-researcher"
  prompt: "Analyze the codebase for patterns relevant to: [feature description].
           Look for: existing patterns, CLAUDE.md guidance, similar features,
           technology familiarity, file structure conventions."

Task subagent_type="aimi-engineering:research:aimi-learnings-researcher"
  prompt: "Search .aimi/solutions/ for learnings relevant to: [feature description].
           Look for: gotchas, patterns, past solutions, lessons learned."
```

If either agent fails, proceed with available results.

## Phase 1.5: Research Decision

- **High-risk** (security, payments, external APIs) → always run external research
- **Strong local context** → skip external research
- **Uncertainty** → run external research

## Phase 1.5b: External Research (Conditional, Parallel)

Only if Phase 1.5 decides external research is needed:

```
Task subagent_type="aimi-engineering:research:aimi-best-practices-researcher"
  prompt: "Research current best practices for: [feature description]."

Task subagent_type="aimi-engineering:research:aimi-framework-docs-researcher"
  prompt: "Research framework documentation for: [feature description]."
```

## Phase 1.6: Research Consolidation

Merge all findings:
- Relevant file paths and codebase patterns
- Institutional learnings from `.aimi/solutions/`
- External best practices (if researched)
- CLAUDE.md conventions

## Phase 2: Spec Analysis

```
Task subagent_type="aimi-engineering:workflow:aimi-spec-flow-analyzer"
  prompt: "Analyze this feature specification for flow completeness, gaps, and edge cases:
           Feature: [feature description]
           Context from research: [consolidated research summary]
           Identify: user flows, edge cases, missing requirements, security concerns."
```

Incorporate gaps as acceptance criteria or story notes.

## Phase 3: Story Decomposition

Using consolidated research and spec-flow output:

1. Extract all requirements (explicit + spec-flow identified)
2. Group by layer (schema → backend → UI → aggregation)
3. Assign IDs in `US-NNN` zero-padded format (`US-001`, `US-002`, ...) — never `US-1`, `story-1`, `S1`, or any other format
4. Size check: each story must be completable in ONE agent iteration (one context window)
5. Order by dependency: assign `dependsOn` arrays (explicit story IDs) and `priority` as tiebreaker
6. Write descriptions in user story format: "As a [specific role], I want [feature] so that [benefit]" — role must name the actor, never just "user"
7. Generate verifiable acceptance criteria (every story must have "Typecheck passes")
8. Initialize every story with `status: "pending"` and appropriate `dependsOn` array
9. Validate: no circular dependencies in `dependsOn`, no self-references, all referenced IDs exist, no vague criteria

See `references/story-decomposition.md` for detailed rules.

### Type Values

| Type | Use When |
|------|----------|
| `feat` | New feature |
| `ref` | Refactoring |
| `bug` | Bug fix |
| `chore` | Maintenance task |

## Phase 4: Write tasks.json

### Derive Metadata

- **title**: `<type>: <Descriptive Name>`
- **type**: `feat`, `ref`, `bug`, or `chore`
- **branchName**: Kebab-case, prefixed with type — e.g., `feat/add-user-auth`
- **createdAt**: Today's date (YYYY-MM-DD)
- **planPath**: Always `null`
- **brainstormPath**: Path to brainstorm if one was used, otherwise omit
- **maxConcurrency**: Default `4`. Set to `1` for strictly sequential execution.

### Derive Filename

```
.aimi/tasks/YYYY-MM-DD-[feature-name]-tasks.json
```

### Write File

```bash
mkdir -p .aimi/tasks
```

Write JSON using the Write tool. Validate JSON is well-formed before writing.

### Output Format

> **Schema:** See `task-format-v3.md` in `skills/task-planner/references/`. Full v3 specification with complete example, validation rules, and dependency system.
> Key fields: `schemaVersion`, `metadata{title,type,branchName,createdAt,planPath,maxConcurrency}`, `userStories[]{id,title,description,acceptanceCriteria,priority,status,dependsOn,notes}`

### Checklist Before Writing

- [ ] Every story `id` uses `US-NNN` zero-padded format (`US-001`, `US-002`, ...) — not `US-1`, `S1`, `TASK-1`, or any other format
- [ ] Each story completable in one agent iteration
- [ ] Stories ordered by dependency (schema → backend → UI)
- [ ] Every story has "Typecheck passes" as criterion
- [ ] Acceptance criteria are verifiable (not vague)
- [ ] `dependsOn` arrays are valid: no circular dependencies, no self-references, all referenced IDs exist
- [ ] No story depends on a story that depends on it (DAG validation)
- [ ] Every story has `status` initialized to `"pending"`
- [ ] `dependsOn` is `[]` for root stories with no upstream dependencies
- [ ] branchName is valid (alphanumeric, hyphens, slashes)
- [ ] `planPath` is `null`
- [ ] Every description follows "As a [specific role], I want [feature] so that [benefit]" format — role names the actor, never just "user"
- [ ] Field lengths: title ≤ 200, description ≤ 500, criterion ≤ 600

## Phase 4.5: Post-Generation Validation

After writing the tasks.json file, validate the generated output using the CLI:

### Validate Story IDs

```bash
$AIMI_CLI validate-ids
```

### Validate Dependency Graph

```bash
$AIMI_CLI validate-deps
```

**If either validation fails (non-zero exit):**
1. Read the error output to identify the issues
2. Fix the offending story IDs, `dependsOn` references, or dependency cycles
3. Re-write the tasks.json file using the Write tool
4. Re-run both validations until they pass

Do **not** proceed to the report step until both validations succeed.

## Step 5: Aimi-Branded Report

```
Tasks generated successfully!

Tasks: .aimi/tasks/[tasks-filename].json

Stories: [X] total
Schema version: 3.0
[If brainstorm used]: Context: .aimi/brainstorms/[brainstorm-file]
[If gaps found]: Gaps identified: [N] (captured as criteria/notes)
[If 10+ stories]: Warning: [N] stories generated. Consider splitting into smaller feature sets.
[If parallel stories detected]: Parallel groups: [N] stories can run concurrently (max concurrency: [maxConcurrency])

Next steps:
1. **Run `/aimi:deepen`** - Enrich stories with research (optional)
2. **Run `/aimi:review`** - Get feedback from code reviewers
3. **Run `/aimi:status`** - View task list
4. **Run `/aimi:execute`** - Begin autonomous execution
```

## Error Handling

| Phase | Failure | Action |
|-------|---------|--------|
| Phase 0 | No feature description | Ask user for input |
| Phase 1 | Research agent fails | Proceed with available results |
| Phase 1.5b | External research fails | Proceed without external context |
| Phase 2 | Spec-flow finds critical gaps | Add gaps as story notes, flag in report |
| Phase 3 | Zero stories produced | Report error, ask user to refine scope |
| Phase 3 | 10+ stories produced | Proceed with warning in report |
| Phase 4 | File write fails | Report error with path |
