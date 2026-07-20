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

> Key fields: `schemaVersion` ("3.3"), `metadata{title,type,branchName,createdAt,planPath(null),researchDepth(optional),maxConcurrency(20),frontendOnly(optional),backendSpec(optional:{endpoints[{method,path,description}],dataModels[{name,fields}],businessRules[string],businessContext(string)})}`, `userStories[]{id(US-NNN),title(≤200),description(≤500),acceptanceCriteria(each≤5000),priority,status("pending"),dependsOn([]),notes,project(optional),wave(computed),tasks[](optional,max50,each≤5000chars),implementation(optional),verification(optional),gate(optional)}`

**Notes:** `planPath` is always `null` (this skill generates tasks.json directly). All stories initialize with `status: "pending"`. `dependsOn` is a string array of story IDs. `maxConcurrency` defaults to `20`.

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

#### Roadmap Materialization (phased features only)

When the loaded brainstorm carries a `phases:` frontmatter block (2+ sanitized phase entries — see `commands/brainstorm.md` "phases frontmatter rules"), materialize `.aimi/tasks/<feature-slug>/roadmap.json` via the `aimi-cli.sh` `roadmap-init` verb before continuing — **never** write it with the Write tool. Sanitize every field and re-derive each phase's `phase-<id>[.<n>]-<slug>` directory segment from the (sanitized) `name`, never trusting the frontmatter's own `slug`; fall back to the bare `phase-<id>` form with a warning if the derived segment fails `^phase-[0-9]+(\.[0-9]+)?(-[a-z0-9][a-z0-9-]*)?$`. First run creates the file; a re-run against an existing `roadmap.json` calls `roadmap-init --sync` to append only phases missing by numeric id, leaving existing status/claim/branch fields byte-for-byte untouched. Absent `phases:` frontmatter (the common case): skip entirely — no folder created, no `roadmap.json` written, flow identical to today. Full field-sanitization, directory-validation, and idempotency/additive-sync rules: [pipeline-phases.md](references/pipeline-phases.md#roadmap-materialization).

#### Rolling-Wave Phase Selection (phased features only)

Runs regardless of whether a brainstorm loaded this session, so a later `/aimi:plan` (or `/aimi:plan --phase <N>`) re-invocation can continue an already-materialized roadmap — auto-selecting and expanding exactly one pending phase per invocation, leaving every other phase outline-only. No `roadmap.json` → completely unaffected. Full rules: `commands/plan.md` "Rolling-Wave Phase Selection".

#### Implementation Scope Detection

After the brainstorm check, determine the implementation scope:

1. **Auto-detect default from brainstorm context** (if a brainstorm was found):
   - If brainstorm text contains signals like `frontend-only`, `mocked data`, or `prototype` → default to option 1
   - If brainstorm text contains signals like `backend`, `API`, `schema`, or `full-stack` → default to option 2

2. **Ask the user** via AskUserQuestion:
   > What type of implementation? (1) frontend prototype with mocked data (2) full-stack implementation (frontend + backend)

   Present the auto-detected default if one was determined.

3. **Store the result** as `implementationScope: "frontend-only" | "full-stack"` for use in Phase 4 metadata.

#### Scope-Context Classification (Inline Fallback)

When no brainstorm supplied a `phases:` cut and no roadmap is already being continued from Rolling-Wave Phase Selection above, classify the feature description into scope contexts using the same shared reference `/aimi:brainstorm`'s roadmap-definition gate applies — [commands/references/scope-contexts.md](../../commands/references/scope-contexts.md) — so a feature gets the same phase cut regardless of which command runs the classification. Zero or one scope context: fall straight through unchanged, no gate. Two or more: gated phase-cut proposal, materialized via the same `roadmap-init` path Roadmap Materialization above uses, then handed off to Rolling-Wave Phase Selection for phase-1-only expansion. Full gate mechanics: `commands/plan.md` "Scope-Context Classification (Inline Fallback)".

### Resolve Agent Models

Follow the **Resolve Agent Models** section of `commands/references/cli-path-resolution.md` to populate `AGENT_MODELS` (JSON map of category→model). Re-read `$AIMI_CLI` from cache in the same Bash call. When resolution fails, treat every category as `"inherit"` and continue.

### Phase 1: Local Research (Parallel)

**Prepare research directory:**
```bash
mkdir -p .aimi/research
```

**Derive topic slug** from the feature description: lowercase, replace spaces/special chars with hyphens, remove consecutive hyphens, truncate to 50 chars, remove trailing hyphens. Store as `topicSlug`.

**Generate run discriminator:** Generate a single timestamp for this run (prevents same-day re-runs from overwriting prior research files):
```bash
RUN_TS=$(date +%H%M%S)
```
Store `RUN_TS` and use it in all research agent prompts for this run.

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
  [model: <AGENT_MODELS.research when not "inherit">]
  prompt: "[feature description + brainstorm context + discovered repos]
           topicSlug: [topicSlug]
           outputPath: .aimi/research/YYYY-MM-DD-[topicSlug]-[RUN_TS]-codebase.md"

Task subagent_type="aimi-engineering:research:aimi-learnings-researcher"
  [model: <AGENT_MODELS.research when not "inherit">]
  prompt: "[feature description]
           topicSlug: [topicSlug]
           outputPath: .aimi/research/YYYY-MM-DD-[topicSlug]-[RUN_TS]-learnings.md"
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
  [model: <AGENT_MODELS.research when not "inherit">]
  prompt: "[feature description]
           researchDepth: [computed researchDepth from Phase 1.5]
           topicSlug: [topicSlug]
           outputPath: .aimi/research/YYYY-MM-DD-[topicSlug]-[RUN_TS]-best-practices.md"

Task subagent_type="aimi-engineering:research:aimi-framework-docs-researcher"
  [model: <AGENT_MODELS.research when not "inherit">]
  prompt: "[feature description]
           researchDepth: [computed researchDepth from Phase 1.5]
           topicSlug: [topicSlug]
           outputPath: .aimi/research/YYYY-MM-DD-[topicSlug]-[RUN_TS]-framework-docs.md"
```

### Phase 1.6: Research Consolidation

Consume researcher agent **summary returns** (brief outputs from Task calls) -- do NOT re-read `.aimi/research/` files unless a summary is insufficient for a planning decision.

> **Fallback:** If a summary lacks detail for a specific planning decision, read the corresponding `.aimi/research/YYYY-MM-DD-[topicSlug]-[RUN_TS]-*.md` file on demand.

Merge findings into a structured consolidation with these sections:

1. **Key Patterns** -- Architectural patterns, conventions, and recurring structures found in the codebase
2. **Conflicts** -- Contradictions between sources (e.g., CLAUDE.md says X but codebase does Y), unresolved trade-offs
3. **File References** -- Concrete file paths relevant to the feature, grouped by concern (schema, backend, UI, config)
4. **Learnings** -- Institutional knowledge from `.aimi/solutions/`: gotchas, past mistakes, proven approaches
5. **External Insights** -- Best practices and framework guidance from external research (empty if Phase 1.5b was skipped)

### Phase 2: Spec Analysis

```
Task subagent_type="aimi-engineering:workflow:aimi-spec-flow-analyzer"
  [model: <AGENT_MODELS.workflow when not "inherit">]
  prompt: "[feature description + consolidated research]"
```

Incorporate identified gaps as acceptance criteria or story notes.

### Phase 3: Story Decomposition

1. Extract requirements from research + spec-flow output
2. **Group by user-facing capability (vertical slices).** Each story bundles all layers (schema + backend + UI) needed to deliver one complete, user-observable outcome. Do NOT create horizontal layer-only stories. If a slice exceeds ~10 files or ~4 architectural layers, add to story notes: `Large slice ({n} files across {k} layers). Consider splitting if there's a natural seam, otherwise proceed.` Re-scope any orphan UI (component not wired to real backend) into the slice where that capability is introduced — do NOT use storybook-only or dev-preview-route verification as substitutes.
3. Size check (one context window per story)
4. Order by capability dependency (capabilities that unlock others come first; assign priority numbers)
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
9.5. **Populate `tasks[]` — horizontal mechanical breakdown**: for every story, generate a `tasks` array of 3–15 concrete mechanical sub-steps (each ≤ 5000 chars, max 50, verb-object phrasing). MUST include explicit `"Wire <X> into <Y>"` entries for any file in `implementation.files` that is also listed in another story's `implementation.files` (parent shells, routers, index barrels, MSW handlers, `main.tsx`). Order: creation → integration wiring → local verification. Tasks are planner guidance, not acceptance criteria. Omit the field (do not emit `tasks: []`) when fewer than 3 meaningful steps exist. See `references/task-format-v3.md` for the canonical fixture.
10. **Detect and attach `gate` objects** using heuristics:
    - `verify` gate: OAuth, email, webhooks, payment, external service integration
    - `decision` gate: multiple viable approaches with significant downstream impact
    - `action` gate: external manual action the agent cannot perform
    - Most stories have no gate; only attach when heuristics clearly match
11. Assign IDs in `US-NNN` zero-padded format (`US-001`, `US-002`, ...) — never `US-1`, `story-1`, `S1`, or any other format
12. Write descriptions in user story format: "As a [specific role], I want [feature] so that [benefit]" — role must name the actor, never just "user"
13. Generate verifiable acceptance criteria: every story must include at least one user-observable, end-to-end outcome listed **first**. Mixed mechanical + behavioral criteria are allowed but the user-observable item comes first.
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
6. Derive shared metadata: title, type, createdAt, `schemaVersion: "3.3"`, `planPath: null`, `brainstormPath`, `researchDepth`, `maxConcurrency`
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
4. Derive metadata: title, type, branchName (kebab-case, `-frontend` suffix), createdAt, `schemaVersion: "3.3"`, `planPath: null`, `brainstormPath`, `researchDepth`, `maxConcurrency`
5. For each story: set `status: "pending"`, include `dependsOn`, `wave`, and optional `implementation`, `verification`, `gate` objects

#### When `implementationScope` is unset (legacy):

1. Derive metadata: title, type, branchName (kebab-case), createdAt (today)
2. Set `schemaVersion: "3.3"`, `planPath: null`, `brainstormPath`, `researchDepth`, `maxConcurrency`
3. For each story: set `status: "pending"`, include `dependsOn`, `wave`, and optional `implementation`, `verification`, `gate` objects
4. Write to `.aimi/tasks/YYYY-MM-DD-[feature-name]-tasks.json`

### Phase 4.5: Post-Generation Validation

After writing the tasks.json file(s), validate each generated output independently.

**Step 0 — Resolve CLI Path** (see [cli-path-resolution.md](../../commands/references/cli-path-resolution.md) for full Layer 0–3 strategy).
Each Bash call is an isolated shell — `$AIMI_CLI` is never inherited. Re-read from cache at the top of every Bash call that needs it:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
```

**For split files (full-stack):** run validation on each file separately, using `init-session --file` to target each file:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
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
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
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
