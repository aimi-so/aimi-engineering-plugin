# Pattern Library

The pattern library contains workflow templates for common task types. These patterns are used by `/aimi:plan-to-tasks` to generate task-specific execution steps.

## How Patterns Are Used

1. **At plan-to-tasks time:** Each story is analyzed for keywords and file patterns
2. **Pattern matching:** Stories are matched against pattern files using keywords and file_patterns
3. **Step generation:** Matched patterns provide step templates that are interpolated with story-specific values
4. **Fallback:** If no pattern matches, LLM inference generates domain-aware steps

## Pattern File Format

Each pattern is a markdown file with YAML frontmatter.

### Frontmatter Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | Yes | Unique identifier in snake_case (becomes `taskType`) |
| `keywords` | array | Yes | Words that trigger this pattern when found in story title/description |
| `file_patterns` | array | Yes | File path patterns that trigger this pattern |

### Markdown Body Sections

| Section | Required | Description |
|---------|----------|-------------|
| `## Steps Template` | Yes | Numbered list of execution steps |
| `## Relevant Files` | Yes | Common files to read for this task type |
| `## Gotchas` | No | Common pitfalls and things to watch for |

## Example Pattern

```markdown
---
name: prisma_schema
keywords: [prisma, schema, model, migration, database, table, column]
file_patterns: ["prisma/schema.prisma", "*.prisma"]
---

# Prisma Schema Changes

## Steps Template

1. Read prisma/schema.prisma to understand existing models and relations
2. Add/modify the required model with appropriate field types
3. Add necessary relations to existing models
4. Run: npx prisma generate
5. Run: npx prisma migrate dev --name {migration_name}
6. Verify typecheck passes with: npx tsc --noEmit

## Relevant Files

- prisma/schema.prisma
- src/lib/db.ts (or db client location)

## Gotchas

- Always check for existing relations before adding new ones
- Use @default(autoincrement()) for ID fields
- Consider adding indexes for frequently queried fields
- Enum changes require careful migration handling
```

## Pattern Matching Algorithm

1. **Extract keywords** from story title and description
2. **For each pattern file:**
   - Check if any `keywords` appear in story content
   - Check if any `file_patterns` match files mentioned in story
3. **Score matches** by number of keyword/pattern hits
4. **Select best match** (highest score wins)
5. **If no match:** Fall back to LLM inference

## Creating New Patterns

1. Create a new `.md` file in this directory
2. Add YAML frontmatter with `name`, `keywords`, `file_patterns`
3. Add `## Steps Template` with numbered steps
4. Add `## Relevant Files` listing common files
5. Optionally add `## Gotchas` with pitfalls

### Step Template Guidelines

- Steps should be **actionable and specific**
- Include **tool commands** where appropriate (e.g., "Run: npm test")
- Use **placeholders** for story-specific values: `{migration_name}`, `{component_name}`
- Keep steps **sequential** (order matters)
- Final step should **verify** the work (typecheck, test, etc.)
- Maximum **10 steps** per pattern

### Keyword Guidelines

- Include **technology names** (prisma, react, next)
- Include **action verbs** (create, add, update, migrate)
- Include **domain terms** (schema, component, route, endpoint)
- Be **specific** to avoid false matches

## Available Patterns

| Pattern | Task Type | Description |
|---------|-----------|-------------|
| [prisma-schema.md](./prisma-schema.md) | `prisma_schema` | Database schema changes with Prisma |
| [server-action.md](./server-action.md) | `server_action` | Next.js server actions |
| [react-component.md](./react-component.md) | `react_component` | React component creation |
| [api-route.md](./api-route.md) | `api_route` | API endpoint implementation |
