# _resolve-cli.sh - resolves $AIMI_CLI for the resolve-pr-parallel scripts.
#
# Sourced by get-pr-comments and resolve-pr-thread -- never executed on its
# own; an internal helper, not a third publicly documented entry point.
#
# Why this exists as a standalone file instead of relying on an inherited
# env var: install.sh's install_skills() copies everything under a skill's
# scripts/ directory byte-for-byte (`cp -R`, only chmod +x on *.sh files --
# no content rewrite), unlike commands/*.md bodies, which go through
# translate_command_body's explicit ${CLAUDE_PLUGIN_ROOT} -> $AIMI_PLUGIN_DIR
# substitution. A standalone script also has no LLM in the loop to interpret
# commands/references/cli-path-resolution.md's prose the way a command
# markdown file's steps are interpreted. So this file mirrors that doc's
# Layer 0-2 strategy as literal, executable bash instead (Layer 3's
# per-project .aimi/cli-path fallback is intentionally omitted -- these
# scripts are invoked from an arbitrary CWD, not necessarily a project
# root).
#
# On success, sets AIMI_CLI to an executable path and returns normally. On
# failure, prints a clear error to stderr and exits 1 -- letting the caller
# fall through to an unguarded "command not found" for whatever subcommand
# it tried to run next would be far less clear.

AIMI_CLI=""

# Layer 0: AIMI_PLUGIN_DIR (OpenCode install) / CLAUDE_PLUGIN_ROOT, skipped
# for AIMI_PLUGIN_DIR when CLAUDECODE is set so the Claude Code cache always
# wins there.
if [ -z "${CLAUDECODE:-}" ] && [ -n "${AIMI_PLUGIN_DIR:-}" ] && [ -x "$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh" ]; then
  AIMI_CLI="$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh"
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -x "$CLAUDE_PLUGIN_ROOT/scripts/aimi-cli.sh" ]; then
  AIMI_CLI="$CLAUDE_PLUGIN_ROOT/scripts/aimi-cli.sh"
fi

# Layer 1: global cache file (new XDG path first, then the legacy path).
if [ -z "$AIMI_CLI" ]; then
  AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
  if [ -n "$AIMI_CLI" ] && [ ! -x "$AIMI_CLI" ]; then
    AIMI_CLI=""
  fi
fi

# Layer 2: glob fallback under the Claude Code plugin cache (zsh-safe via
# `bash -c`, matching cli-path-resolution.md's own Layer 2 exactly).
if [ -z "$AIMI_CLI" ]; then
  AIMI_CLI=$(bash -c 'ls ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | tail -1')
fi

if [ -z "$AIMI_CLI" ]; then
  echo "Error: aimi-cli.sh not found. Set AIMI_PLUGIN_DIR, or reinstall the aimi-engineering plugin." >&2
  exit 1
fi
