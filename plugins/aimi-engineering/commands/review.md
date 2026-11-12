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

Unconditional — every item below (PR number, GitHub URL, and the Setup section's changed-files lookup) needs `$AIMI_CLI` regardless of which target type is detected, not only the empty-argument path. Resolve the CLI path using the layered strategy. Each check is a separate Bash call (no compound operators).

**Layer 0-dev: AIMI_DEV_DIR (development override, any host)**

Consulted first, and unlike Layer 0 below it carries no `CLAUDECODE` gate: `AIMI_DEV_DIR` names a checkout the operator is deliberately testing, not another host's install. The fifth check refuses a path under `/.worktrees/`, the same refusal `write_global_cli_cache` applies — a worktree copy vanishes on cleanup. Canonical rule: `references/cli-path-resolution.md`.

```bash
if [ -n "$AIMI_DEV_DIR" ] && [ "${AIMI_DEV_DIR#/}" != "$AIMI_DEV_DIR" ] && [ -d "$AIMI_DEV_DIR" ] && [ -x "$AIMI_DEV_DIR/scripts/aimi-cli.sh" ] && [ "${AIMI_DEV_DIR#*/.worktrees/}" = "$AIMI_DEV_DIR" ]; then AIMI_CLI="$AIMI_DEV_DIR/scripts/aimi-cli.sh"; fi
```

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
each candidate carries its own version segment and `sort -V` keys on that. The
`grep` is load-bearing too: `sort -V` ranks a directory that is not a version
at all, and ranks it above the real ones — a sibling named `1.124.0.bak` wins
without it. Canonical rule: `_resolve_latest_cache_path` in `aimi-cli.sh`,
inlined here because it lives inside the file this block is still looking for.

```bash
if [ -z "$AIMI_CLI" ]; then AIMI_CLI=$(bash -c 'ls ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | sed -E "s#.*/aimi-engineering/([^/]+)/.*#\1 &#" | grep -E "^[0-9]+\.[0-9]+\.[0-9]+ " | sort -V | tail -1 | cut -d" " -f2-'); fi
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

### Read the Request

The request is free text. Read it once and split it into three things:

- **TARGET:** a PR number, a PR URL, a branch name, or nothing. There may be several. A URL names its repository on the forge: review it in the local folder whose `origin` remote (`git -C <dir> remote get-url origin`) points at that repository, the current one or a sibling under the `.aimi/` root. A number or branch alone belongs to the current repository. A URL no local folder matches is not reviewed: say which one, and go on with the others.
- **SCOPE:** `diff-only` when the person asks for the diff alone ("only the diff", "somente o diff"); otherwise `diff-and-affected-code`.
- **FOCUS:** what to look for, if stated: bugs, security, performance, simplicity or structure, project conventions. Empty when none is stated.

A bare word that is not a number, a URL or an existing branch (`git show-ref --verify --quiet refs/heads/<word>`, then `refs/remotes/origin/<word>`) is a FOCUS, not a TARGET. The blocks below show the request where they use it: put the TARGET alone there (the digits for a PR, the branch name for a branch) before running one, as item 2 already does for a URL. Their same-block checks stay as they are.

### Detect Target Type

1. **PR number** (numeric): fetch the PR with `forge-pr-view` (`--include` selects fields; see `commands/references/forge-contract.md`). A missing or unauthenticated `gh` yields `status: "error"` with no stderr banner, and the git-diff fallback in Error Handling covers it:

   `$ARGUMENTS` is validated as digits-only **in the same block that interpolates it**: each fenced block runs in its own shell, so a gate in an earlier block cannot stop this one. Keep the `case` form (`docs/dev/review.md` § Why the gates sit where they do).

   ```bash
   AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
   : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
   PR_PROJECT="[the folder of this PR's repository, or . for the current one]"
   case "$ARGUMENTS" in
     ''|*[!0-9]*)
       echo "Error: Invalid PR number: $ARGUMENTS" >&2
       exit 1
       ;;
   esac
   case "$PR_PROJECT" in
     ''|*[!A-Za-z0-9._/-]*|*..*)
       echo "Error: Invalid repository folder: $PR_PROJECT" >&2
       exit 1
       ;;
   esac
   PR_JSON=$($AIMI_CLI forge-pr-view --pr "$ARGUMENTS" --project "$PR_PROJECT" --include title,body,headRefName,baseRefName)
   ```

   This gate is defense-in-depth, not the only line of defense — `forge-pr-view` validates its own `--pr` value against a fixed regex before it reaches any `gh` command, which is what covers a value crafted to break out of the quoting in the gate line itself.

   Branch on `PR_JSON`'s `status` field (`found` | `not_found` | `error` — forge-contract.md's Three-Way Status Convention): on `found`, read `.pr.title`/`.pr.body`/`.pr.headRefName`/`.pr.baseRefName`; on `not_found` or `error`, fall through to the git-diff comparison the same way a missing `gh` does (see Error Handling below).
2. **PR URL**: Extract the PR number from the URL, assign that extracted number into `$ARGUMENTS` and the URL's local folder into `PR_PROJECT`, then run item 1's block **unchanged** — the same validation gates and the same `forge-pr-view` call — once per URL. Do NOT write a second, parallel `forge-pr-view` invocation or a raw forge CLI call for this case: item 1's block is the single gated path to that command, and re-entering it is what makes the URL case inherit its checks instead of skipping them.
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

Only runs when `$ARGUMENTS` is empty (Detect Target Type item 4). It finds `$REVIEW_BRANCH` without assuming HEAD is the feature branch: after a container-mode or phase-mode `/aimi:execute` run HEAD is parked on the base branch, or on another feature branch when the run was stacked, so the test is whether HEAD differs from the branch the active tasks file names, not from `$DEFAULT_BRANCH`.

1. Resolve `$AIMI_CLI` by following the **Resolve CLI Path** and **Version Check** sections of `commands/references/cli-path-resolution.md`.
2. Read the active tasks file's branch name with the guarded `$AIMI_CLI metadata` call that `commands/open-pr.md` Case B uses. It is read-only: it never calls `init-session`, so it cannot repoint a live `/aimi:execute` session.

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

**Case B — HEAD is not the branch the tasks file names.** A valid `$CANDIDATE_BRANCH` differs from `$CURRENT_BRANCH`, whether HEAD is parked on `$DEFAULT_BRANCH` or on another feature branch under a stacked run:

```bash
if [ -n "$CANDIDATE_BRANCH" ] && echo "$CANDIDATE_BRANCH" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9/_-]*$' && [ "$CANDIDATE_BRANCH" != "$CURRENT_BRANCH" ]; then
  echo "Resolved feature branch from the active tasks file: $CANDIDATE_BRANCH (HEAD was on $CURRENT_BRANCH)" >&2
  REVIEW_BRANCH="$CANDIDATE_BRANCH"
fi
```

The correction is reported to stderr, naming both branches, and never applied silently: the branch it replaces can itself look like a feature branch.

Track whether `$REVIEW_BRANCH` was resolved from the tasks file (i.e. `$REVIEW_BRANCH` != `$CURRENT_BRANCH`) — Step 5's report surfaces this so the user is never confused about what was diffed.

### Setup

```bash
# Get changed files
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
PR_FILES_JSON=$($AIMI_CLI forge-pr-view --pr [number] --project [folder of the PR, as in item 1] --include files)
echo "$PR_FILES_JSON" | jq -r '.pr.files[].path'
# OR for branch comparison (REVIEW_BRANCH is the branch-name TARGET of item 3
# above, or the value resolved by "Resolve Review Branch (Empty Argument)"
# when no target was given):
git diff $DEFAULT_BRANCH...$REVIEW_BRANCH --name-only
```

Keep the list of changed files: it chooses the reviewers in Step 2. The reviewers read the code themselves.

### Where the Reviewers Read

For each repository under review (the one you are in, or one per sibling repository when the request spans several), settle three values:

- **WORKDIR:** the checkout where the reviewed revision is checked out (`git worktree list --porcelain`). If none holds it, create nothing: use the repository root and tell the reviewers to read with `git show REVISION:path`.
- **REVISION:** the commit or ref under review.
- **DIFF_CMD:** the command that prints the diff, such as `git diff <base>...<head>`. The reviewers run it.

With two repositories (a frontend and a backend, say), run Steps 2 to 5 once per repository, and give the correctness reviewer the other one's WORKDIR and DIFF_CMD as RELATED, so a contract broken across the two is visible.

### Prototype Design Context (optional)

If the PR's branch has a matching brainstorm document under `.aimi/brainstorms/` (semantic match on feature name, within 30 days) **or** the current branch name appears in a tasks file with a `metadata.brainstormPath`, parse the brainstorm for prototype references and load them as design context for reviewers:

1. Parse frontmatter for a `prototype:` key (path string or YAML list).
2. Scan the brainstorm body for a `## Prototype` heading and extract `.html` paths.
3. Read the sibling `.aimi/brainstorms/prototypes/<topic-slug>-tokens.json` if present.
4. Pass the prototype HTML path and the tokens JSON path to the correctness and maintainability reviewers as `DESIGN_REFERENCE` (paths, not content). They compare the implementation's structure and behavior against the chosen variant and the target-project tokens.

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

## Step 2: Choose the Reviewers

Pick from this table. Step 3's message that starts the reviewers opens with this block as text, before its first Task call; a message with no tool call would end the turn and stop the run:

```
Team for [repository]:
- [reviewer]: [why it runs, from the table]
- Not run: [subject the FOCUS left out, or a conditional row whose subject is not in the diff], [why]
```

| Reviewer | With no FOCUS, it runs when |
|----------|-----------------------------|
| `aimi-correctness-reviewer`, `aimi-security-reviewer`, `aimi-performance-reviewer`, `aimi-maintainability-reviewer` | always |
| `aimi-project-standards-reviewer` | a `CLAUDE.md`, `AGENTS.md` or `CODING_STANDARDS.md` exists at or above a changed file |
| `aimi-frontend-races-reviewer` | changed browser UI code waits on a timer, a request, an event or a subscription |
| `aimi-agent-native-reviewer` | the diff changes an agent tool definition, an MCP configuration or a prompt the product builds |
| `aimi-data-migration-reviewer` | the diff adds or changes a migration, a schema definition or a backfill |
| `aimi-deployment-verification-agent` | the data-migration reviewer runs and existing data is dropped, renamed, retyped, constrained or rewritten |
| `aimi-learnings-researcher` | `.aimi/solutions/` holds files, whatever the FOCUS |
| `aimi-design-implementation-reviewer` | the Design Fidelity gate below passes |
| a review agent the target project defines | the session lists it and it reviews code |

With a FOCUS, run only the rows whose subject it names: bugs, correctness; vulnerabilities, security; speed or scale, performance; simplicity, duplication or structure, maintainability; conventions, project-standards. A conditional row still needs its subject in the diff. A FOCUS no row matches goes to the correctness reviewer, and you say so.

## Step 3: Run the Reviewers

Run the chosen reviewers **in parallel** with the Task tool, one per repository. While they run, a reviewer that finishes gets one short progress line at most (how many are done), never its findings: the report states them once, checked. The prompt carries data lines only; the reviewer runs `DIFF_CMD` and reads the code itself:

```
Task subagent_type="aimi-engineering:review:[REVIEWER]"
  [model: <AGENT_MODELS.review when not "inherit">]
  prompt: "REPO: [repository name]
           WORKDIR: [absolute path of the checkout]
           REVISION: [commit or ref under review]
           DIFF_CMD: [command that prints the diff]
           SCOPE: [diff-only | diff-and-affected-code]
           FOCUS: [the stated focus, or none]
           INTENT: [one line: what the change is for, from the PR title, the branch name or the person's words]
           PROJECT_GUIDELINES: [absolute paths of the CLAUDE.md and AGENTS.md that govern the changed files, or none]
           RELATED: [the other repository's WORKDIR and DIFF_CMD, for the correctness reviewer only, or none]
           DESIGN_REFERENCE: [prototype and tokens paths from Prototype Design Context, or none]
           FILES: [changed files to read first, for the second pass in Step 4 only, or none]"
```

The learnings researcher is `Task subagent_type="aimi-engineering:research:aimi-learnings-researcher"` with `[model: <AGENT_MODELS.research when not "inherit">]` and the prompt "Search .aimi/solutions/ for past issues related to: [INTENT and the changed file paths]".

### Design Fidelity Agent (Conditional)

Automatically invoke the design-implementation reviewer when the tasks file signals a visual story with prototype references.

**Trigger gate** — both conditions must be true:

1. `jq -r '.metadata.prototypePaths // empty' $TASKS_FILE` returns a non-empty value
2. `$AIMI_CLI verification-report --tasks-file $TASKS_FILE | jq '.visual | length'` returns a value greater than 0 (the verb `/aimi:execute` Step 0.7 uses; it type-checks `verification`, so a malformed one counts zero and never aborts)

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

## Step 4: Check the Findings and Consolidate

1. **Cover what nobody read.** From the reviewers' lists of files read, take the changed files no reviewer read, leaving out tests, generated files, lockfiles and fixtures. When one of them adds 100 lines or more, run the correctness reviewer once more for that repository with `FILES` naming the largest of them, five at most, and treat its findings like the others.
2. Collect the findings of every reviewer. Surface the learnings researcher's results: flag relevant past solutions as "Known Pattern", with links to the `.aimi/solutions/` files. Merge duplicates, meaning findings with the same cause or the same line, and keep the highest severity. Discard any finding that recommends deleting a protected artifact (see Protected Artifacts).
3. **Check before reporting.** For every P1 and P2, read the quoted line at its `path:line`, then check the premise the finding rests on: the guard it says is missing, the caller it says exists, the rule it cites, the concurrency guarantee it assumes. Four tool calls at most for each. Check a P3 too when two reads settle it. Drop what the code does not support and count it. When a finding holds but one of its claims does not, remove that claim and say so. Mark each finding you keep:
   - `Checked: yes` when the code confirms the line and the premise;
   - `Checked: pattern present, effect not measured` when it confirms both, and the finding claims a speed, a race or an exploit that only running the code would measure;
   - `Checked: no (reason)` when the check needs running code or more calls than allowed, never for a check two reads settle. An unchecked P1 keeps its severity and this mark.
4. Categorize:
   - **P1 CRITICAL:** blocks merge: security vulnerabilities, data corruption risks, breaking changes.
   - **P2 IMPORTANT:** should fix: defects with limited reach, performance issues, structural problems.
   - **P3 NICE-TO-HAVE:** enhancements: minor improvements, cleanup.

   A severity that rests on a rule the project does not write down (a size limit, a convention) is P3.
5. Estimate effort for each finding: Small (< 30 min), Medium (30 min - 2 hours), Large (> 2 hours).

## Step 5: Aimi-Branded Report

```
## Review Complete

**Review Target:** [PR title or branch name]
**Branch:** [$REVIEW_BRANCH — the branch actually diffed]<if the empty-argument fallback resolved $REVIEW_BRANCH from the active tasks file and it differs from $CURRENT_BRANCH, append: " (resolved from the active tasks file; the working tree is on $CURRENT_BRANCH)">
**Focus:** [FOCUS, or none] · **Scope:** [SCOPE]

### Findings Summary

- **Total Findings:** [X] ([N] dropped after checking)
- **P1 CRITICAL:** [count] - BLOCKS MERGE
- **P2 IMPORTANT:** [count] - Should Fix
- **P3 NICE-TO-HAVE:** [count] - Enhancements

### P1 - Critical (Must Fix Before Merge)

1. **[Finding title]** — [description]
   - Location: [file:line]
   - Impact: [what breaks]
   - Fix: [how to fix]
   - Effort: [Small/Medium/Large]
   - Checked: [yes | pattern present, effect not measured | no (reason)]

### P2 - Important (Should Fix)

1. **[Finding title]** — [description]
   - Location: [file:line]
   - Recommendation: [how to improve]
   - Effort: [Small/Medium/Large]
   - Checked: [as above]

### P3 - Nice-to-Have

1. **[Finding title]** — [description]
   - Suggestion: [improvement]
   - Checked: [as above]

### Review Agents Used

- [each reviewer that ran, with its repository when there were several]
- Not run: [each subject the FOCUS left out, or none]
- Not read by any reviewer: [changed source files no reviewer read, after the second pass, or none]

### Next Steps

1. **Fix the P1 findings** — they block the merge
2. **Fix the P2 findings, or record each one as an accepted risk**
3. **Track the P3 findings as follow-up work**
```

**Fresh session hint:** After the Next Steps, tell the person, in one sentence in their language, that this run's state is saved under `.aimi/` and that starting the next command in a fresh session (`/clear`) loses nothing and makes each of its turns cheaper. Skip it in agent mode.

## Error Handling

| Failure | Action |
|---------|--------|
| No review target found | Ask user to specify PR number or branch |
| Agent fails | Proceed with available results, note in report |
| No changed files | Report "No changes to review" |
| The reviewed branch is checked out nowhere | Create nothing; the reviewers read with `git show REVISION:path` and the diff (see Where the Reviewers Read) |
| A FOCUS that no reviewer matches | Run the correctness reviewer and say so |
| `forge-pr-view` reports `status: "error"` (e.g. gh CLI not installed) | Fall back to git diff for branch comparison |
| Empty arguments, no active tasks file discoverable (or its `branchName` is missing/invalid) | Fall back to `$CURRENT_BRANCH`; warn (see Resolve Review Branch (Empty Argument)) |
