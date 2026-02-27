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

---

## Phase 1: Local Research (Always Runs)

Run two agents **in parallel** using the Task tool:

### Agent 1: aimi-codebase-researcher

```
Task subagent_type="aimi-engineering:research:aimi-codebase-researcher"
  prompt: "Analyze the codebase for patterns relevant to: [feature description].
           Look for: existing patterns, CLAUDE.md guidance, similar features,
           technology familiarity, file structure conventions."
```

**What to extract:** File paths, naming conventions, architectural patterns, relevant existing code.

### Agent 2: aimi-learnings-researcher

```
Task subagent_type="aimi-engineering:research:aimi-learnings-researcher"
  prompt: "Search .aimi/solutions/ for learnings relevant to: [feature description].
           Look for: gotchas, patterns, past solutions, lessons learned."
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

---

## Phase 1.5b: External Research (Conditional)

Only run if Phase 1.5 decides external research is valuable.

Run two agents **in parallel**:

### Agent 3: aimi-best-practices-researcher

```
Task subagent_type="aimi-engineering:research:aimi-best-practices-researcher"
  prompt: "Research current best practices for: [feature description].
           Focus on: industry standards, common patterns, security considerations."
```

### Agent 4: aimi-framework-docs-researcher

```
Task subagent_type="aimi-engineering:research:aimi-framework-docs-researcher"
  prompt: "Research framework documentation for: [feature description].
           Focus on: official docs, API references, version-specific features."
```

### If agents fail

If external research fails (network issues, agent errors):
- Log: "External research unavailable. Proceeding with local context only."
- Continue to Phase 1.6.

---

## Phase 1.6: Research Consolidation

Merge all findings into a structured summary:

1. **Codebase patterns**: Relevant file paths, naming conventions, architectural decisions
2. **Institutional learnings**: Gotchas, proven patterns from `.aimi/solutions/`
3. **External best practices**: Industry standards, security patterns (if researched)
4. **Framework documentation**: API references, version constraints (if researched)
5. **CLAUDE.md conventions**: Project-specific rules and preferences

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
3. Apply sizing rules (one context window per story)
4. Assign priority numbers by dependency order
5. Generate verifiable acceptance criteria per story
6. Run validation checklist

---

## Phase 4: Write tasks.json

### Derive Metadata

- **title**: Conventional format — `<type>: <Descriptive Name>`
- **type**: `feat`, `ref`, `bug`, or `chore`
- **branchName**: Kebab-case, prefixed with type — e.g., `feat/add-user-auth`
- **createdAt**: Today's date (YYYY-MM-DD)
- **planPath**: Always `null`
- **brainstormPath**: Path to brainstorm if one was used, otherwise omit

### Derive Filename

```
.aimi/tasks/YYYY-MM-DD-[feature-name]-tasks.json
```

Strip type prefix, kebab-case the descriptive name, add date prefix and `-tasks.json` suffix.

### Write File

```bash
mkdir -p .aimi/tasks
```

Use the Write tool to save the JSON file. Validate JSON is well-formed before writing.

### Output Report

After writing, report:

```
Tasks generated successfully!

Tasks: .aimi/tasks/[filename].json
Stories: [N] total
Schema: 3.0
[If brainstorm used]: Context: .aimi/brainstorms/[brainstorm-file]
[If gaps found]: Gaps identified: [N] (captured as criteria/notes)
[If 10+ stories]: Warning: [N] stories generated. Consider splitting for parallel work.
```
