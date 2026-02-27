---
name: task-planner
description: "Generate tasks.json directly from a feature description. Full pipeline: research, spec analysis, story decomposition, JSON output. Triggers on: plan feature, generate tasks, create task list, direct planning."
user-invocable: false
---

# Task Planner

Generate `.aimi/tasks/YYYY-MM-DD-[feature]-tasks.json` directly from a feature description. No intermediate markdown plan.

---

## The Job

Take a feature description through research, spec analysis, and story decomposition. Output a tasks.json file ready for autonomous execution.

---

## Output Format

**Filename:** `.aimi/tasks/YYYY-MM-DD-[feature-name]-tasks.json`

**Schema:** v3 — see `references/task-format-v3.md` for the full specification.

```json
{
  "schemaVersion": "3.0",
  "metadata": {
    "title": "feat: Feature name",
    "type": "feat",
    "branchName": "feat/feature-name",
    "createdAt": "YYYY-MM-DD",
    "planPath": null,
    "brainstormPath": ".aimi/brainstorms/... (optional)",
    "maxConcurrency": 4
  },
  "userStories": [
    {
      "id": "US-001",
      "title": "Add schema migration",
      "description": "As a [user], I want [feature] so that [benefit]",
      "acceptanceCriteria": ["Criterion 1", "Typecheck passes"],
      "priority": 1,
      "status": "pending",
      "dependsOn": [],
      "notes": ""
    },
    {
      "id": "US-002",
      "title": "Add server action",
      "description": "As a [user], I want [feature] so that [benefit]",
      "acceptanceCriteria": ["Criterion 1", "Typecheck passes"],
      "priority": 2,
      "status": "pending",
      "dependsOn": ["US-001"],
      "notes": ""
    }
  ]
}
```

**Key fields:**
- `planPath` is always `null` — this skill generates tasks.json directly, no intermediate plan.
- `status` replaces the old `passes` boolean. All stories initialize as `"pending"`.
- `dependsOn` is a string array of story IDs that must complete before this story can start.
- `maxConcurrency` (optional) controls how many stories execute in parallel (default: `4`).

### Type Values

| Type | Use When |
|------|----------|
| `feat` | New feature |
| `ref` | Refactoring |
| `bug` | Bug fix |
| `chore` | Maintenance task |

---

## Pipeline Overview

Execute these phases in order. See `references/pipeline-phases.md` for detailed instructions per phase.

### Phase 0: Idea Refinement

Check `.aimi/brainstorms/` for a matching brainstorm (semantic match, within 14 days). If found, use as context and skip questions. If multiple match, ask user. If none, ask refinement questions via AskUserQuestion until the idea is clear.

### Phase 1: Local Research (Parallel)

Run these agents **in parallel**:

```
Task subagent_type="aimi-engineering:research:aimi-codebase-researcher"
  prompt: "[feature description + brainstorm context]"

Task subagent_type="aimi-engineering:research:aimi-learnings-researcher"
  prompt: "[feature description]"
```

### Phase 1.5: Research Decision

- **High-risk** (security, payments, external APIs) → always run external research
- **Strong local context** → skip external research
- **Uncertainty** → run external research

### Phase 1.5b: External Research (Conditional, Parallel)

Only if Phase 1.5 decides external research is needed:

```
Task subagent_type="aimi-engineering:research:aimi-best-practices-researcher"
  prompt: "[feature description]"

Task subagent_type="aimi-engineering:research:aimi-framework-docs-researcher"
  prompt: "[feature description]"
```

### Phase 1.6: Research Consolidation

Merge findings from all research agents:
- Relevant file paths and codebase patterns
- Institutional learnings from `.aimi/solutions/`
- External best practices (if researched)
- CLAUDE.md conventions

### Phase 2: Spec Analysis

```
Task subagent_type="aimi-engineering:workflow:aimi-spec-flow-analyzer"
  prompt: "[feature description + consolidated research]"
```

Incorporate identified gaps as acceptance criteria or story notes.

### Phase 3: Story Decomposition

Apply rules from `references/story-decomposition.md`:
1. Extract requirements from research + spec-flow output
2. Group by layer (schema → backend → UI → aggregation)
3. Size check (one context window per story)
4. Order by dependency (assign priority numbers)
5. **Generate `dependsOn` arrays** using the inference rules in `references/story-decomposition.md`:
   - **Same layer, independent concerns** (different tables, different pages) → `dependsOn: []` between them
   - **Same layer, shared concern** (FK referencing another story's table) → add dependency
   - **Cross-layer**: backend depends on schema stories it reads/writes; UI depends on backend it calls; aggregation depends on what it consumes
   - **Skip layers when appropriate**: UI reading directly from a new table depends on the schema story, not a non-existent backend story
6. Generate verifiable acceptance criteria
7. Validate dependency graph:
   - No circular dependencies (DAG check)
   - No self-references (no story lists its own ID)
   - All IDs referenced in `dependsOn` exist as story IDs
   - No vague acceptance criteria

### Phase 4: Write tasks.json

1. Derive metadata: title, type, branchName (kebab-case), createdAt (today)
2. Set `schemaVersion: "3.0"`
3. Set `planPath: null`
4. Set `brainstormPath` if a brainstorm was used
5. Set `maxConcurrency` (optional — default `4`; set to `1` for fully sequential execution)
6. For each story: set `status: "pending"`, include `dependsOn` array from Phase 3
7. Write to `.aimi/tasks/YYYY-MM-DD-[feature-name]-tasks.json`

See `references/task-format-v3.md` for the complete v3 schema definition, status state machine, and validation rules.

---

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

---

## Checklist Before Writing

### Sizing and Content
- [ ] Each story completable in one agent iteration
- [ ] Stories ordered by dependency (schema → backend → UI)
- [ ] Every story has "Typecheck passes" as criterion
- [ ] Acceptance criteria are verifiable (not vague)
- [ ] branchName is valid (alphanumeric, hyphens, slashes)
- [ ] `planPath` is `null`
- [ ] Field lengths: title ≤ 200, description ≤ 500, criterion ≤ 300

### v3 Schema Validations
- [ ] `schemaVersion` is `"3.0"`
- [ ] Every story has `status` initialized to `"pending"`
- [ ] Every story has a `dependsOn` array (even if empty `[]`)
- [ ] No circular dependencies in `dependsOn` (graph must be a DAG)
- [ ] All IDs referenced in `dependsOn` exist as story IDs in the file
- [ ] No self-references (no story lists its own ID in `dependsOn`)
- [ ] `priority` values are sequential integers, consistent with dependency depth
- [ ] `maxConcurrency` (if set) is a positive integer
