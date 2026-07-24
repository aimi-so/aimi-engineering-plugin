---
name: architecture-foundation
description: >
  Use when proposing, reviewing, or laying down the initial architecture for a
  repository — greenfield layering decisions, brownfield convention inference,
  folder-layout proposals, module boundaries, or any foundation-gate story that
  must justify layering and domain-modeling choices. Applies Clean Architecture
  (dependency direction, layers, ports/adapters) and Domain-Driven Design
  (Ubiquitous Language, Bounded Contexts, Entities, Value Objects, Aggregates,
  Repositories) as condensed, actionable conventions. Trigger phrases: greenfield
  foundation, brownfield conventions, architecture proposal, layering, folder
  layout, module boundaries, dependency rule, bounded context, aggregate root,
  domain model, ubiquitous language, ports and adapters, foundation gate.
license: MIT (NOTICE.md)
---

# Architecture Foundation

Condensed, actionable Clean Architecture (Robert C. Martin) and Domain-Driven
Design (Eric Evans) conventions for laying down or auditing a repository's
foundation — greenfield proposals and brownfield convention inference alike.
Full-depth material lives under `references/`; this file carries everything
needed to make a foundation decision without reading further.

> **Attribution**: The rules below adapt condensed guidance from the
> `agent-rules-books` project's Clean Architecture and Domain-Driven Design
> mini-guides, Copyright (c) 2026 Maciej Ciemborowicz, MIT License. Rewritten
> here as foundation-story conventions, not reproduced verbatim. See `NOTICE.md`.

## When to Use

- A greenfield or near-empty repository needs a layering + folder-layout
  proposal before the first story is written.
- A brownfield repository has no detectable architecture convention and needs
  one inferred or proposed from existing structure.
- Reviewing whether a proposed or existing folder layout, module boundary, or
  domain model keeps business rules independent of frameworks and databases.
- Any story whose `implementation.approach` must justify a layering, module
  boundary, or naming decision.

## The One Rule That Matters Most

**Source-code dependencies point inward.** Domain and use-case code never
imports frameworks, database drivers, web/HTTP libraries, queue clients, or UI
toolkits. Frameworks, databases, transport, and messaging are outer-layer
details reached only through an interface the inner layer owns. Inner layers
define ports; outer layers implement them; a composition root wires concrete
details at the edge. Every other rule below exists to protect this one.

## Layers (Clean Architecture)

| Layer | Contains | Must | Must not |
|---|---|---|---|
| Domain | entities, invariants, core business rules | be framework-free, persistence-ignorant | import web/db/queue libs, perform I/O |
| Application | use cases, input/output models, ports | depend only on domain abstractions, orchestrate one action per use case | contain controller logic, return framework types |
| Interface Adapters | controllers, presenters, gateway adapters, mappers | translate external formats to/from internal models | own business decisions, bypass use cases |
| Infrastructure | framework bootstrap, DB access, external clients, composition root | implement interfaces owned by inner layers, stay replaceable | define business rules, leak vendor types inward |

Prefer feature/use-case-oriented folder names (`orders/place-order/`) over
generic technical buckets (`services/`, `helpers/`, `utils/`) — structure
should reveal the domain and its use cases, not the framework.

## Domain-Driven Design Building Blocks

- **Ubiquitous Language** — one vocabulary per Bounded Context, shared by code,
  tests, docs, and conversation. Awkward or repeatedly-translated terms mean
  the model needs refining before more behavior is added.
- **Bounded Context** — every meaningful model gets one explicit context that
  owns its language, rules, and code structure. The same word can mean
  different things in different contexts; translate at the boundary, never
  assume shared meaning.
- **Entities** — objects with stable identity across state changes. Protect
  identity and valid state transitions; do not expose unrestricted setters.
- **Value Objects** — immutable, self-validating, defined by their attributes,
  not identity. Promote a primitive to a Value Object once it starts carrying
  domain rules (a raw string/int with validation logic is a smell).
- **Aggregates** — invariant and transactional consistency boundaries. Keep
  them small, modify only through the root, reference other aggregates by
  identity (not object reference), and change one aggregate per transaction.
- **Repositories** — expose only Aggregate roots, speak domain terms, hide
  query/mapping/storage details. A repository that leaks ORM/query-builder
  types into domain code has failed its job.
- **Domain Services** — hold operations that don't naturally belong to one
  Entity or Value Object, only when the operation is a real domain concept
  (not a dumping ground for orchestration).
- **Factories** — hide complex creation and prevent partially-formed objects
  from escaping into the rest of the system.
- **Application Services** — coordinate use cases (load aggregate, invoke
  domain behavior, save, publish); they orchestrate, they do not become the
  real domain model.

## Decision Rules

Apply as PROPOSE-style defaults — recommendations with rationale — when
drafting a layering, folder layout, module template, or naming convention.
Reweight or skip a rule when a named stack's own ecosystem convention already
satisfies it better; never present the reweighting as an open question.

1. Preserve independent business rules and inward dependencies even when the
   immediate feature would ship faster without them.
2. Put enterprise rules/invariants in entities; put per-use-case orchestration
   in focused application services or use cases — one application action each.
3. Pass plain request/response models across use-case boundaries; never pass
   web requests, ORM rows, or framework contexts into or out of core policy.
4. Give every meaningful model one explicit Bounded Context; do not assume a
   term means the same thing outside it.
5. Use Aggregates only as consistency boundaries — small, root-modified,
   identity-referenced to other aggregates, one aggregate per transaction.
6. Choose the lightest enforceable boundary (package structure, dependency
   rule, build constraint, or test) over a diagram or a shared `common/`
   folder that nobody enforces.
7. Do not merge unrelated use cases or eliminate duplication when sharing
   would couple actors, change reasons, team ownership, or deployment needs.
8. Test entities, use cases, and boundary contracts first, without the real
   framework, database, network, or external service.
9. Refactor toward deeper domain insight, not only mechanical cleanliness —
   make implicit constraints, policies, and processes explicit when they
   carry domain meaning.
10. Choose context relationships deliberately (Shared Kernel, Customer/
    Supplier, Conformist, Anticorruption Layer, Open Host Service, Published
    Language, Separate Ways) — do not default to sharing domain classes
    across contexts.

## Trigger Rules — When to Push Back

- Framework annotations, ORM rows, serializers, or vendor SDKs entering
  domain/use-case code → move translation outward behind an adapter.
- Controllers, jobs, views, or SQL scripts containing business branching or
  validation → move the rule inward to an entity, value object, or domain
  service.
- A use case instantiating infrastructure directly or depending on a concrete
  implementation → introduce a policy-owned port, wire the concrete detail at
  the composition root.
- A `*Service`, `utils/`, `helpers/`, or `core/` folder becoming an escape
  hatch for everything → split by use case or domain concept, restore
  ownership.
- Terminology that is fuzzy, generic, overloaded, or borrowed from another
  context → sharpen the local Ubiquitous Language before adding more behavior.
- A change that crosses many unrelated modules or several aggregate roots →
  reassess module cohesion, aggregate boundaries, and consistency timing.
- Tests that need the real framework, database, or network to verify a
  business rule → move the test to the use case/entity level with fakes.

## Forbidden Patterns

- Domain entities importing web/database/queue libraries.
- Use cases returning framework response objects or database rows.
- Controllers/jobs/views containing business decisions or direct persistence
  calls that bypass a use case.
- God `*Service` classes that create, fetch, validate, persist, and publish
  everything for every use case.
- Generic `utils/`, `common/`, or `core/` folders used as architecture escape
  hatches instead of named use cases or domain concepts.
- Aggregates that hold direct object references to other aggregates instead
  of identities, or that span more than one transaction's consistency need.
- A repository, gateway, or mapper that leaks its underlying storage/query
  technology's types into domain code.

## Final Checklist

Before accepting a foundation proposal or a layering change, confirm:

- Business rules are independent of frameworks, databases, UI, and vendors.
- Dependencies point inward; ports are owned by inner layers.
- Entities guard invariants; use cases each orchestrate one application action.
- Every meaningful model has one explicit Bounded Context and Ubiquitous
  Language.
- Aggregates are small, root-modified, and reference other aggregates by
  identity only.
- Folder structure reveals use cases/domain capabilities, not generic
  technical buckets.
- Core tests run without a live framework, database, network, or external
  service.

## Deep Reference

For the full-depth source material behind these condensed rules — additional
heuristics, code-generation ordering, refactoring playbooks, and testing
detail — read on demand (not auto-loaded):

- `references/clean-architecture.md` — full layering, boundary, and
  refactoring detail.
- `references/domain-driven-design.md` — full strategic + tactical pattern
  detail (Bounded Contexts, context mapping, Aggregates, Repositories,
  Specifications, Factories).
- `references/domain-driven-design-distilled.md` — the pragmatic "smallest
  effective DDD" subset (subdomain classification, integration styles).
- `references/patterns-of-enterprise-application-architecture.md` — Service
  Layer, Repository/Data Mapper/Active Record tradeoffs, Unit of Work,
  Identity Map, session-state patterns for enterprise application shape.
