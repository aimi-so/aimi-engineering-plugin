# Task Schema

All execution state lives in one file: `.aimi/tasks/YYYY-MM-DD-[feature-name]-tasks.json`. There is no separate progress file — status is tracked in place, on each story.

Current schema version: **3.3**.

---

## Shape

```json
{
  "schemaVersion": "3.3",
  "metadata": {
    "title": "feat: Add user authentication",
    "type": "feat",
    "branchName": "feat/user-auth",
    "createdAt": "2026-02-16",
    "planPath": null,
    "maxConcurrency": 20,
    "execution": "container"
  },
  "userStories": [
    {
      "id": "US-001",
      "title": "Add user database schema",
      "description": "As a developer, I need the user table schema",
      "acceptanceCriteria": [
        "Users table has email, password_hash, created_at columns",
        "Email column has unique constraint",
        "Typecheck passes"
      ],
      "priority": 1,
      "status": "pending",
      "dependsOn": [],
      "notes": ""
    }
  ]
}
```

---

## Root fields

| Field | Type | Description |
|-------|------|-------------|
| `schemaVersion` | string | Currently `"3.3"` |
| `metadata` | object | Feature-level information |
| `userStories` | array | The stories to execute |

## Metadata fields

| Field | Type | Description |
|-------|------|-------------|
| `title` | string | Feature title, with a type prefix |
| `type` | string | One of `feat`, `ref`, `bug`, `chore` |
| `branchName` | string | Git branch for this feature |
| `createdAt` | string | Creation date, `YYYY-MM-DD` |
| `planPath` | string | Path to a source plan file, when one exists |
| `brainstormPath` | string | Optional — path to the brainstorm that produced this |
| `maxConcurrency` | number | Maximum parallel workers. Default 20 |
| `execution` | string | `"container"` or `"inline"`. Absent means inline |
| `splitGroup` | object | Present only on per-project split files. See below |

### `splitGroup`

When a plan spans two or more repositories, `story-merge --split full-stack` writes one tasks file per repository, and each carries this marker:

| Field | Type | Description |
|-------|------|-------------|
| `project` | string | The repository this file belongs to |
| `index` | number | Position in the group, 1-based |
| `total` | number | How many files the group has |
| `siblings` | array | Paths of the other files in the group |

`/aimi:execute` detects a split by reading this marker, not by matching filenames. Files written before this existed have no `splitGroup` key and still execute through the older frontend/backend naming rule.

## Story fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | `US-001`, `US-002`, and so on |
| `title` | string | Short title |
| `description` | string | User-story format |
| `acceptanceCriteria` | array | What must be true for this to count as done |
| `priority` | number | Tiebreaker between stories at the same dependency depth |
| `status` | string | `pending`, `in_progress`, `completed`, `failed`, or `skipped` |
| `dependsOn` | array | Story ids that must finish first |
| `notes` | string | Error details or learnings |
| `project` | string | Optional — path to the target repository, for multi-repo runs |

### Field limits

Validation rejects anything over these lengths:

| Field | Maximum |
|-------|---------|
| `title` | 200 characters |
| `description` | 500 characters |
| Each acceptance criterion | 5000 characters |

---

## Sizing a story

Each story must be completable in **one agent iteration** — one context window. That constraint is what makes parallel execution work.

**Right-sized:**

- Add a database column
- Create a UI component
- Implement a server action
- Add an API endpoint

**Too big — split these:**

- "Build entire dashboard"
- "Add full authentication"
- "Create complete checkout flow"

---

## Ordering

Stories are ordered by dependency, not by a fixed layer sequence. Priority breaks ties between stories that could otherwise start at the same time.

| Priority | Kind | Examples |
|----------|------|----------|
| 1 | Schema and database | Migrations, models |
| 2 | Backend logic | Server actions, services |
| 3 | UI components | Forms, buttons, pages |
| 4 | Aggregation | Dashboards, summaries |

Note this is a tiebreaker, not the decomposition rule. Stories themselves are cut as vertical slices — each one crosses whatever layers it needs to deliver something visible.
