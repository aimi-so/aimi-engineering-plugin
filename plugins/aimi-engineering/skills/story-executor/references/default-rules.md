# Aimi Default Commit and PR Rules

These rules apply when the target project does not have CLAUDE.md or AGENTS.md with commit/PR guidelines.

## Commit Message Format

```
<type>: [<story-id>] - <description>
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
feat: [US-001] - Add users database schema
fix: [US-005] - Fix login redirect on expired session
refactor: [US-012] - Extract password validation to utility
test: [US-003] - Add unit tests for auth service
```

### Rules

- First line max 72 characters
- Use imperative mood ("Add" not "Added")
- Reference story ID in every commit
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
[Feature] <brief description>
```

Match the branch name pattern where possible.

### PR Description Template

```markdown
## Summary

Brief description of what this PR implements.

## Stories Completed

- [US-001] Story title
- [US-002] Story title

## Changes

- Change 1
- Change 2

## Testing

- [ ] All unit tests pass
- [ ] Typecheck passes
- [ ] Manual testing completed

## Notes

Any additional context or notes for reviewers.
```

### PR Rules

1. **Request review** - Always request at least one reviewer
2. **Link to tasks** - Reference the tasks.json or plan file
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
