---
title: Hoist Static I/O to Module Level
impact: HIGH
impactDescription: avoids repeated file/network I/O per request
---

## Hoist Static I/O to Module Level

**Impact: HIGH (avoids repeated file/network I/O per request)**

When loading static assets (fonts, logos, images, config files) in route handlers or server functions, hoist the I/O operation to module level. Module-level code runs once when the module is first imported, not on every request. This eliminates redundant file system reads or network fetches that would otherwise run on every invocation.

**Incorrect: reads font file on every request**

**Correct: loads once at module initialization**

**Alternative: synchronous file reads with Node.js fs**

**General Node.js example: loading config or templates**

**When to use this pattern:**

- Loading fonts for OG image generation

- Loading static logos, icons, or watermarks

- Reading configuration files that don't change at runtime

- Loading email templates or other static templates

- Any static asset that's the same across all requests

**When NOT to use this pattern:**

- Assets that vary per request or user

- Files that may change during runtime (use caching with TTL instead)

- Large files that would consume too much memory if kept loaded

- Sensitive data that shouldn't persist in memory

**With Vercel's [Fluid Compute](https://vercel.com/docs/fluid-compute):** Module-level caching is especially effective because multiple concurrent requests share the same function instance. The static assets stay loaded in memory across requests without cold start penalties.

**In traditional serverless:** Each cold start re-executes module-level code, but subsequent warm invocations reuse the loaded assets until the instance is recycled.
