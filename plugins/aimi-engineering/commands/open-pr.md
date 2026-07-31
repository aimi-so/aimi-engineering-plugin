---
name: aimi:open-pr
description: Open a pull request with title and description derived from git commits and diff
argument-hint: "[--branch <name>]"
disable-model-invocation: true
allowed-tools: Bash(git:*), Bash(AIMI_CLI=*), Bash($AIMI_CLI:*)
---

# Aimi Open PR

Automatically detect the parent branch, build the PR title and description from git commits and the diff against the base branch, and create a pull request via the `forge-pr-create` verb (`plugins/aimi-engineering/commands/references/forge-contract.md`) — GitHub is the only adapter this verb ships in phase 1.

## Project Conventions

This command does not read the working project's `CLAUDE.md` or `AGENTS.md`. The PR **body** is derived purely from git commits and the diff against the base branch (see Steps 2–4), with the internal `US-NNN` story tags stripped from every commit subject it renders (see Step 4b's story-tag strip). The PR **title** prefers the tasks file's feature-level `metadata.title` when one is available, falling back to the git-derived first-commit subject (see Step 4a) — this keeps the title describing the whole feature rather than the first story's slice. Both title and body strip the internal `US-NNN` story tags `/aimi:execute` writes per commit.

For project-specific PR structure (e.g., required Test Plan section, issue-link footer, checklists), use GitHub's standard mechanism:

- **`.github/pull_request_template.md`** — `gh pr create` honors this file automatically. Any template content is prepended to the body we build in Step 4b.

Commit-message conventions (Conventional Commits, etc.) are preserved automatically: the `metadata.title` source is itself authored in `type: description` form, and the first-commit-subject fallback preserves the subject verbatim apart from stripping the internal `US-NNN` story tag.

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

### 1a. Verify forge authentication

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
AUTH_STATUS_JSON=$($AIMI_CLI forge-auth-status)
echo "$AUTH_STATUS_JSON"
```

Branch on the printed JSON's `status` field. `forge-auth-status` reports exactly `found` or `error` — never `not_found` (see `commands/references/forge-contract.md`'s Three-Way Status Convention and `forge-auth-status`'s own found/error contract: the check either runs to a definitive true/false answer, or cannot run at all):

- `status == "found"` and `.data.authenticated == true`: authenticated. Continue to Step 1b exactly as today.
- `status == "found"` and `.data.authenticated == false`: a confirmed logged-out session. Report, naming the actual forge from `.data.forge` (never a hardcoded "GitHub CLI" string): "`<.data.forge>` CLI not authenticated. Run `gh auth login` first." and STOP.
- `status == "error"`: the authentication check itself could not run — `gh` missing from PATH, or no adapter for the detected forge. This step has no fallback, so the degradation must always surface (mandatory-print mode, `forge-contract.md`'s Degradation Contract — never the quiet mode `review.md`/`validate-bug.md` use where a fallback path already exists). Report `.message` verbatim (it already names the missing binary or the unsupported forge), prefixed with "Warning: ", plus "Install and authenticate a forge CLI for this repository, then re-run this command." and STOP.

No branch above may silently fall through to Step 2 as if authenticated.

### 1b. Check for existing PR on this branch

When `$CURRENT_BRANCH` is already set (from `--branch`), check that branch explicitly:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
PR_VIEW_JSON=$($AIMI_CLI forge-pr-view --pr "$CURRENT_BRANCH" --include url,number)
echo "$PR_VIEW_JSON"
```

Otherwise, check the currently checked-out branch. `forge-pr-view --pr` always requires an explicit ref — unlike plain `gh pr view`, it never defaults to whatever is checked out — so resolve it locally first:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
PR_VIEW_REF=$(git rev-parse --abbrev-ref HEAD)
PR_VIEW_JSON=$($AIMI_CLI forge-pr-view --pr "$PR_VIEW_REF" --include url,number)
echo "$PR_VIEW_JSON"
```

Branch on the printed JSON's `status` field (`found` | `not_found` | `error` — forge-contract.md's Three-Way Status Convention):

- `status == "found"`: an existing PR already exists. Report the PR URL (`.pr.url`) to the user and STOP (do not error — this is informational):
```
PR already exists for this branch: <url>
```
- `status == "not_found"`: no existing PR for this branch — fall through to Step 1c exactly as today.
- `status == "error"`: the existing-PR check itself could not complete — a missing forge CLI, broken auth, or a network failure. This step has no fallback either, so the same mandatory-print degradation as Step 1a applies. Report `.message` verbatim, prefixed with "Warning: existing-PR check could not complete: ", plus "Verify your forge CLI is installed and authenticated, then re-run this command." and STOP. Never treat this the same as `not_found` — a broken check must never be read as "no PR yet," since that would let a broken token proceed straight into creating a duplicate PR.

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

A bare HEAD read is not reliable here: after a container-mode `/aimi:execute` run, the **Main Working Tree Untouched Invariant** (`commands/references/container-execution.md:57`) means the main working tree was never checked out onto the feature branch, and Step 5's teardown (`container-execution.md:198`) removes the container with `--keep-branch`, leaving the feature branch checked out nowhere. HEAD stays parked on the base branch for the whole run — trusting it as-is would open a PR of the base branch against its own grandparent. Resolve both HEAD and the repository's default branch up front, then decide which one is actually the feature branch:

```bash
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
DEFAULT_BRANCH=$($AIMI_CLI detect-default-branch 2>/dev/null)
```

**Case A — HEAD is already on a real feature branch.** When `$CURRENT_BRANCH` is non-empty, is not the literal string `HEAD` (detached), and differs from `$DEFAULT_BRANCH`, reuse it unchanged — no behavior change from before:

```bash
: # CURRENT_BRANCH already holds the right value; nothing to do
```

**Case B — HEAD is on `$DEFAULT_BRANCH` (or detached).** This is the normal container-mode end state. Resolve the feature branch from the active tasks file's `metadata.branchName` instead of trusting HEAD:

```bash
CANDIDATE_BRANCH=$($AIMI_CLI metadata 2>/dev/null | jq -r '.branchName // empty' 2>/dev/null)
if [ -n "$CANDIDATE_BRANCH" ] && echo "$CANDIDATE_BRANCH" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9/_-]*$'; then
  CURRENT_BRANCH="$CANDIDATE_BRANCH"
else
  echo "Warning: No active tasks file found (or its branchName is missing/invalid) and HEAD is on $DEFAULT_BRANCH — proceeding with the checked-out branch, which may be the base branch itself." >&2
fi
```

This reuses the single guarded `$AIMI_CLI metadata` call already established at Step 4a for `.title`, rather than `commands/review.md`'s two-step `find-tasks` + separate `jq -r '.metadata.branchName'`. That is safe for the same reason `find-tasks` is safe: `cmd_metadata`'s `get_tasks_file` (`aimi-cli.sh:507`) never calls `init-session`, so it satisfies `commands/review.md:63`'s concurrent-session-safety rationale — it never repoints a live `/aimi:execute` session's tracked tasks file. Its only state write is the narrow self-heal path (`aimi-cli.sh:511-521`) that fires only when the recorded state pointer already points to a deleted file, correcting a broken pointer rather than clobbering a valid one.

Store the resolved value as `$CURRENT_BRANCH`.

**Why Step 1c's skip condition is not widened to cover this case:** at Step 1c's point in the flow, neither `$DEFAULT_BRANCH` nor the Case A/Case B outcome exist yet — both are computed here in Step 2a, which runs after 1c. Widening 1c's skip condition would require moving branch detection earlier, out of this story's scope. The check is also advisory-only (it warns, never stops) and vacuously harmless in container mode, since the Main Working Tree Untouched Invariant keeps the CWD clean throughout the run regardless.

### 2b. Detect parent branch via `detect-parent-branch`

Call the tested CLI verb instead of parsing decorations by hand — it already handles decoration parsing, `origin/` prefix normalization, and `git merge-base` verification internally, and owns the "no verified candidate" fallback (it returns the repository's default branch itself in that case).

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
PARENT_RESULT=$($AIMI_CLI detect-parent-branch "$CURRENT_BRANCH")
BASE_BRANCH=$(printf '%s' "$PARENT_RESULT" | jq -r '.base // empty')
PARENT_VERIFIED=$(printf '%s' "$PARENT_RESULT" | jq -r '.verified // false')
```

Store as `$BASE_BRANCH` and `$PARENT_VERIFIED`. Note `.base` is the resolved parent branch — `.branch` in the response is merely an echo of the input `$CURRENT_BRANCH` and must never be read here.

When `$PARENT_VERIFIED` is not `true` (the candidate could not be confirmed via `git merge-base`, or no decoration candidate existed and the verb fell back to the default branch), print an explicit warning naming the unverified candidate before continuing — do not silently proceed as if the value were trustworthy:

```
Warning: could not verify "$BASE_BRANCH" as the true parent branch of "$CURRENT_BRANCH" (git merge-base check failed or no candidate found). Proceeding with this value as the PR base — double-check it before merging.
```

Execution continues regardless of `$PARENT_VERIFIED`; Step 2d's regex validation is the only hard STOP gate on `$BASE_BRANCH`.

### 2c. Fallback when the CLI call itself failed

`detect-parent-branch` already owns the "no verified candidate" case internally (see 2b) — this step is **not** a second "no parent found" handler. It exists only as defense-in-depth for the narrower case where the CLI call in 2b itself failed or produced no output (e.g., `$AIMI_CLI` resolution broke, the process exited non-zero, or the JSON could not be parsed) and `$BASE_BRANCH` is still empty here:

```bash
if [ -z "$BASE_BRANCH" ]; then
  AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
  : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
  BASE_BRANCH=$($AIMI_CLI detect-default-branch)
fi
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

Derive a **feature-level** PR title — one that describes the whole change, not just the first story's slice, and that never leaks an internal `US-NNN` story tag from the per-story commits `/aimi:execute` produces. Three sources, in order of preference:

1. **Tasks metadata title.** When a tasks file exists for this session, `metadata.title` is the human-authored feature title (e.g. `feat: brownfield foundation gate + architecture-foundation skill (issue #56 phase 3)`) — the best PR title, since it summarizes the entire feature rather than whichever story happened to commit first. Read it with the same guarded `$AIMI_CLI metadata` call Step 4c uses; any failure (no tasks file, CLI error) falls through to source 2.
2. **First commit subject, story-tag stripped.** Fall back to the first commit subject on the branch (preserving conventional-commit form), then strip any trailing aimi story tag the execute flow appends per story (e.g. a trailing ` — US-001` / ` - Story US-012a`, or a leading `US-001 `), so the internal id never reaches the public title.
3. **Branch name.** When the branch has zero commits ahead of base, fall back to `$CURRENT_BRANCH`.

```bash
# Source 1: feature-level metadata title (guarded, like Step 4c). The
# `metadata` subcommand emits the metadata object itself, so the title is at
# the top level (`.title`), not nested under `.metadata`.
METADATA_TITLE=$($AIMI_CLI metadata 2>/dev/null | jq -r '.title // empty' 2>/dev/null)
# Ignore story-merge's pre-patch skeleton placeholder — never a real title.
if [ "$METADATA_TITLE" = "feat: merged tasks" ]; then
  METADATA_TITLE=""
fi

if [ -n "$METADATA_TITLE" ]; then
  PR_TITLE="$METADATA_TITLE"
else
  # Source 2: first commit subject, with any internal story tag stripped.
  PR_TITLE=$(git log "$BASE_BRANCH".."$CURRENT_BRANCH" --reverse --pretty=format:'%s' --no-merges | head -1)
  PR_TITLE=$(printf '%s' "$PR_TITLE" | sed -E \
    -e 's/[[:space:]]*(—|–|-)[[:space:]]*(Story[[:space:]]+)?US-[0-9]{3}[a-z]?[[:space:]]*$//' \
    -e 's/^(Story[[:space:]]+)?US-[0-9]{3}[a-z]?[[:space:]:—–-]+//')
  # Source 3: branch name when there are no commits ahead of base.
  if [ -z "$PR_TITLE" ]; then
    PR_TITLE="$CURRENT_BRANCH"
  fi
fi
```

Store as `$PR_TITLE`.

### 4b. PR Description

Build the description from git state with three core sections:

- **Summary**: Aggregated commit bodies from `$COMMIT_LOG`. Split records by the ASCII record separator (`%x1e`), then split each record's fields by the unit separator (`%x1f`) into `hash`, `subject`, `body`. Concatenate the non-empty `body` fields into a single prose block. If every commit body is empty, concatenate the commit **subjects** instead — apply the **story-tag strip** below to each subject first.
- **Changes**: Each commit **subject** (the second field from every record) rendered as a bullet, one per line — apply the **story-tag strip** below to each subject before rendering.
- **Files Changed**: The `$DIFF_STAT` output rendered inside a fenced code block.

**Story-tag strip (applies to every commit subject used in the body).** The per-story commits `/aimi:execute` produces carry an internal `US-NNN` tag in their subject (e.g. a trailing ` — US-001`, ` - Story US-012a`, or a leading `US-003 `). Strip that tag from each subject before it appears in the **Changes** bullets or the **Summary** subject-fallback, so the internal id never leaks into the public PR body — the identical rule Step 4a already applies to the title. The commit **bodies** (the Summary's primary source) are used verbatim; the tag lives only in subjects, so only subjects are stripped. Per subject `$s`:

```bash
s_clean=$(printf '%s' "$s" | sed -E \
  -e 's/[[:space:]]*(—|–|-)[[:space:]]*(Story[[:space:]]+)?US-[0-9]{3}[a-z]?[[:space:]]*$//' \
  -e 's/^(Story[[:space:]]+)?US-[0-9]{3}[a-z]?[[:space:]:—–-]+//')
```

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

Render the body into a captured shell variable first — `$PR_BODY` — instead of embedding a HEREDOC directly as the `--body` argument, then call `forge-pr-create` with that variable plus the title, base, and head values. The Summary/Changes/Files Changed sections always appear. The Backend Implementation Spec section is appended only when `$INCLUDE_BACKEND_SPEC=1`:

```bash
PR_BODY=$(cat <<'EOF'
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
)

AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
PR_CREATE_JSON=$($AIMI_CLI forge-pr-create --title "$PR_TITLE" --base "$BASE_BRANCH" --head "$CURRENT_BRANCH" --body "$PR_BODY")
PR_STATUS=$(printf '%s' "$PR_CREATE_JSON" | jq -r '.status // empty' 2>/dev/null)
if [ "$PR_STATUS" != "created" ] && [ "$PR_STATUS" != "unchanged" ]; then
  echo "Error: forge-pr-create reported status ${PR_STATUS:-<none>} — see the manual create-it-yourself instructions above (mandatory-print degradation, forge-contract.md's Degradation Contract)." >&2
  exit 1
fi
PR_URL=$(printf '%s' "$PR_CREATE_JSON" | jq -r '.data.url')
PR_NUMBER=$(printf '%s' "$PR_CREATE_JSON" | jq -r '.data.number')
echo "PR_URL=$PR_URL"
echo "PR_NUMBER=$PR_NUMBER"
echo "--- PR_BODY (verbatim, for Step 5c to re-derive) ---"
echo "$PR_BODY"
echo "--- end PR_BODY ---"
```

`forge-pr-create` returns `forge-contract.md`'s write-verb envelope — `{status, data: {url, number}, message}` with `status` one of `created`, `unchanged`, or `degraded` (Write-Verb Status Convention). `unchanged` means an open PR already existed for this branch and was reused rather than duplicated; both it and `created` carry a usable `data.url`/`data.number`, which is why the check above accepts either and treats everything else — a `degraded` envelope, or no envelope at all — as the failure case.

If `forge-pr-create` itself exits non-zero (an unsupported forge, a missing `gh` binary, or the `gh pr create` call failing), it has already printed manual create-it-yourself instructions to stderr — mandatory-print degradation, `forge-contract.md`'s Degradation Contract, since opening a PR has no other fallback — **and** now emits a `status: "degraded"` envelope on stdout carrying the same reason in its `message` field. The exit code is unchanged; the envelope is an additional in-band signal, not a replacement for it. Report those instructions to the user and STOP.

**Important**: The Backend Implementation Spec section is rendered entirely from the `backendSpec` metadata object. No LLM generation is used — all content comes from deterministic template rendering of the structured data. When `$INCLUDE_BACKEND_SPEC=0` (no tasks file, `frontendOnly` is false, or `backendSpec` is null), the section is omitted entirely and the PR body ends after the Files Changed section. If `businessContext` is a plain string (legacy format), render it as a single paragraph for backwards compatibility.

### 5c. Create backend issue and link to PR (conditional)

This step only runs when `$INCLUDE_BACKEND_SPEC=1` (from Step 4c). If false, skip to Step 5d.

Re-assign `PR_URL`, `PR_NUMBER`, and `PR_BODY` at the top of this block from the exact literal values Step 5b's block printed — each Bash tool call is its own shell, so nothing Step 5b assigned survives into this one (the same convention `$CURRENT_BRANCH`/`$AIMI_CLI` already use at the start of later steps in this file):

```bash
PR_URL="[the PR_URL value Step 5b printed]"
PR_NUMBER="[the PR_NUMBER value Step 5b printed]"
PR_BODY=$(cat <<'PR_BODY_EOF'
[paste Step 5b's printed PR_BODY here, verbatim — the text between its "--- PR_BODY ---" and "--- end PR_BODY ---" markers]
PR_BODY_EOF
)
```

Build the issue body reusing the same Backend Implementation Spec template from Step 4c. The issue body contains the four subsections (Endpoints, Data Models, Business Rules, Business Context) rendered identically to the PR body section.

**Attempt to create the backend issue and link it to the PR:**

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
if [ "$INCLUDE_BACKEND_SPEC" = "1" ]; then
  ISSUE_BODY=$(cat <<'EOF'
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
)
  ISSUE_CREATE_JSON=$($AIMI_CLI forge-issue-create --title "Backend: $METADATA_TITLE" --body "$ISSUE_BODY")
  ISSUE_STATUS=$(printf '%s' "$ISSUE_CREATE_JSON" | jq -r '.status')
  if [ "$ISSUE_STATUS" = "created" ]; then
    ISSUE_URL=$(printf '%s' "$ISSUE_CREATE_JSON" | jq -r '.data.url')
    ISSUE_NUMBER=$(printf '%s' "$ISSUE_CREATE_JSON" | jq -r '.data.number')
    PR_EDIT_JSON=$($AIMI_CLI forge-pr-edit --number "$PR_NUMBER" --body "$(cat <<EOF
$PR_BODY

---
Related issue: #$ISSUE_NUMBER
EOF
)")
    echo "Backend issue created: $ISSUE_URL (linked to PR)"
  else
    echo "Warning: Could not create backend issue (permissions denied, issues disabled, or rate limit). The backend spec is still available in the PR body."
  fi
fi
```

Where `$METADATA_TITLE` is `metadata.title` from Step 4c, and `$PR_NUMBER`/`$PR_BODY` are the values re-assigned above from Step 5b's printed output.

**Important**: `forge-issue-create` is a soft-fail verb — it always exits `0` and reports `created` or `degraded` in the `status` field of `forge-contract.md`'s shared write-verb envelope (`commands/references/forge-contract.md`, Write-Verb Status Convention), so the `if`/`else` above branches on that field, never on a bare exit code. A `degraded` result (permissions denied, issues disabled, rate limit, missing forge CLI, or an unsupported forge) means the issue was not created automatically — a warning is logged but PR creation is NOT affected, since the backend spec still lives in the PR body (guaranteed by Step 5b). `forge-issue-create` itself already prints the manual "create this yourself" instructions to stderr on a `degraded` result (mandatory-print degradation), so no separate STOP is needed here. `forge-pr-edit` emits that same envelope and shares `forge-pr-create`'s own mandatory-print/non-zero-exit contract — the shared shape deliberately does NOT mean a shared exit-code contract, and this verb's always-`0` exit is exactly what keeps a failed backend issue from blocking the PR. If `forge-pr-edit` fails, its own manual fallback instructions are already on stderr (alongside its `degraded` envelope on stdout); the issue is still created and linked in every other respect.

**On success**: The issue URL and number are read from the envelope's nested `data.url` and `data.number` fields — the same nesting `forge-pr-create` and `forge-pr-edit` use, and the `grep -oE '[0-9]+$'` derivation is gone — and `forge-pr-edit` appends a "Related issue: #N" link to the PR body.

**On failure (degraded)**: A warning message is displayed and execution continues to Step 5d.

### 5d. Report success

Display the PR URL to the user:

```
PR created successfully: <url>
```
