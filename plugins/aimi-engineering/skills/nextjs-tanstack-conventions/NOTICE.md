# NOTICE

This skill incorporates material adapted from two upstream documentation
sources, both under the **MIT License** (the "License"). Neither source is
reproduced verbatim — see the per-source notes below for how each was
adapted. The full License text is reproduced once at the end of this file
since both grants are textually identical.

---

## Next.js official documentation

Source: https://nextjs.org/docs/app (repository `vercel/next.js`, `docs/`
folder), copyright Vercel, Inc.

The conventions in `SKILL.md`'s "App Router Structure and Colocation" and
"The Server/Client Component Boundary" sections, and the deep-reference
material in `references/app-router-structure.md` and
`references/server-client-boundary.md`, are paraphrased and reorganized from
the following upstream pages (not reproduced verbatim, cross-checked against
current docs via the Context7 MCP before finalizing):

- `docs/01-app/01-getting-started/02-project-structure.mdx` (colocation,
  private folders, project structure)
- `docs/01-app/01-getting-started/05-server-and-client-components.mdx`
  (Server/Client Component composition)
- `docs/01-app/01-getting-started/06-fetching-data.mdx` (server-side and
  parallel data fetching)
- `docs/01-app/01-getting-started/10-error-handling.mdx` (`error.tsx`
  boundaries)
- `docs/01-app/02-guides/building.mdx` (`loading.tsx` / Suspense streaming)
- `docs/01-app/03-api-reference/01-directives/use-client.mdx`
- `docs/01-app/03-api-reference/03-file-conventions/route-groups.mdx`

**License note**: the `vercel/next.js` repository is MIT licensed as a
whole. The MIT grant's text refers to "the Software," and whether that
phrase is read to cover the prose `docs/` markdown as cleanly as it covers
the framework's code is a common ambiguity in MIT-licensed monorepos that
was not separately resolved with a docs-specific license file. This NOTICE
takes the conservative reading — attributing the source and paraphrasing
rather than reproducing large verbatim blocks — regardless of how that
ambiguity would ultimately resolve.

## TanStack Query official documentation

Source: https://tanstack.com/query/latest/docs (repository `TanStack/query`),
copyright Tanner Linsley, 2021–present. Confirmed MIT via the repository's
`LICENSE` file.

The conventions in `SKILL.md`'s "TanStack Query Conventions" and "Bridging
the Two: Server Prefetch + Client Hydration" sections, and the deep-reference
material in `references/tanstack-query-conventions.md`, are paraphrased and
reorganized from the following upstream pages (not reproduced verbatim,
cross-checked against current docs via the Context7 MCP before finalizing):

- `docs/framework/react/guides/query-keys.md` (query key structure and
  hashing)
- `docs/framework/react/guides/invalidations-from-mutations.md`
  (`onSuccess` invalidation pattern)
- `docs/framework/react/reference/useQuery.md` (`staleTime` / `gcTime`
  defaults)
- `docs/framework/react/guides/does-this-replace-client-state.md`
  (server-state vs. client-state separation)
- `docs/framework/react/guides/advanced-ssr.md` (App Router
  prefetch/`HydrationBoundary` integration)

---

## MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
