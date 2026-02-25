---
name: task-planner
description: "Generate tasks.json directly from a feature description. Full pipeline: research, spec analysis, story decomposition, JSON output. Triggers on: plan feature, generate tasks, create task list, direct planning."
user-invocable: true
---

# Task Planner

Generate `docs/tasks/YYYY-MM-DD-[feature]-tasks.json` directly from a feature description. No intermediate markdown plan.

---

## The Job

Take a feature description through research, spec analysis, and story decomposition. Output a tasks.json file ready for autonomous execution.

---

## Output Format

**Filename:** `docs/tasks/YYYY-MM-DD-[feature-name]-tasks.json`

```json
{
  "schemaVersion": "2.2",
  "metadata": {
    "title": "feat: Feature name",
    "type": "feat",
    "branchName": "feat/feature-name",
    "createdAt": "YYYY-MM-DD",
    "planPath": null,
    "brainstormPath": "docs/brainstorms/... (optional)"
  },
  "userStories": [
    {
      "id": "US-001",
      "title": "Story title",
      "description": "As a [user], I want [feature] so that [benefit]",
      "acceptanceCriteria": ["Criterion 1", "Typecheck passes"],
      "priority": 1,
      "passes": false,
      "notes": ""
    }
  ]
}
```

**Key:** `planPath` is always `null` — this skill generates tasks.json directly, no intermediate plan.

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

Check `docs/brainstorms/` for a matching brainstorm (semantic match, within 14 days). If found, use as context and skip questions. If multiple match, ask user. If none, ask refinement questions via AskUserQuestion until the idea is clear.

### Phase 1: Local Research (Parallel)

Run these agents **in parallel**:

```
Task subagent_type="compound-engineering:research:repo-research-analyst"
  prompt: "[feature description + brainstorm context]"

Task subagent_type="compound-engineering:research:learnings-researcher"
  prompt: "[feature description]"
```

### Phase 1.5: Research Decision

- **High-risk** (security, payments, external APIs) → always run external research
- **Strong local context** → skip external research
- **Uncertainty** → run external research

### Phase 1.5b: External Research (Conditional, Parallel)

Only if Phase 1.5 decides external research is needed:

```
Task subagent_type="compound-engineering:research:best-practices-researcher"
  prompt: "[feature description]"

Task subagent_type="compound-engineering:research:framework-docs-researcher"
  prompt: "[feature description]"
```

### Phase 1.6: Research Consolidation

Merge findings from all research agents:
- Relevant file paths and codebase patterns
- Institutional learnings from `docs/solutions/`
- External best practices (if researched)
- CLAUDE.md conventions

### Phase 2: Spec Analysis

```
Task subagent_type="compound-engineering:workflow:spec-flow-analyzer"
  prompt: "[feature description + consolidated research]"
```

Incorporate identified gaps as acceptance criteria or story notes.

### Phase 3: Story Decomposition

Apply rules from `references/story-decomposition.md`:
1. Extract requirements from research + spec-flow output
2. Group by layer (schema → backend → UI → aggregation)
3. Size check (one context window per story)
4. Order by dependency (assign priority numbers)
5. Generate verifiable acceptance criteria
6. Validate (no circular dependencies, no vague criteria)

### Phase 4: Write tasks.json

1. Derive metadata: title, type, branchName (kebab-case), createdAt (today)
2. Set `planPath: null`
3. Set `brainstormPath` if a brainstorm was used
4. Write to `docs/tasks/YYYY-MM-DD-[feature-name]-tasks.json`

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

If compound-engineering plugin is not installed, report: "compound-engineering plugin is required for research agents. Install it first." and STOP.

---

## Checklist Before Writing

- [ ] Each story completable in one agent iteration
- [ ] Stories ordered by dependency (schema → backend → UI)
- [ ] Every story has "Typecheck passes" as criterion
- [ ] Acceptance criteria are verifiable (not vague)
- [ ] No story depends on a later story
- [ ] branchName is valid (alphanumeric, hyphens, slashes)
- [ ] `planPath` is `null`
- [ ] Field lengths: title ≤ 200, description ≤ 500, criterion ≤ 300
