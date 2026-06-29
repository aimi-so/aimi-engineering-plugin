---
description: "Use during migration checks to determine whether target functionality already exists by tracing data-flow signals instead of relying on legacy-name grep."
---

# Migration Data-Flow Signals (canonical)

Single source of truth for "does the target already have X?" during a **migration** task. Referenced by `aimi-codebase-researcher` (Migration-aware existence checks) and `aimi-scope-negative-verifier`. When you tune this doctrine, edit it **here** — both agents link to this file rather than restating it.

## Principle

Across a migration boundary only the **external contract** (API endpoint, event name, user-visible behavior, GraphQL schema) is preserved. Internal symbols — class names, module paths, function names — are typically renamed or restructured. **A legacy-name grep that returns zero results therefore proves nothing**: the feature may exist under a new name.

**Never conclude "absent / not yet migrated" from a legacy-symbol grep alone.** Determine existence by data flow and callers instead.

## The four signals

1. **Row writes (persistence writes)** — search for calls that would record the feature's data: ORM patterns (`repository.create`, `new Model(`, `Model.create`, `.save()`, `.insert(`, `create_or_update`, `upsert`) or raw SQL (`INSERT INTO <table>`, `create table <table>`). Scope Grep to repositories, models, services, and mutation handlers.
2. **Persisted collection / table** — confirm the schema artifact: migration files, table definitions, ActiveRecord / Mongoose / Prisma models. Search the table name, collection name, or domain noun in migration and model directories.
3. **Triggering endpoint / mutation** — locate the HTTP route, GraphQL mutation, gRPC handler, or background-job entry point that activates the code path. Search routes, controllers, resolvers, and job classes by domain noun, resource name, or HTTP verb+path.
4. **Callers of the legacy symbol** (only when a legacy name is known) — follow every callsite of the old symbol; if callers were themselves renamed, trace the chain until the data-flow boundary is confirmed present or confirmed absent. Zero callsites is consistent with the negative but does **not** confirm it (callers may have been renamed) — Signals 1–3 are still required.

## Conclusion rule

Only conclude the feature is **not migrated** after all four signals are checked **and** at least the **persistence layer** and the **triggering entry point** are confirmed absent. If either is present, the feature exists (possibly under a new name) or is partially migrated.
