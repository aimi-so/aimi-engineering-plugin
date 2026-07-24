---
name: nestjs-conventions
version: "1.0.0"
description: >
  Use when writing, reviewing, or scaffolding NestJS server-side code —
  module boundaries, dependency injection, controller/service/repository
  layering, DTO validation, or per-layer testing. Applies evergreen NestJS
  conventions: one @Module() per bounded feature, constructor DI by
  interface/token (never a concrete class reaching across a module
  boundary), strict Controller→Service→Repository separation honoring the
  Clean Architecture dependency rule, class-validator DTOs enforced by a
  global ValidationPipe, and unit/integration/e2e testing per layer.
  Trigger phrases: NestJS, Nest module, @Module, @Injectable, @Controller,
  dependency injection token, custom provider, forwardRef, injection scope,
  ValidationPipe, class-validator, DTO validation, @nestjs/config, Nest
  TestingModule, supertest, fat service, fat controller.
license: MIT (NOTICE.md)
---

# NestJS Conventions

Condensed, actionable NestJS conventions for module boundaries, dependency
injection, layering, DTO validation, and per-layer testing. Full-depth
material (forbidden-pattern catalogue, per-layer test recipes) lives under
`references/`; this file carries everything needed to write or review
NestJS code without reading further.

> **Attribution**: The conventions below are sourced from and cross-checked
> against the official NestJS documentation (`nestjs/nest`, MIT License),
> restated here in original wording as agent-facing conventions rather than
> reproduced verbatim. See `NOTICE.md`.

## When to Use

- Scaffolding a new NestJS module, controller, service, or repository.
- Reviewing whether a NestJS feature keeps its module boundary, DI wiring,
  and layering clean.
- Deciding where a DTO, validation rule, guard, interceptor, or pipe belongs.
- Writing or reviewing tests for a NestJS controller, service, or endpoint.

## The Dependency Rule (Inherited, Not Re-derived)

NestJS's module/DI system is a concrete mechanism for enforcing the same
dependency rule this plugin's **architecture-foundation** skill already
covers in full: source-code dependencies point inward, and outer-layer
details (HTTP, ORM, external clients) are reached only through an interface
the inner layer owns. Read `architecture-foundation`'s "The One Rule That
Matters Most" and "Layers" sections for the underlying Clean Architecture
reasoning — it is not repeated here. What follows is how that rule expresses
itself in NestJS's own vocabulary: modules, providers, tokens, and pipes.

## Module Boundaries

- **One `@Module()` per bounded domain feature.** A module encapsulates its
  own controllers and providers and exports only what other modules
  genuinely need; everything else stays private to the module by default —
  Nest's DI container only resolves providers that are part of the current
  module or explicitly exported from an imported one.
- **Feature modules depend on shared/core modules, never the reverse.** This
  one-directional import graph is what actually prevents a "god module":
  shared/core code has no knowledge of the features that consume it.
- **A module that re-exports an imported module** (`imports: [CommonModule],
  exports: [CommonModule]`) is how a composed module hands a dependency's
  providers on to its own consumers — use it to simplify composition, not to
  paper over a missing export somewhere else.
- Treat a module's `exports` array as its public API. If two features need
  the same provider, export it from a shared module both depend on — do not
  let one feature module reach into another's unexported internals.

## Dependency Injection by Interface/Token

- **Constructor-based DI only.** Nest's container resolves providers by
  constructor parameter; never `new SomeService()` inside application code —
  it defeats testability (no override point) and lifecycle management (Nest
  no longer controls the instance).
- **Depend on an interface, not a concrete class, whenever a module boundary
  or swappable implementation is involved.** Because TypeScript interfaces
  are erased at runtime, register the implementation against a `Symbol` (or
  string) token and inject it with `@Inject(TOKEN)`:

  ```typescript
  export interface LoggerService { log(message: string): void; }
  export const LOGGER_SERVICE = Symbol('LOGGER_SERVICE');

  @Module({
    providers: [{ provide: LOGGER_SERVICE, useClass: PinoLoggerService }],
  })
  export class AppModule {}

  @Injectable()
  export class CatsService {
    constructor(@Inject(LOGGER_SERVICE) private readonly logger: LoggerService) {}
  }
  ```

  A concrete class importing another concrete class across a module boundary
  — instead of both sides depending on a shared token/interface — is the
  NestJS-specific shape of the dependency rule being violated.
- **Custom providers** (`useClass`, `useValue`, `useFactory`, `useExisting`)
  are the mechanism for every DI need beyond a plain injectable class: swap
  implementations per environment, inject constants/mocks, build a provider
  from other providers at runtime, or alias one token to an existing one.
  Reach for the matching provider shape instead of hand-wiring instances.
- **Circular dependencies between modules or providers are a design smell to
  eliminate, not a default to paper over with `forwardRef()`.** `forwardRef()`
  is Nest's documented escape hatch for a genuinely unavoidable cycle — if
  reached for reflexively on every DI resolution error, restructure instead
  (commonly: extract the shared responsibility both sides need into a
  provider/module they can both depend on without depending on each other).
- **Provider scope defaults to singleton; request-scoped or transient scope
  (`@Injectable({ scope: Scope.REQUEST })`) is opted into deliberately.**
  Non-default scopes carry a real performance cost and change lifecycle
  assumptions app-wide — do not reach for them out of habit.

## Controller → Service → Repository Layering

Strict three-layer separation, mirroring architecture-foundation's Interface
Adapters → Application → Infrastructure layers in NestJS's own terms:

| Layer | Owns | Must not |
|---|---|---|
| Controller | route wiring, request parsing, response shaping | contain business rules, call a repository/ORM directly |
| Service | business rules, orchestration, use-case logic | touch `Request`/`Response` or other HTTP concerns |
| Repository / data access | query and persistence details | leak ORM/query-builder types past its own boundary |

- A controller's job stops at translating HTTP in and out. Any `if` branching
  on domain rules, or a direct repository/ORM call, inside a controller is a
  layering violation — push it into the service.
- A service never imports `Request`/`Response` or reads HTTP-specific state;
  it depends on repository interfaces (by token, see above), not concrete
  ORM clients.
- **Fat controllers and fat services** — a handler or service accumulating
  unrelated responsibilities (validation, business rules, direct queries,
  third-party calls, caching) instead of delegating to focused collaborators
  — are the most commonly named NestJS anti-pattern in practice. Split by
  responsibility, not by convenience.
- Cross-cutting concerns (auth, logging, request shaping) go through Nest's
  designated extension points — **Guards** for authorization decisions,
  **Pipes** for transformation/validation, **Interceptors** for
  wrapping request/response, **Middleware** for pre-routing concerns — used
  for their intended purpose, never smeared as ad hoc logic inside a service.
- Raise failures as Nest's built-in HTTP exception classes
  (`NotFoundException`, `BadRequestException`, …) or a custom exception
  caught by an `ExceptionFilter`, not as raw thrown errors handled ad hoc
  per-route.

## DTOs and Validation at the Edge

- **Every request body crosses a DTO class validated by `class-validator`
  decorators** (`@IsString()`, `@IsInt()`, `@IsEmail()`, …) — the DTO is the
  single source of truth for "what shape can enter this handler," not manual
  `if` checks in the controller.
- **Enforce validation globally via `ValidationPipe`**, with `whitelist:
  true` to strip properties the DTO doesn't declare, and
  `forbidNonWhitelisted: true` to reject the request outright instead of
  silently stripping when extra properties are present:

  ```typescript
  app.useGlobalPipes(new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true }));
  ```

- Trusting `req.body` directly, or re-implementing field checks by hand
  instead of decorators + the global pipe, is a forbidden pattern (see
  `references/forbidden-patterns.md`).
- Use `class-transformer` alongside `class-validator` to map between DTOs
  and domain/entity objects rather than hand-rolling that mapping.
- Centralize configuration through `@nestjs/config` (or an equivalent typed
  config module) and inject it — never read `process.env` scattered across
  services; a single injected config surface is what keeps environment
  handling testable and typed.

## Testing per Layer

- **Unit test services in isolation**, with the repository (or any other
  collaborator) provided through its DI token as a mock/`useValue` —
  `Test.createTestingModule({ providers: [...] })` gives you a real Nest DI
  graph with test doubles substituted at the boundary, so the service under
  test runs through its actual constructor wiring.
- **Integration test controllers against a real `TestingModule`** built from
  `Test.createTestingModule({ controllers: [...], providers: [...] })`,
  retrieving instances with `moduleRef.get(...)` and spying on/mocking the
  service methods the controller calls — this verifies the controller's
  wiring without needing a live HTTP server.
- **End-to-end test endpoints with `supertest`** against a real
  `INestApplication` (`app.getHttpServer()`), overriding only the specific
  provider(s) that need a test double (`.overrideProvider(X).useValue(...)`)
  so the rest of the module graph — routing, pipes, filters, guards — runs
  for real.
- Full recipes (mocked-repository unit tests, `TestingModule` controller
  tests, `supertest` e2e flows, `useMocker` auto-mocking) live in
  `references/testing-recipes.md`.

## Forbidden Patterns

The five NestJS-specific anti-patterns worth flagging on sight — fat
controllers/services, business logic in controllers, `forwardRef()` as a
default DI fix, skipped DTO validation, and reaching into another module's
unexported internals — are cataloged with the "why" and the fix in
`references/forbidden-patterns.md`. Any one of them found in review is
grounds to push back before merging.

## Final Checklist

Before accepting a NestJS module, controller, service, or repository change:

- Each module encapsulates its own providers and exports only what other
  modules genuinely need; nothing reaches into another module's unexported
  internals.
- Every cross-module or swappable dependency is injected by interface/token,
  never by importing a concrete class across a module boundary.
- Controllers only route; services only orchestrate business rules;
  repositories only handle persistence — none leaks into another's job.
- Every external input crosses a validated DTO; the global `ValidationPipe`
  runs with `whitelist`/`forbidNonWhitelisted`.
- `forwardRef()`, non-default injection scopes, and scattered `process.env`
  reads are each a deliberate, justified choice — not a default habit.
- Services have unit tests with mocked collaborators; controllers have
  `TestingModule` coverage; endpoints have `supertest` e2e coverage.

## Deep Reference

For depth material not needed to make a day-to-day NestJS decision, read on
demand (not auto-loaded):

- `references/forbidden-patterns.md` — the full anti-pattern catalogue with
  rationale and fix per pattern.
- `references/testing-recipes.md` — unit, integration, and e2e test recipes
  per layer, including auto-mocking and provider overrides.
