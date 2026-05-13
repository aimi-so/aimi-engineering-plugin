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

## Tasks File Schema

> Key fields: `schemaVersion` ("3.3"), `metadata{title,type,branchName,researchDepth,maxConcurrency,researchPaths[](optional),prototypePaths[](optional),frontendOnly(optional),backendSpec(optional:{endpoints[],dataModels[],businessRules[],businessContext{summary,userRoles[],constraints[],assumptions[],successCriteria[]}})}`, `userStories[]{id(US-NNN),title,description,acceptanceCriteria,status,dependsOn,project,wave,tasks[](optional,max50,each≤5000chars),implementation{files,approach,verify},verification{strategy,status,url,expect},gate{type,status,prompt,options}}`
> The `project` field is optional on stories — when present, it specifies the relative path from AIMI_ROOT to the target git repository for multi-repo execution.


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

## Dependencies

This plugin is fully standalone. No external plugin dependencies required.
