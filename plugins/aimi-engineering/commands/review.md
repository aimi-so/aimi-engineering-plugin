---
name: aimi:review
description: Perform code reviews using parallel aimi-native review agents
argument-hint: "[PR number, GitHub URL, branch name, or latest]"
---

# Aimi Review

Perform code reviews using parallel aimi-native review agents with findings synthesis.

## Step 1: Determine Review Target

<review_target> #$ARGUMENTS </review_target>

### Detect Default Branch

Before any diff commands, detect the repository's default branch:

```bash
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
if [ -z "$DEFAULT_BRANCH" ]; then
  DEFAULT_BRANCH="main"
fi
```

Use `$DEFAULT_BRANCH` in all subsequent git diff commands instead of a hardcoded branch name.

### Detect Current Branch

```bash
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
```

### Resolve $AIMI_CLI

Unconditional — every item below (PR number, GitHub URL, and the Setup section's changed-files lookup) needs `$AIMI_CLI` regardless of which target type is detected, not only the empty-argument path. Resolve the CLI path using the four-layer strategy. Each check is a separate Bash call (no compound operators).

**Layer 0: AIMI_PLUGIN_DIR (env var override)**

```bash
if [ -z "${CLAUDECODE:-}" ] && [ -n "$AIMI_PLUGIN_DIR" ] && [ "${AIMI_PLUGIN_DIR#/}" != "$AIMI_PLUGIN_DIR" ] && [ -d "$AIMI_PLUGIN_DIR" ] && [ -x "$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh" ]; then AIMI_CLI="$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh"; fi
```

**Layer 1: Global cache (fast path)**

```bash
if [ -z "$AIMI_CLI" ]; then AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null); fi
```

**Layer 1 validation: verify cached path exists and is executable**

```bash
if [ -n "$AIMI_CLI" ] && [ ! -x "$AIMI_CLI" ]; then AIMI_CLI=""; fi
```

**Layer 2: Glob fallback (zsh-safe)**

```bash
if [ -z "$AIMI_CLI" ]; then AIMI_CLI=$(bash -c 'ls ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1'); fi
```

**Layer 2 cache update: save for next time**

```bash
if [ -n "$AIMI_CLI" ]; then _aimi_cfg="${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}"; mkdir -p "$_aimi_cfg" && printf '%s\n' "$AIMI_CLI" > "$_aimi_cfg/cli-path.tmp" && mv "$_aimi_cfg/cli-path.tmp" "$_aimi_cfg/cli-path" && chmod 600 "$_aimi_cfg/cli-path"; fi
```

**Layer 3: Per-project fallback (last resort)**

```bash
if [ -z "$AIMI_CLI" ] && [ -f .aimi/cli-path ] && [ -x "$(cat .aimi/cli-path)" ]; then AIMI_CLI=$(cat .aimi/cli-path); fi
```

If `$AIMI_CLI` is still empty after all layers, report the error and STOP:
- If `$AIMI_PLUGIN_DIR` is set: "aimi-cli.sh not found. Check AIMI_PLUGIN_DIR path: $AIMI_PLUGIN_DIR"
- Otherwise: "aimi-cli.sh not found. Reinstall plugin: `/plugin install aimi-engineering`"

**Run version check:**

```bash
$AIMI_CLI check-version --quiet --fix
```

### Detect Target Type

1. **PR number** (numeric): Fetch PR with `forge-pr-view` (`--include` is a comma-separated field selector — see `commands/references/forge-contract.md`; `files` is dropped here since nothing at this step consumes it). Runs in `forge-pr-view`'s built-in quiet degrade mode, so a missing/unauthenticated `gh` yields `status: "error"` with no stderr banner — the git-diff fallback documented in Error Handling below is what actually surfaces that to the user:

   ```bash
   AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
   : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
   PR_JSON=$($AIMI_CLI forge-pr-view --pr "$ARGUMENTS" --include title,body,headRefName,baseRefName)
   ```

   Branch on `PR_JSON`'s `status` field (`found` | `not_found` | `error` — forge-contract.md's Three-Way Status Convention): on `found`, read `.pr.title`/`.pr.body`/`.pr.headRefName`/`.pr.baseRefName`; on `not_found` or `error`, fall through to the git-diff comparison the same way a missing `gh` does (see Error Handling below).
2. **GitHub URL**: Extract the PR number, then fetch with the same `forge-pr-view` call as item 1, substituting the extracted number for `$ARGUMENTS`.
3. **Branch name**: Validate `$ARGUMENTS` against `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$` before it is ever interpolated into a git command — the same check Case B step 4 below applies to `$CANDIDATE_BRANCH`:

   ```bash
   if ! echo "$ARGUMENTS" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9/_-]*$'; then
     echo "Error: Invalid branch name: $ARGUMENTS" >&2
     exit 1
   fi
   ```

   Then compare against default branch with `git diff $DEFAULT_BRANCH...$ARGUMENTS --name-only`
4. **Empty** (no arguments): Resolve `$REVIEW_BRANCH` per **Resolve Review Branch (Empty Argument)** below, then compare with `git diff $DEFAULT_BRANCH...$REVIEW_BRANCH --name-only`

### Resolve Review Branch (Empty Argument)

Only runs when `$ARGUMENTS` is empty (Detect Target Type item 4). It determines `$REVIEW_BRANCH` without assuming `$CURRENT_BRANCH` is the feature branch — HEAD parked on `$DEFAULT_BRANCH` is the normal end state after a container-mode or phase-mode `/aimi:execute` run, since the main working tree is never checked out onto the feature branch in either mode.

**Case A — HEAD is already on a real feature branch.** When `$CURRENT_BRANCH` is non-empty, is not the literal string `HEAD` (detached), and differs from `$DEFAULT_BRANCH`, reuse it unchanged — no behavior change from before:

```bash
REVIEW_BRANCH="$CURRENT_BRANCH"
```

**Case B — HEAD is on `$DEFAULT_BRANCH` (or detached).** Resolve the target from the active tasks file's `metadata.branchName` instead of diffing against `HEAD`:

1. Resolve `$AIMI_CLI` by following the **Resolve CLI Path** and **Version Check** sections of `commands/references/cli-path-resolution.md`.
2. Discover the active tasks file with the **read-only** lookup only — never `$AIMI_CLI init-session`, which writes `.aimi/state/current-tasks` and `.aimi/state/current-branch` as a side effect and could repoint a concurrently running `/aimi:execute` session's tracked tasks file:

   ```bash
   TASKS_FILE=$($AIMI_CLI find-tasks 2>/dev/null)
   ```

3. When `$TASKS_FILE` is non-empty, read its branch name:

   ```bash
   CANDIDATE_BRANCH=$(jq -r '.metadata.branchName // empty' "$TASKS_FILE" 2>/dev/null)
   ```

4. Validate `$CANDIDATE_BRANCH` against `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$` before it is ever interpolated into a git command:

   ```bash
   if [ -n "$CANDIDATE_BRANCH" ] && echo "$CANDIDATE_BRANCH" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9/_-]*$'; then
     REVIEW_BRANCH="$CANDIDATE_BRANCH"
   fi
   ```

5. **Fallback.** When `$TASKS_FILE` is empty (no tasks file discoverable), `$CANDIDATE_BRANCH` is empty, or validation fails, do not proceed with an unvalidated value — fall back to the checked-out branch and warn:

   ```bash
   REVIEW_BRANCH="$CURRENT_BRANCH"
   ```

   ```
   Warning: No active tasks file found (or its branchName is missing/invalid) and HEAD is on $DEFAULT_BRANCH — nothing to review.
   ```

Track whether `$REVIEW_BRANCH` was resolved from the tasks file (i.e. `$REVIEW_BRANCH` != `$CURRENT_BRANCH`) — Step 5's report surfaces this so the user is never confused about what was diffed.

### Setup

```bash
# Get changed files
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
PR_FILES_JSON=$($AIMI_CLI forge-pr-view --pr [number] --include files)
echo "$PR_FILES_JSON" | jq -r '.pr.files[].path'
# OR for branch comparison (REVIEW_BRANCH is $ARGUMENTS for the explicit
# branch-name path in item 3 above, or the value resolved by "Resolve Review
# Branch (Empty Argument)" when no argument was given):
git diff $DEFAULT_BRANCH...$REVIEW_BRANCH --name-only
```

Read the changed files to understand the PR content. Collect the diff for agent context.

### Prototype Design Context (optional)

If the PR's branch has a matching brainstorm document under `.aimi/brainstorms/` (semantic match on feature name, within 30 days) **or** the current branch name appears in a tasks file with a `metadata.brainstormPath`, parse the brainstorm for prototype references and load them as design context for reviewers:

1. Parse frontmatter for a `prototype:` key (path string or YAML list).
2. Scan the brainstorm body for a `## Prototype` heading and extract `.html` paths.
3. Read the sibling `.aimi/brainstorms/prototypes/<topic-slug>-tokens.json` if present.
4. Pass the prototype HTML content and tokens JSON to the architecture, simplicity, and language-specific reviewers as a `<design_reference>` block. Reviewers compare the implementation's visual/structural fidelity against the chosen variant and the target-project tokens.

If no matching brainstorm is found, skip this step silently — it is additive context, never a precondition.

### Protected Artifacts

These paths must never be flagged for deletion or removal by any review agent:
- `.aimi/plans/*.md` — Plan files
- `.aimi/solutions/*.md` — Solution documents
- `.aimi/tasks/*.json` — Task files
- `.aimi/brainstorms/*.md` — Brainstorm documents
- `.aimi/research/*.md` — Research output files

## Step 1.5: Resolve Agent Models

Read and follow the **Resolve Agent Models** section of `commands/references/cli-path-resolution.md` to populate `AGENT_MODELS`. When resolution fails, treat every category as `"inherit"` and continue.

## Step 2: Run Default Review Agents (Parallel)

Run these agents **in parallel** using the Task tool:

```
Task subagent_type="aimi-engineering:review:aimi-architecture-strategist"
  [model: <AGENT_MODELS.review when not "inherit">]
  prompt: "Review this code for architectural compliance:
           [PR content / diff summary]"

Task subagent_type="aimi-engineering:review:aimi-security-sentinel"
  [model: <AGENT_MODELS.review when not "inherit">]
  prompt: "Perform security audit on this code:
           [PR content / diff summary]"

Task subagent_type="aimi-engineering:review:aimi-code-simplicity-reviewer"
  [model: <AGENT_MODELS.review when not "inherit">]
  prompt: "Review this code for simplicity and minimalism:
           [PR content / diff summary]"

Task subagent_type="aimi-engineering:review:aimi-performance-oracle"
  [model: <AGENT_MODELS.review when not "inherit">]
  prompt: "Analyze this code for performance issues:
           [PR content / diff summary]"

Task subagent_type="aimi-engineering:review:aimi-agent-native-reviewer"
  [model: <AGENT_MODELS.review when not "inherit">]
  prompt: "Verify new features are agent-accessible:
           [PR content / diff summary]"

Task subagent_type="aimi-engineering:research:aimi-learnings-researcher"
  [model: <AGENT_MODELS.research when not "inherit">]
  prompt: "Search .aimi/solutions/ for past issues related to this PR:
           [PR content / diff summary]"
```

## Step 3: Run Conditional Agents (If Applicable)

### Migration Agents

**Run ONLY when PR contains database migrations, schema changes, or data backfills.**

Detection: Check if changed files include `db/migrate/*.rb`, `db/schema.rb`, migration scripts, or data backfill tasks.

```
Task subagent_type="aimi-engineering:review:aimi-schema-drift-detector"
  [model: <AGENT_MODELS.review when not "inherit">]
  prompt: "Detect unrelated schema.rb changes:
           [PR content / diff summary]"

Task subagent_type="aimi-engineering:review:aimi-data-migration-expert"
  [model: <AGENT_MODELS.review when not "inherit">]
  prompt: "Validate ID mappings and migration safety:
           [PR content / diff summary]"

Task subagent_type="aimi-engineering:review:aimi-deployment-verification-agent"
  [model: <AGENT_MODELS.review when not "inherit">]
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

### Design Fidelity Agent (Conditional)

Automatically invoke the design-implementation reviewer when the tasks file signals a visual story with prototype references.

**Trigger gate** — both conditions must be true:

1. `jq -r '.metadata.prototypePaths // empty' $TASKS_FILE` returns a non-empty value
2. `jq -r '[.userStories[] | select(.verification.strategy == "visual")] | length' $TASKS_FILE` returns a value greater than 0

If either condition fails (e.g., pre-1.73.0 tasks files that lack `metadata.prototypePaths`, or no story uses `verification.strategy: "visual"`), skip this section entirely — no agent is spawned.

**agent-browser availability check** — before spawning any Task, verify the browser tool is installed:

```
command -v agent-browser
```

If the command returns non-zero, log the following warning and skip all invocations in this section:

```
Design fidelity review skipped: agent-browser not installed
```

**Per-visual-story invocation** — when the gate passes and `agent-browser` is available, spawn one Task per visual story (stories where `verification.strategy == "visual"`):

- `prototype_path`: use `story.implementation.prototypeAnchor` if present; otherwise use the first prototype path cited in the story's acceptance criteria; otherwise fall back to the first entry of `metadata.prototypePaths`.
- `live_url`: use `story.verification.url` when present; omit the field otherwise.

```
Task subagent_type="aimi-engineering:design:aimi-design-implementation-reviewer"
  [model: <AGENT_MODELS.design when not "inherit">]
  prompt: "Compare the implementation against the design prototype and report visual fidelity drift.
           Story ID: [story.id]
           Story title: [story.title]
           prototype_path: [resolved prototype_path — see derivation rule above]
           live_url: [story.verification.url or omit if absent]"
```

Findings from this agent are emitted at the same severity levels (P1/P2/P3) as all other review agents.

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
**Branch:** [$REVIEW_BRANCH — the branch actually diffed]<if the empty-argument fallback resolved $REVIEW_BRANCH from the active tasks file and it differs from $CURRENT_BRANCH, append: " (resolved from the active tasks file; the working tree is on $CURRENT_BRANCH)">

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
- Design Fidelity (conditional)
- [other conditional agents if run]

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
| `forge-pr-view` reports `status: "error"` (e.g. gh CLI not installed) | Fall back to git diff for branch comparison |
| Empty arguments, HEAD on `$DEFAULT_BRANCH` (or detached), no active tasks file discoverable (or its `branchName` is missing/invalid) | Fall back to `$CURRENT_BRANCH`; warn "nothing to review" (see Resolve Review Branch (Empty Argument)) |
