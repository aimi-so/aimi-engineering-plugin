# Domain-Driven Design — Deep Reference

Adapted from Eric Evans's *Domain-Driven Design*, via the `agent-rules-books`
mini-guide (`domain-driven-design.mini.md`) and full guide
(`domain-driven-design.md`), Copyright (c) 2026 Maciej Ciemborowicz, MIT
License. Rewritten and reorganized for this skill's foundation-proposal
purpose — not a verbatim reproduction. See `../NOTICE.md` for the full
license text.

This file is the depth tier behind `SKILL.md`'s condensed rules. Read it when
a foundation story needs the reasoning behind a strategic or tactical DDD
decision, not just the rule itself.

## Knowledge Crunching and Model-Driven Design

A model is worth using only when it organizes domain knowledge, clarifies
communication with domain experts, and can actually be expressed in the
implementation. Build it iteratively: code, conversation with experts,
concrete scenarios, and refactoring toward deeper insight, in a loop — not a
single up-front diagramming pass. Keep any explanatory or analysis model
separate from the model that actually drives the implementation; a model
that cannot be implemented is not doing its job.

**Anti-patterns**: a model frozen after initial design and never revisited
against new domain understanding; a model built by developers in isolation
from domain experts; documentation that drifts from the code it was supposed
to describe.

## Ubiquitous Language

Every Bounded Context gets exactly one shared vocabulary, used consistently
in code, tests, documents, diagrams, planning artifacts, and everyday
conversation about that context. When a term is awkward, ambiguous, or
requires repeated translation between "how developers say it" and "how the
business says it," that is a signal to refine the language and rename code —
before adding more behavior on top of a shaky vocabulary.

**Anti-patterns**: technical jargon substituted for the business's own words;
the same class or method meaning different things depending on who reads it;
a glossary that exists separately from the code and is never enforced by it.

## Bounded Contexts

Define every meaningful model's boundary explicitly. Never assume a term
carries the same meaning in a different part of the system — "Order" in a
fulfillment context and "Order" in a billing context are different concepts
that happen to share a word, and conflating them corrupts both models.
Protect model integrity across a boundary with context maps, boundary tests,
and active communication between the teams or areas involved.

### Strategic Design

- **Core Domain** — the part of the model that provides the system's
  primary competitive or business value. It deserves the most modeling
  effort, the most experienced people, and the most scrutiny.
- **Supporting Subdomains** — necessary but not differentiating; keep them
  simpler unless their own complexity proves otherwise.
- **Generic Subdomains** — solved problems (auth, notifications, generic
  CRUD); do not let them consume Core Domain modeling attention, and prefer
  off-the-shelf or externally-sourced solutions over custom modeling here.
- **Context Mapping** — make every relationship between Bounded Contexts an
  explicit, named choice: Shared Kernel (small, jointly-owned, tested
  overlap), Customer/Supplier, Conformist (accept the upstream model as-is),
  Anticorruption Layer (translate and defend against a foreign model),
  Separate Ways (no integration at all), Open Host Service + Published
  Language (a stable public contract for many consumers), or incremental
  replacement of a legacy Big Ball of Mud.

**Anti-patterns**: a Shared Kernel with no joint governance or tests; calling
a translation layer an "Anticorruption Layer" when it does not actually
translate anything; letting a legacy system's model bleed unfiltered into a
new one because "it's just easier for now."

### Distillation

Distill the Core Domain so its distinctive value is visible and undiluted —
extract generic subdomains and reusable mechanisms out of it, and keep
supporting complexity from obscuring what actually differentiates the
system. Apply large-scale structure (evolving order, responsibility layers,
pluggable component frameworks) only once individual objects and Bounded
Contexts alone no longer make a large model understandable — and keep any
such structure domain-specific and valid only inside compatible contexts.

## Tactical Patterns

### Entities
Use when an object's continuity and identity matter across state changes and
over time — a Customer, an Order, a User account. Give the entity an explicit
identity, protect its valid state transitions, and avoid exposing
unrestricted setters that let external code push it into an invalid state.

**Anti-patterns**: identity implied only by database primary keys with no
domain meaning; entities that are just data bags with public setters for
every field.

### Value Objects
Use when a concept is fully described by its attributes and has no
conceptual identity — Money, an Address, a DateRange. Make them immutable and
self-validating; replace a primitive that has started carrying domain rules
(a raw string that must match a format, an int that must stay positive) with
a Value Object.

**Anti-patterns**: "primitive obsession" — passing raw strings/ints/booleans
around that silently carry domain constraints no type enforces; mutable
value objects that get shared and mutated out from under a caller.

### Associations and Modules
Keep associations traversable in only the direction the domain actually
needs; unnecessary bidirectional references add coupling without modeling
value. Group classes into Modules by conceptual cohesion (what the model
means), not by technical layer — a module boundary should read as a
statement about the domain, not about the framework.

### Aggregates
The consistency and transactional boundary of the model. Rules:

- Expose only the Aggregate root to the outside world; internal members are
  reached only through the root.
- Enforce invariants inside the boundary — an aggregate must never be left in
  a state that violates its own rules, even transiently, from outside code.
- Reference other Aggregates by identity (an ID), never by holding a direct
  object reference — this keeps aggregates independently loadable and
  prevents accidental large-object-graph loads.
- Keep aggregates small. Prefer modifying and persisting exactly one
  aggregate per transaction; treat cross-aggregate consistency as usually
  eventual, not immediate.

**Anti-patterns**: an aggregate that holds live references to other
aggregates and lets callers reach through it; a "God Aggregate" that grew to
contain most of the domain because splitting felt inconvenient.

### Domain Services
Use only when an important domain operation does not naturally belong to any
Entity or Value Object — a transfer between two accounts, for instance,
which does not belong to either account alone. A Domain Service still
carries real domain behavior; it is not a place to relocate orchestration
that belongs in the application layer or, worse, business logic that
actually belongs to an Entity.

### Explicit Concepts and Specifications
When a rule, policy, or selection criterion is implicit — buried in
conditional logic scattered across the codebase — make it an explicit domain
concept. A `Specification` names a predicate ("is an OverdueInvoice") so it
can be tested, reused, and combined instead of duplicated as ad hoc
`if`-statements.

### Repositories
Provide the illusion of an in-memory collection of Aggregates, addressed by
identity or by domain-meaningful query criteria — never by raw SQL or
query-builder types leaking through the interface. A repository is defined
per Aggregate root, not per table; it is the seam that keeps persistence
technology out of the domain model.

**Anti-patterns**: a repository interface that accepts or returns
ORM-specific types; a "generic repository" so broad it stops meaning
anything domain-specific.

### Factories
Use when object creation is complex enough that scattering it across callers
would risk producing partially-formed or invalid objects. A Factory
encapsulates that complexity and guarantees only valid, fully-formed
Aggregates and Entities are ever handed back.

## Application Layer

Coordinates use cases: load the Aggregate(s) via a Repository, invoke domain
behavior, persist results, and trigger any necessary integration work
(publishing a Domain Event, calling out to another Bounded Context). The
Application Layer must not become the real domain model — if it accumulates
business rules and branching logic, that behavior belongs in an Entity, a
Value Object, or a Domain Service instead.

## Infrastructure and Translation at Boundaries

Frameworks, persistence mechanics, transport formats, and external API
payloads stay out of the domain model — translate at the boundary and let the
domain model define its own shape rather than being shaped by storage or
transport. Wherever an external or foreign model's meaning crosses into this
Bounded Context, that translation deserves its own test, independent of the
domain logic it feeds.

## Supple Design

Design domain objects for their users: name operations for their domain
purpose (not their mechanism), separate side-effect-free query methods from
state-changing commands, and make assertions/preconditions explicit rather
than implicit. Reach for analysis patterns, established design patterns, and
industry formalisms only when they genuinely clarify the current model — not
as a way to look sophisticated.

## Code Generation Rules

1. Identify the domain concept first, before reaching for generic plumbing.
2. Prefer modeling a concept explicitly over adding another flag, enum, or
   boolean to an existing type.
3. Use raw primitives only when a value truly carries no domain meaning or
   constraint.
4. Protect invariants at the model boundary — an Aggregate's public API
   should make invalid states unrepresentable, not merely "usually avoided."
5. Keep the model persistence-ignorant; derive the persistence mapping from
   the model, never the reverse.
6. Keep Bounded Context boundaries visible in the folder/package structure,
   not just in a document.
7. Translate foreign models explicitly at every context boundary.
8. Actively look for implicit concepts hiding in conditionals, flags, and
   comments — that is usually where the next Value Object or Domain Service
   is waiting to be named.
9. Preserve strategic priorities: spend the deepest modeling effort on the
   Core Domain.

## Domain Events

Use Domain Events for meaningful, past-tense business facts that matter to
collaboration or cross-context integration (`OrderShipped`, not
`OrderFieldChanged`). Do not publish an event for every field mutation — a
noisy event stream that mirrors internal state changes has no domain
meaning and burdens every consumer.

## Testing Rules

Prioritize domain tests, written in the Ubiquitous Language, that prove:
invariants hold, valid state transitions succeed, invalid transitions and
invalid construction are rejected, Specifications classify correctly, and
Application Services orchestrate without absorbing business logic. Only
after domain behavior is covered do generic infrastructure and framework
checks matter.

## Forbidden Patterns

- **Passive/anemic domain model** — Entities that are pure data with all
  behavior implemented elsewhere (services, controllers, helpers).
- **Smart UI** — business rules embedded directly in presentation code
  because it seemed faster for a small feature.
- **Persistence-driven design** — a domain model shaped by the database
  schema instead of the other way around.
- **Primitive obsession** — domain rules enforced ad hoc on raw
  strings/numbers instead of Value Objects.
- **Shared-model-everything** — reusing one class across Bounded Contexts
  that actually mean different things by the same name.
- **God services** — one class that owns creation, validation, persistence,
  and publishing for every use case in a context.
- **Invalid construction** — objects that can be instantiated in a state
  that violates their own invariants.
- **Fake DDD** — Entity/Value Object/Aggregate/Repository vocabulary applied
  to what is really a CRUD data-access layer with extra ceremony and no
  actual domain modeling investment.
- **Context Map blindness** — integrating with another Bounded Context
  without ever naming the relationship or writing a translation test.

## Refactoring Toward Deeper Insight

Refactor when: terminology feels awkward, generic, or borrowed; the core
concern of the domain drifts and terms stop matching code; one model
sprawls across concerns that should be separate contexts (billing, identity,
catalog...); an upstream schema, UI, or transport payload starts dictating
the domain model instead of being translated at a boundary; or a new
behavior is hard to explain, test, or extend — often a sign of a missing
implicit concept rather than a reason to add another conditional branch.

## Review Checklist

- Is domain behavior explicit in the model, not hidden in delivery,
  persistence, or integration code?
- Do code, tests, docs, and conversation use one language inside each
  Bounded Context?
- Do tactical patterns (Entity, Value Object, Aggregate, Repository,
  Factory, Domain Service) protect identity, value semantics, lifecycle, and
  invariants — rather than adding ceremony with no behavioral payoff?
- Does every cross-context integration have an explicit relationship,
  translation strategy, and boundary test?
- Is the Core Domain visible and protected from supporting complexity,
  generic mechanisms, and infrastructure concerns?

Make major strategic decisions — context boundaries, core-domain
distillation, integration relationships — with people who understand both
the implementation and the domain. Architecture and framework guidance must
serve the domain model and the application team, not the reverse.
