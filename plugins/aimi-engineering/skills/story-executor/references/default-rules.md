# Aimi Default Commit and PR Rules

These rules apply when the target project does not have CLAUDE.md or AGENTS.md with commit/PR guidelines.

## Commit Message Format

```
<type>(<scope>): <description>
```

### Types

| Type | When to Use |
|------|-------------|
| `feat` | New feature or functionality |
| `fix` | Bug fix |
| `refactor` | Code refactoring (no behavior change) |
| `docs` | Documentation only |
| `test` | Adding or updating tests |
| `chore` | Build, tooling, or dependency updates |

### Examples

```
feat(users): Add users database schema
fix(auth): Fix login redirect on expired session
refactor(auth): Extract password validation to utility
test(auth): Add unit tests for auth service
```

### Rules

- First line max 72 characters
- Scope: module or feature area (e.g., auth, users, tasks)
- Use imperative mood ("Add" not "Added")
- No trailing period

## Commit Behavior

**MUST follow:**

1. **One commit per story** - Each story completion = one commit
2. **Quality gates first** - All checks must pass before commit
3. **Never skip hooks** - Never use `--no-verify` or skip pre-commit hooks
4. **No force push** - Never force push unless explicitly instructed by user
5. **Clean working tree** - Commit only story-related changes

**If quality checks fail:**
- Do NOT commit
- Mark story as failed with error details
- Report the failure

## Pull Request Rules

When creating PRs (via `gh pr create` or similar):

### PR Title Format

```
<type>(<scope>): <subject>
```

Example: `feat(auth): add user authentication flow`

### PR Description Template

```markdown
## Problem

<Why this change is needed - the business or technical problem>

## Solution

<How the problem was solved - high-level approach>

## Stories Completed

- US-001: Story title
- US-002: Story title

## Changes

- <Main change 1>
- <Main change 2>

## Testing

- <How changes were verified>
```

### Example PR

**Title:** `feat(tasks): add task status feature`

**Description:**

```markdown
## Problem

Users had no way to track task progress. All tasks appeared the same
regardless of whether they were pending, in progress, or completed.

## Solution

Add status field to tasks with visual indicators and filtering.

## Stories Completed

- US-001: Add status field to tasks table
- US-002: Display status badge on task cards
- US-003: Add status toggle to task list rows
- US-004: Filter tasks by status

## Changes

- Add status column to tasks table (pending/in_progress/done)
- Add colored status badges to task cards
- Add status toggle dropdown in task list
- Add filter dropdown with URL persistence

## Testing

- Unit tests for status mutations
- Manual verification in browser
- Typecheck passes
```

### PR Rules

1. **Request review** - Always request at least one reviewer
2. **Link to tasks** - Reference the tasks file or plan file
3. **Draft for WIP** - Use draft PR if work is incomplete
4. **Small PRs** - Prefer smaller, focused PRs over large ones
5. **No self-merge** - Wait for approval before merging (unless solo project)

## Branch Naming

```
feature/<project-name>
fix/<issue-description>
refactor/<scope>
```

- Use lowercase
- Use hyphens for spaces
- Keep it concise but descriptive
