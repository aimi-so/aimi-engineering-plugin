# Context Propagation & Concurrency — Deep Reference

Adapted and modified from the `context` package documentation
(https://pkg.go.dev/context), the "Canceling in-progress operations" guide
(https://go.dev/doc/database/cancel-operations), and Effective Go's
"Concurrency" section (https://go.dev/doc/effective_go#concurrency) — The Go
Authors, CC-BY 4.0. See `../NOTICE.md`.

## `context.Context` is a parameter, never a field

```go
// Right: ctx flows explicitly through every call that might block, do I/O,
// or need to be canceled.
func (s *Server) HandleOrder(ctx context.Context, orderID string) error {
    order, err := s.store.Get(ctx, orderID)
    if err != nil {
        return fmt.Errorf("loading order %s: %w", orderID, err)
    }
    return s.notifier.Send(ctx, order)
}

// Wrong: ctx frozen at construction time, no longer reflects the caller's
// actual deadline/cancellation for calls made through this struct later.
type Server struct {
    ctx context.Context // don't do this
}
```

`ctx` is always the first parameter, always named `ctx`, and is passed to
every function down the call chain that might block, perform I/O, or need to
respect cancellation. Storing it in a struct field freezes it at
construction time and disconnects every later call through that struct from
the caller's actual deadline or cancellation signal — exactly the failure
mode explicit parameter-passing exists to prevent.

## Deriving contexts for cancellation and deadlines

```go
func (s *Server) QueryWithTimeout(ctx context.Context, q string) (Rows, error) {
    queryCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
    defer cancel() // always defer immediately, before anything can return early

    return s.db.QueryContext(queryCtx, q)
}
```

`context.WithCancel`, `context.WithTimeout`, and `context.WithDeadline` each
derive a new, more restrictive context from a parent. Cancellation
propagates downward through the whole derived tree: canceling (or timing
out) the parent cancels every context derived from it. Always `defer
cancel()` right after creation — this releases resources tied to the
derived context as soon as the enclosing function returns, whether it
returned because the operation finished, failed, or the timeout fired.
Skipping the `defer` leaks the context's internal timer/goroutine until the
parent itself is canceled or the process exits.

## Every goroutine needs a visible exit

```go
// Leak: nothing ever tells this goroutine to stop, and nothing waits for it.
go func() {
    for {
        process(<-work)
    }
}()

// Fixed: tied to ctx cancellation, with a WaitGroup so the caller can
// observe completion.
func (s *Server) runWorker(ctx context.Context, wg *sync.WaitGroup, work <-chan Job) {
    wg.Add(1)
    go func() {
        defer wg.Done()
        for {
            select {
            case <-ctx.Done():
                return
            case job := <-work:
                process(job)
            }
        }
    }()
}
```

A goroutine spawned with no `context`, no `sync.WaitGroup`, and no channel
signaling its completion is a goroutine the rest of the program can neither
stop nor wait for — the standard root cause of goroutine leaks in
long-running services. For a group of goroutines all doing related work
where the first error should stop the rest, `golang.org/x/sync/errgroup`
packages this pattern (shared cancellation + first-error propagation +
`Wait()`) instead of hand-rolling it with a raw `WaitGroup`.

## Channels vs. mutex: a decision, not a default

Go's concurrency proverb is **"Do not communicate by sharing memory;
instead, share memory by communicating."** In practice that cashes out to
two distinct tools solving different problems:

**Use a channel when you're transferring ownership** of a value or handing
off a result between goroutines — the sender stops touching the data once
it's sent, and only the receiver acts on it from that point on:

```go
results := make(chan Result, len(jobs))
for _, j := range jobs {
    go func(j Job) { results <- process(j) }(j)
}
for range jobs {
    handle(<-results)
}
```

**Use `sync.Mutex`/`sync.RWMutex` when multiple goroutines need to read or
write the same in-memory state** and there is no natural "ownership" to hand
off — a shared cache, a counter, a registry:

```go
var (
    mu      sync.Mutex
    service = map[string]net.Addr{}
)

func RegisterService(name string, addr net.Addr) {
    mu.Lock()
    defer mu.Unlock()
    service[name] = addr
}

func LookupService(name string) net.Addr {
    mu.Lock()
    defer mu.Unlock()
    return service[name]
}
```

Neither is universally "more idiomatic" than the other — reaching for
channels to guard a simple shared counter adds indirection with no benefit,
and reaching for a mutex to hand off a one-shot result between two
goroutines fights the language's grain. Pick based on whether the goroutines
involved are handing something off (channel) or all touching the same
long-lived state at once (mutex), and use `go test -race` to catch the cases
where the wrong tool — or no synchronization at all — let a race through.
