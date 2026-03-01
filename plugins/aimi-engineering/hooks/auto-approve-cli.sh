#!/bin/bash
# auto-approve-cli.sh
# Auto-approves only AIMI CLI, Worktree Manager, Sandbox Manager, Build Image,
# and specific Docker exec commands. Rejects shell metacharacter chaining and
# enforces subcommand whitelists.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

ALLOW='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'

# --- Helper: Reject shell metacharacters ---
# Returns 0 (true) if dangerous metacharacters are found after the variable reference.
has_metacharacters() {
  local cmd="$1"
  # Check for: ; && || | $() `` (backticks)
  if echo "$cmd" | grep -qE ';|&&|\|\||`|\$\('; then
    return 0
  fi
  # Check for pipe (|) that is NOT part of || (already caught above)
  # We need to check for standalone | that isn't ||
  if echo "$cmd" | grep -qE '\|' && ! echo "$cmd" | grep -qE '\|\|'; then
    return 0
  fi
  return 1
}

# --- Pattern 1: AIMI_CLI= assignment ---
# Validates the assigned path matches the expected plugin cache pattern.
if echo "$COMMAND" | grep -qE '^AIMI_CLI='; then
  if echo "$COMMAND" | grep -qE '^AIMI_CLI=\$\(ls ~/.claude/plugins/cache/[a-zA-Z0-9_-]+/aimi-engineering/[a-zA-Z0-9._-]+/scripts/aimi-cli\.sh\)$'; then
    echo "$ALLOW"
    exit 0
  fi
  # Invalid path pattern — fall through to normal permission prompt
  exit 0
fi

# --- Pattern 2: $AIMI_CLI invocation with subcommand whitelist ---
if echo "$COMMAND" | grep -qE '^\$AIMI_CLI\b|^\$\{AIMI_CLI\}'; then
  # Reject any shell metacharacters
  if has_metacharacters "$COMMAND"; then
    exit 0
  fi

  # Extract the subcommand (first argument after $AIMI_CLI or ${AIMI_CLI})
  SUBCMD=$(echo "$COMMAND" | sed -E 's/^\$AIMI_CLI\s+//; s/^\$\{AIMI_CLI\}\s+//' | awk '{print $1}')

  # Whitelist of allowed CLI subcommands
  case "$SUBCMD" in
    init-session|find-tasks|status|metadata|next-story|current-story|\
    list-ready|mark-in-progress|mark-complete|mark-failed|mark-skipped|\
    count-pending|validate-deps|validate-stories|cascade-skip|reset-orphaned|\
    get-branch|get-state|clear-state|help|\
    swarm-init|swarm-add|swarm-update|swarm-remove|swarm-status|swarm-list|swarm-cleanup)
      echo "$ALLOW"
      exit 0
      ;;
    *)
      # Unknown subcommand — fall through to normal permission prompt
      exit 0
      ;;
  esac
fi

# --- Pattern 3: WORKTREE_MGR= assignment ---
# Validates the assigned path matches the expected worktree manager plugin path.
if echo "$COMMAND" | grep -qE '^WORKTREE_MGR='; then
  if echo "$COMMAND" | grep -qE '^WORKTREE_MGR=\$\(ls ~/.claude/plugins/cache/[a-zA-Z0-9_-]+/aimi-engineering/[a-zA-Z0-9._-]+/skills/git-worktree/scripts/worktree-manager\.sh\)$'; then
    echo "$ALLOW"
    exit 0
  fi
  # Invalid path pattern — fall through to normal permission prompt
  exit 0
fi

# --- Pattern 4: $WORKTREE_MGR invocation with subcommand whitelist ---
if echo "$COMMAND" | grep -qE '^\$WORKTREE_MGR\b|^\$\{WORKTREE_MGR\}'; then
  # Reject any shell metacharacters
  if has_metacharacters "$COMMAND"; then
    exit 0
  fi

  # Extract the subcommand (first argument after $WORKTREE_MGR or ${WORKTREE_MGR})
  SUBCMD=$(echo "$COMMAND" | sed -E 's/^\$WORKTREE_MGR\s+//; s/^\$\{WORKTREE_MGR\}\s+//' | awk '{print $1}')

  # Whitelist of allowed worktree manager subcommands
  case "$SUBCMD" in
    create|remove|merge|list|help)
      echo "$ALLOW"
      exit 0
      ;;
    *)
      # Unknown subcommand — fall through to normal permission prompt
      exit 0
      ;;
  esac
fi

# --- Pattern 5: SANDBOX_MGR= assignment ---
# Validates the assigned path matches the expected sandbox manager plugin path.
if echo "$COMMAND" | grep -qE '^SANDBOX_MGR='; then
  if echo "$COMMAND" | grep -qE '^SANDBOX_MGR=\$\(ls ~/.claude/plugins/cache/[a-zA-Z0-9_-]+/aimi-engineering/[a-zA-Z0-9._-]+/skills/sandbox/scripts/sandbox-manager\.sh\)$'; then
    echo "$ALLOW"
    exit 0
  fi
  # Invalid path pattern — fall through to normal permission prompt
  exit 0
fi

# --- Pattern 6: $SANDBOX_MGR invocation with subcommand whitelist ---
if echo "$COMMAND" | grep -qE '^\$SANDBOX_MGR\b|^\$\{SANDBOX_MGR\}'; then
  # Reject any shell metacharacters
  if has_metacharacters "$COMMAND"; then
    exit 0
  fi

  # Extract the subcommand (first argument after $SANDBOX_MGR or ${SANDBOX_MGR})
  SUBCMD=$(echo "$COMMAND" | sed -E 's/^\$SANDBOX_MGR\s+//; s/^\$\{SANDBOX_MGR\}\s+//' | awk '{print $1}')

  # Whitelist of allowed sandbox manager subcommands
  case "$SUBCMD" in
    create|remove|list|status|cleanup|check-runtime)
      echo "$ALLOW"
      exit 0
      ;;
    *)
      # Unknown subcommand — fall through to normal permission prompt
      exit 0
      ;;
  esac
fi

# --- Pattern 7: BUILD_IMG= assignment ---
# Validates the assigned path matches the expected build image plugin path.
if echo "$COMMAND" | grep -qE '^BUILD_IMG='; then
  if echo "$COMMAND" | grep -qE '^BUILD_IMG=\$\(ls ~/.claude/plugins/cache/[a-zA-Z0-9_-]+/aimi-engineering/[a-zA-Z0-9._-]+/skills/sandbox/scripts/build-project-image\.sh\)$'; then
    echo "$ALLOW"
    exit 0
  fi
  # Invalid path pattern — fall through to normal permission prompt
  exit 0
fi

# --- Pattern 8: $BUILD_IMG invocation ---
if echo "$COMMAND" | grep -qE '^\$BUILD_IMG\b|^\$\{BUILD_IMG\}'; then
  # Reject any shell metacharacters
  if has_metacharacters "$COMMAND"; then
    exit 0
  fi

  # Allow the build script (no subcommand whitelist needed — the script itself is the operation)
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 9: docker exec -i aimi-* for ACP adapter ---
# Only allows: docker exec -i aimi-<name> python3 /opt/aimi/acp-adapter.py
# No wildcard Docker approvals — only specific aimi-* container patterns.
if echo "$COMMAND" | grep -qE '^docker exec -i '; then
  # Reject any shell metacharacters
  if has_metacharacters "$COMMAND"; then
    exit 0
  fi

  # Validate: docker exec -i aimi-<container> python3 /opt/aimi/acp-adapter.py
  if echo "$COMMAND" | grep -qE '^docker exec -i aimi-[a-zA-Z0-9_-]+ python3 /opt/aimi/acp-adapter\.py$'; then
    echo "$ALLOW"
    exit 0
  fi
  # Non-matching docker exec — fall through to normal permission prompt
  exit 0
fi

# --- Everything else — normal permission prompt ---
exit 0
