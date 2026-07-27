# Agents and Skills

Two different things, easy to confuse.

A **skill** is packaged knowledge — conventions, a checklist, a workflow. It shapes how work gets done but does not run on its own.

An **agent** is a worker with its own fresh context. Commands spawn agents to research, review, or expand a piece of work in isolation.

---

## Skills (24)

### Core — used internally

These are invoked by commands, not by you.

| Skill | What it carries |
|-------|-----------------|
| `brainstorm` | The brainstorming process — batched questions, adaptive exit, design capture |
| `task-planner` | The pipeline that produces a tasks file: research, spec analysis, story decomposition |
| `story-executor` | The canonical prompt every story-executing agent receives |
| `aimi-learnings` | Triage of friction events captured by hooks; drafts promotion proposals for review |

### Development and code style

| Skill | What it carries |
|-------|-----------------|
| `dhh-rails-style` | Ruby and Rails in DHH's 37signals style |
| `andrew-kane-gem-writer` | Ruby gems following Andrew Kane's patterns |
| `dspy-ruby` | Type-safe LLM applications with DSPy.rb |
| `frontend-design` | Distinctive, production-grade frontend interfaces |
| `every-style-editor` | Copy review against Every's editorial style |
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
| `rclone` | Uploading and syncing to S3, R2, B2, Google Drive, Dropbox |

### Disabled — kept for reference

| Skill | What it carries |
|-------|-----------------|
| `file-todos` | File-based todo tracking |
| `resolve-pr-parallel` | Resolving PR comments in parallel |

---

## Agents (33)

### Research (7)

| Agent | What it does |
|-------|--------------|
| `aimi-codebase-researcher` | Repository structure, patterns, conventions |
| `aimi-learnings-researcher` | Searches `.aimi/solutions/` for past solutions to similar problems |
| `aimi-best-practices-researcher` | External best practices and community conventions |
| `aimi-framework-docs-researcher` | Framework documentation and version-specific guidance |
| `aimi-bundle-prototype-author` | Builds a self-contained prototype HTML from a design bundle |
| `aimi-design-bundle-researcher` | Reads BusinessSpec and DesignSpec bundles into structured findings |
| `aimi-foundation-architect` | Proposes a stack-adaptive Clean Architecture foundation for new repositories |

### Review (15)

| Agent | What it does |
|-------|--------------|
| `aimi-architecture-strategist` | Architectural compliance and design integrity |
| `aimi-security-sentinel` | Security vulnerabilities and OWASP compliance |
| `aimi-code-simplicity-reviewer` | YAGNI violations and simplification opportunities |
| `aimi-performance-oracle` | Performance bottlenecks and scalability |
| `aimi-agent-native-reviewer` | Whether an agent can do everything a user can |
| `aimi-data-integrity-guardian` | Migrations, data models, transaction safety |
| `aimi-data-migration-expert` | Data migrations, backfills, schema changes |
| `aimi-deployment-verification-agent` | Go/No-Go deployment checklists |
| `aimi-schema-drift-detector` | Unrelated `schema.rb` changes sneaking into a PR |
| `aimi-pattern-recognition-specialist` | Design patterns, anti-patterns, naming |
| `aimi-dhh-rails-reviewer` | DHH and 37signals Rails style |
| `aimi-kieran-rails-reviewer` | Rails conventions, clarity, maintainability |
| `aimi-kieran-typescript-reviewer` | TypeScript type safety and modern patterns |
| `aimi-kieran-python-reviewer` | Pythonic patterns, type safety, maintainability |
| `aimi-julik-frontend-races-reviewer` | JavaScript race conditions and DOM lifecycle bugs |

### Design (2)

| Agent | What it does |
|-------|--------------|
| `aimi-design-implementation-reviewer` | Compares the live UI against Figma or a prototype |
| `aimi-design-iterator` | Refines a UI through screenshot, analyze, improve cycles |

### Workflow (8)

| Agent | What it does |
|-------|--------------|
| `aimi-bug-reproduction-validator` | Reproduces and validates bug reports, any language or framework |
| `aimi-cross-story-auditor` | Audits staged stories for drift between them; emits patches, writes no file |
| `aimi-learnings-triage` | Read-only triage of friction events; returns a grouped report without marking anything |
| `aimi-scope-negative-verifier` | Re-checks a claim that something is absent, using data-flow analysis rather than a name search |
| `aimi-scope-positive-verifier` | Re-checks a claim that something already exists, the same way |
| `aimi-spec-flow-analyzer` | Analyzes a spec for flow gaps and missing cases |
| `aimi-spec-flow-symbol-extractor` | Pulls grep-safe code symbols out of spec questions for cross-checking |
| `aimi-story-expander` | Expands one outline entry into a complete user story |

---

## Choosing models per category

Each of the four agent categories can run on a different Claude model. Configure it with `/aimi:setup-models`, or by hand in `~/.config/aimi/models.json`.

See [architecture.md](architecture.md#per-category-model-configuration) for how the resolution works.
