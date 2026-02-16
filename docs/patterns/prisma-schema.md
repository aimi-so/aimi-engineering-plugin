---
name: prisma_schema
keywords: [prisma, schema, model, migration, database, table, column, field, relation, enum]
file_patterns: ["prisma/schema.prisma", "*.prisma", "prisma/*"]
---

# Prisma Schema Changes

Use this pattern when adding or modifying database models, fields, relations, or running migrations with Prisma.

## Steps Template

1. Read prisma/schema.prisma to understand existing models and relations
2. Add/modify the required model with appropriate field types
3. Add necessary relations to existing models (if applicable)
4. Run: npx prisma generate
5. Run: npx prisma migrate dev --name {migration_name}
6. Verify typecheck passes with: npx tsc --noEmit

## Relevant Files

- prisma/schema.prisma - Main schema file
- src/lib/db.ts - Database client (or similar)
- prisma/migrations/ - Existing migrations for reference

## Gotchas

- **Check existing relations** before adding new ones to avoid conflicts
- **Use @default(autoincrement())** for ID fields unless using UUIDs
- **Add indexes** for frequently queried fields: `@@index([fieldName])`
- **Enum changes** require careful migration handling - may need manual SQL
- **Relation naming** should be explicit when multiple relations exist between same models
- **Optional fields** need `?` suffix: `email String?`
- **Default values** for new required fields when table has data: `@default("value")`
- **Cascade deletes** must be explicit: `onDelete: Cascade`
