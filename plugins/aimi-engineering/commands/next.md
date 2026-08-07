---
name: aimi:next
description: Execute the next pending story from tasks.json
argument-hint: "[--base <branch>] [--container|--inline]"
disable-model-invocation: true
allowed-tools: Read, Write, Edit, Bash(git:*), Bash(AIMI_CLI=*), Bash($AIMI_CLI:*), Bash(WORKTREE_MGR=*), Bash($WORKTREE_MGR:*), Bash(npm:*), Bash(bun:*), Bash(yarn:*), Bash(pnpm:*), Bash(npx:*), Bash(tsc:*), Bash(eslint:*), Bash(prettier:*), Task
---

# Aimi Next

Execute the next pending story using a Task-spawned agent.

## Step 0: Resolve CLI Path

Read `${CLAUDE_PLUGIN_ROOT}/commands/references/cli-path-resolution.md` and follow the **Resolve CLI Path** and **Version Check** sections to set `$AIMI_CLI`. Each layer is a separate Bash call.

If resolution fails, report error and STOP.

Use `$AIMI_CLI` for all subsequent script calls.

## Step 1: Get Next Story

**CRITICAL:** Use the CLI script to get the next story. Do NOT interpret jq queries directly.

```bash
$AIMI_CLI next-story
```

This returns the next pending story as JSON. Fields depend on schema version:

**Response format:**
```json
{
  "id": "US-001",
  "title": "Add user schema",
  "description": "As a developer, I need...",
  "acceptanceCriteria": ["Criterion 1", "Criterion 2"],
  "priority": 1,
  "status": "pending",
  "dependsOn": [],
  "notes": "",
  "wave": 1,
  "implementation": {
    "files": ["src/db/schema.ts"],
    "approach": "Add user table with Drizzle ORM",
    "verify": "npm test"
  },
  "gate": {
    "type": "decision",
    "status": "pending",
    "prompt": "Approve schema design before proceeding"
  }
}
```

> The `implementation` and `gate` fields are optional in schema v3.3. Include them in the display only when present in the story JSON.

If result is `null`:
```
All stories complete! Run /aimi:review to review the implementation.
```
STOP execution.

The CLI also saves the story ID to `.aimi/current-story` for tracking.

## Step 1b: Resolve Project Path

If the story JSON contains a `project` field:

1. Determine `AIMI_ROOT` — the parent directory of `.aimi/` (the CLI auto-discovers `.aimi/` by walking up from CWD)
2. Resolve `PROJECT_PATH = realpath(AIMI_ROOT / story.project)`
3. Verify `PROJECT_PATH` exists as a directory; if not, report failure and STOP

If the story does **not** have a `project` field, skip this step — `PROJECT_PATH` remains unset and behavior is unchanged (CWD fallback).

## Step 1c: Resolve Container

Read `metadata.execution` to decide whether this story runs inline (today's behavior) or inside a per-branch container that survives across `/aimi:next` invocations. See `commands/references/execution-mode.md` for the full read contract.

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
METADATA_JSON=$($AIMI_CLI metadata)
PHASE_ID=$(echo "$METADATA_JSON" | jq -r '.phase.id // empty')
EXECUTION_MODE=$(echo "$METADATA_JSON" | jq -r '.execution // "inline"')
BRANCH_NAME=$(echo "$METADATA_JSON" | jq -r '.branchName')
```

**Phase-scope refusal.** If `PHASE_ID` is non-empty, the active tasks file belongs to a phase/milestone roadmap. `/aimi:next` has no phase-claim step and no phase-container base resolution, so it cannot safely build a container here — the prior behavior of constructing one straight from `metadata.branchName` with `--from DEFAULT_BRANCH` used the wrong base entirely (that name is the phase's own branch, not a fresh branch point). Report:

```
This tasks file is phase-scoped (phase [PHASE_ID]). /aimi:next does not execute stories from a phase/milestone roadmap.

Run /aimi:execute instead — it claims the phase and executes its stories inside the phase's own container.
```

and STOP execution entirely — do not continue to Step 2 or any later step. This check runs first and unconditionally, before evaluating `--container`/`--inline` or any other container logic below, so it also gates the Container Mode: Complete the Run logic in Step 5.

**Parse `--container`/`--inline` Override.** Reached only when `PHASE_ID` is empty. Scan `$ARGUMENTS` for an explicit `--container` or `--inline` token (mirrors execute.md's own Parse --container/--inline Override, and the `--base` extraction style just below):

```bash
case " $ARGUMENTS " in
  *" --container "*) CONTAINER_FLAG=true ;;
  *) CONTAINER_FLAG=false ;;
esac
case " $ARGUMENTS " in
  *" --inline "*) INLINE_FLAG=true ;;
  *) INLINE_FLAG=false ;;
esac

if [ "$CONTAINER_FLAG" = "true" ] && [ "$INLINE_FLAG" = "true" ]; then
  EXECUTION_OVERRIDE="conflict"
elif [ "$CONTAINER_FLAG" = "true" ]; then
  EXECUTION_OVERRIDE="container"
elif [ "$INLINE_FLAG" = "true" ]; then
  EXECUTION_OVERRIDE="inline"
else
  EXECUTION_OVERRIDE=""
fi
```

If `EXECUTION_OVERRIDE` is `"conflict"`, report `--container and --inline are mutually exclusive — pass at most one.` and STOP.

When `EXECUTION_OVERRIDE` is non-empty, it replaces `EXECUTION_MODE` for this run. When it differs from the value already on disk, persist it via `set-execution-mode` so a later `/aimi:next` invocation without the flag continues in the same mode:

```bash
if [ -n "$EXECUTION_OVERRIDE" ]; then
  if [ "$EXECUTION_OVERRIDE" != "$EXECUTION_MODE" ]; then
    AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
    : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
    $AIMI_CLI set-execution-mode "$EXECUTION_OVERRIDE"
  fi
  EXECUTION_MODE="$EXECUTION_OVERRIDE"
fi
```

`set-execution-mode` itself refuses on a phase-scoped file, but that path is unreachable here — the phase-scope refusal above already STOPped on any such file before this point.

**When `EXECUTION_MODE` is not exactly `"container"`** (absent, `"inline"`, or any unrecognized value — every non-`"container"` value resolves to inline per the fail-safe default in `execution-mode.md`): leave `CONTAINER_PATH` unset, set `CONTAINER_MODE=false`, and skip the rest of this step entirely. Step 4 proceeds exactly as it does today — no worktree resolution, no `WORKTREE_PATH` interpolation.

**When `EXECUTION_MODE` is `"container"`:**

1. **Validate `BRANCH_NAME`** against `^[a-zA-Z0-9][a-zA-Z0-9/_-]*$` before using it in any git or worktree command. If it does not match, report `Invalid branchName in metadata.branchName: [BRANCH_NAME]` and STOP.

2. **Parse `--base` Argument.** Scan `$ARGUMENTS` for an explicit `--base <branch>` token (mirrors the `--phase <N>` extraction style used by `/aimi:execute` and the `--branch <name>` extraction style used by `/aimi:open-pr`):

Parse and validate in the **same** block, and echo the result. A validation fence of its own would run in a different shell, test an unset variable against the regex, and pass vacuously; the echo is what lets step 4's own block re-assign the value:

```bash
case " $ARGUMENTS " in
  *" --base "*)
    BASE_BRANCH=$(echo "$ARGUMENTS" | sed -n 's/.*--base[[:space:]]\+\([^ ]*\).*/\1/p')
    ;;
  *)
    BASE_BRANCH=""
    ;;
esac
if [ -n "$BASE_BRANCH" ] && ! echo "$BASE_BRANCH" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9/_-]*$'; then
  echo "Invalid --base value: $BASE_BRANCH" >&2
  exit 1
fi
echo "BASE_BRANCH=$BASE_BRANCH"
```

A non-zero exit here stops the run before any git or worktree call consumes the value. Step 4's block below must re-assign `BASE_BRANCH` with the literal value echoed here (`BASE_BRANCH=""` when `--base` was absent) — each Bash call is its own shell, so nothing assigned in this block survives into that one. When `--base` was not passed, the base is resolved by `resolve-base-branch`, which stacks on the current branch when it carries unmerged work relative to `$DEFAULT_BRANCH` rather than always defaulting to it.

3. **Resolve `CONTAINER_ROOT`** — one container per project group, following the same convention execute.md's flat mode uses (context.md decision 3):
   - `CONTAINER_ROOT = PROJECT_PATH` (from Step 1b) when the story has a `project` field
   - `CONTAINER_ROOT = AIMI_ROOT` (i.e. `$PWD`) otherwise

4. **Detect the default branch, then resolve the container's base.** Scope detection to `CONTAINER_ROOT` via `--project` only when Step 1b resolved a `PROJECT_PATH` — mirrors execute.md's Main-Repo-vs-Per-Project split. `DEFAULT_BRANCH` is computed unconditionally, regardless of `--base` — Step 5's completion report counts commits against it later. `CONTAINER_BASE` is then resolved by `resolve-base-branch` — the same shared primitive execute.md's Flat Container Mode and phase container use — scoped to `CONTAINER_ROOT` via `--project` the same way `DEFAULT_BRANCH` just was, with `--base "$BASE_BRANCH"` passed through only when the user supplied `--base`; when omitted, the resolver stacks on the current branch when it carries unmerged work, falling back to `$DEFAULT_BRANCH` otherwise — the same rule Step 1.6's own picker would apply for this repo:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
BASE_BRANCH="[the value step 2's Parse --base Argument echoed, or empty when --base was absent]"
if [ -n "$PROJECT_PATH" ]; then
  DEFAULT_BRANCH=$($AIMI_CLI detect-default-branch --project "$CONTAINER_ROOT")
else
  DEFAULT_BRANCH=$($AIMI_CLI detect-default-branch)
fi
if [ -n "$BASE_BRANCH" ]; then
  BASE_JSON=$($AIMI_CLI resolve-base-branch "$BRANCH_NAME" --project "$CONTAINER_ROOT" --default-branch "$DEFAULT_BRANCH" --base "$BASE_BRANCH")
else
  BASE_JSON=$($AIMI_CLI resolve-base-branch "$BRANCH_NAME" --project "$CONTAINER_ROOT" --default-branch "$DEFAULT_BRANCH")
fi
CONTAINER_BASE=$(echo "$BASE_JSON" | jq -r '.base')
CONTAINER_BASE_REASON=$(echo "$BASE_JSON" | jq -r '.reason')
```

5. **Create or reuse the container**, with CWD set to `CONTAINER_ROOT` so `worktree-manager.sh`'s own `git rev-parse --show-toplevel` resolves against the right repo. This is execute.md's **Create or Reuse a Container** with `EXEC_ROOT="$CONTAINER_ROOT"`, `EXEC_BRANCH="$BRANCH_NAME"`, `CONTAINER_BASE` as computed above — see that section for the full reuse/idempotency behavior. `/aimi:next` captures the exit code inline instead of letting the Bash tool call surface it, since its own STOP messaging (below) never uses `AskUserQuestion`:

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
cd "$CONTAINER_ROOT"
CREATE_OUTPUT=$($WORKTREE_MGR create "$BRANCH_NAME" --from "$CONTAINER_BASE" 2>&1)
CREATE_EXIT=$?
if [ "$CREATE_EXIT" -ne 0 ]; then
  echo "$CREATE_OUTPUT"
fi
```

If `CREATE_EXIT` is non-zero, `$CREATE_OUTPUT` (just printed above) already names the occupying worktree — STOP here without any further checkout-conflict detection or remediation, and without `AskUserQuestion`.

If `CREATE_EXIT` is zero, continue:

```bash
CONTAINER_PATH="$CONTAINER_ROOT/.worktrees/$BRANCH_NAME"
CONTAINER_MODE=true
```

Report:
```
Container for [BRANCH_NAME] ready in [CONTAINER_ROOT] — branched from [CONTAINER_BASE] ([CONTAINER_BASE_REASON])
```

This line is emitted here, by the caller, on every call — fresh-create and reuse alike — rather than relying on `worktree-manager.sh`'s own output: `create_worktree()` only prints its own `From: <base>` line on the branch that creates a worktree fresh, and returns early, printing nothing, on the branch that finds one already there (see Create or Reuse a Container in `container-execution.md`). `CONTAINER_BASE_REASON` is rendered verbatim from `resolve-base-branch`'s own `reason` field, never paraphrased.

`$WORKTREE_MGR create` reuses an existing target directory silently instead of recreating it, so calling it on every invocation is idempotent — a second `/aimi:next` run against the same branch reuses `$CONTAINER_PATH` unchanged instead of recreating it. No per-story worktree is created; the story executes and commits directly inside this container, on `$BRANCH_NAME`.

6. **Install dependencies on every create-or-reuse call, unconditionally** — never gated on whether the container directory already existed:

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
$WORKTREE_MGR install-deps "$BRANCH_NAME" || true
```

`install-deps` is advisory (see `skills/git-worktree/scripts/worktree-manager.sh`) — never let a non-zero exit block story execution; log a warning and continue regardless of outcome. Calling it unconditionally, instead of gating on the container directory's pre-existence, means a first install that failed is retried on the next invocation rather than being skipped forever just because the directory already exists.

## Step 2: Load Project Guidelines

Load project guidelines following the discovery order defined in `story-executor/SKILL.md` → "PROJECT GUIDELINES" section:

1. **CLAUDE.md** — If `PROJECT_PATH` is set, look for `CLAUDE.md` in `PROJECT_PATH` first. Otherwise use the current project root.
2. **AGENTS.md** (any directory) - Module-specific patterns
3. **Aimi defaults** from story-executor - Fallback if neither exists

Read these files and store the content as `PROJECT_GUIDELINES`.

## Step 3: Display Current Story

Show what's being executed:

```
Executing: [STORY_ID] - [STORY_TITLE]
Priority: [priority]

Acceptance Criteria:
- [criterion 1]
- [criterion 2]
...
```

If the story has an `implementation` field, also display:

```
Implementation Hints:
- Files: [implementation.files joined by ", "]
- Approach: [implementation.approach]
- Verify: [implementation.verify]
```

If the story has a `gate` field, also display:

```
Gate: [gate.type] ([gate.status])
- [gate.prompt]
```

If the story has a `tasks` field that is a non-empty array, also display:

```
Tasks:
1. [task 1]
2. [task 2]
...
```

## Step 4: Build Worker Prompt

**CRITICAL:** Construct the worker prompt following the canonical template in `story-executor/SKILL.md`.

Interpolate the following into the template:
- `PROJECT_GUIDELINES` = guidelines loaded in Step 2
- `PROJECT_PATH` = resolved project path from Step 1b (include <project_context> section only if set)
- `STORY_ID` = story.id
- `STORY_TITLE` = story.title
- `STORY_DESCRIPTION` = story.description
- `ACCEPTANCE_CRITERIA` = story.acceptanceCriteria (bulleted)
- `story.tasks` = story.tasks (include <tasks> block only if story.tasks is a non-empty array; place after <acceptance_criteria> and before <notes>)
- `story.notes` = story.notes (include <previous_notes> section only if non-empty)
- `WORKTREE_PATH` = `CONTAINER_PATH` from Step 1c when that step resolved a container (`CONTAINER_MODE=true` — the file's own `metadata.execution` or, when passed, a `--container` override that resolved `EXECUTION_MODE` to `"container"`) — the story executes and commits inside the container, on the feature branch, with no per-story worktree. Otherwise (`CONTAINER_MODE=false`), no WORKTREE_PATH (sequential mode — worker operates in current directory, or PROJECT_PATH if set), exactly as before this story.

```
# IMPORTANT: subagent_type MUST be "general-purpose" — story-executor is a skill, NOT an agent.
Task general-purpose: "Execute [STORY_ID]: [STORY_TITLE]

[story-executor/SKILL.md prompt template with interpolated values]
"
```

> Passing `WORKTREE_PATH` does not change the tasks-file-update contract below. Both the with-`WORKTREE_PATH` and without-`WORKTREE_PATH` branches of `story-executor/SKILL.md`'s `<worktree_context>` already forbid the worker from touching `tasks.json` and leave status updates to the caller — so Step 5 is unchanged by container mode.

## Step 5: Handle Result

### If Task succeeds:

Mark the story as complete:

```bash
$AIMI_CLI mark-complete [STORY_ID]
```

**When `CONTAINER_MODE` is false** (inline mode, unchanged): report success exactly as before:
```
[STORY_ID] - [STORY_TITLE] completed successfully.

Run /aimi:next for the next story.
Run /aimi:status to see overall progress.
```

**When `CONTAINER_MODE` is true:** check whether any stories remain pending:

```bash
AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
: "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
$AIMI_CLI count-pending
```

**If the result is greater than 0** — stories remain, and the container survives untouched for the next `/aimi:next` invocation. Report:
```
[STORY_ID] - [STORY_TITLE] completed successfully.

Work is in [CONTAINER_PATH] on branch [BRANCH_NAME].

Run /aimi:next for the next story.
Run /aimi:status to see overall progress.
```

**If the result is 0** — this was the last pending story. Run **Container Mode: Complete the Run** below, then report its output instead of the message above.

#### Container Mode: Complete the Run

**Runs only when `CONTAINER_MODE` is true and `count-pending` above returned 0.** Remove the container while keeping the branch, count the commits that branch accumulated, and report — the same removal `commands/references/container-execution.md`'s **Container Mode: Remove the Container** performs, minus the dev server stop (next.md never starts one — see notes above).

**This section publishes nothing.** `/aimi:next` never pushes `$BRANCH_NAME` to `origin`; `commands/references/publish-confirmation.md` is the confirm-before-publishing contract it follows, and states it once for every completion path rather than each restating it. Nothing is lost by not pushing here: `/aimi:open-pr` performs the push itself when the user runs `/aimi:open-pr --branch [BRANCH_NAME]`, which is why the report below names that command. Because nothing is published, the contract's ask-first obligation never engages — do not add a confirmation prompt to this section.

1. **Remove the container, keeping the branch.** A worktree cannot be removed while CWD sits inside it, so return to `$CONTAINER_ROOT` first:

```bash
WORKTREE_MGR=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/worktree-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" 2>/dev/null)
: "${WORKTREE_MGR:?WORKTREE_MGR is empty — re-resolve via cat ~/.config/aimi/worktree-path in this Bash call}"
cd "$CONTAINER_ROOT"
$WORKTREE_MGR remove "$BRANCH_NAME" --keep-branch
```

`--keep-branch` preserves the local branch ref: this container is the deliverable the report below points the user at for review and a PR, not a throwaway per-story worktree — removing it without `--keep-branch` would delete the very branch the Next Steps suggestions tell the user to open a PR from.

2. **Count commits against the default branch.** The branch is no longer checked out anywhere after the removal above, so count against the branch name directly, from `$CONTAINER_ROOT`:

```bash
cd "$CONTAINER_ROOT"
git log --oneline "$DEFAULT_BRANCH".."$BRANCH_NAME" | wc -l
```

3. Report:
```
All stories complete! [STORY_ID] - [STORY_TITLE] completed successfully.

Branch: [BRANCH_NAME]
Commits: [count]

This branch is local only — it has not been published to origin.

Review commits: `git log --oneline -[count]`
Open a PR: `/aimi:open-pr --branch [BRANCH_NAME]`
Run `/aimi:review [BRANCH_NAME]` for code review
```

### If Task fails (first attempt):

1. Mark the story as failed with notes:

```bash
$AIMI_CLI mark-failed [STORY_ID] "Attempt 1 failed: [error summary]"
```

2. RETRY automatically with error context:

```
# IMPORTANT: subagent_type MUST be "general-purpose" — story-executor is a skill, NOT an agent.
Task general-purpose: "RETRY: Execute [STORY_ID]: [STORY_TITLE]

PREVIOUS ATTEMPT FAILED:
[error details from failed attempt]

Please try a different approach or fix the issue described above.

[Full prompt from Step 4 including PROJECT GUIDELINES]
"
```

### If Task fails (second attempt):

1. Mark with detailed failure:

```bash
$AIMI_CLI mark-failed [STORY_ID] "Failed after 2 attempts: [error]"
```

2. Ask user with clear options:

```
Story [STORY_ID] failed after 2 attempts.

Error: [error summary]

Options:
- **skip** - Mark as skipped and continue to next story
- **retry [guidance]** - Try again with your guidance
- **stop** - Halt execution to investigate manually

What would you like to do?
```

## Step 6: Handle User Response

### If user says "skip":

```bash
$AIMI_CLI mark-skipped [STORY_ID]
```

Report: "Skipped [STORY_ID]. Run /aimi:next for the next story."

### If user says "retry [guidance]":

Spawn another Task with user's guidance included in prompt. Continue from Step 5.

### If user says "stop":

Report: "Execution stopped. Review the error and run /aimi:next when ready."
STOP execution.

## Resuming After /clear

If you need to check the current story after a `/clear`:

```bash
$AIMI_CLI current-story
```

Returns the story that was in progress, or `null` if none.
