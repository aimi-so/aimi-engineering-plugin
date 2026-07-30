# Server/Client Component Boundary — Deep Reference

Full-depth detail behind the "The Server/Client Component Boundary" section
of `SKILL.md`. Paraphrased from the official Next.js documentation
(`vercel/next.js`, `docs/01-app/01-getting-started/05-server-and-client-components.mdx`
and `docs/01-app/01-getting-started/06-fetching-data.mdx`), MIT licensed —
see `../NOTICE.md`. This reference covers structure and data-fetching
placement only; component-level performance tuning (memoization, re-render
cost, bundle splitting) is `react-best-practices` territory, not restated
here — see `SKILL.md`'s "Relationship to react-best-practices."

## Server Components Are the Default

In the App Router, every component is a Server Component unless its file (or
a file that imports it in the wrong direction) opts out with `'use client'`
at the top. Server Components:

- Render on the server and do not contribute to the client-side JavaScript
  bundle — their code never ships to the browser.
- Can be `async` functions and fetch data directly (via `fetch`, a database
  client, etc.) without any client-side data-fetching hook.
- Cannot use state (`useState`), effects (`useEffect`), or browser-only APIs
  — those require a Client Component.

```tsx
// Layout is a Server Component by default — no directive needed
export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <>
      <nav>
        <Logo />    {/* Server Component */}
        <Search />  {/* Client Component — see below */}
      </nav>
      <main>{children}</main>
    </>
  )
}
```

## `'use client'` Marks a Boundary, Not a Whole Subtree

The directive is placed at the top of a file:

```tsx
'use client'

import { useState } from 'react'

export default function LikeButton({ likes }: { likes: number }) {
  const [count, setCount] = useState(likes)
  // ...
}
```

Two properties of the boundary matter more than the directive itself:

1. **It extends downward through that file's module graph, not upward to its
   importers.** A Server Component `Layout` can import and render the
   `LikeButton` Client Component above without `Layout` itself becoming
   client code. The boundary is per-file, not per-subtree-from-the-top.
2. **Everything the marked file imports (that isn't already marked
   otherwise) is pulled into the client bundle with it.** This is why the
   convention is to push `'use client'` to the smallest leaf that actually
   needs interactivity/state/browser APIs — marking a whole page or a large
   layout "to be safe" drags everything that page imports into client-side
   JS and forfeits server-rendering for all of it, not just the one
   interactive piece.

## Composition Direction: Server-into-Client, Never Client-Importing-Server

The one direction that silently breaks the boundary: importing a Server
Component from inside a Client Component's module forces that Server
Component (and its own imports) to become part of the client bundle too — the
boundary doesn't stop that import, it just quietly loses you the server-only
benefit.

The correct shape passes Server Components in as `children` or other props,
composed from a parent that is itself allowed to know about both sides:

```tsx
// app/page.tsx — Server Component
import Modal from './ui/modal'   // Client Component
import Cart from './ui/cart'     // Server Component

export default function Page() {
  return (
    <Modal>
      <Cart />
    </Modal>
  )
}
```

`Modal` never imports `Cart`; it only declares a `children` slot. `Page`
(itself a Server Component) is what wires them together. `Cart` still
renders on the server — the React Server Component payload contains its
already-rendered output plus a placeholder for where `Modal`'s client-side
output will hydrate around it. This pattern generalizes: any Client Component
that needs to "wrap" server-rendered content (modals, providers, tab shells)
should accept that content via `children`/props rather than importing it.

A more advanced variant: a Server Component can pass non-serializable
children (including other Server Components) through a cached wrapper
component without the wrapper needing to read or modify them — the wrapper
just forwards `children`, keeping the cached shell and the dynamic content
independently composable.

## Where Initial Data Fetching Belongs

Fetch page-level/initial data in a Server Component or a Route Handler:

```tsx
// Server Component — fetches during the server render itself
export default async function Page() {
  const data = await fetch('https://api.vercel.app/blog')
  const posts = await data.json()
  return (
    <ul>
      {posts.map((post) => (
        <li key={post.id}>{post.title}</li>
      ))}
    </ul>
  )
}
```

The alternative — fetching in a `useEffect` after the component mounts —
produces a strictly worse sequence: blank UI ships → client JS downloads and
hydrates → the effect fires → the fetch resolves → the real content finally
renders. Server-side fetching collapses that into one server-rendered
response. Reserve `useEffect`/client-side fetching (including TanStack
Query's default client fetch) for data that legitimately changes *after*
mount: polling, a user-triggered refetch, or state that has no meaningful
value until user interaction occurs.

## Parallel vs. Sequential Fetching

Independent data requests should start together, not one after another:

```tsx
// Sequential — the second request cannot start until the first resolves
const artist = await getArtist(username)
const albums = await getAlbums(username)
```

```tsx
// Parallel — both requests start immediately; only the awaiting is deferred
const artistData = getArtist(username)   // not awaited yet — starts the request
const albumsData = getAlbums(username)   // starts immediately too
const [artist, albums] = await Promise.all([artistData, albumsData])
```

The difference is exactly when `await` is applied: calling the async
functions without immediately awaiting them starts both requests at the call
site; the `Promise.all` only blocks rendering until both have resolved. This
is one of the most-cited avoidable App Router performance mistakes — a
sequential chain across genuinely independent data sources adds up their
latencies instead of taking the slower of the two.

## Error and Loading Boundaries

- `loading.tsx` in a segment folder wraps that segment in a `<Suspense>`
  boundary automatically; Next.js can then serve a static shell for the
  surrounding layout while the segment's async work streams in.
- `error.tsx` catches uncaught exceptions thrown by its segment's children
  and must itself be a Client Component:

```tsx
'use client' // Error boundaries must be Client Components

import { useEffect } from 'react'

export default function ErrorPage({
  error,
  retry,
}: {
  error: Error & { digest?: string }
  retry: () => void
}) {
  useEffect(() => {
    console.error(error)
  }, [error])

  return (
    <div>
      <h2>Something went wrong!</h2>
      <button onClick={() => retry()}>Try again</button>
    </div>
  )
}
```

Prefer these two conventions over hand-rolled conditional loading/error
rendering duplicated in every `page.tsx` — they integrate with the router's
own streaming and recovery machinery (including nested-segment isolation: an
error in one segment does not need to take down its siblings) in a way an ad
hoc equivalent does not.
