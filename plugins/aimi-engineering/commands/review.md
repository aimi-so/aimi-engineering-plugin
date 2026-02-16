---
name: aimi:review
description: Code review using compound-engineering workflows
argument-hint: "[files or PR to review]"
---

# Aimi Review

Run compound-engineering's review workflow, then present Aimi-branded summary.

## Step 1: Execute Compound Review

/workflows:review $ARGUMENTS

## Step 2: Aimi-Branded Summary (OVERRIDE)

**CRITICAL:** After the review completes, present ONLY Aimi-specific next steps.

```
Review complete!

Next steps:
1. **Address findings** - Fix issues identified in the review
2. **Run `/aimi:execute`** - Continue autonomous execution
3. **Run `/aimi:status`** - Check current task progress
```

**Command Mapping (what to say vs what NOT to say):**

| If compound says... | Aimi says instead... |
|---------------------|----------------------|
| `/workflows:work` | `/aimi:execute` |
| `/workflows:plan` | `/aimi:plan` |

**NEVER mention:**
- compound-engineering
- workflows:*
- Any command without the `aimi:` prefix
