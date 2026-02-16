# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0] - 2026-02-16

### Added

- **jq-based task extraction**: Only load ONE story into context at a time
  - `/aimi:execute` extracts only metadata (project, branchName, counts)
  - `/aimi:next` extracts only the next pending story
- **`skipped` field**: Prevents infinite loop on failed tasks
  - When user says "skip", sets `skipped: true` on the story
  - jq query filters: `passes == false AND skipped != true`

### Changed

- `/aimi:execute` now shows separate counts for pending, completed, and skipped
- `/aimi:next` uses jq instead of reading full tasks.json
- Added `Bash(jq:*)` to allowed-tools for both commands

### Fixed

- Infinite loop when a task keeps failing (now properly excluded after skip)

## [0.4.2] - 2026-02-16

### Fixed

- `/aimi:plan` now properly runs compound-engineering's `/workflows:plan` first, then automatically converts to tasks.json
- Added explicit two-phase execution flow with no user prompts between phases
- Added `Skill(compound-engineering:workflows:plan)` to allowed-tools

### Added

- Error handling section in `/aimi:plan` for failed or cancelled operations

## [0.4.1] - 2026-02-16

### Security

- **Path Traversal Prevention**: Added comprehensive path validation for `relevantFiles` and `patternsToFollow`
  - Blocks `..` sequences, absolute paths, protocol prefixes, null bytes
  - Blocks access to sensitive paths (`.git/`, `.env`, `.ssh/`)
- **Expanded Command Injection Blocklist**: Now blocks `&&`, `||`, `>`, `>>`, `<`, newlines, and more
- **Strengthened Prompt Injection Defenses**: Added patterns for role manipulation, system prompt extraction, and boundary breaking

### Added

- **Schema Versioning**: `schemaVersion` field in tasks.json (v2.0 for task-specific steps)
- **qualityChecks Field**: Explicit verification commands per story (typecheck, test, lint)
- **AGENTS.md Content Injection**: Small AGENTS.md files (< 2KB) are inlined directly in prompts
- **Placeholder Interpolation Documentation**: Complete reference for prompt template placeholders
- **Pattern Matching Tie-Breaking Rules**: Deterministic selection when multiple patterns match

### Changed

- **Naming Consistency**: Renamed `file_patterns` to `filePatterns` (camelCase) in pattern library
- **Simplified Error Messages**: Consistent format: `Error: Story [ID] - [field]: [issue]. Fix: [action].`
- **Consolidated Validation Rules**: task-format.md is now the single source of truth
- **Removed Duplicate Prompt Example**: Task Tool Invocation section now references the main template

### Fixed

- Pattern files now use consistent camelCase for `filePatterns` field

## [0.4.0] - 2026-02-16

### Added

- **Task-Specific Step Generation**: Each story now includes pre-computed, domain-aware execution steps
- **Pattern Library** (`docs/patterns/`): Workflow templates for common task types
  - `prisma-schema.md` - Database schema changes with Prisma
  - `server-action.md` - Next.js server actions
  - `react-component.md` - React component creation
  - `api-route.md` - API endpoint implementation
- **AGENTS.md Discovery**: Automatic discovery and matching of AGENTS.md files to tasks
- **TaskType Inference**: Keyword-based pattern matching with LLM fallback

### Changed

- **BREAKING:** tasks.json schema now requires four new fields per story:
  - `taskType` (string, snake_case, max 50 chars) - Domain classification
  - `steps` (array, 1-10 items, each max 500 chars) - Task-specific execution steps
  - `relevantFiles` (array, max 20 items) - Files to read first
  - `patternsToFollow` (string) - AGENTS.md path or "none"
- `/aimi:next` now validates required fields before execution
- `/aimi:next` prompt template uses story.steps instead of generic execution flow
- `story-executor` skill updated with STEPS, RELEVANT FILES, and PATTERNS sections
- `plan-to-tasks` skill now generates task-specific fields during conversion

### Migration

Existing tasks.json files will fail validation. To migrate:

```bash
# Regenerate tasks.json from your plan file
/aimi:plan-to-tasks docs/plans/your-plan.md
```

Or manually add the required fields to each story in tasks.json.

## [0.3.0] - 2026-02-15

### Changed

- **BREAKING:** Rename `completed` field to `passes` in tasks.json schema
  - Better reflects acceptance criteria validation semantics (pass/fail)
  - Aligns with testing vocabulary
  - Updated all commands: deepen, execute, next, status
  - Updated all skills: plan-to-tasks, story-executor
  - Existing tasks.json files need field renamed from `completed` to `passes`

## [0.2.1] - 2026-02-15

### Added

- AGENTS.md update instructions in story-executor (mirrors Ralph's prompt.md pattern)
- Step 10 in execution-rules.md for updating AGENTS.md files with reusable patterns
- AGENTS.md guidance in compact prompt template

### Changed

- Execution flow now includes AGENTS.md check before committing (Step 5 in SKILL.md)

## [0.2.0] - 2026-02-15

### Security

- **BREAKING:** Add branchName validation in `/aimi:execute` to prevent command injection
- Add input sanitization for story content before prompt interpolation (prevents prompt injection)
- Restrict Bash permissions in `/aimi:next` to specific command prefixes (git, npm, bun, yarn, tsc, eslint, prettier)

### Changed

- **BREAKING:** Introduced `completed` field in tasks.json schema (now renamed to `passes` in v0.3.0)
- Inline story data in Task prompts (reduces file I/O by ~33%)
- Extract only Codebase Patterns from progress.md (reduces context usage)
- Add structured error format with type classification for programmatic handling

### Added

- JSON schema validation requirements in task-format.md
- Available Capabilities section in story-executor (agents know their tools)
- Compact prompt template for subsequent stories (~60% token reduction)
- Progress rotation guidelines (archive when exceeding 50KB)
- Error type classification: typecheck_failure, test_failure, lint_failure, runtime_error, dependency_missing, unknown

### Removed

- Duplicate plugin.json at root level (keep only in plugins/aimi-engineering/)

## [0.1.0] - 2026-02-15

### Added

#### Commands
- `/aimi:brainstorm` - Explore ideas through guided brainstorming (wraps compound-engineering)
- `/aimi:plan` - Create implementation plan and convert to tasks.json
- `/aimi:deepen` - Enhance plan with research and update tasks.json
- `/aimi:review` - Code review using compound-engineering workflows
- `/aimi:status` - Show current task execution progress
- `/aimi:next` - Execute the next pending story with retry logic
- `/aimi:execute` - Run all stories autonomously in a loop

#### Skills
- `plan-to-tasks` - Convert markdown implementation plans to structured tasks.json format
- `story-executor` - Provides prompt template for Task-spawned agents executing stories

#### Documentation
- Task format reference with JSON schema and sizing rules
- Execution rules reference with 9-step execution flow
- Complete README with workflow guide and troubleshooting

### Dependencies

This plugin requires **compound-engineering-plugin** to be installed first.
