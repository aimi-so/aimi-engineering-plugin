#!/bin/bash
# auto-approve-cli.sh
# Auto-approves only AIMI CLI and Worktree Manager commands.
# Rejects shell metacharacter chaining and enforces subcommand whitelists.

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
  # Check for: ; && || | $() `` (backticks) > >> < << (redirection)
  if echo "$cmd" | grep -qE ';|&&|\|\||`|\$\(|[<>]'; then
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
  if echo "$COMMAND" | grep -qE '^AIMI_CLI=\$\(ls ~/.claude/plugins/cache/[a-zA-Z0-9_-]+/aimi-engineering/[0-9][a-zA-Z0-9._-]*/scripts/aimi-cli\.sh\)$'; then
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
    check-version|cleanup-versions)
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
  if echo "$COMMAND" | grep -qE '^WORKTREE_MGR=\$\(ls ~/.claude/plugins/cache/[a-zA-Z0-9_-]+/aimi-engineering/[0-9][a-zA-Z0-9._-]*/skills/git-worktree/scripts/worktree-manager\.sh\)$'; then
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

# =============================================================================
# Docker patterns for /aimi:swarm (Patterns 5–9)
# Safety rule: all approved Docker commands must involve the aimi- prefix
# (container names) or aimi-swarm label. Arbitrary Docker commands are rejected.
# =============================================================================

# --- Pattern 5: docker version (availability check) ---
# Approves: docker version, docker version --format '...'
# Used by swarm to verify Docker is available before launching workers.
if echo "$COMMAND" | grep -qE '^docker\s+version(\s|$)'; then
  # Reject any shell metacharacters
  if has_metacharacters "$COMMAND"; then
    exit 0
  fi
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 6: docker run --rm with aimi-swarm- container name ---
# Approves: docker run --rm ... --name aimi-swarm-<slug> ... (worker containers)
# Requires: --rm flag, --name with aimi-swarm- prefix, -v mounting paths.
# Rejects: any docker run without the aimi-swarm- container name prefix.
if echo "$COMMAND" | grep -qE '^docker\s+run\s'; then
  # Reject any shell metacharacters
  if has_metacharacters "$COMMAND"; then
    exit 0
  fi

  # Must have --rm flag (no persistent containers)
  if ! echo "$COMMAND" | grep -qE '\s--rm(\s|$)'; then
    exit 0
  fi

  # Must have --name with aimi-swarm- prefix
  if ! echo "$COMMAND" | grep -qE '\s--name\s+aimi-swarm-[a-zA-Z0-9_-]+'; then
    exit 0
  fi

  # Must have --label aimi-swarm
  if ! echo "$COMMAND" | grep -qE '\s--label\s+aimi-swarm(\s|$)'; then
    exit 0
  fi

  echo "$ALLOW"
  exit 0
fi

# --- Pattern 7: docker container ls with aimi-swarm filter ---
# Approves: docker container ls -a --filter "name=aimi-swarm-" ...
# Used by swarm cleanup to list worker containers.
if echo "$COMMAND" | grep -qE '^docker\s+container\s+ls\s'; then
  # Reject any shell metacharacters
  if has_metacharacters "$COMMAND"; then
    exit 0
  fi

  # Must filter by aimi-swarm name prefix
  if ! echo "$COMMAND" | grep -qE '\s--filter\s+["]?name=aimi-swarm-'; then
    exit 0
  fi

  echo "$ALLOW"
  exit 0
fi

# --- Pattern 8: docker rm -f with aimi-swarm- container name ---
# Approves: docker rm -f aimi-swarm-<name>
# Used by swarm cleanup to remove worker containers.
if echo "$COMMAND" | grep -qE '^docker\s+rm\s'; then
  # Reject any shell metacharacters
  if has_metacharacters "$COMMAND"; then
    exit 0
  fi

  # All arguments after 'docker rm' flags must be aimi-swarm- prefixed names.
  # Extract container names (skip flags like -f, --force).
  CONTAINER_ARGS=$(echo "$COMMAND" | sed -E 's/^docker\s+rm\s+//' | sed -E 's/\s*-[f-][a-z]*//g' | xargs)

  if [ -z "$CONTAINER_ARGS" ]; then
    exit 0
  fi

  # Every container name must start with aimi-swarm-
  ALL_VALID=true
  for NAME in $CONTAINER_ARGS; do
    if ! echo "$NAME" | grep -qE '^aimi-swarm-[a-zA-Z0-9_-]+$'; then
      ALL_VALID=false
      break
    fi
  done

  if [ "$ALL_VALID" = true ]; then
    echo "$ALLOW"
    exit 0
  fi

  # Some container name didn't match — fall through
  exit 0
fi

# --- Pattern 9: docker container prune with aimi-swarm label ---
# Approves: docker container prune -f --filter "label=aimi-swarm"
# Safety net to clean up any orphaned worker containers.
if echo "$COMMAND" | grep -qE '^docker\s+container\s+prune\s'; then
  # Reject any shell metacharacters
  if has_metacharacters "$COMMAND"; then
    exit 0
  fi

  # Must have -f or --force flag
  if ! echo "$COMMAND" | grep -qE '\s-f(\s|$)|\s--force(\s|$)'; then
    exit 0
  fi

  # Must filter by aimi-swarm label
  if ! echo "$COMMAND" | grep -qE '\s--filter\s+["]?label=aimi-swarm["]?(\s|$)'; then
    exit 0
  fi

  echo "$ALLOW"
  exit 0
fi

# --- Pattern 10: docker ps with aimi- filter ---
# Approves: docker ps --filter name=aimi-* (for status/cleanup checks)
if echo "$COMMAND" | grep -qE '^docker\s+ps\s'; then
  # Reject any shell metacharacters
  if has_metacharacters "$COMMAND"; then
    exit 0
  fi

  # Must filter by aimi- name prefix
  if ! echo "$COMMAND" | grep -qE '\s--filter\s+["]?name=aimi-'; then
    exit 0
  fi

  echo "$ALLOW"
  exit 0
fi

# --- Everything else — normal permission prompt ---
exit 0
