---
name: aimi:review
description: Perform code reviews using parallel aimi-native review agents
argument-hint: "[PR number, GitHub URL, branch name, or latest]"
---

# Aimi Review

Perform code reviews using parallel aimi-native review agents with findings synthesis.

## Step 1: Determine Review Target

<review_target> #$ARGUMENTS </review_target>

### Detect Target Type

1. **PR number** (numeric): Fetch PR with `gh pr view $ARGUMENTS --json title,body,files,headRefName,baseRefName`
2. **GitHub URL**: Extract PR number, then fetch as above
3. **Branch name**: Compare against main/master with `git diff main...$ARGUMENTS --name-only`
4. **Empty** (no arguments): Review current branch against main/master

### Setup

```bash
# Get changed files
gh pr view [number] --json files --jq '.files[].path'
# OR for branch comparison:
git diff main...HEAD --name-only
```

Read the changed files to understand the PR content. Collect the diff for agent context.

### Protected Artifacts

These paths must never be flagged for deletion or removal by any review agent:
- `.aimi/plans/*.md` — Plan files
- `.aimi/solutions/*.md` — Solution documents
- `.aimi/tasks/*.json` — Task files
- `.aimi/brainstorms/*.md` — Brainstorm documents

## Step 2: Run Default Review Agents (Parallel)

Run these agents **in parallel** using the Task tool:

```
Task subagent_type="aimi-engineering:review:aimi-architecture-strategist"
  prompt: "Review this code for architectural compliance:
           [PR content / diff summary]"

Task subagent_type="aimi-engineering:review:aimi-security-sentinel"
  prompt: "Perform security audit on this code:
           [PR content / diff summary]"

Task subagent_type="aimi-engineering:review:aimi-code-simplicity-reviewer"
  prompt: "Review this code for simplicity and minimalism:
           [PR content / diff summary]"

Task subagent_type="aimi-engineering:review:aimi-performance-oracle"
  prompt: "Analyze this code for performance issues:
           [PR content / diff summary]"

Task subagent_type="aimi-engineering:review:aimi-agent-native-reviewer"
  prompt: "Verify new features are agent-accessible:
           [PR content / diff summary]"

Task subagent_type="aimi-engineering:research:aimi-learnings-researcher"
  prompt: "Search .aimi/solutions/ for past issues related to this PR:
           [PR content / diff summary]"
```

## Step 3: Run Conditional Agents (If Applicable)

### Migration Agents

**Run ONLY when PR contains database migrations, schema changes, or data backfills.**

Detection: Check if changed files include `db/migrate/*.rb`, `db/schema.rb`, migration scripts, or data backfill tasks.

```
Task subagent_type="aimi-engineering:review:aimi-schema-drift-detector"
  prompt: "Detect unrelated schema.rb changes:
           [PR content / diff summary]"

Task subagent_type="aimi-engineering:review:aimi-data-migration-expert"
  prompt: "Validate ID mappings and migration safety:
           [PR content / diff summary]"

Task subagent_type="aimi-engineering:review:aimi-deployment-verification-agent"
  prompt: "Create deployment checklist with verification queries:
           [PR content / diff summary]"
```

### Language-Specific Agents

Detect primary language from changed files and run the appropriate reviewer:

| File Extensions | Agent |
|----------------|-------|
| `*.rb`, `Gemfile`, `*.erb` | `aimi-engineering:review:aimi-kieran-rails-reviewer` |
| `*.ts`, `*.tsx`, `*.js` | `aimi-engineering:review:aimi-kieran-typescript-reviewer` |
| `*.py` | `aimi-engineering:review:aimi-kieran-python-reviewer` |

For Rails projects, also consider running:
- `aimi-engineering:review:aimi-dhh-rails-reviewer` for Rails convention checks
- `aimi-engineering:review:aimi-julik-frontend-races-reviewer` for Stimulus/JS race conditions

## Step 4: Findings Synthesis

### Consolidate Results

1. Collect findings from all parallel agents
2. Surface learnings-researcher results: flag relevant past solutions as "Known Pattern" with links to .aimi/solutions/ files
3. Discard any findings that recommend deleting protected artifacts (see Step 1)
4. Remove duplicate or overlapping findings

### Categorize by Severity

- **P1 CRITICAL** — Blocks merge: security vulnerabilities, data corruption risks, breaking changes
- **P2 IMPORTANT** — Should fix: performance issues, architectural concerns, code quality problems
- **P3 NICE-TO-HAVE** — Enhancements: minor improvements, cleanup, documentation

### Estimate Effort

For each finding: Small (< 30 min), Medium (30 min - 2 hours), Large (> 2 hours)

## Step 5: Aimi-Branded Report

```
## Review Complete

**Review Target:** [PR title or branch name]
**Branch:** [branch-name]

### Findings Summary

- **Total Findings:** [X]
- **P1 CRITICAL:** [count] - BLOCKS MERGE
- **P2 IMPORTANT:** [count] - Should Fix
- **P3 NICE-TO-HAVE:** [count] - Enhancements

### P1 - Critical (Must Fix Before Merge)

1. **[Finding title]** — [description]
   - Location: [file:line]
   - Impact: [what breaks]
   - Fix: [how to fix]
   - Effort: [Small/Medium/Large]

### P2 - Important (Should Fix)

1. **[Finding title]** — [description]
   - Location: [file:line]
   - Recommendation: [how to improve]
   - Effort: [Small/Medium/Large]

### P3 - Nice-to-Have

1. **[Finding title]** — [description]
   - Suggestion: [improvement]

### Review Agents Used

- aimi-architecture-strategist
- aimi-security-sentinel
- aimi-code-simplicity-reviewer
- aimi-performance-oracle
- aimi-agent-native-reviewer
- aimi-learnings-researcher
- [conditional agents if run]

### Next Steps

1. **Address P1 findings** — Critical issues must be fixed before merge
2. **Run `/aimi:execute`** — Continue autonomous execution
3. **Run `/aimi:status`** — Check current task progress
```

## Error Handling

| Failure | Action |
|---------|--------|
| No review target found | Ask user to specify PR number or branch |
| Agent fails | Proceed with available results, note in report |
| No changed files | Report "No changes to review" |
| gh CLI not installed | Fall back to git diff for branch comparison |
