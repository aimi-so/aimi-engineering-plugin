# Explicit Error Handling — Deep Reference

Core wrapping/inspection guidance adapted and modified from the Go Blog's
"Working with Errors in Go 1.13" (https://go.dev/blog/go1.13-errors) and
Effective Go's "Errors" section (https://go.dev/doc/effective_go#errors) —
The Go Authors, CC-BY 4.0. The succinct-wrapping note and comma-ok
type-assertion note are adapted and modified from the Uber Go Style Guide
(https://github.com/uber-go/guide), Apache-2.0. See `../NOTICE.md` for full
attribution on both.

## Errors are values, not exceptions

```go
data, err := readConfig(path)
if err != nil {
    return nil, fmt.Errorf("reading config %s: %w", path, err)
}
```

Check the error immediately, on the next line — not several statements
later, not after using the (possibly zero-valued) result. There is no
try/catch in Go; an unchecked error is a silently discarded failure.

## Wrapping: `%w`, `errors.Is`, `errors.As`

`fmt.Errorf`'s `%w` verb wraps an error so it can be found later: the
resulting error implements `Unwrap() error` (or, since Go 1.20, `Unwrap()
[]error` when the format string uses more than one `%w`), which is what lets
`errors.Is` and `errors.As` walk back through the chain.

```go
var ErrNotFound = errors.New("record not found")

func (s *Store) Get(id string) (*Record, error) {
    rec, err := s.db.Query(id)
    if errors.Is(err, sql.ErrNoRows) {
        return nil, fmt.Errorf("store: get %s: %w", id, ErrNotFound)
    }
    if err != nil {
        return nil, fmt.Errorf("store: get %s: %w", id, err)
    }
    return rec, nil
}

// Caller:
rec, err := store.Get(id)
if errors.Is(err, ErrNotFound) {
    // handle the specific, known case
}
var pathErr *fs.PathError
if errors.As(err, &pathErr) {
    // extract a concrete type from anywhere in the chain
}
```

`errors.Is(err, target)` reports whether `target` appears anywhere in `err`'s
unwrap tree — use it for sentinel errors declared with `errors.New`.
`errors.As(err, &target)` walks the same tree looking for an error whose
concrete type is assignable to `target` (or that implements a matching
`As(any) bool` method) — use it to recover a typed error and its fields.
Both perform a depth-first traversal of the whole tree, so an error wrapped
three calls deep is still found.

**Multi-error wrapping (Go 1.20+).** A single `fmt.Errorf` call can wrap more
than one error, and `errors.Join` combines any number of independent errors
into one that still supports `errors.Is`/`errors.As` against every member:

```go
if err1 != nil || err2 != nil {
    return fmt.Errorf("running both steps: %w, %w", err1, err2)
}

// or, combining independently-collected errors:
return errors.Join(errClosingA, errClosingB)
```

Reach for this when a batch operation can fail in more than one independent
way and the caller may care about any of them — not as a default replacement
for a single `%w`.

## Wrap only when it adds value

Every `%w` call site adds one more line to the error chain a human or a log
line eventually has to read. Wrap when the added context tells the caller
something they couldn't infer from the inner error alone (which operation,
which input, which resource) — not reflexively at every function boundary.
Keep the added text succinct: avoid stock phrases like `"failed to "` that
just restate the obvious and pile up as the error rises through several
layers of the call stack (`"failed to failed to failed to open file"` is a
real failure mode of over-eager wrapping).

## Sentinel errors vs. typed errors

- **Sentinel** (`var ErrX = errors.New("...")`) — use when callers only need
  to know *that* a specific, singular condition occurred (not-found, closed,
  canceled). Compare with `errors.Is`.
- **Typed** (`type ValidationError struct { Field string; ... }`, satisfying
  `error`) — use when callers need to *extract data* from the failure (which
  field, what value, what limit was exceeded). Compare with `errors.As`.
- Don't invent a typed error when a sentinel would do, and don't force a
  sentinel to carry structured data via string formatting when a typed error
  would let the caller access it directly.

## No panics in library code for expected failures

```go
// Wrong: panics on a completely ordinary "not found."
func (s *Store) MustGet(id string) *Record {
    rec, err := s.Get(id)
    if err != nil {
        panic(err)
    }
    return rec
}

// Right: the caller decides how to handle the error.
func (s *Store) Get(id string) (*Record, error) {
    // ...
}
```

Reserve `panic` for conditions that indicate a bug in the program itself
(an invariant the code assumed always holds turned out false) or for
top-level entry points (e.g., `main`) that have nowhere else to report an
unrecoverable startup failure. A library function receiving ordinary bad
input, a closed connection, or a missing record returns an `error` — it does
not decide, on the caller's behalf, that the program should crash.

## Comma-ok type assertions

The single-value form of a type assertion panics the moment the underlying
type doesn't match:

```go
// Panics if v does not hold an int.
n := v.(int)

// Reports failure instead of panicking.
n, ok := v.(int)
if !ok {
    return fmt.Errorf("expected int, got %T", v)
}
```

Use the two-value form whenever there is any realistic chance the assertion
can fail — which, outside of a handful of "we just checked this type"
situations, is most of the time. This is the same discipline as checking an
error: prefer a reportable failure to a crash.
