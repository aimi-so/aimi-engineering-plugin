---
name: aimi:plan
description: Generate tasks.json directly from a feature description
argument-hint: "[feature description]"
---

# Aimi Plan

Generate `tasks.json` directly from a feature description using the task-planner skill. No intermediate markdown plan.

## Step 1: Generate Tasks

**CRITICAL: You MUST use the Skill tool to load the `task-planner` skill.**

Do NOT generate tasks.json from memory or inline. The `task-planner` skill contains the authoritative pipeline: research, spec analysis, story decomposition, and output format.

1. Call the Skill tool with `skill: "aimi-engineering:task-planner"` and `args: "$ARGUMENTS"`
2. Follow ALL instructions from the loaded skill to produce the tasks.json

If the Skill tool is unavailable, read the skill file directly at `plugins/aimi-engineering/skills/task-planner/SKILL.md` and follow its instructions exactly.

## Step 2: Aimi-Branded Report (OVERRIDE)

**CRITICAL:** Display ONLY Aimi-specific output. NEVER show compound-engineering options.

```
Tasks generated successfully!

Tasks: docs/tasks/[tasks-filename].json

Stories: [X] total
Schema version: 2.2

Next steps:
1. **Run `/aimi:deepen`** - Enrich stories with research (optional)
2. **Run `/aimi:review`** - Get feedback from code reviewers
3. **Run `/aimi:status`** - View task list
4. **Run `/aimi:execute`** - Begin autonomous execution
```

**Command Mapping (what to say vs what NOT to say):**

| If compound says... | Aimi says instead... |
|---------------------|----------------------|
| `/workflows:plan` | `/aimi:plan` |
| `/workflows:work` | `/aimi:execute` |
| `/deepen-plan` | `/aimi:deepen` |
| `/plan_review` | `/aimi:review` |
| `/technical_review` | `/aimi:review` |

**NEVER mention:**
- compound-engineering
- workflows:*
- Any command without the `aimi:` prefix

## Error Handling

If the task-planner skill fails:
- Report the error to the user
- Suggest: "Check that compound-engineering plugin is installed for research agents."

If the tasks.json file was not written:
- Report which phase failed
- Suggest running `/aimi:plan` again with a more specific feature description
