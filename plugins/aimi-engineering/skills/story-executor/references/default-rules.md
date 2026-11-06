# Aimi Default Commit Rules

These rules apply when the target project does not have CLAUDE.md or AGENTS.md with commit guidelines.

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

## Branch Naming

```
feature/<project-name>
fix/<issue-description>
refactor/<scope>
```

- Use lowercase
- Use hyphens for spaces
- Keep it concise but descriptive
