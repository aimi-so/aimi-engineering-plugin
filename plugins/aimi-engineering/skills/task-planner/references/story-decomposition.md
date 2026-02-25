# Story Decomposition Rules

## The Number One Rule: Story Size

**Each story must be completable in ONE agent iteration (one context window).**

The agent spawns fresh per iteration with no memory of previous work. If a story is too big, the agent runs out of context before finishing.

### Right-sized stories:
- Add a database column and migration
- Add a UI component to an existing page
- Update a server action with new logic
- Add a filter dropdown to a list
- Create a new skill file with frontmatter and body
- Update a command file with new flow

### Too big (split these):
- "Build the entire dashboard" → schema, queries, UI components, filters
- "Add authentication" → schema, middleware, login UI, session handling
- "Refactor the API" → one story per endpoint or pattern

**Rule of thumb:** If you cannot describe the change in 2-3 sentences, it is too big.

---

## Adaptive Granularity

Do NOT ask the user for a detail level. Size stories based on detected complexity:

- **Simple feature** (1-3 stories): Coarse stories, each covers a bigger chunk
- **Complex feature** (4-10 stories): Fine-grained, tightly scoped
- **Very complex** (10+ stories): Generate all stories but include warning in report

---

## Layer Ordering

Group requirements by layer and assign priorities in this order:

| Priority Range | Layer | Examples |
|---------------|-------|----------|
| 1-N | Schema/database | Migrations, model changes, seed data |
| N+1-M | Backend/services | Server actions, API routes, business logic |
| M+1-P | UI components | Forms, lists, buttons, modals |
| P+1-Q | Aggregation/dashboards | Summary views, reports, analytics |

Earlier stories must NOT depend on later stories.

---

## Acceptance Criteria Generation

Each criterion must be something the agent can CHECK, not something vague.

### Good criteria (verifiable):
- "Add `status` column to tasks table with default 'pending'"
- "Filter dropdown has options: All, Active, Completed"
- "Clicking delete shows confirmation dialog"
- "SKILL.md is under 300 lines"
- "Typecheck passes"

### Bad criteria (vague):
- "Works correctly"
- "User can do X easily"
- "Good UX"
- "Handles edge cases"

### Mandatory criteria:

**Every story:**
```
"Typecheck passes"
```

**Stories with testable logic:**
```
"Tests pass"
```

**Stories that change UI:**
```
"Verify in browser"
```

---

## Conversion Rules

1. Each requirement becomes one or more JSON stories
2. **IDs**: Sequential — `US-001`, `US-002`, etc.
3. **Priority**: Based on dependency order (lower = executes first)
4. **All stories**: `passes: false` and empty `notes`
5. **branchName**: Derive from feature name, kebab-case, prefixed with type
6. **Always add**: "Typecheck passes" to every story's acceptance criteria

---

## Splitting Large Requirements

If a single requirement is too big for one story, split it:

**Original:**
> "Add user notification system"

**Split into:**
1. US-001: Add notifications table to database
2. US-002: Create notification service for sending
3. US-003: Add notification bell icon to header
4. US-004: Create notification dropdown panel
5. US-005: Add mark-as-read functionality

Each must be independently completable and verifiable.

---

## Input Sanitization

When generating stories from research output and user input:

- **Title**: Strip markdown headers (`#`), limit to 200 characters
- **Description**: Strip code fences, limit to 500 characters
- **Acceptance criteria**: Strip newlines, limit each to 300 characters
- **branchName**: Validate against `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$`

---

## Validation Checklist

Before finalizing stories, verify:

- [ ] Each story is completable in one iteration (small enough)
- [ ] Stories are ordered by dependency (schema → backend → UI)
- [ ] Every story has "Typecheck passes" as criterion
- [ ] UI stories have "Verify in browser" as criterion
- [ ] Acceptance criteria are verifiable (not vague)
- [ ] No story depends on a later story
- [ ] No duplicate priority numbers
- [ ] IDs are sequential (US-001, US-002, ...)
- [ ] Field lengths within limits (title ≤ 200, description ≤ 500, criterion ≤ 300)
- [ ] branchName matches validation regex
