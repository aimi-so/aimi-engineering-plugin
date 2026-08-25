---
name: aimi:open-pr
description: Open a pull request with title and description derived from git commits and diff
argument-hint: "[--branch <name>]"
disable-model-invocation: true
allowed-tools: Bash(git:*), Bash(AIMI_CLI=*), Bash($AIMI_CLI:*)
---

# Aimi Open PR

Automatically detect the parent branch, build the PR title and description from git commits and the diff against the base branch, and create a pull request via the `forge-pr-create` verb (`plugins/aimi-engineering/commands/references/forge-contract.md`) — GitHub, GitLab and Gitea/Forgejo each have an adapter for this verb today.

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

#### Select the acting forge account for this repository

Step 1a has just established that a forge exists for this repository and that its adapter is authenticated — the two preconditions that make the account question meaningful at all. Settle here, once per repository ever, which account should author this repository's forge writes.

Resolve interactivity and ask the CLI whether the question is warranted, in one call:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
INTERACTIVE_MODE=$($AIMI_CLI detect-interactivity)
ACCOUNT_CHECK_JSON=$($AIMI_CLI forge-account-select --check)
echo "$INTERACTIVE_MODE"
echo "$ACCOUNT_CHECK_JSON"
```

`detect-interactivity` prints exactly `picker` or `agent`, and `picker` is the default — `agent` comes only from an explicit opt-out (`--non-interactive`, `AIMI_AGENT_MODE=true`, `CI=true`). A non-TTY shell is **not** a signal for agent mode; see `commands/references/interactivity.md`, which is the arbiter for mode resolution, option format and the agent-mode rule for this site.

Ask **only** when `INTERACTIVE_MODE` is `picker` AND `ACCOUNT_CHECK_JSON`'s `.decision` is `"ask"` — the same two-condition AND the first-run model prompt already uses (`commands/references/cli-path-resolution.md`: `detect-interactivity == picker` AND `models-prompt-check == prompt`, otherwise proceed silently). `forge-account-select --check` is the sole owner of the second condition: it reports `"ask"` only when this repository has no recorded answer *for its own host* and this project's git identity and the active forge account actually diverge. It decides on this repository's own entry, never on the store file's existence, so a store that already holds other repositories' answers still asks here. Every other outcome reports `"skip"` — `.basis` of `answer_recorded`, `identity_override`, `no_repository`, `no_host`, `single_account`, `identity_matches_active`, `not_authenticated`, `cli_missing`, or `no_adapter` — and this subsection then does nothing at all: no picker, no output, straight on to Step 1b. `--check` writes nothing, so evaluating it never changes what a later run will ask.

**When `INTERACTIVE_MODE=picker` and `.decision == "ask"`:** Use **AskUserQuestion**, building the options from `ACCOUNT_CHECK_JSON`:

```
Which account should author this repository's pull requests and issues on [host]?

A — Always use the active account ([activeAccount])
B — [the divergence candidate]
C/D/E — [further logged-in accounts, in the order .accounts lists them]
Other — Enter a different account login
```

- **Option A** is deliberately the least disruptive answer, and it is the one agent mode auto-picks below: every write stays on whichever account is active, now and in future.
- **Option B** is the divergence candidate — the login in `.accounts` that this repository's own git identity points at and that is not `.activeAccount`. Derive it from `.identity.email`: a `…@users.noreply.github.com` address encodes the login exactly (dropping any leading `<digits>+`); otherwise use the address's local-part with the same leading `<digits>+` dropped. When no `.accounts` entry matches, option B is simply the first `.accounts` entry other than `.activeAccount`.
- **C/D/E** are the remaining `.accounts` entries, in the order gh listed them.
- **Other** is the free-form escape hatch, and is always last.

Never fewer than 2 options and never more than 6 in total (`commands/references/interactivity.md`), so at most five accounts are ever listed. When gh reports more accounts than fit, keep option A and the divergence candidate and drop the remainder — `Other` already covers them.

Record the answer — picker mode only, and only once a human has actually selected something. The chosen value crosses into this call as a literal the orchestrator substitutes, never as a shell variable carried over from the fence above (each fence runs in its own shell):

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
FORGE_ACCOUNT_CHOICE="[the account chosen above — the literal word active for option A, otherwise the login]"
if [ "$FORGE_ACCOUNT_CHOICE" = "active" ]; then
  $AIMI_CLI forge-account-select --record-active
elif echo "$FORGE_ACCOUNT_CHOICE" | grep -qE '^[A-Za-z0-9][A-Za-z0-9-]*$'; then
  $AIMI_CLI forge-account-select --record "$FORGE_ACCOUNT_CHOICE"
else
  echo "Not a forge login: $FORGE_ACCOUNT_CHOICE" >&2
  echo 'A login must match ^[A-Za-z0-9][A-Za-z0-9-]*$ — nothing was recorded.' >&2
  exit 1
fi
```

Option A records the permanent "always use the active account" opt-out — a real stored answer, not the absence of one, which is exactly why it stops the question being raised here again. Every other option records that login. The `Other` free-form value is validated against the login shape above *before* it reaches the verb; if it fails, nothing is recorded and this step STOPs, so the answer stays unrecorded and the next run asks again. This command layer performs no file I/O of its own — it owns the prompt, and `forge-account-select` owns both "should I ask?" and "remember this answer".

**When `INTERACTIVE_MODE=agent`** (`--non-interactive`, `AIMI_AGENT_MODE=true`, or `CI=true`): no picker. Auto-select option A — act as whichever account is active — and make **no** `forge-account-select --record` or `--record-active` call at all. Applying option A takes no action of any kind: the active account is already the one every forge verb uses, so "applied for this invocation" and "changed nothing" are the same thing here. The repository's recorded state after an agent-mode run is byte-for-byte what it was before. Log exactly one line — no retry, no blocking, no second line:

```
agent-mode: forge-account auto-selected active account (not recorded)
```

*Agent-mode fallback: if `INTERACTIVE_MODE=agent`, auto-select option A and record nothing. Log: `agent-mode: forge-account auto-selected active account (not recorded)`.*

**Why the auto-answer is never persisted.** Option A is not merely the least disruptive answer — it is also this repository's *permanent* opt-out. Recording it is precisely what stops the question ever being raised again. So if agent mode persisted its own auto-answer, one unattended CI run would silently and permanently answer the question on behalf of every human who touches the repository afterwards: they would never be asked, and would have no way to discover why. That failure is not hypothetical here — 1.93.0 shipped a remembered dismissal that could not be revoked and left users silently stuck with no way to re-trigger the prompt. Applied-but-not-persisted is what keeps it from recurring: the `(not recorded)` in the log line above is the observable proof in the transcript, and `--check`'s zero-side-effect contract is the mechanical guarantee behind it.

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

A bare HEAD read is not reliable here: after a container-mode `/aimi:execute` run, the **Main Working Tree Untouched Invariant** (`commands/references/container-execution.md:57`) means the main working tree was never checked out onto the feature branch, and Step 5's teardown (`container-execution.md:198`) removes the container with `--keep-branch`, leaving the feature branch checked out nowhere. HEAD stays parked on **the base branch** for the whole run — trusting it as-is would open a PR of the base branch against its own grandparent. "The base branch" is not always `$DEFAULT_BRANCH`: a container-mode run stacked on top of another feature branch (its own base was never the default branch to begin with) leaves HEAD parked on that other feature branch instead, so the discriminator below asks the one question that actually matters — does HEAD differ from the branch the active tasks file names — rather than the narrower "does HEAD differ from `$DEFAULT_BRANCH`". Resolve HEAD, the repository's default branch, and the active tasks file's candidate branch up front, then decide which one is actually the feature branch:

```bash
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
DEFAULT_BRANCH=$($AIMI_CLI detect-default-branch 2>/dev/null)
CANDIDATE_BRANCH=$($AIMI_CLI metadata 2>/dev/null | jq -r '.branchName // empty' 2>/dev/null)
```

`$DEFAULT_BRANCH` is kept here even though the discriminator below no longer reads it — Step 2c's own independent `detect-default-branch` call still needs the concept documented, and the cross-reference paragraph at the end of this step depends on it being computed in this preamble.

This reuses the single guarded `$AIMI_CLI metadata` call already established at Step 4a for `.title`, rather than `commands/review.md`'s two-step `find-tasks` + separate `jq -r '.metadata.branchName'`. That is safe for the same reason `find-tasks` is safe: `cmd_metadata`'s `get_tasks_file` (`aimi-cli.sh:507`) never calls `init-session`, so it satisfies `commands/review.md:63`'s concurrent-session-safety rationale — it never repoints a live `/aimi:execute` session's tracked tasks file. Its only state write is the narrow self-heal path (`aimi-cli.sh:511-521`) that fires only when the recorded state pointer already points to a deleted file, correcting a broken pointer rather than clobbering a valid one.

**Case A — nothing to correct.** Either the active tasks file's `branchName` is unusable (no tasks file discoverable, or `branchName` empty or invalid), or it is usable but already equals `$CURRENT_BRANCH` — HEAD is already on the branch the tasks file names, whether or not that happens to be `$DEFAULT_BRANCH`:

```bash
if [ -z "$CANDIDATE_BRANCH" ] || ! echo "$CANDIDATE_BRANCH" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9/_-]*$'; then
  echo "Warning: No active tasks file found (or its branchName is missing/invalid) — proceeding with the checked-out branch ($CURRENT_BRANCH), which may not be the feature branch." >&2
fi
```

No message is printed for the "already correct" half of Case A — `$CURRENT_BRANCH` needs no announcement to keep using itself.

**Case B — HEAD is not the branch the tasks file names.** Fires whenever a valid `$CANDIDATE_BRANCH` differs from `$CURRENT_BRANCH`. This covers both the pre-existing scenario (HEAD parked on `$DEFAULT_BRANCH`, the ordinary container-mode end state) and the stacked-base scenario the widened trigger fixes (HEAD parked on a *different* feature branch because the run was stacked on top of it) — one rule for both, since neither case is special beyond "HEAD is not the tasks file's branch":

```bash
if [ -n "$CANDIDATE_BRANCH" ] && echo "$CANDIDATE_BRANCH" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9/_-]*$' && [ "$CANDIDATE_BRANCH" != "$CURRENT_BRANCH" ]; then
  echo "Resolved feature branch from the active tasks file: $CANDIDATE_BRANCH (HEAD was on $CURRENT_BRANCH)" >&2
  CURRENT_BRANCH="$CANDIDATE_BRANCH"
fi
```

The correction is reported (to stderr, matching the Case A warning's own `>&2` convention) rather than applied silently: once the trigger also covers the stacked-base case, `$CURRENT_BRANCH` being swapped is no longer obviously "HEAD was on the default branch" — the swapped-from value is itself a plausible-looking feature branch, and a silent substitution there would be a surprise rather than a correction. Naming both branches makes it auditable in the transcript instead.

Store the resolved value as `$CURRENT_BRANCH`.

**Why Step 1c's skip condition is not widened to cover this case:** at Step 1c's point in the flow, neither `$DEFAULT_BRANCH` nor the Case A/Case B outcome exist yet — both are computed here in Step 2a, which runs after 1c. Widening 1c's skip condition would require moving branch detection earlier, out of this story's scope. The check is also advisory-only (it warns, never stops) and vacuously harmless in container mode, since the Main Working Tree Untouched Invariant keeps the CWD clean throughout the run regardless.

### 2b. Detect parent branch: a declared `integrationBranch` first, `detect-parent-branch` inference otherwise

#### 2b-i. Prefer a declared `integrationBranch` when the active tasks file is phase-scoped

A rolling-wave roadmap can declare a feature-level `integrationBranch` in its `roadmap.json` (materialized via `roadmap-init --integration-branch`, per issue #87's direction 1) — the long-lived branch every phase's PR should target, which the git graph alone cannot distinguish from the default branch until the two diverge. When one is declared, prefer it over inference outright: it is an explicit statement of intent, not a guess `detect-parent-branch`'s decoration walk needs to confirm.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
METADATA_JSON=$($AIMI_CLI metadata 2>/dev/null) || METADATA_JSON=""
if [ -z "$METADATA_JSON" ]; then
  echo "Note: no active tasks file readable — not looking for a declared integration branch." >&2
fi
ROADMAP_PATH_REL=$(printf '%s' "$METADATA_JSON" | jq -r '.roadmapPath // empty' 2>/dev/null)
INTEGRATION_BRANCH=""
if [ -n "$ROADMAP_PATH_REL" ]; then
  FEATURE_SLUG=$(basename "$(dirname "$ROADMAP_PATH_REL")")
  ROADMAP_JSON=$($AIMI_CLI roadmap-get --feature "$FEATURE_SLUG" 2>/dev/null) || ROADMAP_JSON=""
  if [ -z "$ROADMAP_JSON" ]; then
    echo "Note: could not read $FEATURE_SLUG's roadmap — falling back to parent-branch inference." >&2
  fi
  INTEGRATION_BRANCH=$(printf '%s' "$ROADMAP_JSON" | jq -r '.integrationBranch // empty' 2>/dev/null)
fi
```

`metadata.roadmapPath` (`.aimi/tasks/<feature>/roadmap.json`, relative to `AIMI_ROOT`) is present only on a phase-scoped tasks file — see `plan.md`'s Roadmap Materialization — so a flat tasks file yields an empty `$ROADMAP_PATH_REL` and `$INTEGRATION_BRANCH` stays empty, falling straight through to 2b-ii below exactly as if this sub-step never ran. `roadmap-get --feature <slug>` with neither `--phase` nor `--next-eligible` dumps `roadmap.json` byte for byte, so `.integrationBranch` reads whatever `roadmap-init` wrote — or a value hand-added to a roadmap that predates the field, per issue #87's direction 1 — and the trailing `// empty` degrades a legacy roadmap missing the key the same way as "not declared": empty, not an error.

**The two failure paths say so rather than degrading in silence.** A flat tasks file legitimately has no `roadmapPath`, and a roadmap that predates the field legitimately has no `integrationBranch` — those are the quiet cases and they stay quiet. But a `metadata` call that fails outright, or a `roadmap-get` that cannot read a roadmap this session just named, are different: both land on the default branch, which is precisely the wrong answer issue #87 was filed about. Landing there silently is how that issue went unnoticed for as long as it did, so each prints one line naming what it could not read.

**When `$INTEGRATION_BRANCH` is non-empty**, confirm the branch actually resolves before adopting it, then skip 2b-ii — its `detect-parent-branch` call, and both of its warning blocks, never run:

```bash
if [ -n "$INTEGRATION_BRANCH" ]; then
  if git rev-parse --verify --quiet "$INTEGRATION_BRANCH" >/dev/null \
     || git rev-parse --verify --quiet "origin/$INTEGRATION_BRANCH" >/dev/null; then
    BASE_BRANCH="$INTEGRATION_BRANCH"
    PARENT_SOURCE="integration-branch"
    echo "Base branch: $INTEGRATION_BRANCH (declared in the roadmap)" >&2
  else
    echo "Warning: the roadmap declares integrationBranch \"$INTEGRATION_BRANCH\", but no such branch resolves locally or on origin. Falling back to parent-branch inference — push that branch, or correct roadmap.json, if it is the base you meant." >&2
    INTEGRATION_BRANCH=""
  fi
fi
```

**Falling back rather than stopping is the deliberate choice.** A declared branch that does not resolve is most often one that simply has not been pushed yet — the first-phase case this whole feature exists for — and inference is a better answer than an abort. Clearing `$INTEGRATION_BRANCH` is what routes execution into 2b-ii, so the fallback needs no second condition anywhere below.

`PARENT_VERIFIED` is deliberately **not** set here. That flag means "confirmed as the true parent via `git merge-base`", which is a claim about the git graph that nothing in this sub-step makes — the check above proves the ref exists, not that it is this branch's parent. Setting it `true` would give one variable two meanings in one file, directly against what 2b-ii's own `ambiguous-decoration` answer was added to fix. Read `$PARENT_SOURCE` instead: `integration-branch` says a human declared this base, which is a stronger warrant than any inference, and it says so without overloading a boolean that means something else.

`$BASE_BRANCH` still passes through Step 2d's regex validation like every other source of it — a declared value is trusted as the RIGHT branch, not exempted from being a WELL-FORMED one.

#### 2b-ii. Otherwise, infer via `detect-parent-branch`

**Skip this whole sub-step when 2b-i already set a non-empty `$INTEGRATION_BRANCH`** — `$BASE_BRANCH`, `$PARENT_VERIFIED` and `$PARENT_SOURCE` are already set and proceed straight to Step 2c.

Call the tested CLI verb instead of parsing decorations by hand — it already handles decoration parsing, `origin/` prefix normalization, and `git merge-base` verification internally, and owns the "no verified candidate" fallback (it returns the repository's default branch itself in that case).

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
PARENT_RESULT=$($AIMI_CLI detect-parent-branch "$CURRENT_BRANCH")
BASE_BRANCH=$(printf '%s' "$PARENT_RESULT" | jq -r '.base // empty')
PARENT_VERIFIED=$(printf '%s' "$PARENT_RESULT" | jq -r '.verified // false')
PARENT_SOURCE=$(printf '%s' "$PARENT_RESULT" | jq -r '.source // empty')
```

Store as `$BASE_BRANCH`, `$PARENT_VERIFIED` and `$PARENT_SOURCE`. Note `.base` is the resolved parent branch — `.branch` in the response is merely an echo of the input `$CURRENT_BRANCH` and must never be read here.

**When `$PARENT_SOURCE` is `ambiguous-decoration`**, two or more candidate branches sit on the exact same commit (e.g. an integration branch and the default branch that have not diverged yet) and the verb could not pick between them — this is not the ordinary "no candidate at all" case, so it gets its own message naming the tied candidates before falling back to `$BASE_BRANCH` (already the repository's default branch in this case):

```bash
if [ "$PARENT_SOURCE" = "ambiguous-decoration" ]; then
  PARENT_CANDIDATES=$(printf '%s' "$PARENT_RESULT" | jq -r '(.candidates // []) | join(", ")')
  echo "Warning: could not determine a single parent branch for \"$CURRENT_BRANCH\" -- these candidates are tied at the same commit: $PARENT_CANDIDATES. Falling back to the default branch (\"$BASE_BRANCH\") as the PR base — double-check it before merging." >&2
fi
```

**Otherwise**, when `$PARENT_VERIFIED` is not `true` (the candidate could not be confirmed via `git merge-base`, or no decoration candidate existed and the verb fell back to the default branch), print the general warning naming the unverified candidate before continuing — do not silently proceed as if the value were trustworthy:

```bash
if [ "$PARENT_SOURCE" != "ambiguous-decoration" ] && [ "$PARENT_VERIFIED" != "true" ]; then
  echo "Warning: could not verify \"$BASE_BRANCH\" as the true parent branch of \"$CURRENT_BRANCH\" (git merge-base check failed or no candidate found). Proceeding with this value as the PR base — double-check it before merging." >&2
fi
```

Execution continues regardless of `$PARENT_VERIFIED` or `$PARENT_SOURCE`; Step 2d's regex validation is the only hard STOP gate on `$BASE_BRANCH`.

### 2c. Fallback when the CLI call itself failed

`detect-parent-branch` already owns the "no verified candidate" case internally (see 2b-ii) — this step is **not** a second "no parent found" handler. It exists only as defense-in-depth for the narrower case where 2b set no `$BASE_BRANCH` at all — no `integrationBranch` was declared (2b-i) AND the `detect-parent-branch` call in 2b-ii itself failed or produced no output (e.g., `$AIMI_CLI` resolution broke, the process exited non-zero, or the JSON could not be parsed):

```bash
if [ -z "$BASE_BRANCH" ]; then
  AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
  : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
  BASE_BRANCH=$($AIMI_CLI detect-default-branch)
fi
```

Store the result as `$BASE_BRANCH`.

### 2d. Validate base branch name

The detected `$BASE_BRANCH` must match the pattern `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$`, tested against the **whole value** rather than line by line:

```bash
case "$BASE_BRANCH" in
  ''|*[!a-zA-Z0-9/_-]*|[!a-zA-Z0-9]*) BASE_BRANCH_OK=false ;;
  *) BASE_BRANCH_OK=true ;;
esac
```

`case` rather than `echo … | grep -qE`, and the difference is not stylistic. `grep` matches per line, so it exits 0 whenever **any** line of a multi-line value matches — a `$BASE_BRANCH` of `main\nfoo; bar` passed the old form. That was unreachable while every source of this variable was a git ref (refnames cannot contain a newline), and it stopped being unreachable when 2b-i began reading the value out of a hand-editable JSON document. `case` tests the whole string, which is also what `forge-pr-create` already does with `[[ =~ ]]` at its own `--base` gate.

When `$BASE_BRANCH_OK` is `false`, report `Invalid parent branch name detected: $BASE_BRANCH` and STOP.

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
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
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
```

`forge-pr-create` returns `forge-contract.md`'s write-verb envelope — `{status, data: {url, number}, message}` with `status` one of `created`, `unchanged`, or `degraded` (Write-Verb Status Convention). `unchanged` means an open PR already existed for this branch and was reused rather than duplicated; both it and `created` carry a usable `data.url`/`data.number`, which is why the check above accepts either and treats everything else — a `degraded` envelope, or no envelope at all — as the failure case.

If `forge-pr-create` itself exits non-zero (an unsupported forge, a missing `gh` binary, or the `gh pr create` call failing), it has already printed manual create-it-yourself instructions to stderr — mandatory-print degradation, `forge-contract.md`'s Degradation Contract, since opening a PR has no other fallback — **and** now emits a `status: "degraded"` envelope on stdout carrying the same reason in its `message` field. The exit code is unchanged; the envelope is an additional in-band signal, not a replacement for it. Report those instructions to the user and STOP.

**Important**: The Backend Implementation Spec section is rendered entirely from the `backendSpec` metadata object. No LLM generation is used — all content comes from deterministic template rendering of the structured data. When `$INCLUDE_BACKEND_SPEC=0` (no tasks file, `frontendOnly` is false, or `backendSpec` is null), the section is omitted entirely and the PR body ends after the Files Changed section. If `businessContext` is a plain string (legacy format), render it as a single paragraph for backwards compatibility.

### 5c. Create backend issue and link to PR (conditional)

This step only runs when `$INCLUDE_BACKEND_SPEC=1` (from Step 4c). If false, skip to Step 5d.

Each Bash tool call is its own shell, so nothing Step 5b assigned survives into this one (the same convention `$CURRENT_BRANCH`/`$AIMI_CLI` already use at the start of later steps in this file). Retype **only** `PR_NUMBER` — a small GitHub-issued integer, validated below as digits-only before it is used for anything — and re-read the body itself back through `forge-pr-view` rather than retyping Step 5b's printed transcript. The body is assembled from commit messages and the diff, so it is repository content, not operator input: pasting it into a shell heredoc would let a commit message whose own line matches the heredoc delimiter close it early and run every following line as a command in the operator's session. `PR_URL` is not re-assigned at all — `forge-pr-edit` takes `--number`, and nothing else in this step reads a URL.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
PR_NUMBER="[the PR_NUMBER value Step 5b printed]"
if ! printf '%s' "$PR_NUMBER" | grep -qE '^[0-9]+$'; then
  echo "Error: PR_NUMBER must be digits only (got: ${PR_NUMBER:-<empty>}). Re-read the PR_NUMBER= line Step 5b printed and retype it exactly." >&2
  exit 1
fi
PR_VIEW_JSON=$($AIMI_CLI forge-pr-view --pr "$PR_NUMBER" --include url,number,body)
PR_VIEW_STATUS=$(printf '%s' "$PR_VIEW_JSON" | jq -r '.status // empty' 2>/dev/null)
PR_VIEW_NUMBER=$(printf '%s' "$PR_VIEW_JSON" | jq -r '.pr.number // empty' 2>/dev/null)
PR_VIEW_MESSAGE=$(printf '%s' "$PR_VIEW_JSON" | jq -r '.message // empty' 2>/dev/null)
if [ "$PR_VIEW_STATUS" = "found" ] && [ "$PR_VIEW_NUMBER" = "$PR_NUMBER" ]; then
  PR_BODY=$(printf '%s' "$PR_VIEW_JSON" | jq -r '.pr.body // empty')
else
  PR_BODY=""
  echo "Warning: could not re-read the body of PR #$PR_NUMBER (status=${PR_VIEW_STATUS:-<none>}, returned number=${PR_VIEW_NUMBER:-<none>}, message=${PR_VIEW_MESSAGE:-<none>}). The backend issue will still be created; only the 'Related issue' link back into the PR body is skipped." >&2
fi
```

`forge-pr-view` returns its own envelope — `{status, pr, unsupported_fields, message}` with `status` one of `found`, `not_found`, or `error` (`forge-contract.md`'s **`forge-pr-view` Envelope**) — which is why `PR_BODY` is read from `.pr.body` rather than a generic `.data`. A returned `.pr.number` that disagrees with the retyped `$PR_NUMBER` is treated exactly like `not_found` or `error`: relinking the wrong PR's body is worse than not relinking at all. Every non-`found` outcome degrades to an empty `PR_BODY` plus the warning above and continues — the backend issue is still worth creating even when the link cannot be appended.

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
    if [ -n "$PR_BODY" ]; then
      PR_EDIT_JSON=$($AIMI_CLI forge-pr-edit --number "$PR_NUMBER" --body "$(cat <<EOF
$PR_BODY

---
Related issue: #$ISSUE_NUMBER
EOF
)")
      echo "Backend issue created: $ISSUE_URL (linked to PR)"
    else
      echo "Backend issue created: $ISSUE_URL — NOT linked in the PR body, because the PR body could not be re-read (see the warning above). Add \"Related issue: #$ISSUE_NUMBER\" to the PR body yourself."
    fi
  else
    echo "Warning: Could not create backend issue (permissions denied, issues disabled, or rate limit). The backend spec is still available in the PR body."
  fi
fi
```

Where `$METADATA_TITLE` is `metadata.title` from Step 4c, `$PR_NUMBER` is the digits-only value retyped and validated in the block above from Step 5b's printed output, and `$PR_BODY` is the body that same block re-read fresh through `forge-pr-view` — never a transcript pasted back in. An empty `$PR_BODY` means that re-read did not succeed, which is exactly what the `[ -n "$PR_BODY" ]` guard branches on: the issue is still created, only the `forge-pr-edit` link back into the PR body is skipped.

**Important**: `forge-issue-create` is a soft-fail verb — it always exits `0` and reports `created` or `degraded` in the `status` field of `forge-contract.md`'s shared write-verb envelope (`commands/references/forge-contract.md`, Write-Verb Status Convention), so the `if`/`else` above branches on that field, never on a bare exit code. A `degraded` result (permissions denied, issues disabled, rate limit, missing forge CLI, or an unsupported forge) means the issue was not created automatically — a warning is logged but PR creation is NOT affected, since the backend spec still lives in the PR body (guaranteed by Step 5b). `forge-issue-create` itself already prints the manual "create this yourself" instructions to stderr on a `degraded` result (mandatory-print degradation), so no separate STOP is needed here. `forge-pr-edit` emits that same envelope and shares `forge-pr-create`'s own mandatory-print/non-zero-exit contract — the shared shape deliberately does NOT mean a shared exit-code contract, and this verb's always-`0` exit is exactly what keeps a failed backend issue from blocking the PR. If `forge-pr-edit` fails, its own manual fallback instructions are already on stderr (alongside its `degraded` envelope on stdout); the issue is still created and linked in every other respect.

**On success**: The issue URL and number are read from the envelope's nested `data.url` and `data.number` fields — the same nesting `forge-pr-create` and `forge-pr-edit` use, and the `grep -oE '[0-9]+$'` derivation is gone — and `forge-pr-edit` appends a "Related issue: #N" link to the PR body whenever `$PR_BODY` was re-read successfully. When it was not, the issue is still created and reported, and the message says so instead of claiming a link that was never appended.

**On failure (degraded)**: A warning message is displayed and execution continues to Step 5d.

### 5d. Report success

Display the PR URL to the user:

```
PR created successfully: <url>
```
