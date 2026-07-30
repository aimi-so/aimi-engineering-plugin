# App Router Structure — Deep Reference

Full-depth detail behind the "App Router Structure and Colocation" section of
`SKILL.md`. Paraphrased from the official Next.js documentation
(`vercel/next.js`, `docs/01-app/`), MIT licensed — see `../NOTICE.md`.

## Route Segments and the URL

Every folder nested inside `app/` is a route segment; the folder hierarchy
maps directly onto the URL path hierarchy. A small set of reserved file names
inside a segment folder give it behavior:

| File | Role |
|---|---|
| `page.tsx` | Makes the segment publicly reachable and defines its UI. |
| `layout.tsx` | Shared UI wrapping the segment and its children; preserves state across navigations within it. |
| `template.tsx` | Like `layout.tsx`, but re-mounts (no state preservation) on navigation. |
| `loading.tsx` | Wraps the segment in a `<Suspense>` boundary; Next.js renders it as the fallback while the segment's async work resolves. |
| `error.tsx` | Client Component error boundary for the segment; catches uncaught exceptions from its children. |
| `route.ts` | Route Handler — a server endpoint for this path instead of a page. |
| `default.tsx` | Fallback UI for a parallel route slot when no more-specific match exists. |

Only these (and a few more specialized ones — `not-found.tsx`,
`global-error.tsx`) are special. Any other file or folder inside a route
segment is invisible to the router.

## Colocation

Because only the reserved file names above are routable, project files —
components, hooks, styles, tests, utilities used by exactly one route — can
be placed directly inside that route's segment folder without accidentally
becoming a URL. This is what "colocation" means in the App Router: keep a
feature's implementation next to the route that owns it, rather than
scattering it into parallel top-level directories organized by file type
(`components/`, `hooks/`, `styles/`) that make a single feature's boundary
hard to see.

Colocation is a convention, not a requirement — files may still live outside
`app/` (e.g. a top-level `components/`, `lib/`) when multiple routes
genuinely share them. The rule of thumb from `SKILL.md` — colocate by
default, centralize only genuinely cross-route primitives — is what keeps a
shared directory from becoming a second, competing structure that duplicates
what the route tree already expresses.

## Private Folders

A folder prefixed with an underscore (`_folderName`) and everything inside it
is excluded from routing, even though it stays inside `app/`. It exists for:

- Separating UI/implementation-detail files from routing logic so a
  directory listing reads as "routes" at the top level and "internals" one
  level down.
- Consistent organization/sorting in editors and file trees.
- Avoiding accidental collisions with a future Next.js file-convention name
  (a plain folder named `styles` or `components` could someday become
  meaningful to the router; a private folder never will).

Private folders are opt-in, not required for colocation itself — colocation
works without them — but they're the mechanism when a route's internals need
to be visually and mechanically separated from its route-defining files.

## Route Groups

A folder wrapped in parentheses — `(marketing)`, `(shop)`, `(auth)` — is a
route group: it organizes routes by category/team/concern but is **excluded
from the URL path**. `app/(marketing)/about/page.tsx` still resolves to
`/about`, not `/marketing/about`.

Common uses:

- Splitting a large route tree into team- or domain-owned groups without
  changing any URL.
- Giving different sections of an app different root layouts (e.g. a
  logged-out marketing shell vs. a logged-in app shell) while keeping both
  under one `app/` tree.
- Opting a subset of routes into or out of a shared layout without
  restructuring URLs.

Caveats worth enforcing in review:

- **Conflicting paths**: two route groups must never resolve to the same URL
  path — the router does not disambiguate this for you.
- **Full page reload on cross-group navigation**: navigating between routes
  that use *different* root layouts (i.e., crossing a route-group boundary
  that changes the root layout) triggers a full page reload rather than a
  client-side transition. This is expected, not a bug to "fix" by merging
  groups that intentionally have different shells.
- **Home route ownership**: if multiple root layouts are used without a
  single top-level `layout.tsx`, the `/` route must be defined inside one of
  the groups — it needs an owner.

## Parallel Routes (`@slot`) — Awareness, Not a Default

A folder prefixed with `@` (e.g. `@analytics`, `@team`) declares a parallel
route slot — simultaneously rendered, independently navigable UI within the
same layout. This is a more advanced, less universally-needed pattern than
route groups or colocation; mention it here for recognition (so a slot folder
in a codebase isn't mistaken for a route group or a typo), not as a default
structural recommendation. Reach for it only when a layout genuinely needs
more than one independently-loading/erroring region rendered at once (e.g. a
dashboard with an always-present sidebar feed alongside route-driven main
content).

## Reserved File Conventions Replace Ad Hoc Conditionals

`loading.tsx` and `error.tsx` are read directly by the router at the segment
level — they are not just "a component you could also write inline." Once
present:

- `loading.tsx` causes Next.js to prerender a static shell for the segment
  and stream in the rest as data resolves, via an automatically-inserted
  `<Suspense>` boundary. Omitting it does not remove streaming ability
  entirely (inline `<Suspense>` can still be placed anywhere in the tree for
  finer-grained control) but does remove the automatic segment-level
  boundary.
- `error.tsx` must be a Client Component (`'use client'` at the top) even
  though the segment it guards may otherwise be entirely server-rendered —
  this is a framework requirement of error boundaries, not a style choice.

Prefer these conventions over a hand-rolled `if (loading) return <Spinner/>`
or a custom error-boundary component duplicated per page — they compose with
the router's own streaming and error-recovery machinery in ways an ad hoc
equivalent cannot.
