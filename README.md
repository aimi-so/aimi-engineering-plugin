# Aimi Engineering Plugin

Autonomous task execution for Claude Code with structured JSON task management.

Transform implementation plans into executable user stories, then run them autonomously with full context isolation. Stories with independent dependencies execute in parallel via wave-based swarm orchestration. Each story gets its own agent with automatic state tracking.

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Commands](#commands)
- [Workflow](#workflow)
- [Task Schema](#task-schema)
- [Pattern Library](#pattern-library)
- [Architecture](#architecture)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [Version History](#version-history)

## Installation

### Prerequisites

No external plugin dependencies. This plugin is fully standalone.

### Install Steps

```bash
# Install aimi-engineering plugin
claude /plugin marketplace add https://github.com/aimi-so/aimi-engineering-plugin
claude /plugin install aimi-engineering
```

### Verify Installation

```bash
# Check both plugins are installed
claude /plugin list

# Test aimi commands are available
/aimi:status
```

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
| `/aimi:brainstorm` | Explore ideas through guided brainstorming | `/aimi:brainstorm [feature]` |
| `/aimi:plan` | Generate tasks.json directly from feature description | `/aimi:plan [feature]` |
| `/aimi:deepen` | Enrich tasks.json stories with research insights | `/aimi:deepen [tasks-path]` |
| `/aimi:status` | Show current task execution progress | `/aimi:status` |
| `/aimi:next` | Execute the next pending story | `/aimi:next` |
| `/aimi:execute` | Run all stories autonomously (parallel for v3, sequential for v2.2) | `/aimi:execute` |
| `/aimi:review` | Multi-agent code review with findings synthesis | `/aimi:review [PR or branch]` |
| `/aimi:swarm` | Execute multiple tasks.json files in parallel Docker sandboxes | `/aimi:swarm [--file path] [--max N]` |

### Command Details

#### `/aimi:brainstorm`

Standalone brainstorm workflow with codebase research and Ralph-style batched multiple-choice questions. Explores requirements and approaches interactively before committing to implementation.

```bash
/aimi:brainstorm Add social login with Google and GitHub
```

#### `/aimi:plan`

Generates `.aimi/tasks/YYYY-MM-DD-[feature]-tasks.json` directly from a feature description. Runs a full pipeline: brainstorm detection, parallel research (codebase + learnings), optional external research, spec-flow analysis, and story decomposition.

```bash
/aimi:plan Add user registration flow
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

#### `/aimi:execute`

Orchestrates autonomous execution of all pending stories. Automatically detects schema version and dependency graph shape to choose the optimal execution strategy.

**v3 with parallel opportunities:**
1. Validates branch name and dependency graph (DAG validation)
2. Creates/checkouts feature branch
3. Builds execution waves from dependency graph
4. Executes each wave: independent stories run in parallel via Team/swarm workers
5. Each worker operates in its own worktree; leader merges results after each wave
6. Cascade-skips dependent stories on failure
7. Reports completion with wave progress and commit count

**v3 with linear dependencies / v2.2 fallback:**
1. Validates branch name (security)
2. Creates/checkouts feature branch
3. Loops through stories sequentially via `/aimi:next`
4. Handles skip/retry/stop decisions
5. Reports completion with commit count

#### `/aimi:review`

Multi-agent code review using aimi-native review agents. Runs parallel agents (architecture, security, simplicity, performance, agent-native), plus conditional migration and language-specific reviewers. Synthesizes findings with severity categorization (P1/P2/P3).

```bash
/aimi:review           # Review current branch
/aimi:review 42        # Review PR #42
/aimi:review feat/auth # Review specific branch
```

#### `/aimi:swarm`

Executes multiple tasks.json files in parallel Docker sandboxes. Each task file gets its own Sysbox-isolated container with a full Claude Code agent running the story-executor flow inside it.

```bash
/aimi:swarm                          # Discover and select task files
/aimi:swarm --file .aimi/tasks/f.json  # Execute a single task file
/aimi:swarm --max 2                  # Limit to 2 concurrent containers
/aimi:swarm status                   # View swarm state
/aimi:swarm resume                   # Resume pending containers
/aimi:swarm cleanup                  # Remove containers and state
```

Requirements:
- Docker with Sysbox runtime installed
- Git remote `origin` configured (containers clone via URL)
- `ANTHROPIC_API_KEY` set in environment (injected into containers)

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
  "schemaVersion": "3.0",
  "metadata": {
    "title": "feat: Add user authentication",
    "type": "feat",
    "branchName": "feat/user-auth",
    "createdAt": "2026-02-16",
    "planPath": ".aimi/plans/2026-02-16-user-auth-plan.md",
    "maxConcurrency": 4
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
| `schemaVersion` | string | Schema version (currently "3.0", also supports "2.2") |
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
| `maxConcurrency` | number | (v3) Max parallel workers (default 4) |

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
AIMI_CLI=$(ls ~/.claude/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1)

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
| Each acceptance criterion | 300 chars |

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

**Fix:** Review the tasks file manually, remove suspicious content, regenerate with `/aimi:plan-to-tasks`.

## Version History

**Current Version:** 1.17.0

### Recent Changes

**v1.17.0** - Sandbox & Swarm Auto-Approve Hooks
- auto-approve-cli.sh: SANDBOX_MGR path validation + subcommand whitelist
- auto-approve-cli.sh: BUILD_IMG path validation + invocation approval
- auto-approve-cli.sh: swarm-* subcommands added to AIMI_CLI whitelist
- auto-approve-cli.sh: docker exec -i aimi-* pattern for ACP adapter (no wildcard Docker)

**v1.16.0** - Docker Swarm Orchestration
- `/aimi:swarm` command for multi-task parallel Docker sandbox execution
- Multi-select task file discovery, container provisioning, parallel ACP fan-out
- Subcommands: status, resume, cleanup
- Configurable maxContainers limit with partial failure handling

**v1.12.0** - Parallel Execution Hardening
- worktree-manager: `remove` command, `--from` flag, input validation, non-interactive
- aimi-cli: flock-based locking, story ID validation, `validate-stories` command, maxConcurrency guard
- execute.md: orphaned recovery, content validation, agent-driven merge conflict resolution, worker timeout, single-sourced worker prompt
- auto-approve-cli.sh: subcommand whitelist, metacharacter rejection, WORKTREE_MGR support
- story-executor SKILL.md: canonical prompt template, contradiction fixes

**v1.9.0** - Schema v3, Parallel Execution, Worktree Merge
- Schema v3 with `dependsOn` dependency graph and `status` enum replacing `passes` boolean
- `/aimi:execute` parallel execution: wave-based swarm orchestration for independent stories
- Worktree merge commands (`merge`, `merge-all`) in worktree-manager.sh
- CLI extensions: `detect-schema`, `list-ready`, `mark-in-progress`, `validate-deps`, `cascade-skip`
- All existing commands updated for dual v2.2/v3 support

**v1.8.0** - Fully Standalone (Zero Dependencies)
- New `brainstorm` skill with process knowledge, Ralph-style questions, adaptive exit
- `/aimi:brainstorm` rewritten as standalone (codebase research + batched questions)
- compound-engineering dependency fully eliminated

**v1.5.0** - Standalone Agents
- 28 aimi-native agents (research, review, design, docs, workflow)
- `/aimi:review` rewritten as standalone multi-agent review
- Task-planner and deepen use aimi agents directly

**v1.4.0** - Direct Generation (Schema v2.2)
- `planPath` optional/nullable (null when generated by task-planner)
- `brainstormPath` as optional context reference
- Backward compatible with v2.1

**v1.2.0** - CLI & State Management
- Simplified schema: removed `taskType`, `steps`, `relevantFiles`, `qualityChecks`
- Dynamic task filenames: `YYYY-MM-DD-[feature-name]-tasks.json`
- Improved commit format: `<type>(<scope>): <description>`
- Rich PR template with Problem/Solution sections

**v2.0.0** - Metadata Restructure
- Schema version set to "2.0"
- Metadata block with `title`, `type`, `branchName`, `createdAt`, `planPath`
- Shorter type values: `feat`, `ref`, `bug`, `chore`

**v1.0.0** - Ralph-Style Flat Stories
- Flat story structure (no nested tasks array)
- Priority-based execution order
- Project guidelines loading from CLAUDE.md/AGENTS.md

See [CHANGELOG.md](CHANGELOG.md) for complete version history.

## Components

| Type | Count | Description |
|------|-------|-------------|
| Commands | 8 | Slash commands for workflow stages |
| Skills | 3 | `brainstorm`, `task-planner`, `story-executor` |
| Agents | 28 | 4 research, 15 review, 3 design, 1 docs, 5 workflow |

## License

MIT
