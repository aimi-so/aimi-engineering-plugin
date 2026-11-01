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
- **Manage a dev server** (`serve start|stop|status`) for a worktree, with a readiness probe, an ownership check, and a bind-address verification that refuses and kills any listener that isn't actually loopback-only

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

# Install dependencies inside a worktree (frozen command, no fallback, ends with DEPS_STATUS=<status>)
bash ${CLAUDE_PLUGIN_ROOT}/skills/git-worktree/scripts/worktree-manager.sh install-deps feature-login

# Start a dev server for a worktree, verified loopback-only after readiness (prints http://127.0.0.1:<port> and pid)
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

### `install-deps <worktree-name> | --root`

Installs dependencies with the frozen install command, run as argv, never eval. Callers install every container whether or not it serves a dev server; only `serve start` is gated on a visual story.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/git-worktree/scripts/worktree-manager.sh install-deps feature-login
bash ${CLAUDE_PLUGIN_ROOT}/skills/git-worktree/scripts/worktree-manager.sh install-deps --root
```

**`--root`:** installs the checkout the command runs from (an inline run), same engine, marker and status line, no `.worktrees/` check. A name beside it is a usage error (exit `1`, no stdout). A dependency directory with no marker of ours is user-managed: no installer, no marker, `DEPS_STATUS=ok`.

**Commands:** `bun install --frozen-lockfile`, `pnpm install --frozen-lockfile`, `npm ci`, `yarn install --frozen-lockfile` (classic) or `--immutable` (berry). **No fallback:** a failed command is final. A command with `; | & $ < >`, a backtick or a newline runs nothing; a first word missing from PATH fails naming it. `package.json` with no lockfile installs with the detector's command, warns that versions are not pinned and deletes any lockfile it created.

**Directories:** the root alone when it has something to install; otherwise each first-level subfolder with a manifest, sorted (hidden directories, `node_modules`, `vendor`, `dist`, `build` skipped). A failing subfolder is recorded `failed` and exits `1`, the rest are still installed.

**Marker and status line:** `<git dir>/aimi-deps.json` holds `{status, directories:[{dir, status, command, lockfileHash}]}`. Stdout ends with `DEPS_STATUS=<status>`: `failed` exits `1`; `ok`, `nothing-to-install` and `needs-recipe` exit `0` (the last two run no installer). A re-run installs nothing when the marker records `ok` for the same command and lockfile hash and `node_modules` exists.

**Treat exit `1` as a degradation:** container mode falls visual verification back to `skipped`/`failed` and never aborts its wave loop because of it.

### `serve start|stop|status <worktree-name>`

Manages a dev server for a container worktree, so `/aimi:execute`'s container mode (and visual verification) can bring one up before a wave and tear it down after. `serve start` never reports a server "ready" unless it has verified the listener is actually loopback-only — see **Attempt-then-verify loopback bind** below.

- **`serve start <name> [--dir <subfolder>]`** — Picks a free `127.0.0.1` port, launches the worktree's `dev` script bound to that port with the framework-appropriate host flag (see below), blocks on a readiness probe (an actual HTTP response), confirms via an ownership check that the port's listener really is the process it just spawned, then confirms via a bind-address check that the listener is actually loopback-only, and records the entry. Its stdout, on both the reuse path and a successful fresh launch, is exactly the raw `http://127.0.0.1:<port>` URL as its only line — pid and all narration go to stderr, so a caller can capture stdout directly. A live, already-registered server for the same worktree is reused as-is (a `kill -0` liveness check) instead of spawning a duplicate — the bind-address check runs only against a freshly-launched listener, never on reuse.
- **`serve stop <name>`** — Kills the whole recorded process group (a negative-pid kill against the setsid-launched leader), so children forked by `next dev` or `vite` are not orphaned. The state entry is removed whether or not the kill fully succeeded.
- **`serve status <name>`** — Prints **exactly one line of JSON** to stdout: `{"running":<bool>,"port":<number|null>,"pid":<number|null>}`, exit code `0` in every state case (no `.aimi/`, no entry, a dead pid, a live pid with a complete or partial/corrupt entry). This shape is a contract parsed with `jq`; do not add, rename, or omit keys. Status is read-only: it never runs the bind-address check and never removes a stale (dead-pid) entry; that cleanup belongs to `serve start` (its reuse path) and `serve stop`, so a status call never races a start writing the same key.

**Attempt-then-verify loopback bind:** only `HOST=127.0.0.1` is set unconditionally, and that alone satisfies CRA/webpack-dev-server but not Next.js (wants `-H`/`HOSTNAME`), Vite, Astro, or Nuxt (want `--host`) — an ignored flag leaves a wildcard bind (`0.0.0.0`/`::`) reachable from the network, with the worktree's real `.env` loaded. `serve start` closes that gap in two halves:
1. **Attempt:** it reads `scripts.dev` from the worktree's `package.json` and classifies the command (`next dev`, `vite`, `astro dev`, `nuxt dev`, `react-scripts`, or unrecognized) to pick the right flag — `-H 127.0.0.1` for Next.js, `--host 127.0.0.1` for Vite/Astro/Nuxt, or none beyond the env pair for react-scripts/unrecognized.
2. **Verify:** once the readiness probe succeeds, it resolves the listening socket's local address (`ss`, falling back to `lsof`) and adopts only exactly `127.0.0.1` or `::1` — otherwise it kills the process group, names the detected command and the address found, and writes no state entry. This is the guarantee; the flag in step 1 is only the mechanism.

**Port injection has no universal mechanism**, so `serve start` tries two, in order, each carrying the host flag from step 1 above alongside the port mechanism:
1. A `PORT` environment variable on the spawned command (covers Next.js, CRA, Nuxt, Remix).
2. If the readiness probe still doesn't see anything on the chosen port within the timeout, `serve start` kills that attempt's process group and retries once with `-- --port <n>` appended to the dev command (covers Vite, Astro).

If neither yields a listener, `serve start` reports a failure naming both and exits `0`.

**Ownership check:** once the readiness probe succeeds, `serve start` resolves the pid actually holding the listening socket on the chosen port and compares its process group to the process it just spawned. A mismatch (a stale process, or a foreign service already on that port) is reported and never adopted. This is independent of the bind-address verification above.

**State:** `.aimi/state/dev-server.json`, keyed by the container's absolute resolved path (`realpath -m` of the worktree directory) — **not** by worktree/branch name, so two project groups whose container gets the same `[branchName]` (e.g. two project roots sharing one `.aimi/`) never collide on the same entry. Each entry holds `port`, `pid` (the process-group leader pid, used for teardown), `startedAt` and `dir` (the served directory, `.` for the root; an entry without it counts as `.`). Written only by `worktree-manager.sh` (atomic, `flock`-protected), never through Write or Edit, which `guard-runtime-state.py` blocks under `.aimi/state/`. `.aimi/` is found by walking upward from the current directory, not via `GIT_ROOT`, which in a nested container is its own worktree root.

**Which directory is served:** the worktree root. With no root `package.json` and no `--dir`, the only first-level subfolder whose `package.json` has a `dev` script (never a hidden directory, `node_modules`, `vendor`, `dist` or `build`) is served, from inside it, and named on stderr; several candidates print no URL and name them and `--dir`. `--dir` takes exactly one first-level directory; an empty value, a path, `..`, a hidden or skipped name, a missing directory, a symlink leaving the worktree, an unknown option or a root with its own `package.json` is a usage error naming `--dir`. A live server registered for another directory is neither reused nor stopped: no URL, and stderr names it and `serve stop`.

**Dependency refusal:** before launching or reusing anything, `serve start` exits `0` with no URL and a stderr reason when the install marker records `failed` or `needs-recipe` for the served directory, or, with no marker entry, when neither it nor any directory up to the worktree root has `node_modules` or `.pnp.cjs` while a directory above the worktree does (it would run another checkout's packages).

**No package.json, or no `dev` script:** a clean skip — exits `0`, writes no state, and is never reported as an error.

**Every other failure degrades gracefully too:** port exhaustion, readiness timeout, ownership mismatch, a non-loopback bind and kill failure never exit non-zero. A missing or invalid `<worktree-name>` is a usage error in all three verbs — non-zero exit, stderr message, no stdout. `serve start` treats two more conditions the same way, since the name never matched a real worktree: a directory that doesn't exist, and a resolved path that escapes `.worktrees/` (the check `install-deps` uses).

**Example:**
```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/git-worktree/scripts/worktree-manager.sh serve start feature-login
# -> http://127.0.0.1:4100
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
