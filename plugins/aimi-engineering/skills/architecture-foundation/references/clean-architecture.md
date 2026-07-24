# Clean Architecture — Deep Reference

Adapted from Robert C. Martin's *Clean Architecture*, via the `agent-rules-books`
mini-guide (`clean-architecture.mini.md`) and full guide
(`clean-architecture.md`), Copyright (c) 2026 Maciej Ciemborowicz, MIT License.
Rewritten and reorganized for this skill's foundation-proposal purpose — not a
verbatim reproduction. See `../NOTICE.md` for the full license text.

This file is the depth tier behind `SKILL.md`'s condensed rules. Read it when a
foundation story needs the reasoning behind a rule, not just the rule itself.

## Layer Responsibilities, in Full

### Domain Layer
Holds entities, enterprise business rules, and domain invariants. May be
implemented as plain objects, functions, or modules — Clean Architecture
requires independent business rules, not a specific modeling style.

- Must be framework-free, persistence-ignorant, delivery-mechanism agnostic.
- Must not import web libraries, database access types, or external service
  clients; must not perform I/O or read configuration directly.

### Application Layer
Holds use cases, input/output models, ports, and orchestration logic.

- Must depend only on domain abstractions and models; must define interfaces
  for any external behavior it needs; must coordinate workflows explicitly.
- Must not contain controller logic, database access details, or return
  framework response types.

### Interface Adapters Layer
Holds controllers, presenters, view models, gateway adapters, and mappers.

- Must translate between external formats and internal models, depending
  inward on application and domain code.
- Must not move business policy out of the use case/domain layer, and must
  not bypass use cases to call gateways directly without explicit justification.

### Infrastructure Layer
Holds framework bootstrap, object-graph wiring, database access, external
service integrations, message-bus clients, filesystem implementations.

- Must remain replaceable and implement interfaces owned by inner layers.
- Must not define business rules, dictate domain shapes, or leak vendor types
  inward.

## Code Generation Order

For any non-trivial feature, work in this order so dependency direction is
correct from the first line written:

1. Domain rule or entity behavior
2. Use case
3. Boundary interfaces (ports)
4. Presenter contract
5. Gateway contract
6. Adapters
7. Framework wiring (composition root)

Use plain request/response models owned by the application layer at every
boundary — never pass database-bound entities, web requests, or framework
structures into core logic, and never return framework objects from a use
case. Introduce ports for every volatile dependency: gateways, mailers,
payment providers, message publishers, storage providers, clocks, ID
generators. Keep object construction in the composition root — never
instantiate infrastructure inside a use case or entity.

## Architecture Heuristics

**Dependency direction.** For every import, ask: does it point inward? Is a
high-level policy depending on a low-level detail? Is a framework or vendor
type leaking into a core layer? If yes, refactor.

**Policy vs. detail.** When placing new code, ask whether it is business
policy, orchestration, translation, or infrastructure — put it in the
highest-level place that matches its responsibility.

**Stable core, replaceable edge.** A well-architected system lets you swap the
web framework, persistence technology, message broker, job runner, cloud
vendor, serializer, or UI without rewriting business rules.

**Feature-first structure.** Prefer feature/use-case/business-capability names
over generic controller/service/gateway buckets. Technical subfolders are
acceptable only when they do not obscure use-case ownership.

## Architecture Economics

Architecture exists to keep future change cost proportional to the scope of
change — it is not free, and it is not infinite either:

- Do not sacrifice important architectural work merely because urgent feature
  work is louder.
- Preserve optionality around frameworks, databases, delivery mechanisms, and
  deployment topology until evidence justifies commitment.
- Choose boundaries by volatility, policy importance, substitution value,
  testability, and cost — do not overbuild boundaries whose cost exceeds the
  option value they preserve.
- Revisit architecture when change shape, team ownership, or operational
  constraints reveal rising cost.

## Paradigm and Component Rules

- Structured programming keeps behavior decomposable and testable.
- Polymorphism inverts dependencies when high-level policy must not know
  low-level details (Dependency Inversion Principle).
- SRP: separate code that changes for different actors or reasons.
- OCP: protect stable policy from volatile extension details.
- LSP: substitutable implementations must preserve caller expectations.
- ISP: keep interfaces focused on what each client actually needs.
- Group components by cohesion and release pressure — not because they share
  a technical layer. Avoid component cycles. Balance stability and
  abstraction: stable components should not depend on unstable details.

## Boundary Cost, Deployment, and Services

A boundary may be a source boundary, deployment boundary, process boundary,
service boundary, or partial boundary — choose the lightest one that
preserves the needed independence. Partial boundaries are acceptable when a
full runtime split is too expensive today but future separation has value.
Make boundaries enforceable through package structure, dependency rules,
tests, or build constraints — a diagram alone is not a boundary.

A service is not automatically an architectural boundary; source dependencies
and data ownership still decide coupling. Treat remote calls as I/O
boundaries, never as local method calls. Keep service listeners humble:
translate external messages into use-case calls and return through output
boundaries.

## Naming Rules

- Name modules/packages after business capabilities or use cases.
- Name use cases with action verbs from the application's own use cases.
- Name ports by the role they play for the use case; name adapters by the
  external detail they adapt.
- If a class is named `Service`, be able to justify why it is not a use case,
  adapter, or domain object in disguise.

## Testing Rules

**Core tests first.** Entities, use cases, and boundary contracts get tests
that run without the real framework, database, or network — fast and
deterministic. **Adapter tests** cover mapping correctness, gateway behavior,
controller translation, and presenter formatting separately. Prefer testing
use cases with fakes/mocks for ports over reaching into private internals
when a public use-case boundary already exists.

## Forbidden Patterns

- **Framework leakage** — domain entities annotated with DB/web framework
  metadata; use cases depending on `Request`/`Response` or framework session
  objects.
- **Database leakage** — use cases returning table rows; domain objects
  shaped primarily around persistence convenience.
- **Controller-centric logic** — controllers with branching business rules,
  or controllers calling gateways directly instead of use cases.
- **God services** — large `*Service` classes that create, fetch, validate,
  persist, publish, and present everything.
- **Layer bypass** — controllers skipping use cases; presenters reading the
  database directly; infrastructure both importing inward and being imported
  by domain code.
- **Direction violations** — gateway interfaces defined in infrastructure and
  consumed by core policy; entities importing adapters.
- **Utility dumping grounds** — generic `utils/`/`common/`/`core/` folders
  used as escape hatches instead of named use cases or domain concepts.

## Refactoring Playbook

When modifying existing code toward Clean Architecture: (1) move business
rules inward, extracting domain logic from controllers/handlers/jobs; (2)
introduce boundaries around external services, DB access, message buses,
clocks; (3) replace concrete dependencies with ports defined in inner layers
and implemented outward; (4) separate translation (parsing, mapping,
serialization) from policy; (5) break up god services by use case; (6)
rewrite tests to target use cases/entities directly; (7) refactor
incrementally — prefer safe boundary extraction over rewrites, and document
any temporary boundary violation rather than normalizing it.

## Preferred Default Shapes

Feature shape: `domain/ → application/ → adapters/ → infrastructure/` (or
nested per-feature: `feature/domain`, `feature/application`, ...). Use-case
shape: request model → use case → output boundary/response model → ports,
with adapter implementations living outside. Dependency pattern: inner layer
defines the interface, outer layer implements it, composition root wires them.

## Review Checklist

- Are business rules independent from frameworks and databases?
- Do use cases stay independent from delivery and persistence details?
- Do source dependencies point inward, with ports owned by inner layers?
- Are controllers thin and gateways just persistence adapters?
- Do entities guard domain invariants? Is composition happening at the edge?
- Can core tests run without the web framework and database?
- Does the project structure reveal domain and use cases rather than a
  generic technical taxonomy?

When constraints force a compromise, keep it at the outermost layer possible,
document it explicitly, and preserve a path back to separation. When
uncertain, choose the option that keeps business rules independent, points
dependencies inward, isolates details behind boundaries, and improves
testability.
