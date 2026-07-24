# Module Boundaries: ESM/CJS Interop, moduleResolution, and Exports Maps

Deep-dive companion to `SKILL.md`'s "ESM/CJS Module Boundary" and "Package
Exports Maps" sections. Read this on demand when a story specifically
involves `tsconfig.json` module settings, `package.json` `exports`, or a
CJS/ESM interop bug — not required for routine TypeScript work.

## Why the boundary matters

Node.js has two module systems (CommonJS and ECMAScript Modules) that resolve
imports differently, expose different globals (`__dirname`/`__filename` vs.
`import.meta.url`), and — until recently — could only cross into each other
through specific, limited mechanisms. TypeScript's compiler options
(`module`, `moduleResolution`, `verbatimModuleSyntax`) exist to tell the
compiler which of these worlds your emitted code will run in, so it can
elide type-only imports correctly and avoid rewriting syntax in ways that
break at runtime. Treating this as an incidental compiler setting rather than
a deliberate architectural choice is the root cause of most "works in my
bundler, breaks under `node`" bugs.

## moduleResolution / module decision table

| Target | `module` | `moduleResolution` | `verbatimModuleSyntax` | Notes |
|---|---|---|---|---|
| Node.js app/service | `nodenext` | `nodenext` (implied by `module`) | `true` | Matches Node's own resolution algorithm exactly, including the `.js`-extension-on-relative-import requirement for ESM. Type-only imports are elided; value imports/exports are preserved verbatim so you must write CJS-specific syntax (`import = require(...)`, `export =`) explicitly if you intend to emit CommonJS. |
| Library published to npm, run unbundled on Node | `node16` or `nodenext` | `node16` or `nodenext` | `true` recommended | Maximizes portability: `bundler` resolution can produce output that works under a bundler's looser resolution but fails under plain Node due to missing file extensions or condition mismatches. Libraries should resolve exactly the way their consumers' Node runtime will. |
| Bundler-driven app (webpack/esbuild/Vite/etc.) or Bun-first project | `preserve` (TS 5.4+) | `bundler` | `true` or `isolatedModules: true` | Models how modern bundlers and Bun actually perform module lookups, including conditional `exports`. Avoid setting `"type": "module"` in `package.json` or using `.mts` files under this combination — some bundlers implement ESM/CJS interop behaviors TypeScript can't fully analyze when resolution is `bundler`. |
| Older/legacy CJS-only codebase not yet migrating | `commonjs` | `node` (classic) | not applicable | Acceptable for now-frozen legacy code; not a target for new code. Migrate opportunistically rather than mixing new ESM-authored files into a `commonjs`-targeted compile ad hoc. |

`verbatimModuleSyntax: true` (TS 5.0+) is the modern replacement for the
older `importsNotUsedAsValues`/`preserveValueImports` flags: any import or
export **without** a `type` modifier is preserved exactly as written in the
emitted JS; anything **with** a `type` modifier is fully erased. This is what
makes the compiler's behavior at the CJS/ESM boundary predictable instead of
inferring intent from usage.

## The require(esm) shift

Historically, crossing from CommonJS into ESM required an async
`import()` (which returns a Promise, forcing an async boundary even in
otherwise-synchronous code) or restructuring the consumer as ESM itself.
Starting with an experimental flag in Node 20/22 and stabilizing across
Node 22.12+ and Node 23+, `require()` can load a **synchronous** ES module
graph directly and return its module namespace object — check
`process.features.require_module` at runtime to see whether it's active in
the current process.

This meaningfully narrows the CJS→ESM interop problem, but does not remove
the need for a deliberate boundary:

- It only works for ESM graphs that are themselves fully synchronous (no
  top-level `await` anywhere in the dependency graph).
- Older supported Node LTS lines and Bun's own compatibility surface may not
  have it enabled — code that depends on it silently breaks portability to
  those targets unless you've actually confirmed support.
- It's a resolution mechanism, not a license to stop being explicit: still
  document at the module boundary whether you're relying on native
  `require(esm)`, an explicit `createRequire`, or a dynamic `import()`, so a
  future reader (or a downgrade to an older Node) doesn't have to
  rediscover which mechanism is load-bearing.

## Exports maps in depth

An explicit `exports` field in `package.json` is what makes a package's
public API surface enforceable — anything not listed under `exports` simply
cannot be imported by a consumer, regardless of the package's actual file
layout. This is the mechanism that makes safe internal refactors and
ESM/CJS dual-publishing possible at all.

```json
{
  "name": "example-pkg",
  "type": "module",
  "exports": {
    ".": {
      "import": "./dist/index.js",
      "require": "./dist/index.cjs",
      "types": "./dist/index.d.ts"
    },
    "./subpath": "./dist/subpath.js"
  }
}
```

### The `module-sync` condition

Node 22.10 introduced a `"module-sync"` exports condition specifically as a
transitional feature-detection mechanism for dual CJS/ESM package authors
during the period where some active Node LTS lines support `require(esm)`
and some don't:

```json
{
  "type": "module",
  "exports": {
    "node": {
      "module-sync": "./index.js",
      "default": "./dist/index.cjs"
    },
    "default": "./index.js"
  }
}
```

Guidance for package authors, straight from the Node release notes:

- If you need to support both bundlers and being run unbundled on Node
  during the transition, point both `module` (the long-standing de facto
  bundler condition) and `module-sync` at the same ESM file.
- Once every Node LTS line you support has `require(esm)` enabled, simplify:
  bump a major version, drop the CJS build, and remove the `module-sync`
  condition entirely — `main`/`default` pointing straight at ESM is the
  steady-state target.
- If you don't need to support older Node versions lacking `require(esm)`
  at all, skip `module-sync` from the start; it exists only to smooth the
  transition, not as a permanent fixture.
- Bundlers/tools themselves should generally *not* implement `module-sync` —
  the existing `module` condition already covers the bundler case.

### Dual package hazard

The "dual package hazard" is what happens when a package is resolved via
*both* its CJS and ESM entry points within the same running process (e.g. one
dependency `require()`s it while another `import`s it) and the two entry
points don't actually share module-level state — you end up with two live
copies of anything the module holds at module scope (caches, singletons,
class prototypes used for `instanceof` checks). This is a design bug in the
package's `exports` map to fix — typically by ensuring both conditions
resolve to code that shares its actual state (e.g. the CJS build re-exports
from a single canonical implementation) — not a downstream workaround to
route around in every consumer.

## Worked interop example: consuming ESM-only dependency from CJS

```ts
// Before Node's require(esm): forced into an async boundary
// even though the surrounding function is otherwise synchronous.
async function loadConfig() {
  const { default: chalk } = await import("chalk"); // ESM-only package
  return chalk;
}

// With require(esm) available and confirmed (process.features.require_module):
// synchronous, matches the surrounding code's style — but document the
// dependency on this feature being enabled in your supported runtime matrix.
const chalk = require("chalk");
```

Prefer the explicit `createRequire`-based interop (`import { createRequire }
from "node:module"`) over ad hoc `require` calls in an ESM file that needs to
load a CJS-only dependency — it makes the interop point searchable and
self-documenting rather than an unexplained runtime quirk.
