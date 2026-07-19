# Aimi Engineering Plugin - Development Guidelines

## Versioning Requirements

**Every change to this plugin MUST include:**

1. **Bump version** in `.claude-plugin/plugin.json` (follow semver)
   - MAJOR: Breaking changes to command syntax or output format
   - MINOR: New commands, skills, or features
   - PATCH: Bug fixes, documentation updates

2. **Update CHANGELOG.md** with the change description
   - Follow [Keep a Changelog](https://keepachangelog.com/) format
   - Categories: Added, Changed, Fixed, Removed, Security

3. **Update README.md** component counts if adding/removing components

4. **Update marketplace.json** version to match plugin.json

## Plugin Structure

```
aimi-engineering-plugin/
├── .claude-plugin/
│   └── marketplace.json         # Marketplace manifest (points to plugins/)
├── plugins/aimi-engineering/    # Actual plugin content
│   ├── .claude-plugin/
│   │   └── plugin.json          # Plugin manifest
│   ├── commands/                # Slash commands (.md files)
│   ├── skills/                  # Skills (subdirs with SKILL.md)
│   │   └── skill-name/
│   │       ├── SKILL.md
│   │       └── references/
│   └── CLAUDE.md                # This file
├── CHANGELOG.md                 # Version history
└── README.md                    # User documentation
```

## Security Requirements

### Input Validation (CRITICAL)

1. **branchName validation** - Must match `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$`
   - Prevents command injection in git operations
   - Reject invalid names before any git command

2. **Story content sanitization** - Before prompt interpolation:
   - Strip newlines, markdown headers, code fences
   - Validate field lengths (title: 200, description: 500, criterion: 5000)
   - Reject suspicious content ("ignore previous instructions", shell syntax)

3. **Bash permissions** - Use specific prefixes in allowed-tools:
   - `Bash(git:*), Bash(npm:*), Bash(bun:*), Bash(tsc:*)` etc.
   - Never use unrestricted `Bash` in commands that spawn Task agents

## Hook Conventions

- Hooks emitting hookSpecificOutput must gate on CLAUDECODE env var when their output schema is Claude Code-specific.

## Command Conventions

- Use `aimi:` prefix for all commands — always show `/aimi:plan`, `/aimi:execute`, etc. in output, NEVER the fully-qualified `/aimi-engineering:plan` form
- Use `disable-model-invocation: true` for side-effect commands
- Wrapper commands should pass `$ARGUMENTS` to wrapped commands
- Document allowed-tools in frontmatter with specific Bash prefixes
- Validate inputs before passing to external commands

## Skill Conventions

- Keep SKILL.md under 300 lines
- Move detailed schemas/examples to `references/` directory
- Include trigger phrases in description
- Use imperative writing style
- Include Input Sanitization section for skills that process user data
- Document Available Capabilities for Task-spawned agents

## Output Files

All task execution files go in `.aimi/tasks/`:

- `YYYY-MM-DD-[feature-name]-tasks.json` - Structured task list with user stories

> The CLI auto-discovers `.aimi/` by walking up from CWD -- no need to be in the project root to run commands.

Learnings are stored in project files (not separate progress log):

- `CLAUDE.md` (root) - Project-wide patterns and conventions
- `AGENTS.md` (plugin-level) - Single source of truth for spawned agent output compression rules; portable across tools (Claude Code, OpenCode). Per-directory AGENTS.md files in skills/ extend these base rules with domain-specific patterns

## aimi-cli.sh Research Subcommands

Two CLI subcommands manage the research lifecycle. Both are internal — consumed by `plan` and `deepen` commands, not invoked by users directly.

- **`research-lookup <path>`** — Content-aware freshness check. Reads the `## File References` h2 bullet section of the given research `.md` file, compares its mtime against the newest mtime of every cited source path, and exits 0 (fresh) or 1 (stale). Cited paths that are missing or outside the project root are treated as stale. Used by `plan`/`deepen` before deciding whether to spawn a researcher.

- **`research-gc`** — Orphan garbage collector. Deletes `.aimi/research/*.md` files older than 30 days that are not referenced by any active `.aimi/tasks/*.json` `metadata.researchPaths` or any `.aimi/brainstorms/*.md` frontmatter `researchPaths`. Called opportunistically once per `plan`/`deepen` session. Silent when nothing is removed.

## aimi-cli.sh Story Lifecycle Subcommands

One CLI subcommand manages the story-merge lifecycle. It is consumed by the `/aimi:plan` two-pass pipeline, not invoked by users directly.

- **`story-merge`** — Consolidates per-story JSON staging files written by Pass 2 sub-agents into a single validated `tasks.json`. Key behaviors:
  - **Deterministic ID assignment**: each staging file receives a stable `US-NNN` identifier in outline order.
  - **dependsOn token remapping**: `outline:NN` tokens emitted by sub-agents are rewritten to the assigned `US-NNN` before write.
  - **DAG validation**: cycle detection aborts the merge before any write.
  - **Wave computation**: BFS over the dependency graph assigns each story to a parallelism wave.
  - **Post-merge sweeps**: Rule 22 mock-sync AC routing, Phase 3.1 Reference Element Inventory verdict check, and Phase 4.1 Coverage Self-Check run after DAG validation and before the atomic write.
  - **Atomic write**: output file is written under `flock` to prevent partial reads by concurrent processes.
  - **Flags**:
    - `--staging-dir <path>` — directory containing per-story staging `.json` files (default: `.aimi/.tasks-staging/<topic-slug>-<RUN_TS>/`).
    - `--output <path>` — destination `tasks.json` path (default: `.aimi/tasks/<date>-<topic-slug>-tasks.json`).
    - `--split legacy|full-stack` — `full-stack` emits two files (frontend + backend) partitioned by story `project` field; `legacy` (default) emits one file.
    - `--agent-mode` — demotes Phase 3.1 and Phase 4.1 hard rejects to warnings, allowing CI pipelines to proceed without a user review gate.

## Tasks File Schema

> Key fields: `schemaVersion` ("3.3"), `metadata{title,type,branchName,researchDepth,maxConcurrency,researchPaths[](optional),prototypePaths[](optional),frontendOnly(optional),backendSpec(optional:{endpoints[],dataModels[],businessRules[],businessContext{summary,userRoles[],constraints[],assumptions[],successCriteria[]}}),decisions[](optional:{anchor,source,text,resolution})}`, `userStories[]{id(US-NNN),title,description,acceptanceCriteria,status,dependsOn,project,wave,tasks[](optional,max50,each≤5000chars),implementation{files,approach,verify},verification{strategy,status,url,expect},gate{type,status,prompt,options}}`
> The `project` field is optional on stories — when present, it specifies the relative path from AIMI_ROOT to the target git repository for multi-repo execution.
> `metadata.decisions[].anchor` valid forms: `specFlow:<key>`, `outline:edit:<idx>` (zero-padded index into the outline list, e.g. `outline:edit:02`), `phase:edit:<idx>` (zero-padded index into the `/aimi:brainstorm` roadmap-gate `phases` array at edit time, e.g. `phase:edit:02` — distinct from the persisted numeric phase `id`). `metadata.decisions[].source` valid values: `"specFlow:CriticalQ<n>"`, `"specFlow:Gap<n>"`, `"researchConflict"` (Phase 1.6b conflict escalation gate; anchor `researchConflict:<n>`), `"outline"` (for outline-gate edits recorded during the `/aimi:plan` outline gate), `"phaseGate"` (for roadmap-gate edits recorded in `phaseEditDecisions[]` during the `/aimi:brainstorm` Phase 3.5 roadmap definition gate).


## Performance Guidelines

1. **Pointer-only handoff** - Spawn prompts carry only the story id in a `task_pointer` block; each subagent fetches its own full context via `$AIMI_CLI get-story-context $STORY_ID` as its first action
   - Keeps the orchestrator's working memory slim across waves — no inlined story body, no inlined prototype HTML in the spawn prompt
   - Prototype files are read by the subagent itself using the Read tool when `metadata.prototypePaths` is non-empty or `story.implementation.prototypeAnchor` is set

2. **Use CLAUDE.md/AGENTS.md** - Project conventions inline or referenced
   - Small files (<2KB) are inlined in prompt
   - Larger files are referenced for agent to read

3. **Compact prompts** - First story in a session gets the full template (SKILL.md "Prompt Template"); subsequent stories get the condensed variant (SKILL.md "Compact Template") where static sections (`<project_guidelines>`, `<execution_flow>`, `<tools>`, `<on_failure>`, `<project_root_boundary>`) are condensed to one-line summaries — NOT omitted, since each agent has fresh context. Story-specific and context-varying sections remain in full
   - Reduces prompt size by collapsing static sections; actual savings depend on story content and have not been benchmarked

4. **Fresh context per story** - Each Task agent starts with clean context
   - No memory carryover between stories
   - Learnings persist via CLAUDE.md/AGENTS.md files

5. **Spawned agent output behavior** - See `AGENTS.md` for output compression, safety escapes, and context-adaptive verbosity rules
   - AGENTS.md defines the rules; this file references them (no duplication)
   - AGENTS.md is portable across tools (Claude Code, OpenCode) and is the single source of truth for spawned agent behavior

## Guard Bypass Envs

Hooks support per-guard bypass via environment variables. Set `<name>=off` (or unset to leave the guard active). Bypass is intentional escape hatch — use sparingly and document why.

| Env Var | Hook | Behavior when `off` |
|---|---|---|
| `AIMI_DEFAULT_BRANCH_GUARD` | pre-bash-dispatcher (default-branch handler) | Allows commits on protected branches (main/master/develop) |
| `AIMI_SHELL_TRUE_GUARD` | pre-bash-dispatcher (shell-true handler) | Allows commits with shell=True in staged Python files |
| `AIMI_WORKTREE_BUDGET_GUARD` | pre-bash-dispatcher (worktree-budget handler) | Allows git worktree add beyond metadata.maxConcurrency |
| `AIMI_RUNTIME_STATE_GUARD` | guard-runtime-state | Allows direct Write/Edit to .aimi/state/, .aimi/tasks during execution, friction/telemetry logs |
| `AIMI_AGENT_MODE` | aimi-learnings skill | Forces JSON-only read-only path; never marks events |

## Dependencies

This plugin is fully standalone. No external plugin dependencies required.
