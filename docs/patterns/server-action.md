---
name: server_action
keywords: [server, action, next, api, mutation, form, submit, create, update, delete, "use server"]
filePatterns: ["src/actions/*", "app/**/actions.ts", "src/lib/actions/*", "**/actions/*.ts"]
---

# Next.js Server Actions

Use this pattern when creating or modifying Next.js server actions for form handling, mutations, or server-side operations.

## Steps Template

1. Read existing server actions in src/actions/ or app/ to understand patterns
2. Create or update the action file with "use server" directive at top
3. Implement the action function with proper input validation
4. Add error handling with try/catch and meaningful error messages
5. Connect action to form or call site (if applicable)
6. Verify typecheck passes with: npx tsc --noEmit

## Relevant Files

- src/actions/ - Server actions directory
- app/**/actions.ts - Co-located actions
- src/lib/db.ts - Database client
- src/lib/auth.ts - Authentication utilities

## Gotchas

- **"use server" directive** must be at the top of file or function
- **Input validation** is critical - never trust client data
- **Revalidation** after mutations: use `revalidatePath()` or `revalidateTag()`
- **Error handling** should return user-friendly messages, not stack traces
- **Authentication** should be checked at the start of protected actions
- **FormData parsing** - use `.get()` with type assertions carefully
- **Redirect** after successful mutation often improves UX
- **Return types** should be consistent: `{ success: true, data }` or `{ success: false, error }`
