---
name: aimi:brainstorm
description: Explore ideas through guided brainstorming with batched questions and codebase research
argument-hint: "[feature description]"
---

# Aimi Brainstorm

Clarify **WHAT** to build through collaborative dialogue before planning **HOW** to build it.

**Process knowledge:** Load the `brainstorm` skill for detailed question techniques, response parsing, and document template.

## Feature Description

<feature_description> $ARGUMENTS </feature_description>

**If the feature description above is empty, ask the user:** "What would you like to explore? Describe the feature, problem, or improvement you're thinking about."

Do not proceed until you have a feature description from the user.

## Phase 0: Assess Requirements Clarity

Evaluate whether brainstorming is needed based on the feature description.

**Clear requirements signals:**
- Specific acceptance criteria provided
- Referenced existing patterns to follow
- Described exact expected behavior
- Constrained, well-defined scope

**If requirements are already clear:**
Use **AskUserQuestion** to suggest: "Your requirements seem detailed enough to proceed directly to planning. Should I run `/aimi:plan` instead, or would you like to explore the idea further?"

**If unclear or vague:** proceed to Phase 1.

## Phase 1: Codebase Research

Run a lightweight research scan to understand existing patterns:

```
Task subagent_type="aimi-engineering:research:aimi-codebase-researcher"
  prompt: "Understand existing patterns related to: [feature description].
           Look for: similar features, established patterns, CLAUDE.md guidance,
           relevant file paths, technology choices."
```

If the research agent fails, proceed without codebase context — questions will be generic instead of contextual.

## Phase 2: Batched Questions

Using the user's feature description and research findings, generate **3-5 batched multiple-choice questions**.

### Question Generation Rules

- Questions are informed by research findings when available (contextual options)
- Fall back to generic topic-based questions when research is empty
- Cover topic categories: Purpose, Users, Constraints, Success, Edge Cases, Existing Patterns
- See the `brainstorm` skill for question format, response parsing, and topic categories

### Present Questions

Format questions as numbered items with lettered options:

```
Based on the codebase research and your description, I have a few questions:

1. [Question informed by research or topic category]
   A. [Option]
   B. [Option]
   C. [Option]
   D. Other: [please specify]

2. [Question]
   A. [Option]
   ...

You can answer with shorthand like "1A, 2C, 3B" or respond in your own words.
```

### Adaptive Rounds

After each response, assess which topic categories remain unaddressed:

- **If all key topics covered** OR **user says "proceed"/"let's move on"** → advance to Phase 3
- **If topics remain uncovered** AND **under 4 rounds** → generate follow-up batch targeting uncovered topics
- **If 4 rounds completed** → advance to Phase 3 regardless

## Phase 3: Explore Approaches (Conditional)

**Only propose approaches when research + answers reveal multiple genuinely valid paths.** Skip this phase when there is one obvious direction.

If proposing approaches, present 2-3 with:
- Brief description (2-3 sentences)
- Pros and cons
- When it's best suited

Lead with a recommendation and explain why. Apply YAGNI — prefer simpler solutions.

Use **AskUserQuestion** to ask which approach the user prefers.

## Phase 4: Capture the Design

### Derive Filename

From the feature description, derive a topic slug:
1. Convert to lowercase
2. Replace spaces and special characters with hyphens
3. Remove consecutive hyphens
4. Truncate to 50 characters
5. Remove trailing hyphens

**Filename:** `.aimi/brainstorms/YYYY-MM-DD-<topic-slug>-brainstorm.md`

### Handle Filename Collision

Check if the target file already exists:

```bash
ls .aimi/brainstorms/YYYY-MM-DD-<topic-slug>-brainstorm.md 2>/dev/null
```

If it exists, append a counter: `-2`, `-3`, etc.
Example: `2026-02-27-user-auth-brainstorm-2.md`

### Create Directory

```bash
mkdir -p .aimi/brainstorms
```

### Write Document

Use the design document template from the `brainstorm` skill:

```markdown
---
date: YYYY-MM-DD
topic: <topic-slug>
---

# <Topic Title>

## What We're Building
[Concise description from brainstorm dialogue]

## Why This Approach
[Approaches considered, rationale for choice — or "Single obvious approach" if Phase 3 was skipped]

## Key Decisions
- [Decision 1]: [Rationale]
- [Decision 2]: [Rationale]

## Open Questions
- [Any unresolved questions]

## Next Steps
> Run `/aimi:plan` to generate implementation tasks
```

### Resolve Open Questions

**Before proceeding to handoff**, check the Open Questions section. If there are unresolved questions:

1. Ask the user about each open question using AskUserQuestion
2. Move resolved questions to a "Resolved Questions" section
3. Only proceed when Open Questions is empty or user explicitly defers them

## Phase 5: Handoff

Display the brainstorm summary and next steps:

```
Brainstorm complete!

Document: .aimi/brainstorms/[filename].md

Key decisions:
- [Decision 1]
- [Decision 2]

Next steps:
1. **Run `/aimi:plan`** - Create implementation plan and tasks.json
2. **Continue brainstorming** - Run `/aimi:brainstorm` to explore further
3. **Review document** - Open the brainstorm file to refine manually
4. **Done for now** - Return later
```

**If user selects "Continue brainstorming":** Return to Phase 2 with the existing document as context. Generate targeted follow-up questions about areas not yet explored.

**If user selects "Done for now":** End the session. Display:
```
Brainstorm saved. To resume later: `/aimi:brainstorm [topic]`
To start planning: `/aimi:plan`
```

## Error Handling

| Phase | Failure | Action |
|-------|---------|--------|
| Pre-Phase 0 | No feature description | Prompt user for input |
| Phase 1 | Research agent fails or times out | Proceed without codebase context; questions will be generic |
| Phase 1 | Greenfield project (no codebase) | Proceed with generic topic-based questions |
| Phase 4 | `.aimi/brainstorms/` directory creation fails | Report error with path |
| Phase 4 | File write fails | Report error; no document saved |
| Phase 4 | Filename collision | Append counter (-2, -3) to filename |

## Important Guidelines

- **Stay focused on WHAT, not HOW** — implementation details belong in the plan
- **Apply YAGNI** — prefer simpler approaches
- **Keep outputs concise** — 200-300 words per section max
- **Never code** — just explore and document decisions

