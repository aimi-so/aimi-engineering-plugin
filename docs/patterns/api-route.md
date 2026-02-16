---
name: api_route
keywords: [api, route, endpoint, rest, get, post, put, delete, patch, handler, request, response]
filePatterns: ["app/api/**/route.ts", "pages/api/*", "src/app/api/*"]
---

# API Route Implementation

Use this pattern when creating or modifying API endpoints, REST handlers, or backend routes.

## Steps Template

1. Read existing API routes in app/api/ or pages/api/ to understand patterns
2. Create the route file with proper HTTP method handlers (GET, POST, etc.)
3. Implement request validation and parsing
4. Add business logic with proper error handling
5. Return appropriate HTTP status codes and JSON responses
6. Verify typecheck passes with: npx tsc --noEmit

## Relevant Files

- app/api/ - App Router API routes
- pages/api/ - Pages Router API routes
- src/lib/db.ts - Database client
- src/lib/auth.ts - Authentication utilities
- src/types/ - Shared type definitions

## Gotchas

- **HTTP methods** are exported as named functions: `export async function GET()`
- **Request parsing** - use `request.json()` for body, `request.nextUrl.searchParams` for query
- **Response format** - always return `NextResponse.json()` with status
- **Error handling** - catch errors and return appropriate status codes (400, 401, 404, 500)
- **Authentication** - check session/token at start of protected routes
- **CORS** - may need headers for cross-origin requests
- **Rate limiting** - consider for public endpoints
- **Input validation** - validate all incoming data with Zod or similar
- **Status codes**:
  - 200: Success
  - 201: Created
  - 400: Bad Request
  - 401: Unauthorized
  - 404: Not Found
  - 500: Internal Server Error
