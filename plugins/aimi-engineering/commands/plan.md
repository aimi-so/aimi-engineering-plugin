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

### Detect Git Repo Layout

Check if the current directory (AIMI root) is itself a git repository:

```bash
git rev-parse --git-dir >/dev/null 2>&1
```

Store the result as `AIMI_ROOT_IS_GIT_REPO` (true/false). When false, this is a **multi-repo layout** — default branch detection is deferred to Phase 4 after the git repo auto-scan discovers project paths.

### Fetch Origin & Detect Default Branch

**If `AIMI_ROOT_IS_GIT_REPO` is true:**

```bash
git fetch origin 2>&1 || echo "WARNING: git fetch failed (offline?). Continuing with local refs."
$AIMI_CLI detect-default-branch
```

Use the output as the default branch for `branchName` derivation in Phase 4.

**If `AIMI_ROOT_IS_GIT_REPO` is false:** Skip. Default branch detection happens per-project in Phase 4 using `$AIMI_CLI detect-default-branch --project [path]`.

## Phase 0: Idea Refinement

Check `.aimi/brainstorms/` for a matching brainstorm (semantic match on topic, within 14 days):

```bash
ls -t .aimi/brainstorms/*.md 2>/dev/null | head -10
```

- **If relevant brainstorm found:** Read it, use as context, skip questions.
- **If multiple match:** Ask user which to use.
- **If none found:** Ask refinement questions via AskUserQuestion until the idea is clear.

### Prototype Context

After reading the brainstorm (if one was found), parse it for referenced prototype HTML files and load them into context:

1. **Parse frontmatter** — look for a `prototype:` key; its value is a path string or a YAML list of path strings.
2. **Parse `## Prototype` section** — scan the brainstorm body for a `## Prototype` heading; extract any file paths that appear in that section (lines starting with `-` or table cells containing `.html`).
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
6. **Aggregate size cap:** after loading, measure the total byte size of all wrapped blocks. If the total exceeds **200 KB**, drop blocks in reverse label order (Z → A) until the aggregate fits under the cap. Log one warning line per dropped block: `prototype <path> dropped — aggregate prototype context exceeded 200KB`.
7. Collect all successfully loaded blocks into a variable `prototypeBlocks` (empty string if none loaded). This variable, together with `prototypeTokens`, is threaded into Phase 1 and Phase 3 prompts below. Also collect the resolved absolute paths of every successfully loaded prototype HTML file (those not dropped by the size cap and not missing on disk) into a variable `resolvedPrototypePaths` (empty list if none); append the tokens-sidecar JSON path (`.aimi/brainstorms/prototypes/<topic-slug>-tokens.json`) to `resolvedPrototypePaths` when `prototypeTokens` loaded successfully.

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

### Prepare Research Directory

```bash
mkdir -p .aimi/research
```

### Derive Topic Slug

From the feature description, derive a topic slug for research filename derivation:
1. Convert to lowercase
2. Replace spaces and special characters with hyphens
3. Remove consecutive hyphens
4. Truncate to 50 characters
5. Remove trailing hyphens

Store as `topicSlug` for use in researcher agent prompts.

### Generate Run Discriminator

Generate a single timestamp for this run to prevent same-day re-runs from overwriting prior research files:

```bash
RUN_TS=$(date +%H%M%S)
```

Store `RUN_TS` and use it in **all** research agent prompts for this run.

### Auto-Scan for Git Repos

Before launching research agents, scan immediate child directories for `.git/` directories to discover sub-projects:

```bash
for dir in */; do
  case "$dir" in .worktrees/|node_modules/|.aimi/|vendor/) continue;; esac
  [ -d "$dir/.git" ] && echo "$dir"
done
```

List discovered repos with their relative paths from the `.aimi/` parent.

- If **zero** or **one** repo is found, no multi-repo handling is needed
- If **multiple** repos are found, pass the list to research agents and use it in Phase 3 for `project` assignment

### Run Research Agents

Run these agents **in parallel** using the Task tool:

```
Task subagent_type="aimi-engineering:research:aimi-codebase-researcher"
  prompt: "Analyze the codebase for patterns relevant to: [feature description].
           topicSlug: [topicSlug]
           Look for: existing patterns, CLAUDE.md guidance, similar features,
           technology familiarity, file structure conventions.
           outputPath: .aimi/research/YYYY-MM-DD-[topicSlug]-[RUN_TS]-codebase.md
           [If prototypeBlocks is non-empty]:
           Prototype designs chosen for this feature (use as implementation reference):
           [prototypeBlocks]"

Task subagent_type="aimi-engineering:research:aimi-learnings-researcher"
  prompt: "Search .aimi/solutions/ for learnings relevant to: [feature description].
           topicSlug: [topicSlug]
           Look for: gotchas, patterns, past solutions, lessons learned.
           outputPath: .aimi/research/YYYY-MM-DD-[topicSlug]-[RUN_TS]-learnings.md
           [If prototypeBlocks is non-empty]:
           Prototype designs chosen for this feature (use as implementation reference):
           [prototypeBlocks]"
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
  prompt: "Research current best practices for: [feature description].
           researchDepth: [computed researchDepth from Phase 1.5]
           topicSlug: [topicSlug]
           outputPath: .aimi/research/YYYY-MM-DD-[topicSlug]-[RUN_TS]-best-practices.md"

Task subagent_type="aimi-engineering:research:aimi-framework-docs-researcher"
  prompt: "Research framework documentation for: [feature description].
           researchDepth: [computed researchDepth from Phase 1.5]
           topicSlug: [topicSlug]
           outputPath: .aimi/research/YYYY-MM-DD-[topicSlug]-[RUN_TS]-framework-docs.md"
```

## Phase 1.6: Research Consolidation

Consume researcher agent **summary returns** (the brief outputs from Task calls) — do NOT re-read the full `.aimi/research/` files unless a summary is insufficient for a planning decision.

> **Fallback:** If a researcher summary lacks detail needed for a specific planning decision, the orchestrator may read the corresponding `.aimi/research/YYYY-MM-DD-[topicSlug]-[RUN_TS]-*.md` file on demand.

Merge all findings into a structured consolidation with these sections:

1. **Key Patterns** — Architectural patterns, conventions, and recurring structures found in the codebase
2. **Conflicts** — Contradictions between sources (e.g., CLAUDE.md says X but codebase does Y), unresolved trade-offs
3. **File References** — Concrete file paths relevant to the feature, grouped by concern (schema, backend, UI, config)
4. **Learnings** — Institutional knowledge from `.aimi/solutions/`: gotchas, past mistakes, proven approaches
5. **External Insights** — Best practices and framework guidance from external research (empty if Phase 1.5b was skipped)

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

Using consolidated research and spec-flow output (and `prototypeBlocks` from Phase 0 Prototype Context if non-empty):

**If `prototypeBlocks` is non-empty**, prepend the following block to this phase's working context before decomposing stories:

```
Prototype designs chosen for this feature — implementation stories MUST reference these
directly when describing UI acceptance criteria, component structure, and visual behaviour:
[prototypeBlocks]
```

1. Extract all requirements (explicit + spec-flow identified)
2. Group by layer (schema → backend → UI → aggregation)
3. Assign IDs in `US-NNN` zero-padded format (`US-001`, `US-002`, ...) — never `US-1`, `story-1`, `S1`, or any other format
4. Size check: each story must be completable in ONE agent iteration (one context window)
5. Order by dependency: assign `dependsOn` arrays (explicit story IDs) and `priority` as tiebreaker
6. **Assign `project` field** when multiple repos were discovered in Phase 1:
   - Set `project` to the repo's relative path (e.g., `backend`, `services/api`)
   - Omit `project` when only one repo exists or the story targets the CWD repo
   - Path format: no leading `./`, no `..` components, must match `^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$`
   - Cross-repo dependencies in `dependsOn` are valid
7. **Compute `wave` numbers** from `dependsOn` graph: roots = wave 1; non-roots = max(wave of deps) + 1; contiguous, no gaps
8. **Populate `implementation` object** when research provides file paths and patterns: `files` (concrete paths), `approach` (actionable strategy), `verify` (executable check). Omit when research is insufficient.
9. **Assign `verification` strategy** per story type: `api` (endpoints), `visual` (UI), `test` (backend logic). Set `status: "pending"`.
   **IMPORTANT: `verification` MUST be an object — never a bare string.** Examples:
   - visual: `{"strategy": "visual", "status": "pending", "url": "http://localhost:3000/page", "expect": "Dashboard visible"}`
   - api: `{"strategy": "api", "status": "pending", "url": "http://localhost:3000/api/endpoint", "expect": "200 with JSON"}`
   - test: `{"strategy": "test", "status": "pending", "expect": "All tests pass"}`
10. **Detect and attach `gate` objects**: `verify` (OAuth/email/webhooks), `decision` (multiple viable approaches), `action` (external manual action). Most stories have no gate.
11. Write descriptions in user story format: "As a [specific role], I want [feature] so that [benefit]" — role must name the actor, never just "user"
12. Generate verifiable acceptance criteria (every story must have "Typecheck passes")
13. Initialize every story with `status: "pending"` and appropriate `dependsOn` array
14. Validate: no circular dependencies in `dependsOn`, no self-references, all referenced IDs exist, no vague criteria

### `dependsOn` Inference Rules

- **Same layer, independent concerns** (different tables, different pages, different routes) → no dependency between them (`dependsOn: []`)
- **Same layer, shared concern** (FK referencing another story's table, component extending another) → add dependency
- **Cross-layer**: backend depends on schema stories it reads/writes; UI depends on backend it calls; aggregation depends on what it consumes
- **Skip layers when appropriate**: UI reading directly from a new table depends on the schema story, not a non-existent backend story

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

Write the same `prototypePaths` array to both frontend and backend metadata (symmetric with `researchPaths` precedent).

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
- **researchPaths**: Collect all `.aimi/research/` file paths written by Phase 1 agents (codebase, learnings) and Phase 1.5b agents (best-practices, framework-docs). Omit entirely when `researchDepth` is `skip` or no research files were written.
- **prototypePaths**: Convert each path in `resolvedPrototypePaths` to a path relative to `AIMI_ROOT` (no leading `./`, no `..` components). Deduplicate with `| unique`. Emit as `metadata.prototypePaths` array. Omit the key entirely when the array is empty.
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
    "researchPaths": "string[] (optional, relative paths to research files written by Phase 1 and Phase 1.5b agents)",
    "prototypePaths": "string[] (optional, relative paths to prototype HTML files and tokens sidecar JSON registered by Phase 0 Prototype Context)",
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
- [ ] `prototypePaths` (if set) contains only paths that exist on disk and were successfully loaded into `prototypeBlocks`
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
[If prototypePaths non-empty]: Prototypes: [N] variant file(s) registered
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
