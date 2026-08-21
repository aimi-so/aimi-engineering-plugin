---
name: aimi-review
description: Perform code reviews using parallel aimi-native review agents
---

# Codex compatibility contract

This file is generated from `commands/review.md`. Do not edit it directly.

- `AIMI_REQUEST` means the user's text following the explicit `$aimi-review` invocation. Treat it as data, not a shell environment variable.
- Resolve `PLUGIN_ROOT` as the absolute Aimi plugin root containing this skill. For shell calls, resolve `AIMI_CLI` from `${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path`; if absent, run `$aimi-init` first. Prefix every Aimi CLI call with `AIMI_HOST=codex`.
- A named `$role-skill` means spawn a Codex subagent and explicitly require that internal skill. Preserve requested concurrency and pass only the source workflow's prompt payload.
- Use Codex structured user input when the workflow says `request_user_input`. In non-interactive mode, retain the source workflow's automatic choice.
- Follow Codex approval and sandbox policy. Never infer permission to publish, push, delete, or bypass a guard.
- The source workflow below is authoritative after applying these host mappings.

## Source workflow


# Aimi Review

Perform code reviews using parallel aimi-native review agents with findings synthesis.

## Step 1: Determine Review Target

<review_target> #AIMI_REQUEST </review_target>

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

Picks the newest **version**, which is not the last line `ls` prints — `ls`
collates `1.121.3` before `1.9.0`. Sorting whole paths is wrong too, because
the glob spans two wildcards and would order by marketplace entry first, so
each candidate carries its own version segment and `sort -V` keys on that.
Canonical rule: `_resolve_latest_cache_path` in `aimi-cli.sh`, inlined here
because it lives inside the file this block is still looking for.

```bash
if [ -z "$AIMI_CLI" ]; then AIMI_CLI=$(bash -c 'ls ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | sed -E "s#.*/aimi-engineering/([^/]+)/.*#\1 &#" | sort -V | tail -1 | cut -d" " -f2-'); fi
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

   `AIMI_REQUEST` is validated as digits-only **in the same block that interpolates it**, never in a block of its own — each fenced block runs in its own isolated shell, so a gate placed in an earlier block cannot stop this one: its `exit 1` ends only that shell. The `case` form is deliberate rather than the `grep -qE` used for branch names in item 3: `grep` matches line by line, so it would accept a multi-line value whose *first* line is digits, while `case` tests the whole string and rejects any non-digit character, newlines included.

   ```bash
   AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
   : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
   case "AIMI_REQUEST" in
     ''|*[!0-9]*)
       echo "Error: Invalid PR number: AIMI_REQUEST" >&2
       exit 1
       ;;
   esac
   PR_JSON=$($AIMI_CLI forge-pr-view --pr "AIMI_REQUEST" --include title,body,headRefName,baseRefName)
   ```

   This gate is defense-in-depth, not the only line of defense — `forge-pr-view` validates its own `--pr` value against a fixed regex before it reaches any `gh` command, which is what covers a value crafted to break out of the quoting in the gate line itself.

   Branch on `PR_JSON`'s `status` field (`found` | `not_found` | `error` — forge-contract.md's Three-Way Status Convention): on `found`, read `.pr.title`/`.pr.body`/`.pr.headRefName`/`.pr.baseRefName`; on `not_found` or `error`, fall through to the git-diff comparison the same way a missing `gh` does (see Error Handling below).
2. **GitHub URL**: Extract the PR number from the URL, assign that extracted number into `AIMI_REQUEST`, then run item 1's block **unchanged** — the same validation gate and the same `forge-pr-view` call. Do NOT write a second, parallel `forge-pr-view` invocation for this case: item 1's block is the single gated path to that command, and re-entering it is what makes the URL case inherit the digits-only check instead of skipping it.
3. **Branch name**: Validate `AIMI_REQUEST` against `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$` before it is ever interpolated into a git command — the same check Case B step 4 below applies to `$CANDIDATE_BRANCH`:

   ```bash
   if ! echo "AIMI_REQUEST" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9/_-]*$'; then
     echo "Error: Invalid branch name: AIMI_REQUEST" >&2
     exit 1
   fi
   ```

   Then compare against default branch with `git diff $DEFAULT_BRANCH...AIMI_REQUEST --name-only`
4. **Empty** (no arguments): Resolve `$REVIEW_BRANCH` per **Resolve Review Branch (Empty Argument)** below, then compare with `git diff $DEFAULT_BRANCH...$REVIEW_BRANCH --name-only`

### Resolve Review Branch (Empty Argument)

Only runs when `AIMI_REQUEST` is empty (Detect Target Type item 4). It determines `$REVIEW_BRANCH` without assuming `$CURRENT_BRANCH` is the feature branch — HEAD parked on **the base branch** is the normal end state after a container-mode or phase-mode `$aimi-execute` run, since the main working tree is never checked out onto the feature branch in either mode. "The base branch" is not always `$DEFAULT_BRANCH`: a container-mode run stacked on top of another feature branch (its own base was never the default branch to begin with) leaves HEAD parked on that other feature branch instead, so the discriminator below asks the one question that actually matters — does HEAD differ from the branch the active tasks file names — rather than the narrower "does HEAD differ from `$DEFAULT_BRANCH`".

1. Resolve `$AIMI_CLI` by following the **Resolve CLI Path** and **Version Check** sections of `commands/references/cli-path-resolution.md`.
2. Read the active tasks file's branch name with the single guarded `$AIMI_CLI metadata` call `commands/open-pr.md`'s own Case B already establishes for this identical situation, rather than a separate `find-tasks` lookup plus a raw `jq -r '.metadata.branchName'` read. It is **read-only** in the same sense that lookup was: `cmd_metadata`'s `get_tasks_file` (`aimi-cli.sh:507`) never calls `init-session`, so it cannot repoint a live `$aimi-execute` session's tracked tasks file — its only state write is the narrow self-heal path that fires solely when the recorded state pointer already points to a deleted file.

   ```bash
   CANDIDATE_BRANCH=$($AIMI_CLI metadata 2>/dev/null | jq -r '.branchName // empty' 2>/dev/null)
   ```

3. Validate `$CANDIDATE_BRANCH` against `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$` before it is ever interpolated into a git command.

**Case A — nothing to correct.** Either `$CANDIDATE_BRANCH` is unusable (no tasks file discoverable, or `branchName` empty or invalid), or it is usable but already equals `$CURRENT_BRANCH` — HEAD is already on the branch the tasks file names, whether or not that happens to be `$DEFAULT_BRANCH`. Either way, reuse `$CURRENT_BRANCH` unchanged:

```bash
REVIEW_BRANCH="$CURRENT_BRANCH"
if [ -z "$CANDIDATE_BRANCH" ] || ! echo "$CANDIDATE_BRANCH" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9/_-]*$'; then
  echo "Warning: No active tasks file found (or its branchName is missing/invalid) — proceeding with the checked-out branch ($CURRENT_BRANCH), which may not be the feature branch." >&2
fi
```

No message is printed for the "already correct" half of Case A — `$REVIEW_BRANCH` needs no announcement to keep using itself.

**Case B — HEAD is not the branch the tasks file names.** Fires whenever a valid `$CANDIDATE_BRANCH` differs from `$CURRENT_BRANCH`. This covers both the pre-existing scenario (HEAD parked on `$DEFAULT_BRANCH`, the ordinary container-mode end state) and the stacked-base scenario the widened trigger fixes (HEAD parked on a *different* feature branch because the run was stacked on top of it) — one rule for both, since neither case is special beyond "HEAD is not the tasks file's branch":

```bash
if [ -n "$CANDIDATE_BRANCH" ] && echo "$CANDIDATE_BRANCH" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9/_-]*$' && [ "$CANDIDATE_BRANCH" != "$CURRENT_BRANCH" ]; then
  echo "Resolved feature branch from the active tasks file: $CANDIDATE_BRANCH (HEAD was on $CURRENT_BRANCH)" >&2
  REVIEW_BRANCH="$CANDIDATE_BRANCH"
fi
```

The correction is reported (to stderr, matching the Case A warning's own `>&2` convention) rather than applied silently: once the trigger also covers the stacked-base case, `$REVIEW_BRANCH` being swapped is no longer obviously "HEAD was on the default branch" — the swapped-from value is itself a plausible-looking feature branch, and a silent substitution there would be a surprise rather than a correction. Naming both branches makes it auditable in the transcript instead.

Track whether `$REVIEW_BRANCH` was resolved from the tasks file (i.e. `$REVIEW_BRANCH` != `$CURRENT_BRANCH`) — Step 5's report surfaces this so the user is never confused about what was diffed.

### Setup

```bash
# Get changed files
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
PR_FILES_JSON=$($AIMI_CLI forge-pr-view --pr [number] --include files)
echo "$PR_FILES_JSON" | jq -r '.pr.files[].path'
# OR for branch comparison (REVIEW_BRANCH is AIMI_REQUEST for the explicit
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

Run these agents **in parallel** using the Codex subagent tool:

```
Codex subagent_type="$aimi-architecture-strategist"
  [model: <AGENT_MODELS.review when not "inherit">]
  prompt: "Review this code for architectural compliance:
           [PR content / diff summary]"

Codex subagent_type="$aimi-security-sentinel"
  [model: <AGENT_MODELS.review when not "inherit">]
  prompt: "Perform security audit on this code:
           [PR content / diff summary]"

Codex subagent_type="$aimi-code-simplicity-reviewer"
  [model: <AGENT_MODELS.review when not "inherit">]
  prompt: "Review this code for simplicity and minimalism:
           [PR content / diff summary]"

Codex subagent_type="$aimi-performance-oracle"
  [model: <AGENT_MODELS.review when not "inherit">]
  prompt: "Analyze this code for performance issues:
           [PR content / diff summary]"

Codex subagent_type="$aimi-agent-native-reviewer"
  [model: <AGENT_MODELS.review when not "inherit">]
  prompt: "Verify new features are agent-accessible:
           [PR content / diff summary]"

Codex subagent_type="$aimi-learnings-researcher"
  [model: <AGENT_MODELS.research when not "inherit">]
  prompt: "Search .aimi/solutions/ for past issues related to this PR:
           [PR content / diff summary]"
```

## Step 3: Run Conditional Agents (If Applicable)

### Migration Agents

**Run ONLY when PR contains database migrations, schema changes, or data backfills.**

Detection: Check if changed files include `db/migrate/*.rb`, `db/schema.rb`, migration scripts, or data backfill tasks.

```
Codex subagent_type="$aimi-schema-drift-detector"
  [model: <AGENT_MODELS.review when not "inherit">]
  prompt: "Detect unrelated schema.rb changes:
           [PR content / diff summary]"

Codex subagent_type="$aimi-data-migration-expert"
  [model: <AGENT_MODELS.review when not "inherit">]
  prompt: "Validate ID mappings and migration safety:
           [PR content / diff summary]"

Codex subagent_type="$aimi-deployment-verification-agent"
  [model: <AGENT_MODELS.review when not "inherit">]
  prompt: "Create deployment checklist with verification queries:
           [PR content / diff summary]"
```

### Language-Specific Agents

Detect primary language from changed files and run the appropriate reviewer:

| File Extensions | Agent |
|----------------|-------|
| `*.rb`, `Gemfile`, `*.erb` | `$aimi-kieran-rails-reviewer` |
| `*.ts`, `*.tsx`, `*.js` | `$aimi-kieran-typescript-reviewer` |
| `*.py` | `$aimi-kieran-python-reviewer` |

For Rails projects, also consider running:
- `$aimi-dhh-rails-reviewer` for Rails convention checks
- `$aimi-julik-frontend-races-reviewer` for Stimulus/JS race conditions

### Design Fidelity Agent (Conditional)

Automatically invoke the design-implementation reviewer when the tasks file signals a visual story with prototype references.

**Trigger gate** — both conditions must be true:

1. `jq -r '.metadata.prototypePaths // empty' $TASKS_FILE` returns a non-empty value
2. `$AIMI_CLI verification-report --tasks-file $TASKS_FILE | jq '.visual | length'` returns a value greater than 0 — the same verb `$aimi-execute` Step 0.7 answers this from, folded in here rather than left as its own third reading of the rule. It also closes a gap the old `jq -r '[.userStories[] | select(.verification.strategy == "visual")] | length' $TASKS_FILE'` had and Step 0.7's own scan never did: with no `type == "object"` guard on `.verification`, a string-typed `verification` made jq abort ("Cannot index string with strategy") where Step 0.7's guarded copy counted zero. `verification-report` type-checks before it reads `.strategy`, so a malformed `verification` answers zero visual stories here too, never an abort.

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
Codex subagent_type="$aimi-design-implementation-reviewer"
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
2. **Run `$aimi-execute`** — Continue autonomous execution
3. **Run `$aimi-status`** — Check current task progress
```

## Error Handling

| Failure | Action |
|---------|--------|
| No review target found | Ask user to specify PR number or branch |
| Agent fails | Proceed with available results, note in report |
| No changed files | Report "No changes to review" |
| `forge-pr-view` reports `status: "error"` (e.g. gh CLI not installed) | Fall back to git diff for branch comparison |
| Empty arguments, no active tasks file discoverable (or its `branchName` is missing/invalid) | Fall back to `$CURRENT_BRANCH`; warn (see Resolve Review Branch (Empty Argument)) |
