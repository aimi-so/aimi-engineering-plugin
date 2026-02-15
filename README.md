# Aimi Engineering Plugin

A Claude Code plugin that extends `compound-engineering-plugin` to generate autonomous task execution files in JSON format.

## Overview

This plugin enables iterative autonomous agent execution by generating structured task files following Ralph's `prd.json` format. Each task is broken down into verifiable user stories that can be completed within a single agent iteration.

## Installation

```bash
# Clone the repository
git clone git@github.com:aimi-so/aimi-engineering-plugin.git

# Add to your Claude Code plugins
claude plugins add ./aimi-engineering-plugin
```

## Task Output Format

The plugin generates `prd.json` files with the following structure:

```json
{
  "project": "ProjectName",
  "branchName": "feature/task-name",
  "description": "Task description",
  "userStories": [
    {
      "id": "US-001",
      "title": "Story title",
      "description": "As a [user], I want [feature] so that [benefit]",
      "acceptanceCriteria": ["Criterion 1", "Typecheck passes"],
      "priority": 1,
      "passes": false,
      "notes": ""
    }
  ]
}
```

## Story Guidelines

### Sizing

- Each story must be completable in ONE agent iteration (single context window)
- Acceptance criteria must be verifiable (not vague)

### Ordering

Stories are ordered by dependency:

1. Schema/database changes (migrations)
2. Server actions / backend logic
3. UI components that use the backend
4. Dashboard/summary views that aggregate data

## Project Structure

```
aimi-engineering-plugin/
├── .claude-plugin/
│   └── plugin.json           # Plugin manifest
├── agents/                   # Specialized agents (.md files)
├── commands/                 # Slash commands (.md files)
├── skills/                   # Skills (subdirs with SKILL.md)
│   └── skill-name/
│       ├── SKILL.md
│       └── references/
└── README.md
```

## Components

| Type | Count |
|------|-------|
| Agents | 0 |
| Commands | 0 |
| Skills | 0 |

## License

MIT
