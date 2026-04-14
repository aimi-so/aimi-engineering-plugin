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

Follow the 4-layer resolution strategy from `references/cli-path-resolution.md` to set `$AIMI_CLI`. Each layer is a separate Bash call:

**Layer 0 — AIMI_PLUGIN_DIR override:**
```bash
if [ -n "$AIMI_PLUGIN_DIR" ] && [ "${AIMI_PLUGIN_DIR#/}" != "$AIMI_PLUGIN_DIR" ] && [ -d "$AIMI_PLUGIN_DIR" ] && [ -x "$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh" ]; then AIMI_CLI="$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh"; fi
```

**Layer 1 — Global cache:**
```bash
if [ -z "$AIMI_CLI" ]; then AIMI_CLI=$(cat ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path 2>/dev/null); fi
```

```bash
if [ -n "$AIMI_CLI" ] && [ ! -x "$AIMI_CLI" ]; then AIMI_CLI=""; fi
```

**Layer 2 — Glob fallback (zsh-safe):**
```bash
if [ -z "$AIMI_CLI" ]; then AIMI_CLI=$(bash -c 'ls ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1'); fi
```

```bash
if [ -n "$AIMI_CLI" ]; then printf '%s\n' "$AIMI_CLI" > "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path.tmp" && mv "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path.tmp" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" && chmod 600 "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path"; fi
```

**Layer 3 — Per-project fallback:**
```bash
if [ -z "$AIMI_CLI" ] && [ -f .aimi/cli-path ] && [ -x "$(cat .aimi/cli-path)" ]; then AIMI_CLI=$(cat .aimi/cli-path); fi
```

If `$AIMI_CLI` is still empty, report error and STOP.

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

### Derive Metadata

- **title**: `<type>: <Descriptive Name>`
- **type**: `feat`, `ref`, `bug`, or `chore`
- **branchName**: Kebab-case, prefixed with type — e.g., `feat/add-user-auth`
- **createdAt**: Today's date (YYYY-MM-DD)
- **planPath**: Always `null`
- **brainstormPath**: Path to brainstorm if one was used, otherwise omit
- **researchDepth**: Value computed in Phase 1.5 (`skip`, `quick`, `standard`, `deep`), or omit if not computed
- **maxConcurrency**: Default `4`. Set to `1` for strictly sequential execution.
- **frontendOnly / backendSpec**: If `implementationScope` was set in Phase 0, include `"frontendOnly": true` when `"frontend-only"`, or `"backendSpec": true` when `"full-stack"`.

### Derive Filename

```
.aimi/tasks/YYYY-MM-DD-[feature-name]-tasks.json
```

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
    "maxConcurrency": "number (optional, default 4)"
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

### Validate Story Content

```bash
$AIMI_CLI validate-stories
```

**If any validation fails (non-zero exit):**
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
