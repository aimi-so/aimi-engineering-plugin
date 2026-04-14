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

> Key fields: `schemaVersion` ("3.2"), `metadata{title,type,branchName,createdAt,planPath(null),researchDepth(optional),maxConcurrency(4),frontendOnly(optional),backendSpec(optional)}`, `userStories[]{id(US-NNN),title(≤200),description(≤500),acceptanceCriteria(each≤600),priority,status("pending"),dependsOn([]),notes,project(optional),wave(computed),implementation(optional),verification(optional),gate(optional)}`

**Notes:** `planPath` is always `null` (this skill generates tasks.json directly). All stories initialize with `status: "pending"`. `dependsOn` is a string array of story IDs. `maxConcurrency` defaults to `4`.

### Type Values

| Type | Use When |
|------|----------|
| `feat` | New feature |
| `ref` | Refactoring |
| `bug` | Bug fix |
| `chore` | Maintenance task |

---

## Pipeline Overview

Execute these phases in order.

### Phase 0: Idea Refinement

Check `.aimi/brainstorms/` for a matching brainstorm (semantic match, within 14 days). If found, use as context and skip questions. If multiple match, ask user. If none, ask refinement questions via AskUserQuestion until the idea is clear.

### Phase 1: Local Research (Parallel)

**Auto-scan for git repos:** Before launching research agents, scan immediate child directories for `.git/` directories to discover sub-projects:
```bash
for dir in */; do
  case "$dir" in .worktrees/|node_modules/|.aimi/|vendor/) continue;; esac
  [ -d "$dir/.git" ] && echo "$dir"
done
```
List discovered repos with their relative paths from the `.aimi/` parent.

Run these agents **in parallel**:

```
Task subagent_type="aimi-engineering:research:aimi-codebase-researcher"
  prompt: "[feature description + brainstorm context + discovered repos]"

Task subagent_type="aimi-engineering:research:aimi-learnings-researcher"
  prompt: "[feature description]"
```

### Phase 1.5: Research Decision

- **High-risk** (security, payments, external APIs) → always run external research
- **Strong local context** → skip external research
- **Uncertainty** → run external research

Compute `researchDepth` and store in metadata: `skip` (internal + strong patterns), `quick` (solid patterns, minor uncertainty), `standard` (default), `deep` (security, payments, new tech, high uncertainty).

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

1. Extract requirements from research + spec-flow output
2. Group by layer (schema → backend → UI → aggregation)
3. Size check (one context window per story)
4. Order by dependency (assign priority numbers)
5. **Generate `dependsOn` arrays**:
   - **Same layer, independent concerns** (different tables, different pages) → `dependsOn: []` between them
   - **Same layer, shared concern** (FK referencing another story's table) → add dependency
   - **Cross-layer**: backend depends on schema stories it reads/writes; UI depends on backend it calls; aggregation depends on what it consumes
   - **Skip layers when appropriate**: UI reading directly from a new table depends on the schema story, not a non-existent backend story
6. **Assign `project` field** when multiple repos were discovered in Phase 1:
   - Set `project` to the repo's relative path (e.g., `backend`, `services/api`)
   - Omit `project` when only one repo exists or the story targets the CWD repo
   - Path format: no leading `./`, no `..` components, must match `^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$`
7. **Compute `wave` numbers** from `dependsOn` graph:
   - Root stories (`dependsOn: []`) are wave 1
   - Each non-root story: `wave = max(wave(dep) for dep in dependsOn) + 1`
   - Waves must be contiguous (1, 2, 3, ...) with no gaps
8. **Populate `implementation` object** when research provides sufficient context:
   - `files`: concrete file paths from codebase research (omit entire object if no files identified)
   - `approach`: actionable strategy referencing specific codebase patterns
   - `verify`: executable command or checkable assertion
9. **Assign `verification` strategy** based on story type:
   - API endpoint stories → `strategy: "api"` (with `url` and `expect`)
   - UI component stories → `strategy: "visual"` (with `url` and `expect`)
   - Backend logic stories → `strategy: "test"` (with `expect`)
   - Set `verification.status` to `"pending"`
10. **Detect and attach `gate` objects** using heuristics:
    - `verify` gate: OAuth, email, webhooks, payment, external service integration
    - `decision` gate: multiple viable approaches with significant downstream impact
    - `action` gate: external manual action the agent cannot perform
    - Most stories have no gate; only attach when heuristics clearly match
11. Assign IDs in `US-NNN` zero-padded format (`US-001`, `US-002`, ...) — never `US-1`, `story-1`, `S1`, or any other format
12. Write descriptions in user story format: "As a [specific role], I want [feature] so that [benefit]" — role must name the actor, never just "user"
13. Generate verifiable acceptance criteria
14. Validate dependency graph:
    - No circular dependencies (DAG check)
    - No self-references (no story lists its own ID)
    - All IDs referenced in `dependsOn` exist as story IDs
    - No vague acceptance criteria

### Phase 4: Write tasks.json

1. Derive metadata: title, type, branchName (kebab-case), createdAt (today)
2. Set `schemaVersion: "3.2"`
3. Set `planPath: null`
4. Set `brainstormPath` if a brainstorm was used
5. Set `researchDepth` from Phase 1.5 (if computed)
6. Set `maxConcurrency` (optional — default `4`; set to `1` for fully sequential execution)
7. For each story: set `status: "pending"`, include `dependsOn` array, `wave` number, and optional `implementation`, `verification`, `gate` objects from Phase 3
8. Write to `.aimi/tasks/YYYY-MM-DD-[feature-name]-tasks.json`

### Phase 4.5: Post-Generation Validation

After writing the tasks.json file, validate the generated output:

```bash
$AIMI_CLI validate-ids
$AIMI_CLI validate-deps
$AIMI_CLI validate-stories
```

**If any validation fails (non-zero exit):**
1. Read the error output to identify the issues
2. Fix the offending story IDs, `dependsOn` references, dependency cycles, or `project` fields
3. Re-write the tasks.json file using the Write tool
4. Re-run all validations until they pass

Do **not** proceed to the report step until all validations succeed.

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
- [ ] Every description follows "As a [specific role], I want [feature] so that [benefit]" format — role names the actor, never just "user"
- [ ] Field lengths: title ≤ 200, description ≤ 500, criterion ≤ 600

### v3.2 Schema Validations
- [ ] `schemaVersion` is `"3.2"`
- [ ] Every story `id` follows `US-NNN` format (e.g., `US-001`, `US-002`) — not `S1`, `F1`, `TASK-1`, or any other format
- [ ] Every story has `status` initialized to `"pending"`
- [ ] Every story has a `dependsOn` array (even if empty `[]`)
- [ ] No circular dependencies in `dependsOn` (graph must be a DAG)
- [ ] All IDs referenced in `dependsOn` exist as story IDs in the file
- [ ] No self-references (no story lists its own ID in `dependsOn`)
- [ ] `priority` values are sequential integers, consistent with dependency depth
- [ ] `maxConcurrency` (if set) is a positive integer
- [ ] `project` (if present) is a relative path with no `..` components, matching `^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$`
- [ ] `project` is omitted when only one repo exists or story targets CWD repo
- [ ] `researchDepth` (if set) is one of: `skip`, `quick`, `standard`, `deep`
- [ ] Every story has a `wave` number (wave 1 for roots, computed from `dependsOn` for others)
- [ ] Wave numbers are contiguous with no gaps
- [ ] `implementation` (if present) has `files` (string[]), `approach` (string), `verify` (string)
- [ ] `implementation.files` uses concrete paths from research, not placeholders
- [ ] `verification` (if present) has `strategy` (`test`, `visual`, or `api`) and `status` (`"pending"`)
- [ ] `gate` (if present) has `type` (`verify`, `decision`, or `action`), `status` (`"pending"`), and `prompt`
- [ ] Gates only attached when heuristics clearly match; most stories have no gate
