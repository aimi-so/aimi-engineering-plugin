# NOTICE

This skill incorporates material adapted from three official rust-lang
projects. Each is **dual-licensed under your choice of the MIT License or
the Apache License, Version 2.0 — licensed under either MIT or Apache-2.0,
at your option.** This is the standard licensing convention used across
the Rust project and its ecosystem. The MIT license body is reproduced
below; the Apache-2.0 license is referenced by link. Each source's own
copyright notice is quoted in its own section.

---

## Sources Incorporated

### 1. Rust API Guidelines

- **Repository**: https://github.com/rust-lang/api-guidelines
- **Site**: https://rust-lang.github.io/api-guidelines/
- **License**: MIT OR Apache-2.0 (confirmed directly via
  `LICENSE-MIT`/`LICENSE-APACHE` at the repository root)
- **Copyright (MIT text)**: Copyright (c) 2017 The Rust Project Developers
- **Copyright (Apache text)**: Copyright [yyyy] [name of copyright owner]
  (the repository's own `LICENSE-APACHE` file carries the unfilled
  standard Apache boilerplate at this field; reproduced here exactly as
  found upstream rather than filled in speculatively)

The RFC 430 naming table, the conversion-method (`as_`/`to_`/`into_`)
naming guidance, and the flexibility/generics guidance in
`references/naming-and-api-design.md` are rewritten adaptations of this
project's `naming.md` and `flexibility.md` pages. Illustrative code
snippets closely following this source's own examples (`read_config`,
`sum_values`, `as_bytes`/`to_uppercase`/`into_bytes`) are used as teaching
examples under the same license.

### 2. The Rust Programming Language ("The Book")

- **Repository**: https://github.com/rust-lang/book
- **Site**: https://doc.rust-lang.org/book/
- **License**: MIT OR Apache-2.0 (confirmed directly via
  `LICENSE-MIT`/`LICENSE-APACHE` at the repository root)
- **Copyright (MIT text)**: Copyright (c) 2010 The Rust Project Developers
- **Copyright (Apache text)**: Copyright 2010 The Rust Project Developers

The ownership/borrowing guidance, the `Result`/`Option`/`?` error-handling
guidance, and the file-per-module vs. `mod.rs` module-organization
guidance in `SKILL.md` and `references/error-handling.md` /
`references/module-organization.md` are rewritten adaptations of this
project's "References and Borrowing," "Error Handling," "Separating
Modules into Different Files," and "Exporting a Convenient Public API"
chapters. Several short code examples (the `read_username_from_file` `?`
progression, the `art` crate `pub use` example, the `front_of_house`
re-export example) are reproduced close to verbatim as teaching examples,
as permitted under this project's license for both prose and code.

### 3. Clippy

- **Repository**: https://github.com/rust-lang/rust-clippy
- **Site**: https://doc.rust-lang.org/clippy/, https://rust-lang.github.io/rust-clippy/
- **License**: MIT OR Apache-2.0 (confirmed directly via
  `LICENSE-MIT`/`LICENSE-APACHE` at the repository root)
- **Copyright (MIT text)**: Copyright (c) The Rust Project Contributors

The clippy-as-CI-gate guidance, the `unwrap_used`/`expect_used` lint
configuration detail, and the CI snippets in `references/clippy-ci.md`
are rewritten adaptations of this project's own "Continuous Integration"
and "Lint Configuration" documentation pages. The GitHub Actions, GitLab
CI, and Travis CI snippets are reproduced close to verbatim from this
project's own documentation, as permitted under its license.

---

## What Is Adapted vs. Reproduced

None of `SKILL.md` or `references/` is a bulk copy of any of the three
sources above. The condensed rules, forbidden-pattern lists, and
explanatory prose throughout this skill are rewritten and reorganized for
this plugin's use as agent-facing conventions — not reproduced verbatim.
Short illustrative code snippets that closely follow (or, in a few small
cases, directly reuse) an upstream example are called out per-source
above; these are the kind of short, illustrative excerpts both licenses
expressly permit to redistribute with attribution, and this NOTICE
preserves the required copyright and permission notices from each
upstream project as both licenses require for any redistributed copy or
substantial portion of the licensed material.

The **thiserror-for-libraries, anyhow-for-applications** guidance in
`SKILL.md`/`references/error-handling.md` is **not** adapted from any of
the three sources above — it is stated as widely-held Rust community
consensus (corroborated by multiple independent sources, none of them
official rust-lang documentation) and is explicitly labeled as such in
`SKILL.md` rather than attributed to a specific licensed source.

---

## MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

(Each source's specific copyright line is quoted under "Sources
Incorporated" above; this is the shared body text of the MIT License each
of the three upstream `LICENSE-MIT` files carries.)

---

## Apache License, Version 2.0

Each source above is offered under the Apache License, Version 2.0 as one of
its two "at your option" license grants. The full license text is available
at https://www.apache.org/licenses/LICENSE-2.0. The per-source Apache-text
copyright lines are quoted under "Sources Incorporated" above, matching each
source's own `LICENSE-APACHE` file; those retained notices satisfy the
license's attribution requirements.
