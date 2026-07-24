---
name: rust-conventions
version: "1.0.0"
description: >
  Use when writing, reviewing, or refactoring Rust code — ownership and
  borrowing decisions, Result/Option error handling, the ? operator,
  choosing between thiserror and anyhow, module and crate organization,
  naming, or setting up clippy/rustfmt as a CI gate. Applies evergreen,
  version-independent Rust conventions distilled from the official Rust
  Book, the Rust API Guidelines, and Clippy's own documentation, each
  cross-checked against current upstream docs via Context7. Trigger
  phrases: Rust code review, ownership, borrow checker, clone, Result,
  Option, error handling, thiserror, anyhow, unwrap, expect, module
  organization, crate layout, pub use, RFC 430, clippy, rustfmt, CI gate,
  idiomatic Rust.
license: MIT OR Apache-2.0 (NOTICE.md)
---

# Rust Conventions

Condensed, actionable Rust conventions for writing and reviewing Rust code —
ownership idioms, `Result`/`Option` error handling, module organization,
naming, and the `clippy`/`rustfmt` CI gate. Deep-dive material and extended
examples live under `references/`; this file carries everything needed to
make a Rust convention decision without reading further.

> **Attribution and verification**: The rules below adapt guidance from the
> official [Rust Programming Language book](https://doc.rust-lang.org/book/),
> the [Rust API Guidelines](https://rust-lang.github.io/api-guidelines/), and
> [Clippy](https://github.com/rust-lang/rust-clippy)'s own documentation —
> all three dual-licensed MIT OR Apache-2.0. Every claim in this file was
> cross-checked against those sources' current documentation via the
> Context7 MCP before being finalized. See `NOTICE.md` for full
> attribution and license text.

## When to Use

- Writing new Rust code and deciding how to model ownership, errors, or
  module structure.
- Reviewing a Rust pull request for idiom violations (needless clones,
  `unwrap()` on fallible paths, a leaking `mod.rs`/file-per-module mix).
- Setting up or auditing a Rust project's CI pipeline for a `clippy`/`fmt`
  gate.
- Deciding whether a crate should depend on `thiserror` or `anyhow` for its
  error type.

## The Rule That Matters Most

**Let the compiler enforce ownership; let convention decide how to work with
it.** The borrow checker will not let unsound code compile — but it will
happily accept code that clones its way past every borrow error. Idiomatic
Rust prefers `&T`/`&mut T` (borrowing) over `.clone()`/move by default,
reserving `.clone()` for when ownership genuinely must be duplicated
(crossing a thread boundary, storing owned data past the borrower's
lifetime) rather than as a reflexive fix for a compiler complaint. Every
other rule below exists to keep that discipline consistent across a crate.

## Ownership: Borrow Over Clone

- Accept `&T` (or `&mut T` when mutation is needed) in function signatures
  by default; only take an owned `T` when the function must store, move, or
  transform-and-return the value.
- Reach for `.clone()` when ownership genuinely needs duplicating — not as
  a default response to a borrow-checker error. Excessive `.clone()` calls
  sprinkled through a codebase to silence the compiler are a sign the
  ownership/lifetime structure needs restructuring, not a style choice.
- `Rc`/`Arc`/`RefCell`/`Mutex` solve a specific sharing or interior-mutability
  problem (shared ownership across a graph, mutation behind an immutable
  API, cross-thread shared state). Reach for them deliberately, for that
  problem — not as a default escape hatch the moment the borrow checker
  pushes back. `Rc<RefCell<T>>` in particular is worth a second look before
  reaching for it reflexively: it usually means the data model or lifetime
  structure could be simplified instead.
- In public function signatures, accept the least restrictive type that
  still works — a borrow over an owned value, a trait bound
  (`impl AsRef<Path>`, `impl IntoIterator<Item = T>`) over a concrete
  collection type — so callers aren't forced into unnecessary conversions.
  See `references/naming-and-api-design.md` for the full flexibility
  guidance and examples.

## Error Handling: Result, ?, and the thiserror/anyhow Boundary

- Fallible functions return `Result<T, E>`; values that are optional but
  never an error return `Option<T>`. Never encode "might not have a value"
  or "might fail" with sentinels (`-1`, empty-string, magic numbers).
- Propagate errors with the `?` operator instead of manual `match`/`unwrap`
  chains at every fallible call — this is Rust's idiomatic, compiler-assisted
  propagation mechanism.
- **Library crates define a specific error enum (commonly via `thiserror`)
  so callers can `match` on failure variants. Application/binary crates use
  a broad, ergonomic error type (commonly `anyhow::Error`) since their
  caller is a human or a log, not code that branches on failure mode.** This
  "thiserror for libraries, anyhow for applications" boundary is **widely-held
  community consensus among Rust practitioners, corroborated by multiple
  independent sources — it is not an official rust-lang policy or a rule
  enforced by any tool.** Treat it as a strong default, not a spec
  requirement: a library that legitimately only has one caller, or an
  application that re-exports part of itself as a library, can reasonably
  deviate.
- `.unwrap()`/`.expect()` are fine in tests, quick prototypes, and call
  sites where the invariant is compiler-provable (e.g. indexing a
  fixed-size array you just constructed) — not on paths that handle
  untrusted or fallible input in production code. Clippy's `unwrap_used`
  and `expect_used` lints enforce this, but they live in the **allow-by-default
  `clippy::restriction` group** — they do nothing until a crate opts in
  explicitly (`#![warn(clippy::unwrap_used)]`, a `[lints.clippy]` table in
  `Cargo.toml`, or equivalent). See `references/error-handling.md` for the
  opt-in config, `thiserror`/`anyhow` examples, and the forbidden-pattern
  detail.

## Module and Crate Organization

- Prefer the file-per-module style (`foo.rs` + a `foo/` sibling directory
  for its submodules) over the older `foo/mod.rs`-in-every-directory style
  for new code. The Rust Book itself now names the first "the modern,
  idiomatic style" and the second "the older style" — functionally
  equivalent, but mixing both conventions within the same crate is
  confusing (and using both for the *same* module is a compiler error).
- Curate a crate's public API with explicit `pub use` re-exports at the
  crate root, keeping internal module structure free to be reorganized
  without breaking downstream consumers. Keep internals `pub(crate)` (or
  private) and re-export only the flat, stable surface consumers need — the
  Book's own guidance for "Exporting a Convenient Public API" is exactly
  this pattern.
- Types that logically support it implement standard traits (`Debug`,
  `Clone`, `PartialEq`, `Default`, etc.) via `#[derive(...)]` rather than
  hand-rolled equivalents — this is what lets a type interoperate naturally
  with formatting, collections, and comparisons across the ecosystem.
- See `references/module-organization.md` for a worked crate layout and the
  `pub use` re-export pattern in full.

## Naming: RFC 430

Rust's ecosystem-wide naming convention, enforced by `rustfmt`/`clippy::style`
and near-universally followed:

| Item | Convention | Example |
|---|---|---|
| Types, traits, enum variants | `UpperCamelCase` | `struct Config`, `trait Messenger`, `enum Status { Active }` |
| Functions, methods, modules, variables | `snake_case` | `fn read_config()`, `mod error_handling`, `let max_size` |
| Constants, statics | `SCREAMING_SNAKE_CASE` | `const MAX_SIZE: usize = 1024;` |
| Type parameters | concise `UpperCamelCase`, usually one letter | `struct Container<T>` |
| Lifetimes | short `lowercase`, usually one letter | `'a`, `'de` |
| Macros | `snake_case!` | `my_macro!()` |

Acronyms count as one word in `UpperCamelCase` (`Uuid`, not `UUID`; `Stdin`,
not `StdIn`) and are lower-cased in `snake_case` (`is_xid_start`). See
`references/naming-and-api-design.md` for the full table (crates, features,
conversion-method prefixes `as_`/`to_`/`into_`) and derive-trait guidance.

## Clippy and Rustfmt as a CI Gate

- `cargo clippy` and `cargo fmt --check` run in CI as a **hard gate**, not
  an optional nicety. Clippy catches idiom violations (needless clones,
  manual patterns with a stdlib equivalent, etc.) that `rustc` alone will
  not flag; `rustfmt` removes formatting bikeshedding entirely.
- Make CI actually fail on lint warnings — a bare `cargo clippy` only
  prints them. Set `RUSTFLAGS="-Dwarnings"` or run
  `cargo clippy --all-targets --all-features -- -D warnings` so warnings
  (including clippy lints) fail the build, per Clippy's own CI
  documentation. See `references/clippy-ci.md` for GitHub Actions/GitLab
  snippets and the useful lint groups beyond the default set (`pedantic`,
  `restriction`, `nursery`).

## Forbidden Patterns

- `.unwrap()`/`.expect()` on `Result`/`Option` in library or production
  code paths that handle untrusted or fallible input, instead of
  propagating with `?` or handling `Err`/`None` explicitly.
- A library crate exposing `anyhow::Error` (or an equally opaque boxed
  error) as its public error type, forcing every downstream consumer into
  a type they cannot `match` on.
- Defaulting to `Rc<RefCell<T>>` (or `Arc<Mutex<T>>` in single-threaded
  code) to "get past" a borrow-checker complaint instead of restructuring
  ownership.
- Excessive `.clone()` calls used to silence the borrow checker instead of
  restructuring lifetimes/borrows.
- Mixing the `foo.rs` + `foo/` and `foo/mod.rs` module-file conventions
  inconsistently within the same crate.

## Final Checklist

Before accepting a Rust change, confirm:

- Function signatures borrow (`&T`) rather than take ownership unless
  ownership is genuinely needed; `.clone()` calls have a specific reason.
- Fallible functions return `Result<T, E>`; optional-but-not-erroring
  values return `Option<T>`; `?` propagates instead of manual matches.
- The crate's error type matches its role: a specific `thiserror` enum for
  a library, a broad `anyhow::Error` for an application binary — and that
  boundary is understood as strong convention, not a spec rule.
- `.unwrap()`/`.expect()` calls are confined to tests, prototypes, or
  compiler-provable invariants.
- Module files consistently use one convention (file-per-module or
  `mod.rs`), and the public API is a curated set of `pub use` re-exports.
- Naming follows RFC 430 casing throughout.
- CI runs `cargo clippy` and `cargo fmt --check` as a gate that actually
  fails on warnings (`-D warnings`), not just prints them.

## Deep Reference

For the full-depth material behind these condensed rules — additional
examples, the complete RFC 430 table, and CI configuration snippets — read
on demand (not auto-loaded):

- `references/error-handling.md` — `Result`/`?` in depth, the
  `thiserror`/`anyhow` boundary with examples, `unwrap_used`/`expect_used`
  lint configuration.
- `references/module-organization.md` — file-per-module vs `mod.rs` layout,
  `pub use` re-export pattern, `pub(crate)` internals.
- `references/naming-and-api-design.md` — full RFC 430 table, conversion
  method naming (`as_`/`to_`/`into_`), derive-trait and generics/flexibility
  guidance.
- `references/clippy-ci.md` — CI snippets (GitHub Actions, GitLab CI,
  Travis), clippy lint groups (`pedantic`, `restriction`, `nursery`) and
  configuration.
