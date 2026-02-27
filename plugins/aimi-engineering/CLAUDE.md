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
   - Validate field lengths (title: 200, description: 500, criterion: 300)
   - Reject suspicious content ("ignore previous instructions", shell syntax)

3. **Bash permissions** - Use specific prefixes in allowed-tools:
   - `Bash(git:*), Bash(npm:*), Bash(bun:*), Bash(tsc:*)` etc.
   - Never use unrestricted `Bash` in commands that spawn Task agents

## Command Conventions

- Use `aimi:` prefix for all commands
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

Learnings are stored in project files (not separate progress log):

- `CLAUDE.md` (root) - Project-wide patterns and conventions
- `AGENTS.md` (per-directory) - Module-specific patterns and gotchas

## Tasks File Schema

### Required Fields

```json
{
  "schemaVersion": "2.1",
  "metadata": {
    "title": "feat: Add feature name",
    "type": "feat|ref|bug|chore",
    "branchName": "feat/feature-name",
    "createdAt": "YYYY-MM-DD",
    "planPath": ".aimi/plans/YYYY-MM-DD-feature-name-plan.md"
  },
  "userStories": [{
    "id": "US-XXX",
    "title": "string (max 200)",
    "description": "string (max 500)",
    "acceptanceCriteria": ["string"],
    "priority": 1,
    "passes": false,
    "notes": ""
  }]
}
```

## Performance Guidelines

1. **Inline story data** - Pass story content directly in Task prompts
   - Don't tell agents to re-read the tasks file
   - Reduces file I/O by ~33%

2. **Use CLAUDE.md/AGENTS.md** - Project conventions inline or referenced
   - Small files (<2KB) are inlined in prompt
   - Larger files are referenced for agent to read

3. **Compact prompts** - Use compressed prompt format for subsequent stories
   - Full prompt for first story, compact for rest
   - ~60% token reduction

4. **Fresh context per story** - Each Task agent starts with clean context
   - No memory carryover between stories
   - Learnings persist via CLAUDE.md/AGENTS.md files

## Dependencies

This plugin is fully standalone. No external plugin dependencies required.
