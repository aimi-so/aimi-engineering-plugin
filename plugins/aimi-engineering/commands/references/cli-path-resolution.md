# CLI Path Resolution

Shared reference for resolving `$AIMI_CLI` and `$WORKTREE_MGR` across all commands. This file is the single source of truth for the CLI resolution logic.

## Resolve CLI Path

**CRITICAL:** The CLI script lives in the plugin install directory, NOT the project directory. Resolve it using the three-layer strategy below. Each command is a separate Bash call (no compound operators).

### Layer 1: Global cache (fast path)

```bash
AIMI_CLI=$(cat ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path 2>/dev/null)
```

### Layer 1 validation: verify cached path exists and is executable

```bash
if [ -n "$AIMI_CLI" ] && [ ! -x "$AIMI_CLI" ]; then AIMI_CLI=""; fi
```

### Layer 2: Glob fallback (zsh-safe)

Only runs if Layer 1 failed. Uses `bash -c` to avoid zsh `NOMATCH` errors.

```bash
if [ -z "$AIMI_CLI" ]; then AIMI_CLI=$(bash -c 'ls ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1'); fi
```

### Layer 2 cache update: save for next time

```bash
if [ -n "$AIMI_CLI" ]; then printf '%s\n' "$AIMI_CLI" > "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path.tmp" && mv "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path.tmp" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" && chmod 600 "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path"; fi
```

### Layer 3: Per-project fallback (last resort)

```bash
if [ -z "$AIMI_CLI" ] && [ -f .aimi/cli-path ] && [ -x "$(cat .aimi/cli-path)" ]; then AIMI_CLI=$(cat .aimi/cli-path); fi
```

If empty, report: "aimi-cli.sh not found. Reinstall plugin: `/plugin install aimi-engineering`" and STOP.

## Resolve Worktree Manager Path

**CRITICAL:** The worktree manager script lives alongside the CLI. Resolve `$WORKTREE_MGR` using the same three-layer strategy.

### Layer 1: Global cache (fast path)

```bash
WORKTREE_MGR=$(cat ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path 2>/dev/null)
```

### Layer 1 validation: verify cached path exists and is executable

```bash
if [ -n "$WORKTREE_MGR" ] && [ ! -x "$WORKTREE_MGR" ]; then WORKTREE_MGR=""; fi
```

### Layer 2: Glob fallback (zsh-safe)

Only runs if Layer 1 failed. Uses `bash -c` to avoid zsh `NOMATCH` errors.

```bash
if [ -z "$WORKTREE_MGR" ]; then WORKTREE_MGR=$(bash -c 'ls ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/*/aimi-engineering/*/scripts/worktree-manager.sh 2>/dev/null | tail -1'); fi
```

### Layer 2 cache update: save for next time

```bash
if [ -n "$WORKTREE_MGR" ]; then printf '%s\n' "$WORKTREE_MGR" > "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path.tmp" && mv "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path.tmp" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path" && chmod 600 "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-worktree-path"; fi
```

### Layer 3: Per-project fallback (last resort)

```bash
if [ -z "$WORKTREE_MGR" ] && [ -f .aimi/cli-path ]; then WORKTREE_MGR=$(dirname "$(cat .aimi/cli-path)")/worktree-manager.sh; if [ ! -x "$WORKTREE_MGR" ]; then WORKTREE_MGR=""; fi; fi
```

If empty, report: "worktree-manager.sh not found. Reinstall plugin: `/plugin install aimi-engineering`" and STOP.

## Version Check

After resolving `$AIMI_CLI`, verify the cached CLI path is current:

```bash
$AIMI_CLI check-version --quiet --fix
```

If `check-version` exits 0, no action is needed — proceed normally. The `--quiet` flag suppresses informational output and `--fix` auto-updates a stale cli-path. This does NOT call `cleanup-versions` (cleanup is manual-only).

**Use `$AIMI_CLI` for ALL subsequent script calls in this command.**

## CWD Auto-Discovery

The CLI automatically discovers the project root by walking up the directory tree from CWD looking for `.aimi/`. This means:

- The CLI can be invoked from any subdirectory within the project tree
- No need to `cd` to the project root before running CLI commands
- If `.aimi/` is not found in any parent directory, the CLI exits with an error

**Note:** The `.aimi/cli-path` fallback in the resolution snippet above uses a relative path (`.aimi/cli-path`). This fallback only works when CWD is the project root. The primary glob-based resolution is unaffected and works from any directory.
