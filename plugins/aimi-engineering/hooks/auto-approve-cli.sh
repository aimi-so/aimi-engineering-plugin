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

# --- Resolve config directory for dynamic path matching ---
# The hook receives literal command text BEFORE shell expansion.
# Commands may reference the config dir as:
#   1. ~/.claude                              (old/default form)
#   2. ${CLAUDE_CONFIG_DIR:-$HOME/.claude}    (parameterized form)
#   3. /absolute/path/.claude                 (resolved absolute path)
# We build a regex alternation that matches any of these forms.
RESOLVED_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# Remove trailing slash if present
RESOLVED_CONFIG_DIR="${RESOLVED_CONFIG_DIR%/}"
# Escape special regex characters in the resolved path (. / are the main ones)
ESCAPED_CONFIG_DIR=$(printf '%s' "$RESOLVED_CONFIG_DIR" | sed 's/[.[\*^$()+?{|\\]/\\&/g; s/\//\\\//g')
# Build the config dir regex alternation:
#   ~\/.claude  |  \$\{CLAUDE_CONFIG_DIR:-\$HOME\/\.claude\}  |  /resolved/path
CONFIG_DIR_RE="(~/\\.claude|\\\$\\{CLAUDE_CONFIG_DIR:-\\\$HOME/\\.claude\\}|${ESCAPED_CONFIG_DIR})"

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

# --- Pattern 0a: Layer 0 AIMI_CLI assignment via AIMI_PLUGIN_DIR ---
# Approves: if [ -n "$AIMI_PLUGIN_DIR" ] && [ -x "$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh" ]; then AIMI_CLI="$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh"; fi
# The path inside AIMI_PLUGIN_DIR must be free of shell metacharacters.
if echo "$COMMAND" | grep -qE '^if \[ -n "\$AIMI_PLUGIN_DIR" \] && \[ -x "\$AIMI_PLUGIN_DIR/scripts/aimi-cli\.sh" \]; then AIMI_CLI="\$AIMI_PLUGIN_DIR/scripts/aimi-cli\.sh"; fi$'; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 0b: Layer 0 WORKTREE_MGR assignment via AIMI_PLUGIN_DIR ---
# Approves: if [ -n "$AIMI_PLUGIN_DIR" ] && [ -x "$AIMI_PLUGIN_DIR/skills/git-worktree/scripts/worktree-manager.sh" ]; then WORKTREE_MGR="$AIMI_PLUGIN_DIR/skills/git-worktree/scripts/worktree-manager.sh"; fi
if echo "$COMMAND" | grep -qE '^if \[ -n "\$AIMI_PLUGIN_DIR" \] && \[ -x "\$AIMI_PLUGIN_DIR/skills/git-worktree/scripts/worktree-manager\.sh" \]; then WORKTREE_MGR="\$AIMI_PLUGIN_DIR/skills/git-worktree/scripts/worktree-manager\.sh"; fi$'; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 1: AIMI_CLI= assignment ---
# Validates the assigned path matches the expected plugin cache pattern.
# Accepts config dir as ~/.claude, ${CLAUDE_CONFIG_DIR:-$HOME/.claude}, or resolved absolute path.
# Supports both legacy $(ls ...) form and new $(cat ...) cache read form.
if echo "$COMMAND" | grep -qE '^AIMI_CLI='; then
  # Legacy: AIMI_CLI=$(ls <config>/plugins/cache/.../aimi-cli.sh)
  if echo "$COMMAND" | grep -qE "^AIMI_CLI=\\$\\(ls ${CONFIG_DIR_RE}/plugins/cache/[a-zA-Z0-9_-]+/aimi-engineering/[0-9][a-zA-Z0-9._-]*/scripts/aimi-cli\\.sh\\)\$"; then
    echo "$ALLOW"
    exit 0
  fi
  # Cache read: AIMI_CLI=$(cat <config>/aimi-engineering-cli-path 2>/dev/null)
  if echo "$COMMAND" | grep -qE "^AIMI_CLI=\\$\\(cat ${CONFIG_DIR_RE}/aimi-engineering-cli-path 2>/dev/null\\)\$"; then
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
    init-session|find-tasks|find-tasks-all|status|metadata|next-story|current-story|\
    list-ready|mark-in-progress|mark-complete|mark-failed|mark-skipped|\
    count-pending|validate-deps|validate-stories|cascade-skip|reset-orphaned|\
    get-branch|get-state|detect-default-branch|clear-state|help|\
    check-version|cleanup-versions|\
    list-archivable|archive-task|setup-branch)
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
# Accepts config dir as ~/.claude, ${CLAUDE_CONFIG_DIR:-$HOME/.claude}, or resolved absolute path.
# Supports both legacy $(ls ...) form and new $(cat ...) cache read form.
if echo "$COMMAND" | grep -qE '^WORKTREE_MGR='; then
  # Legacy: WORKTREE_MGR=$(ls <config>/plugins/cache/.../worktree-manager.sh)
  if echo "$COMMAND" | grep -qE "^WORKTREE_MGR=\\$\\(ls ${CONFIG_DIR_RE}/plugins/cache/[a-zA-Z0-9_-]+/aimi-engineering/[0-9][a-zA-Z0-9._-]*/skills/git-worktree/scripts/worktree-manager\\.sh\\)\$"; then
    echo "$ALLOW"
    exit 0
  fi
  # Cache read: WORKTREE_MGR=$(cat <config>/aimi-engineering-worktree-path 2>/dev/null)
  if echo "$COMMAND" | grep -qE "^WORKTREE_MGR=\\$\\(cat ${CONFIG_DIR_RE}/aimi-engineering-worktree-path 2>/dev/null\\)\$"; then
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

# --- Pattern 5: AIMI_CLI Layer 1 validation ---
# Approves: if [ -n "$AIMI_CLI" ] && [ ! -x "$AIMI_CLI" ]; then AIMI_CLI=""; fi
if echo "$COMMAND" | grep -qE '^if \[ -n "\$AIMI_CLI" \] && \[ ! -x "\$AIMI_CLI" \]; then AIMI_CLI=""; fi$'; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 6: WORKTREE_MGR Layer 1 validation ---
# Approves: if [ -n "$WORKTREE_MGR" ] && [ ! -x "$WORKTREE_MGR" ]; then WORKTREE_MGR=""; fi
if echo "$COMMAND" | grep -qE '^if \[ -n "\$WORKTREE_MGR" \] && \[ ! -x "\$WORKTREE_MGR" \]; then WORKTREE_MGR=""; fi$'; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 7: AIMI_CLI Layer 2 glob fallback (bash -c wrapper) ---
# Approves: if [ -z "$AIMI_CLI" ]; then AIMI_CLI=$(bash -c 'ls <config>/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1'); fi
if echo "$COMMAND" | grep -qE "^if \\[ -z \"\\\$AIMI_CLI\" \\]; then AIMI_CLI=\\$\\(bash -c 'ls ${CONFIG_DIR_RE}/plugins/cache/\\*/aimi-engineering/\\*/scripts/aimi-cli\\.sh 2>/dev/null \\| tail -1'\\); fi\$"; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 8: WORKTREE_MGR Layer 2 glob fallback (bash -c wrapper) ---
# Approves: if [ -z "$WORKTREE_MGR" ]; then WORKTREE_MGR=$(bash -c 'ls <config>/plugins/cache/*/aimi-engineering/*/scripts/worktree-manager.sh 2>/dev/null | tail -1'); fi
if echo "$COMMAND" | grep -qE "^if \\[ -z \"\\\$WORKTREE_MGR\" \\]; then WORKTREE_MGR=\\$\\(bash -c 'ls ${CONFIG_DIR_RE}/plugins/cache/\\*/aimi-engineering/\\*/scripts/worktree-manager\\.sh 2>/dev/null \\| tail -1'\\); fi\$"; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 9: AIMI_CLI Layer 2 cache write ---
# Approves: if [ -n "$AIMI_CLI" ]; then printf '%s\n' "$AIMI_CLI" > "<config>/aimi-engineering-cli-path.tmp" && mv "<config>/aimi-engineering-cli-path.tmp" "<config>/aimi-engineering-cli-path" && chmod 600 "<config>/aimi-engineering-cli-path"; fi
if echo "$COMMAND" | grep -qE "^if \\[ -n \"\\\$AIMI_CLI\" \\]; then printf '%s\\\\n' \"\\\$AIMI_CLI\" > \"${CONFIG_DIR_RE}/aimi-engineering-cli-path\\.tmp\" && mv \"${CONFIG_DIR_RE}/aimi-engineering-cli-path\\.tmp\" \"${CONFIG_DIR_RE}/aimi-engineering-cli-path\" && chmod 600 \"${CONFIG_DIR_RE}/aimi-engineering-cli-path\"; fi\$"; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 10: WORKTREE_MGR Layer 2 cache write ---
# Approves: if [ -n "$WORKTREE_MGR" ]; then printf '%s\n' "$WORKTREE_MGR" > "<config>/aimi-engineering-worktree-path.tmp" && mv "<config>/aimi-engineering-worktree-path.tmp" "<config>/aimi-engineering-worktree-path" && chmod 600 "<config>/aimi-engineering-worktree-path"; fi
if echo "$COMMAND" | grep -qE "^if \\[ -n \"\\\$WORKTREE_MGR\" \\]; then printf '%s\\\\n' \"\\\$WORKTREE_MGR\" > \"${CONFIG_DIR_RE}/aimi-engineering-worktree-path\\.tmp\" && mv \"${CONFIG_DIR_RE}/aimi-engineering-worktree-path\\.tmp\" \"${CONFIG_DIR_RE}/aimi-engineering-worktree-path\" && chmod 600 \"${CONFIG_DIR_RE}/aimi-engineering-worktree-path\"; fi\$"; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 11: AIMI_CLI Layer 3 per-project fallback ---
# Approves: if [ -z "$AIMI_CLI" ] && [ -f .aimi/cli-path ] && [ -x "$(cat .aimi/cli-path)" ]; then AIMI_CLI=$(cat .aimi/cli-path); fi
if echo "$COMMAND" | grep -qE '^if \[ -z "\$AIMI_CLI" \] && \[ -f \.aimi/cli-path \] && \[ -x "\$\(cat \.aimi/cli-path\)" \]; then AIMI_CLI=\$\(cat \.aimi/cli-path\); fi$'; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 12: WORKTREE_MGR Layer 3 per-project fallback ---
# Approves: if [ -z "$WORKTREE_MGR" ] && [ -f .aimi/cli-path ]; then WORKTREE_MGR=$(dirname "$(cat .aimi/cli-path)")/worktree-manager.sh; if [ ! -x "$WORKTREE_MGR" ]; then WORKTREE_MGR=""; fi; fi
if echo "$COMMAND" | grep -qE '^if \[ -z "\$WORKTREE_MGR" \] && \[ -f \.aimi/cli-path \]; then WORKTREE_MGR=\$\(dirname "\$\(cat \.aimi/cli-path\)"\)/worktree-manager\.sh; if \[ ! -x "\$WORKTREE_MGR" \]; then WORKTREE_MGR=""; fi; fi$'; then
  echo "$ALLOW"
  exit 0
fi

# =============================================================================
# Docker patterns for /aimi:swarm (Patterns 13–18)
# Safety rule: all approved Docker commands must involve the aimi- prefix
# (container names) or aimi-swarm label. Arbitrary Docker commands are rejected.
# =============================================================================

# --- Pattern 13: docker version (availability check) ---
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

# --- Pattern 14: docker run --rm with aimi-swarm- container name ---
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

# --- Pattern 15: docker container ls with aimi-swarm filter ---
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

# --- Pattern 16: docker rm -f with aimi-swarm- container name ---
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

# --- Pattern 17: docker container prune with aimi-swarm label ---
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

# --- Pattern 18: docker ps with aimi- filter ---
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
