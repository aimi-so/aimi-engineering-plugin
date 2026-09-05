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

# Layer 0-dev: AIMI_DEV_DIR, the development override, ahead of everything
# below and honored on EVERY host -- no CLAUDECODE gate, unlike AIMI_PLUGIN_DIR
# in the next block. The asymmetry is deliberate and is argued once, in
# commands/references/cli-path-resolution.md: AIMI_PLUGIN_DIR names where a
# converter installed the plugin, so inside Claude Code (which has an install
# of its own) honoring it would let another host's install win; AIMI_DEV_DIR
# names a tree the operator is deliberately testing, so gating it on
# CLAUDECODE would make it work only where nobody needs it.
#
# Four of the five checks are the same ones the two branches below apply, for
# the same reason -- the absolute-path check especially, since these scripts
# run from an arbitrary repository's checkout. The fifth has no counterpart
# there: a path under a `/.worktrees/` segment is refused, exactly as
# write_global_cli_cache in aimi-cli.sh refuses one, because a worktree copy is
# ephemeral and every later call would hit exit 127 once it is cleaned up.
if [ -n "${AIMI_DEV_DIR:-}" ] && [ "${AIMI_DEV_DIR#/}" != "$AIMI_DEV_DIR" ] && [ -d "$AIMI_DEV_DIR" ] && [ -x "$AIMI_DEV_DIR/scripts/aimi-cli.sh" ] && [ "${AIMI_DEV_DIR#*/.worktrees/}" = "$AIMI_DEV_DIR" ]; then
  AIMI_CLI="$AIMI_DEV_DIR/scripts/aimi-cli.sh"
fi

# Layer 0: AIMI_PLUGIN_DIR (OpenCode install) / CLAUDE_PLUGIN_ROOT, skipped
# for AIMI_PLUGIN_DIR when CLAUDECODE is set so the Claude Code cache always
# wins there.
#
# Both branches apply cli-path-resolution.md's four documented Layer 0
# checks: (1) env var non-empty, (2) path absolute, (3) directory exists,
# (4) target script executable. The absolute-path check is the load-bearing
# one here and is NOT redundant with the executable check: these scripts run
# from an arbitrary repository's checkout, so a RELATIVE value (a bare "."
# being the worst case) makes "$VAR/scripts/aimi-cli.sh" resolve against
# that repository instead of a plugin install -- handing execution to any
# checkout that happens to ship its own executable scripts/aimi-cli.sh.
# CLAUDE_PLUGIN_ROOT carries the identical guards because it is the same
# class of untrusted env-var-derived path; it has no section of its own in
# cli-path-resolution.md (that doc's four-layer strategy is written for
# command authoring generally, while CLAUDE_PLUGIN_ROOT is specific to this
# one sourced helper), so this comment is its documentation.
#
# The `[ -z "$AIMI_CLI" ]` opening this block is what makes Layer 0-dev above
# an actual layer rather than a value this one immediately overwrites: without
# it, an operator running a dev tree on an OpenCode host would silently get the
# installed copy back. Every later layer already guards itself the same way.
if [ -z "$AIMI_CLI" ]; then
  if [ -z "${CLAUDECODE:-}" ] && [ -n "${AIMI_PLUGIN_DIR:-}" ] && [ "${AIMI_PLUGIN_DIR#/}" != "$AIMI_PLUGIN_DIR" ] && [ -d "$AIMI_PLUGIN_DIR" ] && [ -x "$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh" ]; then
    AIMI_CLI="$AIMI_PLUGIN_DIR/scripts/aimi-cli.sh"
  elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ "${CLAUDE_PLUGIN_ROOT#/}" != "$CLAUDE_PLUGIN_ROOT" ] && [ -d "$CLAUDE_PLUGIN_ROOT" ] && [ -x "$CLAUDE_PLUGIN_ROOT/scripts/aimi-cli.sh" ]; then
    AIMI_CLI="$CLAUDE_PLUGIN_ROOT/scripts/aimi-cli.sh"
  fi
fi

# Layer 1: global cache file (new XDG path first, then the legacy path).
if [ -z "$AIMI_CLI" ]; then
  AIMI_CLI=$(cat "${AIMI_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/aimi}/cli-path" 2>/dev/null || cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/aimi-engineering-cli-path" 2>/dev/null)
  if [ -n "$AIMI_CLI" ] && [ ! -x "$AIMI_CLI" ]; then
    AIMI_CLI=""
  fi
fi

# Layer 2: glob fallback under the Claude Code plugin cache (zsh-safe via
# `bash -c`, matching cli-path-resolution.md's own Layer 2 exactly), then
# validated the same way Layer 1's cached path is directly above -- `ls`
# matching a name proves only that the path exists, not that it can be run.
# Clearing it back to empty on failure lets the not-found error below fire
# with its own clear message instead of the caller dying on a bare
# "Permission denied" from a path this file already knew was unusable.
#
# The pipeline picks the newest VERSION, not the last line `ls` prints: `ls`
# collates 1.121.3 before 1.9.0 ('1' < '9' at the third character), and a plain
# `sort -V` over whole paths would order by marketplace-entry directory first
# because the glob spans two wildcards. Each candidate is therefore prefixed
# with its own version segment and the sort keys on that. The grep is part of
# that rule and not an optimization: `sort -V` is a total order over arbitrary
# strings rather than a filter, so a cache directory that is not a version at
# all is still ranked -- and ranked ABOVE the real ones. Measured: a sibling
# named 1.124.0.bak beside 1.124.0 wins, and a directory named zz beats
# 1.127.0. The canonical rule is _resolve_latest_cache_path in aimi-cli.sh; it
# is inlined rather than called, because it lives inside the very file this
# block is resolving.
if [ -z "$AIMI_CLI" ]; then
  AIMI_CLI=$(bash -c 'ls ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/*/aimi-engineering/*/scripts/aimi-cli.sh 2>/dev/null | sed -E "s#.*/aimi-engineering/([^/]+)/.*#\1 &#" | grep -E "^[0-9]+\.[0-9]+\.[0-9]+ " | sort -V | tail -1 | cut -d" " -f2-')
  if [ -n "$AIMI_CLI" ] && [ ! -x "$AIMI_CLI" ]; then
    AIMI_CLI=""
  fi
fi

if [ -z "$AIMI_CLI" ]; then
  echo "Error: aimi-cli.sh not found. Set AIMI_PLUGIN_DIR, or reinstall the aimi-engineering plugin." >&2
  exit 1
fi
