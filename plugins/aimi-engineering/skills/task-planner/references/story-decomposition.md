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

## `dependsOn` Generation Rules

Every v3 story MUST include a `dependsOn` array (string array of story IDs). The planner infers dependencies using two strategies: **layer-based** and **cross-layer**.

### Layer-Based Inference (Same Layer)

Stories within the same layer that touch **independent concerns** have no dependency on each other — their `dependsOn` arrays do NOT reference each other.

**Rule:** Two stories in the same layer are independent when:
- They modify different database tables / columns
- They affect different UI pages or components with no shared state
- They operate on different server actions or API routes

**Example — Two independent schema stories:**
```json
{ "id": "US-001", "title": "Add status column to tasks table", "dependsOn": [], "priority": 1 }
{ "id": "US-002", "title": "Add categories table", "dependsOn": [], "priority": 2 }
```
Both are schema-layer. They touch different tables, so neither depends on the other. They can execute in parallel.

**Example — Two dependent schema stories (same layer, shared concern):**
```json
{ "id": "US-001", "title": "Add categories table", "dependsOn": [], "priority": 1 }
{ "id": "US-002", "title": "Add category_id FK to tasks table", "dependsOn": ["US-001"], "priority": 2 }
```
Both are schema-layer, but US-002 references the table US-001 creates. US-002 depends on US-001.

### Cross-Layer Inference

Stories in a higher layer depend on stories in a lower layer **that they directly consume**.

**Rules:**
1. **Backend depends on Schema**: A server action / API route story depends on every schema story that defines tables, columns, or types it reads or writes.
2. **UI depends on Backend**: A UI component story depends on every backend story that provides the data or actions it calls.
3. **Aggregation depends on UI or Backend**: Dashboard / summary stories depend on the backend queries or UI components they aggregate.
4. **Skip layers when appropriate**: A UI story that reads directly from a new table (no intermediate backend story) depends on the schema story directly.

**Example — Full cross-layer chain:**
```json
{ "id": "US-001", "title": "Add notifications table",          "dependsOn": [],           "priority": 1 }
{ "id": "US-002", "title": "Create sendNotification action",   "dependsOn": ["US-001"],   "priority": 2 }
{ "id": "US-003", "title": "Add notification bell to header",  "dependsOn": ["US-002"],   "priority": 3 }
{ "id": "US-004", "title": "Create notifications dropdown",    "dependsOn": ["US-002"],   "priority": 4 }
{ "id": "US-005", "title": "Add mark-as-read functionality",   "dependsOn": ["US-003", "US-004"], "priority": 5 }
```

- US-002 (backend) depends on US-001 (schema) because it writes to the notifications table.
- US-003 and US-004 (UI) depend on US-002 (backend) because they call the send/fetch actions.
- US-005 (UI) depends on US-003 and US-004 because it extends both components.

### Dependency Inference Checklist

When generating `dependsOn` for a story, ask:

1. Does this story **read from or write to** a table/column created in another story? Add that story ID.
2. Does this story **call a server action or API route** defined in another story? Add that story ID.
3. Does this story **render a component** built in another story? Add that story ID.
4. Does this story **extend or modify** something created in another story? Add that story ID.
5. If none of the above apply, `dependsOn: []`.

### Priority as Tiebreaker

With v3, `priority` no longer drives execution order alone. Instead:

- **`dependsOn`** determines **structural ordering** — what must complete before a story can start.
- **`priority`** is a **tiebreaker** — when multiple stories are ready (all dependencies satisfied), the one with the lower `priority` value executes first.

**Always assign both fields:**
- `dependsOn`: Inferred from the rules above.
- `priority`: Sequential integers (1, 2, 3, ...) reflecting the intended execution order. Stories in earlier layers get lower priorities. Within the same layer, assign priorities in a logical order (e.g., base table before FK table).

### Parallel Grouping Examples

The dependency graph determines which stories can execute concurrently. Below are common patterns.

**Pattern 1: Independent roots (parallel start)**

When multiple schema stories touch unrelated tables:
```
US-001 (add users table)      dependsOn: []     priority: 1
US-002 (add products table)   dependsOn: []     priority: 2
US-003 (add user CRUD action) dependsOn: [US-001]  priority: 3
US-004 (add product listing)  dependsOn: [US-002]  priority: 4
```
Parallel groups:
- Group 1: US-001, US-002 (both ready immediately)
- Group 2: US-003, US-004 (both ready after their respective deps complete)

**Pattern 2: Diamond convergence**

```
US-001 (schema)             dependsOn: []              priority: 1
US-002 (backend: read)      dependsOn: [US-001]        priority: 2
US-003 (backend: write)     dependsOn: [US-001]        priority: 3
US-004 (UI: dashboard)      dependsOn: [US-002, US-003]  priority: 4
```
Parallel groups:
- Group 1: US-001
- Group 2: US-002, US-003 (both depend only on US-001)
- Group 3: US-004 (waits for both US-002 and US-003)

**Pattern 3: Fully sequential (no parallelism)**

When every story depends on the previous:
```
US-001  dependsOn: []           priority: 1
US-002  dependsOn: [US-001]     priority: 2
US-003  dependsOn: [US-002]     priority: 3
```
No parallel groups. Stories execute sequentially.

**Pattern 4: Wide parallel (plugin/config type tasks)**

```
US-001 (add agent file)    dependsOn: []  priority: 1
US-002 (add command file)  dependsOn: []  priority: 2
US-003 (add skill dir)     dependsOn: []  priority: 3
US-004 (update plugin.json) dependsOn: [US-001, US-002, US-003]  priority: 4
```
Parallel groups:
- Group 1: US-001, US-002, US-003 (all independent)
- Group 2: US-004 (waits for all three)

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
4. **All stories**: `status: "pending"` and empty `notes`
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

### Sizing and Content
- [ ] Each story is completable in one iteration (small enough)
- [ ] Stories are ordered by dependency (schema → backend → UI)
- [ ] Every story has "Typecheck passes" as criterion
- [ ] UI stories have "Verify in browser" as criterion
- [ ] Acceptance criteria are verifiable (not vague)
- [ ] IDs are sequential (US-001, US-002, ...)
- [ ] Field lengths within limits (title ≤ 200, description ≤ 500, criterion ≤ 300)
- [ ] branchName matches validation regex

### Dependency Graph (`dependsOn`)
- [ ] Every story has a `dependsOn` array (even if empty `[]`)
- [ ] No circular dependencies in `dependsOn` (graph must be a DAG)
- [ ] All referenced IDs in `dependsOn` exist as story IDs in the file
- [ ] No self-references (no story lists its own ID in `dependsOn`)
- [ ] Cross-layer dependencies are correct (backend → schema, UI → backend)
- [ ] Same-layer stories with no shared concerns are independent (`dependsOn` does not link them)

### Priority
- [ ] No duplicate priority numbers
- [ ] Priority values are consistent with dependency depth (earlier layers get lower values)
- [ ] Priority serves as tiebreaker only — execution order is driven by `dependsOn`
