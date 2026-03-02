# CLI Path Resolution

Shared reference for resolving `$AIMI_CLI` across all commands. This file is the single source of truth for the CLI resolution logic.

## Resolve CLI Path

**CRITICAL:** The CLI script lives in the plugin install directory, NOT the project directory. Resolve it first:

```bash
# Glob always finds the latest installed version
AIMI_CLI=$(ls ~/.claude/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1)
# Fallback to cached cli-path if glob found nothing (edge case)
if [ -z "$AIMI_CLI" ] && [ -f .aimi/cli-path ] && [ -x "$(cat .aimi/cli-path)" ]; then
  AIMI_CLI=$(cat .aimi/cli-path)
fi
```

If empty, report: "aimi-cli.sh not found. Reinstall plugin: `/plugin install aimi-engineering`" and STOP.

## Version Check

After resolving `$AIMI_CLI`, verify the cached CLI path is current:

```bash
$AIMI_CLI check-version --quiet --fix
```

If `check-version` exits 0, no action is needed — proceed normally. The `--quiet` flag suppresses informational output and `--fix` auto-updates a stale cli-path. This does NOT call `cleanup-versions` (cleanup is manual-only).

**Use `$AIMI_CLI` for ALL subsequent script calls in this command.**
