# Context7 Cross-Check Log

Source research: `.aimi/research/2026-07-24-stack-conventions-skills-112211-best-practices.md`
§ 5 (Rust). Every load-bearing claim in `SKILL.md`/`references/` was
cross-checked against current documentation via the Context7 MCP
(`resolve-library-id` → `query-docs`) against three libraries:

- `/rust-lang/book` — The Rust Programming Language
- `/rust-lang/api-guidelines` — Rust API Guidelines
- `/rust-lang/rust-clippy` — Clippy

No conflicts were found between the research file and current upstream
docs. The queries below either **confirmed** a claim as-is or **refined**
it with a detail current docs surfaced that the research summary didn't
capture.

## Confirmed As-Is

- **Borrow over clone.** `/rust-lang/book` "References and Borrowing"
  (ch04-02) and the accompanying `.clone()` example confirm: functions
  take `&T` to avoid taking ownership; `.clone()` is presented as the
  explicit, deliberate tool for when a deep copy is actually needed.
- **`Result`/`Option`/`?`.** `/rust-lang/book` ch09-00 confirms the
  recoverable (`Result`) vs. unrecoverable (`panic!`) split verbatim, and
  ch09 examples confirm `?` as the idiomatic replacement for manual
  `match`-and-early-return propagation.
- **RFC 430 naming table.** `/rust-lang/api-guidelines`
  `naming.md`/"Casing Conforms to RFC 430 (C-CASE)" reproduces the exact
  casing table used in `references/naming-and-api-design.md`
  (`UpperCamelCase` types/traits/variants, `snake_case`
  functions/methods/modules/variables, `SCREAMING_SNAKE_CASE`
  constants/statics, single-letter type parameters/lifetimes), including
  the acronym-as-one-word rule (`Uuid`, not `UUID`).
- **`pub use` re-exports at the crate root.** `/rust-lang/book`
  ch14-02 ("Exporting a Convenient Public API") and ch07-04
  ("Re-exporting Names with `pub use`") confirm the pattern and the exact
  `art`-crate example used in `references/module-organization.md`.
- **Minimal trait bounds / flexibility.** `/rust-lang/api-guidelines`
  `flexibility.md` (C-GENERIC) confirms "accept the least restrictive
  type/bound the implementation needs" via the same `AsRef<Path>` and
  `IntoIterator` examples reproduced in
  `references/naming-and-api-design.md`, including the documented
  trade-off (monomorphization cost, verbosity) the research didn't spell
  out.
- **Clippy CI gate.** `/rust-lang/rust-clippy`'s own "Continuous
  Integration" docs confirm the exact mechanism: `cargo clippy` alone
  exits `0` on lint warnings, and `RUSTFLAGS="-Dwarnings"` (or
  `-- -D warnings`) is the documented way to make CI actually fail. The
  GitHub Actions/GitLab/Travis snippets in `references/clippy-ci.md` are
  adapted directly from Clippy's own CI documentation pages.

## Confirmed With a Refinement

- **File-per-module vs `mod.rs`.** The research described this as a
  preference "tooling has nudged toward since 1.30." Current
  `/rust-lang/book` ch07-05 ("Separating Modules into Different Files")
  goes further and names it directly: the file-per-module style is now
  called **"the modern, idiomatic style"** and `mod.rs` **"the older
  style"** in the Book's own prose — a stronger, more citable framing than
  the research anticipated. The Book also confirms mixing conventions
  within one project is legal-but-discouraged, and using both for the
  *same* module is a compiler error, not just a lint. `SKILL.md` and
  `references/module-organization.md` were worded to use the Book's own
  "modern idiomatic" / "older style" language directly.
- **`unwrap_used`/`expect_used` are opt-in, not ambient.** The research
  correctly named these as the enforcement mechanism but didn't note that
  Clippy's own `lint_configuration.md` places both lints in the
  **allow-by-default `clippy::restriction` group** — `cargo clippy` does
  nothing with them until a crate explicitly enables them (`#[warn(...)]`,
  `#[deny(...)]`, or a `[lints.clippy]` table in `Cargo.toml`). Docs also
  surfaced two configuration knobs worth documenting:
  `allow-unwrap-in-tests` (default `false`) and `allow-unwrap-types`
  (default `[]`). `SKILL.md`'s Error Handling section and
  `references/error-handling.md` were updated to state the opt-in
  requirement explicitly rather than implying `cargo clippy` catches
  these lints out of the box.

## Deliberately Not Re-Verified Against Official Docs

- **The thiserror/anyhow library-vs-application boundary.** Per the story's
  requirement, this is stated in `SKILL.md` as community consensus, not
  official rust-lang policy — there is no rust-lang team document to
  cross-check it against, and Context7 has no indexed rust-lang-authored
  source that takes a position on it. The research's own citation trail
  (multiple independent 2026 blog sources converging on the same rule of
  thumb) is the correct kind of evidence for a community-consensus claim
  and was left as-is.
- **`thiserror`/`anyhow` crate-level API specifics** (attribute syntax,
  `#[from]` behavior) were used from general Rust ecosystem knowledge for
  the illustrative code samples in `references/error-handling.md`; these
  are third-party crate docs (docs.rs), not one of the three dual-licensed
  sources this skill attributes, and are illustrative rather than
  normative claims.
