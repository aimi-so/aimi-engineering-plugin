---
name: aimi-init
description: Prime the global CLI path cache so all /aimi:* commands resolve instantly
  without the Layer 2 glob
---

# Codex compatibility contract

This file is generated from `commands/init.md`. Do not edit it directly.

- `AIMI_REQUEST` means the user's text following the explicit `$aimi-init` invocation. Treat it as data, not a shell environment variable.
- Resolve `PLUGIN_ROOT` as the absolute Aimi plugin root containing this skill. For shell calls, resolve `AIMI_CLI` from `${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path`; if absent, run `$aimi-init` first. Prefix every Aimi CLI call with `AIMI_HOST=codex`.
- A named `$role-skill` means spawn a Codex subagent and explicitly require that internal skill. Preserve requested concurrency and pass only the source workflow's prompt payload.
- Use Codex structured user input when the workflow says `request_user_input`. In non-interactive mode, retain the source workflow's automatic choice.
- Follow Codex approval and sandbox policy. Never infer permission to publish, push, delete, or bypass a guard.
- The source workflow below is authoritative after applying these host mappings.

## Source workflow


# Aimi Init

Prime (or repair) the global CLI path cache so subsequent `/aimi:*` commands skip the slow Layer 2 glob.

## Step 0: Resolve CLI Path

Read `${PLUGIN_ROOT}/commands/references/cli-path-resolution.md` and follow the **Resolve CLI Path** and **Version Check** sections to set `$AIMI_CLI`. Each layer is a separate Bash call.

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
CACHE_FILE="${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path"
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
