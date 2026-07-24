# TanStack Query Conventions — Deep Reference

Full-depth detail behind the "TanStack Query Conventions" and "Bridging the
Two" sections of `SKILL.md`. Paraphrased from the official TanStack Query
documentation (`TanStack/query`), MIT licensed — see `../NOTICE.md`. This
reference covers query keys, invalidation, mutations, cache lifetime, and the
App Router prefetch/hydrate integration; it does not restate general React
re-render or effect-dependency guidance owned by `react-best-practices`.

## Query Keys Are Cache Identity

TanStack Query keys are hashed (a stable, deterministic serialization) to
produce the cache's identity for a query. Two consequences that matter for
review:

- **Arrays, always.** A query key is an array at the top level, and should
  uniquely describe the data the query function returns.
- **Object entries inside a key are order-independent.** `['todos', {status,
  page}]` and `['todos', {page, status}]` hash to the exact same cache entry
  — the library sorts object keys before hashing. Reviewers should not treat
  differing property order across call sites as a bug; it isn't one.
- **Every value the query function's behavior depends on belongs in the key**
  — filters, ids, pagination cursors, sort order. Treat the key like a
  `useEffect` dependency array: omitting a dependency means two logically
  different queries collide into one cache entry (stale-looking data that
  "doesn't update" is often a key that's missing a variable, not an
  invalidation bug).

## Hierarchical Keys and Query Key Factories

Structure keys as a prefix hierarchy so invalidation can target a whole
family or a single entry:

```ts
// query-keys.ts — one colocated factory per resource
export const todoKeys = {
  all: ['todos'] as const,
  lists: () => [...todoKeys.all, 'list'] as const,
  list: (filters: TodoFilters) => [...todoKeys.lists(), filters] as const,
  details: () => [...todoKeys.all, 'detail'] as const,
  detail: (id: string) => [...todoKeys.details(), id] as const,
}
```

```ts
useQuery({ queryKey: todoKeys.list(filters), queryFn: () => fetchTodos(filters) })
useQuery({ queryKey: todoKeys.detail(id), queryFn: () => fetchTodo(id) })

// Invalidate every todo query — lists and details
queryClient.invalidateQueries({ queryKey: todoKeys.all })
// Invalidate only list queries, leaving cached detail entries alone
queryClient.invalidateQueries({ queryKey: todoKeys.lists() })
```

Centralizing construction in a factory (rather than hand-typing
`['todos', 'list', filters]` at every call site) is what prevents silent
cache-key drift: if one call site types `['todo', id]` (singular, no
`'detail'` segment) while the factory everywhere else emits
`['todos', 'detail', id]`, that one query gets its own isolated cache entry
that a broad `invalidateQueries({ queryKey: todoKeys.all })` will never touch
— a bug that looks like "this one screen doesn't refresh" and is easy to miss
in review without a factory to diff against.

## Invalidating from Mutations

The default mechanism for "make the UI reflect a mutation" is invalidating
the affected query family from the mutation's `onSuccess`:

```tsx
const queryClient = useQueryClient()

const mutation = useMutation({
  mutationFn: addTodo,
  onSuccess: async () => {
    // Single family
    await queryClient.invalidateQueries({ queryKey: todoKeys.all })

    // Multiple independent families affected by one mutation
    await Promise.all([
      queryClient.invalidateQueries({ queryKey: todoKeys.all }),
      queryClient.invalidateQueries({ queryKey: reminderKeys.all }),
    ])
  },
})
```

Returning (or awaiting) the invalidation promise from `onSuccess` ensures the
refetch is in flight — and, if awaited by the caller — resolved before the
mutation itself is considered fully settled. This is the default; reach for
direct cache writes (`queryClient.setQueryData`) only when an optimistic or
immediate-update UX genuinely requires bypassing a refetch round-trip, not as
a routine substitute for invalidation.

## `staleTime` and `gcTime`

Two independent settings govern a query's lifecycle, and defaults are not
"correct for everything":

| Setting | Default | Governs |
|---|---|---|
| `staleTime` | `0` ms | How long fetched data is considered fresh. At `0`, data is marked stale immediately, so the next mount/access triggers a background refetch even though cached data is shown instantly. |
| `gcTime` | 5 minutes on the client, `Infinity` during server rendering | How long an *unused* (no active observers) cache entry is retained before garbage collection. Not how long data stays "fresh" — that's `staleTime`'s job. |

```ts
useQuery({
  queryKey: todoKeys.detail(id),
  queryFn: () => fetchTodo(id),
  staleTime: 5 * 60 * 1000, // reference-ish data: refetch at most every 5 min
})
```

Choose both deliberately per query based on how the data actually behaves:
rarely-changing reference data (a list of countries, a user's own profile)
warrants a longer `staleTime`; a live dashboard or a value another user can
change warrants the default or shorter. Setting `staleTime: Infinity`
everywhere defeats the point of a data-synchronization library; leaving
every query at the library default without considering the data's actual
volatility is the more common review finding.

## Server State vs. Client State

TanStack Query is a **server-state** library — it's designed to manage
asynchronous data that is owned by, and can change independently of, the
client. That is a different job from a client-state library (`useState`,
Redux, Zustand, etc.), which manages state whose source of truth is the
client itself (a form draft, a theme toggle, whether a sidebar is open).

The failure mode this section exists to prevent: copying TanStack Query's
`data` into local `useState` "so I can tweak it locally." The moment that
happens, the component has two sources of truth — the query cache and the
local copy — and they desync the instant an invalidation, background
refetch, or another component's mutation updates the cache without the local
copy knowing. Prefer deriving what you need from the query result directly
(a `select` transform, a computed value in render) over storing a mutable
copy.

After migrating server-state slices to TanStack Query, most applications are
left with only a small amount of genuinely client-only global state (e.g.
`{ themeMode, sidebarStatus }`) — TanStack Query is not a wholesale
replacement for a client-state manager in an app with substantial
synchronous, client-only state (e.g. a visual editor's in-progress
selection), but it does absorb essentially all of the server-derived
portion, including the loading/error/success bookkeeping that used to be
hand-rolled around it.

## App Router Integration: Server Prefetch + Client Hydration

The standard pattern for combining a Server Component's data-fetching with
TanStack Query's client-side cache: prefetch on the server, dehydrate the
cache into serializable state, hand it to the client via
`HydrationBoundary`, and let the ordinary client hook pick it up under the
same key.

```tsx
// app/posts/page.tsx — Server Component
import { dehydrate, HydrationBoundary } from '@tanstack/react-query'
import { getQueryClient } from './get-query-client'
import Posts from './posts'

export default function PostsPage() {
  const queryClient = getQueryClient()

  // Not awaited — lets the response start streaming while this resolves
  queryClient.prefetchQuery({ queryKey: ['posts'], queryFn: getPosts })

  return (
    <HydrationBoundary state={dehydrate(queryClient)}>
      <Posts />
    </HydrationBoundary>
  )
}
```

```tsx
// app/posts/posts.tsx — Client Component
'use client'

export default function Posts() {
  // Same query key as the prefetch — finds hydrated data immediately,
  // no loading flash, then behaves like any other useQuery from here on.
  const { data } = useQuery({ queryKey: ['posts'], queryFn: getPosts })
  // ...
}
```

Two details worth enforcing in review:

- **`HydrationBoundary` is itself a Client Component** — the Server
  Component wrapping it (`PostsPage` above) does not need `'use client'`
  itself; only the boundary component does, and that's already handled by
  the library.
- **Construct a fresh `QueryClient` per server request, and only one shared
  instance in the browser.** A shared module-level `QueryClient` on the
  server would leak one request's cached data into another's response — the
  standard `getQueryClient()` helper checks whether it's running on the
  server (always create new) or in the browser (create once, reuse) for
  exactly this reason. Do not hoist a single `QueryClient` to true module
  scope and share it across server requests.
- **The query key used in `prefetchQuery` and the key used in the
  consuming `useQuery` must match exactly** (same factory call, same
  arguments) — a mismatch means the hydration boundary contains data the
  client component never looks up, silently falling back to a fresh client
  fetch and losing the whole benefit of prefetching.
