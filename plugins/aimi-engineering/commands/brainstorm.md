---
name: aimi:brainstorm
description: Explore ideas through guided brainstorming (wraps compound-engineering)
argument-hint: "[feature description]"
---

# Aimi Brainstorm

Run compound-engineering's brainstorm workflow, then present Aimi-branded next steps.

## Step 1: Execute Compound Brainstorm

/workflows:brainstorm $ARGUMENTS

## Step 2: Aimi-Branded Next Steps (OVERRIDE)

**CRITICAL:** After the brainstorm workflow completes, IGNORE any compound-engineering options it presents. Instead, display ONLY these Aimi-specific next steps:

```
Brainstorm complete!

Document: docs/brainstorms/[filename].md

Next steps:
1. **Run `/aimi:plan`** - Create implementation plan and tasks.json
2. **Continue brainstorming** - Run `/aimi:brainstorm` to explore further
3. **Review document** - Open the brainstorm file to refine manually
```

**Command Mapping (what to say vs what NOT to say):**

| If compound says... | Aimi says instead... |
|---------------------|----------------------|
| `/workflows:plan` | `/aimi:plan` |
| `/workflows:brainstorm` | `/aimi:brainstorm` |
| `/workflows:work` | `/aimi:execute` |
| `/deepen-plan` | `/aimi:deepen` |
| `/plan_review` | `/aimi:review` |
| `/technical_review` | `/aimi:review` |

**NEVER mention:**
- compound-engineering
- workflows:*
- Any command without the `aimi:` prefix
