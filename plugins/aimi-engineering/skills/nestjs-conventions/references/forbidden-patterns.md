# NestJS Forbidden Patterns

Full anti-pattern catalogue for NestJS code review. Each entry: what it looks
like, why it's a problem, and the fix. Corroborated against current
`docs.nestjs.com` content via Context7 (see `../NOTICE.md`); the underlying
"why" for several of these is a restatement of the dependency rule covered by
the **architecture-foundation** skill, expressed in NestJS's own vocabulary.

## 1. Fat controllers / fat services

**Looks like**: a controller handler or a service method that has grown to
own validation logic, business rules, direct database queries, third-party
integration calls, and caching — all in one place, for one route or one use
case.

**Why it's a problem**: it collapses the Controller → Service → Repository
separation into one undifferentiated blob. Nothing is independently
testable, nothing is independently reusable, and every unrelated change to
"the cats feature" now risks breaking every other concern crammed into the
same class. This is the single most commonly named NestJS anti-pattern in
community review discussion, corroborating the official docs' insistence on
per-feature module/provider separation.

**Fix**: split by responsibility. Extract validation into a DTO + pipe,
persistence into a repository provider, third-party calls into their own
injectable client, caching into an interceptor or a dedicated cache
provider. The controller keeps routing; the service keeps orchestration.

## 2. Business logic or persistence code inside a Controller

**Looks like**: an `if` branch on a domain rule (e.g., checking a user's
role before allowing an action, computing a derived value) or a direct
repository/ORM call (`this.repo.find(...)`) written inline in a
`@Controller()` method.

**Why it's a problem**: controllers exist to translate HTTP in and out —
parse the request, call the service, shape the response. Business rules
living in the controller means they can't be exercised without the HTTP
layer (no unit test without spinning up a request), and means the same rule
is one copy-paste away from silently diverging if another controller needs
it too.

**Fix**: move the rule into the service (or, for genuine domain
invariants, into the entity/value object the service orchestrates around,
per architecture-foundation). The controller calls exactly one service
method for the use case and returns what it gets back.

## 3. Reaching for `forwardRef()` as a default fix for DI errors

**Looks like**: hitting `Nest cannot create the <module> instance` or a
similar circular-dependency error and immediately wrapping both sides in
`forwardRef(() => X)` without asking why the cycle exists.

**Why it's a problem**: `forwardRef()` is a documented, legitimate escape
hatch for a genuinely unavoidable cycle — but reaching for it reflexively
masks an underlying architectural coupling problem: two modules or providers
that each need something the other owns are usually a sign that the shared
responsibility belongs in a third, common module both can depend on without
depending on each other.

**Fix**: before wrapping in `forwardRef()`, ask whether the two sides
share a responsibility that can be extracted into its own provider/module.
Reserve `forwardRef()` for the residual cases where a true cycle is the
correct model of the domain (rare).

## 4. Skipping DTO validation and trusting `req.body` directly

**Looks like**: reading `req.body.someField` (or an untyped parameter)
directly in a handler, or hand-writing `if (!body.email) throw ...` checks
instead of a `class-validator`-decorated DTO enforced by the global
`ValidationPipe`.

**Why it's a problem**: DTOs + `class-validator` + a global `ValidationPipe`
(with `whitelist`/`forbidNonWhitelisted`) are the single source of truth for
"what shape can enter this handler." Ad hoc checks are incomplete by
construction — they validate exactly the fields someone remembered to check,
and drift from the DTO the moment one is edited without the other.

**Fix**: every external input gets a DTO class with `class-validator`
decorators; the global `ValidationPipe` is the only enforcement point. If a
check can't be expressed declaratively, it belongs in the service as a
domain rule, not as inline controller validation.

## 5. Injecting services from unrelated modules without exporting/importing them properly

**Looks like**: one feature module reaching into another feature module's
internal provider — either by importing the concrete provider class
directly (bypassing the module's `exports` array) or by re-declaring the
same provider in multiple modules so it can be "locally" injected.

**Why it's a problem**: Nest's module system encapsulates providers by
design — a module's `exports` array is its public API. Reaching around that
API (or duplicating providers to avoid using it) defeats the encapsulation
the module system exists to enforce, and tends to produce exactly the "god
object"/hidden-coupling failure mode the per-module DI container is meant
to prevent. It is also the module-system-specific shape of a concrete
class crossing a boundary that should have been an interface/token
(see `../SKILL.md`'s DI section).

**Fix**: export the provider from its owning module and import that module
where it's needed. If two features need the same provider and neither
"owns" it conceptually, extract it into a shared/core module both import —
never the reverse.
