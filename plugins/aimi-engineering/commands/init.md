---
name: aimi:init
description: Prime the global CLI path cache so all /aimi:* commands resolve instantly without the Layer 2 glob
disable-model-invocation: true
allowed-tools: Read(references/cli-path-resolution.md), Bash(cat:*), Bash(bash:*), Bash(printf:*), Bash(mv:*), Bash(chmod:*), Bash($AIMI_CLI:*)
---

# Aimi Init

Prime (or repair) the global CLI path cache so subsequent `/aimi:*` commands skip the slow Layer 2 glob.

## Step 0: Resolve CLI Path

Read `references/cli-path-resolution.md` and follow the **Resolve CLI Path** and **Version Check** sections to set `$AIMI_CLI`. Each layer is a separate Bash call.

If resolution fails, report error and STOP.

Use `$AIMI_CLI` for all subsequent script calls.

## Step 1: Prime the Cache

```bash
PRIME_JSON=$($AIMI_CLI prime-cache)
```

## Step 2: Parse and Render Result

```bash
STATUS=$(printf '%s' "$PRIME_JSON" | jq -r '.status')
PATH_VAL=$(printf '%s' "$PRIME_JSON" | jq -r '.path // "null"')
VERSION=$(printf '%s' "$PRIME_JSON" | jq -r '.version // "null"')
MESSAGE=$(printf '%s' "$PRIME_JSON" | jq -r '.message // ""')
CACHE_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path"
```

Display the result based on `$STATUS`:

**`ok` or `already_current`:**

```
Cache primed successfully.
  Cache file : <CACHE_FILE>
  CLI path   : <PATH_VAL>
  Version    : <VERSION>
```

**`not_found`:**

```
Plugin not installed. Run /plugin install aimi-engineering first.
```

**`error`:**

```
Cache prime failed: <MESSAGE>
  Cache file : <CACHE_FILE>

Hint: Check permissions on ~/.claude/ or re-run /plugin install aimi-engineering.
```

## Step 3: Next-Step Hint

If status was `ok` or `already_current`, display:

```
Cache primed. Subsequent /aimi:* commands will skip the Layer 2 glob until the cache goes stale.
```
