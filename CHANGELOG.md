# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.35.0] - 2026-04-02

### Added

- **brainstorm**: Parallel best-practices research in Phase 1 — spawns aimi-best-practices-researcher alongside aimi-codebase-researcher
- **brainstorm**: Decoupled specificity-skip logic — codebase and best-practices researchers assessed independently with distinct skip criteria
- **brainstorm**: Research Consolidation step (1c) merges internal patterns and external best practices, surfaces conflicts as candidate Phase 2 questions
- **brainstorm**: Graceful degradation for all 4 research permutations (both succeed, either fails/skipped, both fail)

## [1.34.0] - 2026-03-31

### Added

- **install.sh**: Full OpenCode command body translation — agent invocations rewritten for OpenCode Task tool compatibility
- **install.sh**: Skills installation (`install_skills()`) — copies SKILL.md and references to OpenCode skills directory
- **install.sh**: Nested command directories — commands installed as `commands/aimi/plan.md` for `/aimi:plan` naming
- **install.sh**: Bash permission auto-approval (`install_permissions()`) — configures opencode.json for autonomous execution
- **install.sh**: CLI path resolution rewriting — `CLAUDE_CONFIG_DIR` references replaced with `OPENCODE_CONFIG_DIR`
- **install.sh**: Error message rewriting — recovery instructions point to `./install.sh --to opencode`
- **install.sh**: AskUserQuestion fallback — replaced with natural conversation prompts
- **install.sh**: `disable-model-invocation` workaround — side-effect warning prepended to command bodies
- **install.sh**: Agent model field preservation — `model: haiku` preserved in translated agents

### Fixed

- **install.sh**: Python3 MCP fallback now uses `type: remote` instead of `type: http`

## [1.33.0] - 2026-03-30

### Added

- **install.sh**: Self-contained installer script for OpenCode cross-platform installation (no external dependencies)
- **install.sh**: Translates Claude Code commands and agents to OpenCode-native format
- **install.sh**: Automatic context7 MCP configuration in opencode.json
- **install.sh**: Uninstall support with `--uninstall` flag

### Changed

- **README.md**: Replaced compound-plugin converter instructions with install.sh usage

## [1.32.0] - 2026-03-30

### Added

- **cross-platform**: Cross-platform installation via compound-plugin converter for OpenCode, Codex, Copilot, and auto-detect
- **AIMI_PLUGIN_DIR**: Environment variable support for custom plugin directory resolution in all CLI commands
- **Layer 0**: CLI path resolution in all commands using AIMI_PLUGIN_DIR as Layer 0
- **auto-approve**: Hook patterns for Layer 0 resolution
- **tests**: Coverage for AIMI_PLUGIN_DIR paths

## [1.31.0] - 2026-03-30

### Changed

- **brainstorm.md**: Make command self-contained by inlining all brainstorm skill content — removes dependency on SKILL.md and reference files
- **brainstorm.md**: Conditional codebase research — skip research phase when no codebase context is available, reducing latency for greenfield brainstorms

### Removed

- **question-patterns.md**: Delete unused reference file from brainstorm skill — content was already inlined into brainstorm.md
- **SKILL.md (brainstorm)**: Remove reference to deleted question-patterns.md; add deprecation notice — skill is retained for reference only

## [1.30.3] - 2026-03-30

### Changed

- **brainstorm.md**: Make command self-contained by inlining all brainstorm skill content — response parsing table, formatting constraints, contextual question rules, topic addressed signals, input sanitization, pre-save checklist, and incremental validation guidance. Removes all references to the brainstorm skill, reducing token usage per session.

## [1.30.2] - 2026-03-30

### Fixed

- **execute.md, next.md, status.md, swarm.md**: Inline CLI path resolution logic — removes broken `See commands/references/cli-path-resolution.md` references that fail when plugin is installed outside the repo
- **status.md**: Remove broken `See task-format-v3.md` reference
- **SKILL.md (story-executor)**: Remove broken `See task-format-v3.md in ../task-planner/references/` reference — inline key fields with constraints instead
- **CLAUDE.md**: Remove broken `See task-format-v3.md` reference — inline schema version and key fields

## [1.30.1] - 2026-03-27

### Fixed

- **plan.md**: Inline schema v3 structure and dependsOn inference rules — planner agent no longer fails to find reference files when running outside the plugin repo
- **plan.md**: Add `validate-stories` to Phase 4.5 validation step
- **SKILL.md (task-planner)**: Remove broken relative path references to `references/task-format-v3.md`, `references/pipeline-phases.md`, and `references/story-decomposition.md` — inline essential content instead
- **SKILL.md (task-planner)**: Inline git repo auto-scan bash command (previously only in pipeline-phases.md)

## [1.30.0] - 2026-03-26

### Added

- **task-format-v3.md**: Optional per-story `project` field added to task schema v3 — specifies the relative path from AIMI_ROOT to the target git repository for multi-repo story execution
- **aimi-cli.sh**: Project field validation in `cmd_validate_stories()` — rejects absolute paths, path traversal (`..`), and shell metacharacters (`$`, `` ` ``, `;`, `|`, `&`); accepts valid relative paths; backwards compatible when project is absent
- **aimi-cli.sh**: Project field included in `cmd_list_ready --brief` output (`{id, title, priority, dependsOn, project}`)
- **next.md**: Per-story project path resolution — when a story has a `project` field, resolves PROJECT_PATH relative to AIMI_ROOT and passes it to the worker agent prompt; loads CLAUDE.md from PROJECT_PATH when set; backwards compatible when project field is absent
- **execute.md**: Per-project worktree grouping for multi-repo execution — wave stories are grouped by `project` field before worktree creation, worktrees are created within each project's git repo, merge-all runs per-project group
- **execute.md**: Per-project branch setup — creates/checks out the feature branch in each unique project's git repo when stories target different repos
- **execute.md**: Per-project guidelines loading — builds `PROJECT_GUIDELINES_MAP` from each project's CLAUDE.md/AGENTS.md
- **execute.md**: Single-story waves pass `PROJECT_PATH` to worker prompt when story has `project` field
- **execute.md**: Post-loop cleanup handles per-project worktree removal
- **plan.md / story-decomposition.md**: Multi-repo project assignment rules — planner auto-scans subfolders for git repos and assigns `project` field to stories targeting specific repositories
- **test-aimi-cli.sh**: Updated `--brief` key count assertion to include project field

## [1.29.0] - 2026-03-06

### Changed

- **cli-path-resolution.md**: Rewrite CLI resolution with three-layer strategy — global cache, zsh-safe glob fallback, per-project fallback — for reliable path discovery across shells and plugin updates
- **cli-path-resolution.md**: Add equivalent WORKTREE_MGR three-layer resolution section
- **cli-path-resolution.md**: Structure resolution as sequential commands (no compound `&&` or `||`) for auto-approve hook compatibility

### Added

- **aimi-cli.sh**: Global cache functions (`_cache_path`, `_read_cache`, `_write_cache`) for persistent CLI and worktree manager path storage across sessions
- **auto-approve-cli.sh**: Auto-approve patterns for three-layer CLI resolution commands (cache read via `cat`, Layer 1 validation, Layer 2 `bash -c` glob fallback, Layer 2 cache write via `printf`/`mv`/`chmod`, Layer 3 per-project fallback)
- **aimi-cli.sh / worktree-manager.sh**: Tests for global cache read/write/invalidation functions

## [1.28.2] - 2026-03-04

### Fixed

- **plan.md**: Add explicit US-NNN ID format step to Phase 3 story decomposition and checklist — LLM now sees the format requirement before generating IDs, not just in reference docs
- **task-planner/SKILL.md**: Add US-NNN ID format step to Phase 3 between dependency assignment and description writing
- **pipeline-phases.md**: Add US-NNN ID format to Phase 3 and Phase 4 metadata derivation
- **story-decomposition.md**: Strengthen ID format with explicit zero-padding language, regex pattern, and negative examples (US-1, story-1, S1, F1)

### Added

- **aimi-cli.sh**: New `validate-ids` command — validates all story IDs in a tasks file match `^US-[0-9]{3}[a-z]?$` regex, returns JSON with valid/count or errors array
- **plan.md**: Phase 4.5 post-generation validation step — runs `validate-ids` and `validate-deps` after writing tasks.json, with fix-and-rewrite loop if validation fails
- **task-planner/SKILL.md**: Matching Phase 4.5 post-generation validation step

## [1.28.1] - 2026-03-03

### Fixed

- **task-format-v3.md**: Enforce specific role in user story descriptions — `[user]` replaced with `[specific role]` with examples (e.g., "store admin", "developer"), preventing generic "As a user" descriptions
- **story-decomposition.md**: Add "Description Format" section with required format, good/bad examples, and 500-char limit
- **task-planner/SKILL.md**: Add description format step to Phase 3 story decomposition and checklist validation
- **plan.md**: Add description format step to Phase 3 story decomposition and checklist validation

## [1.28.0] - 2026-03-03

### Added

- **aimi-cli.sh**: New `_claude_config_dir()` helper that resolves the Claude config directory from `CLAUDE_CONFIG_DIR` env var, falling back to `~/.claude` -- validates the path is absolute when set, and strips trailing slashes
- **aimi-cli.sh**: All hardcoded `~/.claude/plugins/cache/` glob patterns in `cmd_check_version()`, `cmd_cleanup_versions()`, and help text examples now use the resolved config dir variable, enabling custom config directory support
- **test-aimi-cli.sh**: New test cases for `CLAUDE_CONFIG_DIR` support — validates custom config dir resolution, absolute path enforcement, and trailing slash stripping

### Changed

- **auto-approve-cli.sh**: Dynamic config dir resolution using `CONFIG_DIR_RE` alternation — auto-approve patterns now match both `~/.claude` and custom `CLAUDE_CONFIG_DIR` paths
- **cli-path-resolution.md**: Parameterized CLI resolution example to use `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` instead of hardcoded `~/.claude`
- **execute.md**: Parameterized CLI path resolution to support custom config directories via `CLAUDE_CONFIG_DIR`
- **swarm.md**: Parameterized CLI path resolution to support custom config directories via `CLAUDE_CONFIG_DIR`

### Security

- **aimi-cli.sh**: Add `PROJECT_ROOT` export to `find_aimi_root()` — discovers git repository root and exports it for use by other functions
- **aimi-cli.sh**: Add `validate_path_in_project()` function — validates resolved paths are under `PROJECT_ROOT` using realpath comparison, exits with clear error if path escapes project root
- **aimi-cli.sh**: Add path validation to file operation functions (`read_state`, `write_state`, `clear_state_file`, `get_tasks_file`) — prevents directory traversal attacks
- **story-executor/SKILL.md**: Add explicit project-root boundary guardrails — agents must not read or modify files outside the git repository root, worktree paths are explicitly allowed

## [1.27.4] - 2026-03-03

### Fixed

- **execute.md**: Use task branch name as worktree branch prefix instead of hardcoded `aimi-` — worktree branches are now named `[branchName]-[storyId]` (e.g., `feat/feature-name-US-001`) for clearer branch association

## [1.27.3] - 2026-03-03

### Fixed

- **task-format-v3.md**: Add explicit validation rule requiring story `id` fields to match `^US-\d{3}[a-z]?$` format — previously only `dependsOn` references were validated, allowing LLMs to generate invalid IDs like `S1` or `F1` that are rejected by aimi-cli.sh at runtime
- **task-planner/SKILL.md**: Add checklist item enforcing US-NNN format for story IDs in the v3 Schema Validations section

## [1.27.2] - 2026-03-03

### Added

- **react-best-practices skill**: Add AGENTS.md compiled guide with all React and Next.js rules expanded
- **react-native-skills skill**: Add AGENTS.md compiled guide and move rule files into skill's own rules/ directory

### Fixed

- **marketplace.json**: Sync version to match plugin.json

## [1.27.1] - 2026-03-02

### Added

- **react-best-practices skill**: Vercel React and Next.js performance optimization guidelines — 58 rules across 8 categories covering waterfalls, bundle size, server-side performance, and client-side data fetching
- **react-native-skills skill**: React Native and Expo best practices — rules for list performance, animations with Reanimated, UI patterns, image handling, navigation, monorepo configuration, and platform-specific optimizations

## [1.27.0] - 2026-03-02

### Added

- **aimi-cli.sh**: `get-story <id>` command for on-demand story fetching — returns full story JSON for a single story by ID, enabling lazy loading instead of bulk extraction

### Changed

- **execute.md**: Two-phase story loading — wave selection uses `list-ready --brief` (returns `{id, title, priority, dependsOn}` stubs), full story data fetched via `get-story <id>` per story after `mark-in-progress` (claim-then-fetch pattern)
- **execute.md**: Single-story wave path now follows: `list-ready --brief` -> `mark-in-progress` -> `get-story` -> build prompt -> Task
- **execute.md**: Multi-story wave path now follows: `list-ready --brief` -> select -> `mark-in-progress` all -> `get-story` each -> create worktrees -> spawn Tasks
- **execute.md**: Error handling for `get-story` failures: marks story failed, cascade-skips dependents, continues with remaining stories in wave
- **execute.md**: Multi-story wave gracefully degrades — if fetch failures reduce to 1 story, falls back to single-story path (no worktree overhead)

## [1.26.2] - 2026-03-02

### Fixed

- **execute.md**: Added `subagent_type` guard (`IMPORTANT: Do NOT change subagent_type`) to Task spawn ensuring agents never substitute `story-executor` as an agent type
- **next.md**: Added `subagent_type` guard comments to both Task spawn locations (line 86 and retry at line 122), matching the pattern in execute.md — prevents agents from substituting `story-executor` as an agent type

### Added

- **story-executor SKILL.md**: Added Tools section documenting available capabilities (Read, Edit, Write, Bash, Glob, Grep, WebSearch, WebFetch, Task) for agents spawned within story execution

## [1.26.1] - 2026-03-02

### Changed

- **Acceptance criterion limit increased from 300 to 600 chars** across CLI validation, schema docs, skill references, and command checklists (aimi-cli.sh, task-format-v3.md, story-decomposition.md, SKILL.md, plan.md, CLAUDE.md, README.md)

## [1.26.0] - 2026-03-02

### Added

- **aimi-cli.sh**: `--brief` flag on `list-ready` command — outputs a summary line (count + story IDs) instead of full JSON story objects, reducing output for wave orchestration
- **aimi-cli.sh**: `--counts-only` flag on `status` command — returns aggregate counts (`pending`, `in_progress`, `completed`, `failed`, `skipped`, `total`) without the `userStories` array, enabling lightweight progress checks in wave loops
- **aimi-cli.sh**: `status` dispatch updated to `shift; cmd_status "$@"` pattern for flag forwarding

### Changed

- **aimi-cli.sh**: `mark-in-progress`, `mark-completed`, `mark-failed`, `mark-skipped` commands now return minimal `{id, status}` JSON confirmation instead of the full story object, reducing output noise in agent loops

## [1.25.0] - 2026-03-02

### Added

- **aimi-cli.sh**: `find_aimi_root()` auto-discovery — CLI walks up the directory tree from CWD to find `.aimi/`, eliminating silent failures when invoked from subdirectories
- **test-aimi-cli.sh**: Test isolation via `cd "$TEST_DIR"` and `trap` cleanup; new auto-discovery tests (subdirectory + not-found)
- **cli-path-resolution.md**: CWD Auto-Discovery section documenting the new behavior
- **CLAUDE.md**: CWD contract documented in both root and plugin CLAUDE.md files

## [1.24.1] - 2026-03-02

### Added

- **auto-approve-cli.sh**: Docker auto-approve patterns (5–10) for `/aimi:swarm` commands
  - Pattern 5: `docker version` availability check
  - Pattern 6: `docker run --rm` with `--name aimi-swarm-*` and `--label aimi-swarm` (worker containers)
  - Pattern 7: `docker container ls` with `--filter name=aimi-swarm-` (container listing)
  - Pattern 8: `docker rm -f` with validated `aimi-swarm-*` container names (cleanup)
  - Pattern 9: `docker container prune -f --filter label=aimi-swarm` (safety net)
  - Pattern 10: `docker ps --filter name=aimi-*` (status/cleanup checks)
- All Docker patterns enforce aimi- prefix on container names and reject shell metacharacters

## [1.24.0] - 2026-03-02

### Changed

- **swarm.md**: Complete rewrite — replace Docker/ACP/Sysbox architecture with Team orchestration + git worktrees + simplified `docker run --rm` containers
- **swarm.md**: New frontmatter with Team/Docker/Worktree allowed-tools (removed SANDBOX_MGR, BUILD_IMG)
- **swarm.md**: Step 0 resolves only $AIMI_CLI and $WORKTREE_MGR (no SANDBOX_MGR or BUILD_IMG)
- **swarm.md**: Workers run `docker run --rm` with volume-mounted worktrees and `npx claude` inside generic `node:22-slim` image
- **swarm.md**: Team lead reads task file content and passes it in worker prompt (no reliance on task file in worktree)
- **swarm.md**: `status` subcommand reads task files directly (no swarm-state.json)
- **swarm.md**: `cleanup` subcommand removes aimi-* worktrees and Docker containers
- **swarm.md**: Merge conflict handling preserves worktrees for manual inspection

### Removed

- **docker-sandbox skill**: Removed entire skill (sandbox-manager.sh, build-project-image.sh, acp-adapter.py, Dockerfile.base)
- **swarm.md**: All references to Sysbox runtime, ACP protocol, sandbox-manager, build-project-image
- **swarm.md**: swarm-state.json state management (replaced by Team task list)
- **swarm.md**: `resume` subcommand (Team workers are foreground, no detached containers to resume)
- **swarm.md**: State reconciliation subroutine (no persistent container state to reconcile)
- **swarm.md**: Container provisioning with Sysbox-isolated containers
- **swarm.md**: ACP adapter invocation via docker exec/docker cp

## [1.23.2] - 2026-03-02

### Removed

- **auto-approve-cli.sh**: Remove swarm-* entries from CLI subcommand whitelist (swarm-init, swarm-add, swarm-update, swarm-remove, swarm-status, swarm-list, swarm-cleanup)
- **auto-approve-cli.sh**: Remove Pattern 5 (SANDBOX_MGR= assignment) and Pattern 6 ($SANDBOX_MGR invocation)
- **auto-approve-cli.sh**: Remove Pattern 7 (BUILD_IMG= assignment) and Pattern 8 ($BUILD_IMG invocation)
- **auto-approve-cli.sh**: Remove Pattern 9 (docker exec aimi-* for ACP adapter)
- **auto-approve-cli.sh**: Remove Pattern 10 (docker cp for ACP payload files)

## [1.23.1] - 2026-03-02

### Changed

- **commands**: Extract CLI path resolution boilerplate to shared reference at `commands/references/cli-path-resolution.md`
- **execute.md**: Replace Step 0 CLI resolution block with pointer to shared reference
- **status.md**: Replace Step 0 CLI resolution block with pointer to shared reference
- **next.md**: Replace Step 0 CLI resolution block with pointer to shared reference
- **swarm.md**: Replace AIMI CLI resolution block in Step 0 with pointer to shared reference

## [1.23.0] - 2026-03-01

### Added

- **swarm.md**: Subscription auth detection in Step 2.5 — checks for `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR/.credentials.json`)
- **swarm.md**: `CLAUDE_AUTH=subscription` variable set when subscription credentials found
- **swarm.md**: `--mount-claude-config` flag passthrough to `sandbox-manager.sh create` when subscription auth detected
- **swarm.md**: Credential summary now displays `Claude` field showing subscription auth status

### Changed

- **swarm.md**: `ANTHROPIC_API_KEY` check is now a warning (not hard stop) when subscription auth is available
- **swarm.md**: Hard stop message updated to mention both `ANTHROPIC_API_KEY` and Claude config directory options
- **swarm.md**: Resume subcommand container recreation now passes `--mount-claude-config` when subscription auth detected
- **swarm.md**: Resume fan-out re-detection now includes `CLAUDE_AUTH` alongside `AUTH_METHOD`

## [1.22.0] - 2026-03-01

### Added

- **Dockerfile.base**: Pre-populate SSH known_hosts for GitHub, GitLab, and Bitbucket during image build
- **sandbox-manager.sh**: New `--ssh-agent` flag to forward host SSH_AUTH_SOCK into containers
- **acp-adapter.py**: SSH clone support with protocol detection (git@/ssh:// vs https://)
- **swarm.md**: Credential auto-detection step (Step 2.5) — detects ANTHROPIC_API_KEY, GITHUB_TOKEN via env/gh-cli/SSH agent
- **swarm.md**: Git remote fallback chain — tries origin, upstream, then first available remote
- **swarm.md**: AUTH_METHOD-to-protocol mismatch warnings (SSH auth with HTTPS remote, and vice versa)
- **swarm.md**: `--ssh-agent` flag passthrough in container provisioning when SSH auth detected
- **swarm.md**: Container creation command logging for debugging
- **swarm.md**: Resume subcommand now uses the same fallback chain and credential detection

### Fixed

- **swarm.md**: No longer hard-fails when `origin` remote is missing — falls back to other remotes
- **swarm.md**: Resume subcommand no longer hard-codes `git remote get-url origin`
- **acp-adapter.py**: SSH URLs no longer attempt HTTPS credential helper setup

## [1.21.0] - 2026-03-01

### Changed

- **README.md**: Added Skills section documenting all 17 skills (4 core, 6 development/style, 4 tooling/automation, 3 disabled/reference)
- **README.md**: Added Agents section documenting all 28 agents with descriptions per category
- **README.md**: Updated Components table from 4 skills to 17 skills
- **README.md**: Updated Table of Contents with Skills and Agents links
- **orchestrating-swarms SKILL.md**: Replaced all `compound-engineering:*` agent type references with `aimi-engineering:*` equivalents
- **orchestrating-swarms SKILL.md**: Updated agent lists to match actual aimi-engineering agents (removed non-existent `git-history-analyzer`, `repo-research-analyst`)

### Fixed

- **README.md**: Fixed stale `/aimi:plan-to-tasks` reference in troubleshooting → `/aimi:plan`
- **README.md**: Fixed "Check both plugins" → "Check plugin" in installation verification

### Removed

- **orchestrating-swarms SKILL.md**: All `compound-engineering` references eliminated — zero remaining in active plugin code

## [1.20.0] - 2026-03-01

### Changed

- **`check-version` CLI subcommand**: `_extract_version_from_path()` now uses bash parameter expansion (`${path%/*}`, `${no_scripts##*/}`) instead of `dirname`/`basename` forks — eliminates 3 subshell spawns per call
- **`check-version` CLI subcommand**: `current` status path uses `printf` instead of `jq -n` for JSON output — eliminates 1 jq fork on the happy path
- **`check-version` `--quiet` flag**: Suppresses all stderr warnings (e.g., stale/missing cli-path) for clean machine-readable output
- **`check-version` `--fix` flag**: Auto-updates `cli-path` via `write_state` on stale detection and outputs `{"status":"fixed",...}` with exit 0 instead of `{"status":"stale",...}` with exit 1
- **`check-version` dispatch table**: Now passes `"$@"` to `cmd_check_version` for flag forwarding
- **Command version-check blocks**: Consolidated multi-line `check-version` + jq parsing + `init-session` re-stamp in `execute.md`, `status.md`, `next.md`, and `swarm.md` into single `$AIMI_CLI check-version --quiet --fix` call — eliminates `2>/dev/null`, `VERSION_CHECK`, `VERSION_EXIT`, `STORED_VER`, `LATEST_VER` variables and jq dependency from version-check sections

### Added

- **`check-version` `--quiet` and `--fix` tests**: Tests for `--quiet` flag (suppressed stderr), `--fix` flag (auto-update on stale), combined `--quiet --fix` flags, and backward compatibility (no-flags behavior unchanged)

### Fixed

- **CHANGELOG.md**: Removed redundant `[1.18.1]` entry that duplicated content from `[1.18.0]`
- **auto-approve-cli.sh path traversal regex**: Version segments in plugin path now require digit-first pattern (`[0-9][0-9.]*`) — prevents crafted directory names from bypassing path validation

### Security

- **auto-approve-cli.sh `has_metacharacters()`**: Added `[<>]` character class to the first grep pattern — now blocks `>`, `>>`, `<`, `<<` redirection operators in addition to existing `;`, `&&`, `||`, backtick, and `$()` patterns

## [1.19.0] - 2026-03-01

### Added

- **`check-version` CLI subcommand**: Compares running plugin version against installed version on disk — returns JSON `{running, installed, match}` result; warns user on mismatch and triggers `init-session` to refresh `cli-path`
- **`cleanup-versions` CLI subcommand**: Finds and removes stale plugin versions from `~/.claude/plugins/cache/` — keeps only the latest installed version, returns JSON `{kept, removed: [paths]}` result
- **Step 0 version check integration**: All four execution commands (`execute.md`, `status.md`, `next.md`, `swarm.md`) now call `$AIMI_CLI check-version` after glob resolution — warns user on version mismatch and auto-updates `cli-path` via `init-session`; does NOT call `cleanup-versions` (cleanup is manual-only)
- **auto-approve-cli.sh whitelist**: Added `check-version` and `cleanup-versions` to the permitted subcommand list for auto-approval during task execution
- **test-aimi-cli.sh**: New tests covering `check-version` (match and mismatch scenarios) and `cleanup-versions` (no stale versions, stale version removal)

## [1.18.0] - 2026-03-01

### Added

- **Dockerfile.base**: COPY `acp-adapter.py` into base image at `/opt/aimi/acp-adapter.py` — containers now have the ACP adapter available for `docker exec` invocation
- **acp-adapter.py `provision_repo()`**: Repository cloning and branch checkout inside containers — clones `repoUrl`, configures GITHUB_TOKEN credential helper, checks out target branch (with fallback for new branches), verifies task file exists
- **acp-adapter.py `--input` flag**: File-based alternative to stdin for receiving task-request payloads — enables auto-approve-compatible `docker cp` + `docker exec --input` pattern
- **acp-adapter.py env var value sanitization**: `validate_env_var_value()` rejects values containing newlines, null bytes, or shell metacharacters (`;`, `&&`, `||`, backticks, `$(`)
- **acp-adapter.py progress throttling**: Progress emissions throttled to at most once every 2 seconds (time-based), reducing NDJSON volume by 90%+ with final line always emitted
- **acp-adapter.py concurrent stderr drain**: `threading.Thread` drains stderr concurrently while streaming stdout, preventing 64KB pipe buffer deadlock
- **sandbox-manager.sh `--container-id` and `--swarm-id`**: Optional flags for `cmd_create` to pass identity env vars into containers for ACP message envelopes
- **sandbox-manager.sh advisory disk limit**: Attempts `--storage-opt size=` and falls back gracefully with warning if storage driver doesn't support it
- **swarm.md non-interactive flags**: `--all`, `--files`, `--force`, `--append` flags skip AskUserQuestion prompts for fully autonomous agent-to-agent orchestration
- **auto-approve-cli.sh Pattern 9/10**: `docker exec` with optional `--input` flag and `docker cp` for ACP payload delivery — restricted to `aimi-` prefixed containers
- **SKILL.md total resource table**: Shows CPU, RAM, and swap consumption at 2, 4, and 8 containers with host sizing guidance (2x container RAM recommended)

### Fixed

- **auto-approve-cli.sh path regex**: Changed `skills/sandbox/` to `skills/docker-sandbox/` in `SANDBOX_MGR` and `BUILD_IMG` patterns to match actual plugin directory structure
- **sandbox-manager.sh swap default**: Changed `AIMI_SANDBOX_SWAP` from `4g` to `8g` — Docker's `--memory-swap` is total (memory + swap), so `4g` with `4g` memory meant zero actual swap
- **sandbox-manager.sh consolidated inspect**: Replaced 5 separate `docker inspect` calls in `cmd_status` with a single call using combined Go template format string
- **aimi-cli.sh swarm-cleanup**: Updated jq filter to also exclude `stopped` status (was only excluding `completed` and `failed`)
- **aimi-cli.sh `_validate_container_name`**: Harmonized with `sandbox-manager.sh` — now requires `aimi-` prefix and same character set (`^aimi-[a-zA-Z0-9][a-zA-Z0-9_-]*$`)
- **swarm.md Step 5 ACP invocation**: Changed from piped `echo | docker exec -i` to file-based `docker cp` + `docker exec --input` pattern — works with auto-approve hooks

## [1.17.1] - 2026-03-01

### Fixed

- **auto-approve-cli.sh**: Fixed `SANDBOX_MGR` and `BUILD_IMG` path validation regex patterns — changed `skills/sandbox/` to `skills/docker-sandbox/` to match actual plugin directory structure and the glob patterns used in swarm.md Step 0

## [1.17.0] - 2026-03-01

### Changed

- **`/aimi:swarm` status subcommand**: Now runs automatic state reconciliation before displaying status table — detects zombie entries (containers in state but missing from Docker), silent completions, silent failures, unexpected stops, and already-started containers
- **`/aimi:swarm` resume subcommand**: Enhanced with full crash recovery — reconciles state first, identifies resumable containers, recreates failed containers for retry, skips running/completed containers, fans out only pending containers
- **`/aimi:swarm` cleanup subcommand**: Enhanced with per-container removal reporting (removed vs already gone), proper state entry cleanup count, and graceful handling of missing swarms

### Added

- **State reconciliation subroutine** in swarm.md: Shared procedure that runs before `status` display and `resume` operations, comparing `swarm-state.json` entries against actual Docker daemon state via `sandbox-manager.sh status`
- **Zombie detection documentation**: New "State Reconciliation" reference section documenting detection scenarios (zombie, silent completion/failure, unexpected stop, already started), zombie causes, and idempotency guarantees

### Security

- **auto-approve-cli.sh**: Added `SANDBOX_MGR` patterns with path validation and subcommand whitelist (create, remove, list, status, cleanup, check-runtime)
- **auto-approve-cli.sh**: Added `BUILD_IMG` patterns with path validation for build-project-image.sh invocation
- **auto-approve-cli.sh**: Added swarm subcommands to `$AIMI_CLI` whitelist (swarm-init, swarm-add, swarm-update, swarm-remove, swarm-status, swarm-list, swarm-cleanup)
- **auto-approve-cli.sh**: Added `docker exec -i aimi-*` pattern for ACP adapter communication — restricted to `aimi-` prefixed containers running `python3 /opt/aimi/acp-adapter.py` only (no wildcard Docker approvals)

## [1.16.0] - 2026-03-01

### Added

- **`/aimi:swarm` command**: Multi-task Docker sandbox orchestration for parallel feature execution
  - Discovers `.aimi/tasks/*-tasks.json` files, presents multi-select list to user
  - Supports `--file <path>` flag for single-file execution
  - Provisions Sysbox-isolated Docker containers via `sandbox-manager.sh` for each task file
  - Builds per-project images via `build-project-image.sh` with checksum-based rebuild skipping
  - Fans out parallel Task agents, each communicating with its container via ACP adapter (`docker exec -i`)
  - Tracks execution via `swarm-state.json` using CLI swarm-* subcommands
  - Configurable `maxContainers` limit (default 4, override with `--max <N>`)
  - Subcommands: `status` (view swarm state), `resume` (restart pending containers), `cleanup` (remove containers and state)
  - Handles partial failure: failed containers marked in state, successful ones continue independently
  - Reports summary with per-container status, branch names, and PR URLs

## [1.15.0] - 2026-03-01

### Changed

- **execute.md parallel execution rewrite**: Replaced Team/SendMessage swarm orchestration with foreground fan-out using `run_in_background` Task agents — eliminates Team lifecycle complexity, reduces token overhead, and runs parallel workers directly from the orchestrator's context
- **execute.md Team/SendMessage dependency removed**: Parallel story execution no longer requires TeamCreate, SendMessage, or teammate coordination — workers are spawned as background tasks and polled for completion

### Fixed

- **worktree-manager.sh merge stderr suppression**: Removed `2>/dev/null` from `git checkout` and `git merge` commands in `merge_worktree()` and `merge_all_worktrees()` functions — merge conflicts and failures are now visible in stderr for proper diagnosis

## [1.14.0] - 2026-02-28

### Changed

- **aimi-cli.sh portable `_lock()` function**: Replaces direct `flock` calls with cross-platform locking — Linux uses `flock`, macOS uses atomic `mkdir` spinlock with 10s stale-lock timeout and `trap EXIT` cleanup
- **aimi-cli.sh platform detection at startup**: Caches `_HAS_FLOCK` and `_HAS_REALPATH` to avoid per-call `command -v` overhead
- **aimi-cli.sh `cmd_clear_state`**: Also removes `*.lock.d` directories (mkdir-based lock cleanup)
- **execute.md CLI resolution**: Glob first (always finds latest version), cli-path as fallback only — prevents stale cached path from using old plugin version
- **status.md + next.md CLI resolution**: Consistent with execute.md — glob first, cli-path fallback (was glob-only, no fallback)

## [1.13.0] - 2026-02-27

### Added

- **aimi-cli.sh `resolve_path()` helper**: POSIX-compatible path resolution (uses `realpath` when available, falls back to `cd`+`pwd`+`basename` for macOS)
- **aimi-cli.sh `reset-orphaned` subcommand**: Atomically marks all `in_progress` stories as `failed`, returns `{count, reset: [ids]}` — replaces fragile `status | jq` pipeline
- **aimi-cli.sh `validate_story_exists()` function**: Verifies story ID exists in tasks file before mutation; all `mark-*` and `cascade-skip` commands now exit 1 with clear error for non-existent IDs
- **aimi-cli.sh `cli-path` state file**: `init-session` writes CLI's absolute path to `.aimi/cli-path` for reliable resolution across shell sessions
- **aimi-cli.sh stale state warning**: `get_tasks_file()` prints stderr warning when `current-tasks` points to a deleted file, auto-updates state with discovered alternative
- **test-aimi-cli.sh**: 16 new tests (65 total) covering: resolve_path, cli-path, userStories key, story ID existence validation, reset-orphaned (empty + with orphans), stale state warning
- **test-aimi-cli.sh `assert_stderr_contains` helper**: New test helper for validating stderr output

### Changed

- **aimi-cli.sh `cmd_status` output**: Renamed `.stories` key to `.userStories` for consistency with schema v3.0 source field name
- **aimi-cli.sh state files**: `init-session` and `get_tasks_file()` now store absolute paths in `.aimi/current-tasks` (resolves cwd-dependency bugs)
- **aimi-cli.sh `write_state()` and `clear_state_file()`**: Now use `flock` with `$AIMI_DIR/.state.lock` for parallel execution safety
- **aimi-cli.sh `cmd_clear_state`**: Also removes `.state.lock`, `cli-path`, and all `.lock` files under `.aimi/`
- **execute.md Step 0**: CLI resolution now tries `cat .aimi/cli-path` first, falls back to `ls` glob if missing or invalid
- **execute.md orphaned recovery**: Replaced `status | jq` pipeline with `$AIMI_CLI reset-orphaned` subcommand
- **status.md**: Updated example output to use `userStories` key
- **auto-approve-cli.sh**: Added `reset-orphaned` to subcommand whitelist

## [1.12.0] - 2026-02-27

### Added

- **worktree-manager.sh `remove` command**: New `remove <worktree-name>` subcommand for non-interactive worktree cleanup (`git worktree remove --force` + `git branch -D`)
- **worktree-manager.sh `--from` flag**: `create` now supports `create name --from branch` (and positional backward compat)
- **worktree-manager.sh input validation**: `validate_branch_name()` with regex `^[a-zA-Z0-9][a-zA-Z0-9/_.-]*$`, path containment check via `realpath -m`
- **aimi-cli.sh flock-based file locking**: All 5 mutation functions use `flock -x` advisory locking with unique `mktemp` temp files
- **aimi-cli.sh `validate_story_id()`**: Regex `^US-[0-9]{3}[a-z]?$` validated on all mark-* commands
- **aimi-cli.sh `validate-stories` command**: Checks field lengths (title: 200, description: 500, criterion: 300) and suspicious content patterns for prompt injection defense
- **aimi-cli.sh `maxConcurrency` guard**: Values <= 0 default to 4 in status and metadata commands
- **execute.md orphaned recovery**: Step 1 detects stories stuck in `in_progress` from interrupted runs, resets to `failed`
- **execute.md content validation**: Step 1 calls `validate-stories` before any execution
- **execute.md agent-driven merge conflict resolution**: On merge conflict, spawns a Task agent to attempt resolution before falling back to manual
- **execute.md worker timeout**: Configurable timeout (default 15 min); non-responding workers marked as failed

### Changed

- **worktree-manager.sh**: Removed all interactive `read -r` prompts — create reuses existing worktrees silently, cleanup proceeds without confirmation
- **worktree-manager.sh**: Removed unnecessary `git checkout`/`git pull` from create (worktree add works without checkout)
- **worktree-manager.sh**: `chmod 600` applied to all copied .env files; git commands use `--` separator before branch arguments
- **story-executor SKILL.md**: Fixed contradiction (agents report results, callers handle status via CLI), removed duplicated sections (compact prompt, JS examples, default rules), added `story.notes` placeholder, declared as canonical prompt template
- **execute.md**: Moved `validate-deps` from parallel-only path to shared Step 3.1 — both sequential and parallel validate dependency graph
- **execute.md**: Worker prompt includes `## PREVIOUS NOTES` section with `story.notes` (omitted when empty)
- **execute.md + next.md**: Replaced duplicated inline worker prompts with references to story-executor SKILL.md canonical template (net -96 lines)
- **execute.md + next.md**: Replaced duplicated guideline loading sections with references to story-executor discovery order

### Security

- **auto-approve-cli.sh**: Replaced permissive `$AIMI_CLI` pattern with explicit subcommand whitelist (19 commands) and shell metacharacter rejection
- **auto-approve-cli.sh**: `AIMI_CLI=` assignment now validates path matches expected plugin install directory
- **auto-approve-cli.sh**: Added `WORKTREE_MGR` patterns with path validation and subcommand whitelist (create, remove, merge, list, help)

## [1.11.0] - 2026-02-27

### Removed

- **v2.2 backward compatibility**: All v2.2 schema support removed — v3.0 is now the only supported format
- **plan-to-tasks skill**: Deleted entire `skills/plan-to-tasks/` directory (v2.2-only task generator)
- **detect-schema CLI command**: Removed `detect-schema` command and all dual-schema detection logic from aimi-cli.sh
- **v2.2 code paths in CLI**: Removed `detect_schema()`, `is_v3()`, `cmd_detect_schema()` functions and all if/else version branching
- **v2.2 test fixtures**: Rewrote test suite to v3-only (49 tests, all passing)
- **v2.2 references in docs**: Cleaned all v2.2 mentions from commands (deepen, next, status, execute), execution-rules, task-format-v3, story-decomposition, and CLAUDE.md files

## [1.10.0] - 2026-02-27

### Fixed

- **Plugin CLAUDE.md**: Updated schema example from v2.1 to v3 (status, dependsOn, maxConcurrency)
- **story-executor**: Removed direct tasks file mutation instructions — agents now delegate to CLI for all status updates
- **execution-rules.md**: Updated with v3 status enum and dual-schema documentation
- **deepen.md**: Made schema-aware — detects v3 status field instead of v2.2 passes boolean
- **next.md**: Updated CLI output example with both v3 and v2.2 variants
- **pipeline-phases.md**: Fixed output report from "Schema: 2.2" to "Schema: 3.0"
- **story-decomposition.md**: Fixed conversion rule from `passes: false` to `status: "pending"`

### Changed

- **aimi-cli.sh**: Removed dead code (abandoned jq blocks, duplicated ready-story logic); DRYed cmd_next_story to reuse cmd_list_ready
- **plan-to-tasks**: Added deprecation notice (generates v2.2 only; use task-planner for v3)

### Added

- **test-aimi-cli.sh**: 31 new v3 test cases covering detect-schema, list-ready, mark-in-progress, validate-deps, cascade-skip, dependency resolution, and circular dependency detection (65 total tests)

## [1.9.0] - 2026-02-27

### Added

- **Schema v3 (`task-format-v3.md`)**: New tasks.json schema with dependency graph and parallel execution support
  - `dependsOn` (string[]) for explicit inter-story dependency graphs (DAG)
  - `status` enum (`pending`, `in_progress`, `completed`, `failed`, `skipped`) replacing `passes` boolean
  - `maxConcurrency` metadata field (default 4) for parallel story execution
  - `priority` retained as tiebreaker for stories at same dependency depth
  - Status state machine with valid transitions documented
  - `dependsOn` validation rules: no circular deps, no self-refs, all referenced IDs must exist
  - Backward compatibility with v2.2: auto-detection and fallback behavior
  - Migration guide: v2.2 to v3 conversion rules with priority-layer inference for `dependsOn`

- **Parallel execution in `/aimi:execute`**: Automatic detection and execution of independent stories in parallel
  - Wave-based execution: independent stories run concurrently within waves
  - Team/swarm orchestration for parallel workers using Claude Code Teams
  - Adaptive concurrency: `min(ready stories, maxConcurrency)`
  - Cascade-skip on failure: dependent stories automatically skipped when a dependency fails
  - v2.2 fallback: sequential execution preserved for older schema files
  - v3 with linear deps: runs sequentially without Team/worktree overhead

- **Worktree merge commands** in `worktree-manager.sh`
  - `merge <worktree-name> [--into <branch>]` — merge worktree branch into target
  - `merge-all <branch1> <branch2> ... [--into <branch>]` — sequential multi-merge
  - Merge conflict detection with conflicting file listing
  - Stop-on-conflict behavior for merge-all

- **CLI extensions** for v3 schema support in `aimi-cli.sh`
  - `detect-schema` — returns schema version (`2.2` or `3.0`)
  - `list-ready` — dependency-aware ready story detection (v3)
  - `mark-in-progress` — sets `status: "in_progress"` for a story (v3)
  - `validate-deps` — DAG validation for dependency graph (cycles, missing refs, self-refs)
  - `cascade-skip` — transitive skip on failure for dependent stories

### Changed

- **`/aimi:execute` command**: Rewritten for smart parallel/sequential execution based on schema version and dependency graph shape
- **`story-decomposition.md`**: Updated with `dependsOn` generation rules, layer-based inference, and parallel grouping examples
- **`task-planner` SKILL.md**: Phase 3 and Phase 4 updated for v3 output with `dependsOn` arrays and `status` field
- **`plan.md` command**: Output format updated to v3 schema with `dependsOn` and `status` fields
- **`story-executor` skill**: Added optional `WORKTREE_PATH` variable for parallel worker context; workers report status instead of writing tasks.json directly
- **`/aimi:status` command**: v3 display with status values, dependency info, and wave grouping; v2.2 display unchanged
- **CLI dual-version support**: `mark-complete`, `mark-failed`, `mark-skipped`, `count-pending`, `next-story` all updated for v2.2/v3 compatibility

## [1.8.0] - 2026-02-27

### Added

- **`brainstorm` skill**: Standalone process knowledge for brainstorming sessions
  - `skills/brainstorm/SKILL.md` (229 lines) — hybrid question flow, Ralph-style batched multiple-choice, adaptive exit, YAGNI, design document template
  - `skills/brainstorm/references/question-patterns.md` (240 lines) — formatting rules, scenario batches, response parsing, contextual question generation

### Changed

- **`/aimi:brainstorm` command**: Full rewrite as standalone (no longer wraps compound-engineering)
  - Phase 0: Assess requirements clarity
  - Phase 1: Codebase research via `aimi-codebase-researcher` agent
  - Phase 2: Batched 3-5 multiple-choice questions with "1A, 2C, 3B" shorthand
  - Phase 3: Conditional approaches (only when multiple valid paths exist)
  - Phase 4: Design document capture with slug derivation, collision handling, open questions enforcement
  - Phase 5: Aimi-branded handoff
- **compound-engineering dependency fully eliminated**: All commands and skills are now standalone. Zero external plugin dependencies required.
- **CLAUDE.md**: Dependencies section updated to reflect full independence
- **`aimi-code-simplicity-reviewer` agent**: Updated pipeline artifacts reference
- **`aimi-best-practices-researcher` agent**: Removed `compound-docs` from skill mapping

## [1.7.0] - 2026-02-26

### Added

- **PermissionRequest hook**: Auto-approves `$AIMI_CLI` and `AIMI_CLI=` Bash commands during task execution, eliminating manual permission prompts for CLI operations
  - `hooks/hooks.json` — hook configuration
  - `hooks/auto-approve-cli.sh` — approval script matching only AIMI CLI patterns

## [1.6.0] - 2026-02-25

### Changed

- **Output directory**: All document output paths moved from `docs/` to `.aimi/`
  - `docs/tasks/` → `.aimi/tasks/`
  - `docs/brainstorms/` → `.aimi/brainstorms/`
  - `docs/plans/` → `.aimi/plans/`
  - `docs/solutions/` → `.aimi/solutions/`
- **`aimi-cli.sh`**: `TASKS_DIR` now derived from `$AIMI_DIR` variable (`$AIMI_DIR/tasks`)
- All commands, skills, and agents updated with new paths

## [1.5.2] - 2026-02-25

### Changed

- **`/aimi:plan` command**: Inlined full task-planner pipeline directly into plan.md to fix double skill loading issue (both `plan` command and `task-planner` skill were loading into context)
- **`task-planner` skill**: Set to `user-invocable: false` since pipeline is now embedded in `/aimi:plan`

## [1.5.1] - 2026-02-25

### Added

- **Context7 MCP server**: Registered `context7` HTTP MCP server directly in plugin.json so `aimi-best-practices-researcher` and `aimi-framework-docs-researcher` can access documentation without compound-engineering installed

## [1.5.0] - 2026-02-25

### Added

- **28 aimi-native agents**: Standalone agents that eliminate compound-engineering dependency for plan, review, and deepen workflows
  - 4 research agents: `aimi-codebase-researcher`, `aimi-learnings-researcher`, `aimi-best-practices-researcher`, `aimi-framework-docs-researcher`
  - 15 review agents: `aimi-architecture-strategist`, `aimi-security-sentinel`, `aimi-code-simplicity-reviewer`, `aimi-performance-oracle`, `aimi-agent-native-reviewer`, `aimi-data-integrity-guardian`, `aimi-data-migration-expert`, `aimi-deployment-verification-agent`, `aimi-schema-drift-detector`, `aimi-pattern-recognition-specialist`, `aimi-dhh-rails-reviewer`, `aimi-kieran-rails-reviewer`, `aimi-kieran-typescript-reviewer`, `aimi-kieran-python-reviewer`, `aimi-julik-frontend-races-reviewer`
  - 3 design agents: `aimi-design-implementation-reviewer`, `aimi-design-iterator`, `aimi-figma-design-sync`
  - 1 docs agent: `aimi-ankane-readme-writer`
  - 5 workflow agents: `aimi-spec-flow-analyzer`, `aimi-bug-reproduction-validator`, `aimi-every-style-editor`, `aimi-lint`, `aimi-pr-comment-resolver`

### Changed

- **`task-planner` skill**: All agent references updated from `compound-engineering:*` to `aimi-engineering:*`
- **`/aimi:deepen` command**: Now uses `aimi-engineering:research:aimi-codebase-researcher` instead of compound agent
- **`/aimi:review` command**: Fully rewritten as standalone multi-agent review command. No longer wraps `/workflows:review`. Invokes parallel aimi-native review agents with default agents (architecture, security, simplicity, performance, agent-native), conditional migration agents, language-specific reviewers, and findings synthesis with severity categorization.
- **Reduced compound-engineering dependency**: Only `/aimi:brainstorm` still requires compound-engineering. Plan, deepen, and review are now fully standalone.

## [1.4.0] - 2026-02-25

### Added

- **`task-planner` skill**: New skill that generates `tasks.json` directly from a feature description. Full pipeline: brainstorm detection, local/external research (parallel), spec-flow analysis, story decomposition, and direct JSON output — no intermediate markdown plan.
  - `skills/task-planner/SKILL.md` (160 lines) — orchestration overview and agent invocation syntax
  - `skills/task-planner/references/pipeline-phases.md` — detailed phase-by-phase instructions
  - `skills/task-planner/references/story-decomposition.md` — sizing, ordering, validation rules

### Changed

- **`/aimi:plan` command**: No longer wraps compound-engineering `/workflows:plan`. Now invokes the `task-planner` skill directly, producing `tasks.json` without an intermediate plan markdown file.
- **`/aimi:deepen` command**: No longer wraps compound-engineering `/deepen-plan`. Now enriches `tasks.json` directly — spawns research agents per pending story, improves acceptance criteria, splits oversized stories, preserves completed story state. Accepts optional path argument; auto-discovers most recent tasks.json if omitted.
- **Schema version**: Bumped from 2.1 to 2.2
  - `metadata.planPath` is now optional/nullable (`null` when generated by task-planner)
  - `metadata.brainstormPath` documented as optional context reference
  - Backward compatible with v2.1 — existing files work without modification
- **`plan-to-tasks` skill**: Updated to output schema v2.2. Added note directing users to `task-planner` for direct generation. Remains functional as standalone converter for external markdown plans.

## [1.3.1] - 2026-02-25

### Fixed

- **`/aimi:plan` not loading `plan-to-tasks` skill**: Step 4 used ambiguous pseudo-syntax (`Skill: plan-to-tasks`) inside a code block, which Claude interpreted as descriptive text instead of an actionable tool invocation
  - Replaced with explicit instructions to call the Skill tool with `skill: "aimi-engineering:plan-to-tasks"`
  - Added "Do NOT generate tasks.json from memory or inline" guardrail
  - Added fallback: read `SKILL.md` directly if Skill tool is unavailable
  - Updated Step 5 to clarify the skill handles output writing

## [1.3.0] - 2026-02-24

### Fixed

- **CLI script path resolution**: Commands now resolve `aimi-cli.sh` from plugin install directory (`~/.claude/plugins/cache/*/aimi-engineering/*/scripts/`) instead of using `./scripts/` relative path which fails when cwd is the user's project
  - Updated `execute.md`, `next.md`, `status.md` with Step 0: Resolve CLI Path
  - Added `$AIMI_CLI` variable pattern (matches compound-engineering's plugin path convention)
  - Updated `allowed-tools` frontmatter to permit `$AIMI_CLI` execution
  - Updated README architecture section and CLI help examples

## [1.2.2] - 2026-02-24

### Fixed

- **Schema structure divergences** across 7 files:
  - `commands/plan.md`: Schema version output said "2.0" instead of "2.1"
  - `README.md`: jq example referenced non-existent top-level `project`/`branchName` fields (now uses `metadata.*`)
  - `README.md`: Removed stale `steps`/`taskType` from field length limits table (fields removed in v2.1)
  - `README.md`: Updated intro text (removed references to removed `steps`/`qualityChecks` fields)
  - `README.md`: Added missing Root Fields table, moved `schemaVersion` out of Metadata table
  - `README.md`: Added missing `brainstormPath` to Metadata Fields table
  - Root `CLAUDE.md`: Replaced obsolete pre-v2.0 schema (missing `schemaVersion`, `metadata` wrapper) with current v2.1 structure
  - `marketplace.json`: Synced version from "0.2.0" to "1.2.2" (matching plugin.json)

## [1.2.1] - 2026-02-24

### Changed

- **Schema version bump**: `schemaVersion` updated from "2.0" to "2.1" across all files
  - README.md, CLAUDE.md, SKILL.md, task-format.md, test-aimi-cli.sh

## [1.2.0] - 2026-02-24

### Added

- **aimi-cli.sh**: Single bash script for deterministic task file operations
  - 13 subcommands: `init-session`, `find-tasks`, `status`, `metadata`, `next-story`, `current-story`, `mark-complete`, `mark-failed`, `mark-skipped`, `count-pending`, `get-branch`, `get-state`, `clear-state`
  - State management via `.aimi/` directory (persists across `/clear`)
  - Atomic file updates using temp file + mv pattern
  - Comprehensive test suite (33 tests)
- **Story-by-story execution**: Execute one story at a time with `/clear` between stories
- `.gitignore` entry for `.aimi/` state directory

### Changed

- **Commands updated to use CLI instead of inline jq**:
  - `/aimi:execute` - Uses `init-session`, `count-pending`, `get-state`
  - `/aimi:next` - Uses `next-story`, `mark-complete`, `mark-failed`, `mark-skipped`
  - `/aimi:status` - Uses `status` command
- Simplified command files (less error-prone, no jq interpretation by AI)

### Fixed

- AI hallucination when interpreting bash commands embedded in markdown
  - Variable substitution errors
  - Command sequence errors
  - jq query modifications
  - Path/filename errors

## [2.0.0] - 2026-02-17

### Changed

- **BREAKING:** Restored v2.0 schema with task-specific fields
  - Re-added `taskType`, `steps`, `relevantFiles`, `qualityChecks` to story schema
  - `schemaVersion` changed from "3.0" to "2.0"
  - Improved agent execution with domain-specific guidance
  - All story `steps` start with "Read CLAUDE.md and AGENTS.md for project conventions"

### Added

- Automated taskType detection via keyword matching (7 types)
  - `prisma_schema` - Database schema/migration changes
  - `server_action` - Server-side logic and actions
  - `react_component` - React/UI component work
  - `api_route` - API endpoint implementation
  - `utility` - Helper functions and services
  - `test` - Test implementation
  - `other` - Fallback for unclassified tasks
- Predefined step templates for each taskType
- `relevantFiles` inference from story content + taskType defaults
- `qualityChecks` assignment based on taskType
- New placeholders in prompt template: `[TASK_TYPE]`, `[STEPS_ENUMERATED]`, `[RELEVANT_FILES_BULLETED]`, `[QUALITY_CHECKS_BULLETED]`

### Removed

- v3.0 schema (minimal field set without task-specific guidance)

### Migration

Existing v3.0 tasks.json files must be regenerated:

```bash
/aimi:plan [feature]
```

## [1.0.0] - 2026-02-16

### Changed

- **BREAKING:** New tasks.json schema v3.0 with Ralph-style flat stories
  - Flat story structure (no nested `tasks[]` array)
  - Story IDs changed from `story-0` to `US-001` format
  - Added `priority` field for explicit execution order
  - Simple `passes: true/false` state tracking (no per-task status)
  - Per-story `acceptanceCriteria` array (moved from root level)
  - Required "Typecheck passes" in every story's acceptance criteria
  - `successMetrics` at root level for tracking improvements

### Added

- **Priority-based execution**: `/aimi:next` uses jq `sort_by(.priority)` to select next story
- **Project guidelines loading**: CLAUDE.md/AGENTS.md loaded before implementation
- **Aimi default rules**: Fallback commit format and quality checks when no project guidelines exist
- Brainstorm document: `docs/brainstorms/2026-02-16-ralph-style-tasks-brainstorm.md`

### Updated

- `plan-to-tasks` skill updated for flat story conversion
- `task-format.md` reference rewritten for v3.0 schema
- `story-executor` skill simplified for flat structure
- `execution-rules.md` updated with "Read Project Guidelines" as Step 1
- `/aimi:next` loads guidelines before building Task prompt
- `/aimi:execute` derives branch name from metadata title
- `/aimi:status` shows priority in story list

### Removed

- Nested `tasks[]` array structure
- `estimatedEffort` field (agent determines pace from story scope)
- `taskType`, `steps`, `relevantFiles`, `patternsToFollow` fields
- Root-level `acceptanceCriteria` (now per-story)
- `deploymentOrder` field

### Migration

Existing tasks.json files need to be regenerated:

```bash
/aimi:plan-to-tasks docs/plans/your-plan.md
```

## [0.9.0] - 2026-02-16

### Changed

- **BREAKING:** New tasks.json schema v2.0 with nested tasks structure
  - Stories contain nested `tasks[]` array with task objects
  - Added `metadata` object with `title`, `type`, `createdAt`, `planPath`, `brainstormPath`
  - Added `successMetrics` object for tracking improvements
  - Tasks have `id`, `title`, `description`, `file`, `action`, `status` fields
  - Added `estimatedEffort` field to stories

### Updated

- `plan-to-tasks` skill updated for new schema structure
- `task-format.md` reference rewritten for v2.0 schema
- `story-executor` skill updated to work with nested tasks
- `execution-rules.md` updated for task-based execution flow

### Removed

- Old schema fields: `taskType`, `steps`, `relevantFiles`, `patternsToFollow`, `qualityChecks` (per-story)

## [0.8.0] - 2026-02-16

### Fixed

- **Aimi-Branded Messaging**: All commands now show only Aimi commands in next steps
  - Commands still execute compound-engineering workflows under the hood
  - Post-completion options are intercepted and replaced with Aimi equivalents
  - Command mapping: `/workflows:plan` → `/aimi:plan`, `/deepen-plan` → `/aimi:deepen`, etc.

### Changed

- `/aimi:brainstorm` - Added Step 2 with Aimi-branded next steps override
- `/aimi:plan` - Added Step 6 with Aimi-branded report override
- `/aimi:deepen` - Added Step 6 with Aimi-branded report override
- `/aimi:review` - Added Step 2 with Aimi-branded summary override
- All commands include "NEVER mention" guidance to prevent compound-engineering leakage

## [0.7.0] - 2026-02-16

### Added

- **Project Guidelines Injection**: CLAUDE.md/AGENTS.md content injected into Task prompts
  - Discovery order: CLAUDE.md (root) → AGENTS.md (directory) → Aimi defaults
  - Small files (<2KB) inlined, larger files referenced
- **Aimi Default Commit/PR Rules**: Fallback rules when project lacks CLAUDE.md/AGENTS.md
  - `default-rules.md` reference file with commit format, behavior, and PR guidelines
  - Always applied if project files lack commit/PR section
- **Fresh Context Per Story**: Each Task agent starts with clean context (no memory carryover)

### Changed

- **BREAKING:** Renamed `[PATTERNS_CONTENT]` placeholder to `[PROJECT_GUIDELINES]`
- Story-executor now uses `get_project_guidelines()` instead of `get_patterns_content()`
- Execution rules Step 1 now reads CLAUDE.md/AGENTS.md instead of progress.md
- Learnings stored in CLAUDE.md (project-wide) or AGENTS.md (module-specific)

### Removed

- `patternsToFollow` field is now optional (guidelines discovery is automatic)

## [0.6.0] - 2026-02-16

### Changed

- **BREAKING:** Removed `progress.md` - all state now in `tasks.json`
  - No more progress.md initialization in `/aimi:plan`
  - No more progress entry appending in `/aimi:next`
  - No more CODEBASE_PATTERNS from progress.md
- Simplified prompt template (removed progress.md references)
- Simplified interpolation function signature

### Removed

- `progress.md` file and all references
- CODEBASE_PATTERNS placeholder
- `Bash(grep:*)`, `Bash(cat:*)`, `Bash(tail:*)` from allowed-tools (no longer needed)

## [0.5.1] - 2026-02-16

### Fixed

- `/aimi:next` now ensures `progress.md` is always updated after task completion
  - Step 5a: Verify tasks.json updated, fallback update via jq if not
  - Step 5b: Check if progress entry exists, append if missing
- `/aimi:status` now uses jq for minimal context usage
- `/aimi:status` shows skipped stories with `✗` indicator
- `/aimi:status` displays recent activity from progress.md

### Added

- `Bash(grep:*)`, `Bash(cat:*)` to `/aimi:next` allowed-tools
- `Bash(tail:*)` to `/aimi:status` allowed-tools

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

This plugin requires **compound-engineering-plugin** for brainstorm, plan, and review workflows.
