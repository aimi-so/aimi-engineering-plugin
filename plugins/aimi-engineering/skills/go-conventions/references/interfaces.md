# Small Interfaces, Defined at the Consumer — Deep Reference

Adapted and modified from Effective Go's "Interfaces and methods" and
"Generality" sections (https://go.dev/doc/effective_go#interfaces_and_types)
— The Go Authors, CC-BY 4.0 — and from the Google Go Style Guide's
"Interfaces" section (https://google.github.io/styleguide/go/decisions#interfaces)
— Google Inc., CC-BY 3.0. See `../NOTICE.md` for full attribution on both.

## The core rule: consumer defines, producer implements

An interface's job is to describe what a **caller** needs, not what a
**type** happens to offer. That means the package that *calls* a dependency
through an interface is the one that should declare the interface — sized to
exactly the methods that caller uses — while the package providing the
concrete implementation exports only the concrete type.

```go
// storage/store.go — the producer. No interface here.
package storage

type Store struct{ /* ... */ }

func (s *Store) Get(id string) (*Record, error)     { /* ... */ }
func (s *Store) Put(r *Record) error                { /* ... */ }
func (s *Store) Delete(id string) error              { /* ... */ }
func (s *Store) ListByOwner(owner string) ([]*Record, error) { /* ... */ }

// billing/invoice.go — the consumer. It only ever reads records.
package billing

// recordReader is exactly what this package needs — nothing from Store's
// wider surface leaks into billing's contract.
type recordReader interface {
    Get(id string) (*Record, error)
}

func NewInvoiceService(r recordReader) *InvoiceService { /* ... */ }
```

`billing` never imports an interface from `storage`; it declares its own,
scoped to the one method it calls. `*storage.Store` satisfies it implicitly
— nothing in `storage` needs to know `billing`'s interface exists. A second
consumer with different needs (say, an admin package needing `Delete` and
`ListByOwner` too) declares its own, separately-scoped interface; the two
consumers never need to renegotiate a shared interface as one of them
changes.

## Why not declare the interface next to the implementation?

A producer-side interface tends to grow to match everything the concrete
type does, "just in case a caller needs it" — which reintroduces a fat
contract every caller depends on whether they use one method or all of them.
It also makes the concrete type harder to evolve: every method the producer
adds is now a decision about whether the shared interface should grow too.
Consumer-defined interfaces sidestep both problems: each caller's interface
is exactly as wide as that caller's actual usage, and adding a method to the
concrete type never touches an interface declaration a *different* package
owns.

## Accept interfaces, return concrete types

```go
// Right: caller passes whatever satisfies recordReader; NewInvoiceService
// gets full access to *storage.Store's methods internally if it needs them
// later, and callers of storage.NewStore keep full access to every method
// storage.Store exposes.
func NewInvoiceService(r recordReader) *InvoiceService

func NewStore(dsn string) (*Store, error)   // concrete return, not an interface
```

Returning an interface from a constructor forces every caller down to that
interface's subset of methods, even ones who need something wider — and it
makes the function's real dependency on a specific implementation opaque.
Return the concrete type; let callers narrow to whatever interface *they*
need at their own call site.

**Exception:** if a type exists solely to satisfy one interface and has no
exported behavior beyond it (a common pattern for adapting one API shape to
another), it's reasonable to keep the concrete type unexported and have the
constructor return the interface — there is no wider surface being hidden,
because there isn't one.

## Compile-time interface satisfaction checks

For any type meant to satisfy an interface — especially one it satisfies
"by convention" without embedding it — assert that at compile time next to
the implementing type:

```go
var _ io.Reader = (*BufferedSource)(nil)
var _ recordReader = (*storage.Store)(nil)
```

This costs nothing at runtime, documents the intended contract right where
the implementation lives, and turns an accidental signature drift (someone
renames or re-types a method) into a build failure instead of a runtime
surprise or, worse, a silent behavior change if a *different* incidental
method happened to satisfy the interface.

## When not to add an interface at all

If a concrete type has exactly one production implementation and no test is
substituting a fake for it, an interface is very likely premature
abstraction — introduce one when a second implementation (a fake for tests,
a second backend, a second transport) actually shows up, not speculatively
ahead of that need.
