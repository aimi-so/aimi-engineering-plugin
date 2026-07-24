---
name: nextjs-tanstack-conventions
version: "1.0.0"
description: >
  Use when writing, reviewing, or structuring Next.js App Router code or
  TanStack Query data-fetching logic — route segment layout, colocation and
  route groups, the Server/Client Component boundary, where 'use client'
  belongs, or TanStack Query query keys, cache invalidation, mutations, and
  server-state vs. client-state separation. Trigger phrases: App Router,
  Server Components, Client Components, 'use client', route groups,
  colocation, TanStack Query, React Query, query keys, invalidateQueries,
  staleTime, gcTime, HydrationBoundary, prefetchQuery, server state.
license: MIT (NOTICE.md)
---

# Next.js App Router + TanStack Query Conventions

Evergreen, version-independent structural and state-management conventions
for the Next.js App Router and TanStack Query — where files live, where the
server/client boundary falls, and how server state is keyed, cached, and
invalidated. Full-depth material lives under `references/`; this file carries
everything needed to make a structural or data-layer decision without reading
further.

> **Attribution**: The conventions below are paraphrased and reorganized from
> the official Next.js documentation (`vercel/next.js`, `docs/` folder) and
> the official TanStack Query documentation (`TanStack/query`), both MIT
> licensed, then cross-checked against current docs via the Context7 MCP.
> No large verbatim blocks are reproduced. See `NOTICE.md`.

## Relationship to react-best-practices

This skill and `react-best-practices` (Vercel Engineering's 58-rule
performance guide) are complementary, not overlapping. `react-best-practices`
answers "is this render/fetch/bundle fast?" — waterfalls, memoization,
bundle-splitting, re-render cost. This skill answers "is this file in the
right place, on the right side of the server/client boundary, keyed and
invalidated correctly?" — App Router structure and TanStack Query state
ownership. Apply both together on Next.js work; neither substitutes for the
other, and this file does not restate performance-rule content already owned
by `react-best-practices`.

## When to Use

- Laying out or reviewing an `app/` route tree: where a page's components,
  data-fetching, and route-specific UI should live.
- Deciding whether a component needs `'use client'` or should stay a Server
  Component.
- Introducing or reviewing TanStack Query usage: key structure, invalidation,
  mutations, or the split between server state and local UI state.
- Combining Server Component data-fetching with TanStack Query (prefetch +
  hydrate) in the same route.

## App Router Structure and Colocation

- **Nested folders under `app/` define routing**; each folder is a route
  segment mapped to a URL segment. Project files (components, hooks, utils
  used only by that route) can be safely colocated inside a route segment
  folder without becoming routable themselves — only `page`, `route`,
  `layout`, `template`, `default`, `loading`, `error`, and a few other
  reserved file names are special.
- **Colocate by default; centralize only genuinely cross-route primitives.**
  A route's page, layout, loading/error boundaries, and route-specific
  components live together under its segment folder. A top-level shared
  directory (e.g. `components/`, `lib/`) is for code multiple routes
  genuinely need, not a default dumping ground.
- **Private folders** (`_folderName`, leading underscore) opt a folder and
  its children out of routing — useful for separating UI/implementation
  detail from route structure, or avoiding collisions with future Next.js
  file-convention names, without leaving the `app/` tree.
- **Route groups** (`(folderName)`, parentheses) organize routes by team or
  concern — e.g. multiple root layouts, or grouping `(marketing)` vs.
  `(shop)` — without adding a segment to the URL path. Routes in different
  groups must not resolve to the same URL; navigating across route groups
  with different root layouts triggers a full page reload, not a soft
  transition.
- **Route-level UI conventions replace ad hoc conditional rendering**:
  `loading.tsx` wraps a segment in a `<Suspense>` boundary so Next.js can
  serve a static shell while content streams; `error.tsx` is a per-segment
  error boundary. Both are reserved file names read directly by the router —
  don't hand-roll an equivalent inside `page.tsx`.

## The Server/Client Component Boundary

- **Server Components are the default in the App Router; `'use client'` is an
  opt-in escape hatch**, not a habit applied "to be safe." A component needs
  it only for interactivity (event handlers), React state/effects, or
  browser-only APIs.
- **`'use client'` marks a boundary that extends downward through that file's
  import graph, not upward to its importers.** A Server Component layout can
  import and render a Client Component child without itself becoming client
  code — push the boundary as far down the tree as possible: isolate the one
  interactive leaf, keep the shell (layout, data-fetching, page composition)
  on the server.
- **Compose across the boundary by passing Server Components as children or
  props into Client Components — never import a Server Component from inside
  a Client Component's module.** A common shape: a Client Component (e.g. a
  modal) accepts `children`, and the page composes it with a Server Component
  passed in as that `children` slot; the Server Component still renders on
  the server even though it's visually nested inside client-rendered chrome.
  Importing the wrong direction silently forces everything downstream client-
  side.
- **Fetch page-level/initial data in a Server Component (or a Route Handler),
  not in a `useEffect` after mount.** `useEffect`-based initial fetching
  produces the blank-shell → JS loads → fetch fires → render waterfall that
  server-side fetching eliminates by resolving data during the server render
  itself. Reserve client-side fetching (via `useEffect` or TanStack Query)
  for data that changes *after* mount: polling, user-triggered refetch,
  client-only interactions.
- **Fetch independent data in parallel, never as a sequential `await` chain.**
  Start every independent request before awaiting any of them (call the
  fetching functions first, then `Promise.all` the results) so requests fire
  concurrently; awaiting each call in turn before starting the next is one of
  the most common avoidable App Router performance mistakes.
- **Error boundaries must be Client Components.** `error.tsx` requires
  `'use client'` even though it lives in what is otherwise server-rendered
  territory — this is a framework requirement, not a stylistic choice.

## TanStack Query Conventions

- **Query keys are arrays and are the mechanism for cache identity and
  invalidation** — treat a key like a dependency array: include every value
  the query depends on (filters, ids, pagination). Two calls with the same
  key resolve to the same cache entry regardless of object-key order inside
  the key (`['todos', {status, page}]` hashes identically to
  `['todos', {page, status}]`); two calls with different key values are
  independently cached.
- **Use a hierarchical prefix structure** — `['todos']`, then
  `['todos', 'list', filters]`, then `['todos', 'detail', id]` — so a broad
  `invalidateQueries({ queryKey: ['todos'] })` invalidates the whole family,
  and a narrow key invalidates just one entry.
- **Centralize key construction in one colocated factory function per
  resource** rather than hand-typing arrays at each call site. A call site
  that types `['todo', id]` where the factory emits `['todos', 'detail', id]`
  creates a silent cache-key drift bug: the entry exists, but the broad
  invalidation you expect never reaches it.
- **Invalidate from the mutation's `onSuccess`, as the default "make the UI
  reflect the mutation" mechanism.** `queryClient.invalidateQueries({
  queryKey: [...] })`, awaited or returned from `onSuccess`, marks matching
  queries stale and triggers a refetch — this is the standard shape, not
  manual local-state patching after a write.
- **Configure `staleTime` and `gcTime` deliberately per query; don't leave
  every query at the library default or set both to `Infinity` reflexively.**
  `staleTime` (default `0`) controls how long fetched data is considered
  fresh before a refetch is triggered on next access; `gcTime` (default 5
  minutes on the client, `Infinity` during server rendering) controls how
  long an unused cache entry is retained in memory before eviction. A query
  backing rarely-changing reference data warrants a longer `staleTime`; one
  backing a live dashboard often warrants the default or shorter.
- **TanStack Query owns server state; `useState`/component state owns
  UI-only state.** Don't copy fetched data into local state "to tweak it" —
  that duplication desyncs from the cache the moment an invalidation or
  background refetch updates the original. TanStack Query is not a
  replacement for genuinely client-only state (a theme toggle, a sidebar's
  open/closed flag) — keep that in ordinary component/client state; it
  replaces the server-state slice that global client-state libraries are
  often misused to hold.

## Bridging the Two: Server Prefetch + Client Hydration

Fetching in a Server Component and using TanStack Query in a Client Component
are not competing choices for the same route — the standard integration
prefetches on the server and hands the cache to the client:

1. In a Server Component (typically `page.tsx`), construct a `QueryClient`,
   `await queryClient.prefetchQuery({ queryKey, queryFn })` for data the page
   needs, then render `<HydrationBoundary state={dehydrate(queryClient)}>`
   around the Client Component that will read it.
2. The wrapped Client Component calls the ordinary `useQuery({ queryKey,
   queryFn })` with the **same query key** used in the prefetch — it finds
   the hydrated data immediately instead of suspending, and TanStack Query's
   normal cache/invalidation/refetch behavior takes over from there.
3. `HydrationBoundary` is itself a Client Component; the Server Component
   wrapping it does not itself need `'use client'`.

See `references/tanstack-query-conventions.md` for the full pattern,
including per-request `QueryClient` construction to avoid leaking state
across users.

## Forbidden Patterns

- Marking a page or large subtree `'use client'` by default instead of
  isolating the interactive leaf.
- Fetching initial page data with `useEffect` + `useState` instead of a
  Server Component, Route Handler, or server-prefetched TanStack Query.
- Sequential `await`s on independent data sources instead of starting all
  requests before awaiting any of them.
- Importing a Server Component from inside a Client Component's module
  (rather than passing it in as a child/prop).
- Hand-writing ad hoc query key arrays at call sites instead of a shared key
  factory.
- Duplicating TanStack Query data into local `useState` instead of reading
  it, deriving from it, or updating the cache directly.

## Final Checklist

Before accepting an App Router structure or a TanStack Query data-layer
change, confirm:

- Route-specific files are colocated under their segment; only genuinely
  shared code lives in a top-level directory.
- `'use client'` appears only where interactivity/state/browser APIs are
  actually needed, as far down the tree as possible.
- Composition passes Server Components into Client Components as
  children/props — never the reverse import direction.
- Initial data is fetched server-side (or server-prefetched into TanStack
  Query); independent fetches run in parallel.
- Query keys follow a hierarchical, factory-built structure; mutations
  invalidate the right key family from `onSuccess`.
- `staleTime`/`gcTime` were chosen for the data's actual freshness needs, not
  left at an unconsidered default or `Infinity`.
- Server state lives in TanStack Query's cache; client-only state lives in
  component state — no copy of one inside the other.

## Deep Reference

For the full-depth source material behind these condensed rules — additional
examples, the complete prefetch/hydration pattern, and route-group edge
cases — read on demand (not auto-loaded):

- `references/app-router-structure.md` — route segments, colocation, private
  folders, route groups, parallel routes, and reserved file conventions in
  full.
- `references/server-client-boundary.md` — the Server/Client Component
  boundary, composition patterns, data-fetching placement, and waterfall
  avoidance in full.
- `references/tanstack-query-conventions.md` — query keys and factories,
  invalidation, mutations, `staleTime`/`gcTime`, server-vs-client state
  separation, and the App Router prefetch/hydrate integration in full.
