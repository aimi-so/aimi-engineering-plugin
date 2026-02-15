# Aimi Engineering Plugin - Development Guidelines

## Versioning Requirements

**Every change to this plugin MUST include:**

1. **Bump version** in `.claude-plugin/plugin.json` (follow semver)
   - MAJOR: Breaking changes to command syntax or output format
   - MINOR: New commands, skills, or features
   - PATCH: Bug fixes, documentation updates

2. **Update CHANGELOG.md** with the change description
   - Follow [Keep a Changelog](https://keepachangelog.com/) format
   - Categories: Added, Changed, Fixed, Removed

3. **Update README.md** component counts if adding/removing components

## Plugin Structure

```
aimi-engineering-plugin/
├── .claude-plugin/
│   └── plugin.json              # Plugin manifest (NO dependencies field)
├── commands/                    # Slash commands (.md files)
├── skills/                      # Skills (subdirs with SKILL.md)
│   └── skill-name/
│       ├── SKILL.md
│       └── references/
├── CLAUDE.md                    # This file
├── CHANGELOG.md                 # Version history
└── README.md                    # User documentation
```

## Command Conventions

- Use `aimi:` prefix for all commands
- Use `disable-model-invocation: true` for side-effect commands
- Wrapper commands should pass `$ARGUMENTS` to wrapped commands
- Document allowed-tools in frontmatter for permission clarity

## Skill Conventions

- Keep SKILL.md under 300 lines
- Move detailed schemas/examples to `references/` directory
- Include trigger phrases in description
- Use imperative writing style

## Output Files

All task execution files go in `docs/tasks/`:
- `tasks.json` - Structured task list with user stories
- `progress.md` - Learnings log with Codebase Patterns section

## Dependencies

This plugin requires **compound-engineering-plugin** to be installed.
Document this in README.md (Claude Code does not support plugin dependencies in manifest).

## Commit Message Format

```
feat: Add [component name]
fix: Fix [issue description]
docs: Update [documentation]
```
