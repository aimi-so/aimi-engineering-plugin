# NOTICE

This skill incorporates material adapted from the **NestJS** project
(https://github.com/nestjs/nest and its documentation source
https://github.com/nestjs/docs.nestjs.com, published at
https://docs.nestjs.com), licensed under the MIT License (the "License").
The full License text is reproduced below.

---

## NestJS

Copyright (c) 2017-present, Kamil Mysliwiec <https://kamilmysliwiec.com>

The conventions in `SKILL.md`, and the deep-reference material in
`references/forbidden-patterns.md` and `references/testing-recipes.md`, are
rewritten and reorganized adaptations of guidance and code samples from the
following NestJS documentation pages (via `nestjs/docs.nestjs.com`):

- `content/modules.md` (module encapsulation, exports, feature-module
  organization)
- `content/controllers.md` and `content/providers.md` (Controller → Service
  layering)
- `content/fundamentals/dependency-injection.md` and
  `content/fundamentals/custom-providers.md` (constructor DI, interface/token
  injection, `useClass`/`useValue`/`useFactory`/`useExisting`)
- `content/fundamentals/circular-dependency.md` (`forwardRef()`)
- `content/fundamentals/injection-scopes.md` (provider scope defaults)
- `content/techniques/validation.md` and `content/pipes.md` (DTOs,
  `class-validator`, `ValidationPipe` whitelist/forbidNonWhitelisted)
- `content/techniques/configuration.md` (centralized `@nestjs/config`)
- `content/exception-filters.md`, `content/guards.md`,
  `content/interceptors.md` (cross-cutting extension points)
- `content/fundamentals/unit-testing.md` (unit, integration, and e2e testing
  patterns: `Test.createTestingModule`, `useMocker`, `supertest`)

None of these files are reproduced verbatim — the prose conventions in
`SKILL.md` are restated in original wording as agent-facing conventions for
this plugin's use; the short code samples in `references/testing-recipes.md`
and `SKILL.md`'s DI/validation examples are adapted illustrations of the
same patterns shown in the cited documentation pages, not copy-pasted
blocks. This NOTICE preserves the required copyright and permission notice
from the upstream MIT License, as that License requires for any
redistributed copy or substantial portion of the licensed material.

Every load-bearing convention in this skill was additionally cross-checked
against current NestJS documentation via the Context7 MCP
(`mcp__plugin_aimi-engineering_context7`, library `/nestjs/docs.nestjs.com`)
before finalizing — no drift was found between the frozen research-file
snapshot this skill was drafted from and current `docs.nestjs.com` content.

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
