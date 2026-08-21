---
name: go-conventions
description: >
  Use when writing, reviewing, or scaffolding Go code — package layout under a
  module, error handling and wrapping, interface design, context propagation,
  goroutine/channel concurrency, or test authoring. Applies evergreen,
  version-independent Go conventions confirmed against current go.dev
  documentation: cmd/+internal/ module layout, error values wrapped with %w
  and inspected with errors.Is/errors.As/errors.Join, consumer-defined small
  interfaces, context.Context as an explicit first parameter, goroutine exit
  guarantees, channels-vs-mutex tradeoffs, and table-driven tests. Trigger
  phrases: Go package layout, internal package, cmd directory, Go error
  wrapping, errors.Is, errors.As, Go interfaces, accept interfaces return
  structs, context.Context, goroutine leak, channels vs mutex, table-driven
  test, gofmt, Go project structure, golang-standards/project-layout.
license: CC-BY 4.0, Apache-2.0, CC-BY 3.0 (NOTICE.md)
metadata:
  version: "1.0.0"
---

# Go Conventions

Condensed, actionable conventions for structuring, error-handling, and
testing Go code — sourced from Effective Go and the go.dev documentation
(cross-checked against current docs via Context7 before finalizing), with two
supplementary style-guide conventions where they add something go.dev doesn't
spell out. Full-depth material and extended examples live under
`references/`; this file carries everything needed to write or review
idiomatic Go without reading further.

> **Attribution**: Package layout, error handling, interface, context/
> concurrency, and testing guidance below is adapted and modified from
> Effective Go and the go.dev documentation (The Go Authors, CC-BY 4.0). The
> comma-ok type-assertion and succinct-wrapping notes are adapted from the
> Uber Go Style Guide (Apache-2.0); the consumer-side interface framing is
> adapted from the Google Go Style Guide (CC-BY 3.0). None of these sources
> are reproduced verbatim — see `NOTICE.md` for full attribution.

## When to Use

- Scaffolding a new Go module or package and deciding what goes where
  (`cmd/`, `internal/`, package boundaries, package naming).
- Writing or reviewing error handling — creating, wrapping, or inspecting
  errors.
- Designing a function or package's interface surface, including whether an
  interface belongs here at all.
- Writing code that does I/O, spawns goroutines, or needs to be cancellable.
- Writing tests for a function with more than one meaningful case.

## Package Layout

- Package names are short, lowercase, single-word, no underscores or
  mixedCaps, and name what the package *provides* (`http`, `json`), never
  what it *contains* (`util`, `common`, `helpers`, `misc`) — those names
  invite unrelated code to accumulate with no cohesion.
- `internal/` holds code the module does not want imported by other modules;
  the Go toolchain mechanically enforces this — nothing outside the tree
  rooted at `internal/`'s parent can import it. This is a compiler-enforced
  boundary, not a naming convention.
- `cmd/` holds one subdirectory per binary the module produces, each a
  `package main`; `go install module/cmd/prog@latest` installs it directly.
  Use `cmd/` once a module produces more than one binary, or once a single
  binary's `main` package needs supporting code that should not itself be
  part of the module's importable API.
- A module's importable surface is deliberately small: a handful of
  top-level (or nested) packages, each with a clear single responsibility,
  everything else pushed into `internal/`.
- **`golang-standards/project-layout` is a disputed community template, not
  an official or standard Go layout** — Russ Cox has publicly pushed back on
  it being called a standard. `cmd/` + `internal/` is the one piece of that
  template actually backed by toolchain behavior; do not adopt its other
  directories (`pkg/`, `api/`, `configs/`, ...) on the strength of that repo
  alone. Prefer [go.dev/doc/modules/layout](https://go.dev/doc/modules/layout)
  as the authoritative source for module organization.
- See `references/package-layout.md` for layout examples at each module size.

## Explicit Error Handling

- Errors are values: the last return value, checked immediately
  (`if err != nil { return ..., err }`), never exceptions or ordinary
  control flow via `panic`.
- Wrap with context using `fmt.Errorf("doing X: %w", err)` — the `%w` verb
  makes the result satisfy `Unwrap() error`, keeping the chain inspectable.
  Since Go 1.20, `fmt.Errorf` also accepts **more than one** `%w` verb in a
  single call, producing `Unwrap() []error`; `errors.Join(errs...)` combines
  independent errors (e.g., from a batch of operations) the same way.
- Inspect wrapped chains with `errors.Is(err, sentinel)` for sentinel-value
  comparison and `errors.As(err, &target)` to extract a concrete error type
  — both walk the full `Unwrap` tree. Never `strings.Contains(err.Error(), …)`
  to detect an error kind; message text is not a stable contract.
- Only wrap when the added context is genuinely useful to the caller. Don't
  wrap reflexively at every call site, and keep the added context succinct
  — avoid filler like "failed to" that states the obvious and piles up as
  the error rises through the stack.
- **No panics in library code for expected failures** — a missing record, a
  bad argument, a failed parse are `error` returns, not `panic`. Reserve
  `panic` for programmer errors and truly unrecoverable state, and only at
  the top of a call chain a caller cannot reasonably continue past.
- Always use the two-value ("comma-ok") form of a type assertion —
  `v, ok := x.(T)` — when there is any chance `x` isn't a `T`. The
  single-value form panics on mismatch, turning a data problem into a crash.
- See `references/error-handling.md` for wrapping depth, sentinel-vs-typed
  error tradeoffs, and `errors.Join` batch-error examples.

## Small Interfaces, Defined at the Consumer

- Interfaces are declared by the package that **consumes** a dependency
  through them, sized to exactly what that consumer calls — not
  pre-declared by the producer "in case someone needs to mock it."
  A single-method interface capturing just what's needed is the common case.
- Functions accept the smallest interface that satisfies their needs and
  **return concrete types**, so callers keep full access to every method the
  concrete type offers rather than being limited to a pre-chosen subset.
- A type that exists solely to satisfy an interface, with no exported
  methods beyond it, doesn't need to be exported itself — export the
  interface, keep the implementation private, and have any constructor
  return the interface type.
- Assert intended interface satisfaction at compile time next to the
  implementing type: `var _ SomeInterface = (*ConcreteType)(nil)`. This
  turns accidental interface drift into a compile error instead of a
  surprise at the call site.
- See `references/interfaces.md` for producer-vs-consumer examples and the
  compile-time satisfaction-check pattern in more depth.

## Context Propagation & Concurrency

- `context.Context` is the **first parameter** of any function doing I/O,
  RPC, or long-running work, conventionally named `ctx`, and flows explicitly
  through the call chain — it is never stored inside a struct field.
- Derive contexts for cancellation/deadlines with `context.WithCancel` /
  `context.WithTimeout` / `context.WithDeadline`, and **always `defer
  cancel()`** immediately after creating the derived context so resources
  are released once the enclosing function returns, whether or not the
  timeout fired.
- Every goroutine has a guaranteed, reachable exit path — tied to context
  cancellation, a `sync.WaitGroup`, a closed/buffered channel, or an
  `errgroup.Group`. A goroutine with no way for its caller to learn it
  finished, or to stop it, is a leak waiting to happen in a long-running
  service.
- Choose concurrency primitives deliberately: use **channels** to hand
  ownership of a value or a result from one goroutine to another ("share
  memory by communicating" — structure the program so only one goroutine
  owns a piece of data at a time); use **`sync.Mutex`/`sync.RWMutex`** to
  guard simple shared in-memory state (a map, a counter) accessed
  concurrently. Neither is a default — pick the one that matches whether
  you're transferring ownership or protecting shared state.
- See `references/context-and-concurrency.md` for goroutine-leak examples
  and a worked channels-vs-mutex decision walkthrough.

## Table-Driven Tests

- The idiomatic default for exercising multiple cases of one function is a
  slice of anonymous structs plus a loop, with each case run as its own
  subtest: `for _, tt := range cases { t.Run(tt.name, func(t *testing.T) {
  ... }) }`. Subtests give per-case pass/fail output and let cases run in
  isolation.
- Name struct-literal fields in the table (`{name: "...", in: "...", want:
  "..."}`) once a table has more than two or three columns — positional
  literals stop being self-describing as columns are added.
- See `references/testing.md` for a full table-test template and guidance on
  when a table is the wrong tool (cases needing genuinely different setup).

## Forbidden Patterns

- Discarding a returned error (`result, _ := someCall()`) instead of
  checking and handling or propagating it.
- Panicking on expected, ordinary failure conditions instead of returning an
  `error`.
- String-matching an error's message instead of `errors.Is`/`errors.As`.
- Storing `context.Context` in a struct field instead of passing it
  explicitly as each function's first parameter.
- Spawning a goroutine with no cancellation path and no wait mechanism —
  no `context`, no `WaitGroup`, no channel signaling completion.
- Presenting `golang-standards/project-layout` as *the* standard Go project
  layout rather than a disputed community template.
- A package named `util`, `common`, `helpers`, or `core` used as a dumping
  ground instead of a cohesive, purpose-named package.

## Final Checklist

Before accepting Go code in review, confirm:

- `internal/` hides implementation detail; `cmd/` holds one `main` per
  binary; no package is named as a generic dumping ground.
- Every returned error is checked; wraps use `%w` and add real context;
  callers branch with `errors.Is`/`errors.As`, never message matching.
- No library-code panics on ordinary, expected failure — only on programmer
  error or truly unrecoverable state.
- Interfaces are small, declared where they're consumed, and functions
  return concrete types.
- Every function doing I/O takes `ctx context.Context` as its first
  parameter; no `Context` lives in a struct field.
- Every goroutine has a visible exit path; channel vs. mutex choice matches
  ownership-transfer vs. shared-state-guarding.
- Multi-case tests are table-driven with named `t.Run` subtests.

## Deep Reference

For extended examples, edge cases, and the two supplementary style-guide
notes, read on demand (not auto-loaded):

- `references/package-layout.md` — module layout at each size, package
  naming, the `golang-standards/project-layout` controversy in full.
- `references/error-handling.md` — wrapping depth, sentinel vs. typed
  errors, `errors.Join`/multi-`%w`, comma-ok type assertions.
- `references/interfaces.md` — consumer-vs-producer interface examples,
  compile-time satisfaction checks.
- `references/context-and-concurrency.md` — goroutine-leak patterns,
  channels-vs-mutex walkthrough, `errgroup` usage.
- `references/testing.md` — table-test template, subtests, when tables
  don't fit.
