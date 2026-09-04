#!/bin/bash
# auto-approve-cli.sh
# Auto-approves only AIMI CLI and Worktree Manager commands.
# Rejects shell metacharacter chaining and enforces subcommand whitelists.

# NOTE -- deliberately NOT gated on CLAUDECODE, unlike inspect-session.py.
# plugins/aimi-engineering/CLAUDE.md asks hooks emitting hookSpecificOutput to
# gate when their output schema is Claude Code-specific, and this one's is. It
# is left ungated for a reason worth stating rather than rediscovering:
#   - install.sh registers no hooks at all for OpenCode, so this file is copied
#     there but never invoked. The gate would protect against nothing.
#   - CLAUDECODE is observably set in a SessionStart hook's environment, which
#     is what inspect-session.py relies on; whether a PreToolUse hook inherits
#     the same environment has NOT been verified here. If it does not, adding
#     the gate would silently stop every approval, and a machine with Bash(*)
#     in its allow list cannot tell that apart from working correctly.
# Verify the PreToolUse hook environment before adding the gate; the asymmetric
# downside is why it is absent, not oversight.
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

# The payload MUST name the event this hook is registered on in hooks.json
# (PreToolUse / matcher Bash) and use that event's decision key. Anthropic's
# plugin-dev hook-development skill documents PreToolUse output as
# hookSpecificOutput.permissionDecision = allow|deny|ask; hook_utils.deny()
# emits the same shape for the sibling PreToolUse guards in this directory.
# This line previously read hookEventName "PermissionRequest" with a
# decision.behavior object -- the shape of a DIFFERENT event, one this plugin
# never registers -- so it approved nothing from the day it was written.
# test_auto_approve_cli.py now reads hooks.json and fails if the two disagree.
ALLOW='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'

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

# --- Resolve XDG aimi config directory for new cache path matching ---
# Commands may reference the aimi config dir as:
#   1. ~/.config/aimi                                        (tilde shorthand)
#   2. ${XDG_CONFIG_HOME:-$HOME/.config}/aimi                (parameterized XDG form)
#   3. ${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}  (AIMI_CONFIG_DIR form)
#   4. /resolved/absolute/path/aimi                          (resolved absolute path)
RESOLVED_AIMI_DIR="${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}"
RESOLVED_AIMI_DIR="${RESOLVED_AIMI_DIR%/}"
ESCAPED_AIMI_DIR=$(printf '%s' "$RESOLVED_AIMI_DIR" | sed 's/[.[\*^$()+?{|\\]/\\&/g; s/\//\\\//g')
# Build the aimi dir regex alternation:
#   ~/\.config\/aimi  |  \$\{XDG_CONFIG_HOME:-\$HOME\/\.config\}\/aimi  |  \$\{AIMI_CONFIG_DIR:-...\}  |  /resolved/path
AIMI_DIR_RE="(~/\\.config/aimi|\\\$\\{XDG_CONFIG_HOME:-\\\$HOME/\\.config\\}/aimi|\\\$\\{AIMI_CONFIG_DIR:-\\\$\\{XDG_CONFIG_HOME:-\\\$HOME/\\.config\\}/aimi\\}|${ESCAPED_AIMI_DIR})"

# --- The Layer 2 glob pipeline's version-comparison tail ---
# Patterns 7 and 8 approve the Layer 2 glob one-liners written out in
# commands/references/cli-path-resolution.md, and they match the command text
# LITERALLY -- so this tail has to be spelled here exactly as those blocks
# spell it, or the commands stop being auto-approved and start prompting.
# The rule it encodes (sort on the version path segment, never lexicographic
# `ls` order and never a whole-path `sort -V`) is owned by
# _resolve_latest_cache_path in scripts/aimi-cli.sh.
#
# It is escaped by the same sed pass that escapes the config dirs above rather
# than by hand, for two reasons: the fragment is dense with ERE
# metacharacters -- `\1` left unescaped is a BACK-REFERENCE, not a literal --
# and hand-escaping it twice, once here and once for the worktree-manager
# twin, is exactly how two copies of one string drift apart.
#
# THE `grep -E` IN THE MIDDLE IS PART OF THE LITERAL and not an optimization
# the commands may skip: `sort -V` is a total order over arbitrary strings, so
# a cache directory that is not a version at all still gets ranked, and gets
# ranked above the real ones -- a sibling named `1.124.0.bak` beside `1.124.0`
# wins outright. Both this constant and every command block it approves gained
# it in the same commit, because a command that emits the filtered pipeline
# while this constant still spells the unfiltered one is a command that stops
# being auto-approved. That escape pass handles it unaided: `[0-9]` becomes
# `\[0-9\]` and each `\.` becomes `\\\.`, which is the literal backslash-dot
# the command text really carries.
GLOB_VERSION_TAIL=' | sed -E "s#.*/aimi-engineering/([^/]+)/.*#\1 &#" | grep -E "^[0-9]+\.[0-9]+\.[0-9]+ " | sort -V | tail -1 | cut -d" " -f2-'
GLOB_VERSION_TAIL_RE=$(printf '%s' "$GLOB_VERSION_TAIL" | sed 's/[].[\*^$()+?{|\\}]/\\&/g')

# The same tail WITHOUT the numeric filter -- the spelling every command block
# carried before the filter was added. Kept for the reason Pattern 0a is kept
# beside Pattern 0a2: a fix for today's text must not un-approve yesterday's.
# A command body that entered a conversation before an upgrade is still run
# verbatim afterwards, and the only thing the hook can do about a line it no
# longer recognizes is prompt the user for it -- which is precisely the
# regression the mirrored-idiom rule exists to prevent. Patterns 7L and 8L
# below are built from this and are otherwise byte-identical to 7 and 8.
# Deliberately a SECOND LITERAL rather than a loosened first one: the two
# alternatives are exact strings, and no path that was not already spelled out
# here becomes matchable.
GLOB_VERSION_TAIL_LEGACY=' | sed -E "s#.*/aimi-engineering/([^/]+)/.*#\1 &#" | sort -V | tail -1 | cut -d" " -f2-'
GLOB_VERSION_TAIL_LEGACY_RE=$(printf '%s' "$GLOB_VERSION_TAIL_LEGACY" | sed 's/[].[\*^$()+?{|\\}]/\\&/g')

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

# --- Pattern 0a2: Layer 0 AIMI_CLI assignment, current five-condition form ---
# The Layer 0 guard grew from two conditions to five (CLAUDECODE unset, var set,
# absolute path, directory exists, file executable). Pattern 0a above still
# matches the older two-condition spelling; this one matches what commands/
# actually emits today. Both stay: an older install may still carry either.
if echo "$COMMAND" | grep -qE '^if \[ -z "\$\{CLAUDECODE:-\}" \] && \[ -n "\$AIMI_PLUGIN_DIR" \] && \[ "\$\{AIMI_PLUGIN_DIR#/\}" != "\$AIMI_PLUGIN_DIR" \] && \[ -d "\$AIMI_PLUGIN_DIR" \] && \[ -x "\$AIMI_PLUGIN_DIR/scripts/aimi-cli\.sh" \]; then AIMI_CLI="\$AIMI_PLUGIN_DIR/scripts/aimi-cli\.sh"; fi$'; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 0b2: Layer 0 WORKTREE_MGR assignment, current five-condition form ---
if echo "$COMMAND" | grep -qE '^if \[ -z "\$\{CLAUDECODE:-\}" \] && \[ -n "\$AIMI_PLUGIN_DIR" \] && \[ "\$\{AIMI_PLUGIN_DIR#/\}" != "\$AIMI_PLUGIN_DIR" \] && \[ -d "\$AIMI_PLUGIN_DIR" \] && \[ -x "\$AIMI_PLUGIN_DIR/skills/git-worktree/scripts/worktree-manager\.sh" \]; then WORKTREE_MGR="\$AIMI_PLUGIN_DIR/skills/git-worktree/scripts/worktree-manager\.sh"; fi$'; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 0c: Layer 0 AIMI_CLI assignment via AIMI_DEV_DIR ---
# Approves: if [ -n "$AIMI_DEV_DIR" ] && [ "${AIMI_DEV_DIR#/}" != "$AIMI_DEV_DIR" ] && [ -d "$AIMI_DEV_DIR" ] && [ -x "$AIMI_DEV_DIR/scripts/aimi-cli.sh" ] && [ "${AIMI_DEV_DIR#*/.worktrees/}" = "$AIMI_DEV_DIR" ]; then AIMI_CLI="$AIMI_DEV_DIR/scripts/aimi-cli.sh"; fi
#
# The development override sits AHEAD of AIMI_PLUGIN_DIR and carries no
# CLAUDECODE gate -- see _dev_dir_path in scripts/aimi-cli.sh for why that
# asymmetry is deliberate. Its five conditions are matched literally, in
# order, like every Pattern 0 above: the last one is the `.worktrees/`
# refusal, expressed as a prefix-strip comparison rather than a `case` so the
# whole guard stays one line an agent can run in one Bash call.
if echo "$COMMAND" | grep -qE '^if \[ -n "\$AIMI_DEV_DIR" \] && \[ "\$\{AIMI_DEV_DIR#/\}" != "\$AIMI_DEV_DIR" \] && \[ -d "\$AIMI_DEV_DIR" \] && \[ -x "\$AIMI_DEV_DIR/scripts/aimi-cli\.sh" \] && \[ "\$\{AIMI_DEV_DIR#\*/\.worktrees/\}" = "\$AIMI_DEV_DIR" \]; then AIMI_CLI="\$AIMI_DEV_DIR/scripts/aimi-cli\.sh"; fi$'; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 0d: Layer 0 WORKTREE_MGR assignment via AIMI_DEV_DIR ---
# Approves: if [ -n "$AIMI_DEV_DIR" ] && [ "${AIMI_DEV_DIR#/}" != "$AIMI_DEV_DIR" ] && [ -d "$AIMI_DEV_DIR" ] && [ -x "$AIMI_DEV_DIR/skills/git-worktree/scripts/worktree-manager.sh" ] && [ "${AIMI_DEV_DIR#*/.worktrees/}" = "$AIMI_DEV_DIR" ]; then WORKTREE_MGR="$AIMI_DEV_DIR/skills/git-worktree/scripts/worktree-manager.sh"; fi
if echo "$COMMAND" | grep -qE '^if \[ -n "\$AIMI_DEV_DIR" \] && \[ "\$\{AIMI_DEV_DIR#/\}" != "\$AIMI_DEV_DIR" \] && \[ -d "\$AIMI_DEV_DIR" \] && \[ -x "\$AIMI_DEV_DIR/skills/git-worktree/scripts/worktree-manager\.sh" \] && \[ "\$\{AIMI_DEV_DIR#\*/\.worktrees/\}" = "\$AIMI_DEV_DIR" \]; then WORKTREE_MGR="\$AIMI_DEV_DIR/skills/git-worktree/scripts/worktree-manager\.sh"; fi$'; then
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
  # Cache read: AIMI_CLI=$(cat <config>/aimi-engineering-cli-path 2>/dev/null)  [legacy]
  if echo "$COMMAND" | grep -qE "^AIMI_CLI=\\$\\(cat ${CONFIG_DIR_RE}/aimi-engineering-cli-path 2>/dev/null\\)\$"; then
    echo "$ALLOW"
    exit 0
  fi
  # Cache read: AIMI_CLI=$(cat <aimi-dir>/cli-path 2>/dev/null)  [new XDG]
  if echo "$COMMAND" | grep -qE "^AIMI_CLI=\\$\\(cat ${AIMI_DIR_RE}/cli-path 2>/dev/null\\)\$"; then
    echo "$ALLOW"
    exit 0
  fi
  # Per-Call Resolution: AIMI_CLI=$(cat "<aimi-dir>/cli-path" 2>/dev/null || cat "<config>/aimi-engineering-cli-path" 2>/dev/null)
  # This is the form commands/ actually emits (quoted paths, legacy fallback) --
  # 104 occurrences. The bare unquoted branch above predates it.
  if echo "$COMMAND" | grep -qE "^AIMI_CLI=\\$\\(cat \"${AIMI_DIR_RE}/cli-path\" 2>/dev/null \\|\\| cat \"${CONFIG_DIR_RE}/aimi-engineering-cli-path\" 2>/dev/null\\)\$"; then
    echo "$ALLOW"
    exit 0
  fi
  # Canonical single-line form: the Per-Call Resolution assignment directly
  # above, joined by `;` with the fail-loud guard Pattern 13 below matches on
  # its own -- the one-line spelling commands/references/cli-path-resolution.md's
  # "Canonical single-line form (call sites)" section defines for a call site
  # to use inline instead of two statements. Matched as one literal line built
  # from those same two pieces, never a new alternative, so a chained
  # `; rm -rf /` appended after the guard still falls through to the normal
  # prompt: the guard's ${VAR:?word} word is matched literally here too, for
  # the reason Pattern 13's own comment gives -- that word IS expanded when
  # the variable is empty, so admitting it by wildcard would auto-approve
  # command substitution.
  if echo "$COMMAND" | grep -qE "^AIMI_CLI=\\$\\(cat \"${AIMI_DIR_RE}/cli-path\" 2>/dev/null \\|\\| cat \"${CONFIG_DIR_RE}/aimi-engineering-cli-path\" 2>/dev/null\\); : \"\\$\\{AIMI_CLI:\\?AIMI_CLI is empty — re-resolve via cat ~/\\.config/aimi/cli-path in this Bash call\\}\"\$"; then
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
  # Cache read: WORKTREE_MGR=$(cat <config>/aimi-engineering-worktree-path 2>/dev/null)  [legacy]
  if echo "$COMMAND" | grep -qE "^WORKTREE_MGR=\\$\\(cat ${CONFIG_DIR_RE}/aimi-engineering-worktree-path 2>/dev/null\\)\$"; then
    echo "$ALLOW"
    exit 0
  fi
  # Cache read: WORKTREE_MGR=$(cat <aimi-dir>/worktree-path 2>/dev/null)  [new XDG]
  if echo "$COMMAND" | grep -qE "^WORKTREE_MGR=\\$\\(cat ${AIMI_DIR_RE}/worktree-path 2>/dev/null\\)\$"; then
    echo "$ALLOW"
    exit 0
  fi
  # Per-Call Resolution: WORKTREE_MGR=$(cat "<aimi-dir>/worktree-path" 2>/dev/null || cat "<config>/aimi-engineering-worktree-path" 2>/dev/null)
  if echo "$COMMAND" | grep -qE "^WORKTREE_MGR=\\$\\(cat \"${AIMI_DIR_RE}/worktree-path\" 2>/dev/null \\|\\| cat \"${CONFIG_DIR_RE}/aimi-engineering-worktree-path\" 2>/dev/null\\)\$"; then
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

# --- Pattern 6a: AIMI_CLI Layer 1 cache read, guarded form ---
# Approves: if [ -z "$AIMI_CLI" ]; then AIMI_CLI=$(cat "<aimi-dir>/cli-path" 2>/dev/null || cat "<config>/aimi-engineering-cli-path" 2>/dev/null); fi
# Pattern 1 cannot reach this: it gates on ^AIMI_CLI= and this line starts with `if`.
if echo "$COMMAND" | grep -qE "^if \\[ -z \"\\\$AIMI_CLI\" \\]; then AIMI_CLI=\\$\\(cat \"${AIMI_DIR_RE}/cli-path\" 2>/dev/null \\|\\| cat \"${CONFIG_DIR_RE}/aimi-engineering-cli-path\" 2>/dev/null\\); fi\$"; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 6b: WORKTREE_MGR Layer 1 cache read, guarded form ---
if echo "$COMMAND" | grep -qE "^if \\[ -z \"\\\$WORKTREE_MGR\" \\]; then WORKTREE_MGR=\\$\\(cat \"${AIMI_DIR_RE}/worktree-path\" 2>/dev/null \\|\\| cat \"${CONFIG_DIR_RE}/aimi-engineering-worktree-path\" 2>/dev/null\\); fi\$"; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 7: AIMI_CLI Layer 2 glob fallback (bash -c wrapper) ---
# Approves: if [ -z "$AIMI_CLI" ]; then AIMI_CLI=$(bash -c 'ls <config>/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null<version tail>'); fi
if echo "$COMMAND" | grep -qE "^if \\[ -z \"\\\$AIMI_CLI\" \\]; then AIMI_CLI=\\$\\(bash -c 'ls ${CONFIG_DIR_RE}/plugins/cache/\\*/aimi-engineering/\\*/scripts/aimi-cli\\.sh 2>/dev/null${GLOB_VERSION_TAIL_RE}'\\); fi\$"; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 8: WORKTREE_MGR Layer 2 glob fallback (bash -c wrapper) ---
# Approves: if [ -z "$WORKTREE_MGR" ]; then WORKTREE_MGR=$(bash -c 'ls <config>/plugins/cache/*/aimi-engineering/*/skills/git-worktree/scripts/worktree-manager.sh 2>/dev/null<version tail>'); fi
if echo "$COMMAND" | grep -qE "^if \\[ -z \"\\\$WORKTREE_MGR\" \\]; then WORKTREE_MGR=\\$\\(bash -c 'ls ${CONFIG_DIR_RE}/plugins/cache/\\*/aimi-engineering/\\*/skills/git-worktree/scripts/worktree-manager\\.sh 2>/dev/null${GLOB_VERSION_TAIL_RE}'\\); fi\$"; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 7L: AIMI_CLI Layer 2 glob fallback, pre-numeric-filter spelling ---
# Byte-identical to Pattern 7 except for the tail. See GLOB_VERSION_TAIL_LEGACY.
if echo "$COMMAND" | grep -qE "^if \\[ -z \"\\\$AIMI_CLI\" \\]; then AIMI_CLI=\\$\\(bash -c 'ls ${CONFIG_DIR_RE}/plugins/cache/\\*/aimi-engineering/\\*/scripts/aimi-cli\\.sh 2>/dev/null${GLOB_VERSION_TAIL_LEGACY_RE}'\\); fi\$"; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 8L: WORKTREE_MGR Layer 2 glob fallback, pre-numeric-filter spelling ---
if echo "$COMMAND" | grep -qE "^if \\[ -z \"\\\$WORKTREE_MGR\" \\]; then WORKTREE_MGR=\\$\\(bash -c 'ls ${CONFIG_DIR_RE}/plugins/cache/\\*/aimi-engineering/\\*/skills/git-worktree/scripts/worktree-manager\\.sh 2>/dev/null${GLOB_VERSION_TAIL_LEGACY_RE}'\\); fi\$"; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 9: AIMI_CLI Layer 2 cache write [legacy] ---
# Approves: if [ -n "$AIMI_CLI" ]; then printf '%s\n' "$AIMI_CLI" > "<config>/aimi-engineering-cli-path.tmp" && mv "<config>/aimi-engineering-cli-path.tmp" "<config>/aimi-engineering-cli-path" && chmod 600 "<config>/aimi-engineering-cli-path"; fi
if echo "$COMMAND" | grep -qE "^if \\[ -n \"\\\$AIMI_CLI\" \\]; then printf '%s\\\\n' \"\\\$AIMI_CLI\" > \"${CONFIG_DIR_RE}/aimi-engineering-cli-path\\.tmp\" && mv \"${CONFIG_DIR_RE}/aimi-engineering-cli-path\\.tmp\" \"${CONFIG_DIR_RE}/aimi-engineering-cli-path\" && chmod 600 \"${CONFIG_DIR_RE}/aimi-engineering-cli-path\"; fi\$"; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 10: WORKTREE_MGR Layer 2 cache write [legacy] ---
# Approves: if [ -n "$WORKTREE_MGR" ]; then printf '%s\n' "$WORKTREE_MGR" > "<config>/aimi-engineering-worktree-path.tmp" && mv "<config>/aimi-engineering-worktree-path.tmp" "<config>/aimi-engineering-worktree-path" && chmod 600 "<config>/aimi-engineering-worktree-path"; fi
if echo "$COMMAND" | grep -qE "^if \\[ -n \"\\\$WORKTREE_MGR\" \\]; then printf '%s\\\\n' \"\\\$WORKTREE_MGR\" > \"${CONFIG_DIR_RE}/aimi-engineering-worktree-path\\.tmp\" && mv \"${CONFIG_DIR_RE}/aimi-engineering-worktree-path\\.tmp\" \"${CONFIG_DIR_RE}/aimi-engineering-worktree-path\" && chmod 600 \"${CONFIG_DIR_RE}/aimi-engineering-worktree-path\"; fi\$"; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 9x: AIMI_CLI Layer 2 cache write [new XDG] ---
# Approves: if [ -n "$AIMI_CLI" ]; then printf '%s\n' "$AIMI_CLI" > "<aimi-dir>/cli-path.tmp" && mv "<aimi-dir>/cli-path.tmp" "<aimi-dir>/cli-path" && chmod 600 "<aimi-dir>/cli-path"; fi
if echo "$COMMAND" | grep -qE "^if \\[ -n \"\\\$AIMI_CLI\" \\]; then printf '%s\\\\n' \"\\\$AIMI_CLI\" > \"${AIMI_DIR_RE}/cli-path\\.tmp\" && mv \"${AIMI_DIR_RE}/cli-path\\.tmp\" \"${AIMI_DIR_RE}/cli-path\" && chmod 600 \"${AIMI_DIR_RE}/cli-path\"; fi\$"; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 10x: WORKTREE_MGR Layer 2 cache write [new XDG] ---
# Approves: if [ -n "$WORKTREE_MGR" ]; then printf '%s\n' "$WORKTREE_MGR" > "<aimi-dir>/worktree-path.tmp" && mv "<aimi-dir>/worktree-path.tmp" "<aimi-dir>/worktree-path" && chmod 600 "<aimi-dir>/worktree-path"; fi
if echo "$COMMAND" | grep -qE "^if \\[ -n \"\\\$WORKTREE_MGR\" \\]; then printf '%s\\\\n' \"\\\$WORKTREE_MGR\" > \"${AIMI_DIR_RE}/worktree-path\\.tmp\" && mv \"${AIMI_DIR_RE}/worktree-path\\.tmp\" \"${AIMI_DIR_RE}/worktree-path\" && chmod 600 \"${AIMI_DIR_RE}/worktree-path\"; fi\$"; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 9z: AIMI_CLI Layer 2 cache write, current _aimi_cfg form ---
# Approves: if [ -n "$AIMI_CLI" ]; then _aimi_cfg="<aimi-dir>"; mkdir -p "$_aimi_cfg" && printf '%s\\n' "$AIMI_CLI" > "$_aimi_cfg/cli-path.tmp" && mv "$_aimi_cfg/cli-path.tmp" "$_aimi_cfg/cli-path" && chmod 600 "$_aimi_cfg/cli-path"; fi
# The write grew an _aimi_cfg temp variable and an mkdir -p; Pattern 9x above
# still matches the older prefix-free spelling.
if echo "$COMMAND" | grep -qE "^if \\[ -n \"\\\$AIMI_CLI\" \\]; then _aimi_cfg=\"${AIMI_DIR_RE}\"; mkdir -p \"\\\$_aimi_cfg\" && printf '%s\\\\n' \"\\\$AIMI_CLI\" > \"\\\$_aimi_cfg/cli-path\\.tmp\" && mv \"\\\$_aimi_cfg/cli-path\\.tmp\" \"\\\$_aimi_cfg/cli-path\" && chmod 600 \"\\\$_aimi_cfg/cli-path\"; fi\$"; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 10z: WORKTREE_MGR Layer 2 cache write, current _aimi_cfg form ---
# (pairs with 9z above; 10y below is the unpaired mkdir pattern and predates both)
if echo "$COMMAND" | grep -qE "^if \\[ -n \"\\\$WORKTREE_MGR\" \\]; then _aimi_cfg=\"${AIMI_DIR_RE}\"; mkdir -p \"\\\$_aimi_cfg\" && printf '%s\\\\n' \"\\\$WORKTREE_MGR\" > \"\\\$_aimi_cfg/worktree-path\\.tmp\" && mv \"\\\$_aimi_cfg/worktree-path\\.tmp\" \"\\\$_aimi_cfg/worktree-path\" && chmod 600 \"\\\$_aimi_cfg/worktree-path\"; fi\$"; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 10y: mkdir -p for new XDG aimi config dir ---
# Approves: mkdir -p <aimi-dir>
if echo "$COMMAND" | grep -qE "^mkdir -p \"?${AIMI_DIR_RE}\"?\$"; then
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
# Approves: if [ -z "$WORKTREE_MGR" ] && [ -f .aimi/cli-path ]; then WORKTREE_MGR=$(dirname "$(dirname "$(cat .aimi/cli-path)")")/skills/git-worktree/scripts/worktree-manager.sh; if [ ! -x "$WORKTREE_MGR" ]; then WORKTREE_MGR=""; fi; fi
if echo "$COMMAND" | grep -qE '^if \[ -z "\$WORKTREE_MGR" \] && \[ -f \.aimi/cli-path \]; then WORKTREE_MGR=\$\(dirname "\$\(dirname "\$\(cat \.aimi/cli-path\)"\)"\)/skills/git-worktree/scripts/worktree-manager\.sh; if \[ ! -x "\$WORKTREE_MGR" \]; then WORKTREE_MGR=""; fi; fi$'; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 13: AIMI_CLI fail-loud guard ---
# Approves the exact guard line the Per-Call Resolution pattern emits:
#   : "${AIMI_CLI:?AIMI_CLI is empty — re-resolve via cat ~/.config/aimi/cli-path in this Bash call}"
# Matched as a LITERAL, never as a wildcard over the ${VAR:?word} word. That is
# deliberate: `word` in ${VAR:?word} IS expanded when VAR is unset, so a pattern
# admitting arbitrary text there would auto-approve command substitution.
if echo "$COMMAND" | grep -qE '^: "\$\{AIMI_CLI:\?AIMI_CLI is empty — re-resolve via cat ~/\.config/aimi/cli-path in this Bash call\}"$'; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 14: WORKTREE_MGR fail-loud guard ---
# Same literal-only rule as Pattern 13 above.
if echo "$COMMAND" | grep -qE '^: "\$\{WORKTREE_MGR:\?WORKTREE_MGR is empty — re-resolve via cat ~/\.config/aimi/worktree-path in this Bash call\}"$'; then
  echo "$ALLOW"
  exit 0
fi

# --- Pattern 14b: WORKTREE_MGR fail-loud guard, existence-checking form ---
# Approves the guard line commands/ emits today: Pattern 14's `:?` guard, then
# an existence test on the same variable.
#
#   : "${WORKTREE_MGR:?…}"; [ -x "$WORKTREE_MGR" ] || { echo "…" >&2; exit 1; }
#
# The second half is not decoration. `:?` fires only on an EMPTY variable, and
# the failure it was written for is a NON-empty one naming a version directory
# that has since been pruned -- $WORKTREE_MGR reads fine, the guard passes, and
# the run continues against a path to nothing. Pattern 14 stays above for the
# older single-statement spelling that older installs still carry.
#
# Kept as a full anchored literal for the same reason Pattern 13 states, and
# for a second one: this shape is a valid prefix followed by a chained command,
# which is exactly what test_adversarial_lines_are_refused' "valid-prefix-with-
# a-chained-command" case checks. Anchoring both ends is what keeps a real
# `; rm -rf /` after the same prefix refused.
if echo "$COMMAND" | grep -qE '^: "\$\{WORKTREE_MGR:\?WORKTREE_MGR is empty — re-resolve via cat ~/\.config/aimi/worktree-path in this Bash call\}"; \[ -x "\$WORKTREE_MGR" \] \|\| \{ echo "WORKTREE_MGR is stale: \$WORKTREE_MGR does not exist — re-run check-version --quiet --fix" >&2; exit 1; \}$'; then
  echo "$ALLOW"
  exit 0
fi

# --- Everything else — normal permission prompt ---
exit 0
