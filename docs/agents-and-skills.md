# Agents and Skills

Two different things, easy to confuse.

A **skill** is packaged knowledge — conventions, a checklist, a workflow. It shapes how work gets done but does not run on its own.

An **agent** is a worker with its own fresh context. Commands spawn agents to research, review, or expand a piece of work in isolation.

---

## Skills (19)

### Core — used internally

These are invoked by commands, not by you.

| Skill | What it carries |
|-------|-----------------|
| `brainstorm` | The brainstorming process — batched questions, adaptive exit, design capture |
| `task-planner` | The pipeline that produces a tasks file: research, spec analysis, story decomposition |
| `story-executor` | The canonical prompt every story-executing agent receives |
| `aimi-design-handoff` | Interviews the operator and authors a BusinessSpec and DesignSpec bundle when no design handoff exists |

### Development and code style

| Skill | What it carries |
|-------|-----------------|
| `frontend-design` | Distinctive, production-grade frontend interfaces |
| `agent-native-architecture` | Apps where agents are first-class users, not an afterthought |
| `architecture-foundation` | Clean Architecture and DDD foundations, for both new and existing repositories |
| `react-best-practices` | React and Next.js performance, from Vercel Engineering |
| `react-native-skills` | React Native and Expo practices for performant mobile apps |
| `typescript-node-conventions` | Strict TypeScript for Node and Bun — typing discipline, ESM/CJS interop, error handling, async hygiene |
| `nestjs-conventions` | NestJS module boundaries, dependency injection, controller/service/repository layering, DTO validation |
| `nextjs-tanstack-conventions` | Next.js App Router structure and TanStack Query data fetching |
| `go-conventions` | Package layout, error wrapping, interfaces, context propagation, concurrency, table-driven tests |
| `rust-conventions` | Ownership and borrowing, Result and Option, thiserror versus anyhow, clippy and rustfmt gates |

### Tooling and automation

| Skill | What it carries |
|-------|-----------------|
| `agent-browser` | Browser automation through Vercel's agent-browser CLI |
| `create-agent-skills` | How to author Claude Code skills and slash commands |
| `git-worktree` | Managing git worktrees for isolated parallel work |
| `forge` | Every GitHub or GitLab action through the CLI's forge verbs, confirmed with you before each write |

### Disabled — kept for reference

| Skill | What it carries |
|-------|-----------------|
| `resolve-pr-parallel` | Resolving PR comments in parallel |

---

## Agents (27)

### Research (8)

| Agent | What it does |
|-------|--------------|
| `aimi-codebase-researcher` | Repository structure, patterns, conventions |
| `aimi-learnings-researcher` | Searches `.aimi/solutions/` for past solutions to similar problems |
| `aimi-best-practices-researcher` | External best practices and community conventions |
| `aimi-framework-docs-researcher` | Framework documentation and version-specific guidance |
| `aimi-bundle-prototype-author` | Builds a self-contained prototype HTML from a design bundle |
| `aimi-design-bundle-researcher` | Reads BusinessSpec and DesignSpec bundles into structured findings |
| `aimi-foundation-architect` | Proposes a stack-adaptive Clean Architecture foundation for new repositories |
| `aimi-spec-deriver` | Extracts entities and HTTP endpoints from a repository as evidence-backed records |

### Review (10)

| Agent | What it does |
|-------|--------------|
| `aimi-correctness-reviewer` | Bugs in a change: logic, boundaries, null and error propagation, races, state transitions |
| `aimi-security-reviewer` | Injection, broken access control, secrets, SSRF, cryptographic failures |
| `aimi-performance-reviewer` | N+1 queries, unbounded memory, missing pagination, blocking calls |
| `aimi-maintainability-reviewer` | Structure and simplicity: duplicated logic, speculative abstraction, dead code, coupling, type holes |
| `aimi-project-standards-reviewer` | Checks a change against the rules in the target project's own CLAUDE.md or AGENTS.md |
| `aimi-frontend-races-reviewer` | Timing and lifecycle bugs in browser UI code, in any framework |
| `aimi-agent-native-reviewer` | Whether an agent can still do and know what a change lets a person do and know |
| `aimi-data-migration-reviewer` | Migrations, backfills, schema drift and deploy-window breaks, in any migration tool |
| `aimi-deployment-verification-agent` | Whether a risky data change has the checks, queries and rollback it needs |
| `aimi-cross-story-auditor` | Audits staged stories for drift between them; writes its patches to the result file it is given |

Every review agent but the auditor ends with the same two sections, how it works and what it returns, so `/aimi:review` can merge and check their findings. See `plugins/aimi-engineering/docs/dev/review.md`.

### Design (2)

| Agent | What it does |
|-------|--------------|
| `aimi-design-implementation-reviewer` | Compares the live UI against Figma or a prototype |
| `aimi-design-iterator` | Refines a UI through screenshot, analyze, improve cycles |

### Workflow (6)

| Agent | What it does |
|-------|--------------|
| `aimi-bug-reproduction-validator` | Reproduces and validates bug reports, any language or framework |
| `aimi-scope-negative-verifier` | Re-checks a claim that something is absent, using data-flow analysis rather than a name search |
| `aimi-scope-positive-verifier` | Re-checks a claim that something already exists, the same way |
| `aimi-spec-flow-analyzer` | Analyzes a spec for flow gaps and missing cases |
| `aimi-spec-flow-symbol-extractor` | Pulls grep-safe code symbols out of spec questions for cross-checking |
| `aimi-story-expander` | Expands one outline entry into a complete user story |

---

## Choosing models per category

Each of the four agent categories can run on a different Claude model. Configure it with `/aimi:setup-models`, or by hand in `~/.config/aimi/models.json`.

Each category also carries an effort: delivered per spawn on Claude Code, as the model variant through `aimi-task` on OpenCode, and readable with `aimi-cli resolve-efforts`. See [commands.md](commands.md#aimisetup-models) for what it means per host and what overrides it.

See [architecture.md](architecture.md#per-category-model-configuration) for how the resolution works.
