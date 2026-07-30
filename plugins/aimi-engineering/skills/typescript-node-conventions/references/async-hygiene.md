# Async Hygiene, Error Taxonomy, and the Bun/Node Adapter Pattern

Deep-dive companion to `SKILL.md`'s "Async Hygiene," "Error Handling," and
"Bun/Node Interchangeability" sections. Read this on demand when a story
specifically involves promise handling, process crash/restart behavior, or
building a module meant to run on both Bun and Node — not required for
routine TypeScript work.

## Floating promises: patterns and fixes

A "floating" promise is one whose eventual rejection has no handler anywhere
in the code — not `await`ed, not `.catch()`-chained, not deliberately
discarded. On modern Node, an unhandled rejection is a process-crashing
event by default (`process.on('unhandledRejection', ...)` and the
`--unhandled-rejections=mode` flag exist to observe or reconfigure this, not
to replace explicit handling as your primary strategy).

```ts
// Floating: if writeAuditLog rejects, nothing observes it. Depending on
// the Node version and --unhandled-rejections mode, this can silently
// disappear or crash the process at a moment unrelated to this call site.
function recordEvent(event: Event) {
  writeAuditLog(event); // returns a Promise, ignored
}

// Fixed: awaited inside the enclosing async function, error handled locally.
async function recordEvent(event: Event) {
  try {
    await writeAuditLog(event);
  } catch (err) {
    logger.error("audit log write failed", { err, event });
  }
}

// Fixed: deliberately fire-and-forget, explicitly marked and explained.
function recordEventBestEffort(event: Event) {
  // Best-effort telemetry; a failed write must never block the caller.
  void writeAuditLog(event).catch(err =>
    logger.warn("audit log write failed (non-blocking)", { err, event })
  );
}
```

The distinguishing feature of the "fixed" fire-and-forget version is not the
`void` keyword alone (which only silences a linter/compiler warning) — it's
that a `.catch()` is still attached so the rejection has a handler. `void`
without a trailing `.catch()` is still a floating promise; it has simply
been silenced from static analysis, which is worse than not silencing it,
because now nothing flags it for review either.

### Flat control flow

```ts
// Avoid: mixing .then() chains with await, and callback-style APIs
// with promise-style ones, inside the same function.
async function loadUser(id: string) {
  return db.query(id).then(row => {
    return normalize(row);
  });
}

// Prefer: flat async/await throughout.
async function loadUser(id: string) {
  const row = await db.query(id);
  return normalize(row);
}
```

## Operational vs. programmer errors, in depth

This taxonomy (popularized in Node.js community error-handling guidance) is
the single most useful lens for deciding *what a catch block should do*:

| | Operational error | Programmer error |
|---|---|---|
| Definition | An expected failure mode external to a bug: bad input, a timed-out network call, a rejected external API response, a full disk. | A bug: a null/undefined dereference that "shouldn't happen," a failed invariant, a broken assumption, corrupted in-memory state. |
| Example | `fetch` throws because the network is down; a request body fails schema validation. | `TypeError: Cannot read properties of undefined` because a function assumed a field that wasn't actually guaranteed present. |
| Where it's caught | Locally, close to the call site that can meaningfully react — retry, fall back, return a 4xx, log and continue. | Nowhere, on purpose — let it propagate to a top-level `uncaughtException`/`unhandledRejection` handler whose only job is to log and exit. |
| What happens next | The process keeps running; the specific request/operation fails gracefully. | The process exits and a supervisor (container orchestrator, systemd, PM2, Kubernetes restart policy) restarts it into a known-good state. |
| Why not just catch and continue? | N/A — that's the correct move. | Once an invariant you relied on has been violated, you no longer know what else in memory might be inconsistent. Catching and continuing risks silently corrupting more state or serving wrong results with high confidence. A clean restart is safer than guessing. |

```ts
class ValidationError extends Error {
  readonly isOperational = true;
  readonly code = "VALIDATION_ERROR";
  constructor(message: string, readonly field: string) {
    super(message);
    this.name = "ValidationError";
  }
}

class UpstreamTimeoutError extends Error {
  readonly isOperational = true;
  readonly code = "UPSTREAM_TIMEOUT";
  constructor(message: string, readonly service: string) {
    super(message);
    this.name = "UpstreamTimeoutError";
  }
}

async function handleRequest(input: unknown) {
  try {
    const parsed = requestSchema.parse(input); // throws a schema-library error on bad shape
    return await callUpstream(parsed);
  } catch (err) {
    if (err instanceof ValidationError || err instanceof UpstreamTimeoutError) {
      // Operational: handle locally, respond meaningfully.
      return { status: err.code === "VALIDATION_ERROR" ? 400 : 502, error: err.message };
    }
    // Not a recognized operational error — treat as a programmer error.
    // Rethrow rather than swallow; let it reach the top-level handler.
    throw err;
  }
}
```

The `isOperational`/`code` discriminating fields on the custom error classes
are what let a `catch` block (or a top-level handler) branch reliably between
"handle and continue" and "let it crash" without resorting to fragile
string-matching on `err.message`.

## Bun/Node adapter pattern, worked example

The goal is a single, obvious seam where runtime-specific code lives, so
business logic never has to know or care which runtime it's executing under.

```ts
// runtime/db.ts — the adapter's interface (shared type).
export interface DbAdapter {
  query<T>(sql: string, params?: unknown[]): Promise<T[]>;
  close(): Promise<void>;
}

// runtime/db.bun.ts — Bun-specific implementation (bun:sqlite is synchronous;
// wrapped in Promise.resolve to satisfy the shared async interface).
import { Database } from "bun:sqlite";

export function createBunDbAdapter(path: string): DbAdapter {
  const db = new Database(path);
  return {
    async query(sql, params = []) {
      return db.query(sql).all(...params);
    },
    async close() {
      db.close();
    },
  };
}

// runtime/db.node.ts — Node-specific implementation (node:sqlite, or any
// Node-native driver).
import { DatabaseSync } from "node:sqlite";

export function createNodeDbAdapter(path: string): DbAdapter {
  const db = new DatabaseSync(path);
  return {
    async query(sql, params = []) {
      return db.prepare(sql).all(...params);
    },
    async close() {
      db.close();
    },
  };
}

// composition-root.ts — the one place that branches on runtime.
import type { DbAdapter } from "./runtime/db";

export function createDb(path: string): DbAdapter {
  return typeof Bun !== "undefined"
    ? require("./runtime/db.bun").createBunDbAdapter(path)
    : require("./runtime/db.node").createNodeDbAdapter(path);
}

// business logic — imports only the shared interface, never bun:sqlite
// or node:sqlite directly, and works unmodified under either runtime.
import type { DbAdapter } from "./runtime/db";

export async function findUser(db: DbAdapter, id: string) {
  const [user] = await db.query<User>("SELECT * FROM users WHERE id = ?", [id]);
  return user ?? null;
}
```

The `typeof Bun !== "undefined"` branch appears exactly once, at the
composition root — this is the difference between an intentional adapter
boundary and the forbidden pattern of runtime checks scattered through
business logic. If a second runtime-specific concern shows up later (e.g. a
Bun-vs-Node HTTP server), it gets its own adapter pair following the same
shape, not a second branch bolted onto this one.
