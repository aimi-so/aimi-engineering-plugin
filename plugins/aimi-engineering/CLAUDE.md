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
- `<feature-slug>/roadmap.json` + `<feature-slug>/phase-N[.M][-slug]/` - Phase/milestone roadmap layer for large-scope features (see Roadmap File Schema below). Each phase folder holds `<feature-slug>-phase-N-tasks.json` (materialized by `/aimi:plan --phase N`) and `handoff.md` (written by `roadmap-write-handoff`). Single-scope-context features never create this layout — they use the flat `YYYY-MM-DD-[feature-name]-tasks.json` form above, with zero overhead.

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
    - `--phase-aware` — only meaningful with `--split full-stack`. Strips one trailing `-tasks` segment from the `--output` basename before appending `-frontend-tasks.json`/`-backend-tasks.json`, so a phase-scoped output path (`<feature>-phase-<N>-tasks.json`) produces single-`tasks`-segment split basenames (`<feature>-phase-<N>-frontend-tasks.json`) instead of the legacy double-`tasks` form. Omitted (default): unchanged legacy derivation.

## aimi-cli.sh Roadmap Lifecycle Subcommands

Eleven CLI subcommands manage the phase/milestone roadmap layer for large-scope features (see `commands/references/scope-contexts.md` for when a feature qualifies for phases vs. the flat single-scope-context pipeline). All are internal — consumed by `/aimi:brainstorm`, `/aimi:plan`, `/aimi:execute`, and `/aimi:status`, not invoked by users directly.

- **`roadmap-init --feature <slug> [--file <path>] [--sync] [--brainstorm-path <path>]`** — Materializes `roadmap.json` from a phases array (stdin or `--file`). `--sync` merges additively into an existing roadmap instead of erroring on an existing file.
- **`roadmap-get --feature <slug> [--phase <id>] [--next-eligible]`** — Reads a single phase, or the next eligible-to-claim phase, from `roadmap.json`.
- **`roadmap-set-status --feature <slug> --phase <id> --status <status> [--force]`** — Transitions a phase's lifecycle status (`pending → planned → in_progress → completed`, or `→ verification_failed`). `--force` overrides the *transition-order* check only. It never overrides the hard precondition that a phase can reach `completed` only once `roadmap-write-handoff` has already written that phase's `handoff.md` to disk — that check runs even with `--force`.
- **`roadmap-claim --feature <slug> --session-id <id> --session-pid <pid> [--phase <id>]`** — Atomically claims the next eligible phase (or a specific `--phase` override) for a session via a locked check-and-set. Auto-releases stale claims whose `claimedPid` is no longer alive before choosing. Idempotent: re-claiming a phase the same session already owns returns it again instead of erroring.
- **`roadmap-release-claim --feature <slug> --phase <id>`** — Manual escape hatch to release a phase's claim (in addition to automatic stale-claim recovery).
- **`roadmap-reconcile --feature <slug>`** — Reconciles every phase's `status` against its own `<feature>-phase-<id>-tasks.json` ground truth (derived from that file's story statuses) and applies corrections in place. A correction that would set a phase to `completed` is applied only when `handoff.md` already exists on disk for that phase; otherwise it is reported as `blocked` rather than applied. Applying a `completed` correction also clears that phase's claim in the same write — reconcile does not otherwise touch claims. Returns `{corrections, blocked}`.
- **`roadmap-write-handoff --feature <slug> --phase <id> [--file <path>]`** — Writes `phase-N/handoff.md` from a structured payload (`decisions`, `artifacts`, `deviations`, `deferred`, `contracts` arrays). A precondition for `roadmap-set-status ... --status completed`.
- **`validate-contracts <feature> [--phase <id>] [--agent-mode]`** — Checks a phase's declared `creates`/`needs` contracts for duplicates and suspicious content; `--agent-mode` demotes hard blocks to warnings (mirrors the Phase 3.1/4.1 `--agent-mode` convention).
- **`phase-overlap <feature> <phase-a> <phase-b>`** — Compares two expanded phases' task files' `implementation.files` sets and emits `{overlapping_files: [...]}`. It reports the overlap only — no splitting suggestion; the caller decides what to do with it.
- **`roadmap-sweep <feature>`** — Batch contract/status consistency sweep across an entire roadmap.
- **`estimate-payload --outline <path> [--research <path>]... [--spec <path>]... [--prototype <path>]... [--budget-bytes <n>] [--budget-fraction <0-1>]`** — Advisory token/byte budget estimate for an outline plus its cited sources; used to warn before a phase's expansion payload gets too large, suggesting a split along a semantic seam.

## Roadmap File Schema

> `roadmap.json` lives at `.aimi/tasks/<feature>/roadmap.json` and tracks phase/milestone lifecycle state for large-scope features. Key fields: `roadmapVersion` ("1.0"), `feature` (slug), `createdAt` (ISO 8601), `brainstormPath` (optional), `phases[]{id(number),name,goal,slug,dir,status(pending|planned|in_progress|completed|verification_failed),dependsOn[](phase ids),branch(optional),notes(optional),successCriteria[](optional),creates[](optional),needs[](optional),areas[](optional),claim(null|{claimedBy,claimedAt,claimedPid})}`.
> `phases[].dir` is a single-path-component directory name matching `^phase-[0-9]+(\.[0-9]+)?(-[a-z0-9][a-z0-9-]*)?$` (e.g. `phase-2`, `phase-2.1-auth-refactor`) — never a slash or `..`.
> `phases[].claim` is written only by `roadmap-claim` and cleared by `roadmap-release-claim`, or automatically when `claimedPid` is no longer alive (PID-liveness check mirrors the guard-runtime-state `_is_alive` pattern).
> All free-text phase fields (`name`, `goal`, `notes`, `successCriteria[]`, `branch`, `brainstormPath`) are sanitized before write using the same regime as `commands/references/sanitization.md` (strip newlines/backticks/`$(`, truncate).

## Tasks File Schema

> Key fields: `schemaVersion` ("3.3"), `metadata{title,type,branchName,researchDepth,maxConcurrency,researchPaths[](optional),prototypePaths[](optional),frontendOnly(optional),backendSpec(optional:{endpoints[],dataModels[],businessRules[],businessContext{summary,userRoles[],constraints[],assumptions[],successCriteria[]}}),decisions[](optional:{anchor,source,text,resolution})}`, `userStories[]{id(US-NNN),title,description,acceptanceCriteria,status,dependsOn,project,wave,tasks[](optional,max50,each≤5000chars),implementation{files,approach,verify},verification{strategy,status,url,expect},gate{type,status,prompt,options}}`
> The `project` field is optional on stories — when present, it specifies the relative path from AIMI_ROOT to the target git repository for multi-repo execution.
> `metadata.decisions[].anchor` valid forms: `specFlow:<key>`, `outline:edit:<idx>` (zero-padded index into the outline list, e.g. `outline:edit:02`), `phase:edit:<idx>` (zero-padded index into a proposed `phases` array at edit time, e.g. `phase:edit:02` — distinct from the persisted numeric phase `id`; used by both the `/aimi:brainstorm` roadmap-gate and the `/aimi:plan` inline fallback gate, see `source` below for how to tell them apart). `metadata.decisions[].source` valid values: `"specFlow:CriticalQ<n>"`, `"specFlow:Gap<n>"`, `"researchConflict"` (Phase 1.6b conflict escalation gate; anchor `researchConflict:<n>`), `"outline"` (for outline-gate edits recorded during the `/aimi:plan` outline gate), `"phaseGate"` (for roadmap-gate edits recorded in `phaseEditDecisions[]` during the `/aimi:brainstorm` Phase 3.5 roadmap definition gate; never written to a tasks.json `metadata.decisions[]` array), `"phase"` (for phase-cut Edit-round edits recorded in `oqDecisions[]`, and thus flushed to `metadata.decisions[]`, by the `/aimi:plan` Phase 0 Scope-Context Classification (Inline Fallback) gate — the no-brainstorm/legacy-brainstorm path that classifies scope contexts directly instead of reusing a brainstorm's `phases:` frontmatter).


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
| `AIMI_RUNTIME_STATE_GUARD` | guard-runtime-state | Allows direct Write/Edit to .aimi/state/, .aimi/tasks during execution, friction/telemetry logs, roadmap.json, and phase-*/handoff.md |
| `AIMI_AGENT_MODE` | aimi-learnings skill | Forces JSON-only read-only path; never marks events |

> `AIMI_RUNTIME_STATE_GUARD` (`guard-runtime-state.py`) intercepts the Write/Edit tool path and blocks direct writes to `roadmap.json` and `phase-*/handoff.md` (see Roadmap File Schema above) the same way it blocks `.aimi/tasks/*-tasks.json`, pointing the caller at the `roadmap-*` aimi-cli.sh verbs instead. This coverage is Write/Edit-tool-only — the hook is registered on `matcher: Write|Edit` (`hooks/hooks.json`) and reads `tool_input.file_path`. A Bash command that writes either file directly (e.g. `jq ... > roadmap.json`) is **not** intercepted.

## Dependencies

This plugin is fully standalone. No external plugin dependencies required.
