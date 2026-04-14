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

**Filename convention:**
- Full-stack: `.aimi/tasks/YYYY-MM-DD-[feature-name]-frontend-tasks.json` and `.aimi/tasks/YYYY-MM-DD-[feature-name]-backend-tasks.json`
- Frontend-only: `.aimi/tasks/YYYY-MM-DD-[feature-name]-frontend-tasks.json`
- Legacy (no scope): `.aimi/tasks/YYYY-MM-DD-[feature-name]-tasks.json`

> Key fields: `schemaVersion` ("3.2"), `metadata{title,type,branchName,createdAt,planPath(null),researchDepth(optional),maxConcurrency(4),frontendOnly(optional),backendSpec(optional:{endpoints[{method,path,description}],dataModels[{name,fields}],businessRules[string],businessContext(string)})}`, `userStories[]{id(US-NNN),title(≤200),description(≤500),acceptanceCriteria(each≤600),priority,status("pending"),dependsOn([]),notes,project(optional),wave(computed),implementation(optional),verification(optional),gate(optional)}`

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

#### Implementation Scope Detection

After the brainstorm check, determine the implementation scope:

1. **Auto-detect default from brainstorm context** (if a brainstorm was found):
   - If brainstorm text contains signals like `frontend-only`, `mocked data`, or `prototype` → default to option 1
   - If brainstorm text contains signals like `backend`, `API`, `schema`, or `full-stack` → default to option 2

2. **Ask the user** via AskUserQuestion:
   > What type of implementation? (1) frontend prototype with mocked data (2) full-stack implementation (frontend + backend)

   Present the auto-detected default if one was determined.

3. **Store the result** as `implementationScope: "frontend-only" | "full-stack"` for use in Phase 4 metadata.

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

   **IMPORTANT: `verification` MUST be an object — never a bare string like `"passed"` or `"pending"`.**

   Required object format examples:
   - visual: `{"strategy": "visual", "status": "pending", "url": "http://localhost:3000/page", "expect": "Dashboard with charts visible"}`
   - api: `{"strategy": "api", "status": "pending", "url": "http://localhost:3000/api/endpoint", "expect": "200 with JSON array"}`
   - test: `{"strategy": "test", "status": "pending", "expect": "All unit tests pass"}`
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

Branch on `implementationScope` from Phase 0:

#### When `implementationScope` is `"full-stack"`:

1. **Partition stories by layer**: UI stories → frontend file; schema + backend + aggregation stories → backend file
2. **Assign unique IDs across both files**: frontend gets `US-001` to `US-N`, backend gets `US-(N+1)` to `US-M` — no ID collisions
3. **Rebuild `dependsOn` independently per file**: remove all cross-file references; within each file, only reference IDs that exist in that file
4. **Recompute `wave` numbers per file**: roots (`dependsOn: []`) are wave 1 within each file, independently
5. **Derive separate `branchName` per file**: `type/[feature]-frontend` and `type/[feature]-backend` (e.g., `feat/add-user-auth-frontend`, `feat/add-user-auth-backend`)
6. Derive shared metadata: title, type, createdAt, `schemaVersion: "3.2"`, `planPath: null`, `brainstormPath`, `researchDepth`, `maxConcurrency`
7. For each story: set `status: "pending"`, include `dependsOn`, `wave`, and optional `implementation`, `verification`, `gate` objects
8. Write frontend file to `.aimi/tasks/YYYY-MM-DD-[feature-name]-frontend-tasks.json`
9. Write backend file to `.aimi/tasks/YYYY-MM-DD-[feature-name]-backend-tasks.json`

#### When `implementationScope` is `"frontend-only"`:

1. Set `metadata.frontendOnly: true`
2. **Generate `metadata.backendSpec`** by analyzing story descriptions and acceptance criteria:
   - `endpoints`: array of `{ method, path, description }` objects — API contracts implied by UI interactions
   - `dataModels`: array of `{ name, fields }` objects — data structures implied by forms and displays
   - `businessRules`: array of strings — validation rules and business logic encoded in acceptance criteria
   - `businessContext`: object with structured business context:
     - `summary`: high-level overview of the business domain and purpose
     - `userRoles`: extract persona names from story descriptions ("As a [role]" patterns)
     - `constraints`: identify non-functional requirements from acceptance criteria (scalability, compliance, performance SLAs)
     - `assumptions`: document integration assumptions, data patterns, auth model, API style
     - `successCriteria`: derive measurable success criteria from acceptance criteria across all stories
3. Write single file to `.aimi/tasks/YYYY-MM-DD-[feature-name]-frontend-tasks.json`
4. Derive metadata: title, type, branchName (kebab-case, `-frontend` suffix), createdAt, `schemaVersion: "3.2"`, `planPath: null`, `brainstormPath`, `researchDepth`, `maxConcurrency`
5. For each story: set `status: "pending"`, include `dependsOn`, `wave`, and optional `implementation`, `verification`, `gate` objects

#### When `implementationScope` is unset (legacy):

1. Derive metadata: title, type, branchName (kebab-case), createdAt (today)
2. Set `schemaVersion: "3.2"`, `planPath: null`, `brainstormPath`, `researchDepth`, `maxConcurrency`
3. For each story: set `status: "pending"`, include `dependsOn`, `wave`, and optional `implementation`, `verification`, `gate` objects
4. Write to `.aimi/tasks/YYYY-MM-DD-[feature-name]-tasks.json`

### Phase 4.5: Post-Generation Validation

After writing the tasks.json file(s), validate each generated output independently.

**For split files (full-stack):** run validation on each file separately, using `init-session --file` to target each file:

```bash
$AIMI_CLI init-session --file .aimi/tasks/YYYY-MM-DD-[feature-name]-frontend-tasks.json
$AIMI_CLI validate-ids
$AIMI_CLI validate-deps
$AIMI_CLI validate-stories

$AIMI_CLI init-session --file .aimi/tasks/YYYY-MM-DD-[feature-name]-backend-tasks.json
$AIMI_CLI validate-ids
$AIMI_CLI validate-deps
$AIMI_CLI validate-stories
```

**For single file (frontend-only or legacy):**

```bash
$AIMI_CLI init-session --file .aimi/tasks/YYYY-MM-DD-[feature-name]-frontend-tasks.json
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

## Checklist Before Writing

Apply the validation checklist from [validation-checklist.md](references/validation-checklist.md) before writing.

## Reference Files

- [pipeline-phases.md](references/pipeline-phases.md)
- [story-decomposition.md](references/story-decomposition.md)
- [task-format-v3.md](references/task-format-v3.md)
- [validation-checklist.md](references/validation-checklist.md)
