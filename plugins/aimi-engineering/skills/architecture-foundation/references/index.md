# References Index

`SKILL.md` is self-sufficient for making a foundation decision — it is the
only file hydrated automatically into a story-executor's context (see
`get-story-context` in `scripts/aimi-cli.sh`). The files below are **not**
auto-loaded; read one on demand via the Read tool when a foundation story
needs the full reasoning behind a condensed rule.

## File Map

| File | Read when... |
|---|---|
| `clean-architecture.md` | Justifying a layering choice, dependency-direction violation, boundary cost tradeoff, naming convention, or refactoring order — full Robert C. Martin detail. |
| `domain-driven-design.md` | Justifying a Bounded Context split, Aggregate design, Repository/Factory shape, context-mapping relationship, or strategic Core/Supporting/Generic classification — full Eric Evans detail. |
| `domain-driven-design-distilled.md` | The repository or feature is small/early-stage and full tactical DDD would be over-engineering — Vaughn Vernon's pragmatic "smallest effective DDD" subset. |
| `patterns-of-enterprise-application-architecture.md` | Choosing between Transaction Script / Table Module / Domain Model, picking a persistence pattern (Repository vs. Data Mapper vs. Active Record), or deciding transaction/session-state ownership — Martin Fowler's enterprise-pattern detail. |

## Attribution

All four files adapt material from the `agent-rules-books` project
(https://github.com/ciembor/agent-rules-books), Copyright (c) 2026 Maciej
Ciemborowicz, MIT License. Content is rewritten/reorganized for this skill's
foundation-proposal purpose, not reproduced verbatim. See `../NOTICE.md` for
the full MIT license text and source-file mapping.
