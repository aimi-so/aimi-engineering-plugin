# Pipeline Phases — Detailed Instructions

## Phase 0: Idea Refinement

### Brainstorm Auto-Detection

1. List files in `.aimi/brainstorms/`:
   ```bash
   ls -t .aimi/brainstorms/*.md 2>/dev/null | head -10
   ```

2. **Relevance criteria:**
   - Topic (from filename or YAML frontmatter `title:`) semantically matches the feature description
   - Created within the last 14 days (check `date:` in frontmatter or file modification time)
   - If multiple candidates match, use the most recent one

3. **If a relevant brainstorm exists:**
   - Read the brainstorm document
   - Announce: "Found brainstorm from [date]: [topic]. Using as context."
   - Extract key decisions, chosen approach, and open questions
   - **Skip refinement questions** — the brainstorm already answered WHAT to build
   - Set `brainstormPath` in metadata

4. **If multiple brainstorms could match:**
   - Use AskUserQuestion to ask which brainstorm to use, or whether to proceed without one

5. **If no brainstorm found:**
   - Run idea refinement via AskUserQuestion
   - Ask questions one at a time to understand: purpose, constraints, success criteria
   - Prefer multiple choice when natural options exist
   - Continue until idea is clear OR user says "proceed"

### Implementation Scope Detection

After the brainstorm check, determine the implementation scope:

1. **Auto-detect default from brainstorm context** (if a brainstorm was found):
   - If brainstorm text contains signals like `frontend-only`, `mocked data`, or `prototype` → default to option 1
   - If brainstorm text contains signals like `backend`, `API`, `schema`, or `full-stack` → default to option 2

2. **Ask the user** via AskUserQuestion:
   > What type of implementation? (1) frontend prototype with mocked data (2) full-stack implementation (frontend + backend)

   Present the auto-detected default if one was determined.

3. **Store the result** as `implementationScope: "frontend-only" | "full-stack"` for use in Phase 4 metadata.

### Pipeline Mode (Non-Interactive)

If running in a `disable-model-invocation` context or automated pipeline:
- Skip all AskUserQuestion calls
- Use the feature description as-is
- Auto-select the most recent matching brainstorm if available

### Signals to Gather

During refinement, note for Phase 1.5:
- **User familiarity**: Do they know the codebase patterns?
- **Topic risk**: Security, payments, external APIs warrant more caution
- **Uncertainty level**: Is the approach clear or open-ended?
- **Implementation scope**: Frontend prototype or full-stack?

---

## Phase 1: Local Research (Always Runs)

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

Before launching research agents, scan immediate child directories of the `.aimi/` parent folder for git repositories:

```bash
for dir in */; do
  case "$dir" in .worktrees/|node_modules/|.aimi/|vendor/) continue;; esac
  [ -d "$dir/.git" ] && echo "$dir"
done
```

**Rules:**
- Only scan **immediate** children (no recursive search)
- Exclude: `.worktrees/`, `node_modules/`, `.aimi/`, `vendor/`
- Record discovered repos with their relative paths (e.g., `backend`, `services/api`, `packages/shared`)
- If **zero** or **one** repo is found, no multi-repo handling is needed
- If **multiple** repos are found, pass the list to research agents and use it in Phase 3 for project assignment

### Research Agents

Run two agents **in parallel** using the Task tool:

### Agent 1: aimi-codebase-researcher

```
Task subagent_type="aimi-engineering:research:aimi-codebase-researcher"
  prompt: "Analyze the codebase for patterns relevant to: [feature description].
           topicSlug: [topicSlug]
           Look for: existing patterns, CLAUDE.md guidance, similar features,
           technology familiarity, file structure conventions.
           outputPath: .aimi/research/YYYY-MM-DD-[topicSlug]-[RUN_TS]-codebase.md"
```

**What to extract:** File paths, naming conventions, architectural patterns, relevant existing code.

### Agent 2: aimi-learnings-researcher

```
Task subagent_type="aimi-engineering:research:aimi-learnings-researcher"
  prompt: "Search .aimi/solutions/ for learnings relevant to: [feature description].
           topicSlug: [topicSlug]
           Look for: gotchas, patterns, past solutions, lessons learned.
           outputPath: .aimi/research/YYYY-MM-DD-[topicSlug]-[RUN_TS]-learnings.md"
```

**What to extract:** Known pitfalls, proven patterns, institutional knowledge.

### If agents fail

If either agent fails or returns empty:
- Log: "Research agent [name] returned no results. Proceeding with available context."
- Continue to Phase 1.5 with whatever was gathered.
- Do NOT halt the pipeline.

---

## Phase 1.5: Research Decision

Based on signals from Phase 0 and findings from Phase 1:

### Always research externally:
- Security-related features (auth, encryption, access control)
- Payment processing or financial calculations
- External API integrations
- Data privacy / GDPR concerns

### Skip external research:
- Codebase has solid patterns for this type of work
- CLAUDE.md has specific guidance
- User demonstrated familiarity during refinement
- Feature is purely internal (refactoring, internal tooling)

### Research when uncertain:
- New technology not present in codebase
- User is exploring options
- No existing examples to follow

**Announce the decision:** Brief explanation, then continue.

### Compute `researchDepth`

Based on the signals gathered in Phase 0 and Phase 1, compute a `researchDepth` value and store it in metadata:

| Value | When to Assign |
|-------|---------------|
| `skip` | Feature is purely internal (refactoring, internal tooling) AND codebase has strong existing patterns AND CLAUDE.md has specific guidance |
| `quick` | Codebase has solid patterns, minor uncertainty only, no high-risk signals |
| `standard` | Default when no strong signal pushes toward skip or deep; moderate uncertainty or partial codebase coverage |
| `deep` | Security, payments, external APIs, new technology, user exploring options, high uncertainty |

**Rules:**
- If Phase 1.5 decides to skip external research entirely, set `researchDepth` to `skip` or `quick`
- If Phase 1.5 decides external research is needed, set `researchDepth` to `standard` or `deep`
- Store `researchDepth` in `metadata` for inclusion in Phase 4 output
- When `researchDepth` is `null` or omitted, the planner decides automatically (backwards compatible)

---

## Phase 1.5b: External Research (Conditional)

Only run if Phase 1.5 decides external research is valuable.

Run two agents **in parallel**:

### Agent 3: aimi-best-practices-researcher

```
Task subagent_type="aimi-engineering:research:aimi-best-practices-researcher"
  prompt: "Research current best practices for: [feature description].
           researchDepth: [computed researchDepth from Phase 1.5]
           topicSlug: [topicSlug]
           Focus on: industry standards, common patterns, security considerations.
           outputPath: .aimi/research/YYYY-MM-DD-[topicSlug]-[RUN_TS]-best-practices.md"
```

### Agent 4: aimi-framework-docs-researcher

```
Task subagent_type="aimi-engineering:research:aimi-framework-docs-researcher"
  prompt: "Research framework documentation for: [feature description].
           researchDepth: [computed researchDepth from Phase 1.5]
           topicSlug: [topicSlug]
           Focus on: official docs, API references, version-specific features.
           outputPath: .aimi/research/YYYY-MM-DD-[topicSlug]-[RUN_TS]-framework-docs.md"
```

### If agents fail

If external research fails (network issues, agent errors):
- Log: "External research unavailable. Proceeding with local context only."
- Continue to Phase 1.6.

---

## Phase 1.6: Research Consolidation

Consume researcher agent **summary returns** (the brief outputs from Task calls) — do NOT re-read the full `.aimi/research/` files unless a summary is insufficient for a planning decision.

> **Fallback:** If a researcher summary lacks detail needed for a specific planning decision, the orchestrator may read the corresponding `.aimi/research/YYYY-MM-DD-[topicSlug]-[RUN_TS]-*.md` file on demand.

Merge all findings into a structured consolidation with these sections:

1. **Key Patterns** — Architectural patterns, conventions, and recurring structures found in the codebase
2. **Conflicts** — Contradictions between sources (e.g., CLAUDE.md says X but codebase does Y), unresolved trade-offs
3. **File References** — Concrete file paths relevant to the feature, grouped by concern (schema, backend, UI, config)
4. **Learnings** — Institutional knowledge from `.aimi/solutions/`: gotchas, past mistakes, proven approaches
5. **External Insights** — Best practices and framework guidance from external research (empty if Phase 1.5b was skipped)

This consolidated context feeds into Phase 2 and Phase 3.

---

## Phase 2: Spec Analysis

Run the spec-flow-analyzer agent:

```
Task subagent_type="aimi-engineering:workflow:aimi-spec-flow-analyzer"
  prompt: "Analyze this feature specification for flow completeness, gaps, and edge cases:

           Feature: [feature description]

           Context from research:
           [consolidated research summary]

           Identify: user flows, edge cases, missing requirements, security concerns."
```

### Processing spec-flow output

- **Gaps that map to requirements**: Convert to acceptance criteria on relevant stories
- **Edge cases**: Add as acceptance criteria or create dedicated stories
- **Security concerns**: Create dedicated stories or add as criteria
- **Missing flows**: Add as story notes with flag "Identified by spec-flow analysis"

The pipeline does NOT pause for spec-flow gaps. All gaps are captured in the output.

---

## Phase 3: Story Decomposition

See `references/story-decomposition.md` for detailed rules.

Using the consolidated research and spec-flow output:

1. Extract all requirements (explicit + spec-flow identified)
2. Group by layer (schema → backend → UI → aggregation)
3. Assign IDs in `US-NNN` zero-padded format (`US-001`, `US-002`, ...) — never `US-1`, `story-1`, `S1`, or any other format
4. Apply sizing rules (one context window per story)
5. Assign priority numbers by dependency order
6. Generate verifiable acceptance criteria per story
7. **Assign `project` field** (multi-repo only)
8. **Compute `wave` numbers** from the `dependsOn` graph (see below)
9. **Populate `implementation` object** when research provides sufficient context (see below)
10. **Assign `verification` strategy** based on story type (see below)
11. **Detect and attach `gate` objects** using heuristics (see below)
12. Run validation checklist

### Project Assignment Rules

When Phase 1 discovered **multiple** git repos, assign the `project` field to each story:

1. **Infer target repo** from the story's feature description, affected file paths, and codebase research results
2. **Set `project`** to the repo's relative path from the `.aimi/` parent (e.g., `backend`, `services/api`, `packages/shared`)
3. **Omit `project`** when:
   - Only one repo was discovered (or zero)
   - The story targets the CWD repo (the repo where `.aimi/` lives)
4. **Path format**: Use forward slashes, no leading `./`, no `..` components. Must match `^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$`
5. **Cross-repo dependencies**: Stories in different repos can still depend on each other via `dependsOn`. The executor handles repo switching.

**Example:**
```
Phase 1 discovered: backend/, frontend/, packages/shared/

US-001 → changes packages/shared/types.ts     → project: "packages/shared"
US-002 → changes backend/src/api/routes.ts    → project: "backend"
US-003 → changes frontend/src/pages/Home.tsx  → project: "frontend"
US-004 → changes only CWD files               → project: omitted
```

### Wave Computation

After computing `dependsOn` for all stories, derive wave numbers:

1. Stories with `dependsOn: []` are **wave 1** (root stories)
2. For each remaining story: `wave = max(wave(dep) for dep in dependsOn) + 1`
3. Resolve in topological order if a dependency's wave is not yet assigned
4. Wave numbers must be contiguous (1, 2, 3, ...) with no gaps
5. Stories in the same wave have no mutual dependencies and can run in parallel

### Implementation Object

When codebase research (Phase 1/1.5b) identified concrete file paths and patterns, populate the `implementation` object on each story:

- **`files`**: List specific file paths from the codebase researcher's output that this story will touch. Use actual discovered paths, not placeholders. If research did not identify files, omit the entire `implementation` object.
- **`approach`**: Summarize the implementation strategy in 1-3 sentences, referencing specific codebase patterns (e.g., "Follow the existing server action pattern in `actions/tasks.ts`").
- **`verify`**: Map acceptance criteria to a concrete verification command or instruction (e.g., `"npm test -- --grep auth"`).

**Omit `implementation`** when research did not produce enough context for concrete file paths or actionable approach guidance.

### Verification Strategy Assignment

Assign a `verification` object to each story based on its type/layer:

| Story Type | Strategy | When to Use |
|------------|----------|-------------|
| API endpoint stories | `api` | REST endpoints, GraphQL resolvers, any HTTP interface |
| UI component stories | `visual` | Layout changes, styling, animations, responsive behavior |
| Backend logic stories | `test` | Server actions, utility functions, business rules |
| Type-only stories | omit verification | Schema changes, type definitions with no runtime behavior |

Set `verification.status` to `"pending"`. Optionally include `url` (for `api`/`visual`) and `expect` (expected result description).

**IMPORTANT: `verification` MUST be an object — never a bare string like `"passed"` or `"pending"`.** The executor's visual-follow detection depends on `verification.strategy` being accessible as an object property.

Required object format examples:
- visual: `{"strategy": "visual", "status": "pending", "url": "http://localhost:3000/page", "expect": "Dashboard with charts visible"}`
- api: `{"strategy": "api", "status": "pending", "url": "http://localhost:3000/api/endpoint", "expect": "200 with JSON array"}`
- test: `{"strategy": "test", "status": "pending", "expect": "All unit tests pass"}`

### Gate Detection

Attach a `gate` object only when heuristics clearly match. Most stories have no gate.

| Gate Type | Trigger Heuristics |
|-----------|-------------------|
| `verify` | Story involves OAuth, email delivery, webhooks, third-party API integration, or external services requiring manual confirmation |
| `decision` | Multiple viable implementation approaches exist with significant downstream impact; planner cannot determine the best path without human input |
| `action` | Story requires an external manual action the agent cannot perform (DNS configuration, app store submission, manual server provisioning) |

**Rules:**
1. If acceptance criteria reference OAuth flows, email sending, webhook endpoints, payment processing, or SMS delivery → `verify` gate
2. If codebase research surfaces multiple architecturally distinct approaches and the story implies a choice → `decision` gate (skip if one approach is clearly superior)
3. If completing the story requires a human action outside the codebase → `action` gate
4. When in doubt, omit the gate

Set `gate.status` to `"pending"` and provide a descriptive `gate.prompt`. For `decision` gates, include `gate.options`.

---

## Phase 4: Write tasks.json

Branch on `implementationScope` from Phase 0:

### When `implementationScope` is `"full-stack"`:

1. **Partition stories by layer**: UI stories → frontend file; schema + backend + aggregation stories → backend file
2. **Assign unique IDs across both files**: frontend gets `US-001` to `US-N`, backend gets `US-(N+1)` to `US-M` — no ID collisions
3. **Rebuild `dependsOn` independently per file**: remove all cross-file references; within each file, only reference IDs that exist in that file
4. **Recompute `wave` numbers per file**: roots (`dependsOn: []`) are wave 1 within each file, independently
5. **Derive separate `branchName` per file**: `type/[feature]-frontend` and `type/[feature]-backend` (e.g., `feat/add-user-auth-frontend`, `feat/add-user-auth-backend`)
6. Derive shared metadata: title, type, createdAt, `schemaVersion: "3.3"`, `planPath: null`, `brainstormPath`, `researchDepth`, `maxConcurrency`
7. Write frontend file to `.aimi/tasks/YYYY-MM-DD-[feature-name]-frontend-tasks.json`
8. Write backend file to `.aimi/tasks/YYYY-MM-DD-[feature-name]-backend-tasks.json`

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
3. Derive branchName with `-frontend` suffix: `type/[feature]-frontend`
4. Write single file to `.aimi/tasks/YYYY-MM-DD-[feature-name]-frontend-tasks.json`

### When `implementationScope` is unset (legacy):

Standard single-file output to `.aimi/tasks/YYYY-MM-DD-[feature-name]-tasks.json`.

### Derive Metadata (all modes)

- **title**: Conventional format — `<type>: <Descriptive Name>`
- **type**: `feat`, `ref`, `bug`, or `chore`
- **branchName**: Kebab-case, prefixed with type. For split files: `type/[feature]-frontend` and `type/[feature]-backend`
- **createdAt**: Today's date (YYYY-MM-DD)
- **planPath**: Always `null`
- **brainstormPath**: Path to brainstorm if one was used, otherwise omit
- **researchDepth**: Value computed in Phase 1.5 (`skip`, `quick`, `standard`, `deep`), or omit if not computed
- **Story IDs**: Must use `US-NNN` zero-padded format (`US-001`, `US-002`, ...) — never `US-1`, `story-1`, `S1`, or any other format

### Derive Filename

- Full-stack: `.aimi/tasks/YYYY-MM-DD-[feature-name]-frontend-tasks.json` and `.aimi/tasks/YYYY-MM-DD-[feature-name]-backend-tasks.json`
- Frontend-only: `.aimi/tasks/YYYY-MM-DD-[feature-name]-frontend-tasks.json`
- Legacy (no scope): `.aimi/tasks/YYYY-MM-DD-[feature-name]-tasks.json`

Strip type prefix, kebab-case the descriptive name, add date prefix and appropriate suffix.

### Write File

```bash
mkdir -p .aimi/tasks
```

Use the Write tool to save the JSON file(s). Validate JSON is well-formed before writing.

### Phase 4.5: Post-Generation Validation

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
2. Fix the offending story IDs, `dependsOn` references, dependency cycles, or `project` fields
3. Re-write the tasks.json file using the Write tool
4. Re-run all validations until they pass

Do **not** proceed to the report step until all validations succeed.

### Output Report

After writing, report:

```
Tasks generated successfully!

Tasks: .aimi/tasks/[filename(s)].json
Stories: [N] total ([X] frontend, [Y] backend — if split)
Schema: 3.2
[If brainstorm used]: Context: .aimi/brainstorms/[brainstorm-file]
[If gaps found]: Gaps identified: [N] (captured as criteria/notes)
[If 10+ stories]: Warning: [N] stories generated. Consider splitting for parallel work.
Waves: [N] total
[If gates found]: Gates: [N] (verify: [X], decision: [Y], action: [Z])
[If frontend-only]: Backend spec: [N] endpoints, [M] data models, [P] business rules
```
