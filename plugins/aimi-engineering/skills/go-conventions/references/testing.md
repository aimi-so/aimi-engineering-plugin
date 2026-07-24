# Table-Driven Tests — Deep Reference

Adapted and modified from go.dev's "How to Write Go Code" testing example
(https://go.dev/doc/code) and Effective Go's discussion of the `testing`
package — The Go Authors, CC-BY 4.0. See `../NOTICE.md`.

## The default shape

```go
package morestrings

import "testing"

func TestReverseRunes(t *testing.T) {
    cases := []struct {
        name string
        in   string
        want string
    }{
        {name: "ascii", in: "Hello, world", want: "dlrow ,olleH"},
        {name: "multibyte", in: "Hello, 世界", want: "界世 ,olleH"},
        {name: "empty", in: "", want: ""},
    }
    for _, tt := range cases {
        t.Run(tt.name, func(t *testing.T) {
            got := ReverseRunes(tt.in)
            if got != tt.want {
                t.Errorf("ReverseRunes(%q) = %q, want %q", tt.in, got, tt.want)
            }
        })
    }
}
```

A slice of anonymous structs holding each case's inputs and expected output,
walked by a `for` loop, with every case run through `t.Run(tt.name, ...)` as
its own subtest. This is the idiomatic default once a function has more than
one meaningful case worth testing — reach for it before writing three
near-identical `TestX_CaseA`, `TestX_CaseB`, `TestX_CaseC` functions that
duplicate the same assertion logic three times.

## Why `t.Run` subtests, not a bare loop

- **Isolated pass/fail per case.** `go test -run TestReverseRunes/multibyte`
  runs exactly one case; a bare loop with `t.Errorf` only tells you *some*
  iteration failed, not which, without reading the message closely.
- **Independent failure.** One case's failure doesn't stop the loop from
  running the rest — every case reports its own result.
- **Descriptive names.** `tt.name` gives each case a stable, greppable
  identity in test output (`--- FAIL: TestReverseRunes/multibyte`) instead of
  an index.

## Name fields once the table grows

```go
// Fine for two or three columns.
cases := []struct{ in, want string }{
    {"Hello, world", "dlrow ,olleH"},
}

// Once there are more columns, name them — positional literals stop being
// self-describing.
cases := []struct {
    name    string
    in      string
    setup   func(*testing.T) *Server
    wantErr bool
    want    string
}{
    {
        name:    "missing record returns ErrNotFound",
        in:      "missing-id",
        setup:   newEmptyServer,
        wantErr: true,
    },
}
```

A two-column table (`in`, `want`) reads fine positionally. Once a table
carries setup functions, error expectations, and multiple output fields,
named fields at each literal are what keeps a reviewer (or you, in six
months) from having to count commas against the struct definition to know
which value is which.

## When a table isn't the right tool

- **Cases needing genuinely different setup/teardown** (one case needs a
  live server, another needs a closed connection, a third needs a specific
  clock) usually read more clearly as separate `Test...` functions than as
  a table with a `setup func(*testing.T) *Fixture` field trying to cover
  every case's needs.
- **A single case, unlikely to grow.** A table adds structure a
  one-assertion test doesn't need yet — a plain `TestX` calling the function
  once is simpler, and can grow into a table later if more cases arrive.
- **Testable examples** (`func ExampleReverseRunes() { ... // Output: ... }`)
  are a better fit than a table entry when the goal is runnable,
  doc-comment-visible usage documentation as much as verification.
