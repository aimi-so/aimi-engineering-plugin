#!/bin/bash
# auto-approve-cli.sh
# Auto-approves only AIMI CLI resolution and invocation commands.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

ALLOW='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'

# Pattern 1: CLI path resolution (AIMI_CLI=$(ls ~/.claude/plugins/...))
if echo "$COMMAND" | grep -qE '^AIMI_CLI='; then
  echo "$ALLOW"
  exit 0
fi

# Pattern 2: CLI invocation ($AIMI_CLI ...)
if echo "$COMMAND" | grep -qE '^\$AIMI_CLI\b|^\$\{AIMI_CLI\}'; then
  echo "$ALLOW"
  exit 0
fi

# Everything else — normal permission prompt
exit 0
