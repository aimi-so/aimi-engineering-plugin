# NOTICE

This skill incorporates material adapted and modified from three upstream
sources, under three different licenses. Each is attributed separately
below with title, author, source, and license, as each source's license
requires.

---

## 1. Effective Go / go.dev documentation (CC-BY 4.0)

The conventions in `SKILL.md` covering package layout (`cmd/`, `internal/`,
package naming), error handling (error values, `%w` wrapping, `errors.Is`/
`errors.As`/`errors.Join`), context propagation, goroutine/channel
concurrency, and table-driven tests — along with the corresponding deep-dive
material in `references/package-layout.md`, `references/error-handling.md`
(wrapping/sentinel sections), `references/interfaces.md` (Effective Go
portions), `references/context-and-concurrency.md`, and `references/
testing.md` — are **adapted and modified from**:

- **Title**: Effective Go; "Organizing a Go module"; Go Blog: "Package
  names", "Organizing Go code", "Working with Errors in Go 1.13"; the
  `context` package documentation; "Canceling in-progress operations"; "How
  to Write Go Code"
- **Author**: The Go Authors
- **Source**:
  - https://go.dev/doc/effective_go
  - https://go.dev/doc/modules/layout
  - https://go.dev/blog/package-names
  - https://go.dev/blog/organizing-go-code
  - https://go.dev/blog/go1.13-errors
  - https://pkg.go.dev/context
  - https://go.dev/doc/database/cancel-operations
  - https://go.dev/doc/code
- **License**: Creative Commons Attribution 4.0 International License
  (CC-BY 4.0), https://creativecommons.org/licenses/by/4.0/

None of the above pages are reproduced verbatim. Prose, examples, and code
snippets in this skill are original wording and original example code
written to convey the same conventions the cited pages document, condensed
and reorganized for this plugin's skill-file format — this constitutes the
modification CC-BY 4.0 requires be indicated.

**Correction to source research**: the internal research note that seeded
this skill (`.aimi/research/2026-07-24-stack-conventions-skills-112211-best-practices.md`)
characterized go.dev's content license as CC-BY **3.0**, based on older,
indirect corroboration. A direct fetch of https://go.dev/doc/copyright
performed while authoring this skill confirms the site's current, live
copyright statement reads: *"Except as noted, the contents of this site are
licensed under the Creative Commons Attribution 4.0 License, and code is
licensed under a BSD license."* This NOTICE attributes go.dev content at
**CC-BY 4.0**, the version go.dev itself currently states, per this skill's
content-truth requirement to resolve conflicts between prior research and
current documentation in favor of current documentation. This confirmation
was performed against the site-wide copyright page and was not re-verified
against a page-specific footer on every individual cited URL.

---

## 2. Uber Go Style Guide (Apache License 2.0)

The "comma-ok" type-assertion guidance and the "keep wrapped-error context
succinct, avoid filler phrases" guidance in `SKILL.md`'s Explicit Error
Handling section and `references/error-handling.md` are **adapted and
modified from**:

- **Title**: Uber Go Style Guide — sections "Handle Type Assertion
  Failures" and "Error Wrapping"
- **Author**: Uber Technologies, Inc. and contributors
- **Source**: https://github.com/uber-go/guide (`style.md`)
- **License**: Apache License, Version 2.0, a copy of which is available at
  https://www.apache.org/licenses/LICENSE-2.0

Neither section is reproduced verbatim; the guidance is restated in original
wording as part of this skill's own error-handling conventions.

Unless required by applicable law or agreed to in writing, the referenced
material is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied. See the License at the
URL above for the specific language governing permissions and limitations.

---

## 3. Google Go Style Guide (CC-BY 3.0)

The "interfaces are declared by the consumer, not the producer; functions
accept interfaces but return concrete types" framing in `SKILL.md`'s Small
Interfaces section and `references/interfaces.md` is **adapted and modified
from**:

- **Title**: Google Go Style Guide — Style Decisions, "Interfaces" section
- **Author**: Google Inc.
- **Source**: https://google.github.io/styleguide/go/decisions#interfaces
  (repository: https://github.com/google/styleguide)
- **License**: Creative Commons Attribution 3.0 Unported License (CC-BY
  3.0), https://creativecommons.org/licenses/by/3.0/

This section is not reproduced verbatim; it is restated in original wording,
merged with the equivalent Effective Go framing (see §1 above) into a single
condensed convention.

This is a distinct license from §1: the Google Go Style Guide repository's
own `LICENSE` file (confirmed via direct fetch of
https://github.com/google/styleguide/blob/gh-pages/LICENSE) states CC-BY
**3.0** Unported, not the CC-BY 4.0 that the go.dev site itself currently
states for §1. Do not conflate the two when reusing material from this
skill.

---

## Summary table

| # | Source | Author | License | Where used |
|---|---|---|---|---|
| 1 | go.dev / Effective Go | The Go Authors | CC-BY 4.0 | Package layout, error handling core, context/concurrency, testing |
| 2 | Uber Go Style Guide | Uber Technologies, Inc. | Apache-2.0 | Comma-ok type assertions, succinct error wrapping |
| 3 | Google Go Style Guide | Google Inc. | CC-BY 3.0 | Consumer-defined interfaces framing |

All three sources permit adaptation with attribution. This NOTICE is
intentionally defensive: where this skill's authoring process found a
conflict between prior research and a source's current, directly-fetched
license statement, the current statement is what is recorded here.
