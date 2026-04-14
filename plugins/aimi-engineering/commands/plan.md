---
name: aimi:plan
description: Generate tasks.json directly from a feature description
argument-hint: "[feature description]"
allowed-tools: Read, Write, Edit, Bash(git:*), Bash(mkdir:*), Bash(AIMI_CLI=*), Bash($AIMI_CLI:*), Task
---

# Aimi Plan

Generate `.aimi/tasks/YYYY-MM-DD-[feature]-tasks.json` directly from a feature description. Full pipeline: research, spec analysis, story decomposition, JSON output. No intermediate markdown plan.

## Feature Description

$ARGUMENTS

## Step 0: Environment Setup

### Resolve CLI Path

Read `references/cli-path-resolution.md` and follow the **Resolve CLI Path** and **Version Check** sections to set `$AIMI_CLI`. Each layer is a separate Bash call.

If resolution fails, report error and STOP.

### Fetch Origin (Branch Freshness Check)

Ensure local refs are current before determining the default branch:

```bash
git fetch origin 2>&1 || echo "WARNING: git fetch failed (offline?). Continuing with local refs."
```

If fetch fails, warn but continue planning with local refs.

### Detect Default Branch

```bash
$AIMI_CLI detect-default-branch
```

Use the output as the default branch for `branchName` derivation in Phase 4.

## Phase 0: Idea Refinement

Check `.aimi/brainstorms/` for a matching brainstorm (semantic match on topic, within 14 days):

```bash
ls -t .aimi/brainstorms/*.md 2>/dev/null | head -10
```

- **If relevant brainstorm found:** Read it, use as context, skip questions.
- **If multiple match:** Ask user which to use.
- **If none found:** Ask refinement questions via AskUserQuestion until the idea is clear.

### Implementation Scope Detection

After the brainstorm check, determine the implementation scope:

- **Non-app feature detected** (feature description contains keywords: `refactor`, `rename`, `migrate`, `CLI`, `command-line`, `plugin`, `skill`, `command`, `documentation`, `docs`, `changelog`, `readme` AND does NOT contain app-related signals: `page`, `dashboard`, `form`, `modal`, `UI`, `frontend`, `backend`, `API`) → skip scope question, leave `implementationScope` unset, proceed to Phase 1
- **Conflicting signals** (both non-app keywords and app-related signals present) → do NOT skip, ask the question below

1. **Auto-detect default from brainstorm context** (if a brainstorm was found):
   - If brainstorm text contains signals like `frontend-only`, `mocked data`, or `prototype` → default to option 1
   - If brainstorm text contains signals like `backend`, `API`, `schema`, or `full-stack` → default to option 2

2. **Ask the user** via AskUserQuestion:
   > What type of implementation? (1) frontend prototype with mocked data (2) full-stack implementation (frontend + backend)

   Present the auto-detected default if one was determined.

3. **Store the result** as `implementationScope: "frontend-only" | "full-stack"` for use in Phase 4 metadata.

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

Compute `researchDepth` and store in metadata: `skip` (internal + strong patterns), `quick` (solid patterns, minor uncertainty), `standard` (default), `deep` (security, payments, new tech, high uncertainty).

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
6. **Compute `wave` numbers** from `dependsOn` graph: roots = wave 1; non-roots = max(wave of deps) + 1; contiguous, no gaps
7. **Populate `implementation` object** when research provides file paths and patterns: `files` (concrete paths), `approach` (actionable strategy), `verify` (executable check). Omit when research is insufficient.
8. **Assign `verification` strategy** per story type: `api` (endpoints), `visual` (UI), `test` (backend logic). Set `status: "pending"`.
   **IMPORTANT: `verification` MUST be an object — never a bare string.** Examples:
   - visual: `{"strategy": "visual", "status": "pending", "url": "http://localhost:3000/page", "expect": "Dashboard visible"}`
   - api: `{"strategy": "api", "status": "pending", "url": "http://localhost:3000/api/endpoint", "expect": "200 with JSON"}`
   - test: `{"strategy": "test", "status": "pending", "expect": "All tests pass"}`
9. **Detect and attach `gate` objects**: `verify` (OAuth/email/webhooks), `decision` (multiple viable approaches), `action` (external manual action). Most stories have no gate.
10. Write descriptions in user story format: "As a [specific role], I want [feature] so that [benefit]" — role must name the actor, never just "user"
11. Generate verifiable acceptance criteria (every story must have "Typecheck passes")
12. Initialize every story with `status: "pending"` and appropriate `dependsOn` array
13. Validate: no circular dependencies in `dependsOn`, no self-references, all referenced IDs exist, no vague criteria

### `dependsOn` Inference Rules

- **Same layer, independent concerns** (different tables, different pages, different routes) → no dependency between them (`dependsOn: []`)
- **Same layer, shared concern** (FK referencing another story's table, component extending another) → add dependency
- **Cross-layer**: backend depends on schema stories it reads/writes; UI depends on backend it calls; aggregation depends on what it consumes
- **Skip layers when appropriate**: UI reading directly from a new table depends on the schema story, not a non-existent backend story

### Multi-Repo Project Assignment

When the workspace has multiple git repos under one parent folder:
- Set `project` to relative path from `.aimi/` parent (e.g., `backend`, `services/api`)
- Omit `project` when only one repo exists or all stories target the same repo
- Cross-repo dependencies in `dependsOn` are valid

### Type Values

| Type | Use When |
|------|----------|
| `feat` | New feature |
| `ref` | Refactoring |
| `bug` | Bug fix |
| `chore` | Maintenance task |

## Phase 4: Write tasks.json

Branch on `implementationScope` from Phase 0:

### When `implementationScope` is `"full-stack"`:

1. **Partition stories by layer**: UI stories → frontend file; schema + backend + aggregation stories → backend file
2. **Assign unique IDs across both files**: frontend gets `US-001` to `US-N`, backend gets `US-(N+1)` to `US-M` — no ID collisions
3. **Rebuild `dependsOn` independently per file**: remove all cross-file references; within each file, only reference IDs that exist in that file
4. **Recompute `wave` numbers per file**: roots (`dependsOn: []`) are wave 1 within each file, independently
5. **Derive separate `branchName` per file**: `type/[feature]-frontend` and `type/[feature]-backend`
6. Write frontend file to `.aimi/tasks/YYYY-MM-DD-[feature-name]-frontend-tasks.json`
7. Write backend file to `.aimi/tasks/YYYY-MM-DD-[feature-name]-backend-tasks.json`

### When `implementationScope` is `"frontend-only"`:

1. Set `metadata.frontendOnly: true`
2. **Generate `metadata.backendSpec`** by analyzing story descriptions and acceptance criteria:
   - `endpoints`: array of `{ method, path, description }` — API contracts implied by UI interactions
   - `dataModels`: array of `{ name, fields }` — data structures implied by forms and displays
   - `businessRules`: array of strings — validation rules and business logic from acceptance criteria
   - `businessContext`: object with structured business context:
     - `summary`: high-level overview of the business domain and purpose
     - `userRoles`: extract persona names from story descriptions ("As a [role]" patterns)
     - `constraints`: identify non-functional requirements from acceptance criteria (scalability, compliance, performance SLAs)
     - `assumptions`: document integration assumptions, data patterns, auth model, API style
     - `successCriteria`: derive measurable success criteria from acceptance criteria across all stories
3. Write single file to `.aimi/tasks/YYYY-MM-DD-[feature-name]-frontend-tasks.json`

### When `implementationScope` is unset (legacy):

Write single file to `.aimi/tasks/YYYY-MM-DD-[feature-name]-tasks.json`

### Derive Metadata (all modes)

- **title**: `<type>: <Descriptive Name>`
- **type**: `feat`, `ref`, `bug`, or `chore`
- **branchName**: Kebab-case, prefixed with type. For split files: `type/[feature]-frontend` and `type/[feature]-backend`
- **createdAt**: Today's date (YYYY-MM-DD)
- **planPath**: Always `null`
- **brainstormPath**: Path to brainstorm if one was used, otherwise omit
- **researchDepth**: Value computed in Phase 1.5 (`skip`, `quick`, `standard`, `deep`), or omit if not computed
- **maxConcurrency**: Default `4`. Set to `1` for strictly sequential execution.

### Write File

```bash
mkdir -p .aimi/tasks
```

Write JSON using the Write tool. Validate JSON is well-formed before writing.

### Schema v3.2 Structure

```json
{
  "schemaVersion": "3.2",
  "metadata": {
    "title": "string (required)",
    "type": "feat|ref|bug|chore (required)",
    "branchName": "string (required, regex: ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$)",
    "createdAt": "YYYY-MM-DD (required)",
    "planPath": "null (always null for planner-generated)",
    "brainstormPath": "string (optional)",
    "researchDepth": "skip|quick|standard|deep (optional, computed in Phase 1.5)",
    "maxConcurrency": "number (optional, default 4)",
    "frontendOnly": "boolean (optional, true when frontend-only scope)",
    "backendSpec": {
      "endpoints": [{"method": "string", "path": "string", "description": "string"}],
      "dataModels": [{"name": "string", "fields": ["string"]}],
      "businessRules": ["string"],
      "businessContext": "string"
    }
  },
  "userStories": [
    {
      "id": "US-NNN (required, zero-padded, regex: ^US-[0-9]{3}[a-z]?$)",
      "title": "string (required, max 200 chars)",
      "description": "string (required, max 500 chars, user story format)",
      "acceptanceCriteria": ["string[] (required, each max 600 chars, must include 'Typecheck passes')"],
      "priority": "number (required, sequential integers, tiebreaker for same-depth stories)",
      "status": "pending (required, always 'pending' for new stories)",
      "dependsOn": ["US-NNN (required, array of story IDs, empty [] for root stories)"],
      "notes": "string (optional, default '')",
      "project": "string (optional, relative path for multi-repo, no '..' components)",
      "wave": "number (required, computed from dependsOn: roots=1, others=max(dep waves)+1)",
      "implementation": {
        "files": ["string[] (required, concrete file paths from research)"],
        "approach": "string (required, actionable strategy referencing codebase patterns)",
        "verify": "string (required, executable command or checkable assertion)"
      },
      "verification": {
        "strategy": "test|visual|api (required)",
        "status": "pending (required)",
        "url": "string (optional, for api/visual strategies)",
        "expect": "string (optional, expected result description)"
      },
      "gate": {
        "type": "verify|decision|action (required)",
        "status": "pending (required)",
        "prompt": "string (required, human-readable description)",
        "options": ["string[] (optional, for decision gates)"]
      }
    }
  ]
}
```

**Notes:** `implementation`, `verification`, and `gate` are optional per story. `wave` is required on all stories.

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
- [ ] `schemaVersion` is `"3.2"`
- [ ] `researchDepth` (if set) is one of: `skip`, `quick`, `standard`, `deep`
- [ ] Every story has a `wave` number (wave 1 for roots, computed from `dependsOn` for others)
- [ ] Wave numbers are contiguous with no gaps
- [ ] `implementation` (if present) has `files` (string[]), `approach` (string), `verify` (string) with concrete paths
- [ ] `verification` (if present) has `strategy` (`test`, `visual`, or `api`) and `status` (`"pending"`)
- [ ] `gate` (if present) has `type` (`verify`, `decision`, or `action`), `status` (`"pending"`), and `prompt`
- [ ] Gates only attached when heuristics clearly match

### Split-File Checks (when `implementationScope` is set)
- [ ] Full-stack: two files generated (`*-frontend-tasks.json` and `*-backend-tasks.json`)
- [ ] Full-stack: each file has its own `branchName` (`type/[feature]-frontend`, `type/[feature]-backend`)
- [ ] Full-stack: story IDs are unique across both files (no ID collisions)
- [ ] Full-stack: no cross-file `dependsOn` references — each file's graph is self-contained
- [ ] Full-stack: wave numbers computed independently per file (roots = wave 1 within each file)
- [ ] Frontend-only: single `*-frontend-tasks.json` with `metadata.frontendOnly: true`
- [ ] Frontend-only: `metadata.backendSpec` contains `endpoints`, `dataModels`, `businessRules`, `businessContext`
- [ ] Phase 4.5 validation runs on each file independently using `$AIMI_CLI init-session --file <path>`

## Phase 4.5: Post-Generation Validation

After writing the tasks.json file(s), validate each generated output independently.

**For split files (full-stack):** run validation on each file separately using `init-session --file`:

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
2. Fix the offending story IDs, `dependsOn` references, or dependency cycles
3. Re-write the tasks.json file using the Write tool
4. Re-run all validations until they pass

Do **not** proceed to the report step until all validations succeed.

## Step 5: Aimi-Branded Report

```
Tasks generated successfully!

Tasks: .aimi/tasks/[tasks-filename].json

Stories: [X] total
Schema version: 3.2
Waves: [N] total
[If gates found]: Gates: [N] (verify: [X], decision: [Y], action: [Z])
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

**IMPORTANT:** Output the "Next steps" block EXACTLY as shown above — use `/aimi:` prefix (e.g., `/aimi:deepen`), NOT the fully-qualified plugin name (e.g., `/aimi-engineering:deepen`). Copy the block verbatim.

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
