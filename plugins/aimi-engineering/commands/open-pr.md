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

This returns JSON with task metadata. Extract `metadata.title` — it is already in `type(scope): subject` format and will be used as the PR title.

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
EOF
)"
```

### 5c. Report success

Display the PR URL to the user:

```
PR created successfully: <url>
```
