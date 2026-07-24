# Package Layout — Deep Reference

Adapted and modified from go.dev's "Organizing a Go module"
(https://go.dev/doc/modules/layout) and Effective Go's "Package names"
(https://go.dev/doc/effective_go#package-names) and the Go Blog's "Package
names" (https://go.dev/blog/package-names) — The Go Authors, CC-BY 4.0. See
`../NOTICE.md`.

## Layout scales with module size

**Single package, root only.** The smallest modules need nothing more than a
`go.mod` and the package files at the module root:

```
modname/
  go.mod
  modname.go
  modname_test.go
```

**Package plus a command.** Once the module also ships a binary, the command
goes in `cmd/<binary-name>/`, keeping `main` separate from the importable
package logic:

```
modname/
  go.mod
  modname.go
  modname_test.go
  cmd/
    modname-server/
      main.go
```

**Multiple importable packages.** A module can export more than one
top-level package; sub-packages live in their own subdirectories and are
imported as `module/subdir`:

```
modname/
  go.mod
  modname.go
  modname_test.go
  auth/
    auth.go
    auth_test.go
    token/
      token.go
      token_test.go
  hash/
    hash.go
```

**With supporting internal packages.** Anything that exists to support the
module's own packages or commands — but isn't part of the intended public
API — goes under `internal/`:

```
modname/
  go.mod
  modname.go
  modname_test.go
  internal/
    auth/
      auth.go
      auth_test.go
    hash/
      hash.go
      hash_test.go
  cmd/
    prog1/
      main.go
    prog2/
      main.go
```

`go install module/cmd/prog1@latest` and `go install
module/cmd/prog2@latest` install each binary independently once they live
under `cmd/`.

## `internal/` is compiler-enforced, not a convention

Code under a directory named `internal/` can be imported only by code rooted
at `internal/`'s parent directory. This is mechanically enforced by the `go`
tool itself — an import of `module/internal/auth` from a different module
fails to build. That makes `internal/` the one part of "standard Go layout"
that is actually a hard boundary rather than a naming convention teams
happen to agree on. Use it for:

- Implementation details of a public package that might change shape across
  releases without notice.
- Code shared across a module's own `cmd/` binaries that has no business
  being imported by anyone else.
- Anything you want the freedom to refactor or delete without a deprecation
  cycle.

## Package naming

- Short, lowercase, one word, no underscores, no mixedCaps: `http`, `json`,
  `token` — not `HttpClient`, `json_util`, `tokenHelpers`.
- Name what the package **provides**: callers write `bufio.Reader`,
  `json.Decoder` — the package name is a prefix callers read every time they
  use an exported identifier, so a vague package name (`util`, `common`,
  `helpers`, `misc`, `core`) makes every call site vague too, and tends to
  accumulate unrelated code because nothing about the name says what
  belongs and what doesn't.
- The package name is conventionally the base name of its directory — avoid
  a directory name and package name that disagree without a good reason
  (tooling and `go doc` both assume they usually match).

## `golang-standards/project-layout` — controversial, not authoritative

`github.com/golang-standards/project-layout` is a widely-starred community
template proposing a much larger directory set: `pkg/`, `api/`, `configs/`,
`deployments/`, `test/`, `web/`, and more, on top of `cmd/` and `internal/`.
It is **not** an official Go team artifact, and it has been publicly
disputed by Russ Cox (Go's tech lead) as inappropriate to call a "standard" —
the repo describes patterns some large projects have converged on, not
something the Go toolchain recognizes or the Go team endorses.

Treat it accordingly:

- `cmd/` and `internal/` are safe to adopt on their own merits — `internal/`
  because the compiler enforces it, `cmd/` because it is exactly what
  `go.dev/doc/modules/layout` itself documents for multi-binary modules.
- The rest of the template (`pkg/`, `api/`, `configs/`, ...) is optional
  convention some larger projects find useful for organizing non-code
  assets and generated clients — not something to add reflexively to a
  small or medium module "to look standard." Prefer growing structure from
  actual need, and cite `go.dev/doc/modules/layout` when justifying a
  layout decision rather than the community template.
- If a codebase already uses the fuller template consistently, don't
  churn it out for the sake of doctrine — but don't extend it into new
  modules on the basis that it's "the standard layout," because it isn't
  one.
