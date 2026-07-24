# Domain-Driven Design Distilled — Deep Reference

Adapted from Vaughn Vernon's *Domain-Driven Design Distilled*, via the
`agent-rules-books` mini-guide (`domain-driven-design-distilled.mini.md`),
Copyright (c) 2026 Maciej Ciemborowicz, MIT License. Rewritten for this
skill's foundation-proposal purpose — not a verbatim reproduction. See
`../NOTICE.md` for the full license text.

Use this file when a foundation proposal needs the smallest effective DDD
practice rather than the full ceremony in `domain-driven-design.md` — most
supporting and generic subdomains, and many early-stage products, belong
here rather than under full tactical DDD.

## Scope Before Patterns

Before designing any code: identify the business capability involved,
classify its subdomain as Core, Supporting, or Generic, name its Bounded
Context, and adopt that context's Ubiquitous Language — only after that
should tactical patterns (Entity, Value Object, Aggregate, ...) be chosen,
and only where they earn their cost.

- **Core Domain** gets the most modeling effort and the most experienced
  people.
- **Supporting Subdomains** stay as simple as their own complexity allows —
  do not apply full tactical DDD here by default.
- **Generic Subdomains** (auth, notification, generic CRUD) should generally
  be bought or borrowed, not modeled from scratch.

Do not force full tactical DDD onto simple CRUD or a mainly technical
problem — strengthen the model only when invariants, lifecycle, language
complexity, or integration risk actually justify the investment.

## Bounded Contexts and Language

Every meaningful model gets one explicit Bounded Context that owns its
language, rules, semantics, code structure, tests, and integration
contracts. Treat the same word in two different contexts as a potentially
different concept — translate at the boundary rather than sharing domain
classes or letting foreign vocabulary leak into the local model.

## Context Relationships

Choose deliberately among: Partnership, Shared Kernel (small, jointly
owned, and tested — without governance, pick a different relationship
instead), Customer/Supplier, Conformist, Anticorruption Layer (verify real
translation exists before calling something this), Open Host Service +
Published Language, Separate Ways, or deliberate containment of a Big Ball
of Mud. Each implies different ownership and translation duties — do not
default to the easiest one to code today.

## Integration Style by Coupling and Failure Semantics

- **RPC** — acceptable only when the request/response coupling itself is
  acceptable for both sides.
- **REST** — resources must not expose Aggregate internals; design the
  resource shape for the consumer, not for the persistence model.
- **Messaging** — must tolerate lag, duplicate delivery, and limited
  ordering guarantees; do not assume message-arrival order equals
  business-event order.

Keep integration contracts separate from internal models, and test the
translation wherever meanings cross a boundary.

## Lightweight Tactical Guidance

- **Entities** — use when identity and lifecycle matter; make identity
  explicit and protect meaningful state transitions instead of exposing
  unrestricted setters.
- **Value Objects** — use immutable, self-validating Value Objects whenever
  a primitive would otherwise hide domain meaning or an implicit constraint.
- **Aggregates** — invariant and transactional consistency boundaries only.
  Keep them small, modify only through the root, reference other Aggregates
  by identity, avoid large object graphs, and usually change one Aggregate
  per transaction.
- **Domain Events** — reserve for meaningful past-tense business facts that
  clarify collaboration or integration; do not publish an event for every
  field change.
- **Application Services** — coordinate use cases (load Aggregate, invoke
  behavior, save, trigger integration); they must not become the real
  domain model.

Keep frameworks, persistence mechanics, transport formats, and REST
representations out of the domain model itself — translate at the boundary,
and let Aggregates be persisted without letting storage define the model.

## Making the Model Teach

Prefer code that teaches: make domain assumptions explicit in names, tests,
and events. Expose richer concepts instead of hiding meaning behind status
flags, booleans, or generic helper functions. When workflow, terminology,
policies, or acceptance criteria are unclear, use Event Storming, concrete
scenarios, acceptance tests, or a timeboxed modeling spike with a domain
expert — and track modeling debt explicitly rather than letting the model
silently drift from the business.

## Trigger Rules

- Language that is fuzzy, generic, overloaded, or imported from another
  context → pause and sharpen the local Ubiquitous Language before more
  code.
- The core concern drifting, or supporting complexity starting to hide the
  Core Domain → reassess subdomain classification and modeling investment.
- A model spreading across billing, identity, catalog, fulfillment, or other
  clearly separate concerns → split or translate instead of reusing shared
  domain classes.
- An upstream schema, UI, framework, or transport payload starting to define
  the domain model → restore boundary translation.
- A request wanting to load and mutate a large graph or several Aggregate
  roots at once → revisit the invariant boundary and whether eventual
  consistency is acceptable instead.
- A concept represented as a primitive, flag, or boolean but carrying domain
  rules → promote it to a Value Object or richer concept.
- Delivery pressure tempting the team to skip design entirely → use a short
  modeling spike or acceptance test and record the known modeling debt
  instead of skipping silently.

## Final Checklist

- Correct subdomain classification and proportional Core Domain investment?
- Explicit Bounded Context and a deliberately chosen relationship to
  neighboring contexts?
- Ubiquitous Language visible in code, tests, commands, events, and APIs?
- Translation tested wherever external or foreign meanings cross a boundary?
- Tactical patterns used only where they clarify meaning or protect
  invariants — not applied as ceremony?
- Aggregates small, root-protected, identity-referenced, not graph-shaped?
- Modeling discoveries and known modeling debt captured before shipping?
