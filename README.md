# Aimi Engineering Plugin

Autonomous task execution for Claude Code with structured JSON task management.

Transform implementation plans into executable user stories, then run them autonomously with full context isolation. Stories with independent dependencies execute in parallel via Team orchestration with git worktrees. Each story gets its own agent with automatic state tracking. Per-category model selection lets you route research, review, design, and workflow agents to different Claude models via `~/.config/aimi/models.json`.

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Commands](#commands)
- [Skills](#skills)
- [Agents](#agents)
- [Workflow](#workflow)
- [Task Schema](#task-schema)
- [Architecture](#architecture)
- [Security](#security)
- [Troubleshooting](#troubleshooting)

## Installation

### Claude Code

No external dependencies. This plugin is fully standalone.

```bash
# Add marketplace and install
claude /plugin marketplace add https://github.com/aimi-so/aimi-engineering-plugin
claude /plugin install aimi-engineering
```

Verify installation:

```bash
claude /plugin list
/aimi:status
```

### OpenCode

Install using the built-in installer script. No external dependencies required.

```bash
git clone https://github.com/aimi-so/aimi-engineering-plugin
cd aimi-engineering-plugin
./install.sh --to opencode
```

This installs the plugin into OpenCode's global config directory (`~/.config/opencode/`) with full compatibility translation:

- **Commands** are translated and installed as nested directories (e.g., `commands/aimi/plan.md`) so they appear as `/aimi:plan`, `/aimi:execute`, etc.
- **Command bodies** are fully rewritten for OpenCode compatibility — agent invocations use the Task tool, CLI path references use `OPENCODE_CONFIG_DIR`, and error messages point to the OpenCode installer
- **Skills** are copied to `~/.config/opencode/skills/` with SKILL.md and reference files preserved
- **Agents** are translated to `~/.config/opencode/agents/aimi-*.md` with model fields preserved
- **Permissions** are auto-configured in `opencode.json` for autonomous Bash execution
- **Plugin source** (CLI scripts, hooks) is copied to `~/.config/opencode/plugins/aimi-engineering/`
- **context7 MCP** server is added to `opencode.json`
- **`AIMI_PLUGIN_DIR`** is set in your shell profile

After installation, restart your shell or run:

```bash
export AIMI_PLUGIN_DIR="$HOME/.config/opencode/plugins/aimi-engineering"
```

#### Known Limitations

- **`disable-model-invocation`** is not supported in OpenCode. The installer prepends a side-effect warning to command bodies as a workaround, instructing the model not to invoke sub-agents autonomously.
- **`AskUserQuestion`** tool is not available in OpenCode. Commands that use it are rewritten to use natural conversation prompts instead (asking the user directly in the response).
- **Custom `subagent_type`** (e.g., `subagent_type: researcher`) is not yet supported in OpenCode. Agents are installed as general-purpose with the agent prompt inlined into the Task tool invocation.

#### Project-Level Install

To install into `.opencode/` in your project directory instead of globally:

```bash
./install.sh --to opencode --project
```

#### Uninstall

```bash
./install.sh --uninstall --from opencode
```

#### Preview Changes

```bash
./install.sh --to opencode --dry-run
```

### Environment Variable

The `AIMI_PLUGIN_DIR` environment variable points to the installed plugin directory so that commands can locate CLI scripts, skill references, and agent definitions. The installer sets this automatically. Do not set this variable manually unless you have a custom installation layout.

## Quick Start

```bash
# 1. Brainstorm your feature
/aimi:brainstorm Add user authentication with email/password

# 2. Generate tasks directly
/aimi:plan Add user authentication

# 3. Execute all stories autonomously
/aimi:execute

# 4. Review the implementation
/aimi:review
```

## Commands

| Command | Description | Usage |
|---------|-------------|-------|
| `/aimi:brainstorm` | Explore ideas through guided brainstorming | `/aimi:brainstorm [feature] [--non-interactive]` |
| `/aimi:plan` | Generate tasks.json directly from feature description | `/aimi:plan [feature] [--non-interactive]` |
| `/aimi:deepen` | Enrich tasks.json stories with research insights | `/aimi:deepen [tasks-path]` |
| `/aimi:status` | Show current task execution progress | `/aimi:status` |
| `/aimi:next` | Execute the next pending story | `/aimi:next` |
| `/aimi:execute` | Run all stories autonomously (parallel for v3, sequential for v2.2) | `/aimi:execute` |
| `/aimi:review` | Multi-agent code review with findings synthesis | `/aimi:review [PR or branch]` |
| `/aimi:open-pr` | Open a pull request from the current task branch | `/aimi:open-pr [PR options]` |
| `/aimi:validate-bug` | Reproduce and validate a bug report via the bug-reproduction-validator agent | `/aimi:validate-bug [bug description]` |

### Command Details

#### `/aimi:brainstorm`

Standalone brainstorm workflow with codebase research and Ralph-style batched multiple-choice questions. Explores requirements and approaches interactively before committing to implementation. Pass `--non-interactive` to skip all prompts and auto-defer open questions (agent/CI mode).

```bash
/aimi:brainstorm Add social login with Google and GitHub
/aimi:brainstorm Add social login --non-interactive
```

#### `/aimi:plan`

Generates `.aimi/tasks/YYYY-MM-DD-[feature]-tasks.json` directly from a feature description. Runs a full pipeline: brainstorm detection, parallel research (codebase + learnings), optional external research, spec-flow analysis, and story decomposition. Stories are decomposed as vertical slices — each delivers user-visible value end-to-end across all layers rather than being split by horizontal layer boundaries. Interactive by default — pass `--non-interactive` to skip all Open Question prompts and auto-defer them (agent/CI mode).

```bash
/aimi:plan Add user registration flow
/aimi:plan Add user registration flow --non-interactive
```

Output:
- `.aimi/tasks/YYYY-MM-DD-feature-name-tasks.json`

#### `/aimi:deepen`

Enhances an existing plan with research insights while preserving completion state of existing stories.

```bash
/aimi:deepen .aimi/plans/2026-02-16-user-auth-plan.md
```

#### `/aimi:status`

Displays progress using jq for minimal context usage.

```
Aimi Status: user-auth (feature/user-auth)

Stories: 3/7 complete

✓ US-001: Add database schema          (completed)
✓ US-002: Add password utilities       (completed)
✗ US-003: Add login UI                 (skipped: auth middleware issue)
→ US-004: Add registration UI          (next)
○ US-005: Add session middleware       (pending)
○ US-006: Add logout endpoint          (pending)
○ US-007: Add dashboard                (pending)

Next: US-004 - Add registration UI
```

#### `/aimi:next`

Executes the next pending story. Uses jq to extract only the current story, keeping context clean.

Features:
- Validates required fields before execution
- Auto-retries once on failure
- Asks user to skip/retry/stop on persistent failures

**Container mode:** when the tasks file's `metadata.execution` is `"container"`, `/aimi:next` creates (or, on a later invocation, reuses) a container for the feature — a git worktree at `.worktrees/<branchName>` — instead of touching the current working tree, and passes that path to the executor as `WORKTREE_PATH`; the story runs and commits inside the container, on the feature branch. Tasks files with `metadata.execution` absent or set to `"inline"` keep running exactly as before this feature shipped: no container is created, no `WORKTREE_PATH` is passed, and the story executes directly against the current working tree (sequential mode).

#### `/aimi:execute`

Orchestrates autonomous execution of all pending stories. Automatically detects schema version, dependency graph shape, and `metadata.execution` to choose the optimal execution strategy.

**v3 with parallel opportunities:**
1. Validates branch name and dependency graph (DAG validation)
2. Creates/checkouts feature branch
3. Builds execution waves from dependency graph
4. Executes each wave: independent stories run in parallel via worktree workers
5. Each worker operates in its own worktree; leader merges results after each wave
6. Cascade-skips dependent stories on failure
7. Reports completion with wave progress and commit count

**v3 with linear dependencies / v2.2 fallback:**
1. Validates branch name (security)
2. Creates/checkouts feature branch
3. Loops through stories sequentially via `/aimi:next`
4. Handles skip/retry/stop decisions
5. Reports completion with commit count

**Container mode (`metadata.execution: "container"`):**

Instead of checking out the feature branch on your current working tree, `/aimi:execute` creates (or reuses) a container — a git worktree at `.worktrees/<branchName>` — and runs the whole thing there:

1. Creates or reuses the feature container. **The main working tree's checkout is left completely untouched for the entire run.**
2. Installs dependencies inside the container once (lockfile-detected package manager: bun/pnpm/yarn/npm)
3. Starts a managed dev server inside the container, automatically, before the wave loop — only when a story needs visual verification
4. Runs the wave loop inside the container (parallel or sequential, per the strategies above)
5. On completion: stops the dev server, pushes `<branchName>` to `origin`, then removes the container while preserving the branch. Since nothing is left checked out locally, the report suggests `/aimi:open-pr --branch <branchName>` and `/aimi:review <branchName>` as next steps instead of the usual `gh pr create` / `/aimi:review`.

**Backward compatible by default:** a tasks.json with no `metadata.execution` field — every file created before this feature, and any new one that doesn't set it — keeps running the inline flows described above exactly as before. No container is ever created for it.

**Known limitations of container mode:**
- Non-Node stacks (no `package.json` with a `dev` script) get no managed dev server — visual verification degrades to `skipped`, not a failure.
- Ports hardcoded in application config (OAuth redirect URIs, CORS allowlists) are not remapped when the dev server binds to a different free port than expected.
- Full-stack split runs get one dev server per sibling container with no proxy between them, so one container's visual verification cannot reach its sibling container's API.
- Uncommitted edits sitting in your main working tree do not propagate into a container — `git worktree add` only branches from committed history, so commit first.

#### `/aimi:review`

Multi-agent code review using aimi-native review agents. Runs parallel agents (architecture, security, simplicity, performance, agent-native), plus conditional migration and language-specific reviewers. Synthesizes findings with severity categorization (P1/P2/P3).

```bash
/aimi:review           # Review current branch
/aimi:review 42        # Review PR #42
/aimi:review feat/auth # Review specific branch
```

## Skills

17 skills providing domain expertise and reusable workflows.

### Core (Internal)

Used internally by commands — not user-invocable.

| Skill | Description |
|-------|-------------|
| `brainstorm` | Brainstorming process knowledge (batched questions, adaptive exit, design capture) |
| `task-planner` | Pipeline for generating tasks.json (research, spec analysis, story decomposition) |
| `story-executor` | Canonical prompt template for Task-spawned agents executing stories |

### Development & Code Style

| Skill | Description |
|-------|-------------|
| `dhh-rails-style` | Write Ruby/Rails code in DHH's 37signals style |
| `andrew-kane-gem-writer` | Write Ruby gems following Andrew Kane's patterns |
| `dspy-ruby` | Build type-safe LLM applications with DSPy.rb |
| `frontend-design` | Create distinctive, production-grade frontend interfaces |
| `every-style-editor` | Review and edit copy for Every's editorial style compliance |
| `agent-native-architecture` | Build apps where agents are first-class citizens |
| `react-best-practices` | React and Next.js performance optimization guidelines from Vercel Engineering |
| `react-native-skills` | React Native and Expo best practices for performant mobile apps |

### Tooling & Automation

| Skill | Description |
|-------|-------------|
| `agent-browser` | Browser automation using Vercel's agent-browser CLI |
| `create-agent-skills` | Expert guidance for creating Claude Code skills and slash commands |
| `git-worktree` | Manage Git worktrees for isolated parallel development |
| `rclone` | Upload and sync files to S3, R2, B2, Google Drive, Dropbox |

### Disabled (Reference Only)

| Skill | Description |
|-------|-------------|
| `file-todos` | File-based todo tracking system |
| `resolve-pr-parallel` | Resolve PR comments using parallel processing |

## Agents

30 aimi-native agents organized into 4 categories.

### Research (6)

| Agent | Description |
|-------|-------------|
| `aimi-codebase-researcher` | Repository structure, patterns, and conventions |
| `aimi-learnings-researcher` | Search `.aimi/solutions/` for past solutions |
| `aimi-best-practices-researcher` | External best practices and community conventions |
| `aimi-framework-docs-researcher` | Framework documentation and version-specific guidance |
| `aimi-bundle-prototype-author` | Generate self-contained bundle prototype HTML from design bundle context |
| `aimi-design-bundle-researcher` | Structured passthrough reader for BusinessSpec and DesignSpec bundles |

### Review (15)

| Agent | Description |
|-------|-------------|
| `aimi-architecture-strategist` | Architectural compliance and design integrity |
| `aimi-security-sentinel` | Security vulnerabilities and OWASP compliance |
| `aimi-code-simplicity-reviewer` | YAGNI violations and simplification opportunities |
| `aimi-performance-oracle` | Performance bottlenecks and scalability |
| `aimi-agent-native-reviewer` | Agent-native parity (user actions = agent actions) |
| `aimi-data-integrity-guardian` | Database migrations, data models, transaction safety |
| `aimi-data-migration-expert` | Data migrations, backfills, schema changes |
| `aimi-deployment-verification-agent` | Go/No-Go deployment checklists |
| `aimi-schema-drift-detector` | Unrelated schema.rb changes in PRs |
| `aimi-pattern-recognition-specialist` | Design patterns, anti-patterns, naming conventions |
| `aimi-dhh-rails-reviewer` | DHH/37signals Rails style compliance |
| `aimi-kieran-rails-reviewer` | Rails conventions, clarity, maintainability |
| `aimi-kieran-typescript-reviewer` | TypeScript type safety and modern patterns |
| `aimi-kieran-python-reviewer` | Pythonic patterns, type safety, maintainability |
| `aimi-julik-frontend-races-reviewer` | JavaScript race conditions and DOM lifecycle |

### Design (2)

| Agent | Description |
|-------|-------------|
| `aimi-design-implementation-reviewer` | Compare live UI against Figma designs |
| `aimi-design-iterator` | Iterative UI refinement through screenshot-analyze-improve cycles |

### Workflow (6)

| Agent | Description |
|-------|-------------|
| `aimi-bug-reproduction-validator` | Systematically reproduce and validate bug reports across all languages and frameworks |
| `aimi-cross-story-auditor` | Audit all Pass 2 staging JSONs for cross-story drift; emits patches and unresolved entries — reads and writes no file |
| `aimi-learnings-triage` | Read-only triage of friction events from aimi hooks; returns a grouped JSON report without marking events |
| `aimi-scope-negative-verifier` | Re-check negative existence claims via data-flow analysis and caller tracing; returns a confirm/refute verdict with evidence |
| `aimi-spec-flow-analyzer` | Analyze specs for user flow completeness and gaps |
| `aimi-story-expander` | Expand a single outline entry into a full schema v3.3 user-story JSON for the /aimi:plan two-pass pipeline |

## Workflow

```
/aimi:brainstorm → /aimi:plan → /aimi:deepen (optional) → /aimi:execute → /aimi:review
```

### Workflow Diagram

```
┌─────────────────┐
│  /aimi:brainstorm  │  Explore ideas interactively
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│    /aimi:plan      │  Generate plan + tasks file
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   /aimi:deepen     │  (Optional) Enhance with research
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   /aimi:execute    │  Run all stories autonomously
│                 │
│  ┌───────────┐  │
│  │ /aimi:next   │  │  One story at a time
│  └───────────┘  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   /aimi:review     │  Code review before merge
└─────────────────┘
```

## Task Schema

All execution state lives in `.aimi/tasks/YYYY-MM-DD-[feature-name]-tasks.json`. No separate progress file.

### Schema Version 3.0 (Current)

```json
{
  "schemaVersion": "3.1",
  "metadata": {
    "title": "feat: Add user authentication",
    "type": "feat",
    "branchName": "feat/user-auth",
    "createdAt": "2026-02-16",
    "planPath": ".aimi/plans/2026-02-16-user-auth-plan.md",
    "maxConcurrency": 20
  },
  "userStories": [
    {
      "id": "US-001",
      "title": "Add user database schema",
      "description": "As a developer, I need the user table schema",
      "acceptanceCriteria": [
        "Users table has email, password_hash, created_at columns",
        "Email column has unique constraint",
        "Typecheck passes"
      ],
      "priority": 1,
      "status": "pending",
      "dependsOn": [],
      "notes": ""
    }
  ]
}
```

### Field Reference

#### Root Fields

| Field | Type | Description |
|-------|------|-------------|
| `schemaVersion` | string | Schema version: `"3.1"` |
| `metadata` | object | Project metadata |
| `userStories` | array | Array of Story objects |

#### Metadata Fields

| Field | Type | Description |
|-------|------|-------------|
| `title` | string | Feature title with type prefix |
| `type` | string | One of: `feat`, `ref`, `bug`, `chore` |
| `branchName` | string | Git branch for this feature |
| `createdAt` | string | Creation date (YYYY-MM-DD) |
| `planPath` | string | Path to source plan file |
| `brainstormPath` | string | (optional) Path to brainstorm file |
| `maxConcurrency` | number | (v3) Max parallel workers (default 20) |

#### Story Fields (v3)

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Story identifier (US-001, US-002, etc.) |
| `title` | string | Short story title |
| `description` | string | User story format description |
| `acceptanceCriteria` | array | Verifiable criteria for completion |
| `priority` | number | Tiebreaker for stories at same dependency depth |
| `status` | string | One of: `pending`, `in_progress`, `completed`, `failed`, `skipped` |
| `dependsOn` | array | Story IDs that must complete before this story can start |
| `notes` | string | Error details or learnings |
| `project` | string | (optional) Relative path from AIMI_ROOT to the target git repository for multi-repo execution |

> **Note:** As of v1.11.0, only schema v3.0 is supported. v2.2 backward compatibility was removed.

### Story Sizing

Each story must be completable in ONE agent iteration (one context window).

**Right-sized:**
- Add a database column
- Create a UI component
- Implement a server action
- Add an API endpoint

**Too big (split these):**
- "Build entire dashboard"
- "Add full authentication"
- "Create complete checkout flow"

### Story Ordering

Stories are ordered by dependency:

| Priority | Type | Examples |
|----------|------|----------|
| 1 | Schema/database | Migrations, models |
| 2 | Backend logic | Server actions, services |
| 3 | UI components | Forms, buttons, pages |
| 4 | Aggregation | Dashboards, summaries |

## Architecture

### One Story at a Time

Commands use `aimi-cli.sh` (installed with the plugin) to extract only what's needed, keeping context clean:

```bash
# Resolve CLI path (plugin install directory)
AIMI_CLI=$(ls "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1)

# /aimi:execute - initialize session with metadata
$AIMI_CLI init-session

# /aimi:next - get ONE story only
$AIMI_CLI next-story

# /aimi:status - get progress summary
$AIMI_CLI status
```

### Fresh Context Per Story

Each Task agent starts with clean context:
- No memory carryover between stories
- Full context window available for current story
- Learnings stored in CLAUDE.md/AGENTS.md for persistence

### Per-Category Model Configuration

Route different agent categories to different Claude models via `~/.config/aimi/models.json`. Generate the initial config interactively:

```bash
aimi-cli detect-models
```

The config maps four categories (`research`, `review`, `design`, `workflow`) to logical tiers, then resolves tiers to concrete model ids per host (`claudeCode`, `opencode`). Resolved models are passed via the Task tool `model:` parameter on Claude Code; the `aimi-task` OpenCode tool provides equivalent per-spawn model selection on OpenCode. Use `aimi-cli resolve-models` to inspect the resolved ids at runtime.

### Project Guidelines Discovery

Agents automatically discover and follow project conventions:

1. **CLAUDE.md** (project root) - Project-wide conventions
2. **AGENTS.md** (per directory) - Module-specific patterns
3. **Aimi defaults** - Fallback commit/PR rules

Small files (< 2KB) are inlined directly in prompts. Larger files are referenced.

### File Structure

```
.aimi/
├── plans/
│   └── YYYY-MM-DD-feature-name-plan.md
└── tasks/
    └── YYYY-MM-DD-feature-name-tasks.json
```

## Security

### Input Validation

All story content is validated before execution:

**Path traversal prevention:**
- Blocks `..` sequences
- Blocks absolute paths
- Blocks protocol prefixes (`file://`, `http://`)
- Blocks sensitive paths (`.git/`, `.env`, `.ssh/`)

**Command injection prevention:**
- Blocks `&&`, `||`, `;`
- Blocks redirects (`>`, `<`, `>>`)
- Blocks command substitution (`$()`, backticks)
- Blocks pipe operators

**Prompt injection prevention:**
- Blocks instruction override patterns
- Blocks role manipulation
- Blocks system prompt extraction attempts

### Branch Name Validation

Branch names must match:
```regex
^[a-zA-Z0-9][a-zA-Z0-9/_-]*$
```

Invalid characters (spaces, semicolons, quotes) trigger validation errors.

### Field Length Limits

| Field | Max Length |
|-------|------------|
| `title` | 200 chars |
| `description` | 500 chars |
| Each acceptance criterion | 600 chars |

## Troubleshooting

### "No tasks file found"

**Cause:** No task file exists yet.

**Fix:** Run `/aimi:plan [feature]` to create a plan and tasks.

### Story keeps failing

**Cause:** Persistent implementation issues.

**Fix:**
1. Check error details with `/aimi:status`
2. Try `/aimi:next` with a different approach
3. Use "skip" to move past blockers (marks `skipped: true`)

### Infinite loop on failed task

**Cause:** Fixed in v0.5.0.

**Fix:** Update to latest version. Skipped stories are excluded from jq query.

### Invalid branch name error

**Cause:** Branch name contains invalid characters.

**Fix:** Edit `branchName` in the tasks file to use only letters, numbers, hyphens, underscores, and forward slashes.

### Story validation failed

**Cause:** Story content contains potentially malicious patterns.

**Fix:** Review the tasks file manually, remove suspicious content, regenerate with `/aimi:plan`.

### Inspecting an agent-browser headed session

**Cause:** You want to attach Chrome DevTools to the Chromium that `agent-browser` launches in `--headed` mode (e.g., during `/aimi:execute` Visual Follow) to inspect the DOM, set breakpoints, or watch network traffic.

**Fix:** Launch the session with the Chrome remote-debugging port exposed, then attach via `chrome://inspect`:

1. Start the agent-browser session with remote debugging enabled:
   ```bash
   agent-browser --headed --session visual-follow \
     --chrome-flag="--remote-debugging-port=9222" \
     open https://example.com
   ```
2. In any local Chrome window, open `chrome://inspect/#devices`.
3. Click **Configure...** under "Discover network targets" and add `localhost:9222`.
4. The agent-browser tab appears under "Remote Target". Click **inspect** to attach DevTools.

The port (`9222`) is arbitrary — pick any free port and match it in step 3. If your installed `agent-browser` does not forward `--chrome-flag`, check `agent-browser --help` for the equivalent flag name on your version (e.g., `--chromium-arg`, `--chrome-args`).

For the full version history, see [CHANGELOG.md](CHANGELOG.md).

## Components

| Type | Count | Description |
|------|-------|-------------|
| Commands | 15 | Slash commands for workflow stages |
| Skills | 17 | 3 core, 8 development/style, 4 tooling/automation, 2 disabled/reference |
| Agents | 29 | 6 research, 15 review, 2 design, 6 workflow |
| Tools | 1 | OpenCode custom tool: `aimi-task` (per-spawn model selection for OpenCode) |

## License

MIT
