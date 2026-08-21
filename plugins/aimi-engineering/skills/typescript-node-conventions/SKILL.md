---
name: typescript-node-conventions
description: >
  Use when writing, reviewing, or setting conventions for TypeScript code that
  runs on Node.js or Bun — strict typing discipline (strict mode, unknown over
  any, no implicit any), the ESM/CJS module interop boundary (moduleResolution,
  verbatimModuleSyntax, package.json exports maps), error-handling taxonomy
  (typed error classes, operational vs programmer errors), async hygiene (no
  floating promises, flat async/await), and keeping Bun and Node
  interchangeable by isolating runtime-specific APIs behind a thin adapter.
  Trigger phrases: strict typing, unknown over any, no implicit any, ESM/CJS
  interop, moduleResolution, verbatimModuleSyntax, operational vs programmer
  errors, floating promises, unhandled rejection, exports map, dual package
  hazard, Bun Node interchangeable, runtime adapter.
license: CC-BY-4.0 AND MIT (NOTICE.md)
metadata:
  version: "1.0.0"
---

# TypeScript / Node / Bun Conventions

Condensed, actionable TypeScript-on-Node/Bun conventions distilled from the
official TypeScript Handbook and Node.js documentation. Full-depth material
lives under `references/`; this file carries everything needed to write or
review TypeScript/Node/Bun code without reading further.

> **Attribution**: The rules below adapt and paraphrase guidance from the
> official TypeScript Handbook (microsoft/TypeScript-Website, CC-BY 4.0 for
> prose) and the official Node.js documentation (nodejs/nodejs.org, MIT).
> Nothing here is reproduced verbatim — conventions are restated in original
> wording as agent-facing rules. Cross-checked against current TypeScript and
> Node.js documentation via Context7. See `NOTICE.md` for full attribution
> and license text.

## When to Use

- Writing new TypeScript for a Node.js or Bun service, CLI, or library.
- Reviewing a PR that touches `tsconfig.json`, module boundaries,
  `package.json` `exports`, error handling, or async code.
- Deciding whether code should be portable between Bun and Node, and where to
  draw the adapter line if it isn't.
- Any story whose `implementation.approach` must justify a typing, module, or
  error-handling decision on a TS/Node/Bun stack.

## The Rule That Matters Most

**`strict: true` is the non-negotiable baseline.** It is TypeScript's single
highest-leverage setting — `tsc --init` has generated it by default since
TypeScript 2.3, and TypeScript 5.9's default `tsc --init` output layers
additional stricter options (`noUncheckedIndexedAccess`,
`exactOptionalPropertyTypes`) on top of it as the current recommended
starting point. Disabling `strict` (or leaving it off in a migrated project)
forfeits most of what makes TypeScript worth using. Every rule below assumes
it is on.

## Strict Typing Discipline

- Enable `strict: true`; do not selectively disable its sub-flags
  (`strictNullChecks`, `noImplicitAny`, `strictFunctionTypes`, ...) to make a
  migration easier — fix the underlying types instead.
- **Never use `any` to silence the compiler.** For genuinely dynamic data
  (API responses, `JSON.parse` results, third-party payloads), type it
  `unknown` and narrow with `typeof`, `instanceof`, a user-defined type
  predicate, or a runtime schema check before use. `unknown` accepts any
  value but permits no operations until narrowed — that gap is the safety
  `any` throws away.
- Catch-clause variables are `unknown` under `strict` (`useUnknownInCatchVariables`,
  on since TS 4.4) — narrow with `if (err instanceof Error)` before reading
  `.message`/`.stack`; don't reflexively re-type a caught value as `any`.
- Prefer `interface` for object shapes callers might extend or implement;
  prefer `type` for unions, intersections, and mapped/conditional types. Not
  a compiler rule, but the near-universal community and linter default
  (`@typescript-eslint/consistent-type-definitions`) — pick one rationale and
  apply it consistently rather than mixing arbitrarily.
- Validate all external input (HTTP bodies, env vars, config files, queue
  messages) at the boundary with a runtime schema validator (zod/valibot or
  equivalent), not just a compile-time type. An `as SomeType` cast on
  unchecked external data is a false sense of safety — types vanish at
  runtime; only a runtime check catches a shape mismatch.

## ESM/CJS Module Boundary

- **ESM (`import`/`export`) is the default for new code.** Reach for
  CommonJS interop deliberately, not as an ad hoc per-file habit — mixing
  `require()` and `import` in the same module graph without a chosen
  boundary produces `__dirname`/`import.meta.url` confusion and dual-package
  hazards.
- Pair `"module": "nodenext"` with `"moduleResolution": "nodenext"` (implied)
  and `"verbatimModuleSyntax": true` when targeting Node — this elides
  type-only imports correctly and keeps the ESM/CJS boundary unambiguous
  instead of TypeScript silently rewriting import syntax. For bundler-driven
  targets, pair `"module": "preserve"` with `"moduleResolution": "bundler"`
  instead (implies `esModuleInterop`), which models how bundlers and
  Bun-style runtimes actually resolve modules. For a **library** meant to run
  unbundled on Node, prefer `node16`/`nodenext` resolution over `bundler` —
  `bundler` resolution can produce output that works under a bundler but
  fails under plain Node due to missing extensions.
- Modern Node (22.12+/23+) can `require()` a synchronous ESM graph directly
  — `process.features.require_module` reports whether it's active. This
  narrows, but does not eliminate, the case for ad hoc interop: still choose
  the boundary deliberately (native `require(esm)` vs. `createRequire` vs.
  dynamic `import()`) and document it, since older supported Node/Bun
  versions may not have it.
- See `references/module-boundaries.md` for the full moduleResolution
  decision table, the `exports`-map deep dive, and worked interop examples.

## Error Handling: Operational vs Programmer Errors

- **Model errors as typed classes extending `Error`**, never throw
  strings or plain objects (`throw "failed"`, `throw { code: 500 }`) — doing
  so breaks stack traces and downstream `instanceof Error` checks. Add
  discriminating fields (`code`, `isOperational`) so a `catch` can branch
  reliably.
- **Distinguish operational errors from programmer errors.** Operational
  errors are expected failures external to a bug — bad input, a timed-out
  network call, a rejected validation. Handle them locally (`try`/`catch`,
  `.catch`) and return/report a meaningful result. Programmer errors are
  bugs — a null dereference, a failed invariant, corrupted in-memory state.
  Let them crash the process and restart via a supervisor (container
  orchestrator, systemd, process manager) rather than catching and
  continuing in a state you no longer understand.
- Never swallow an error silently — an empty `catch {}`, or a `catch` that
  only logs without rethrowing or otherwise surfacing the failure, hides
  operational failures from callers and monitoring.
- Treat `unhandledRejection`/`uncaughtException` process handlers as a
  last-resort safety net for logging/telemetry before exit, never as the
  primary way an operational error gets handled.

## Async Hygiene

- **Never leave a Promise floating.** Every async call is either `await`ed
  inside a `try`/`catch`, chained with `.catch()`, or explicitly discarded
  with a `void` and a one-line comment explaining why it's fire-and-forget.
  An unhandled rejection is, by default, a process-crashing event on modern
  Node — don't rely on that default as your error-handling strategy.
- Keep control flow flat: prefer `async`/`await` over chained `.then()`, and
  don't mix callback-style APIs with promise-style APIs inside the same
  function — pick one, wrap the other at the boundary.
- See `references/async-hygiene.md` for floating-promise patterns, the
  fire-and-forget escape hatch worked example, and the full operational-vs-
  programmer error taxonomy with examples.

## Package Exports Maps

- Define a package's public surface with an explicit `exports` map in
  `package.json` rather than letting consumers deep-import into internal
  files (`pkg/dist/internal/helper.js`). `exports` is what makes internal
  refactors safe and what makes ESM/CJS dual-publishing possible at all —
  anything not listed simply isn't importable.
- When a package must serve both `require()` and `import` consumers during a
  transition, use conditional exports (`"import"`, `"require"`, and — for
  packages opting into modern Node's synchronous ESM `require`
  — `"module-sync"`) pointing at the same or equivalent ESM output, rather
  than hand-maintaining two divergent builds. Drop the transitional
  conditions once you no longer need to support Node versions that lack
  `require(esm)`.
- A dual-published package that resolves to *different module instances*
  for its CJS and ESM consumers (the "dual package hazard" — e.g. two
  separate copies of module-level state) is a bug to design out via the
  exports map, not a quirk to work around downstream.

## Bun/Node Interchangeability

- Treat Bun and Node as interchangeable for standard JS/TS logic — Bun
  targets Node API compatibility and runs Node's own test suite pre-release,
  so "write to the common surface" is a stable long-term stance.
- **Isolate runtime-specific APIs behind a thin adapter** — `Bun.serve`,
  `bun:sqlite`, `Bun.file`, or Node's `worker_threads`/`node:sqlite` go
  behind a small module boundary (e.g. `runtime/server.ts`,
  `runtime/db.ts`) with one implementation per runtime, selected at the
  composition root. Core business logic imports the adapter's interface,
  never the runtime-specific module directly.
- Don't sprinkle `typeof Bun !== "undefined"` runtime checks through
  business logic — that's the adapter boundary leaking. Push the branch to
  the edge, once, at the adapter.

## Forbidden Patterns

1. Silencing type errors with `any`, `@ts-ignore`, or `as unknown as X`
   instead of fixing the underlying mismatch or narrowing properly.
2. Throwing non-`Error` values (`throw "failed"`, `throw { code }`).
3. Swallowing errors silently — empty `catch {}`, or catch-and-log without
   rethrowing/handling.
4. Mixing `require()` and `import` ad hoc within the same module graph with
   no deliberate interop boundary.
5. Treating a programmer error (null dereference, failed assertion,
   corrupted state) as recoverable — catching it and continuing instead of
   crashing/restarting.
6. Leaving a Promise unawaited, uncaught, and undocumented ("floating").
7. Deep-importing a package's internal files instead of its declared
   `exports` map entry points.
8. Calling a runtime-specific API (`Bun.serve`, `bun:sqlite`,
   `worker_threads`) directly from shared business logic instead of through
   an adapter.

## Final Checklist

Before accepting TypeScript/Node/Bun code as convention-compliant, confirm:

- `strict: true` is on and no sub-flag is selectively disabled.
- Dynamic/external data is `unknown` + narrowed or schema-validated at the
  boundary, never cast with `any` or a bare `as`.
- `moduleResolution`/`module` match the actual runtime target, and
  `verbatimModuleSyntax` is set when targeting `nodenext`.
- Errors are typed `Error` subclasses; operational failures are handled
  locally, programmer errors are allowed to crash and restart.
- Every Promise is awaited, `.catch()`-ed, or deliberately voided with a
  documented reason — none are left floating.
- The package's public surface is declared through `exports` in
  `package.json`, not implied by file layout.
- Runtime-specific Bun/Node APIs are isolated behind a named adapter module,
  not scattered through business logic.

## Deep Reference

For full-depth material behind these condensed rules — moduleResolution
decision tables, exports-map worked examples, dual-package-hazard detail,
floating-promise patterns, and the Bun/Node adapter pattern in full — read on
demand (not auto-loaded):

- `references/module-boundaries.md` — ESM/CJS interop boundary, the full
  `moduleResolution`/`module` decision table, `package.json` `exports` map
  patterns (including `module-sync` and dual-package-hazard avoidance), and
  worked CJS/ESM interop examples.
- `references/async-hygiene.md` — floating-promise patterns and fixes, the
  fire-and-forget escape hatch worked example, the full operational-vs-
  programmer error taxonomy with code examples, and the Bun/Node adapter
  pattern worked end-to-end.
