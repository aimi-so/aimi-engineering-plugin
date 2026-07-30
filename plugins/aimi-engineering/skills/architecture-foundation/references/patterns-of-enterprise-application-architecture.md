# Patterns of Enterprise Application Architecture — Deep Reference

Adapted from Martin Fowler's *Patterns of Enterprise Application
Architecture*, via the `agent-rules-books` mini-guide
(`patterns-of-enterprise-application-architecture.mini.md`), Copyright (c)
2026 Maciej Ciemborowicz, MIT License. Rewritten for this skill's
foundation-proposal purpose — not a verbatim reproduction. See
`../NOTICE.md` for the full license text.

Use this file when a foundation proposal must choose an enterprise-shaped
pattern that Clean Architecture and DDD leave open: how business logic is
organized when it is not yet complex enough for a full Domain Model, how
persistence is mapped, how transactions and concurrency are owned, and how
presentation, session state, and remote boundaries are structured.

## Choosing the Business Logic Pattern

Pick by force, not by habit or framework default:

- **Transaction Script** — short, independent, simple flows with little
  shared logic. Fine for early-stage or low-complexity subdomains.
- **Table Module** — one class per database table, organizing set-based
  logic. Appropriate when the domain is genuinely table-shaped.
- **Domain Model** — significant rules, invariants, identity, lifecycle, or
  collaboration between objects. This is where Clean Architecture/DDD
  tactical patterns apply.

Escalate from Transaction Script/Table Module to Domain Model when
duplication, lifecycle complexity, or invariant enforcement starts growing —
do not default to Domain Model everywhere regardless of actual complexity,
and do not stay on Transaction Script once duplicated business rules start
accumulating across scripts.

## Service Layer

Define an explicit Service Layer for application operations: it coordinates
use cases, owns transaction boundaries and orchestration, and exposes an
application-oriented API. It should not silently absorb all domain logic by
default — that logic belongs in the Domain Model (or Transaction
Script/Table Module, per the choice above), not in the Service Layer itself.

## Remote Boundaries: Facade and DTOs

At any remote or cross-process boundary, use a Remote Facade plus Data
Transfer Objects (DTOs) to make coarse-grained operations, batching, and
translation explicit. A DTO is a transport structure, not a domain model —
do not let a DTO's shape leak backward into the domain, and do not expose
fine-grained domain objects directly across a remote boundary (each remote
call has real latency and failure cost; batch accordingly).

## Persistence Patterns

Choose deliberately based on force, not convenience:

- **Repository** — speaks domain terms, hides query/mapping/storage
  details. Preferred whenever the Domain Model pattern is in play (see
  `domain-driven-design.md`).
- **Data Mapper** — keeps SQL and record formats out of domain objects
  entirely; the domain object does not know it is persisted.
- **Gateway** — centralizes access to a record or table for simpler cases
  that do not need a full Repository/Mapper split.
- **Active Record** — acceptable only for simple domains where persistence
  coupling to the domain object is an acceptable tradeoff; the domain
  object embeds its own persistence logic.

Alongside these: **Identity Map** ensures one in-memory object per identity
per scope (preventing duplicate, diverging copies of the same conceptual
record); **Unit of Work** tracks changes and commits one logical transaction
as a whole; **Lazy Load** defers fetching related data — use it only where
hidden database or remote round-trips will not silently surprise a loop or
serializer with N+1 calls.

## Concurrency and Transactions

Design concurrency and transaction ownership explicitly in the application
workflow, not as an incidental side effect of framework defaults:

- **Optimistic locking** — detect conflicts at write time and surface merge
  semantics to the caller; the default choice absent strong contention.
- **Pessimistic locking** — requires justified, real contention; do not
  reach for it by default.
- Keep transactions short. Remote calls usually sit outside a transaction's
  span — do not hold a database transaction open across a network call.
  Transaction ownership must be visible, not hidden inside a helper
  function several layers deep.
- **Coarse-grained/offline locks** — use only when preserving a user-level,
  multi-request edit session, and only when ownership, contention, and
  stale-lock cleanup remain diagnosable.

## Presentation and Session State

Keep presentation code focused on input handling, rendering, routing,
formatting, pagination, and UI state — business rules stay out of
controllers, views, templates, and presentation-layer models (this mirrors
Clean Architecture's "treat the web as a detail," see
`clean-architecture.md`).

Choose session-state storage (client, server, or database) deliberately,
accounting for integrity, security, horizontal scaling, cleanup, durability,
and database load — an unexamined default here tends to surface as a scaling
or data-integrity problem much later.

## Integration Boundaries

Access external systems through explicit boundaries; translate partner
formats into internal domain concepts at that boundary rather than letting
vendor payloads or third-party serialization shape internal design (this
mirrors DDD's Anticorruption Layer — see `domain-driven-design.md` and
`domain-driven-design-distilled.md`).

## Base Patterns, Used for Concrete Pressure Only

Reach for these only when a real force justifies them, not preemptively:
Gateway (external resource access), Mapper (keeping two independent sides
decoupled), Layer Supertype (real shared behavior across a layer), Separated
Interface (breaking an unwanted dependency), Registry (controlled access to
a well-known object), Value Object / Money (value semantics — overlaps with
DDD's Value Object), Special Case (repeated null/default-handling logic),
Plugin (runtime extension point), Service Stub (a substitute for a remote
service in tests), Record Set (natural tabular interchange).

## Trigger Rules — Enterprise-Shape Review Blockers

- Domain behavior appearing in controllers, views, SQL scripts, triggers,
  DTOs, or vendor-payload adapters → move it to the layer that should own it.
- One class or layer coordinating rendering, validation, SQL, transactions,
  domain rules, and external calls at once → split by responsibility before
  adding another pattern on top.
- A Transaction Script accumulating duplicated decisions or lifecycle rules
  → revisit whether Domain Model has become the better fit.
- A "repository" that is really generic CRUD, or a service that only
  forwards to persistence → check whether the ORM or database schema has
  quietly taken over the design.
- Lazy loading, duplicate in-memory identities, or ad hoc saves happening
  inside one logical unit of work → define identity scope, Unit of Work,
  and loading behavior explicitly before continuing.
- A layer that exists only to forward calls, or a controller that owns the
  entire enterprise workflow → treat as a review blocker, not a stylistic
  nit.

## Review Checklist

- Are presentation, workflow, domain, persistence, transaction, concurrency,
  integration, and session-state responsibilities separated intentionally?
- Does the business-logic pattern (Transaction Script / Table Module /
  Domain Model) match actual complexity, not habit or framework shape?
- Is transaction ownership explicit, kept short, and out of hidden helpers
  or remote-call spans?
- Are remote/integration boundaries coarse-grained, translated, and
  failure-aware?
- Is session state owned, secured, and cleaned up rather than an
  unexamined framework default?
