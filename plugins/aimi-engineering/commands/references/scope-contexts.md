# Scope Contexts

Shared reference for cutting a large feature into scope contexts — the phase-level
unit used when a single feature is too large for one flat planning pass. Apply the
rules in this file wherever the command says "identify scope contexts" or "run the
scope-context step."

**Consumed by:** the `/aimi:brainstorm` roadmap-definition step and the `/aimi:plan`
inline scope-context fallback. Both must cut phases identically for the same
feature, regardless of which command runs the step.

## What Is a Scope Context

A scope context is a vertical, user-observable capability: a complete end-to-end
slice of functionality, not a technical layer. "Signup flow" and "payment flow" are
scope contexts; "database layer" and "API layer" are not.

Contrast with a user story: one story is one capability sized to a single agent
iteration (a context window). One scope context is a cluster of stories delivering
one larger vertical capability, sized to roughly one rolling-wave planning pass —
big enough to need its own phase, small enough to plan and demo as a unit before
moving to the next one.

## Cut Criteria

Cut a feature into scope contexts using these criteria, in order:

1. **Coherent** — each context maps to one nameable business capability. If you
   cannot name the capability in a few words ("checkout," "notifications"), it is
   not a valid cut.
2. **Sequential or independent** — contexts either form a clean dependency order
   (a foundation context before the contexts that consume it) or are mutually
   independent. Avoid partial, tangled dependencies between contexts.
3. **One complete, verifiable capability per phase** — each context must be
   independently demoable without waiting on a later phase to finish it.
4. **Split an oversized context only along semantic seams** — e.g. "Payments"
   splits into "Checkout" and "Subscriptions" because those are two distinct
   capabilities, never by size alone.

## The Collapse Rule

When a feature decomposes into exactly one scope context, there are **no phases at
all**. Skip the roadmap/phase machinery entirely and run the feature through the
existing flat pipeline unchanged.

This is distinct from a "1-phase roadmap." A 1-phase roadmap still carries phase
scaffolding (a phase container, a goal, success criteria). The collapse rule means
that scaffolding is never created — the single scope context is the whole feature,
planned exactly as if phases did not exist.

## Shared-Foundation Detection

When an artifact — a table, a service, a shared type, a file — is needed by two or
more scope contexts, it is never duplicated into each consumer's creates list. It is
produced exactly once: either by a dedicated foundation phase that precedes its
consumers, or by whichever consuming phase comes first in dependency order.

Example: if both "Checkout" and "Subscriptions" need a `payment_methods` table,
that table is created once — by a foundation phase, or by whichever of the two
phases runs first — and the other phase declares it as a need, not a create.

## Anti-Patterns

| Anti-pattern | Why it's wrong | Corrective |
|---|---|---|
| Horizontal layer phases (e.g. "Phase 1: all migrations, Phase 2: all endpoints, Phase 3: all UI") | No phase is independently demoable; nothing is user-observable until every phase finishes | Cut by capability instead — each phase ships schema + backend + UI together for one vertical slice |
| Numeric size quotas (splitting to hit a target story or phase count) | Produces contexts with no coherent capability boundary | Cut only where Cut Criteria §1 (coherent) and §4 (semantic seam) apply; let the count fall out of the cuts |
| Phase-count padding (imposing a fixed phase count regardless of actual scope) | Forces artificial splits or merges to match a number chosen in advance | Let the number of phases equal the number of valid scope contexts, including one (see The Collapse Rule) |
| Artificial splits (dividing one coherent capability just to hit a count or size target) | Breaks a single demoable capability across two phases that can't be verified independently | Keep one coherent capability in one phase even if it is larger than other phases |

## Goal and Success Criteria

Each phase's goal must be phrased as an outcome, not a task list.

- Good: "Users receive and can act on in-app notifications."
- Bad: "Build the notification schema and endpoints."

Each phase carries 2 to 5 observable success criteria — things a human can check
against the running app, not internal implementation details.

**Detection heuristic:** a goal that names only technical actions with no
user-facing verb (build, add, migrate, wire up — with no "user can...") is a
horizontal-layer red flag. Re-examine the cut before proceeding.

## Creates/Needs Contracts

Cross-phase contracts name artifacts at the artifact level, using one naming rule
per kind:

| Artifact kind | Naming rule | Example |
|---|---|---|
| Endpoint | `METHOD /path` | `"POST /api/notifications (creates a notification for a user)"` |
| Table | `table_name` | `"notifications (stores per-user notification rows)"` |
| Service | module/class path | `"services/notifications.NotificationService (sends and lists notifications)"` |
| File | relative path | `"components/NotificationBell.tsx (header bell icon with unread badge)"` |

Every entry uses the string format `"<artifact-name> (<one-line description>)"`.

Contracts are checked deterministically, never by LLM judgment alone: a phase's
`creates` entries are verified to exist in code at that phase's close, and a
phase's `needs` entries are checked against prior phases' fulfilled `creates` at
next-phase planning time.

## Coarse File-Area Declaration

Before any story exists, each phase declares a short list of top-level directories
or path globs its stories are expected to touch (e.g. `app/checkout/**`,
`services/payments/`). This declaration is necessarily coarse — directory or glob
level, not individual file paths — because no story has been planned yet.

Use the declaration only for early collision detection between candidate phases
(flagging two phases that claim overlapping areas so the cut can be revisited). It
is not an enforcement mechanism — a phase is not blocked from touching files
outside its declared areas once stories are planned.
