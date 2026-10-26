---
title: Per-Request Deduplication with React.cache()
impact: MEDIUM
impactDescription: deduplicates within request
---

## Per-Request Deduplication with React.cache()

**Impact: MEDIUM (deduplicates within request)**

Use `React.cache()` for server-side request deduplication. Authentication and database queries benefit most.

**Usage:**

```typescript
import { cache } from 'react'

export const getCurrentUser = cache(async () => {
  const session = await auth()
  if (!session?.user?.id) return null
  return await db.user.findUnique({
    where: { id: session.user.id }
  })
})
```

Within a single request, multiple calls to `getCurrentUser()` execute the query only once.

**Avoid inline objects as arguments:**

`React.cache()` uses shallow equality (`Object.is`) to determine cache hits. Inline objects create new references each call, preventing cache hits.

**Incorrect: always cache miss**

```typescript
const getUser = cache(async (params: { uid: number }) => {
  return await db.user.findUnique({ where: { id: params.uid } })
})

// Each call creates new object, never hits cache
getUser({ uid: 1 })
getUser({ uid: 1 })  // Cache miss, runs query again
```

**Correct: cache hit**

```typescript
const params = { uid: 1 }
getUser(params)  // Query runs
getUser(params)  // Cache hit (same reference)
```

If you must pass objects, pass the same reference:

**Next.js-Specific Note:**

In Next.js, the `fetch` API is automatically extended with request memoization. Requests with the same URL and options are automatically deduplicated within a single request, so you don't need `React.cache()` for `fetch` calls. However, `React.cache()` is still essential for other async tasks:

- Database queries (Prisma, Drizzle, etc.)

- Heavy computations

- Authentication checks

- File system operations

- Any non-fetch async work

Use `React.cache()` to deduplicate these operations across your component tree.

Reference: [https://react.dev/reference/react/cache](https://react.dev/reference/react/cache)
