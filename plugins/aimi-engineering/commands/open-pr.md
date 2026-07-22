---
name: aimi:open-pr
description: Open a pull request with title and description derived from git commits and diff
argument-hint: "[--branch <name>]"
disable-model-invocation: true
allowed-tools: Bash(gh:*), Bash(git:*), Bash(AIMI_CLI=*), Bash($AIMI_CLI:*)
---

# Aimi Open PR

Automatically detect the parent branch, build the PR title and description from git commits and the diff against the base branch, and create a pull request via `gh pr create`.

## Project Conventions

This command does not read the working project's `CLAUDE.md` or `AGENTS.md`. PR title and body are derived purely from git commits and the diff against the base branch (see Steps 2–4).

For project-specific PR structure (e.g., required Test Plan section, issue-link footer, checklists), use GitHub's standard mechanism:

- **`.github/pull_request_template.md`** — `gh pr create` honors this file automatically. Any template content is prepended to the body we build in Step 4b.

Commit-message conventions (Conventional Commits, etc.) are preserved automatically because Step 4a derives the PR title from the first commit subject.

## Step 0: Resolve CLI Path

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/cli-path-resolution.md` and follow the **Resolve CLI Path** and **Version Check** sections to set `$AIMI_CLI`. Each layer is a separate Bash call.

If resolution fails, report error and STOP.

Use `$AIMI_CLI` for all subsequent script calls.

## Step 1: Pre-flight Checks

Run these checks before proceeding. STOP on failure unless noted.

### Parse --branch Argument

Scan `$ARGUMENTS` for an explicit `--branch <name>` token (mirrors the `--phase <N>` extraction style used by `/aimi:execute`). A bare `--branch` (no value) and `--branch=<name>` (equals form, not supported — use the space-separated form) must both hard-stop rather than silently falling through to Step 2a's HEAD-branch resolution the same way an omitted `--branch` does:

```bash
case " $ARGUMENTS " in
  *" --branch="*)
    echo "Error: --branch requires a value." >&2
    echo "Use '--branch <name>' (space-separated) — '--branch=<name>' is not supported." >&2
    exit 1
    ;;
  *" --branch "*)
    CURRENT_BRANCH=$(echo "$ARGUMENTS" | sed -n 's/.*--branch[[:space:]]\+\([^ ]*\).*/\1/p')
    if [ -z "$CURRENT_BRANCH" ]; then
      echo "Error: --branch requires a value." >&2
      exit 1
    fi
    ;;
  *)
    CURRENT_BRANCH=""
    ;;
esac
```

If `$CURRENT_BRANCH` is non-empty, validate it before any other `git`/`gh` call:

```bash
echo "$CURRENT_BRANCH" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9/_-]*$'
```

If validation fails, report `Invalid --branch value: $CURRENT_BRANCH` and STOP.

When `--branch` was not passed, `$CURRENT_BRANCH` stays empty here — Step 2a resolves it from the current checked-out branch as before.

### 1a. Verify GitHub CLI authentication

```bash
gh auth status
```

If this fails, report: "GitHub CLI not authenticated. Run `gh auth login` first." and STOP.

### 1b. Check for existing PR on this branch

When `$CURRENT_BRANCH` is already set (from `--branch`), check that branch explicitly:

```bash
gh pr view "$CURRENT_BRANCH" --json url --jq '.url' 2>/dev/null
```

Otherwise, check the currently checked-out branch:

```bash
gh pr view --json url --jq '.url' 2>/dev/null
```

If this succeeds (exit code 0), an existing PR already exists. Report the PR URL to the user and STOP (do not error — this is informational):
```
PR already exists for this branch: <url>
```

### 1c. Warn about uncommitted changes

**Skip this step entirely when `$CURRENT_BRANCH` is already set (from `--branch`)** — this check inspects the CWD working tree, which is irrelevant for a branch checked out elsewhere or nowhere.

```bash
git status --porcelain
```

If output is non-empty, warn the user:
```
Warning: You have uncommitted changes. Consider committing before opening a PR.
```

Continue execution (do not stop).

## Step 2: Read Git Commits and Diff

Build the PR from git state directly — commits and diff against the base branch — instead of relying on tasks.json.

### 2a. Get current branch

**Skip this step entirely when `$CURRENT_BRANCH` is already set (from `--branch`)** — reuse that value instead of resolving HEAD.

```bash
git rev-parse --abbrev-ref HEAD
```

Store as `$CURRENT_BRANCH`.

### 2b. Detect parent branch via decorated ancestor

```bash
git log "$CURRENT_BRANCH" --pretty=format:'%D' --first-parent | grep -v '^$' | grep -v "HEAD" | grep -v "$CURRENT_BRANCH" | head -1
```

Parse the output to extract a branch name. The output may contain multiple refs separated by commas (e.g., `origin/main, main`). Extract the first local branch name (without `origin/` prefix). If the output contains `origin/branch-name`, strip the `origin/` prefix.

### 2c. Fallback to default branch

If no parent branch was detected in 2b, use the repository's default branch:

```bash
gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'
```

Store the result as `$BASE_BRANCH`.

### 2d. Validate base branch name

The detected `$BASE_BRANCH` must match the pattern `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$`.

```bash
echo "$BASE_BRANCH" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9/_-]*$'
```

If validation fails, report: "Invalid parent branch name detected: $BASE_BRANCH" and STOP.

### 2e. Capture full commit log

Capture every non-merge commit on the branch with hash, subject, and body separated by ASCII unit separators (`%x1f`), one commit per record terminated by an ASCII record separator (`%x1e`). This lets the renderer split records cleanly even when commit bodies contain newlines:

```bash
COMMIT_LOG=$(git log "$BASE_BRANCH".."$CURRENT_BRANCH" --pretty=format:'%H%x1f%s%x1f%b%x1e' --no-merges)
```

Store as `$COMMIT_LOG`.

### 2f. Capture diff summary and file list

```bash
DIFF_STAT=$(git diff --stat "$BASE_BRANCH".."$CURRENT_BRANCH")
FILES_CHANGED=$(git diff --name-only "$BASE_BRANCH".."$CURRENT_BRANCH")
```

Store as `$DIFF_STAT` and `$FILES_CHANGED`.

## Step 4: Build PR Title and Description

### 4a. PR Title

Derive the PR title from the first commit subject on the branch (preserving conventional-commit form). When the branch has zero commits ahead of base, fall back to `$CURRENT_BRANCH`:

```bash
PR_TITLE=$(git log "$BASE_BRANCH".."$CURRENT_BRANCH" --reverse --pretty=format:'%s' --no-merges | head -1)
if [ -z "$PR_TITLE" ]; then
  PR_TITLE="$CURRENT_BRANCH"
fi
```

Store as `$PR_TITLE`.

### 4b. PR Description

Build the description from git state with three core sections:

- **Summary**: Aggregated commit bodies from `$COMMIT_LOG`. Split records by the ASCII record separator (`%x1e`), then split each record's fields by the unit separator (`%x1f`) into `hash`, `subject`, `body`. Concatenate the non-empty `body` fields into a single prose block. If every commit body is empty, concatenate the commit subjects instead.
- **Changes**: Each commit subject (the second field from every record) rendered as a bullet, one per line.
- **Files Changed**: The `$DIFF_STAT` output rendered inside a fenced code block.

### 4c. Backend Implementation Spec (conditional)

Only include this section when ALL of the following are true:

1. A tasks file exists for the current session (`$AIMI_CLI metadata` exits 0), AND
2. `metadata.frontendOnly` is `true`, AND
3. `metadata.backendSpec` is not null.

Resolve the metadata guardedly. Any failure (no tasks file, CLI error, missing fields) silently omits this section and PR creation continues:

```bash
$AIMI_CLI metadata 2>/dev/null || true
```

Capture the JSON output (if any). Parse it directly from the result:

- If the CLI exits non-zero or emits no output, set `INCLUDE_BACKEND_SPEC=0` and skip this section entirely.
- Otherwise read `metadata.frontendOnly`, `metadata.backendSpec`, and `metadata.title` from the JSON.
- Set `INCLUDE_BACKEND_SPEC=1` only when `frontendOnly` is exactly `true` AND `backendSpec` is a non-null object.
- Store `metadata.title` as `$METADATA_TITLE` for use in Step 5c.

When `$INCLUDE_BACKEND_SPEC=1`, render the spec deterministically from `metadata.backendSpec` (no LLM generation). Contains four subsections:

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

Works unchanged for a branch not checked out anywhere, as long as the local ref exists — `git push` does not require checkout.

```bash
git push -u origin "$CURRENT_BRANCH"
```

### 5b. Create the PR

Use HEREDOC for the body to handle multi-line content safely. The Summary/Changes/Files Changed sections always appear. The Backend Implementation Spec section is appended only when `$INCLUDE_BACKEND_SPEC=1`:

```bash
gh pr create --title "$PR_TITLE" --base "$BASE_BRANCH" --head "$CURRENT_BRANCH" --body "$(cat <<'EOF'
## Summary

<aggregated commit bodies from $COMMIT_LOG (fallback to concatenated subjects if all bodies empty)>

## Changes

- <commit subject 1>
- <commit subject 2>

## Files Changed

```
<$DIFF_STAT output>
```

<if $INCLUDE_BACKEND_SPEC=1, append the following section>

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

**Important**: The Backend Implementation Spec section is rendered entirely from the `backendSpec` metadata object. No LLM generation is used — all content comes from deterministic template rendering of the structured data. When `$INCLUDE_BACKEND_SPEC=0` (no tasks file, `frontendOnly` is false, or `backendSpec` is null), the section is omitted entirely and the PR body ends after the Files Changed section. If `businessContext` is a plain string (legacy format), render it as a single paragraph for backwards compatibility.

### 5c. Create backend issue and link to PR (conditional)

This step only runs when `$INCLUDE_BACKEND_SPEC=1` (from Step 4c). If false, skip to Step 5d.

Build the issue body reusing the same Backend Implementation Spec template from Step 4c. The issue body contains the four subsections (Endpoints, Data Models, Business Rules, Business Context) rendered identically to the PR body section.

**Attempt to create the GitHub issue:**

```bash
if [ "$INCLUDE_BACKEND_SPEC" = "1" ]; then
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
fi
```

Where `$METADATA_TITLE` is `metadata.title` from Step 4c, `$PR_URL` is the PR URL returned from Step 5b, and `$PR_BODY` is the original PR body from Step 5b.

**Important**: The `gh issue create` call is wrapped in an `if/then/else` block for graceful degradation. If the command fails (non-zero exit: permissions denied, issues disabled, rate limit), a warning is logged but PR creation is NOT affected — the backend spec still lives in the PR body (guaranteed by Step 5b). The `2>/dev/null` suppresses stderr from the failed command.

**On success**: The issue URL is captured, the issue number is extracted via `grep -oE '[0-9]+$'`, and `gh pr edit` appends a "Related issue: #N" link to the PR body.

**On failure**: A warning message is displayed and execution continues to Step 5d.

### 5d. Report success

Display the PR URL to the user:

```
PR created successfully: <url>
```
