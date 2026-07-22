---
name: git-worktree
description: This skill manages Git worktrees for isolated parallel development. It handles creating, listing, switching, and cleaning up worktrees with a simple interactive interface, following KISS principles.
---

# Git Worktree Manager

This skill provides a unified interface for managing Git worktrees across your development workflow. Whether you're reviewing PRs in isolation or working on features in parallel, this skill handles all the complexity.

## What This Skill Does

- **Create worktrees** from main branch with clear branch names
- **List worktrees** with current status
- **Switch between worktrees** for parallel work
- **Clean up completed worktrees** automatically
- **Interactive confirmations** at each step
- **Automatic .gitignore management** for worktree directory
- **Automatic .env file copying** from main repo to new worktrees
- **Manage a loopback-only dev server** (`serve start|stop|status`) for a worktree, with a readiness probe and an ownership check

## CRITICAL: Always Use the Manager Script

**NEVER call `git worktree add` directly.** Always use the `worktree-manager.sh` script.

The script handles critical setup that raw git commands don't:
1. Copies `.env`, `.env.local`, `.env.test`, etc. from main repo
2. Ensures `.worktrees` is in `.gitignore`
3. Creates consistent directory structure

```bash
# ✅ CORRECT - Always use the script
bash ${CLAUDE_PLUGIN_ROOT}/skills/git-worktree/scripts/worktree-manager.sh create feature-name

# ❌ WRONG - Never do this directly
git worktree add .worktrees/feature-name -b feature-name main
```

## When to Use This Skill

Use this skill in these scenarios:

1. **Code Review (`/workflows:review`)**: If NOT already on the target branch (PR branch or requested branch), offer worktree for isolated review
2. **Feature Work (`/workflows:work`)**: Always ask if user wants parallel worktree or live branch work
3. **Parallel Development**: When working on multiple features simultaneously
4. **Cleanup**: After completing work in a worktree

## How to Use

### In Claude Code Workflows

The skill is automatically called from `/workflows:review` and `/workflows:work` commands:

```
# For review: offers worktree if not on PR branch
# For work: always asks - new branch or worktree?
```

### Manual Usage

You can also invoke the skill directly from bash:

```bash
# Create a new worktree (copies .env files automatically)
bash ${CLAUDE_PLUGIN_ROOT}/skills/git-worktree/scripts/worktree-manager.sh create feature-login

# List all worktrees
bash ${CLAUDE_PLUGIN_ROOT}/skills/git-worktree/scripts/worktree-manager.sh list

# Switch to a worktree
bash ${CLAUDE_PLUGIN_ROOT}/skills/git-worktree/scripts/worktree-manager.sh switch feature-login

# Copy .env files to an existing worktree (if they weren't copied)
bash ${CLAUDE_PLUGIN_ROOT}/skills/git-worktree/scripts/worktree-manager.sh copy-env feature-login

# Clean up completed worktrees
bash ${CLAUDE_PLUGIN_ROOT}/skills/git-worktree/scripts/worktree-manager.sh cleanup

# Install dependencies inside a worktree (detects package manager by lockfile)
bash ${CLAUDE_PLUGIN_ROOT}/skills/git-worktree/scripts/worktree-manager.sh install-deps feature-login

# Start a loopback-only dev server for a worktree (prints http://127.0.0.1:<port> and pid)
bash ${CLAUDE_PLUGIN_ROOT}/skills/git-worktree/scripts/worktree-manager.sh serve start feature-login

# Check a worktree's dev server status (single-line JSON: running/port/pid)
bash ${CLAUDE_PLUGIN_ROOT}/skills/git-worktree/scripts/worktree-manager.sh serve status feature-login

# Stop a worktree's dev server (kills the whole process group)
bash ${CLAUDE_PLUGIN_ROOT}/skills/git-worktree/scripts/worktree-manager.sh serve stop feature-login
```

## Commands

### `create <branch-name> [from-branch]`

Creates a new worktree with the given branch name.

**Options:**
- `branch-name` (required): The name for the new branch and worktree
- `from-branch` (optional): Base branch to create from (defaults to `main`)

**Example:**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/git-worktree/scripts/worktree-manager.sh create feature-login
```

**What happens:**
1. Checks if worktree already exists
2. Updates the base branch from remote
3. Creates new worktree and branch
4. **Copies all .env files from main repo** (.env, .env.local, .env.test, etc.)
5. Shows path for cd-ing to the worktree

### `list` or `ls`

Lists all available worktrees with their branches and current status.

**Example:**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/git-worktree/scripts/worktree-manager.sh list
```

**Output shows:**
- Worktree name
- Branch name
- Which is current (marked with ✓)
- Main repo status

### `switch <name>` or `go <name>`

Switches to an existing worktree and cd's into it.

**Example:**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/git-worktree/scripts/worktree-manager.sh switch feature-login
```

**Optional:**
- If name not provided, lists available worktrees and prompts for selection

### `remove <name>` or `rm <name>`

Removes a specific worktree and, by default, deletes its branch too (non-interactive).

**Options:**
- `name` (required): The worktree/branch name to remove
- `--keep-branch` (optional): Skip branch deletion — remove only the worktree directory, leaving the branch intact (default: off, branch is deleted)

**Example:**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/git-worktree/scripts/worktree-manager.sh remove feature-login
bash ${CLAUDE_PLUGIN_ROOT}/skills/git-worktree/scripts/worktree-manager.sh remove feature-login --keep-branch
```

Use `--keep-branch` when the worktree's branch is the actual deliverable — e.g. a feature or split branch a report just pointed the user at for review or `gh pr create` — and must survive worktree teardown.

### `cleanup` or `clean`

Interactively cleans up inactive worktrees with confirmation.

**Example:**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/git-worktree/scripts/worktree-manager.sh cleanup
```

**What happens:**
1. Lists all inactive worktrees
2. Asks for confirmation
3. Removes selected worktrees
4. Cleans up empty directories

### `install-deps <worktree-name>`

Installs dependencies inside an existing worktree by detecting the package manager from its lockfile. Used by the container execution mode of `/aimi:execute` to prepare a worktree before starting its dev server.

**Example:**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/git-worktree/scripts/worktree-manager.sh install-deps feature-login
```

**Package manager detection order (first match wins):**
1. `bun.lockb` → `bun install`
2. `pnpm-lock.yaml` → `pnpm install`
3. `yarn.lock` → `yarn install`
4. `package-lock.json` → `npm ci` (falls back to `npm install` if `npm ci` fails)
5. No recognized lockfile but `package.json` present → `npm install`

**No `package.json`:** prints a single informational line and exits `0`. This is never treated as an error — plenty of worktrees are not Node projects.

**Install failure is advisory, not fatal:** if the package manager's install command fails, `install-deps` prints a clear error naming the package manager and worktree, and exits non-zero — but it never leaves partial state or trips the script's own `set -e`. **Callers must treat a non-zero exit as a degradation, not a hard failure.** In particular, the container mode of `/aimi:execute` must fall visual verification back to `skipped`/`failed` and must never abort its wave loop because `install-deps` failed.

### `serve start|stop|status <worktree-name>`

Manages a **loopback-only** dev server for a container worktree, so `/aimi:execute`'s container mode (and its visual verification step) can bring one up before a wave and tear it down afterward.

- **`serve start <name>`** — Picks a free `127.0.0.1` port, launches the worktree's `dev` script bound to that port, blocks on a readiness probe (an actual HTTP response, not just "the process started"), confirms via an ownership check that the port's listener really is the process it just spawned, prints `http://127.0.0.1:<port>` plus the pid, and records the entry. A live, already-registered server for the same worktree is reused as-is (a `kill -0` liveness check) instead of spawning a duplicate.
- **`serve stop <name>`** — Kills the whole recorded process group (a negative-pid kill against the setsid-launched leader, not just the single pid), so children forked by `next dev`, `vite`, or similar are not orphaned. The state entry is removed whether or not the kill fully succeeded.
- **`serve status <name>`** — Prints **exactly one line of JSON** to stdout: `{"running":<bool>,"port":<number|null>,"pid":<number|null>}`, exit code `0` in both the running and not-running cases. This exact shape is a contract — other tooling parses it with `jq`; do not add, rename, or omit keys.

**Loopback-only, always:** the dev server is bound to `127.0.0.1` and never `0.0.0.0` or a wildcard host, and the readiness probe itself only ever connects to `127.0.0.1:<port>` — an autonomously-started server must never be reachable from outside the loopback interface.

**Port injection has no universal mechanism**, so `serve start` tries two, in order:
1. A `PORT` environment variable on the spawned command (covers Next.js, CRA, Nuxt, Remix).
2. If the readiness probe still doesn't see anything on the chosen port within the timeout, `serve start` kills that attempt's process group and retries once with `-- --port <n>` appended to the dev command (covers Vite, Astro).

If neither mechanism yields a listener, `serve start` reports a clear failure naming both mechanisms tried and exits `0` — it never assumes success and never blocks the caller.

**Ownership check:** once the readiness probe succeeds, `serve start` resolves the pid actually holding the listening socket on the chosen port and compares its process group to the process it just spawned. A mismatch (a stale process from a prior run, or an unrelated foreign service already on that port) is reported clearly and never adopted as the worktree's dev server.

**State:** `.aimi/state/dev-server.json`, keyed by the container's absolute resolved path (`realpath -m` of the worktree directory) — **not** by worktree/branch name, so two project groups whose container gets the same `[branchName]` (e.g. two `.aimi/`-sharing project_roots in a multi-repo layout) never collide on the same entry. Each entry holds `port`, `pid` (the process-group leader pid, used for teardown), and `startedAt`. Written exclusively through a Bash-level atomic (mktemp-then-move, `flock`-protected) write inside `worktree-manager.sh` — **never** through the Write or Edit tool, which `guard-runtime-state.py` blocks unconditionally for any path under `.aimi/state/`. The `.aimi/` directory is located by walking upward from the current directory (not via this script's own `GIT_ROOT`), since a nested phase/story container's `GIT_ROOT` resolves to its own worktree root, not necessarily where `.aimi/` lives.

**No package.json, or no `dev` script:** a clean skip — exits `0`, writes no state, and is never reported as an error.

**Every other failure degrades gracefully too:** port exhaustion, readiness timeout, ownership mismatch, and kill failure never produce a non-zero exit or abort the caller. Only a missing `<worktree-name>` argument is a usage error.

**Example:**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/git-worktree/scripts/worktree-manager.sh serve start feature-login
# -> http://127.0.0.1:4100 (pid 12345)
bash ${CLAUDE_PLUGIN_ROOT}/skills/git-worktree/scripts/worktree-manager.sh serve status feature-login
# -> {"running":true,"port":4100,"pid":12345}
bash ${CLAUDE_PLUGIN_ROOT}/skills/git-worktree/scripts/worktree-manager.sh serve stop feature-login
```

For workflow examples, see [workflow-examples.md](references/workflow-examples.md).

## Key Design Principles

### KISS (Keep It Simple, Stupid)

- **One manager script** handles all worktree operations
- **Simple commands** with sensible defaults
- **Interactive prompts** prevent accidental operations
- **Clear naming** using branch names directly

### Opinionated Defaults

- Worktrees always created from **main** (unless specified)
- Worktrees stored in **.worktrees/** directory
- Branch name becomes worktree name
- **.gitignore** automatically managed

### Safety First

- **Confirms before creating** worktrees
- **Confirms before cleanup** to prevent accidental removal
- **Won't remove current worktree**
- **Clear error messages** for issues

For workflow integration details, see [workflow-integration.md](references/workflow-integration.md).

For troubleshooting, see [troubleshooting.md](references/troubleshooting.md).

For technical details, see [technical-details.md](references/technical-details.md).
