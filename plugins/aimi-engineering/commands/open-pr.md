---
name: aimi:open-pr
description: Open a pull request with auto-populated title and description from tasks
disable-model-invocation: true
allowed-tools: Bash(gh:*), Bash(git:*), Bash(AIMI_CLI=*), Bash($AIMI_CLI:*)
---

# Aimi Open PR

Automatically detect the parent branch, build PR title and description from tasks.json, and create a pull request via `gh pr create`.

## Step 0: Resolve CLI Path

Resolve `$AIMI_CLI` path using the four-layer strategy below. Each command is a separate Bash call (no compound operators).

**Layer 0 — AIMI_PLUGIN_DIR (env var override):**
```bash
if [ -n "$AIMI_PLUGIN_DIR" ] && [ "${AIMI_PLUGIN_DIR#/}" != "$AIMI_PLUGIN_DIR" ] && [ -d "$AIMI_PLUGIN_DIR" ] && [ -x "$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh" ]; then AIMI_CLI="$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh"; fi
```

**Layer 1 — Global cache (fast path):**
```bash
if [ -z "$AIMI_CLI" ]; then AIMI_CLI=$(cat ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path 2>/dev/null); fi
```

**Layer 1 validation:**
```bash
if [ -n "$AIMI_CLI" ] && [ ! -x "$AIMI_CLI" ]; then AIMI_CLI=""; fi
```

**Layer 2 — Glob fallback (zsh-safe, only if Layer 1 failed):**
```bash
if [ -z "$AIMI_CLI" ]; then AIMI_CLI=$(bash -c 'ls ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1'); fi
```

**Layer 2 cache update:**
```bash
if [ -n "$AIMI_CLI" ]; then printf '%s\n' "$AIMI_CLI" > "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path.tmp" && mv "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path.tmp" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" && chmod 600 "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path"; fi
```

**Layer 3 — Per-project fallback (last resort):**
```bash
if [ -z "$AIMI_CLI" ] && [ -f .aimi/cli-path ] && [ -x "$(cat .aimi/cli-path)" ]; then AIMI_CLI=$(cat .aimi/cli-path); fi
```

If empty, report error and STOP:
- If `$AIMI_PLUGIN_DIR` is set: "aimi-cli.sh not found. Check AIMI_PLUGIN_DIR path: $AIMI_PLUGIN_DIR"
- Otherwise: "aimi-cli.sh not found. Reinstall plugin: `/plugin install aimi-engineering`"

**Version check:**
```bash
$AIMI_CLI check-version --quiet --fix
```

Use `$AIMI_CLI` for all subsequent script calls.

## Step 1: Pre-flight Checks

Run these checks before proceeding. STOP on failure unless noted.

### 1a. Verify GitHub CLI authentication

```bash
gh auth status
```

If this fails, report: "GitHub CLI not authenticated. Run `gh auth login` first." and STOP.

### 1b. Check for existing PR on this branch

```bash
gh pr view --json url --jq '.url' 2>/dev/null
```

If this succeeds (exit code 0), an existing PR already exists. Report the PR URL to the user and STOP (do not error — this is informational):
```
PR already exists for this branch: <url>
```

### 1c. Warn about uncommitted changes

```bash
git status --porcelain
```

If output is non-empty, warn the user:
```
Warning: You have uncommitted changes. Consider committing before opening a PR.
```

Continue execution (do not stop).

## Step 2: Read Metadata and Status via CLI

### 2a. Get metadata

```bash
$AIMI_CLI metadata
```

This returns JSON with task metadata. Extract:
- `metadata.title` — already in `type(scope): subject` format, used as the PR title
- `metadata.frontendOnly` — boolean flag indicating a frontend-only prototype
- `metadata.backendSpec` — object containing backend implementation details (endpoints, data models, business rules, business context)

If no tasks file found, the script exits with error. Report:
```
No tasks file found. Run /aimi:plan to create a task list.
```
and STOP.

### 2b. Get status

```bash
$AIMI_CLI status
```

This returns JSON with status counts and story list. Extract completed stories (status = "completed") for the PR description.

## Step 3: Detect Parent Branch

Detect the base branch for the PR by finding the first decorated ancestor commit.

### 3a. Get current branch name

```bash
git rev-parse --abbrev-ref HEAD
```

Store as `$CURRENT_BRANCH`.

### 3b. Find parent branch via decorated ancestor

```bash
git log --pretty=format:'%D' --first-parent | grep -v '^$' | grep -v "HEAD" | grep -v "$CURRENT_BRANCH" | head -1
```

Parse the output to extract a branch name. The output may contain multiple refs separated by commas (e.g., `origin/main, main`). Extract the first local branch name (without `origin/` prefix). If the output contains `origin/branch-name`, strip the `origin/` prefix.

### 3c. Fallback to default branch

If no parent branch was detected in 3b, use the repository's default branch:

```bash
gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'
```

Store the result as `$BASE_BRANCH`.

### 3d. Validate branch name

The detected `$BASE_BRANCH` must match the pattern `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$`.

Validate:
```bash
echo "$BASE_BRANCH" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9/_-]*$'
```

If validation fails, report: "Invalid parent branch name detected: $BASE_BRANCH" and STOP.

## Step 4: Build PR Title and Description

### 4a. PR Title

Use `metadata.title` directly from Step 2a output. This is already in the correct `type(scope): subject` format.

### 4b. PR Description

Build the description following the default PR template.

**Get commit log between base and HEAD:**

```bash
git log --oneline "$BASE_BRANCH"..HEAD
```

**Assemble the PR body with these sections:**

- **Problem**: Derived from the metadata title (what this feature/change addresses)
- **Solution**: From the metadata title and story summary (high-level approach)
- **Stories Completed**: List of completed story IDs and titles from the status output (format: `- US-XXX: Story title`)
- **Changes**: From the `git log --oneline` output between base and HEAD (format each commit as a bullet)
- **Testing**: Story verification information from the status output (strategies used, pass/fail status)
- **Backend Implementation Spec** (conditional): Only included when `frontendOnly` is `true` AND `backendSpec` is not null. Rendered deterministically from the `backendSpec` metadata object (no LLM generation). Contains four subsections:

  #### `### Endpoints`
  A markdown table with columns: Method | Path | Description. Each row corresponds to an entry in `backendSpec.endpoints[]`.

  ```
  | Method | Path | Description |
  |--------|------|-------------|
  | POST | /api/example | Creates a new example |
  ```

  #### `### Data Models`
  A markdown table with columns: Name | Fields | Relationships. Each row corresponds to an entry in `backendSpec.dataModels[]`.

  ```
  | Name | Fields | Relationships |
  |------|--------|---------------|
  | Example | id, name, createdAt | belongs_to User |
  ```

  #### `### Business Rules`
  A bulleted list. Each item corresponds to an entry in `backendSpec.businessRules[]`.

  ```
  - Rule one
  - Rule two
  ```

  #### `### Business Context`
  Render `backendSpec.businessContext` as structured sub-sections. If `businessContext` is a plain string (legacy format), render as a single paragraph.

  When `businessContext` is an object:

  ```
  <businessContext.summary paragraph>

  **User Roles:** <comma-separated list from businessContext.userRoles[]>

  **Constraints:**
  - <item from businessContext.constraints[]>

  **Assumptions:**
  - <item from businessContext.assumptions[]>

  **Success Criteria:**
  - <item from businessContext.successCriteria[]>
  ```

  Omit any sub-section whose array is empty or absent.

## Step 5: Push Branch and Create PR

### 5a. Push branch to origin

Check if the branch needs pushing (not yet pushed or has unpushed commits):

```bash
git push -u origin "$CURRENT_BRANCH"
```

### 5b. Create the PR

Use HEREDOC for the body to handle multi-line content safely:

```bash
gh pr create --title "$PR_TITLE" --base "$BASE_BRANCH" --body "$(cat <<'EOF'
## Problem

<problem description from metadata title>

## Solution

<solution summary from stories>

## Stories Completed

- US-001: Story title
- US-002: Story title

## Changes

- <commit message 1>
- <commit message 2>

## Testing

- <verification info per story>

<if frontendOnly is true AND backendSpec is not null, append the following section>

## Backend Implementation Spec

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| <method> | <path> | <description> |

### Data Models

| Name | Fields | Relationships |
|------|--------|---------------|
| <name> | <fields> | <relationships> |

### Business Rules

- <rule from backendSpec.businessRules[]>

### Business Context

<backendSpec.businessContext.summary paragraph>

**User Roles:** <comma-separated from businessContext.userRoles[]>

**Constraints:**
- <item from businessContext.constraints[]>

**Assumptions:**
- <item from businessContext.assumptions[]>

**Success Criteria:**
- <item from businessContext.successCriteria[]>

<omit any sub-section whose array is empty or absent>
<if businessContext is a plain string (legacy), render as a single paragraph instead>

</if>
EOF
)"
```

**Important**: The Backend Implementation Spec section is rendered entirely from the `backendSpec` metadata object. No LLM generation is used — all content comes from deterministic template rendering of the structured data. When `frontendOnly` is `false` or absent, or when `backendSpec` is null, the section is omitted entirely and the PR body ends after the Testing section. If `businessContext` is a plain string (legacy format), render it as a single paragraph for backwards compatibility.

### 5c. Create backend issue and link to PR (conditional)

This step only runs when `frontendOnly` is `true` AND `backendSpec` is not null. If either condition is false, skip to Step 5d.

Build the issue body reusing the same Backend Implementation Spec template from Step 4b. The issue body contains the four subsections (Endpoints, Data Models, Business Rules, Business Context) rendered identically to the PR body section.

**Attempt to create the GitHub issue:**

```bash
if ISSUE_URL=$(gh issue create --title "Backend: $METADATA_TITLE" --body "$(cat <<'EOF'
## Backend Implementation Spec

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| <method> | <path> | <description> |

### Data Models

| Name | Fields | Relationships |
|------|--------|---------------|
| <name> | <fields> | <relationships> |

### Business Rules

- <rule from backendSpec.businessRules[]>

### Business Context

<backendSpec.businessContext.summary paragraph>

**User Roles:** <comma-separated from businessContext.userRoles[]>

**Constraints:**
- <item from businessContext.constraints[]>

**Assumptions:**
- <item from businessContext.assumptions[]>

**Success Criteria:**
- <item from businessContext.successCriteria[]>

<omit any sub-section whose array is empty or absent>
<if businessContext is a plain string (legacy), render as a single paragraph instead>
EOF
)" 2>/dev/null); then
  ISSUE_NUMBER=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')
  gh pr edit "$PR_URL" --body "$(cat <<EOF
$PR_BODY

---
Related issue: #$ISSUE_NUMBER
EOF
)"
  echo "Backend issue created: $ISSUE_URL (linked to PR)"
else
  echo "Warning: Could not create backend issue (permissions denied, issues disabled, or rate limit). The backend spec is still available in the PR body."
fi
```

Where `$METADATA_TITLE` is `metadata.title` from Step 2a, `$PR_URL` is the PR URL returned from Step 5b, and `$PR_BODY` is the original PR body from Step 4b.

**Important**: The `gh issue create` call is wrapped in an `if/then/else` block for graceful degradation. If the command fails (non-zero exit: permissions denied, issues disabled, rate limit), a warning is logged but PR creation is NOT affected — the backend spec still lives in the PR body (guaranteed by Step 5b). The `2>/dev/null` suppresses stderr from the failed command.

**On success**: The issue URL is captured, the issue number is extracted via `grep -oE '[0-9]+$'`, and `gh pr edit` appends a "Related issue: #N" link to the PR body.

**On failure**: A warning message is displayed and execution continues to Step 5d.

### 5d. Report success

Display the PR URL to the user:

```
PR created successfully: <url>
```
